Salsa.@derived function derived_all_includes(rt)
    files_to_check = copy(derived_julia_files(rt))
    uri2included = Dict{URI,Set{URI}}()

    include_dict = Dict{UInt64, URI}()

    while !isempty(files_to_check)
        uri = first(files_to_check)
        delete!(files_to_check, uri)
        uri2included[uri] = Set{URI}()

        cst = derived_julia_legacy_syntax_tree(rt, uri)
        state = StaticLint.IncludeOnly(uri, include_dict, rt)
        StaticLint.process_EXPR(cst, state)

        for included_file in state.included_files
            if !haskey(uri2included, included_file) && !(included_file in files_to_check)
                push!(files_to_check, included_file)
            end
            push!(uri2included[uri], included_file)
        end
    end

    return uri2included, include_dict
end

Salsa.@derived function derived_includes(rt, uri)
    uri2includ, _ = derived_all_includes(rt)

    return uri2includ[uri]
end

Salsa.@derived function derived_all_julia_files(rt)
    uri2included, _ = derived_all_includes(rt)

    all_files = Set{URI}()

    for (uri, included) in uri2included
        push!(all_files, uri)
    end

    return all_files
end

Salsa.@derived function derived_include_dict(rt)
    _, include_dict = derived_all_includes(rt)

    return include_dict
end

Salsa.@derived function derived_roots(rt)
    uri2included, include_dict = derived_all_includes(rt)

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
    uri2included, _ = derived_all_includes(rt)
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
