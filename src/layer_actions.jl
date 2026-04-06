# Code actions layer
#
# Contains: code action detection (when predicates) and execution (text edit
# generation) for all supported code actions.
#
# All offsets are 0-based byte offsets internally.
# The public API in public.jl converts 1-based string indices.

# ============================================================================
# Result types
# ============================================================================

struct CodeActionInfo
    id::String
    title::String
    kind::Symbol  # :quickfix, :refactor, :refactor_rewrite, :source_organize_imports, :empty
    is_preferred::Bool
end

struct TextEditResult
    start_offset::Int
    end_offset::Int
    new_text::String
end

struct WorkspaceFileEdit
    uri::URI
    edits::Vector{TextEditResult}
end

# ============================================================================
# Internal types and helpers
# ============================================================================

struct _ActionContext
    offset::Int
    diagnostic_messages::Vector{String}
    workspace_folders::Vector{String}
    file_text::String
end

struct _ActionDef
    id::String
    title::String
    kind::Symbol
    is_preferred::Bool
    when::Function       # (x::EXPR, meta_dict, ctx) → Bool
    handler::Function    # (x::EXPR, runtime, uri, meta_dict, ctx) → Vector{WorkspaceFileEdit}
end

function _action_get_text(runtime, uri::URI)
    return input_text_file(runtime, uri).content.content
end

function _action_get_next_line_offset(x, runtime)
    loc = _get_file_loc(x, runtime)
    loc === nothing && return (-1, nothing)
    uri, offset = loc
    text = _action_get_text(runtime, uri)
    insertpos = -1
    pos = 0
    for line in eachline(IOBuffer(text); keep=true)
        nextpos = pos + sizeof(line)
        if pos < offset + x.span <= nextpos
            insertpos = nextpos
            break
        end
        pos = nextpos
    end
    return (insertpos, uri)
end

function _action_get_parent_fexpr(x::CSTParser.EXPR, f)
    if f(x)
        return x
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _action_get_parent_fexpr(CSTParser.parentof(x), f)
    end
    return nothing
end

function _action_is_in_fexpr(x::CSTParser.EXPR, f)
    if f(x)
        return true
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _action_is_in_fexpr(CSTParser.parentof(x), f)
    end
    return false
end

# ============================================================================
# Action: ExplicitPackageVarImport
# ============================================================================

function _find_using_statement(x::CSTParser.EXPR, meta_dict)
    ref = StaticLint.refof(x, meta_dict)
    ref === nothing && return nothing
    ref isa StaticLint.Binding || return nothing
    for r in ref.refs
        if StaticLint.is_in_fexpr(r, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import)
            return CSTParser.parentof(r)
        end
    end
    return nothing
end

