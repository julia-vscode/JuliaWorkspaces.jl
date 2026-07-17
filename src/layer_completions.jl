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
    module CompletionKinds

Named constants for completion item kinds, mirroring the LSP `CompletionItemKind`
enumeration. Used as the `kind` field of [`CompletionResultItem`](@ref JuliaWorkspaces.CompletionResultItem).
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
    module InsertFormats

Named constants for completion insert-text formats: `PlainText` (literal text)
and `Snippet` (LSP snippet syntax with placeholders). Used as the
`insert_text_format` field of [`CompletionResultItem`](@ref JuliaWorkspaces.CompletionResultItem).
"""
module InsertFormats
    const PlainText = 1
    const Snippet   = 2
end

"""
    struct CompletionEdit

A text edit attached to a completion item, expressed with [`Position`](@ref)
values rather than LSP types.

- `start::Position`: Start of the range to replace.
- `stop::Position`: End of the range to replace.
- `new_text::String`: Replacement text.
- `uri::Union{Nothing,URI}`: Target file, or `nothing` for the current file.
"""
struct CompletionEdit
    start::Position
    stop::Position
    new_text::String
    uri::Union{Nothing,URI}  # nothing means same file
end

"""
    struct CompletionResultItem

A single completion candidate, expressed without any LSP types.

- `label::String`: Text shown in the completion list.
- `kind::Int`: A [`CompletionKinds`](@ref) value.
- `detail`, `detail_label`, `detail_description`: Optional detail strings.
- `documentation::Union{Nothing,String}`: Optional markdown documentation.
- `sort_text`, `filter_text`: Optional overrides for sorting/filtering.
- `insert_text_format::Int`: An [`InsertFormats`](@ref) value.
- `text_edit::CompletionEdit`: The primary edit applied on acceptance.
- `additional_edits::Vector{CompletionEdit}`: Extra edits (for example new imports).
- `data::Union{Nothing,String}`: Opaque payload carried through to resolution.
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
    struct CompletionResult

The full result of a completion request.

- `is_incomplete::Bool`: `true` if the list is truncated and should be
  recomputed as the user keeps typing.
- `items::Vector{CompletionResultItem}`: The completion candidates.
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
    rt         # Salsa runtime (nothing in isolated unit tests)
    root::Union{Nothing,URI}                   # best root for `uri`
    module_path::Union{Nothing,Vector{String}} # module path the file splices into
    item_meta::Dict{String,Tuple{String,Int}}  # label => (query, priority), for ranking
end

"""
    _add_completion_item(state, item, query="", priority=_PRIO_STORE)

Record a completion candidate. `query` is the text the item was matched against
and `priority` its source rank; both feed the relevance sort in
[`_finalize_completions`](@ref).
"""
function _add_completion_item(state::_CompletionState, item::CompletionResultItem, query::AbstractString="", priority::Int=_PRIO_STORE)
    if haskey(state.completions, item.label) && state.completions[item.label].data === nothing
        return
    end
    state.completions[item.label] = item
    state.item_meta[item.label] = (String(query), priority)
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
# Relevance ranking for server-side sorting
# ============================================================================
#
# Clients differ in how they order completion items: VS Code re-sorts by
# `sort_text` (falling back to the label) rather than trusting server order,
# while editors that do no client-side sorting at all (e.g. Helix) show items in
# whatever order the server returns. To get a good, stable order everywhere we
# compute a relevance key per item and emit a zero-padded `sort_text` reflecting
# it (see `_finalize_completions`).
#
# The key is `(match_rank, source_priority, length, label)`:
#  - `match_rank`: how well the label matches what the user typed. A
#    case-matching prefix beats a case-insensitive prefix, so all-lowercase
#    input surfaces the lowercase symbol first (e.g. `\epsi` ranks `\epsilon`
#    above `\Epsilon`) without dropping the case-mismatched candidate.
#  - `source_priority`: nearer lexical scope / more relevant source first.
#  - `length` then `label`: deterministic tie-breaking, shorter names first.

const _PRIO_FIELD       = 0     # struct fields on a `x.` access (contextual)
const _PRIO_LOCAL_BASE  = 0     # bindings in the innermost scope; + scope depth
const _PRIO_MODULE_BASE = 100   # `using`-ed modules visible in a scope; + depth
const _PRIO_STORE       = 500   # symbols pulled from a SymbolServer store
const _PRIO_KEYWORD     = 900   # language keywords / snippets

"""
    _match_rank(label, query)

Rank how well `label` matches the typed `query` (lower is better): exact match
(0), case-sensitive prefix (1), case-insensitive prefix (2), otherwise fuzzy (3).
"""
function _match_rank(label::AbstractString, query::AbstractString)
    isempty(query) && return 3
    if label == query
        return 0
    elseif startswith(label, query)
        return 1
    elseif startswith(lowercase(label), lowercase(query))
        return 2
    else
        return 3
    end
