Salsa.@derived function derived_includes(rt, uri)
    cst = derived_julia_legacy_syntax_tree(rt, uri)

    state = StaticLint.IncludeOnly(uri)
    StaticLint.process_EXPR(cst, state)

    return state.included_files
end

Salsa.@derived function derived_all_includes(rt)
    julia_files = derived_julia_files(rt)

    includes = Dict{URI,Any}()

    for i in julia_files
        includes[i] = derived_includes(rt, i)
    end

    return includes
end

Salsa.@derived function derived_roots(rt)
    all_files_included_somewhere = Set{URI}()

    julia_files = derived_julia_files(rt)

    for i in julia_files
        for j in derived_includes(rt, i)
            push!(all_files_included_somewhere, j)
        end
    end

    roots = setdiff(julia_files, all_files_included_somewhere)

    return roots
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)
    # TODO This needs to handle multi env
    return input_active_project(rt)
end