function _explicitly_import_used_variables(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    edits_by_uri = Dict{URI,Vector{TextEditResult}}()
    ref = StaticLint.refof(x, meta_dict)
    !(ref isa StaticLint.Binding && ref.val isa SymbolServer.ModuleStore) && return WorkspaceFileEdit[]
    using_stmt = _find_using_statement(x, meta_dict)
    using_stmt === nothing && return WorkspaceFileEdit[]

    vars = Set{String}()
    for r in ref.refs
        if CSTParser.parentof(r) isa CSTParser.EXPR && CSTParser.is_getfield_w_quotenode(CSTParser.parentof(r)) && CSTParser.parentof(r).args[1] == r
            childname = CSTParser.parentof(r).args[2].args[1]
            StaticLint.hasref(childname, meta_dict) && StaticLint.refof(childname, meta_dict) isa StaticLint.Binding && continue
            !haskey(ref.val.vals, Symbol(CSTParser.valof(childname))) && continue

            loc = _get_file_loc(r, runtime)
            loc === nothing && continue
            ruri, roffset = loc
            if !haskey(edits_by_uri, ruri)
                edits_by_uri[ruri] = TextEditResult[]
            end
            push!(edits_by_uri[ruri], TextEditResult(roffset, roffset + CSTParser.parentof(r).span, CSTParser.valof(childname)))
            push!(vars, CSTParser.valof(childname))
        end
    end
    isempty(edits_by_uri) && return WorkspaceFileEdit[]

    # Add using statement
    if CSTParser.parentof(using_stmt) isa CSTParser.EXPR && (CSTParser.headof(CSTParser.parentof(using_stmt)) === :block || CSTParser.headof(CSTParser.parentof(using_stmt)) === :file)
        insertpos, insert_uri = _action_get_next_line_offset(using_stmt, runtime)
        insertpos == -1 && return WorkspaceFileEdit[]
        insert_uri === nothing && return WorkspaceFileEdit[]
        if !haskey(edits_by_uri, insert_uri)
            edits_by_uri[insert_uri] = TextEditResult[]
        end
        push!(edits_by_uri[insert_uri], TextEditResult(insertpos, insertpos, string("using ", CSTParser.valof(x), ": ", join(vars, ", "), "\n")))
    else
        return WorkspaceFileEdit[]
    end

    return [WorkspaceFileEdit(u, e) for (u, e) in edits_by_uri]
end

# ============================================================================
# Action: ExpandFunction
# ============================================================================

_is_single_line_func(x) = CSTParser.defines_function(x) && CSTParser.headof(x) !== :function

function _expand_inline_func(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    func = _action_get_parent_fexpr(x, _is_single_line_func)
    func === nothing && return WorkspaceFileEdit[]
    length(func) < 3 && return WorkspaceFileEdit[]
    sig = func.args[1]
    op = func.head
    body = func.args[2]
    loc = _get_file_loc(func, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    text = _action_get_text(runtime, furi)

    newtext = nothing
    if CSTParser.headof(body) === :block && length(body) == 1
        newtext = string("function ", text[offset .+ (1:sig.span)], "\n    ", text[offset + sig.fullspan + op.fullspan .+ (1:body.span)], "\nend")
    elseif (CSTParser.headof(body) === :begin || CSTParser.isbracketed(body)) &&
        body.args !== nothing && !isempty(body.args) &&
        CSTParser.headof(body.args[1]) === :block && length(body.args[1]) > 0
        newtext = string("function ", text[offset .+ (1:sig.span)])
        blockoffset = offset + sig.fullspan + op.fullspan + body.trivia[1].fullspan
        for i = 1:length(body.args[1].args)
            newtext = string(newtext, "\n    ", text[blockoffset .+ (1:body.args[1].args[i].span)])
            blockoffset += body.args[1].args[i].fullspan
        end
        newtext = string(newtext, "\nend")
    end
    newtext === nothing && return WorkspaceFileEdit[]
    return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + func.span, newtext)])]
end

# ============================================================================
# Action: FixMissingRef
# ============================================================================

function _is_fixable_missing_ref(x::CSTParser.EXPR, meta_dict, diag_messages::Vector{String})
    if !isempty(diag_messages) && any(startswith(d, "Missing reference") for d in diag_messages) && CSTParser.isidentifier(x)
        xname = StaticLint.valofid(x)
        tls = _retrieve_toplevel_scope(x, meta_dict)
        if tls isa StaticLint.Scope && tls.modules !== nothing
            for m in values(tls.modules)
                if (m isa SymbolServer.ModuleStore && haskey(m, Symbol(xname))) || (m isa StaticLint.Scope && StaticLint.scopehasbinding(m, xname))
                    return true
                end
            end
        end
    end
    return false
end

function _apply_missing_ref_fix(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    xname = StaticLint.valofid(x)
    loc = _get_file_loc(x, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    tls = _retrieve_toplevel_scope(x, meta_dict)
    tls === nothing && return WorkspaceFileEdit[]
    if tls.modules !== nothing
        for (n, m) in tls.modules
            if (m isa SymbolServer.ModuleStore && haskey(m, Symbol(xname))) || (m isa StaticLint.Scope && StaticLint.scopehasbinding(m, xname))
                return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset, string(n, "."))])]
            end
        end
    end
    return WorkspaceFileEdit[]
end

# ============================================================================
# Action: ReexportModule
# ============================================================================

