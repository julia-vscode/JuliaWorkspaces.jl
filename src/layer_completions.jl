# Completion layer
#
# Produces completion items for a given byte offset in a Julia source file.
# All logic that was in LanguageServer/completions.jl now lives here,
# operating purely on CSTParser EXPR trees, StaticLint bindings/scopes,
# and SymbolServer stores — no LSP types.

using REPL
using .URIs2: uri2filepath

# ============================================================================
# Result types (LSP-free)
# ============================================================================

"""
Completion item kinds, mirroring LSP CompletionItemKind values.
"""
module CompletionKinds
    const Text     = 1
    const Method   = 2
    const Function = 3
    const Field    = 4
    const Variable = 6
    const Module   = 9
    const Unit     = 11
    const Value    = 12
    const Keyword  = 14
    const Snippet  = 15
    const File     = 17
    const Struct    = 22
end

"""
Insert text format constants.
"""
module InsertFormats
    const PlainText = 1
    const Snippet   = 2
end

"""
A text edit expressed as Positions.
"""
struct CompletionEdit
    start::Position
    stop::Position
    new_text::String
    uri::Union{Nothing,URI}  # nothing means same file
end

"""
A single completion result item (LSP-free).
"""
struct CompletionResultItem
    label::String
    kind::Int
    detail::Union{Nothing,String}
    detail_label::Union{Nothing,String}
    detail_description::Union{Nothing,String}
    documentation::Union{Nothing,String}  # markdown
    sort_text::Union{Nothing,String}
    filter_text::Union{Nothing,String}
    insert_text_format::Int
    text_edit::CompletionEdit
    additional_edits::Vector{CompletionEdit}
    data::Union{Nothing,String}
end

function CompletionResultItem(label, kind, detail, documentation, text_edit;
        detail_label=nothing, detail_description=nothing,
        sort_text=nothing, filter_text=nothing,
        insert_text_format=InsertFormats.PlainText,
        additional_edits=CompletionEdit[],
        data=nothing)
    CompletionResultItem(label, kind, detail, detail_label, detail_description,
        documentation, sort_text, filter_text, insert_text_format,
        text_edit, additional_edits, data)
end

"""
A complete completion result.
"""
struct CompletionResult
    is_incomplete::Bool
    items::Vector{CompletionResultItem}
end

# ============================================================================
# Internal state (replaces LS CompletionState — no server reference)
# ============================================================================

const Tokens = CSTParser.Tokens

struct _CompletionState
    offset::Int                                   # 0-based byte offset of cursor
    completions::Dict{String,CompletionResultItem}
    start_offset::Int                             # 0-based start of replacement range
    end_offset::Int                               # 0-based end of replacement range
    x::Union{Nothing,CSTParser.EXPR}              # expr at cursor
    cst::CSTParser.EXPR                           # file CST
    uri::URI
    st::SourceText
    meta_dict::MetaDict
    env::StaticLint.ExternalEnv
    completion_mode::Symbol
    using_stmts::Dict{String,Any}
    workspace  # JuliaWorkspace — untyped to avoid circular ref
end

function _add_completion_item(state::_CompletionState, item::CompletionResultItem)
    if haskey(state.completions, item.label) && state.completions[item.label].data === nothing
        return
    end
    state.completions[item.label] = item
end

function _getsymbols(state::_CompletionState)
    return StaticLint.getsymbols(state.env)
end

# ============================================================================
# Shared helpers (from LS utilities.jl — pure functions, no server)
# ============================================================================

"""
    _get_toks(text, offset)

Tokenize `text` and return the three tokens `(ppt, pt, t)` surrounding the
0-based byte `offset`.
"""
function _get_toks(text::AbstractString, offset)
    ts = CSTParser.Tokenize.tokenize(text)
    ppt = CSTParser.Tokens.RawToken(CSTParser.Tokens.ERROR, (0, 0), (0, 0), 1, 0, CSTParser.Tokens.NO_ERR, false, false)
    pt  = CSTParser.Tokens.RawToken(CSTParser.Tokens.ERROR, (0, 0), (0, 0), 1, 0, CSTParser.Tokens.NO_ERR, false, false)
    t   = CSTParser.Tokenize.Lexers.next_token(ts)

    while t.kind != CSTParser.Tokenize.Tokens.ENDMARKER
        if t.startbyte < offset <= t.endbyte + 1
            break
        end
        ppt = pt
        pt = t
        t = CSTParser.Tokenize.Lexers.next_token(ts)
    end
    return ppt, pt, t
end

