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
# Call-site method matching (parameter names for hover and inlay hints)
# ============================================================================

# Positional index of `x` among the call's arguments, skipping the
# `;`-parameters block and inline kwargs. Returns `nothing` when `x` is not a
# positional argument, or when a splat at/before its position makes the
# mapping to declared parameters unknowable.
function _call_positional_arg_index(call::CSTParser.EXPR, x::CSTParser.EXPR)
    call.args === nothing && return nothing
    idx = 0
    for i in 2:length(call.args)
        a = call.args[i]
        (CSTParser.isparameters(a) || CSTParser.iskwarg(a)) && continue
        CSTParser.issplat(a) && return nothing
        idx += 1
        a == x && return idx
    end
    return nothing
end

function _sig_param_name(arg::CSTParser.EXPR, meta_dict::MetaDict)
    arg = StaticLint.unwrap_nospecialize(arg)
    inner = CSTParser.iskwarg(arg) ? arg.args[1] : arg
    b = StaticLint.bindingof(arg, meta_dict)
    b === nothing && (b = StaticLint.bindingof(inner, meta_dict))
    if b isa StaticLint.Binding && CSTParser.valof(b.name) isa String
        return CSTParser.valof(b.name)
    end
    nm = CSTParser.get_arg_name(inner)
    nmval = nm isa CSTParser.EXPR ? CSTParser.str_value(nm) : nothing
    return nmval isa String ? nmval : ""
end

# Positional parameter names of a matched method as `(names, vararg)`, where
# `vararg` says the last name is a trailing vararg; `nothing` when they can't
# be derived.
_method_param_names(m, meta_dict::MetaDict) = nothing

function _method_param_names(m::SymbolServer.MethodStore, meta_dict::MetaDict)
    names = String[string(first(p)) for p in m.sig]
    va = !isempty(m.sig) && StaticLint.CoreTypes.isva(last(m.sig)[2])
    return (names, va)
end

function _method_param_names(m::CSTParser.EXPR, meta_dict::MetaDict)
    if CSTParser.defines_function(m)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(m))
        (sig isa CSTParser.EXPR && sig.args !== nothing) || return nothing
        names = String[]
        va = false
        for i in 2:length(sig.args)
            arg = sig.args[i]
            CSTParser.isparameters(arg) && continue
            push!(names, _sig_param_name(arg, meta_dict))
            inner = StaticLint.unwrap_nospecialize(arg)
            va = CSTParser.issplat(inner) || StaticLint.is_explicit_vararg_decl(inner)
        end
        return (names, va)
    elseif CSTParser.defines_struct(m)
        args = m.args[3]
        args.args === nothing && return nothing
        inner = findfirst(CSTParser.defines_function, args.args)
        inner !== nothing && return _method_param_names(args.args[inner], meta_dict)
        return (String[_sig_param_name(field, meta_dict) for field in args.args], false)
    end
    return nothing
end

"""
    _resolve_call_param_names(call, meta_dict, env)

Positional parameter-name lists of the methods matching `call` (arity- and
type-checked by `StaticLint.find_methods`, the same matcher the
`IncorrectCallArgs` lint semantics build on). Returns `nothing` when the
callee or no matching method resolves. Never throws.
"""
function _resolve_call_param_names(call::CSTParser.EXPR, meta_dict::MetaDict, env)
    try
        methods = StaticLint.find_methods(call, StaticLint.getsymbols(env), meta_dict)
        names = Tuple{Vector{String},Bool}[]
        for m in methods
            ns = _method_param_names(m, meta_dict)
            ns === nothing || push!(names, ns)
        end
        return isempty(names) ? nothing : names
    catch
        return nothing
    end
end

_usable_param_name(name::String) = !(isempty(name) || startswith(name, "#") || name == "_")

# First usable name at position `arg_i` among the matched methods' parameter
# lists, as `(; name, vararg, slot)`: `vararg` says the position binds the
# trailing vararg whose declared position is `slot`.
function _pick_call_arg_name(names::Vector{Tuple{Vector{String},Bool}}, arg_i::Int)
    arg_i < 1 && return nothing
    for (ns, va) in names
        isempty(ns) && continue
        if arg_i <= length(ns)
            name = ns[arg_i]
            _usable_param_name(name) || continue
            return (name = name, vararg = va && arg_i == length(ns), slot = length(ns))
        elseif va
            name = last(ns)
            _usable_param_name(name) || continue
            return (name = name, vararg = true, slot = length(ns))
        end
    end
    return nothing
end

"""
    _resolve_call_arg_name(call, x, meta_dict, env)

Name of the positional parameter that call argument `x` supplies, from the
methods matching `call`, as `(; name, vararg, slot)` (see
`_pick_call_arg_name`). Returns `nothing` when no matching method provides a
usable name. Never throws.
"""
function _resolve_call_arg_name(call::CSTParser.EXPR, x::CSTParser.EXPR, meta_dict::MetaDict, env)
    arg_i = _call_positional_arg_index(call, x)
    arg_i === nothing && return nothing
    names = _resolve_call_param_names(call, meta_dict, env)
    names === nothing && return nothing
    return _pick_call_arg_name(names, arg_i)
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