function _reexport_package(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    ref = StaticLint.refof(x, meta_dict)
    mod = if ref isa SymbolServer.ModuleStore
        ref
    elseif ref isa StaticLint.Binding && ref.val isa SymbolServer.ModuleStore
        ref.val
    else
        return WorkspaceFileEdit[]
    end
    using_stmt = CSTParser.parentof(x)
    loc = _get_file_loc(x, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, _ = loc
    insertpos, _ = _action_get_next_line_offset(using_stmt, runtime)
    insertpos == -1 && return WorkspaceFileEdit[]

    export_text = string("export ", join(sort([string(n) for (n, v) in mod.vals if StaticLint.isexportedby(n, mod)]), ", "), "\n")
    return [WorkspaceFileEdit(furi, [TextEditResult(insertpos, insertpos, export_text)])]
end

# ============================================================================
# Action: DeleteUnusedFunctionArgumentName
# ============================================================================

function _remove_farg_name(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    x1 = StaticLint.get_parent_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) == StaticLint.UnusedFunctionArgument)
    x1 === nothing && return WorkspaceFileEdit[]
    loc = _get_file_loc(x1, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    if CSTParser.isdeclaration(x1)
        return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + x1.args[1].fullspan, "")])]
    else
        return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + x1.fullspan, "_")])]
    end
end

# ============================================================================
# Action: ReplaceUnusedAssignmentName
# ============================================================================

function _remove_unused_assignment_name(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    x1 = StaticLint.get_parent_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) == StaticLint.UnusedBinding && y isa CSTParser.EXPR && y.head === :IDENTIFIER)
    x1 === nothing && return WorkspaceFileEdit[]
    loc = _get_file_loc(x1, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + x1.span, "_")])]
end

# ============================================================================
# Action: CompareNothingWithTripleEqual
# ============================================================================

function _double_to_triple_equal(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    x1 = StaticLint.get_parent_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) in (StaticLint.NothingEquality, StaticLint.NothingNotEq))
    x1 === nothing && return WorkspaceFileEdit[]
    loc = _get_file_loc(x1, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    new_op = StaticLint.errorof(x1, meta_dict) == StaticLint.NothingEquality ? "===" : "!=="
    return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + x1.span, new_op)])]
end

# ============================================================================
# Action: WrapInIfBlock
# ============================================================================

function _wrap_in_if_block(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    loc = _get_file_loc(x, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    return [WorkspaceFileEdit(furi, [
        TextEditResult(offset, offset, "if CONDITION\n"),
        TextEditResult(offset + x.span, offset + x.span, "\nend")
    ])]
end

# ============================================================================
# Action: OrganizeImports
# ============================================================================

function _organize_import_block(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    if !StaticLint.is_in_fexpr(x, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import)
        return WorkspaceFileEdit[]
    end

    siblings = CSTParser.EXPR[]
    using_stmt = StaticLint.get_parent_fexpr(x, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import)
    using_stmt === nothing && return WorkspaceFileEdit[]
    push!(siblings, using_stmt)
    block = CSTParser.parentof(using_stmt)
    if block !== nothing
        myidx = findfirst(a -> a === using_stmt, block.args)
        if myidx !== nothing
            for direction in (-1, 1)
                i = direction
                while true
                    s = get(block.args, myidx + i, nothing)
                    if s isa CSTParser.EXPR && (s.head === :using || s.head === :import)
                        (direction == 1 ? push! : pushfirst!)(siblings, s)
                        i += direction
                    else
                        break
                    end
                end
            end
        end
    end

    using_mods = Set{String}()
    using_syms = Dict{String,Set{String}}()
    import_mods = Set{String}()
    import_syms = Dict{String,Set{String}}()

    function module_join(a)
        io = IOBuffer()
        for y in a.args[1:end-1]
            print(io, y.val)
            y.val == "." && continue
            print(io, ".")
        end
        print(io, a.args[end].val)
        return String(take!(io))
    end

    for s in siblings
        isusing = s.head === :using
        for a in s.args
            if CSTParser.is_colon(a.head)
                mod = module_join(a.args[1])
                set = get!(Set, isusing ? using_syms : import_syms, mod)
                for i in 2:length(a.args)
                    push!(set, join(y.val for y in a.args[i]))
                end
            elseif CSTParser.is_dot(a.head)
                push!(isusing ? using_mods : import_mods, module_join(a))
            elseif !isusing && CSTParser.headof(a) === :as
                push!(import_mods, join((module_join(a.args[1]), "as", a.args[2].val), " "))
            end
        end
    end

    function sort_with_self_first(set, self)
        self_val = pop!(set, self, nothing)
        sorted = sort!(collect(set))
        if self_val !== nothing
            pushfirst!(sorted, self)
        end
        return sorted
    end

    import_lines = String[]
    for m in import_mods
        push!(import_lines, "import " * m)
    end
    for (m, s) in import_syms
        push!(import_lines, "import " * m * ": " * join(sort_with_self_first(s, m), ", "))
    end
    using_lines = String[]
    for m in using_mods
        push!(using_lines, "using " * m)
    end
    for (m, s) in using_syms
        push!(using_lines, "using " * m * ": " * join(sort_with_self_first(s, m), ", "))
    end
    io = IOBuffer()
    join(io, sort!(import_lines), "\n")
    length(import_lines) > 0 && print(io, "\n\n")
    join(io, sort!(using_lines), "\n")
    sorted_text = String(take!(io))

    # Compute range of original blocks
    first_loc = _get_file_loc(first(siblings), runtime)
    last_loc = _get_file_loc(last(siblings), runtime)
    (first_loc === nothing || last_loc === nothing) && return WorkspaceFileEdit[]
    furi, firstoffset = first_loc
    _, lastoffset = last_loc
    lastoffset += last(siblings).span

    return [WorkspaceFileEdit(furi, [TextEditResult(firstoffset, lastoffset, sorted_text)])]
end

# ============================================================================
# Action: RewriteAsRawString / RewriteAsRegularString
# ============================================================================

function _is_string_literal(x::CSTParser.EXPR; inraw::Bool=false)
    if CSTParser.headof(x) === :STRING
        if CSTParser.parentof(x) isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(x)) === :string
            return false
        end
        if CSTParser.parentof(x) isa CSTParser.EXPR && CSTParser.ismacrocall(CSTParser.parentof(x))
            if CSTParser.parentof(x).args[1] isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(x).args[1]) === :IDENTIFIER &&
               endswith(CSTParser.parentof(x).args[1].val, "_str") &&
               ncodeunits(CSTParser.parentof(x).args[1].val) - ncodeunits("@_str") == CSTParser.parentof(x).args[1].span
                return inraw ? CSTParser.parentof(x).args[1].val == "@raw_str" : false
            elseif CSTParser.parentof(x).args[1] isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(x).args[1]) === :globalrefdoc
                return false
            end
        end
        return inraw ? false : true
    end
    return false
