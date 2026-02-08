mutable struct IncludeOnly{RT} <: TraverseState
    uri::URI
    included_files::Set{URI}
    rt::RT
end

getpath(state::IncludeOnly) = URIs2.uri2filepath(state.uri)

IncludeOnly(uri, rt) = IncludeOnly(uri, Set{URI}(), rt)

import ..input_canonical_uri

function process_EXPR(x::EXPR, state::IncludeOnly)
    if (CSTParser.fcall_name(x) == "include" || CSTParser.fcall_name(x) == "includet") && length(x.args) == 2
        path = get_path(x, dirname(getpath(state)), nothing)

        if path!==nothing
            if !isabspath(path)
                parent_path = getpath(state)

                if parent_path === nothing
                    path = nothing
                else
                    path = joinpath(dirname(parent_path), path)
                end
            end

            if path!==nothing
                can_uri = input_canonical_uri(state.rt, filepath2uri(path))
                push!(state.included_files, can_uri)
            end
        end
    elseif !(CSTParser.defines_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public)
        traverse(x, state)
    end

    return state
end

