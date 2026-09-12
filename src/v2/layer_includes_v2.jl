# v2 root discovery: the include graph, roots, and the reverse map — built
# entirely from v2 skeletons (`V2Include` rows + `derived_v2_include_target`),
# replacing the borrow of v1's `derived_roots_for_uri` that routed through
# CSTParser + StaticLint's include collector.
#
# Semantics mirror v1's layer_includes.jl deliberately:
#   - include lists are VALUE-STABLE across content-only edits, so the one
#     shared reverse-map node backdates on typical keystrokes and cuts
#     invalidation off for every per-file query below it;
#   - the reverse map is the single node that depends on every file's include
#     list — per-file queries walk it upward instead of forward-walking from
#     every root, which would record O(workspace) dependencies per file;
#   - visited sets make self- and cyclic includes terminate.
#
# Known deliberate gap vs v1: only LITERAL include paths resolve
# (`derived_v2_include_target`); v1's collector additionally resolves some
# computed includes through StaticLint. The differential test ratchets any
# corpus divergence this causes.

"""
    derived_v2_file_includes(rt, uri) -> Set{URI}

The resolved include targets of `uri`, from the skeleton's `V2Include` rows.
Computed paths contribute nothing. Value-stable across edits that do not
change the include list.
"""
Salsa.@derived function derived_v2_file_includes(rt, uri)
    out = Set{URI}()
    for inc in derived_v2_file_skeleton(rt, uri).includes
        target = derived_v2_include_target(rt, uri, inc.path)
        target === nothing || push!(out, target)
    end
    return out
end

"""
    derived_v2_all_julia_files(rt) -> Set{URI}

Every Julia file in the include graph: the regular workspace files plus
indirect files reached through `include(...)` edges (whose content loads via
the lazy indirect-file input). Mirrors v1's `derived_all_julia_files`.
"""
Salsa.@derived function derived_v2_all_julia_files(rt)
    files_to_check = copy(derived_julia_files(rt))
    all_files = Set{URI}()

    while !isempty(files_to_check)
        uri = first(files_to_check)
        delete!(files_to_check, uri)
        push!(all_files, uri)

        for included in derived_v2_file_includes(rt, uri)
            derived_has_content(rt, included) || continue
            if !(included in all_files) && !(included in files_to_check)
                push!(files_to_check, included)
            end
        end
    end

    return all_files
end

"Files no other file includes: the entry points of the include forest."
Salsa.@derived function derived_v2_roots(rt)
    all_files = derived_v2_all_julia_files(rt)

    included_somewhere = Set{URI}()
    for uri in all_files
        union!(included_somewhere, derived_v2_file_includes(rt, uri))
    end

    return setdiff(all_files, included_somewhere)
end

"""
    derived_v2_reverse_include_map(rt) -> Dict{URI,Set{URI}}

The inverted include graph (child → including parents). The ONE shared node
that depends on every file's include list; see the header for why per-file
queries depend on this instead of the forward graph.
"""
Salsa.@derived function derived_v2_reverse_include_map(rt)
    result = Dict{URI,Set{URI}}()
    for uri in derived_v2_all_julia_files(rt)
        for included in derived_v2_file_includes(rt, uri)
            push!(get!(Set{URI}, result, included), uri)
        end
    end
    return result
end

"""
    derived_v2_roots_for_uri(rt, uri) -> Set{URI}

The roots whose include tree contains `uri` (including `uri` itself when it is
a root). Upward walk over the reverse map with a visited set, so cycles
terminate.
"""
Salsa.@derived function derived_v2_roots_for_uri(rt, uri)
    reverse_map = derived_v2_reverse_include_map(rt)
    roots = derived_v2_roots(rt)

    ancestors = Set{URI}([uri])
    queue = URI[uri]
    while !isempty(queue)
        current = popfirst!(queue)
        parents = get(reverse_map, current, nothing)
        parents === nothing && continue
        for parent in parents
            parent in ancestors && continue
            push!(ancestors, parent)
            push!(queue, parent)
        end
    end

    return intersect(ancestors, roots)
end

"""
    derived_v2_best_root_for_uri(rt, uri) -> Union{Nothing,URI}

One deterministic root for single-answer consumers: prefers non-`/test/` roots
(a file reachable from both `src/Pkg.jl` and `test/runtests.jl` should read as
part of the package), ties broken by URI order for determinism.
"""
Salsa.@derived function derived_v2_best_root_for_uri(rt, uri)
    roots = derived_v2_roots_for_uri(rt, uri)
    isempty(roots) && return nothing
    length(roots) == 1 && return first(roots)

    non_test = filter(r -> !contains(string(r), "/test/"), roots)
    pool = isempty(non_test) ? roots : non_test
    return first(sort!(collect(pool); by=string))
end
