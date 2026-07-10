# Miscellaneous feature layers
#
# Contains: document links (clickable string-literal paths), inlay hints
# (parameter names and variable types).
#
# All position parameters use 0-based byte offsets internally;
# the public API in public.jl converts 1-based string indices.

# ============================================================================
# Result types
# ============================================================================

"""
    struct DocumentLinkResult

A clickable link discovered in a source file (for example a path in a string
literal passed to `include`).

- `start::Position`: Start of the link's text range.
- `stop::Position`: End of the link's text range.
- `target_uri::URI`: The link target.
"""
struct DocumentLinkResult
    start::Position
    stop::Position
    target_uri::URI
end

"""
    struct InlayHintResult

A single inlay hint rendered inline in the editor.

- `position::Position`: Where the hint is anchored.
- `label::String`: Hint text.
- `kind::Symbol`: `:parameter` (a parameter name) or `:type` (an inferred type).
- `padding_left::Bool`: Whether to render padding before the hint.
- `padding_right::Bool`: Whether to render padding after the hint.
"""
struct InlayHintResult
    position::Position
    label::String
    kind::Symbol       # :parameter or :type
    padding_left::Bool
    padding_right::Bool
end

"""
    struct InlayHintConfig

Configuration controlling which inlay hints are produced.

- `enabled::Bool`: Master switch for inlay hints.
- `variable_types::Bool`: Whether to show inferred variable type hints.
- `parameter_names::Symbol`: Which parameter-name hints to show: `:all`,
  `:literals`, or `:nothing`.
"""
struct InlayHintConfig
    enabled::Bool
    variable_types::Bool
    parameter_names::Symbol   # :all, :literals, or :nothing
end

# ============================================================================
# Document links
# ============================================================================

function _find_document_links(x::CSTParser.EXPR, fpath::String, offset::Int, links::Vector{DocumentLinkResult}, st::SourceText)
    if CSTParser.isstringliteral(x)
        val = CSTParser.valof(x)
        if val isa String && isvalid(val) && sizeof(val) < 256
            try
                if isabspath(val) && safe_isfile(val)
                    push!(links, DocumentLinkResult(position_at(st, offset + 1), position_at(st, offset + x.span + 1), URIs2.filepath2uri(val)))
                elseif !isempty(fpath) && safe_isfile(joinpath(_dirname(fpath), val))
                    path = joinpath(_dirname(fpath), val)
                    push!(links, DocumentLinkResult(position_at(st, offset + 1), position_at(st, offset + x.span + 1), URIs2.filepath2uri(path)))
                end
            catch err
                isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
            end
        end
    end
    if x.args !== nothing
        for arg in x
            _find_document_links(arg, fpath, offset, links, st)
            offset += arg.fullspan
        end
    end
    return links
end

function _get_document_links(runtime, uri::URI)
    links = DocumentLinkResult[]
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    cst === nothing && return links
    fpath = something(URIs2.uri2filepath(uri), "")
    st = input_text_file(runtime, uri).content
    _find_document_links(cst, fpath, 0, links, st)
    return links
end

# ============================================================================
# Inlay hints
# ============================================================================

"""
    _get_inlay_parameter_hints(x, meta_dict, env, config, pos, st, name_cache)

Check whether EXPR `x` (which is an argument inside a call) should get a
parameter-name inlay hint.  Returns an `InlayHintResult` or `nothing`.
`name_cache` memoizes the per-call method matching across the call's
arguments.
"""
function _get_inlay_parameter_hints(x::CSTParser.EXPR, meta_dict::MetaDict, env, config::InlayHintConfig, pos::Int, st::SourceText, name_cache::IdDict{CSTParser.EXPR,Any})
    if config.parameter_names === :all || (config.parameter_names === :literals && CSTParser.isliteral(x))
        call = CSTParser.parentof(x)
        call.args === nothing && return nothing
        npos = count(i -> !(CSTParser.isparameters(call.args[i]) || CSTParser.iskwarg(call.args[i])), 2:length(call.args))
        npos < 2 && return nothing
        arg_i = _call_positional_arg_index(call, x)
        arg_i === nothing && return nothing
        names = get!(() -> _resolve_call_param_names(call, meta_dict, env), name_cache, call)
        names === nothing && return nothing
        label = _pick_call_arg_name(names, arg_i)
        label === nothing && return nothing
        length(label) <= 2 && return nothing
        CSTParser.str_value(x) == label && return nothing
        if CSTParser.headof(x) isa CSTParser.EXPR && CSTParser.headof(CSTParser.headof(x)) === :OPERATOR && CSTParser.valof(CSTParser.headof(x)) == "."
            if x.args !== nothing && !isempty(x.args) && x.args[end] isa CSTParser.EXPR &&
                    x.args[end].args !== nothing && !isempty(x.args[end].args) && x.args[end].args[end] isa CSTParser.EXPR
                CSTParser.valof(x.args[end].args[end]) == label && return nothing
            end
        end
        return InlayHintResult(position_at(st, pos + 1), string(label, "="), :parameter, false, false)
    end
    return nothing
end

"""
    _collect_inlay_hints(x, meta_dict, env, config, start, stop, pos, hints, name_cache)

Recursively walk the CST within range [start, stop] collecting inlay hints
for parameter names and variable types.
"""
function _collect_inlay_hints(x::CSTParser.EXPR, meta_dict::MetaDict, env, config::InlayHintConfig, start::Int, stop::Int, st::SourceText, pos::Int=0, hints::Vector{InlayHintResult}=InlayHintResult[], name_cache::IdDict{CSTParser.EXPR,Any}=IdDict{CSTParser.EXPR,Any}())
    # Parameter name hints: x is a call argument (not the callee)
    if CSTParser.parentof(x) isa CSTParser.EXPR &&
            CSTParser.iscall(CSTParser.parentof(x)) &&
            !(CSTParser.parentof(CSTParser.parentof(x)) isa CSTParser.EXPR && CSTParser.defines_function(CSTParser.parentof(CSTParser.parentof(x)))) &&
            CSTParser.parentof(x).args[1] != x
        maybe_hint = _get_inlay_parameter_hints(x, meta_dict, env, config, pos, st, name_cache)
        if maybe_hint !== nothing
            push!(hints, maybe_hint)
        end
    # Variable type hints: x is the LHS of an assignment with a binding
    elseif CSTParser.parentof(x) isa CSTParser.EXPR &&
            CSTParser.isassignment(CSTParser.parentof(x)) &&
            CSTParser.parentof(x).args[1] == x &&
            StaticLint.hasbinding(x, meta_dict)
        if config.variable_types
            typ = completion_type(StaticLint.bindingof(x, meta_dict))
            if typ !== missing
                push!(hints, InlayHintResult(position_at(st, pos + x.span + 1), string("::", typ), :type, false, false))
            end
        end
    end
    if length(x) > 0
        for a in x
            if pos < stop && pos + a.fullspan > start
                _collect_inlay_hints(a, meta_dict, env, config, start, stop, st, pos, hints, name_cache)
            end
            pos += a.fullspan
            pos > stop && break
        end
    end
    return hints
end

function _get_inlay_hints(runtime, uri::URI, start_offset::Int, end_offset::Int, config::InlayHintConfig)
    hints = InlayHintResult[]
    !config.enabled && return hints

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return hints

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict

    project_uri = derived_project_uri_for_root(runtime, root)
    env = derived_environment(runtime, project_uri)

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    cst === nothing && return hints

    st = input_text_file(runtime, uri).content

    return _collect_inlay_hints(cst, meta_dict, env, config, start_offset, end_offset, st, 0, hints)
end