"""
    _get_expr(x, offset, pos=0, ignorewhitespace=false)

Walk a CSTParser EXPR tree using **fullspan** to find the deepest EXPR at
`offset` (0-based byte offset).
"""
function _get_expr(x, offset, pos=0, ignorewhitespace=false)
    if pos > offset
        return nothing
    end
    if length(x) > 0 && CSTParser.headof(x) !== :NONSTDIDENTIFIER
        for a in x
            if pos < offset <= (pos + a.fullspan)
                return _get_expr(a, offset, pos, ignorewhitespace)
            end
            pos += a.fullspan
        end
    elseif pos == 0
        return x
    elseif (pos < offset <= (pos + x.fullspan))
        ignorewhitespace && pos + x.span < offset && return nothing
        return x
    end
end

"""
    _is_in_fexpr(x, f)

Walk EXPR parents until `f(x)` returns true.
"""
function _is_in_fexpr(x::CSTParser.EXPR, f)
    if f(x)
        return true
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _is_in_fexpr(CSTParser.parentof(x), f)
    else
        return false
    end
end

"""
    is_completion_match(s, prefix, cutoff=3)

Returns true if `s` starts with `prefix` or has a sufficiently high fuzzy score.
"""
function is_completion_match(s::AbstractString, prefix::AbstractString, cutoff=3)
    starter = if !any(isuppercase, prefix)
        startswith(lowercase(s), prefix)
    else
        startswith(s, prefix)
    end
    starter || REPL.fuzzyscore(prefix, s) >= cutoff
end

# ============================================================================
# Completion edit helpers (1-based string indices)
# ============================================================================

function _texteditfor(state::_CompletionState, partial, new_text)
    start_off = max(state.start_offset - length(partial), 0)
    CompletionEdit(position_at(state.st, start_off + 1), position_at(state.st, state.end_offset + 1), new_text, nothing)
end

# ============================================================================
# Completion kind mapping
# ============================================================================

function _completion_kind(b)
    if b isa StaticLint.Binding
        if b.type == StaticLint.CoreTypes.String
            return CompletionKinds.Text
        elseif b.type == StaticLint.CoreTypes.Function
            return CompletionKinds.Method
        elseif b.type == StaticLint.CoreTypes.Module
            return CompletionKinds.Module
        elseif b.type == Int || b.type == StaticLint.CoreTypes.Float64
            return CompletionKinds.Value
        elseif b.type == StaticLint.CoreTypes.DataType
            return CompletionKinds.Struct
        else
            return CompletionKinds.Variable
        end
    elseif b isa SymbolServer.ModuleStore || b isa SymbolServer.VarRef
        return CompletionKinds.Module
    elseif b isa SymbolServer.MethodStore
        return CompletionKinds.Method
    elseif b isa SymbolServer.FunctionStore
        return CompletionKinds.Function
    elseif b isa SymbolServer.DataTypeStore
        return CompletionKinds.Struct
    else
        return CompletionKinds.Variable
    end
end

function _completion_details_label(b)
    if b isa StaticLint.Binding
        if b.is_public
            return " (public)"
        end
    end
    return nothing
end

function _completion_details_description(b)
    td = get_typed_definition(b)
    td === missing ? nothing : string(td)
end

# ============================================================================
# String macro helpers
# ============================================================================

function _string_macro_altname(s)
    if startswith(s, "@") && endswith(s, "_str")
        return chop(s; head=1, tail=4) * '"'
    else
        return nothing
    end
end

# ============================================================================
# LaTeX / emoji completions
# ============================================================================

function _latex_completions(partial::String, state::_CompletionState)
    for (k, v) in Iterators.flatten((REPL.REPLCompletions.latex_symbols, REPL.REPLCompletions.emoji_symbols))
        if is_completion_match(string(k), partial)
            _add_completion_item(state, CompletionResultItem(
                k, CompletionKinds.Unit, nothing, v,
                _texteditfor(state, partial, v)))
        end
    end
end

function _is_latex_comp(s, i)
    firstindex(s) <= i <= lastindex(s) || return ""
    i0 = i = thisind(s, i)
    while firstindex(s) <= i
        s[i] == '\\' && return s[i:i0]
        !_is_latex_comp_char(s[i]) && return ""
        i = prevind(s, i)
    end
    return ""
end

_is_latex_comp_char(c::Char) = UInt32(c) <= typemax(UInt8) ? _is_latex_comp_char(UInt8(c)) : false
function _is_latex_comp_char(u)
    u === 0x21 ||
    u === 0x28 ||
    u === 0x29 ||
    u === 0x2b ||
    u === 0x2d ||
    u === 0x2f ||
    0x30 <= u <= 0x39 ||
    u === 0x3a ||
    u === 0x3d ||
    0x41 <= u <= 0x5a ||
    u === 0x5e ||
    u === 0x5f ||
    0x61 <= u <= 0x7a
