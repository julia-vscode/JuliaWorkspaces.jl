# Hover text generation layer
#
# Produces markdown documentation strings for a given position (string index)
# in a Julia source file. All the logic that was in LanguageServer/hover.jl
# now lives here, operating purely on CSTParser EXPR trees, StaticLint
# bindings/scopes, and SymbolServer stores — no LSP types.

using .URIs2: filepath2uri
import REPL

# ============================================================================
# Helper utilities (moved from LanguageServer utilities.jl / staticlint.jl)
# ============================================================================

const MetaDict = Dict{UInt64, StaticLint.Meta}

const _empty_hover_meta_dict = MetaDict()
const _empty_hover_env = StaticLint.ExternalEnv(
    SymbolServer.EnvStore(),
    Dict{SymbolServer.VarRef,Vector{SymbolServer.VarRef}}(),
    Symbol[],
)

# --- CST expr lookup --------------------------------------------------------

"""
    get_expr1(x, offset, pos=0)

Walk a CSTParser EXPR tree and return the leaf EXPR whose `span` covers
`offset` (0-based byte offset). Returns `nothing` if no match is found.
"""
function get_expr1(x, offset, pos=0)
    if length(x) == 0 || CSTParser.headof(x) === :NONSTDIDENTIFIER
        if pos <= offset <= pos + x.span
            return x
        else
            return nothing
        end
    else
        for i = 1:length(x)
            arg = x[i]
            if pos < offset < (pos + arg.span) # def within span
                return get_expr1(arg, offset, pos)
            elseif arg.span == arg.fullspan
                if offset == pos
                    if i == 1
                        return get_expr1(arg, offset, pos)
                    elseif CSTParser.headof(x[i - 1]) === :IDENTIFIER
                        return get_expr1(x[i - 1], offset, pos)
                    else
                        return get_expr1(arg, offset, pos)
                    end
                elseif i == length(x) # offset == pos + arg.fullspan
                    return get_expr1(arg, offset, pos)
                end
            else
                if offset == pos
                    if i == 1
                        return get_expr1(arg, offset, pos)
                    elseif CSTParser.headof(x[i - 1]) === :IDENTIFIER
                        return get_expr1(x[i - 1], offset, pos)
                    else
                        return get_expr1(arg, offset, pos)
                    end
                elseif offset == pos + arg.span
                    return get_expr1(arg, offset, pos)
                elseif offset == pos + arg.fullspan
                elseif pos + arg.span < offset < pos + arg.fullspan
                    return nothing
                end
            end
            pos += arg.fullspan
        end
        return nothing
    end
end

# --- Scope retrieval --------------------------------------------------------

function _retrieve_scope(x, meta_dict::MetaDict)
    if StaticLint.scopeof(x, meta_dict) !== nothing
        return StaticLint.scopeof(x, meta_dict)
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _retrieve_scope(CSTParser.parentof(x), meta_dict)
    end
    return nothing
end

function _retrieve_toplevel_scope(x::CSTParser.EXPR, meta_dict::MetaDict)
    if StaticLint.scopeof(x, meta_dict) !== nothing && StaticLint.is_toplevel_scope(x)
        return StaticLint.scopeof(x, meta_dict)
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _retrieve_toplevel_scope(CSTParser.parentof(x), meta_dict)
    end
    return nothing
end
_retrieve_toplevel_scope(s::StaticLint.Scope, meta_dict::MetaDict) =
    (StaticLint.is_toplevel_scope(s) || !(StaticLint.parentof(s) isa StaticLint.Scope)) ?
        s : _retrieve_toplevel_scope(StaticLint.parentof(s), meta_dict)

# --- Operator reference resolution ------------------------------------------

function _has_parent_file(x::CSTParser.EXPR)
    while CSTParser.parentof(x) isa CSTParser.EXPR
        x = CSTParser.parentof(x)
    end
    return CSTParser.parentof(x) === nothing && CSTParser.headof(x) === :file
end

function _resolve_op_ref(x::CSTParser.EXPR, env, meta_dict::MetaDict)
    StaticLint.hasref(x, meta_dict) && return true
    !CSTParser.isoperator(x) && return false
    _has_parent_file(x) || return false
    scope = _retrieve_scope(x, meta_dict)
    scope === nothing && return false
    return _op_resolve_up_scopes(x, CSTParser.str_value(x), scope, env, meta_dict)
end