end

function _with_sort_text(item::CompletionResultItem, sort_text::String)
    return CompletionResultItem(
        item.label, item.kind, item.detail, item.detail_label,
        item.detail_description, item.documentation, sort_text, item.filter_text,
        item.insert_text_format, item.text_edit, item.additional_edits, item.data)
end

"""
    _finalize_completions(state)

Collect the accumulated completion items, sort them by relevance, and stamp each
with a zero-padded `sort_text` so the server-chosen order is respected by clients.
"""
function _finalize_completions(state)
    items = collect(values(state.completions))
    function relevance_key(item)
        query, priority = get(state.item_meta, item.label, ("", _PRIO_STORE))
        # match against filter_text when present (e.g. qualify-mode `Mod.foo`
        # items filter on the bare `foo`)
        target = item.filter_text === nothing ? item.label : item.filter_text
        return (_match_rank(target, query), priority, length(item.label), item.label)
    end
    sort!(items; by=relevance_key)
    width = max(ndigits(length(items)), 1)
    for (i, item) in enumerate(items)
        items[i] = _with_sort_text(item, lpad(i, width, '0'))
    end
    return items
end

# ============================================================================
# Completion edit helpers (1-based string indices)
# ============================================================================

function _texteditfor(state::_CompletionState, partial, new_text)
    start_off = max(state.start_offset - sizeof(partial), 0)
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
# Non-standard (`var"..."`) identifier helpers
# ============================================================================

"""
    _var_wrap(n)

Wrap a name in `var"..."` quoting. Names that can't be represented that way
(containing `"` or `\\`) are returned as is.
"""
function _var_wrap(n::AbstractString)
    if occursin('"', n) || occursin('\\', n)
        return n
    end
    return string("var\"", n, '"')
end

"""
    _var_quoted_label(n)

Return the completion label/insert text for a name `n` whose definition syntax
is unknown (e.g. field names from the symbol store): names that are not plain
valid identifiers (or that start with `@`) are wrapped in `var"..."` quoting
so that inserting them produces valid code. Use [`_name_expr_label`](@ref)
instead when the defining EXPR is available.
"""
function _var_quoted_label(n::AbstractString)
    if isempty(n) || (Base.isidentifier(n) && !startswith(n, '@'))
        return n
    end
    return _var_wrap(n)
end

"""
    _name_expr_label(x)

Label/insert text for a name written as expr `x` in the source: names defined
with `var"..."` syntax always keep their quoting, everything else stays raw
(in particular macro names). Returns `nothing` if `x` has no name.
"""
function _name_expr_label(x::CSTParser.EXPR)
    n = CSTParser.str_value(x)
    (n isa AbstractString && !isempty(n)) || return nothing
    return CSTParser.headof(x) === :NONSTDIDENTIFIER ? _var_wrap(String(n)) : String(n)
end

_binding_defined_as_var(b) =
    b isa StaticLint.Binding && b.name isa CSTParser.EXPR &&
    CSTParser.headof(b.name) === :NONSTDIDENTIFIER

"""
    _strip_var_partial(s)

Strip the `var"` prefix (and a trailing `"`, if present) from a partially typed
non-standard identifier so it can be matched against raw names: `var"he` and
`var"he"` both become `he`. Strings without the prefix are returned unchanged.
"""
function _strip_var_partial(s::AbstractString)
    startswith(s, "var\"") || return s
    stripped = chop(s, head=4, tail=0)
    endswith(stripped, '"') && (stripped = chop(stripped))
    return stripped
end

"""
    _var_string_partial(pt, t, offset, content)

If the cursor at byte `offset` is inside a string token `t` that directly
follows a `var` identifier token `pt` — i.e. a partially typed non-standard
`var"..."` identifier — return the typed text from the start of `var` up to
the cursor (e.g. `var"he`), otherwise `nothing`.
"""
function _var_string_partial(pt, t, offset, content)
    (t isa CSTParser.Tokens.Token && pt isa CSTParser.Tokens.Token) || return nothing
    (pt.kind == Tokens.IDENTIFIER && pt.val == "var") || return nothing
    pt.endbyte + 1 == t.startbyte || return nothing
    if t.kind == Tokens.STRING
        t.startbyte < offset <= t.endbyte + 1 || return nothing
    elseif t.kind == Tokens.ERROR && t.token_error == Tokens.EOF_STRING
        t.startbyte < offset || return nothing
    else
        return nothing
    end
    return content[pt.startbyte+1:offset]
end