end

# ============================================================================
# Keyword / snippet completions
# ============================================================================

const _snippet_completions = Dict{String,String}(
    "abstract" => "abstract type \$0 end",
    "baremodule" => "baremodule \$1\n\t\$0\nend",
    "begin" => "begin\n\t\$0\nend",
    "break" => "break",
    "catch" => "catch",
    "const" => "const ",
    "continue" => "continue",
    "do" => "do \$1\n\t\$0\nend",
    "else" => "else",
    "elseif" => "elseif ",
    "end" => "end",
    "export" => "export ",
    "false" => "false",
    "finally" => "finally",
    "for" => "for \$1 in \$2\n\t\$0\nend",
    "function" => "function \$1(\$2)\n\t\$0\nend",
    "global" => "global ",
    "if" => "if \$1\n\t\$0\nend",
    "import" => "import",
    "let" => "let \$1\n\t\$0\nend",
    "local" => "local ",
    "macro" => "macro \$1(\$2)\n\t\$0\nend",
    "module" => "module \$1\n\t\$0\nend",
    "mutable" => "mutable struct \$0\nend",
    "outer" => "outer ",
    "primitive" => "primitive type \$1 \$0 end",
    "quote" => "quote\n\t\$0\nend",
    "return" => "return",
    "struct" => "struct \$0 end",
    "true" => "true",
    "try" => "try\n\t\$0\ncatch\nend",
    "using" => "using ",
    "while" => "while \$1\n\t\$0\nend",
)

function _kw_completion(partial::String, state::_CompletionState)
    length(partial) == 0 && return
    for (kw, comp) in _snippet_completions
        if startswith(kw, partial)
            kind = occursin("\$0", comp) ? CompletionKinds.Snippet : CompletionKinds.Keyword
            _add_completion_item(state, CompletionResultItem(
                kw, kind, nothing, nothing,
                _texteditfor(state, partial, comp);
                insert_text_format=InsertFormats.Snippet))
        end
    end
end

# ============================================================================
# String / path completions
# ============================================================================

function _string_completion(t, state::_CompletionState)
    _path_completion(t, state)
    if t.kind in (CSTParser.Tokenize.Tokens.STRING, CSTParser.Tokenize.Tokens.CMD)
        t.startbyte + 1 < state.offset <= t.endbyte || return
        relative_offset = state.offset - t.startbyte - 1
        content = t.val[2:prevind(t.val, lastindex(t.val))]
    else
        t.startbyte + 3 < state.offset <= t.endbyte - 2 || return
        relative_offset = state.offset - t.startbyte - 3
        content = t.val[4:prevind(t.val, lastindex(t.val), 3)]
    end
    relative_offset = clamp(relative_offset, firstindex(content), lastindex(content))
    partial = _is_latex_comp(content, relative_offset)
    !isempty(partial) && _latex_completions(partial, state)
end

function _path_completion(t, state::_CompletionState)
    if t.kind == CSTParser.Tokenize.Tokens.STRING
        path = t.val[2:prevind(t.val, lastindex(t.val))]
        if startswith(path, "~")
            path = replace(path, '~' => homedir())
            dir, partial = splitdir(path)
        else
            dir, partial = splitdir(path)
            if !startswith(dir, "/")
                doc_path = something(uri2filepath(state.uri), "")
                isempty(doc_path) && return
                dir = joinpath(dirname(doc_path), dir)
            end
        end
        try
            fs = readdir(dir)
            for f in fs
                if startswith(f, partial)
                    try
                        if isdir(joinpath(dir, f))
                            f = string(f, "/")
                        end
                        edit = CompletionEdit(position_at(state.st, state.offset - sizeof(partial) + 1), position_at(state.st, state.offset + 1), f, nothing)
                        _add_completion_item(state, CompletionResultItem(
                            f, CompletionKinds.File, f, nothing, edit))
                    catch err
                        isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
                    end
                end
            end
        catch err
            isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
        end
    end
end

# ============================================================================
# Import completions
# ============================================================================

_is_in_import_statement(x::CSTParser.EXPR) = _is_in_fexpr(x, x -> CSTParser.headof(x) in (:using, :import))

function _current_module_expr(x)::Union{CSTParser.EXPR,Nothing}
    y = x
    while y isa CSTParser.EXPR
        CSTParser.defines_module(y) && return y
        y = CSTParser.parentof(y)
    end
    return nothing
end

function _module_ancestor_expr(modexpr::Union{CSTParser.EXPR,Nothing}, n::Int)
    n <= 0 && return modexpr
    y = modexpr
    while n > 0 && y isa CSTParser.EXPR
        z = CSTParser.parentof(y)
        while z isa CSTParser.EXPR && !CSTParser.defines_module(z)
            z = CSTParser.parentof(z)
        end
        y = z
        n -= 1
    end
    return y
