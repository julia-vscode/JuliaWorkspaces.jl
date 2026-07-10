# Signature help layer
#
# Provides signature help (parameter hints) for function calls.
# All position parameters use 0-based byte offsets internally;
# the public API in public.jl converts 1-based string indices.

# ============================================================================
# Result types
# ============================================================================

"""
    struct ParameterInfo

Describes a single parameter of a function signature in signature help.

- `label::String`: The parameter's textual label as it appears in the signature.
- `documentation::Union{String,Nothing}`: Optional documentation for the parameter.
"""
struct ParameterInfo
    label::String
    documentation::Union{String,Nothing}
end

"""
    struct SignatureInfo

Describes a single callable signature in a signature-help result.

- `label::String`: The full signature rendered as text.
- `documentation::String`: Documentation for the signature.
- `parameters::Vector{ParameterInfo}`: The signature's parameters in order.
"""
struct SignatureInfo
    label::String
    documentation::String
    parameters::Vector{ParameterInfo}
end

"""
    struct SignatureResult

The result of a signature-help request at a call site.

- `signatures::Vector{SignatureInfo}`: Candidate signatures for the call.
- `active_signature::Int`: Index of the signature to highlight.
- `active_parameter::Int`: Index of the parameter to highlight.
"""
struct SignatureResult
    signatures::Vector{SignatureInfo}
    active_signature::Int
    active_parameter::Int
end

# ============================================================================
# Internal helpers
# ============================================================================

"""
    _fcall_arg_number(x)

Count which argument position the cursor is at within a function call.
"""
function _fcall_arg_number(x)
    if CSTParser.headof(x) === :LPAREN
        0
    else
        sum(CSTParser.headof(a) === :COMMA for a in CSTParser.parentof(x).trivia)
    end
end

"""
    _collect_signatures(x, meta_dict, env, runtime)

Given an EXPR `x` inside a call, collect all signature information for the
called function.
"""
function _collect_signatures(x, meta_dict::MetaDict, env, runtime)
    sigs = SignatureInfo[]

    if x isa CSTParser.EXPR && CSTParser.parentof(x) isa CSTParser.EXPR && CSTParser.iscall(CSTParser.parentof(x))
        parent_call = CSTParser.parentof(x)
        if CSTParser.isidentifier(parent_call.args[1])
            call_name = parent_call.args[1]
        elseif CSTParser.iscurly(parent_call.args[1]) && CSTParser.isidentifier(parent_call.args[1].args[1])
            call_name = parent_call.args[1].args[1]
        elseif CSTParser.is_getfield_w_quotenode(parent_call.args[1])
            call_name = parent_call.args[1].args[2].args[1]
        else
            call_name = nothing
        end
        if call_name !== nothing &&
                (f_binding = StaticLint.refof(call_name, meta_dict)) !== nothing &&
                (tls = _retrieve_toplevel_scope(call_name, meta_dict)) !== nothing
            _get_signatures(f_binding, tls, sigs, env, meta_dict)
        end
    end

    return sigs
end

# Fallback
function _get_signatures(b, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict) end

function _get_signatures(b::StaticLint.Binding, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict)
    if b.val isa StaticLint.Binding
        _get_signatures(b.val, tls, sigs, env, meta_dict)
    end
    if b.type == StaticLint.CoreTypes.Function || b.type == StaticLint.CoreTypes.DataType
        b.val isa SymbolServer.SymStore && _get_signatures(b.val, tls, sigs, env, meta_dict)
        for ref in b.refs
            method = StaticLint.get_method(ref)
            if method !== nothing
                _get_signatures(method, tls, sigs, env, meta_dict)
            end
        end
    end
end

function _get_signatures(b::T, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict) where T <: Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        push!(sigs, SignatureInfo(
            string(m),
            "",
            [ParameterInfo(string(a[1]), string(a[2])) for a in m.sig]
        ))
        return false
    end)
end

function _get_signatures(x::CSTParser.EXPR, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict)
    if CSTParser.defines_function(x)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
        params = ParameterInfo[]
        if sig isa CSTParser.EXPR && sig.args !== nothing
            for i = 2:length(sig.args)
                argbinding = StaticLint.bindingof(sig.args[i], meta_dict)
                if argbinding !== nothing
                    label = CSTParser.valof(argbinding.name) isa String ? CSTParser.valof(argbinding.name) : ""
                    push!(params, ParameterInfo(label, nothing))
                end
            end
            push!(sigs, SignatureInfo(string(CSTParser.to_codeobject(sig)), "", params))
        end
    elseif CSTParser.defines_struct(x)
        args = x.args[3]
        if length(args) > 0
            if !any(CSTParser.defines_function, args.args)
                params = ParameterInfo[]
                for field in args.args
                    field_name = CSTParser.rem_decl(field)
                    label = field_name isa CSTParser.EXPR && CSTParser.isidentifier(field_name) ? CSTParser.valof(field_name) : ""
                    push!(params, ParameterInfo(label, nothing))
                end
                push!(sigs, SignatureInfo(string(CSTParser.to_codeobject(x)), "", params))
            end
        end
    end
