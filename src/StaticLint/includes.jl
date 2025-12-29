mutable struct IncludeOnly <: State
    uri::URI
    included_files::Vector{URI}
end

getpath(state::IncludeOnly) = URIs2.uri2filepath(state.uri)

IncludeOnly(uri) = IncludeOnly(uri, URI[])

function (state::IncludeOnly)(x::EXPR, meta_dict, rt)
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
                push!(state.included_files, filepath2uri(path))
            end
        end
    elseif !(CSTParser.defines_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public)
        traverse(x, state, meta_dict, rt)
    end

    return state
end

