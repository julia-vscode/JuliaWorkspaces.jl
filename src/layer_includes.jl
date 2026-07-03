"""
    derived_uri2included(rt)

The workspace include graph: maps each Julia file in the graph (regular files
plus files reached transitively via `include(...)`) to the set of files it
includes. Built entirely from the per-file
[`derived_file_include_records`](@ref) queries, so its value only changes when
the actual include *structure* changes — ordinary edits leave it `isequal` and
Salsa's early-exit spares all downstream consumers.
"""
Salsa.@derived function derived_uri2included(rt)
    @debug "derived_uri2included"

    files_to_check = copy(derived_julia_files(rt))
    uri2included = Dict{URI,Set{URI}}()

    while !isempty(files_to_check)
        uri = first(files_to_check)
        delete!(files_to_check, uri)
        uri2included[uri] = Set{URI}()

        for (_, _, target) in derived_file_include_records(rt, uri)
            target === nothing && continue

            tf = derived_text_file_content(rt, target)
            if tf === nothing
                continue
            end
            if !haskey(uri2included, target) && !(target in files_to_check)
                push!(files_to_check, target)
            end
            push!(uri2included[uri], target)
        end
    end

    return uri2included
end

Salsa.@derived function derived_includes(rt, uri)
    uri2included = derived_uri2included(rt)

    return uri2included[uri]
end

Salsa.@derived function derived_all_julia_files(rt)
    uri2included = derived_uri2included(rt)

    return Set{URI}(keys(uri2included))
end

"""
    derived_indirect_files(rt)

Return the set of URIs in the include graph that are *not* regular workspace
files — i.e. files reached only via `include(...)` traversal whose content was
loaded through the lazy `input_indirect_text_file` input.
"""
Salsa.@derived function derived_indirect_files(rt)
    uri2included = derived_uri2included(rt)

    return Set{URI}(uri for uri in keys(uri2included) if !derived_has_file(rt, uri))
end

Salsa.@derived function derived_is_indirect_file(rt, uri)
    return uri in derived_indirect_files(rt)
end

Salsa.@derived function derived_roots(rt)
    @debug "derived_roots"

    uri2included = derived_uri2included(rt)

    all_files_included_somewhere = Set{URI}()

    for uri in keys(uri2included)
        for included_uri in uri2included[uri]
            push!(all_files_included_somewhere, included_uri)
        end
    end

    roots = setdiff(keys(uri2included), all_files_included_somewhere)

    return roots
end

"""
    derived_roots_for_uri(rt, uri)

Return the set of roots whose include tree contains `uri`.
If `uri` is itself a root, it will be included in the result.
"""
Salsa.@derived function derived_roots_for_uri(rt, uri)
    @debug "derived_roots_for_uri" uri=uri

    uri2included = derived_uri2included(rt)
    roots = derived_roots(rt)

    result = Set{URI}()

    for root in roots
        if root == uri
            push!(result, root)
            continue
        end

        # BFS from root through include tree
        visited = Set{URI}()
        queue = URI[root]
        found = false
        while !isempty(queue) && !found
            current = popfirst!(queue)
            current in visited && continue
            push!(visited, current)
            if haskey(uri2included, current)
                for inc in uri2included[current]
                    if inc == uri
                        found = true
                        break
                    end
                    if !(inc in visited)
                        push!(queue, inc)
                    end
                end
            end
        end

        if found
            push!(result, root)
        end
    end

    return result
end

"""
    derived_best_root_for_uri(rt, uri)

Return the single "best" root for a given URI. Prefers package src/ roots
over test roots. Returns `nothing` if the URI is not part of any root's
include tree.
"""
Salsa.@derived function derived_best_root_for_uri(rt, uri)
    roots = derived_roots_for_uri(rt, uri)
    isempty(roots) && return nothing
    length(roots) == 1 && return first(roots)

    # Prefer roots that are NOT test files
    non_test = filter(r -> !contains(string(r), "/test/"), roots)
    if !isempty(non_test)
        return first(non_test)
    end

    return first(roots)
end

"""
    derived_file_include_records(rt, uri)

Return the ordered list of `include(...)` call records for the file `uri` as
`(offset, span, target_uri)` tuples. `target_uri` is the resolved include target
(or `nothing` when the path could not be determined statically). The records are
in source order, which the include-graph diagnostics rely on to flag the
*repeated* `include` rather than the first one.
"""
Salsa.@derived function derived_file_include_records(rt, uri)
    @debug "derived_file_include_records" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return Tuple{Int,Int,Union{URI,Nothing}}[]

    # A `nothing` file path (e.g. an unsaved buffer) still resolves absolute
    # include paths; relative ones come back as `nothing` targets.
    file_path = uri2filepath(uri)

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    return StaticLint.collect_include_calls(cst, file_path)
end

function _include_diagnostic(offset, span, code)
    rng = (offset + 1):(offset + span + 1)
    description = StaticLint.LintCodeDescriptions[code]
    return Diagnostic(rng, :warning, description, nothing, Symbol[], "StaticLint.jl")
end

function _collect_include_diagnostics!(rt, uri, stack, visited, result)
    push!(stack, uri)

    for (offset, span, target) in derived_file_include_records(rt, uri)
        target === nothing && continue

        if derived_text_file_content(rt, target) === nothing
            push!(get!(result, uri, Diagnostic[]), _include_diagnostic(offset, span, StaticLint.MissingFile))
            continue
        end

        if target in stack
            push!(get!(result, uri, Diagnostic[]), _include_diagnostic(offset, span, StaticLint.IncludeLoop))
            continue
        end

        if target in visited
            push!(get!(result, uri, Diagnostic[]), _include_diagnostic(offset, span, StaticLint.DuplicateInclude))
            continue
        end

        push!(visited, target)
        _collect_include_diagnostics!(rt, target, stack, visited, result)
    end

    pop!(stack)

    return result
end

"""
    derived_all_include_diagnostics(rt)

Compute include-graph diagnostics (`DuplicateInclude`, `IncludeLoop`,
`MissingFile`) for the whole workspace, keyed by the URI of the file that
contains the offending `include(...)` statement.

This is a purely structural analysis over the include graph and does not depend
on a project/environment, so it is reported even for files that are not part of
a package.
"""
Salsa.@derived function derived_all_include_diagnostics(rt)
    @debug "derived_all_include_diagnostics"

    result = Dict{URI,Vector{Diagnostic}}()

    for root in derived_roots(rt)
        stack = URI[]
        visited = Set{URI}([root])
        _collect_include_diagnostics!(rt, root, stack, visited, result)
    end

    # The same statement can be reached from multiple roots; deduplicate.
    for ds in values(result)
        unique!(ds)
    end

    return result
end

Salsa.@derived function derived_include_diagnostics(rt, uri)
    all_diags = derived_all_include_diagnostics(rt)

    return get(all_diags, uri, Diagnostic[])
end