end

# ============================================================================
# Call-site method matching (parameter names for hover)
# ============================================================================

"""
    struct _CallCandidate

One candidate method for a call site: positional parameter `names` (`""` when
unknown), comparable declared `types` (`nothing` when undeclared or vararg),
and the `func_nargs`-style `counts` tuple used for arity matching.
"""
struct _CallCandidate
    names::Vector{String}
    types::Vector{Any}
    counts::Tuple{Int,Int,Vector{Symbol},Bool}
end

function _push_param!(names::Vector{String}, types::Vector{Any}, arg::CSTParser.EXPR, meta_dict::MetaDict)
    inner = CSTParser.iskwarg(arg) ? arg.args[1] : arg
    b = StaticLint.bindingof(arg, meta_dict)
    b === nothing && (b = StaticLint.bindingof(inner, meta_dict))
    if b isa StaticLint.Binding && CSTParser.valof(b.name) isa String
        push!(names, CSTParser.valof(b.name))
        push!(types, CSTParser.issplat(inner) ? nothing : b.type)
    else
        nm = CSTParser.get_arg_name(inner)
        nmval = nm isa CSTParser.EXPR ? CSTParser.str_value(nm) : nothing
        push!(names, nmval isa String ? nmval : "")
        push!(types, nothing)
    end
    return nothing
end

function _push_call_candidate!(candidates::Vector{_CallCandidate}, x::CSTParser.EXPR, env, meta_dict::MetaDict)
    if CSTParser.defines_function(x)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
        (sig isa CSTParser.EXPR && sig.args !== nothing) || return nothing
        names = String[]
        types = Any[]
        for i in 2:length(sig.args)
            arg = StaticLint.unwrap_nospecialize(sig.args[i])
            CSTParser.isparameters(arg) && continue
            _push_param!(names, types, arg, meta_dict)
        end
        push!(candidates, _CallCandidate(names, types, StaticLint.func_nargs(x, env, meta_dict)))
    elseif CSTParser.defines_struct(x)
        args = x.args[3]
        args.args === nothing && return nothing
        inner_constructors = findall(CSTParser.defines_function, args.args)
        if !isempty(inner_constructors)
            for i in inner_constructors
                _push_call_candidate!(candidates, args.args[i], env, meta_dict)
            end
        else
            names = String[]
            types = Any[]
            for field in args.args
                _push_param!(names, types, field, meta_dict)
            end
            push!(candidates, _CallCandidate(names, types, StaticLint.struct_nargs(x, env, meta_dict)))
        end
    end
    return nothing
end

function _push_ss_call_candidates!(candidates::Vector{_CallCandidate}, b::Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}, tls::StaticLint.Scope, env)
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        names = String[]
        types = Any[]
        for p in m.sig
            push!(names, string(first(p)))
            t = last(p)
            push!(types, StaticLint.CoreTypes.isva(t) ? nothing : t)
        end
        push!(candidates, _CallCandidate(names, types, StaticLint.func_nargs(m)))
        return false
    end)
    return nothing
end

function _collect_call_candidates!(candidates::Vector{_CallCandidate}, b, tls::StaticLint.Scope, env, meta_dict::MetaDict, depth::Int=0)
    depth > 20 && return nothing
    if b isa StaticLint.Binding
        b.val isa StaticLint.Binding && _collect_call_candidates!(candidates, b.val, tls, env, meta_dict, depth + 1)
        if b.type == StaticLint.CoreTypes.Function || b.type == StaticLint.CoreTypes.DataType
            b.val isa Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore} && _push_ss_call_candidates!(candidates, b.val, tls, env)
            for ref in b.refs
                method = StaticLint.get_method(ref)
                if method isa CSTParser.EXPR
                    _push_call_candidate!(candidates, method, env, meta_dict)
                elseif method isa Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
                    _push_ss_call_candidates!(candidates, method, tls, env)
                end
            end
        end
    elseif b isa Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
        _push_ss_call_candidates!(candidates, b, tls, env)
    end
    return nothing