end

function _relative_dot_depth_at(s::AbstractString, offset::Int)
    k = offset + 1  # 1-based
    while k > firstindex(s)
        p = prevind(s, k)
        c = s[p]
        if c == ' ' || c == '\t' || c == '\r' || c == '\n'
            k = p
        else
            break
        end
    end
    k == firstindex(s) && return 0
    p = prevind(s, k)
    c = s[p]

    if c == '.'
        cnt = 0
        q = p
        while q >= firstindex(s) && s[q] == '.'
            cnt += 1
            q = prevind(s, q)
        end
        if q >= firstindex(s) && Base.is_id_char(s[q])
            return 0
        end
        return cnt
    end

    if Base.is_id_char(c)
        j = p
        while j > firstindex(s) && Base.is_id_char(s[j])
            j = prevind(s, j)
        end
        j > firstindex(s) || return 0
        if s[j] == '.'
            cnt = 0
            q = j
            while q >= firstindex(s) && s[q] == '.'
                cnt += 1
                q = prevind(s, q)
            end
            if q >= firstindex(s) && Base.is_id_char(s[q])
                return 0
            end
            return cnt
        end
    end

    return 0
end

function _child_module_names(x::CSTParser.EXPR)
    names = String[]
    if CSTParser.defines_module(x)
        b = length(x.args) >= 3 ? x.args[3] : nothing
        if b isa CSTParser.EXPR && CSTParser.headof(b) === :block && b.args !== nothing
            for a in b.args
                if a isa CSTParser.EXPR && CSTParser.defines_module(a)
                    n = CSTParser.isidentifier(a.args[2]) ? CSTParser.valof(a.args[2]) : String(CSTParser.to_codeobject(a.args[2]))
                    push!(names, String(n))
                end
            end
        end
    elseif CSTParser.headof(x) === :file && x.args !== nothing
        for a in x.args
            if a isa CSTParser.EXPR && CSTParser.defines_module(a)
                n = CSTParser.isidentifier(a.args[2]) ? CSTParser.valof(a.args[2]) : String(CSTParser.to_codeobject(a.args[2]))
                push!(names, String(n))
            end
        end
    end
    return names
end

function _get_import_root(x::CSTParser.EXPR)
    if CSTParser.isoperator(CSTParser.headof(x.args[1])) && CSTParser.valof(CSTParser.headof(x.args[1])) == ":"
        return last(x.args[1].args[1].args)
    end
    return nothing
end