function _op_resolve_up_scopes(x, mn, scope, env, meta_dict::MetaDict)
    scope isa StaticLint.Scope || return false
    if StaticLint.scopehasbinding(scope, mn)
        StaticLint.setref!(x, scope.names[mn], meta_dict)
        return true
    elseif scope.modules isa Dict && length(scope.modules) > 0
        for (_, m) in scope.modules
            if m isa SymbolServer.ModuleStore && StaticLint.isexportedby(Symbol(mn), m)
                StaticLint.setref!(x, StaticLint.maybe_lookup(m[Symbol(mn)], env), meta_dict)
                return true
            elseif m isa StaticLint.Scope && StaticLint.scopehasbinding(m, mn)
                StaticLint.setref!(x, StaticLint.maybe_lookup(m.names[mn], env), meta_dict)
                return true
            end
        end
    end
    CSTParser.defines_module(scope.expr) || !(StaticLint.parentof(scope) isa StaticLint.Scope) && return false
    return _op_resolve_up_scopes(x, mn, StaticLint.parentof(scope), env, meta_dict)
end

# --- String helpers ---------------------------------------------------------

function _sanitize_docstring(doc::String)
    doc = replace(doc, "```jldoctest" => "```julia")
    doc = replace(doc, "\n#" => "\n###")
    return doc
end

_ensure_ends_with(s, c = "\n") = endswith(s, c) ? s : string(s, c)

# ============================================================================
# Type annotation helpers (for variable hover + completions)
# ============================================================================

function completion_type(b::StaticLint.Binding)
    typ = _inner_completion_type(b.type)
    typ === missing && return missing
    if startswith(typ, "Core.")
        typ = typ[6:end]
    end
    return Symbol(typ)
end
completion_type(_) = missing

_inner_completion_type(b::SymbolServer.DataTypeStore) = sprint(print, b.name)
_inner_completion_type(b::StaticLint.Binding) = sprint(print, CSTParser.to_codeobject(b.name))
_inner_completion_type(_) = missing

function _maybe_insert_type_declaration(b::StaticLint.Binding)
    if b.val isa CSTParser.EXPR
        _maybe_insert_type_declaration(CSTParser.to_codeobject(b.val), completion_type(b))
    else
        completion_type(b)
    end
end

_maybe_insert_type_declaration(_, type) = coalesce(type, "")
_maybe_insert_type_declaration(s::Symbol, ::Missing) = s
_maybe_insert_type_declaration(s::Symbol, type) = Expr(:(::), s, Symbol(type))
_maybe_insert_type_declaration(ex::Expr, ::Missing) = ex
function _maybe_insert_type_declaration(ex::Expr, type)
    if ex.head === :(=) && length(ex.args) >= 2
        lhs = ex.args[1]
        if !(lhs isa Expr && lhs.head === :(::))
            ex.args[1] = Expr(:(::), lhs, Symbol(type))
        end
    end
    return ex
end

function _prettify_expr(ex::Expr)
    if ex.head === :kw && length(ex.args) == 2
        string(ex.args[1], " = ", ex.args[2])
    else
        string(ex)
    end
end
_prettify_expr(ex) = string(ex)

get_typed_definition(b) = completion_type(b)
get_typed_definition(b::StaticLint.Binding) =
    _prettify_expr(_maybe_insert_type_declaration(b))

# ============================================================================
# Doc extraction helpers
# ============================================================================

function _maybe_get_doc_expr(x)
    while CSTParser.hasparent(x) && CSTParser.ismacrocall(CSTParser.parentof(x))
        x = CSTParser.parentof(x)
        CSTParser.headof(x.args[1]) === :globalrefdoc && return x
    end
    return x
end

_expr_has_preceding_docs(x) = false
_expr_has_preceding_docs(x::CSTParser.EXPR) = _is_doc_expr(_maybe_get_doc_expr(x))

_is_const_expr(x) = false
_is_const_expr(x::CSTParser.EXPR) = CSTParser.headof(x) === :const

_is_doc_expr(x) = false
function _is_doc_expr(x::CSTParser.EXPR)
    return CSTParser.ismacrocall(x) &&
           length(x.args) == 4 &&
           CSTParser.headof(x.args[1]) === :globalrefdoc &&
           CSTParser.isstring(x.args[3])
end

_binding_has_preceding_docs(b::StaticLint.Binding) = _expr_has_preceding_docs(b.val)

function _const_binding_has_preceding_docs(b::StaticLint.Binding)
    p = CSTParser.parentof(b.val)
    _is_const_expr(p) && _expr_has_preceding_docs(p)
