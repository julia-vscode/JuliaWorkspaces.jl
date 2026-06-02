Salsa.@declare_input input_files(rt)::Set{URI}

Salsa.@declare_input input_text_file(rt, uri)::Union{TextFile,Nothing}

Salsa.@declare_input input_active_project(rt)::Union{URI,Nothing}

Salsa.@declare_input input_notebook_file(rt, uri)::NotebookFile

Salsa.@declare_input input_env_ready(rt)::Bool

# Lazy input for files that are pulled in via `include(...)` from a regular
# JW file but are not themselves regular files. Initial content is read
# synchronously from disc; the watcher callback (if any) is invoked once per
# URI so the LS can register an LSP file watcher to feed future updates back
# in via `set_input_indirect_text_file!`.
Salsa.@declare_input input_indirect_text_file(rt, uri)::Union{TextFile,Nothing} function(ctx, uri)
    @debug "Lazy load indirect file" uri=uri

    if ctx.indirect_file_watch_callback !== nothing
        try
            ctx.indirect_file_watch_callback(uri)
        catch err
            @error "indirect_file_watch_callback threw" exception=(err, catch_backtrace())
        end
    end

    content = if uri.scheme != "file"
        nothing
    else
        try
            read_text_file_from_uri(uri, return_nothing_on_io_error=true)
        catch err
            @debug "Failed to read indirect file from disc" uri=uri exception=(err, catch_backtrace())
            nothing
        end
    end

    return content
end

# Returns `true` once the environment for this project has been fully
# processed by the dynamic feature (i.e. the per-project `:environment_ready`
# message has been consumed). The lazy default is `false`, which both queues
# the indexing work and signals to gates like `derived_file_env_ready` that
# environment-dependent diagnostics for files belonging to this project are
# not yet trustworthy.
Salsa.@declare_input input_project_environment(rt, uri, content_hash::UInt)::Bool function(ctx, uri, content_hash)
    @debug "Lazy load environment for" uri=uri content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        df = ctx.dynamic_feature
        project_path = uri2filepath(uri)

        # Fast-lane: when no package caches are missing for this project, skip
        # the (single, serial) DJP work queue and signal readiness directly via
        # the out_channel. This prevents quick projects (e.g. a `docs/` env or
        # the active project) from being blocked behind a slow standalone-
        # project DJP for an unrelated package.
        missing_pkgs = try
            _get_missing_packages(project_path, df.store_path)
        catch err
            @debug "Fast-lane env check failed; falling back to queue" project_path=project_path exception=(err, catch_backtrace())
            nothing
        end

        Threads.atomic_add!(df.pending_count, 1)
        df.progress_state.total_items += 1

        if missing_pkgs !== nothing && isempty(missing_pkgs)
            df.progress_state.completed_items += 1
            put!(
                df.out_channel,
                EnvironmentReadyResult(project_path, content_hash),
            )
            Threads.atomic_sub!(df.pending_count, 1)
            if df.pending_count[] == 0
                _report_progress(df, "Indexing complete")
                df.progress_state.total_items = 0
                df.progress_state.completed_items = 0
            end
            try put!(df.update_channel, :data_available) catch; end
        else
            _report_progress(df, "Preparing to index...")
            put!(
                df.in_channel,
                WatchEnvironmentMsg(project_path, content_hash),
            )
        end
    end

    return false
end

Salsa.@declare_input input_project_test_environment(rt, uri, package, content_hash::UInt)::Union{Nothing,URI} function(ctx, uri, package, content_hash)
    @debug "Lazy load test environment for project and package" uri=uri package=package content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        Threads.atomic_add!(ctx.dynamic_feature.pending_count, 1)
        ctx.dynamic_feature.progress_state.total_items += 1
        _report_progress(ctx.dynamic_feature, "Preparing to index...")
        put!(
            ctx.dynamic_feature.in_channel,
            WatchTestEnvironmentMsg(uri2filepath(uri), package, content_hash)
        )
    end

    return nothing
end

Salsa.@declare_input input_standalone_package_project(rt, package_folder_uri, content_hash::UInt)::Union{Nothing,URI} function(ctx, package_folder_uri, content_hash)
    @debug "Lazy create standalone project for package" package_folder_uri=package_folder_uri content_hash=content_hash

    if ctx.dynamic_feature !== nothing
        Threads.atomic_add!(ctx.dynamic_feature.pending_count, 1)
        ctx.dynamic_feature.progress_state.total_items += 1
        _report_progress(ctx.dynamic_feature, "Preparing to index...")
        put!(
            ctx.dynamic_feature.in_channel,
            CreateStandaloneProjectMsg(uri2filepath(package_folder_uri), content_hash)
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

    @debug "No package metadata loading because dynamic feature is off" name=name uuid=uuid version=version git_tree_sha1=git_tree_sha1

    return nothing
end
