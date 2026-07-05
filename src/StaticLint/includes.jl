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
                arg = parg.args[i]
                if _is_macrocall_to_BaseDIR(arg) # Assumes @__DIR__ points to Base macro.
                    file_dir === nothing && return nothing
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

# Shared walker for include-call analyses. Calls `f(x, pos, target)` for every
# `include(...)`/`includet(...)` call, where `pos` is the 0-based byte offset of
# the call EXPR and `target` the resolved target `URI` or `nothing`. `file_dir`
# may be `nothing` (a file without a filesystem path, e.g. an unsaved buffer), in
# which case only absolute include paths resolve.
function _walk_include_calls(f, x::EXPR, file_dir, pos)
    if (CSTParser.fcall_name(x) == "include" || CSTParser.fcall_name(x) == "includet") && length(x.args) == 2
        path = get_path(x, file_dir, nothing)

        target = nothing
        if path !== nothing
            if isabspath(path)
                target = filepath2uri(path)
            elseif file_dir !== nothing
                target = filepath2uri(joinpath(file_dir, path))
            end
        end

        f(x, pos, target)
    elseif !(CSTParser.defines_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public)
        p = pos
        for i in 1:length(x)
            _walk_include_calls(f, x[i], file_dir, p)
            p += x[i].fullspan
        end
    end

    return nothing
end

_include_file_dir(file_path) = file_path === nothing ? nothing : dirname(file_path)

"""
    collect_include_calls(cst::EXPR, file_path::Union{Nothing,String})

Walk `cst` and return a vector of `(offset, span, target_uri)` tuples, one for
each `include(...)`/`includet(...)` call. `offset` is the 0-based byte offset of
the call EXPR within the file and `span` its span. `target_uri` is the resolved
target `URI` (normalised, relative paths joined to the file's directory) or
`nothing` when the path could not be determined statically.

Records the position of every include call (including those that point at
non-existent files) so that include-graph diagnostics can be attached to the
offending statement. A `nothing` `file_path` (a file without a filesystem path,
e.g. an unsaved buffer) still resolves absolute include paths.
"""
function collect_include_calls(cst::EXPR, file_path::Union{Nothing,String})
    results = Tuple{Int,Int,Union{URI,Nothing}}[]
    _walk_include_calls(cst, _include_file_dir(file_path), 0) do x, pos, target
        push!(results, (pos, x.span, target))
    end
    return results
end

"""
    collect_include_analysis(cst::EXPR, file_path::Union{Nothing,String})

Single-pass include analysis for one file. Walks `cst` once and returns a
`NamedTuple` with three products:

  - `edges::Set{URI}` — the resolved include targets (the file's include-graph
    edges).
  - `include_dict::Dict{UInt64,URI}` — maps the `objectid` of each resolved
    include-call EXPR to its target, for use by the semantic pass while
    traversing this exact CST instance. These objectids are only valid for the
    CST they were built from and must not outlive it.
  - `records::Vector` — `(offset, span, target)` tuples for every include call
    (including unresolved ones), in source order, for include-graph diagnostics.
"""
function collect_include_analysis(cst::EXPR, file_path::Union{Nothing,String})
    edges = Set{URI}()
    include_dict = Dict{UInt64,URI}()
    records = Tuple{Int,Int,Union{URI,Nothing}}[]
    _walk_include_calls(cst, _include_file_dir(file_path), 0) do x, pos, target
        push!(records, (pos, x.span, target))
        if target !== nothing
            push!(edges, target)
            include_dict[UInt64(objectid(x))] = target
        end
    end
    return (; edges, include_dict, records)
end