end

function _get_preceding_docs(expr::CSTParser.EXPR, documentation)
    if _expr_has_preceding_docs(expr)
        string(documentation, CSTParser.to_codeobject(_maybe_get_doc_expr(expr).args[3]))
    elseif _is_const_expr(CSTParser.parentof(expr)) && _expr_has_preceding_docs(CSTParser.parentof(expr))
        string(documentation, CSTParser.to_codeobject(_maybe_get_doc_expr(CSTParser.parentof(expr)).args[3]))
    else
        documentation
    end
end

# ============================================================================
# Core hover dispatch
# ============================================================================

_get_hover(x, documentation::String, expr, env, meta_dict) = documentation

function _get_hover(x::CSTParser.EXPR, documentation::String, expr, env, meta_dict)
    if (CSTParser.isidentifier(x) || CSTParser.isoperator(x)) && StaticLint.hasref(x, meta_dict)
        r = StaticLint.refof(x, meta_dict)
        documentation = if r isa StaticLint.Binding
            _get_hover(r, documentation, expr, env, meta_dict)
        elseif r isa SymbolServer.SymStore
            _get_hover(r, documentation, expr, env, meta_dict)
        else
            documentation
        end
    end
    return documentation
end

_get_hover(b::StaticLint.Binding, documentation::String, expr, env, meta_dict) =
    _get_tooltip(b, documentation, meta_dict, expr, env; show_definition = true)

function _get_tooltip(b::StaticLint.Binding, documentation::String, meta_dict::MetaDict=_empty_hover_meta_dict, expr = nothing, env = nothing; show_definition = false)
    if b.val isa StaticLint.Binding
        documentation = _get_hover(b.val, documentation, expr, env, meta_dict)
    elseif b.val isa CSTParser.EXPR
        if CSTParser.defines_function(b.val) || CSTParser.defines_datatype(b.val)
            documentation = _get_func_hover(b, documentation, expr, env, meta_dict)
            for r in b.refs
                method = StaticLint.get_method(r)
                if method isa CSTParser.EXPR
                    documentation = _get_preceding_docs(method, documentation)
                    if CSTParser.defines_function(method)
                        documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(CSTParser.get_sig(method)), "\n```\n")
                    elseif CSTParser.defines_datatype(method)
                        documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(method), "\n```\n")
                    end
                elseif method isa SymbolServer.SymStore
                    documentation = _get_hover(method, documentation, expr, env, meta_dict)
                end
            end
        else
            documentation = try
                if show_definition
                    documentation = string(
                        _ensure_ends_with(documentation),
                        """```julia
                        $(get_typed_definition(b))
                        ```\n
                        """
                    )
                end
                documentation = if _binding_has_preceding_docs(b)
                    string(documentation, CSTParser.to_codeobject(_maybe_get_doc_expr(b.val).args[3]))
                elseif _const_binding_has_preceding_docs(b)
                    string(documentation, CSTParser.to_codeobject(_maybe_get_doc_expr(CSTParser.parentof(b.val)).args[3]))
                else
                    documentation
                end
            catch err
                @error "get_hover failed to convert Expr" exception = (err, catch_backtrace())
                documentation
            end
        end
    elseif b.val isa SymbolServer.SymStore
        documentation = _get_hover(b.val, documentation, expr, env, meta_dict)
    end
    return documentation
end

# --- SymbolServer stores ----------------------------------------------------

function _get_hover(b::SymbolServer.SymStore, documentation::String, expr, env, meta_dict)
    if !isempty(b.doc)
        documentation = string(documentation, b.doc, "\n")
    end
    documentation = string(documentation, "```julia\n", b, "\n```")
end