end

# Cheap type of a call argument: literals and identifiers with a known binding
# type. `nothing` means unknown and matches any parameter type.
function _call_arg_type(x::CSTParser.EXPR, meta_dict::MetaDict)
    h = CSTParser.headof(x)
    h === :INTEGER && return StaticLint.CoreTypes.Int
    h === :FLOAT && return StaticLint.CoreTypes.Float64
    h === :CHAR && return StaticLint.CoreTypes.Char
    h === :TRUE && return StaticLint.CoreTypes.Bool
    h === :FALSE && return StaticLint.CoreTypes.Bool
    CSTParser.isstringliteral(x) && return StaticLint.CoreTypes.String
    if CSTParser.isidentifier(x) || CSTParser.is_getfield_w_quotenode(x)
        r = CSTParser.isidentifier(x) ? StaticLint.refof(x, meta_dict) : StaticLint.refof_maybe_getfield(x, meta_dict)
        r isa StaticLint.Binding && return r.type
    end
    return nothing
end

"""
    _resolve_call_arg_name(call, arg_i, meta_dict, env)

Name of positional parameter `arg_i` of the method that best matches `call`:
candidates are filtered by arity, then by type compatibility of the call
arguments whose types are cheaply inferable. Returns `nothing` when no
matching method provides a usable name.
"""
function _resolve_call_arg_name(call::CSTParser.EXPR, arg_i::Int, meta_dict::MetaDict, env)
    # hover must never throw
    try
        return _resolve_call_arg_name_impl(call, arg_i, meta_dict, env)
    catch
        return nothing
    end
end

function _resolve_call_arg_name_impl(call::CSTParser.EXPR, arg_i::Int, meta_dict::MetaDict, env)
    callee = call.args[1]
    call_name = if CSTParser.isidentifier(callee)
        callee
    elseif CSTParser.iscurly(callee) && CSTParser.isidentifier(callee.args[1])
        callee.args[1]
    elseif CSTParser.is_getfield_w_quotenode(callee)
        callee.args[2].args[1]
    else
        nothing
    end
    call_name === nothing && return nothing
    f_binding = StaticLint.refof(call_name, meta_dict)
    f_binding === nothing && return nothing
    tls = _retrieve_toplevel_scope(call_name, meta_dict)
    tls === nothing && return nothing

    candidates = _CallCandidate[]
    _collect_call_candidates!(candidates, f_binding, tls, env, meta_dict)

    call_counts = StaticLint.call_nargs(call)
    filter!(c -> StaticLint.compare_f_call(c.counts, call_counts), candidates)
    isempty(candidates) && return nothing

    argtypes = Any[]
    for i in 2:length(call.args)
        arg = call.args[i]
        (CSTParser.isparameters(arg) || CSTParser.iskwarg(arg)) && continue
        push!(argtypes, CSTParser.issplat(arg) ? nothing : _call_arg_type(arg, meta_dict))
    end

    store = StaticLint.getsymbols(env)
    compatible = filter(candidates) do c
        all(enumerate(argtypes)) do (k, at)
            at === nothing && return true
            k <= length(c.types) || return true
            pt = c.types[k]
            pt === nothing && return true
            return StaticLint._has_type_intersection(at, pt, store, meta_dict)
        end
    end

    for c in (isempty(compatible) ? candidates : compatible)
        1 <= arg_i <= length(c.names) || continue
        name = c.names[arg_i]
        (isempty(name) || startswith(name, "#") || name == "_") && continue
        return name
    end
    return nothing
end

# ============================================================================
# Top-level entry point
# ============================================================================

"""
    _get_signature_help(runtime, uri, offset)

Core signature help logic: find all matching signatures for the function call
at `offset` (0-based) in the file identified by `uri`.
"""
function _get_signature_help(runtime, uri::URI, offset::Int)
    empty_result = SignatureResult(SignatureInfo[], 0, 0)

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return empty_result

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    project_uri = derived_project_uri_for_root(runtime, root)
    env = derived_environment(runtime, project_uri)

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = _get_expr(cst, offset)

    sigs = _collect_signatures(x, meta_dict, env, runtime)

    if isempty(sigs) || (x isa CSTParser.EXPR && CSTParser.headof(x) === :RPAREN)
        return empty_result
    end

    arg = _fcall_arg_number(x)

    filtered = filter(s -> length(s.parameters) > arg, sigs)
    return SignatureResult(filtered, 0, arg)
end
