function _stdlib_only_env()
    new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)
    return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), collect(keys(new_store)))
end

# ─── Per-key readiness wrappers ──────────────────────────────────────────────
#
# These memoized derived functions expose the per-key readiness state held in
# the `input_ready_*` collection inputs. Reading the collection directly from a
# gate would make *every* readiness query depend on the single collection
# input, so any update would invalidate all of them. By funnelling each key
# through its own derived function, Salsa's early-cutoff means a collection
# update only invalidates downstream queries whose specific key's result
# actually changed — restoring fine-grained invalidation.

"""
    derived_project_environment_ready(rt, project_uri, content_hash) -> Bool

Whether the environment for `project_uri` (at `content_hash`) has been indexed.
"""
Salsa.@derived function derived_project_environment_ready(rt, project_uri, content_hash::UInt64)
    key = WatchEnvironmentKey(uri2filepath(project_uri), content_hash)
    return key in input_ready_project_environments(rt)
end

"""
    derived_ready_test_environment(rt, project_uri, package, content_hash) -> Union{Nothing,URI}

The ready test-project URI for `project_uri` + `package`, or `nothing` if the
test environment has not been indexed yet.
"""
Salsa.@derived function derived_ready_test_environment(rt, project_uri, package, content_hash::UInt64)
    key = WatchTestEnvironmentKey(uri2filepath(project_uri), package, content_hash)
    return get(input_ready_test_environments(rt), key, nothing)
end

"""
    derived_ready_standalone_project(rt, package_folder_uri, content_hash) -> Union{Nothing,URI}

The created standalone-project URI for `package_folder_uri`, or `nothing` if it
has not been created yet.
"""
Salsa.@derived function derived_ready_standalone_project(rt, package_folder_uri, content_hash::UInt64)
    key = CreateStandaloneProjectKey(uri2filepath(package_folder_uri), content_hash)
    return get(input_standalone_projects(rt), key, nothing)
end

# Salsa-memoized stdlib-only env. Sharing a single env instance is required
# because `SymbolServer` stores compare by identity: refs resolved against this
# env during the semantic pass must point at the same instance that later
# read-only queries (hover, completions, tests) retrieve.
Salsa.@derived function derived_stdlib_only_env(rt)
    @debug "derived_stdlib_only_env"
    return _stdlib_only_env()
end

Salsa.@derived function derived_environment(rt, uri)
    @debug "derived_environment" uri=uri

    project = derived_project(rt, uri)

    if project === nothing
        return _stdlib_only_env()
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

    # Check if the file is inside a project folder (has both Project.toml and Manifest.toml).
    # If this project folder is more specific (deeper) than the enclosing package folder,
    # use it directly. This handles cases like benchmark/ sub-projects that aren't packages
    # but define their own environment.
    project_folder_uri = derived_project_for_file(rt, uri)
    package_folder_uri = derived_package_for_file(rt, uri)

    if project_folder_uri !== nothing
        project_is_more_specific = package_folder_uri === nothing ||
            length(uri2filepath(project_folder_uri)) > length(uri2filepath(package_folder_uri))
        if project_is_more_specific
            return project_folder_uri
        end
    end

    if package_folder_uri!==nothing
        package_folder = uri2filepath(package_folder_uri)
        runtests_path = joinpath(package_folder, "test", "runtests.jl")

        pkg = derived_package(rt, package_folder_uri)
        pkg_content_hash = pkg === nothing ? UInt64(0) : pkg.content_hash

        # TODO Is this lowercase the right move? On Windows for sure, not clear about other platforms
        file_needs_test_env = lowercase(uri2filepath(uri)) == lowercase(runtests_path) ||
            _file_has_testitems(rt, uri)

        if file_needs_test_env
            package_name = pkg.name

            project_for_test_env = if package_folder_uri in derived_project_folders(rt)
                package_folder_uri
            else
                # Check if there's a standalone project for this package
                standalone_uri = derived_ready_standalone_project(rt, package_folder_uri, pkg_content_hash)
                if standalone_uri !== nothing
                    standalone_uri
                else
                    active_project
                end
            end

            if project_for_test_env !== nothing
                test_env_project = derived_project(rt, project_for_test_env)
                test_env_hash = test_env_project === nothing ? UInt64(0) : test_env_project.content_hash
                test_project_uri = derived_ready_test_environment(rt, project_for_test_env, package_name, test_env_hash)

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
            standalone_uri = derived_ready_standalone_project(rt, package_folder_uri, pkg_content_hash)
            if standalone_uri !== nothing
                return standalone_uri
            end
        else
            # Package IS deved in a workspace project (possibly the standalone project
            # that was created for it) — find and return that project
            deving_project = _find_deving_project(rt, package_folder_uri)
            if deving_project !== nothing
                return deving_project
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

