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

# Whether `cond` is an existence test that commonly guards an `include`:
# mentions `isfile`/`ispath`/`isdefined` or `@isdefined` anywhere.
function _is_include_guard(cond::EXPR)
    if isidentifier(cond)
        v = valofid(cond)
        return v == "isfile" || v == "ispath" || v == "isdefined" || v == "@isdefined"
    end
    cond.args === nothing && return false
    return any(a -> a isa EXPR && _is_include_guard(a), cond.args)
end

# Whether `x` is a call to one of the TestItems.jl macros that run their body in
# a fresh module at runtime (`@testitem`, `@testmodule`, `@testsnippet`), in
# either the bare or the qualified `Mod.@testitem` form. `@testset`/
# `@safetestset` are deliberately not included: they do not introduce a module,
# so includes inside them share the enclosing file structure.
function _is_testitem_family_macrocall(x::EXPR)
    CSTParser.ismacrocall(x) || return false
    (x.args === nothing || isempty(x.args)) && return false
    name = x.args[1]
    name isa EXPR || return false
    return _is_testitem_macro(name) || _is_testmodule_macro(name) || _is_testsnippet_macro(name)
end

# Shared walker for include-call analyses. Calls `f(x, pos, target, in_function,
# guarded, testitem_ctx)` for every `include(...)`/`includet(...)` call, where
# `pos` is the 0-based byte offset of the call EXPR, `target` the resolved target
# `URI` or `nothing`, and `guarded` whether the call sits under an
# existence-guarded conditional (see below). `testitem_ctx` is `nothing` for
# ordinary calls, or the byte offset of the enclosing testitem-family macrocall
# for a call inside one — each such body is its own module at runtime, so
# duplicate-include detection scopes to it instead of to the include graph as a
# whole. `file_dir` may be `nothing` (a file without a filesystem path, e.g. an
# unsaved buffer), in which case only absolute include paths resolve.
#
# Calls inside function/macro bodies are reported with `in_function = true` and
# always `target = nothing`: a runtime `include` splices into whichever module
# the enclosing function is called from, so even a literal path has no static
# splice context — it must never become an include-graph edge, but it IS the
# "file structure not statically resolvable" signal (ComputedInclude). The
# *signature* of such a definition is excluded, so custom `include` methods
# (`include(p::AbstractPath) = ...`, FilePathsBase-style) are not reported.
function _walk_include_calls(f, x::EXPR, file_dir, pos, in_function::Bool=false, skip::Union{Nothing,EXPR}=nothing, guarded::Bool=false, testitem_ctx::Union{Nothing,Int}=nothing)
    x === skip && return nothing

    if (CSTParser.fcall_name(x) == "include" || CSTParser.fcall_name(x) == "includet") && length(x.args) == 2
        target = nothing
        if !in_function
            path = get_path(x, file_dir, nothing)
            if path !== nothing
                if isabspath(path)
                    target = filepath2uri(path)
                elseif file_dir !== nothing
                    target = filepath2uri(joinpath(file_dir, path))
                end
            end
        end

        f(x, pos, target, in_function, guarded, testitem_ctx)
    elseif CSTParser.defines_function(x) || CSTParser.defines_macro(x)
        sig = try
            CSTParser.get_sig(x)
        catch
            nothing
        end
        # `get_sig` returns the `where` wrapper for `f(x) where T` — unwrap to
        # the call node so identity comparison excludes the signature itself.
        while sig isa EXPR && headof(sig) === :where && sig.args !== nothing && !isempty(sig.args)
            sig = sig.args[1]
        end

        p = pos
        for i in 1:length(x)
            _walk_include_calls(f, x[i], file_dir, p, true, sig, guarded, testitem_ctx)
            p += x[i].fullspan
        end
    elseif !(headof(x) === :export || headof(x) === :public)
        # A conditional whose test mentions an existence/definedness check
        # (`isfile(deps) && include(deps)`, `@isdefined(X) || include("x.jl")`,
        # `if isfile(cfg) include(cfg) else include("default.jl") end`) makes
        # file structure runtime-dependent. The condition isn't evaluated
        # statically, so no arm is judged: every child except the condition
        # itself descends with `guarded = true` and the diagnostics pass
        # abstains from MissingFile/DuplicateInclude/ComputedInclude there.
        # The graph edges are unaffected.
        cond = nothing
        if headof(x) in (:if, :elseif) && x.args !== nothing && length(x.args) >= 1 &&
                x.args[1] isa EXPR && _is_include_guard(x.args[1])
            cond = x.args[1]
        elseif isbinarysyntax(x) && (valof(headof(x)) == "&&" || valof(headof(x)) == "||") &&
                length(x.args) == 2 && x.args[1] isa EXPR && _is_include_guard(x.args[1])
            cond = x.args[1]
        end

        # Each testitem-family body is evaluated in a fresh module, so includes
        # below this point belong to that module rather than to the enclosing
        # file. Nested testitems keep the outermost context: the inner body is
        # part of the same runtime module.
        child_ctx = testitem_ctx === nothing && _is_testitem_family_macrocall(x) ? pos : testitem_ctx

        p = pos
        for i in 1:length(x)
            child_guarded = guarded || (cond !== nothing && x[i] !== cond)
            _walk_include_calls(f, x[i], file_dir, p, in_function, skip, child_guarded, child_ctx)
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
    _walk_include_calls(cst, _include_file_dir(file_path), 0) do x, pos, target, in_function, _, _
        # Top-level calls only, matching this function's historical contract;
        # function-body (runtime) includes are an analysis signal, not part of
        # the include graph.
        in_function || push!(results, (pos, x.span, target))
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
  - `records::Vector` — `(offset, span, target, guarded, testitem_ctx)` tuples
    for every include call (including unresolved ones), in source order, for
    include-graph diagnostics. `guarded` marks calls under an existence guard
    (`isfile`/`isdefined`/`@isdefined` condition): they are conditional at
    runtime, so MissingFile/DuplicateInclude/ComputedInclude are not reported
    for them. `testitem_ctx` is the offset of the enclosing testitem-family
    macrocall (`@testitem`/`@testmodule`/`@testsnippet`) for calls inside one
    and `nothing` otherwise, so duplicate detection can scope to that body.
  - `computed_ids::Set{UInt64}` — the `objectid`s of include-call EXPRs whose
    path could NOT be determined statically (computed includes), for the
    semantic pass to mark the enclosing module scope. Same lifetime caveat as
    `include_dict`.
"""
function collect_include_analysis(cst::EXPR, file_path::Union{Nothing,String})
    edges = Set{URI}()
    include_dict = Dict{UInt64,URI}()
    records = Tuple{Int,Int,Union{URI,Nothing},Bool,Union{Nothing,Int}}[]
    computed_ids = Set{UInt64}()
    _walk_include_calls(cst, _include_file_dir(file_path), 0) do x, pos, target, _, guarded, testitem_ctx
        # Function-body includes carry `target === nothing` by construction
        # (see `_walk_include_calls`), so they land in `records` as computed
        # includes — ComputedInclude diagnostics + suppression signals — but
        # never become include-graph edges.
        push!(records, (pos, x.span, target, guarded, testitem_ctx))
        if target !== nothing
            push!(edges, target)
            include_dict[UInt64(objectid(x))] = target
        else
            push!(computed_ids, UInt64(objectid(x)))
        end
    end
    return (; edges, include_dict, records, computed_ids)
end

