Salsa.@derived function derived_environment(rt, uri)
    project = derived_project(rt, uri)
    
    metadata_packages = SymbolServer.Package[]
    for (k,v) in project.regular_packages
        x = input_package_metadata(rt, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1)
        if x!==nothing
            push!(metadata_packages, x)
        end
    end

    for (k,v) in project.stdlib_packages
        x = input_package_metadata(rt, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), nothing)
        if x!==nothing
            push!(metadata_packages, x)
        end
    end

    new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)

    for i in metadata_packages
        new_store[Symbol(i.name)] = i.val
    end

    @info "The env for $uri is" keys(new_store)

    return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), collect(keys(new_store)))
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)    
    active_project = input_active_project(rt)

    package_folder_uri = derived_package_for_file(rt, uri)

    if package_folder_uri!==nothing
        package_folder = uri2filepath(package_folder_uri)
        runtests_path = joinpath(package_folder, "test", "runtests.jl")

        @info "Now testing whether we have runtests.jl" lowercase(uri2filepath(uri)) lowercase(runtests_path)

        # TODO Is this lowercase the right move? On Windows for sure, not clear about other platforms
        if lowercase(uri2filepath(uri)) == lowercase(runtests_path)
            package_name = derived_package(rt, package_folder_uri).name

            test_project_uri = input_project_test_environment(rt, active_project, package_name)

            @info "And the thing here is" test_project_uri

            if test_project_uri !== nothing
                @info "For $uri we are returning $test_project_uri as the test project."
                return test_project_uri
            end
        end
    end

    @info "For $uri we are returning $active_project as the project."

    # TODO This needs to handle multi env
    return active_project
end