function _import_completions(ppt, pt, t, is_at_end, x, state::_CompletionState)
    # 1) Relative import completions
    depth = _relative_dot_depth_at(state.st.content, state.offset)
    if depth > 0
        x0 = x isa CSTParser.EXPR ? x : _get_expr(state.cst, state.offset, 0, true)
        cur_modexpr = x0 isa CSTParser.EXPR ? _current_module_expr(x0) : nothing
        target_modexpr = cur_modexpr === nothing ? nothing : _module_ancestor_expr(cur_modexpr, depth - 1)
        names = if target_modexpr isa CSTParser.EXPR
            _child_module_names(target_modexpr)
        elseif cur_modexpr === nothing && depth == 1
            _child_module_names(state.cst)
        else
            String[]
        end
        if !isempty(names)
            partial = (t.kind == CSTParser.Tokenize.Tokens.IDENTIFIER && is_at_end) ? t.val : ""
            for n in names
                if isempty(partial) || startswith(n, partial)
                    _add_completion_item(state, CompletionResultItem(
                        n, CompletionKinds.Module, nothing, n,
                        _texteditfor(state, partial, n)))
                end
            end
        end
        return
    end

    # 2) Non-relative path
    import_statement = x isa CSTParser.EXPR ? StaticLint.get_parent_fexpr(x, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import) : nothing
    import_root = import_statement isa CSTParser.EXPR ? _get_import_root(import_statement) : nothing
    symbols = _getsymbols(state)

    if (t.kind == Tokens.WHITESPACE && pt.kind in (Tokens.USING, Tokens.IMPORT, Tokens.IMPORTALL, Tokens.COMMA, Tokens.COLON)) ||
        (t.kind in (Tokens.COMMA, Tokens.COLON))
        if import_root !== nothing && StaticLint.refof(import_root, state.meta_dict) isa SymbolServer.ModuleStore
            for (n, m) in StaticLint.refof(import_root, state.meta_dict).vals
                n = String(n)
                if is_completion_match(n, t.val) && !startswith(n, "#")
                    _add_completion_item(state, CompletionResultItem(
                        n, _completion_kind(m),
                        _completion_details_description(m),
                        m isa SymbolServer.SymStore ? _sanitize_docstring(m.doc) : n,
                        _texteditfor(state, t.val, n)))
                end
            end
        else
            for (n, m) in symbols
                n = String(n)
                (startswith(n, ".") || startswith(n, "#")) && continue
                _add_completion_item(state, CompletionResultItem(
                    n, CompletionKinds.Module,
                    _completion_details_description(m),
                    _sanitize_docstring(m.doc),
                    CompletionEdit(position_at(state.st, state.start_offset + 1), position_at(state.st, state.end_offset + 1), n, nothing)))
            end
        end
    elseif t.kind == Tokens.DOT && pt.kind == Tokens.IDENTIFIER
        if haskey(symbols, Symbol(pt.val))
            _collect_completions(symbols[Symbol(pt.val)], "", state)
        end
    elseif t.kind == Tokens.IDENTIFIER && is_at_end
        if pt.kind == Tokens.DOT && ppt.kind == Tokens.IDENTIFIER
            if haskey(symbols, Symbol(ppt.val))
                rootmod = symbols[Symbol(ppt.val)]
                for (n, m) in rootmod.vals
                    n = String(n)
                    if is_completion_match(n, t.val) && !startswith(n, "#")
                        _add_completion_item(state, CompletionResultItem(
                            n, _completion_kind(m),
                            _completion_details_description(m),
                            m isa SymbolServer.SymStore ? _sanitize_docstring(m.doc) : n,
                            _texteditfor(state, t.val, n)))
                    end
                end
            end
        else
            if import_root !== nothing && StaticLint.refof(import_root, state.meta_dict) isa SymbolServer.ModuleStore
                for (n, m) in StaticLint.refof(import_root, state.meta_dict).vals
                    n = String(n)
                    if is_completion_match(n, t.val) && !startswith(n, "#")
                        _add_completion_item(state, CompletionResultItem(
                            n, _completion_kind(m),
                            _completion_details_description(m),
                            m isa SymbolServer.SymStore ? _sanitize_docstring(m.doc) : n,
                            _texteditfor(state, t.val, n)))
                    end
                end
            else
                for (n, m) in symbols
                    n = String(n)
                    if is_completion_match(n, t.val)
                        _add_completion_item(state, CompletionResultItem(
                            n, CompletionKinds.Module,
                            _completion_details_description(m),
                            m isa SymbolServer.SymStore ? m.doc : n,
                            _texteditfor(state, t.val, n)))
                    end
                end
            end
        end
    end
end

# ============================================================================
# Dot (getfield) completions
# ============================================================================

function _is_rebinding_of_module(x, meta_dict)
    x isa CSTParser.EXPR &&
    StaticLint.refof(x, meta_dict) isa StaticLint.Binding &&
    StaticLint.refof(x, meta_dict).type === StaticLint.CoreTypes.Module &&
    StaticLint.refof(x, meta_dict).val isa CSTParser.EXPR && CSTParser.isassignment(StaticLint.refof(x, meta_dict).val) &&
    StaticLint.hasref(StaticLint.refof(x, meta_dict).val.args[2], meta_dict) &&
    StaticLint.refof(StaticLint.refof(x, meta_dict).val.args[2], meta_dict).type === StaticLint.CoreTypes.Module &&
    StaticLint.refof(StaticLint.refof(x, meta_dict).val.args[2], meta_dict).val isa CSTParser.EXPR &&
    CSTParser.defines_module(StaticLint.refof(StaticLint.refof(x, meta_dict).val.args[2], meta_dict).val)
end