# ============================================================================
# LaTeX / emoji completions
# ============================================================================

function _latex_completions(partial::String, state::_CompletionState)
    for (k, v) in Iterators.flatten((REPL.REPLCompletions.latex_symbols, REPL.REPLCompletions.emoji_symbols))
        if is_completion_match(string(k), partial)
            _add_completion_item(state, CompletionResultItem(
                k, CompletionKinds.Unit, nothing, v,
                _texteditfor(state, partial, v)), partial, _PRIO_STORE)
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
                insert_text_format=InsertFormats.Snippet), partial, _PRIO_KEYWORD)
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
                            f, CompletionKinds.File, f, nothing, edit), partial, _PRIO_STORE)
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

function _module_name_label(name::CSTParser.EXPR)
    if CSTParser.isidentifier(name)
        # var"..." module names keep their quoting so inserting them produces
        # valid code
        _name_expr_label(name)
    else
        String(CSTParser.to_codeobject(name))
    end
end

function _child_module_names(x::CSTParser.EXPR)
    names = String[]
    if CSTParser.defines_module(x)
        b = length(x.args) >= 3 ? x.args[3] : nothing
        if b isa CSTParser.EXPR && CSTParser.headof(b) === :block && b.args !== nothing
            for a in b.args
                if a isa CSTParser.EXPR && CSTParser.defines_module(a)
                    n = _module_name_label(a.args[2])
                    n !== nothing && push!(names, n)
                end
            end
        end
    elseif CSTParser.headof(x) === :file && x.args !== nothing
        for a in x.args
            if a isa CSTParser.EXPR && CSTParser.defines_module(a)
                n = _module_name_label(a.args[2])
                n !== nothing && push!(names, n)
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

# The member source the import path's root component resolved to, from the
# per-file meta: a `SymbolServer.ModuleStore` for env-backed modules
# (directly, or through the plain-data `TreeRef` stand-ins the per-file meta
# stores post-strip), or a `(root, path)` tuple for a module of a workspace
# tree. `nothing` when the component is unresolved.
function _import_root_member_source(state::_CompletionState, import_root)
    import_root === nothing && return nothing
    r = StaticLint.refof(import_root, state.meta_dict)
    r isa StaticLint.Binding && (r = r.val)
    if r isa SymbolServer.ModuleStore
        return r
    elseif r isa StaticLint.TreeRef
        (state.rt === nothing || state.root === nothing) && return nothing
        rt = state.rt
        if r.kind === :module
            return _tree_module_target(rt, state.root, r)
        elseif r.kind === :external_module
            return _resolve_external_module(rt, state.root, vcat(r.origin_module, [r.name]))
        elseif r.kind === :external_symbol && !isempty(r.origin_module)
            p = r.name == r.origin_module[end] ? r.origin_module : vcat(r.origin_module, [r.name])
            return _resolve_external_module(rt, state.root, p)
        end
    end
    return nothing
end

# Member completions for `using`/`import X: <partial>` against the resolved
# member source (see `_import_root_member_source`).
function _import_member_completions(src, partial, state::_CompletionState)
    if src isa SymbolServer.ModuleStore
        for (n, m) in src.vals
            n = String(n)
            if is_completion_match(n, partial) && !startswith(n, "#")
                _add_completion_item(state, CompletionResultItem(
                    n, _completion_kind(m),
                    _completion_details_description(m),
                    m isa SymbolServer.SymStore ? _sanitize_docstring(m.doc) : n,
                    _texteditfor(state, partial, n)), partial, _PRIO_STORE)
            end
        end
    else
        troot, tpath = src
        _visibility_member_completions(state.rt, troot, tpath, partial, state; priority=_PRIO_STORE)
    end
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
                        _texteditfor(state, partial, n)), partial, _PRIO_MODULE_BASE)
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
        member_source = _import_root_member_source(state, import_root)
        if member_source !== nothing
            _import_member_completions(member_source, t.val, state)
        else
            for (n, m) in symbols
                n = String(n)
                (startswith(n, ".") || startswith(n, "#")) && continue
                _add_completion_item(state, CompletionResultItem(
                    n, CompletionKinds.Module,
                    _completion_details_description(m),
                    _sanitize_docstring(m.doc),
                    CompletionEdit(position_at(state.st, state.start_offset + 1), position_at(state.st, state.end_offset + 1), n, nothing)), "", _PRIO_MODULE_BASE)
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
                            _texteditfor(state, t.val, n)), t.val, _PRIO_STORE)
                    end
                end
            end
        else
            member_source = _import_root_member_source(state, import_root)
            if member_source !== nothing
                _import_member_completions(member_source, t.val, state)
            else
                for (n, m) in symbols
                    n = String(n)
                    if is_completion_match(n, t.val)
                        _add_completion_item(state, CompletionResultItem(
                            n, CompletionKinds.Module,
                            _completion_details_description(m),
                            m isa SymbolServer.SymStore ? m.doc : n,
                            _texteditfor(state, t.val, n)), t.val, _PRIO_MODULE_BASE)
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

