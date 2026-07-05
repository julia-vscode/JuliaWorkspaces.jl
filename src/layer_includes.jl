"""
    derived_file_include_data(rt, uri)

Single fused include analysis for one file, memoised per URI. Runs one CST walk
that produces all three include products at once:

  - `edges` — the file's resolved include-graph edges,
  - `include_dict` — `objectid`→target map for the semantic pass, and
  - `records` — `(offset, span, target)` tuples for include diagnostics.

The three are exposed through the thin selectors below. Keeping the selectors
separate is what preserves Salsa's early-exit: `include_dict` churns on every
reparse (objectids are fresh), but `derived_includes` /
`derived_file_include_records` back-date whenever the edges/records compare equal.
"""
Salsa.@derived function derived_file_include_data(rt, uri)
    @debug "derived_file_include_data" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return (edges=Set{URI}(), include_dict=Dict{UInt64,URI}(), records=Tuple{Int,Int,Union{URI,Nothing}}[])

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    # `file_path` may be `nothing` (an unsaved buffer): absolute include paths
    # still resolve, relative ones come back as `nothing` targets.
    file_path = uri2filepath(uri)

    return StaticLint.collect_include_analysis(cst, file_path)
end

Salsa.@derived function derived_includes(rt, uri)
    return derived_file_include_data(rt, uri).edges
end

Salsa.@derived function derived_include_dict(rt, uri)
    return derived_file_include_data(rt, uri).include_dict
end

Salsa.@derived function derived_all_julia_files(rt)
    files_to_check = copy(derived_julia_files(rt))

    all_files = Set{URI}()

    while !isempty(files_to_check)
        uri = first(files_to_check)
        delete!(files_to_check, uri)
        
        push!(all_files, uri)

        included_files = derived_includes(rt, uri)

        for included_file in included_files
            if !derived_has_content(rt, included_file)
                continue
            end
            if !(included_file in all_files) && !(included_file in files_to_check)
                push!(files_to_check, included_file)
            end
        end
    end

    return all_files
end

"""
    derived_include_closure(rt, uri)

The transitive include closure of `uri` (including `uri` itself): every file
reachable from `uri` through `include(...)` edges whose content is available.
This is the set of files a semantic pass starting at `uri` can traverse, and the
only files whose lint state a root rooted at `uri` ever depends on.

Built by BFS over the per-file, value-stable `derived_includes`, so it depends
only on the include structure of files *within* the closure — an edit to a file
outside the closure never invalidates it. Files without content (unresolved or
missing include targets) are skipped, matching `derived_all_julia_files`. The
visited set makes self- and cyclic includes terminate.
"""
Salsa.@derived function derived_include_closure(rt, uri)
    @debug "derived_include_closure" uri=uri

    closure = Set{URI}([uri])
    queue = URI[uri]

    while !isempty(queue)
        current = popfirst!(queue)

        for included in derived_includes(rt, current)
            included in closure && continue
            derived_has_content(rt, included) || continue
            push!(closure, included)
            push!(queue, included)
        end
    end

    return closure
end

"""
    derived_indirect_files(rt)

Return the set of URIs in the include graph that are *not* regular workspace
files — i.e. files reached only via `include(...)` traversal whose content was
loaded through the lazy `input_indirect_text_file` input.
"""
Salsa.@derived function derived_indirect_files(rt)
    all_files = derived_all_julia_files(rt)

    return Set{URI}(uri for uri in all_files if !derived_has_file(rt, uri))
end

Salsa.@derived function derived_is_indirect_file(rt, uri)
    return uri in derived_indirect_files(rt)
end

Salsa.@derived function derived_roots(rt)
    @debug "derived_roots"

    all_files = derived_all_julia_files(rt)

    all_files_included_somewhere = Set{URI}()

    for uri in all_files
        for included_uri in derived_includes(rt, uri)
            push!(all_files_included_somewhere, included_uri)
        end
    end

    roots = setdiff(all_files, all_files_included_somewhere)

    return roots
end

"""
    derived_roots_for_uri(rt, uri)

Return the set of roots whose include tree contains `uri`.
If `uri` is itself a root, it will be included in the result.
"""
Salsa.@derived function derived_roots_for_uri(rt, uri)
    @debug "derived_roots_for_uri" uri=uri

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
                for inc in derived_includes(rt, current)
                    if inc == uri
                        found = true
                        break
                    end
                    if !(inc in visited)
                        push!(queue, inc)
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
    return derived_file_include_data(rt, uri).records
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