function _get_hover(f::SymbolServer.FunctionStore, documentation::String, expr, env, meta_dict)
    if !isempty(f.doc)
        documentation = string(documentation, f.doc, "\n\n")
    end

    if !isnothing(env)
        edt = StaticLint.get_eventual_datatype(f, env)
        if edt isa SymbolServer.DataTypeStore
            documentation = string(_get_hover(edt, documentation, expr, env, meta_dict), "\n\n")
        end
    end

    if expr !== nothing && env !== nothing
        tls = _retrieve_toplevel_scope(expr, meta_dict)
        itr = func -> StaticLint.iterate_over_ss_methods(f, tls, env, func)
    else
        itr = func -> begin
            for m in f.methods
                func(m)
            end
        end
    end

    method_count = 0
    totalio = IOBuffer()
    itr() do m
        method_count += 1

        io = IOBuffer()
        print(io, m.name, "(")
        nsig = length(m.sig)
        for (i, sig) = enumerate(m.sig)
            if sig[1] ≠ Symbol("#unused#")
                print(io, sig[1])
            end
            print(io, "::", sig[2])
            i ≠ nsig && print(io, ", ")
        end
        print(io, ")")
        sig = String(take!(io))

        # Always produce URI-based links
        path = replace(m.file, "\\" => "\\\\")
        if isabspath(m.file)
            link = string(filepath2uri(m.file), "#", m.line)
            text = string(basename(path), ':', m.line)
        else
            text = string(path, ':', m.line)
            link = text
        end

        println(totalio, "$(method_count). `$(sig)` in `$(m.mod)` at [$(text)]($(link))\n")
        return false
    end

    documentation = string(
        documentation,
        "`$(f.name)` is a function with **$(method_count)** method$(method_count == 1 ? "" : "s")\n",
        String(take!(totalio))
    )

    return documentation
end

# --- Func/datatype hover for bindings referencing SymStore -------------------

_get_func_hover(x, documentation, expr, env, meta_dict) = documentation
_get_func_hover(x::SymbolServer.SymStore, documentation, expr, env, meta_dict) =
    _get_hover(x, documentation, expr, env, meta_dict)

# ============================================================================
# Closer hover (what does this `end`/`)`/`]` close?)
# ============================================================================