end

function _convert_to_raw(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    _is_string_literal(x) || return WorkspaceFileEdit[]
    loc = _get_file_loc(x, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    quotes = CSTParser.headof(x) === :TRIPLESTRING ? "\"\"\"" : "\""
    raw = string("raw", quotes, sprint(Base.escape_raw_string, CSTParser.valof(x)), quotes)
    return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + x.span, raw)])]
end

function _convert_from_raw(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    _is_string_literal(x; inraw=true) || return WorkspaceFileEdit[]
    xparent = CSTParser.parentof(x)
    loc = _get_file_loc(xparent, runtime)
    loc === nothing && return WorkspaceFileEdit[]
    furi, offset = loc
    quotes = CSTParser.headof(x) === :TRIPLESTRING ? "\"\"" : ""
    regular = quotes * repr(CSTParser.valof(x)) * quotes
    return [WorkspaceFileEdit(furi, [TextEditResult(offset, offset + xparent.span, regular)])]
end

# ============================================================================
# Action: AddDocstringTemplate
# ============================================================================

function _is_parent_of(parent::CSTParser.EXPR, child::CSTParser.EXPR)
    while child isa CSTParser.EXPR
        if child == parent
            return true
        end
        child = CSTParser.parentof(child)
    end
    return false
end

function _is_in_function_signature(x::CSTParser.EXPR, meta_dict=nothing; with_docstring::Bool=false)
    func = _action_get_parent_fexpr(x, CSTParser.defines_function)
    func === nothing && return false
    sig = func.args[1]
    if CSTParser.headof(x) === :FUNCTION || _is_parent_of(sig, x)
        hasdoc = CSTParser.parentof(func) isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(func)) === :macrocall && CSTParser.parentof(func).args[1] isa CSTParser.EXPR &&
                 CSTParser.headof(CSTParser.parentof(func).args[1]) === :globalrefdoc
        return with_docstring == hasdoc
    end
    return false
end

function _is_in_docstring_for_function(x::CSTParser.EXPR)
    return CSTParser.isstringliteral(x) && CSTParser.parentof(x) isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(x)) === :macrocall &&
       length(CSTParser.parentof(x).args) == 4 && CSTParser.parentof(x).args[1] isa CSTParser.EXPR &&
       CSTParser.headof(CSTParser.parentof(x).args[1]) === :globalrefdoc && CSTParser.defines_function(CSTParser.parentof(x).args[4])