# Field `(name, label)`s of a workspace struct definition, mirroring the
# field-marking logic in `mark_bindings!`: skips inner constructors, unwraps
# `const` and @kwdef defaults. The label carries the var"..." quoting for
# fields defined with non-standard names.
function _struct_field_names(x::CSTParser.EXPR)
    names = Tuple{String,String}[]
    for arg in x.args[3].args
        CSTParser.defines_function(arg) && continue
        if CSTParser.headof(arg) === :const
            arg = arg.args[1]
        end
        if CSTParser.isassignment(arg)
            arg = arg.args[1]
        end
        if CSTParser.isdeclaration(arg)
            arg = arg.args[1]
        end
        if CSTParser.isidentifier(arg)
            # str_value also covers var"..." fields, where valof is nothing
            n = CSTParser.str_value(arg)
            label = _name_expr_label(arg)
            if n isa AbstractString && !isempty(n) && label !== nothing
                push!(names, (String(n), label))
            end
        end
    end
    return names
end

"""
    _add_field_completion(state, spartial, name, label=_var_quoted_label(name))

Add a field completion for `name`, inserted as `label` (its var"..."-quoted
form where required). `spartial` is matched against both the raw name and the
label, so `foo.he` and `foo.var"he` both complete to `foo.var"hello world"`.
"""
function _add_field_completion(state::_CompletionState, spartial, name::String, label::String=_var_quoted_label(name))
    if is_completion_match(name, _strip_var_partial(spartial)) ||
        (label != name && is_completion_match(label, spartial))
        _add_completion_item(state, CompletionResultItem(
            label, CompletionKinds.Field, nothing, name,
            _texteditfor(state, spartial, label)), spartial, _PRIO_FIELD)
    end
end

# ----------------------------------------------------------------------------
# Module-tree visibility bridge (per-file meta)
#
# The per-file analysis meta (`derived_file_analysis(...).meta`) carries only
# THIS file's scopes — module contexts are stripped, so the scope-chain walk
# no longer reaches module-level names from sibling files or `using`/`import`
# bring-ins. The helpers below bridge that gap from the visibility layer
# (`derived_module_visible_names`) and resolve the plain-data
# `StaticLint.TreeRef` stand-ins the per-file meta stores for names resolved
# through the module tree or the environment.
# ----------------------------------------------------------------------------

# CompletionKinds value for an inventory/visibility item kind.
function _completion_kind_for_visible(kind::Symbol)
    if kind === :module
        return CompletionKinds.Module
    elseif kind in (:struct, :mutable_struct, :abstract, :primitive, :enum)
        return CompletionKinds.Struct
    elseif kind in (:function, :macro)
        return CompletionKinds.Method
    else
        return CompletionKinds.Variable
    end
end

# Label/insert text for a name coming from the inventory layers (raw strings,
# macros stored WITH their `@`): macro names stay raw, other non-identifier
# names get var"..." quoting so inserting them produces valid code.
function _tree_name_label(n::AbstractString)
    if startswith(n, "@")
        tail = SubString(n, nextind(n, firstindex(n)))
        return (!isempty(tail) && Base.isidentifier(tail)) ? String(n) : _var_wrap(n)
    end
    return _var_quoted_label(n)
end

# The (root, path) of the module a module-kinded `TreeRef` denotes: the same
# two-candidate `origin_module` validation as `module_context_at`
# (extended path first), then cross-root as a workspace package
# (mirroring `_workspace_package_context`). `nothing` when the ref denotes no
# known module.
function _tree_module_target(rt, root, tr::StaticLint.TreeRef)
    extended = vcat(tr.origin_module, [tr.name])
    derived_module_exists(rt, root, extended) && return (root, extended)
    if !isempty(tr.origin_module) && derived_module_exists(rt, root, tr.origin_module)
        return (root, tr.origin_module)
    end
    roots = derived_workspace_package_roots(rt)
    for cand in (extended, tr.origin_module)
        isempty(cand) && continue
        entry = get(roots, cand[1], nothing)
        entry === nothing && continue
        derived_module_exists(rt, entry, cand) && return (entry, cand)
    end
    return nothing
end

