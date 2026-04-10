Salsa.@derived function derived_environment(rt, uri)
    @debug "derived_environment" uri=uri

    project = derived_project(rt, uri)

    if project === nothing
        new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)
        return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), collect(keys(new_store)))
    end

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

    project_deps = collect(keys(new_store))

    # Add in-workspace deved packages to project_deps so import resolution considers them valid
    for (k,v) in project.deved_packages
        entry_uri = filepath2uri(joinpath(uri2filepath(v.uri), "src", "$(v.name).jl"))
        if derived_has_file(rt, entry_uri)
            push!(project_deps, Symbol(v.name))
        end
    end

    return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), project_deps)
end

Salsa.@derived function derived_workspace_deved_packages(rt, project_uri)
    @debug "derived_workspace_deved_packages" project_uri=project_uri

    project = derived_project(rt, project_uri)
    project === nothing && return Dict{String, URI}()

    result = Dict{String, URI}()
    for (k, v) in project.deved_packages
        entry_uri = filepath2uri(joinpath(uri2filepath(v.uri), "src", "$(v.name).jl"))
        if derived_has_file(rt, entry_uri)
            result[v.name] = entry_uri
        end
    end
    return result
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)
    @debug "derived_project_uri_for_root" uri=uri

    active_project = input_active_project(rt)

    package_folder_uri = derived_package_for_file(rt, uri)

    if package_folder_uri!==nothing
        package_folder = uri2filepath(package_folder_uri)
        runtests_path = joinpath(package_folder, "test", "runtests.jl")

        pkg = derived_package(rt, package_folder_uri)
        pkg_content_hash = pkg === nothing ? UInt(0) : pkg.content_hash

        # TODO Is this lowercase the right move? On Windows for sure, not clear about other platforms
        if lowercase(uri2filepath(uri)) == lowercase(runtests_path)
            package_name = pkg.name

            project_for_test_env = if package_folder_uri in derived_project_folders(rt)
                package_folder_uri
            else
                # Check if there's a standalone project for this package
                standalone_uri = input_standalone_package_project(rt, package_folder_uri, pkg_content_hash)
                if standalone_uri !== nothing
                    standalone_uri
                else
                    active_project
                end
            end

            if project_for_test_env !== nothing
                test_env_project = derived_project(rt, project_for_test_env)
                test_env_hash = test_env_project === nothing ? UInt(0) : test_env_project.content_hash
                test_project_uri = input_project_test_environment(rt, project_for_test_env, package_name, test_env_hash)

                if test_project_uri !== nothing
                    return test_project_uri
                end
            end
        end

        # If the file belongs to a workspace package, use the package's own project
        if package_folder_uri in derived_project_folders(rt)
            return package_folder_uri
        end

        # If the package is not a project (no manifest) and not dev'd into any workspace project,
        # trigger creation of a standalone project for it
        if !_is_package_deved_in_workspace(rt, package_folder_uri)
            standalone_uri = input_standalone_package_project(rt, package_folder_uri, pkg_content_hash)
            if standalone_uri !== nothing
                return standalone_uri
            end
        end
    end

    # TODO This needs to handle multi env
    return active_project
end

function _is_package_deved_in_workspace(rt, package_folder_uri)
    for project_folder_uri in derived_project_folders(rt)
        project = derived_project(rt, project_folder_uri)
        project === nothing && continue
        for (_, v) in project.deved_packages
            if v.uri == package_folder_uri
                return true
            end
        end
    end
    return false
end

Salsa.@derived function derived_required_dynamic_projects(rt)
    @debug "derived_required_dynamic_projects"

    required = Set{DJPKey}()

    # Every project folder needs a :watch_environment DJP
    for project_uri in derived_project_folders(rt)
        project = derived_project(rt, project_uri)
        project === nothing && continue
        push!(required, DJPKey((
            project_path = uri2filepath(project_uri),
            package = nothing,
            content_hash = project.content_hash
        )))
    end

    # Package folders that aren't project folders and aren't deved need a standalone project DJP
    for package_uri in derived_package_folders(rt)
        package_uri in derived_project_folders(rt) && continue
        _is_package_deved_in_workspace(rt, package_uri) && continue

        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue
        push!(required, DJPKey((
            project_path = uri2filepath(package_uri),
            package = nothing,
            content_hash = pkg.content_hash
        )))
    end

    # Test environments: for each package folder with a test/runtests.jl, the test env DJP
    for package_uri in derived_package_folders(rt)
        package_folder = uri2filepath(package_uri)
        runtests_path = joinpath(package_folder, "test", "runtests.jl")
        isfile(runtests_path) || continue

        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue

        # Determine which project provides the test environment
        project_for_test = if package_uri in derived_project_folders(rt)
            package_uri
        elseif !_is_package_deved_in_workspace(rt, package_uri)
            # Would use standalone project
            package_uri
        else
            input_active_project(rt)
        end
        project_for_test === nothing && continue

        proj = derived_project(rt, project_for_test)
        proj_hash = proj === nothing ? UInt(0) : proj.content_hash

        push!(required, DJPKey((
            project_path = uri2filepath(project_for_test),
            package = pkg.name,
            content_hash = proj_hash
        )))
    end

    return required
end