end

function _add_docstring_template(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    _is_in_function_signature(x) || return WorkspaceFileEdit[]
    func = _action_get_parent_fexpr(x, CSTParser.defines_function)
    func === nothing && return WorkspaceFileEdit[]
    func_loc = _get_file_loc(func, runtime)
    func_loc === nothing && return WorkspaceFileEdit[]
    furi, func_offset = func_loc
    sig = func.args[1]
    sig_loc = _get_file_loc(sig, runtime)
    sig_loc === nothing && return WorkspaceFileEdit[]
    _, sig_offset = sig_loc
    text = _action_get_text(runtime, furi)
    docstr = "\"\"\"\n    " * text[sig_offset .+ (1:sig.span)] * "\n\nTBW\n\"\"\"\n"
    return [WorkspaceFileEdit(furi, [TextEditResult(func_offset, func_offset, docstr)])]
end

# ============================================================================
# Action: UpdateDocstringSignature
# ============================================================================

function _update_docstring_sig(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, _ctx=nothing)
    if _is_in_function_signature(x; with_docstring=true)
        func = _action_get_parent_fexpr(x, CSTParser.defines_function)
    elseif _is_in_docstring_for_function(x)
        func = CSTParser.parentof(x).args[4]
    else
        return WorkspaceFileEdit[]
    end
    func === nothing && return WorkspaceFileEdit[]
    docstr_expr = CSTParser.parentof(func).args[3]
    docstr = CSTParser.valof(docstr_expr)
    docstr_loc = _get_file_loc(docstr_expr, runtime)
    docstr_loc === nothing && return WorkspaceFileEdit[]
    furi, docstr_offset = docstr_loc
    text = _action_get_text(runtime, furi)
    sig = func.args[1]
    sig_loc = _get_file_loc(sig, runtime)
    sig_loc === nothing && return WorkspaceFileEdit[]
    _, sig_offset = sig_loc
    sig_str = text[sig_offset .+ (1:sig.span)]
    reg = r"\A    .*$"m
    if (m = match(reg, CSTParser.valof(docstr_expr)); m !== nothing)
        docstr = replace(docstr, reg => string("    ", sig_str))
    else
        docstr = string("    ", sig_str, "\n\n", docstr)
    end
    newline = endswith(docstr, "\n") ? "" : "\n"
    docstr = string("\"\"\"\n", docstr, newline, "\"\"\"")
    return [WorkspaceFileEdit(furi, [TextEditResult(docstr_offset, docstr_offset + docstr_expr.span, docstr)])]
end

# ============================================================================
# Action registry
# ============================================================================

const _JW_ACTIONS = Dict{String,_ActionDef}()

_JW_ACTIONS["ExplicitPackageVarImport"] = _ActionDef(
    "ExplicitPackageVarImport",
    "Explicitly import used package variables.",
    :empty,
    false,
    (x, meta_dict, ctx) -> (ref = StaticLint.refof(x, meta_dict); ref isa StaticLint.Binding && ref.val isa SymbolServer.ModuleStore),
    _explicitly_import_used_variables,
)

_JW_ACTIONS["ExpandFunction"] = _ActionDef(
    "ExpandFunction",
    "Expand function definition.",
    :refactor,
    false,
    (x, meta_dict, ctx) -> _action_is_in_fexpr(x, _is_single_line_func),
    _expand_inline_func,
)

_JW_ACTIONS["FixMissingRef"] = _ActionDef(
    "FixMissingRef",
    "Fix missing reference",
    :empty,
    false,
    (x, meta_dict, ctx) -> _is_fixable_missing_ref(x, meta_dict, ctx.diagnostic_messages),
    _apply_missing_ref_fix,
)

_JW_ACTIONS["ReexportModule"] = _ActionDef(
    "ReexportModule",
    "Re-export package variables.",
    :empty,
    false,
    (x, meta_dict, ctx) -> begin
        StaticLint.is_in_fexpr(x, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import) && begin
            ref = StaticLint.refof(x, meta_dict)
            (ref isa StaticLint.Binding && (ref.type === StaticLint.CoreTypes.Module || (ref.val isa StaticLint.Binding && ref.val.type === StaticLint.CoreTypes.Module) || ref.val isa SymbolServer.ModuleStore) || ref isa SymbolServer.ModuleStore)
        end
    end,
    _reexport_package,
)

_JW_ACTIONS["DeleteUnusedFunctionArgumentName"] = _ActionDef(
    "DeleteUnusedFunctionArgumentName",
    "Delete name of unused function argument.",
    :quickfix,
    false,
    (x, meta_dict, ctx) -> StaticLint.is_in_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) == StaticLint.UnusedFunctionArgument),
    _remove_farg_name,
)