# Add one visibility-dict entry as a completion item. For `:external_symbol`
# names the member store is looked up in the origin module's env store (via
# `store_cache`, one resolution per origin path) so kind/docs match what the
# old store-backed path produced.
function _add_visible_name_completion(state::_CompletionState, rt, root, name::String, vn, spartial, priority::Int, store_cache)
    label = _tree_name_label(name)
    stripped_partial = _strip_var_partial(spartial)
    possible_names = String[]
    if (is_completion_match(name, stripped_partial) ||
        (label != name && is_completion_match(label, spartial))) && label != spartial
        push!(possible_names, label)
    end
    if (nn = _string_macro_altname(name); nn !== nothing) && is_completion_match(nn, spartial)
        push!(possible_names, nn)
    end
    isempty(possible_names) && return

    kind = _completion_kind_for_visible(vn.kind)
    detail = nothing
    documentation = nothing
    if vn.kind === :external_symbol
        store = get!(store_cache, vn.origin_module) do
            _resolve_external_module(rt, root, vn.origin_module)
        end
        val = store isa SymbolServer.ModuleStore ? get(store.vals, Symbol(name), nothing) : nothing
        if val isa SymbolServer.VarRef
            val = SymbolServer._lookup(val, _getsymbols(state), true)
        end
        if val !== nothing
            kind = _completion_kind(val)
            detail = _completion_details_description(val)
            documentation = val isa SymbolServer.SymStore ? _sanitize_docstring(val.doc) : nothing
        end
    elseif vn.item !== nothing
        # A tree-declared name: attach its defining-file docstring UPFRONT
        # (the LS has no `completionItem/resolve` handler, so lazy resolution
        # is not an option). Request-time via `item_documentation` — the
        # docstring lives outside the inventory, so this reads the volatile
        # `derived_item_positions` leaf of the DECLARING file (memoized; a
        # per-keystroke edit in the current file leaves sibling positions
        # cached).
        doc = item_documentation(rt, vn.item)
        doc === nothing || (documentation = _sanitize_docstring(doc))
    end
    foreach(possible_names) do nn
        _add_completion_item(state, CompletionResultItem(
            nn, kind, detail, documentation,
            _texteditfor(state, spartial, nn)), spartial, priority)
    end
end

# All names visible in module `tpath` of `troot`'s tree, as completion items.
# Used for dot-completion on tree-module refs and for member completions in
# import statements. NO export gating: the old whole-closure behavior
# (probe-verified) offered ALL names of a workspace module's scope, and
# `Mod.name` access works for any name resolvable inside `Mod`.
function _visibility_member_completions(rt, troot, tpath::Vector{String}, spartial, state::_CompletionState; priority::Int=_PRIO_LOCAL_BASE)
    visible = derived_module_visible_names(rt, troot, tpath)
    store_cache = Dict{Vector{String},Any}()
    for (name, vn) in visible
        _add_visible_name_completion(state, rt, troot, name, vn, spartial, priority, store_cache)
    end
end

# Names spliced into an IN-FILE module from elsewhere (includes inside the
# module, `using`/`import` bring-ins): merged from the visibility dict on top
# of the module's own (file-local) scope names.
function _merge_infile_module_visibility(modexpr::CSTParser.EXPR, spartial, state::_CompletionState)
    (state.rt === nothing || state.root === nothing || state.module_path === nothing) && return
    names = _in_file_module_names(modexpr, state.meta_dict)
    isempty(names) && return
    _visibility_member_completions(state.rt, state.root, vcat(state.module_path, names), spartial, state)
end

# The module-level completion append for the unqualified scope-chain walk:
# names from the visibility dict of the module the cursor's position splices
# into (rule 1), plus Base/Core exported names from the env stores (the old
# pass read them from the seeded `scope.modules`; the per-file meta has them
# stripped), plus the stores of `using`-ed external modules (for the
# unexported-name completions of `:import`/`:qualify` modes). File-local
# bindings shadow same-named visibility entries via `_add_completion_item`'s
# label dedupe — the scope walk has already run. The enclosing module's own
# self-binding is emitted at most once for the same reason (rule 4).
function _append_module_level_completions(x::CSTParser.EXPR, spartial, state::_CompletionState; depth::Int=0)
    (state.rt === nothing || state.root === nothing || state.module_path === nothing) && return
    rt = state.rt
    root = state.root
    path = vcat(state.module_path, _in_file_module_names(x, state.meta_dict))

    visible = derived_module_visible_names(rt, root, path)
    store_cache = Dict{Vector{String},Any}()
    ext_origins = Set{Vector{String}}()
    for (name, vn) in visible
        vn.origin === :using_external && push!(ext_origins, vn.origin_module)
        # declared/import-bound names rank like the old module-scope bindings;
        # `using` bring-ins rank like the old scope.modules stores
        priority = (vn.origin === :declared || vn.origin === :import_binding) ?
            _PRIO_LOCAL_BASE + depth : _PRIO_MODULE_BASE + depth
        _add_visible_name_completion(state, rt, root, name, vn, spartial, priority, store_cache)
    end

    # Base/Core exported names from the env stores, as before
    symbols = _getsymbols(state)
    for mname in (:Base, :Core)
        if haskey(symbols, mname)
            _collect_completions(symbols[mname], spartial, state, false; priority=_PRIO_MODULE_BASE + depth)
        end
    end

    # `using`-ed external module stores: exported names are already covered by
    # the visibility entries above (label dedupe drops the duplicates); this
    # pass contributes the unexported names offered in `:import`/`:qualify`
    # modes, matching the old scope.modules behavior.
    for origin in ext_origins
        store = _resolve_external_module(rt, root, origin)
        store isa SymbolServer.ModuleStore || continue
        _collect_completions(store, spartial, state, false; priority=_PRIO_MODULE_BASE + depth)
    end