function _find_deving_project(rt, package_folder_uri)
    for project_folder_uri in derived_project_folders(rt)
        project = derived_project(rt, project_folder_uri)
        project === nothing && continue
        for (_, v) in project.deved_packages
            if v.uri == package_folder_uri
                return project_folder_uri
            end
        end
    end
    return nothing
end

"""
    derived_file_env_ready(rt, uri)

Return true if this file's effective environment is ready for static-lint
analysis that depends on environment data (e.g. missing-reference checks).

Per-project gating: each file's *own* project must have completed dynamic
indexing (the corresponding `:environment_ready` /
`:standalone_package_project_ready` / `:test_environment_ready` message has
been consumed). The legacy global `input_env_ready` flag is honored as a
manual override for tests.

Files that need a test environment (`test/runtests.jl` or files with
`@testitem`) additionally require the test-env DJP to have produced a merged
test project URI before we consider their env "ready". Otherwise missing-ref
diagnostics for test-only deps (TestItemRunner, Test, @testitem, @test, …)
would flash as false positives until indexing finishes.
"""
Salsa.@derived function derived_file_env_ready(rt, uri)
    # Determine the file's effective project URI and require its env to have
    # been processed. The legacy global flag (settable in tests) acts as an
    # override that pretends every project's env is ready.
    project_uri = derived_project_uri_for_root(rt, uri)
    if project_uri !== nothing
        project = derived_project(rt, project_uri)
        project_hash = project === nothing ? UInt64(0) : project.content_hash
        if !derived_project_environment_ready(rt, project_uri, project_hash) && !input_env_ready(rt)
            return false
        end
    end

    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing && return true

    pkg = derived_package(rt, package_folder_uri)
    pkg === nothing && return true
    pkg_content_hash = pkg.content_hash

    runtests_path = joinpath(uri2filepath(package_folder_uri), "test", "runtests.jl")
    file_needs_test_env = lowercase(uri2filepath(uri)) == lowercase(runtests_path) ||
        _file_has_testitems(rt, uri)
    file_needs_test_env || return true

    project_for_test_env = if package_folder_uri in derived_project_folders(rt)
        package_folder_uri
    else
        standalone = derived_ready_standalone_project(rt, package_folder_uri, pkg_content_hash)
        standalone !== nothing ? standalone : input_active_project(rt)
    end
    project_for_test_env === nothing && return true

    test_env_project = derived_project(rt, project_for_test_env)
    test_env_hash = test_env_project === nothing ? UInt64(0) : test_env_project.content_hash
    return derived_ready_test_environment(rt, project_for_test_env, pkg.name, test_env_hash) !== nothing
end

"""
    _file_has_testitems(rt, uri)

Check whether a file contains `@testitem` macros by looking at the
already-computed test item detection results (which use JuliaSyntax, not CSTParser).
"""
function _file_has_testitems(rt, uri)
    try
        details = derived_testitems(rt, uri)
        return !isempty(details.testitems)
    catch
        return false
    end
end

Salsa.@derived function derived_required_dynamic_projects(rt)
    @debug "derived_required_dynamic_projects"

    required = Set{DJPKey}()

    # Every project folder needs a :watch_environment DJP
    for project_uri in derived_project_folders(rt)
        project = derived_project(rt, project_uri)
        project === nothing && continue
        push!(required, WatchEnvironmentKey(
            uri2filepath(project_uri),
            project.content_hash,
        ))
    end

    # Package folders that aren't project folders and aren't deved need a standalone project DJP
    for package_uri in derived_package_folders(rt)
        package_uri in derived_project_folders(rt) && continue
        _is_package_deved_in_workspace(rt, package_uri) && continue

        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue
        push!(required, CreateStandaloneProjectKey(
            uri2filepath(package_uri),
            pkg.content_hash,
        ))
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
        proj_hash = proj === nothing ? UInt64(0) : proj.content_hash

        push!(required, WatchTestEnvironmentKey(
            uri2filepath(project_for_test),
            pkg.name,
            proj_hash,
        ))
    end

    return required
end