_get_closer_hover(x, documentation) = documentation
function _get_closer_hover(x::CSTParser.EXPR, documentation)
    if CSTParser.parentof(x) isa CSTParser.EXPR
        if CSTParser.headof(x) === :END
            if CSTParser.headof(CSTParser.parentof(x)) === :function
                documentation = string(documentation, "Closes function definition for `", CSTParser.to_codeobject(CSTParser.get_sig(CSTParser.parentof(x))), "`\n")
            elseif CSTParser.defines_module(CSTParser.parentof(x)) && length(CSTParser.parentof(x).args) > 1
                documentation = string(documentation, "Closes module definition for `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            elseif CSTParser.defines_struct(CSTParser.parentof(x))
                documentation = string(documentation, "Closes struct definition for `", CSTParser.to_codeobject(CSTParser.get_sig(CSTParser.parentof(x))), "`\n")
            elseif CSTParser.headof(CSTParser.parentof(x)) === :for && length(CSTParser.parentof(x).args) > 2
                documentation = string(documentation, "Closes for-loop expression over `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            elseif CSTParser.headof(CSTParser.parentof(x)) === :while && length(CSTParser.parentof(x).args) > 2
                documentation = string(documentation, "Closes while-loop expression over `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            else
                documentation = "Closes `$(CSTParser.headof(CSTParser.parentof(x)))` expression."
            end
        end
    end
    return documentation
end

# ============================================================================
# Function call position hover (argument N of M / datatype field)
# ============================================================================

_get_fcall_position(x, documentation, meta_dict) = documentation

function _get_fcall_position(x::CSTParser.EXPR, documentation, meta_dict, depth=0)
    # Guard against infinite loops via depth limit instead of Set{EXPR}
    depth > 100 && return documentation

    if CSTParser.parentof(x) isa CSTParser.EXPR
        if CSTParser.iscall(CSTParser.parentof(x))
            minargs, _, _ = StaticLint.call_nargs(CSTParser.parentof(x))
            arg_i = 0
            for (i, arg) in enumerate(CSTParser.parentof(x))
                if arg == x
                    arg_i = div(i - 1, 2)
                    break
                end
            end

            # hovering over the function name, so we might as well check the parent
            if arg_i == 0
                return _get_fcall_position(CSTParser.parentof(x), documentation, meta_dict, depth + 1)
            end

            minargs < 4 && return documentation

            fname = CSTParser.get_name(CSTParser.parentof(x))
            if StaticLint.hasref(fname, meta_dict) &&
               (StaticLint.refof(fname, meta_dict) isa StaticLint.Binding && StaticLint.refof(fname, meta_dict).val isa CSTParser.EXPR && CSTParser.defines_struct(StaticLint.refof(fname, meta_dict).val) && StaticLint.struct_nargs(StaticLint.refof(fname, meta_dict).val)[1] == minargs)
                dt_ex = StaticLint.refof(fname, meta_dict).val
                args = dt_ex.args[3]
                args.args === nothing || arg_i > length(args.args) && return documentation
                _fieldname = CSTParser.str_value(CSTParser.get_arg_name(args.args[arg_i]))
                documentation = string("Datatype field `$_fieldname` of $(CSTParser.str_value(CSTParser.get_name(dt_ex)))", "\n", documentation)
            elseif StaticLint.hasref(fname, meta_dict) && (StaticLint.refof(fname, meta_dict) isa SymbolServer.DataTypeStore || StaticLint.refof(fname, meta_dict) isa StaticLint.Binding && StaticLint.refof(fname, meta_dict).val isa SymbolServer.DataTypeStore)
                dts = StaticLint.refof(fname, meta_dict) isa StaticLint.Binding ? StaticLint.refof(fname, meta_dict).val : StaticLint.refof(fname, meta_dict)
                if length(dts.fieldnames) == minargs && arg_i <= length(dts.fieldnames)
                    documentation = string("Datatype field `$(dts.fieldnames[arg_i])`", "\n", documentation)
                end
            else
                callname = if CSTParser.is_getfield(fname)
                    CSTParser.str_value(fname.args[1]) * "." * CSTParser.str_value(CSTParser.get_rhs_of_getfield(fname))
                else
                    CSTParser.str_value(fname)
                end
                documentation = string("Argument $arg_i of $(minargs) in call to `", callname, "`\n", documentation)
            end
            return documentation
        else
            return _get_fcall_position(CSTParser.parentof(x), documentation, meta_dict, depth + 1)
        end
    end
    return documentation
end

# ============================================================================
# Top-level hover entry point (internal)
# ============================================================================

function _get_hover_text(rt, uri, index)
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst === nothing && return nothing

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

    offset = index - 1  # Convert 1-based string index to 0-based CSTParser offset
    x = get_expr1(cst, offset)

    x isa CSTParser.EXPR && CSTParser.isoperator(x) && _resolve_op_ref(x, env, meta_dict)
    documentation = _get_hover(x, "", x, env, meta_dict)
    documentation = _get_closer_hover(x, documentation)
    documentation = _get_fcall_position(x, documentation, meta_dict)
    documentation = _sanitize_docstring(documentation)

    return isempty(documentation) ? nothing : documentation
end

# ============================================================================
# Word-based documentation search
# ============================================================================

function _doc_search_score(needle::Symbol, haystack::Symbol)
    needle === haystack && return 0.0
    needle_s = lowercase(string(needle))
    haystack_s = lowercase(string(haystack))
    ldist = Float64(REPL.levenshtein(needle_s, haystack_s))
    if startswith(haystack_s, needle_s)
        ldist *= 0.5
    end
    return ldist
end

_traverse_store!(_, _) = return
_traverse_store!(f, store::SymbolServer.EnvStore) = _traverse_store!.(f, values(store))
function _traverse_store!(f, store::SymbolServer.ModuleStore)
    for (sym, val) in store.vals
        f(sym, val)
        _traverse_store!(f, val)
    end
end

function _get_doc_from_word(rt, word::AbstractString)
    matches = Pair{Float64, String}[]
    needle = Symbol(word)

    # Collect all unique environments from workspace roots
    seen_envs = Set{UInt64}()
    envs = StaticLint.ExternalEnv[]
    for root in derived_roots(rt)
        project_uri = derived_project_uri_for_root(rt, root)
        project_uri === nothing && continue
        env = derived_environment(rt, project_uri)
        env === nothing && continue
        eid = objectid(env.symbols)
        eid in seen_envs && continue
        push!(seen_envs, eid)
        push!(envs, env)
    end

    # Fallback to stdlibs if no environments available
    if isempty(envs)
        push!(envs, _empty_hover_env)
    end

    for env in envs
        symbols = env.symbols
        # Also include stdlibs if not already in the env
        stores = isempty(symbols) ? [SymbolServer.stdlibs] : [symbols]

        for store in stores
            _traverse_store!(store) do sym, val
                score = _doc_search_score(needle, sym)
                if score < 2
                    hover_text = _get_hover(val, "", nothing, env, _empty_hover_meta_dict)
                    if !isempty(hover_text)
                        push!(matches, score => hover_text)
                    end
                end
            end
        end
    end

    if isempty(matches)
        return "No results found."
    else
        return join(map(x -> x.second, sort!(unique!(matches), by = x -> x.first)[1:min(end, 25)]), "\n---\n")
    end
end