end

# Dot-completion through a plain-data `TreeRef` LHS (the per-file meta's
# stand-in for module/env-backed refs), mirroring
# `StaticLint.qualified_module_target`'s kind dispatch:
# - `:module` — a module of a workspace tree: enumerate its visible names.
# - `:external_module` — the env-store stand-in (post-strip `Base` etc.):
#   enumerate the store, as the old ModuleStore refs did.
# - `:external_symbol` — may denote an env module bound by a whole-module
#   `using`/`import` (self-named: the origin path IS the module path;
#   otherwise the name may extend it).
function _tree_ref_dot_completion(tr::StaticLint.TreeRef, spartial, state::_CompletionState)
    (state.rt === nothing || state.root === nothing) && return
    rt = state.rt
    if tr.kind === :module
        target = _tree_module_target(rt, state.root, tr)
        target === nothing && return
        _visibility_member_completions(rt, target[1], target[2], spartial, state)
    elseif tr.kind === :external_module
        store = _resolve_external_module(rt, state.root, vcat(tr.origin_module, [tr.name]))
        store isa SymbolServer.ModuleStore && _collect_completions(store, spartial, state, true)
    elseif tr.kind === :external_symbol && !isempty(tr.origin_module)
        path = tr.name == tr.origin_module[end] ? tr.origin_module : vcat(tr.origin_module, [tr.name])
        store = _resolve_external_module(rt, state.root, path)
        store isa SymbolServer.ModuleStore && _collect_completions(store, spartial, state, true)
    end
end

# The struct-kind `TreeRef` a binding's declared/inferred type traces to, or
# `nothing`. The per-file pass cannot carry a `TreeRef` in `Binding.type`
# (see `declared_type_is_tree_backed`), so the type is read off the binding's
# defining EXPR: a `::` annotation, a type-asserted assignment RHS, or a
# constructor-call assignment RHS whose callee resolved to a struct-kind
# `TreeRef`. Mirrors `declared_type_is_tree_backed`'s annotation unwrapping.
function _tree_struct_ref_of_binding(b::StaticLint.Binding, meta_dict)
    v = b.val
    v isa CSTParser.EXPR || return nothing
    t = nothing
    if v.head isa CSTParser.EXPR && CSTParser.valof(v.head) == "::" && v.args !== nothing && length(v.args) == 2
        t = v.args[2]
    elseif CSTParser.isassignment(v) && v.args !== nothing && length(v.args) == 2
        rhs = v.args[2]
        if rhs isa CSTParser.EXPR && rhs.head isa CSTParser.EXPR && CSTParser.valof(rhs.head) == "::" && rhs.args !== nothing && length(rhs.args) == 2
            t = rhs.args[2]
        elseif rhs isa CSTParser.EXPR && CSTParser.iscall(rhs) && rhs.args !== nothing && length(rhs.args) >= 1
            t = rhs.args[1]
        end
    end
    t === nothing && return nothing
    if CSTParser.iscurly(t) && t.args !== nothing && length(t.args) >= 1
        t = t.args[1]
    end
    if CSTParser.is_getfield_w_quotenode(t)
        t = t.args[2].args[1]
    end
    r = StaticLint.refof(t, meta_dict)
    return (r isa StaticLint.TreeRef && r.kind in (:struct, :mutable_struct)) ? r : nothing
end

# Field completions for a struct-kind `TreeRef`: the field names come from
# the declaring file's inventory item (matched on BOTH id and name — ids can
# be shared between sibling items, see `_build_kind_index`).
function _tree_struct_field_completions(tr::StaticLint.TreeRef, spartial, state::_CompletionState)
    state.rt === nothing && return
    tr.item === nothing && return
    inv = derived_file_inventory(state.rt, tr.item.file)
    for item in inv.items
        if item.id == tr.item.id && item.name == tr.name
            for f in item.field_names
                _add_field_completion(state, spartial, f)
            end
            return
        end
    end
