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
    _collect_signatures(x, meta_dict, env, runtime; match_call=false)

Given an EXPR `x` inside a call, collect all signature information for the
called function. When `match_call` is true, only signatures whose method is
type-compatible with the call's arguments are collected — used by inlay hints
to pick the actually-called overload rather than the first one of matching
arity.
"""
function _collect_signatures(x, meta_dict::MetaDict, env, runtime; match_call::Bool=false)
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
            matcher = nothing
            if match_call
                store = StaticLint.getsymbols(env)
                args, kws = StaticLint.call_arg_types(parent_call, false, meta_dict, store)
                matcher = m -> StaticLint.match_method(args, kws, m, store, meta_dict)
            end
            _get_signatures(f_binding, tls, sigs, env, meta_dict, matcher)
        end
    end

    return sigs
end

# Fallback
function _get_signatures(b, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, matcher=nothing) end

function _get_signatures(b::StaticLint.Binding, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, matcher=nothing)
    if b.val isa StaticLint.Binding
        _get_signatures(b.val, tls, sigs, env, meta_dict, matcher)
    end
    if b.type == StaticLint.CoreTypes.Function || b.type == StaticLint.CoreTypes.DataType
        b.val isa SymbolServer.SymStore && _get_signatures(b.val, tls, sigs, env, meta_dict, matcher)
        for ref in b.refs
            method = StaticLint.get_method(ref)
            if method !== nothing
                _get_signatures(method, tls, sigs, env, meta_dict, matcher)
            end
        end
    end
end

function _get_signatures(b::T, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, matcher=nothing) where T <: Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        if matcher === nothing || matcher(m)
            push!(sigs, SignatureInfo(
                string(m),
                "",
                [ParameterInfo(string(a[1]), string(a[2])) for a in m.sig]
            ))
        end
        return false
    end)
end

function _get_signatures(x::CSTParser.EXPR, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, matcher=nothing)
    if CSTParser.defines_function(x)
        (matcher === nothing || matcher(x)) || return
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
        (matcher === nothing || matcher(x)) || return
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
