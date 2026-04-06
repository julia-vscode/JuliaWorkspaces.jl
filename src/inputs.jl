Salsa.@declare_input input_files(rt)::Set{URI}

Salsa.@declare_input input_text_file(rt, uri)::Union{TextFile,Nothing}

Salsa.@declare_input input_active_project(rt)::Union{URI,Nothing}

Salsa.@declare_input input_notebook_file(rt, uri)::NotebookFile

Salsa.@declare_input input_fallback_test_project(rt)::Union{URI,Nothing}

Salsa.@declare_input input_env_ready(rt)::Bool

Salsa.@declare_input input_project_environment(rt, uri, content_hash::UInt)::Nothing function(ctx, uri, content_hash)
    Base.@logmsg Trace "Lazy load environment for" uri=uri content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        put!(
            ctx.dynamic_feature.in_channel,
            (
                command = :watch_environment,
                project_path = uri2filepath(uri),
                content_hash = content_hash
            )
        )
    end

    return nothing
end

Salsa.@declare_input input_project_test_environment(rt, uri, package, content_hash::UInt)::Union{Nothing,URI} function(ctx, uri, package, content_hash)
    Base.@logmsg Trace "Lazy load test environment for project and package" uri=uri package=package content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        put!(
            ctx.dynamic_feature.in_channel,
            (
                command = :watch_test_environment,
                project_path = uri2filepath(uri),
                package = package,
                content_hash = content_hash
            )
        )
    end

    return nothing
end

Salsa.@declare_input input_standalone_package_project(rt, package_folder_uri, content_hash::UInt)::Union{Nothing,URI} function(ctx, package_folder_uri, content_hash)
    Base.@logmsg Trace "Lazy create standalone project for package" package_folder_uri=package_folder_uri content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        put!(
            ctx.dynamic_feature.in_channel,
            (
                command = :create_standalone_package_project,
                package_path = uri2filepath(package_folder_uri),
                content_hash = content_hash
            )
        )
    end

    return nothing
end

Salsa.@declare_input input_package_metadata(rt, name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{Nothing,String})::Union{SymbolServer.Package,Nothing} function(ctx, name, uuid, version, git_tree_sha1)


    if ctx.dynamic_feature !== nothing
        cache_path = joinpath(ctx.dynamic_feature.store_path, uppercase(string(name)[1:1]), string(name, "_", uuid), string("v", version, "_", git_tree_sha1, ".jstore"))

        if isfile(cache_path)
            package_data = open(cache_path) do io
                SymbolServer.CacheStore.read(io)
            end

            pkg_path = Base.locate_package(Base.PkgId(uuid, string(name)))

            # TODO Reenable this
            # if pkg_path === nothing || !isfile(pkg_path)
            #     pkg_path = SymbolServer.get_pkg_path(Base.PkgId(uuid, pe_name), environment_path, ctx.dynamic_feature.depot_path)
            # end

            if pkg_path !== nothing
                SymbolServer.modify_dirs(package_data.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", joinpath(pkg_path, "src")))
            end

            # @info "Lazy load package metadata for" name uuid version git_tree_sha1 cache_path

            return package_data
        else
            push!(ctx.dynamic_feature.missing_pkg_metadata, @NamedTuple{name::Symbol,uuid::UUID,version::VersionNumber,git_tree_sha1::Union{String,Nothing}}((name,uuid,version,git_tree_sha1)))
            # @info "Queued package metadata loading" name uuid version git_tree_sha1
            return nothing
        end
    end

    Base.@logmsg Trace "No package metadata loading because dynamic feature is off" name=name uuid=uuid version=version git_tree_sha1=git_tree_sha1

    return nothing
end
