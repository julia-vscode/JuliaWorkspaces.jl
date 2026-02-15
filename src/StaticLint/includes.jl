mutable struct IncludeOnly{RT} <: TraverseState
    uri::URI
    included_files::Set{URI}
    include_dict::Dict{UInt,URI}
    rt::RT
end

getpath(state::IncludeOnly) = URIs2.uri2filepath(state.uri)

IncludeOnly(uri, include_dict, rt) = IncludeOnly(uri, Set{URI}(), include_dict, rt)

"""
    get_path(x::EXPR)

Usually called on the argument to `include` calls, and attempts to determine
the path of the file to be included. Has limited support for `joinpath` calls.
"""
function get_path(x::EXPR, file_dir, meta_dict)
    if CSTParser.iscall(x) && length(x.args) == 2
        parg = x.args[2]

        if CSTParser.isstringliteral(parg)
            if occursin("\0", valof(parg))
                meta_dict !== nothing && seterror!(parg, IncludePathContainsNULL, meta_dict)
                return nothing
            end
            path = CSTParser.str_value(parg)
            path = normpath(path)
            Base.containsnul(path) && throw(SLInvalidPath("Couldn't convert '$x' into a valid path. Got '$path'"))
            return path
        elseif CSTParser.ismacrocall(parg) && valof(parg.args[1]) == "@raw_str" && CSTParser.isstringliteral(parg.args[3])
            if occursin("\0", valof(parg.args[3]))
                meta_dict !== nothing && seterror!(parg.args[3], IncludePathContainsNULL, meta_dict)
                return nothing
            end
            path = normpath(CSTParser.str_value(parg.args[3]))
            Base.containsnul(path) && throw(SLInvalidPath("Couldn't convert '$x' into a valid path. Got '$path'"))
            return path
        elseif CSTParser.iscall(parg) && isidentifier(parg.args[1]) && valofid(parg.args[1]) == "joinpath"
            path_elements = String[]

            for i = 2:length(parg.args)
                arg = parg[i]
                if _is_macrocall_to_BaseDIR(arg) # Assumes @__DIR__ points to Base macro.
                    push!(path_elements, file_dir)
                elseif CSTParser.isstringliteral(arg)
                    if occursin("\0", valof(arg))
                        meta_dict !== nothing && seterror!(arg, IncludePathContainsNULL, meta_dict)
                        return nothing
                    end
                    push!(path_elements, string(valof(arg)))
                else
                    return nothing
                end
            end
            isempty(path_elements) && return nothing

            path = normpath(joinpath(path_elements...))
            Base.containsnul(path) && throw(SLInvalidPath("Couldn't convert '$x' into a valid path. Got '$path'"))
            return path
        end
    end
    return nothing
end

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
                state.include_dict[objectid(x)] = can_uri
            end
        end
    elseif !(CSTParser.defines_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public)
        traverse(x, state)
    end

    return state
end