function _get_dot_completion(px, spartial, state::_CompletionState) end
function _get_dot_completion(px::CSTParser.EXPR, spartial, state::_CompletionState)
    px === nothing && return
    r = StaticLint.refof(px, state.meta_dict)
    if r isa StaticLint.Binding
        if r.val isa SymbolServer.ModuleStore
            _collect_completions(r.val, spartial, state, true)
        elseif r.val isa CSTParser.EXPR && CSTParser.defines_module(r.val) && StaticLint.scopeof(r.val, state.meta_dict) isa StaticLint.Scope
            _collect_completions(StaticLint.scopeof(r.val, state.meta_dict), spartial, state, true)
        elseif _is_rebinding_of_module(px, state.meta_dict)
            _collect_completions(StaticLint.scopeof(StaticLint.refof(r.val.args[2], state.meta_dict).val, state.meta_dict), spartial, state, true)
        elseif r.type isa SymbolServer.DataTypeStore
            for a in r.type.fieldnames
                a = String(a)
                if is_completion_match(a, spartial)
                    _add_completion_item(state, CompletionResultItem(
                        a, CompletionKinds.Field, nothing, a,
                        _texteditfor(state, spartial, a)))
                end
            end
        elseif r.type isa StaticLint.Binding && r.type.val isa SymbolServer.DataTypeStore
            for a in r.type.val.fieldnames
                a = String(a)
                if is_completion_match(a, spartial)
                    _add_completion_item(state, CompletionResultItem(
                        a, CompletionKinds.Field, nothing, a,
                        _texteditfor(state, spartial, a)))
                end
            end
        elseif r.type isa StaticLint.Binding && r.type.val isa CSTParser.EXPR && CSTParser.defines_struct(r.type.val) && StaticLint.scopeof(r.type.val, state.meta_dict) isa StaticLint.Scope
            _collect_completions(StaticLint.scopeof(r.type.val, state.meta_dict), spartial, state, true)
        end
    elseif r isa SymbolServer.ModuleStore
        _collect_completions(r, spartial, state, true)
    end
end

# ============================================================================
# Symbol collection (three overloads)
# ============================================================================

function _collect_completions(m::SymbolServer.ModuleStore, spartial, state::_CompletionState, inclexported=false, dotcomps=false)
    possible_names = String[]
    symbols = _getsymbols(state)
    for val in m.vals
        n, v = String(val[1]), val[2]
        (startswith(n, ".") || startswith(n, "#")) && continue
        canonical_name = n
        resize!(possible_names, 0)
        if is_completion_match(n, spartial)
            push!(possible_names, n)
        end
        if (nn = _string_macro_altname(n); nn !== nothing) && is_completion_match(nn, spartial)
            push!(possible_names, nn)
        end
        length(possible_names) == 0 && continue
        if v isa SymbolServer.VarRef
            v = SymbolServer._lookup(v, symbols, true)
            v === nothing && return
        end
        if StaticLint.isexportedby(canonical_name, m) || inclexported
            foreach(possible_names) do n
                _add_completion_item(state, CompletionResultItem(
                    n, _completion_kind(v),
                    _completion_details_description(v),
                    v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                    _texteditfor(state, spartial, n)))
            end
        elseif dotcomps
            foreach(possible_names) do n
                _add_completion_item(state, CompletionResultItem(
                    n, _completion_kind(v),
                    _completion_details_description(v),
                    v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                    _texteditfor(state, spartial, string(m.name, ".", n))))
            end
        elseif length(spartial) > 3 && !_variable_already_imported(m, canonical_name, state)
            if state.completion_mode === :import
                foreach(possible_names) do n
                    _add_completion_item(state, CompletionResultItem(
                        n, _completion_kind(v), nothing,
                        "This is an unexported symbol and will be explicitly imported.",
                        _texteditfor(state, spartial, n);
                        detail_description = v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                        insert_text_format=InsertFormats.PlainText,
                        additional_edits=_textedit_to_insert_using_stmt(m, canonical_name, state),
                        data="import"))
                end
            elseif state.completion_mode === :qualify
                foreach(possible_names) do n
                    _add_completion_item(state, CompletionResultItem(
                        string(m.name, ".", n), _completion_kind(v), nothing,
                        v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                        _texteditfor(state, spartial, string(m.name, ".", n));
                        filter_text=string(n),
                        insert_text_format=InsertFormats.PlainText))
                end
            end
        end
    end
end

function _variable_already_imported(m, n, state)
    haskey(state.using_stmts, String(m.name.name)) && _import_has_x(state.using_stmts[String(m.name.name)][1], n)
end

function _import_has_x(expr::CSTParser.EXPR, x::String)
    if length(expr.args) == 1 && length(expr.args[1]) > 1
        for i = 2:length(expr.args[1].args)
            arg = expr.args[1].args[i]
            if CSTParser.isoperator(arg.head) && length(arg.args) == 1 && CSTParser.isidentifier(arg.args[1]) && CSTParser.valof(arg.args[1]) == x
                return true
            end
        end
    end
    return false
end

function _collect_completions(x::CSTParser.EXPR, spartial, state::_CompletionState, inclexported=false, dotcomps=false)
    if StaticLint.scopeof(x, state.meta_dict) !== nothing
        _collect_completions(StaticLint.scopeof(x, state.meta_dict), spartial, state, inclexported, dotcomps)
        if StaticLint.scopeof(x, state.meta_dict).modules isa Dict
            for m in StaticLint.scopeof(x, state.meta_dict).modules
                _collect_completions(m[2], spartial, state, inclexported, dotcomps)
            end
        end
    end
    if CSTParser.parentof(x) !== nothing && !CSTParser.defines_module(x)
        return _collect_completions(CSTParser.parentof(x), spartial, state, inclexported, dotcomps)
    end
