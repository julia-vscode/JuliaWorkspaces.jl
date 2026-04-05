# Signature help layer
#
# Provides signature help (parameter hints) for function calls.
# All position parameters use 0-based byte offsets internally;
# the public API in public.jl converts 1-based string indices.

# ============================================================================
# Result types
# ============================================================================

struct ParameterInfo
    label::String
    documentation::Union{String,Nothing}
end

struct SignatureInfo
    label::String
    documentation::String
    parameters::Vector{ParameterInfo}
end

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
        sig = CSTParser.rem_where_decl(CSTParser.get_sig(x))
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