end

function _get_dot_completion(px, spartial, state::_CompletionState) end
function _get_dot_completion(px::CSTParser.EXPR, spartial, state::_CompletionState)
    px === nothing && return
    r = StaticLint.refof(px, state.meta_dict)
    if r isa StaticLint.Binding
        if r.val isa StaticLint.TreeRef
            # import-bound module (`import .Sib`) or the stripped stand-in of
            # an env module store
            _tree_ref_dot_completion(r.val, spartial, state)
        elseif r.val isa SymbolServer.ModuleStore
            _collect_completions(r.val, spartial, state, true)
        elseif r.val isa CSTParser.EXPR && CSTParser.defines_module(r.val) && StaticLint.scopeof(r.val, state.meta_dict) isa StaticLint.Scope
            _collect_completions(StaticLint.scopeof(r.val, state.meta_dict), spartial, state, true)
            # names spliced into the in-file module from other files/imports
            _merge_infile_module_visibility(r.val, spartial, state)
        elseif _is_rebinding_of_module(px, state.meta_dict)
            modexpr = StaticLint.refof(r.val.args[2], state.meta_dict).val
            _collect_completions(StaticLint.scopeof(modexpr, state.meta_dict), spartial, state, true)
            _merge_infile_module_visibility(modexpr, spartial, state)
        elseif r.type isa SymbolServer.DataTypeStore
            for a in r.type.fieldnames
                _add_field_completion(state, spartial, String(a))
            end
        elseif r.type isa StaticLint.Binding && r.type.val isa SymbolServer.DataTypeStore
            for a in r.type.val.fieldnames
                _add_field_completion(state, spartial, String(a))
            end
        elseif r.type isa StaticLint.Binding && r.type.val isa CSTParser.EXPR && CSTParser.defines_struct(r.type.val)
            # only the fields: the struct scope also holds type params and
            # inner constructor names
            for (a, label) in _struct_field_names(r.type.val)
                _add_field_completion(state, spartial, a, label)
            end
        elseif (tsr = _tree_struct_ref_of_binding(r, state.meta_dict)) !== nothing
            # a variable whose type traces to a struct declared in another
            # file (a struct-kind TreeRef): fields from the inventory
            _tree_struct_field_completions(tsr, spartial, state)
        end
    elseif r isa StaticLint.TreeRef
        _tree_ref_dot_completion(r, spartial, state)
    elseif r isa SymbolServer.ModuleStore
        _collect_completions(r, spartial, state, true)
    end
end

# ============================================================================
# Symbol collection (three overloads)
# ============================================================================

function _collect_completions(m::SymbolServer.ModuleStore, spartial, state::_CompletionState, inclexported=false, dotcomps=false; priority::Int=_PRIO_STORE)
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
            v === nothing && continue
        end
        if StaticLint.isexportedby(canonical_name, m) || inclexported
            foreach(possible_names) do n
                _add_completion_item(state, CompletionResultItem(
                    n, _completion_kind(v),
                    _completion_details_description(v),
                    v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                    _texteditfor(state, spartial, n)), spartial, priority)
            end
        elseif dotcomps
            foreach(possible_names) do n
                _add_completion_item(state, CompletionResultItem(
                    n, _completion_kind(v),
                    _completion_details_description(v),
                    v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                    _texteditfor(state, spartial, string(m.name, ".", n))), spartial, priority)
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
                        data="import"), spartial, priority)
                end
            elseif state.completion_mode === :qualify
                foreach(possible_names) do n
                    _add_completion_item(state, CompletionResultItem(
                        string(m.name, ".", n), _completion_kind(v), nothing,
                        v isa SymbolServer.SymStore ? _sanitize_docstring(v.doc) : nothing,
                        _texteditfor(state, spartial, string(m.name, ".", n));
                        filter_text=string(n),
                        insert_text_format=InsertFormats.PlainText), spartial, priority)
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
            if CSTParser.isoperator(arg.head) && length(arg.args) == 1 && CSTParser.isidentifier(arg.args[1]) && CSTParser.str_value(arg.args[1]) == x
                return true
            end
        end
    end
    return false
end