end

function _collect_completions(x::StaticLint.Scope, spartial, state::_CompletionState, inclexported=false, dotcomps=false)
    if x.names !== nothing
        possible_names = String[]
        for n in x.names
            resize!(possible_names, 0)
            if is_completion_match(n[1], spartial) && n[1] != spartial
                push!(possible_names, n[1])
            end
            if (nn = _string_macro_altname(n[1]); nn !== nothing) && is_completion_match(nn, spartial)
                push!(possible_names, nn)
            end
            if length(possible_names) > 0
                documentation = ""
                b = n[2]
                if b isa StaticLint.Binding
                    documentation = _get_tooltip(b, documentation, state.meta_dict)
                    documentation = _sanitize_docstring(documentation)
                end
                foreach(possible_names) do nn
                    _add_completion_item(state, CompletionResultItem(
                        nn, _completion_kind(b),
                        _completion_details_description(b),
                        isempty(documentation) ? nothing : documentation,
                        _texteditfor(state, spartial, nn);
                        detail_label=_completion_details_label(b)))
                end
            end
        end
    end
end

# ============================================================================
# Using statement insertion helpers
# ============================================================================

function _get_file_level_parent(x::CSTParser.EXPR)
    if x.parent isa CSTParser.EXPR && x.parent.head === :file
        x
    else
        x.parent === nothing && return nothing
        _get_file_level_parent(x.parent)
    end
end

function _get_tls_arglist(tls::StaticLint.Scope)
    if tls.expr.head === :file
        tls.expr.args
    elseif tls.expr.head === :module
        tls.expr.args[3].args
    else
        error()
    end
end

function _get_preexisting_using_stmts(x::CSTParser.EXPR, cst::CSTParser.EXPR, meta_dict, workspace)
    using_stmts = Dict{String,Any}()
    tls = _retrieve_toplevel_scope(x, meta_dict)
    file_level_arg = _get_file_level_parent(x)

    if StaticLint.scopeof(cst, meta_dict) == tls
        for a in cst.args
            if CSTParser.headof(a) === :using
                _add_using_stmt(a, using_stmts, workspace)
            end
            a == file_level_arg && break
        end
    end

    if tls !== nothing
        args = _get_tls_arglist(tls)
        for a in args
            if CSTParser.headof(a) === :using
                _add_using_stmt(a, using_stmts, workspace)
            end
        end
    end
    return using_stmts
end

function _add_using_stmt(x::CSTParser.EXPR, using_stmts, workspace)
    if length(x.args) > 0 && CSTParser.is_colon(x.args[1].head)
        if CSTParser.is_dot(x.args[1].args[1].head) && length(x.args[1].args[1].args) == 1
            loc = get_expr_location(workspace, x)
            if loc !== nothing
                using_stmts[CSTParser.valof(x.args[1].args[1].args[1])] = (x, (loc.uri, loc.offset))
            end
        end
    end
end

function _textedit_to_insert_using_stmt(m::SymbolServer.ModuleStore, n::String, state::_CompletionState)
    _pos_for(uri, offset) = if uri === nothing
        position_at(state.st, offset + 1)
    else
        _offset_to_position(state.workspace.runtime, uri, offset)
    end

    tls = _retrieve_toplevel_scope(state.x, state.meta_dict)
    if haskey(state.using_stmts, String(m.name.name))
        (using_stmt, (uri, using_offset)) = state.using_stmts[String(m.name.name)]
        insert_offset = using_offset + using_stmt.span
        p = _pos_for(uri, insert_offset)
        return [CompletionEdit(p, p, ", $n", uri)]
    elseif tls !== nothing
        if tls.expr.head === :file
            p = Position(1, 1)
            return [CompletionEdit(p, p, "using $(m.name): $(n)\n", nothing)]
        elseif tls.expr.head === :module
            tls_loc = get_expr_location(state.workspace, tls.expr)
            if tls_loc !== nothing
                offset2 = tls.expr.trivia[1].fullspan + tls.expr.args[2].fullspan
                insert_offset = tls_loc.offset + offset2
                p = _pos_for(tls_loc.uri, insert_offset)
                return [CompletionEdit(p, p, "using $(m.name): $(n)\n", tls_loc.uri)]
            else
                p = Position(1, 1)
                return [CompletionEdit(p, p, "using $(m.name): $(n)\n", nothing)]
            end
        else
            error()
        end
    else
        p = Position(1, 1)
        return [CompletionEdit(p, p, "using $(m.name): $(n)\n", nothing)]
    end
