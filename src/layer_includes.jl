Salsa.@derived function derived_includes(rt, uri)
    cst = derived_julia_legacy_syntax_tree(rt, uri)

    state = StaticLint.IncludeOnly(uri, rt)
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

    files_to_check = derived_julia_files(rt)
    files_already_checked = Set{URI}()

    while !isempty(files_to_check)
        current_file = first(files_to_check)
        delete!(files_to_check, current_file)
        push!(files_already_checked, current_file)

        for included_file in derived_includes(rt, current_file)
            push!(all_files_included_somewhere, included_file)

            if !(included_file in files_already_checked) && !(included_file in files_to_check)
                push!(files_to_check, included_file)
            end
        end
    end

    roots = setdiff(files_already_checked, all_files_included_somewhere)

    return roots
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)
    # TODO This needs to handle multi env
    return input_active_project(rt)
end