function _collect_completions(x::CSTParser.EXPR, spartial, state::_CompletionState, inclexported=false, dotcomps=false; depth::Int=0)
    scope = StaticLint.scopeof(x, state.meta_dict)
    if scope !== nothing
        # bindings in the nearest scope rank first; scopes further out (and the
        # modules they make visible) get progressively lower priority
        _collect_completions(scope, spartial, state, inclexported, dotcomps; priority=_PRIO_LOCAL_BASE + depth)
        if scope.modules isa Dict
            for m in scope.modules
                _collect_completions(m[2], spartial, state, inclexported, dotcomps; priority=_PRIO_MODULE_BASE + depth)
            end
        end
    end
    if CSTParser.parentof(x) !== nothing && !CSTParser.defines_module(x)
        return _collect_completions(CSTParser.parentof(x), spartial, state, inclexported, dotcomps; depth=depth + 1)
    end
    # the walk ended at the file's root scope or an enclosing in-file module:
    # the per-file meta reaches no further, so module-level names come from
    # the visibility layer (and Base/Core from the env stores)
    if !inclexported && !dotcomps
        _append_module_level_completions(x, spartial, state; depth=depth)
    end
end

function _collect_completions(x::StaticLint.Scope, spartial, state::_CompletionState, inclexported=false, dotcomps=false; priority::Int=_PRIO_LOCAL_BASE)
    if x.names !== nothing
        stripped_partial = _strip_var_partial(spartial)
        possible_names = String[]
        for n in x.names
            resize!(possible_names, 0)
            # bindings defined with var"..." syntax keep their quoting; other
            # names (in particular macros) stay raw
            label = _binding_defined_as_var(n[2]) ? _var_wrap(n[1]) : n[1]
            if (is_completion_match(n[1], stripped_partial) ||
                (label != n[1] && is_completion_match(label, spartial))) && label != spartial
                push!(possible_names, label)
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
                        detail_label=_completion_details_label(b)), spartial, priority)
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
                # str_value also covers var"..." module names, where valof is nothing
                key = CSTParser.str_value(x.args[1].args[1].args[1])
                if key isa AbstractString
                    using_stmts[String(key)] = (x, (loc.uri, loc.offset))
                end
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
        # per-file meta: this file's own scopes/bindings/refs only (module
        # contexts stripped) — module-level names are appended from the
        # visibility layer, see `_append_module_level_completions`
        meta_dict = derived_file_analysis(rt, root, uri).meta
        module_path = derived_file_module_path(rt, root, uri)
        env = project_uri !== nothing ? derived_environment(rt, project_uri) : derived_stdlib_only_env(rt)
    else
        meta_dict = _empty_hover_meta_dict
        env = _empty_hover_env
        module_path = nothing
    end

    x = _get_expr(cst, offset)
    using_stmts = if completion_mode == :import
        !isnothing(x) ? _get_preexisting_using_stmts(x, cst, meta_dict, workspace) : Dict{String, Any}()
    else
        Dict{String,Any}()
    end

    ppt, pt, t = _get_toks(st.content, offset)
    is_at_end = offset == t.endbyte + 1

    # A partially typed `var"..."` identifier (e.g. `foo.var"he`)?
    var_partial = _var_string_partial(pt, t, offset, st.content)
    end_offset = offset
    if var_partial !== nothing && t.kind == Tokens.STRING && offset <= t.endbyte
        # the string is already terminated (auto-closing quotes): also replace
        # the closing quote after the cursor
        end_offset = t.endbyte + 1
    end

    state = _CompletionState(
        offset,
        Dict{String,CompletionResultItem}(),
        offset, end_offset,   # start_offset (cursor), end_offset
        x, cst, uri, st, meta_dict, env,
        completion_mode, using_stmts, workspace,
        rt, root, module_path,
        Dict{String,Tuple{String,Int}}()
    )

    # Update start/end offsets based on cursor position for replacement range
    # We use an immutable struct, so we track this externally in the "partial" length
    # that _texteditfor uses.

    if var_partial !== nothing
        if ppt isa CSTParser.Tokens.Token && ppt.kind == Tokens.DOT
            # anchor on the dot token to find the expression being accessed
            px = _get_expr(cst, ppt.startbyte)
            _get_dot_completion(px, var_partial, state)
        elseif state.x !== nothing
            _collect_completions(state.x, var_partial, state, false)
        end
    elseif pt isa CSTParser.Tokens.Token && pt.kind == CSTParser.Tokenize.Tokens.BACKSLASH
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
        px = _get_expr(cst, t.startbyte)
        _get_dot_completion(px, "", state)
    elseif t isa CSTParser.Tokens.Token && t.kind == Tokens.IDENTIFIER && pt isa CSTParser.Tokens.Token && pt.kind == Tokens.DOT && ppt isa CSTParser.Tokens.Token && ppt.kind == Tokens.IDENTIFIER
        # anchor on the dot token, not the cursor: with the cursor mid-token,
        # subtracting whole token lengths from `offset` overshoots to the left
        px = _get_expr(cst, pt.startbyte)
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

    return CompletionResult(true, _finalize_completions(state))
end