end

# ============================================================================
# Top-level completion entry point (internal)
# ============================================================================

function _get_completions(rt, uri, offset, completion_mode, workspace)
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst === nothing && return CompletionResult(true, CompletionResultItem[])

    text_file = input_text_file(rt, uri)
    st = text_file.content

    root = derived_best_root_for_uri(rt, uri)
    if root !== nothing
        project_uri = derived_project_uri_for_root(rt, root)
        if project_uri !== nothing
            lint_result = derived_static_lint_meta_for_root(rt, root)
            meta_dict = lint_result.meta_dict
            env = derived_environment(rt, project_uri)
        else
            meta_dict = _empty_hover_meta_dict
            env = _empty_hover_env
        end
    else
        meta_dict = _empty_hover_meta_dict
        env = _empty_hover_env
    end

    x = _get_expr(cst, offset)
    using_stmts = if completion_mode == :import
        !isnothing(x) ? _get_preexisting_using_stmts(x, cst, meta_dict, workspace) : Dict{String, Any}()
    else
        Dict{String,Any}()
    end

    state = _CompletionState(
        offset,
        Dict{String,CompletionResultItem}(),
        offset, offset,   # start_offset, end_offset (cursor position)
        x, cst, uri, st, meta_dict, env,
        completion_mode, using_stmts, workspace
    )

    ppt, pt, t = _get_toks(st.content, offset)
    is_at_end = offset == t.endbyte + 1

    # Update start/end offsets based on cursor position for replacement range
    # We use an immutable struct, so we track this externally in the "partial" length
    # that _texteditfor uses.

    if pt isa CSTParser.Tokens.Token && pt.kind == CSTParser.Tokenize.Tokens.BACKSLASH
        _latex_completions(string("\\", CSTParser.Tokenize.untokenize(t)), state)
    elseif ppt isa CSTParser.Tokens.Token && ppt.kind == CSTParser.Tokenize.Tokens.BACKSLASH && pt isa CSTParser.Tokens.Token && (pt.kind === CSTParser.Tokens.CIRCUMFLEX_ACCENT || pt.kind === CSTParser.Tokens.COLON)
        _latex_completions(string("\\", CSTParser.Tokenize.untokenize(pt), CSTParser.Tokenize.untokenize(t)), state)
    elseif t isa CSTParser.Tokens.Token && t.kind == CSTParser.Tokenize.Tokens.COMMENT
        partial = _is_latex_comp(t.val, state.offset - t.startbyte)
        !isempty(partial) && _latex_completions(partial, state)
    elseif t isa CSTParser.Tokens.Token && (t.kind in (CSTParser.Tokenize.Tokens.STRING,
                                                       CSTParser.Tokenize.Tokens.TRIPLE_STRING,
                                                       CSTParser.Tokenize.Tokens.CMD,
                                                       CSTParser.Tokenize.Tokens.TRIPLE_CMD))
        _string_completion(t, state)
    elseif state.x isa CSTParser.EXPR && _is_in_import_statement(state.x) || _relative_dot_depth_at(st.content, offset) > 0
        _import_completions(ppt, pt, t, is_at_end, state.x, state)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.DOT && pt isa CSTParser.Tokens.Token && pt.kind == Tokens.IDENTIFIER
        px = _get_expr(cst, offset - (1 + t.endbyte - t.startbyte))
        _get_dot_completion(px, "", state)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.IDENTIFIER && pt isa CSTParser.Tokens.Token && pt.kind == Tokens.DOT && ppt isa CSTParser.Tokens.Token && ppt.kind == Tokens.IDENTIFIER
        px = _get_expr(cst, offset - (1 + t.endbyte - t.startbyte) - (1 + pt.endbyte - pt.startbyte))
        _get_dot_completion(px, t.val, state)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.IDENTIFIER
        if is_at_end && state.x !== nothing
            spartial = if pt isa CSTParser.Tokens.Token && pt.kind == Tokens.AT_SIGN
                string("@", t.val)
            else
                t.val
            end
            _kw_completion(spartial, state)
            _collect_completions(state.x, spartial, state, false)
        end
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.AT_SIGN
        state.x !== nothing && _collect_completions(state.x, "@", state, false)
    elseif t isa CSTParser.Tokens.Token && CSTParser.Tokens.iskeyword(t.kind) && is_at_end
        _kw_completion(CSTParser.Tokenize.untokenize(t), state)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.IN && is_at_end && state.x !== nothing
        _collect_completions(state.x, "in", state, false)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.ISA && is_at_end && state.x !== nothing
        _collect_completions(state.x, "isa", state, false)
    end

    return CompletionResult(true, unique(values(state.completions)))
end