_JW_ACTIONS["ReplaceUnusedAssignmentName"] = _ActionDef(
    "ReplaceUnusedAssignmentName",
    "Replace unused assignment name with _.",
    :quickfix,
    false,
    (x, meta_dict, ctx) -> StaticLint.is_in_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) == StaticLint.UnusedBinding && y isa CSTParser.EXPR && y.head === :IDENTIFIER),
    _remove_unused_assignment_name,
)

_JW_ACTIONS["CompareNothingWithTripleEqual"] = _ActionDef(
    "CompareNothingWithTripleEqual",
    "Change ==/!= to ===/!==.",
    :quickfix,
    true,
    (x, meta_dict, ctx) -> StaticLint.is_in_fexpr(x, y -> StaticLint.haserror(y, meta_dict) && StaticLint.errorof(y, meta_dict) in (StaticLint.NothingEquality, StaticLint.NothingNotEq)),
    _double_to_triple_equal,
)

_JW_ACTIONS["OrganizeImports"] = _ActionDef(
    "OrganizeImports",
    "Organize `using` and `import` statements.",
    :source_organize_imports,
    false,
    (x, meta_dict, ctx) -> StaticLint.is_in_fexpr(x, y -> CSTParser.headof(y) === :using || CSTParser.headof(y) === :import),
    _organize_import_block,
)

_JW_ACTIONS["RewriteAsRawString"] = _ActionDef(
    "RewriteAsRawString",
    "Rewrite as raw string",
    :refactor_rewrite,
    false,
    (x, meta_dict, ctx) -> _is_string_literal(x),
    _convert_to_raw,
)

_JW_ACTIONS["RewriteAsRegularString"] = _ActionDef(
    "RewriteAsRegularString",
    "Rewrite as regular string",
    :refactor_rewrite,
    false,
    (x, meta_dict, ctx) -> _is_string_literal(x; inraw=true),
    _convert_from_raw,
)

_JW_ACTIONS["AddDocstringTemplate"] = _ActionDef(
    "AddDocstringTemplate",
    "Add docstring template for this method",
    :empty,
    false,
    (x, meta_dict, ctx) -> _is_in_function_signature(x),
    _add_docstring_template,
)

_JW_ACTIONS["UpdateDocstringSignature"] = _ActionDef(
    "UpdateDocstringSignature",
    "Update method signature in docstring",
    :empty,
    false,
    (x, meta_dict, ctx) -> _is_in_function_signature(x; with_docstring=true) || _is_in_docstring_for_function(x),
    _update_docstring_sig,
)

# ============================================================================
# Action: AddLicenseIdentifier
# ============================================================================

function _safe_isfile(s::AbstractString)
    try
        !occursin("\0", s) && isfile(s)
    catch err
        isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
        false
    end
end
_safe_isfile(::Nothing) = false

function _get_spdx_header(text::AbstractString)
    m = match(r"(*ANYCRLF)^# SPDX-License-Identifier:\h+((?:[\w\.-]+)(?:\h+[\w\.-]+)*)\h*$"m, text)
    return m === nothing ? m : String(m[1])
end

function _in_same_workspace_folder(file1_str, file2_str, workspace_folders::Vector{String})
    (file1_str === nothing || file2_str === nothing) && return false
    for ws in workspace_folders
        if _path_startswith(file1_str, ws) && _path_startswith(file2_str, ws)
            return true
        end
    end
    return false
end

# Case-insensitive startswith on Windows for path comparison
@static if Sys.iswindows()
    _path_startswith(path, prefix) = startswith(lowercase(path), lowercase(prefix))
else
    _path_startswith(path, prefix) = startswith(path, prefix)
end

function _identify_short_identifier(runtime, file_uri::URI, workspace_folders::Vector{String})
    file_uri_str = uri2filepath(file_uri)

    # First look in tracked files (in the same workspace folder) for existing headers
    candidate_identifiers = Set{String}()
    for uri in derived_text_files(runtime)
        uri_str = uri2filepath(uri)
        _in_same_workspace_folder(file_uri_str, uri_str, workspace_folders) || continue
        text = _action_get_text(runtime, uri)
        id = _get_spdx_header(text)
        id === nothing || push!(candidate_identifiers, id)
    end
    if length(candidate_identifiers) == 1
        return first(candidate_identifiers)
    end

    # Fallback to looking for a license file in the same workspace folder
    candidate_files = String[]
    for dir in workspace_folders
        for f in joinpath.(dir, ["LICENSE", "LICENSE.md"])
            f_str = f
            _in_same_workspace_folder(file_uri_str, f_str, workspace_folders) || continue
            _safe_isfile(f) || continue
            push!(candidate_files, f)
        end
    end

    length(candidate_files) != 1 && return nothing

    license_text = read(first(candidate_files), String)

    if contains(license_text, r"^\s*MIT\s+(\"?Expat\"?\s+)?Licen[sc]e")
        return "MIT"
    elseif contains(license_text, r"^\s*EUROPEAN\s+UNION\s+PUBLIC\s+LICEN[CS]E\s+v\."i)
        version = match(r"\d\.\d", license_text).match
        return "EUPL-$version"
    end

    return nothing
end

function _is_on_first_line(ctx::_ActionContext)
    first_newline = findfirst('\n', ctx.file_text)
    # offset is 0-based; if no newline, entire file is one line
    return first_newline === nothing || ctx.offset < first_newline
end

function _add_license_identifier(x::CSTParser.EXPR, runtime, uri::URI, meta_dict, ctx::_ActionContext)
    isempty(ctx.workspace_folders) && return WorkspaceFileEdit[]
    text = _action_get_text(runtime, uri)

    # Does the current file already have a header?
    _get_spdx_header(text) === nothing || return WorkspaceFileEdit[]

    short_identifier = _identify_short_identifier(runtime, uri, ctx.workspace_folders)
    short_identifier === nothing && return WorkspaceFileEdit[]

    return [WorkspaceFileEdit(uri, [TextEditResult(0, 0, "# SPDX-License-Identifier: $(short_identifier)\n\n")])]
end

_JW_ACTIONS["AddLicenseIdentifier"] = _ActionDef(
    "AddLicenseIdentifier",
    "Add SPDX license identifier.",
    :empty,
    false,
    (x, meta_dict, ctx) -> !isempty(ctx.workspace_folders) && _is_on_first_line(ctx),
    _add_license_identifier,
)

# ============================================================================
# Top-level API
# ============================================================================

"""
    _get_code_actions(runtime, uri, offset, diagnostic_messages) → Vector{CodeActionInfo}

Return the list of applicable code actions at the given offset.
"""
function _get_code_actions(runtime, uri::URI, offset::Int, diagnostic_messages::Vector{String}, workspace_folders::Vector{String})
    actions = CodeActionInfo[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return actions

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    cst === nothing && return actions

    x = _get_expr(cst, offset)
    x isa CSTParser.EXPR || return actions

    ctx = _ActionContext(offset, diagnostic_messages, workspace_folders, _action_get_text(runtime, uri))

    for (_, ad) in _JW_ACTIONS
        try
            if ad.when(x, meta_dict, ctx)
                push!(actions, CodeActionInfo(ad.id, ad.title, ad.kind, ad.is_preferred))
            end
        catch
            # Skip actions whose predicates fail
        end
    end

    return actions
end

"""
    _execute_code_action(runtime, action_id, uri, offset) → Vector{WorkspaceFileEdit}

Execute the code action identified by `action_id` and return the workspace edits.
"""
function _execute_code_action(runtime, action_id::String, uri::URI, offset::Int, workspace_folders::Vector{String})
    haskey(_JW_ACTIONS, action_id) || return WorkspaceFileEdit[]

    ad = _JW_ACTIONS[action_id]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return WorkspaceFileEdit[]

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    cst === nothing && return WorkspaceFileEdit[]

    x = _get_expr(cst, offset)
    x isa CSTParser.EXPR || return WorkspaceFileEdit[]

    ctx = _ActionContext(offset, String[], workspace_folders, _action_get_text(runtime, uri))
    return ad.handler(x, runtime, uri, meta_dict, ctx)
end
