Salsa.@declare_input input_files(rt)::Set{URI}

Salsa.@declare_input input_text_file(rt, uri)::Union{TextFile,Nothing}

Salsa.@declare_input input_active_project(rt)::Union{URI,Nothing}

Salsa.@declare_input input_notebook_file(rt, uri)::NotebookFile

# Manual override that makes every file's environment count as ready (see
# `derived_file_env_ready`). Only tests set it: readiness is tracked per
# project/work item, never workspace-wide.
Salsa.@declare_input input_env_ready(rt)::Bool

# Whether the workspace fabricates environments (standalone projects for
# manifest-less packages, merged test environments). When false only real
# project environments are watched.
Salsa.@declare_input input_resolve_workspace_environments(rt)::Bool

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

# Readiness state for dynamically-indexed environments. These replace the
# former lazy `input_project_environment` / `input_project_test_environment` /
# `input_standalone_package_project` inputs: instead of each per-key input
# lazily triggering a child process as a side effect, the dynamic-feature
# reactor is driven by an explicit reconcile (see `derived_required_dynamic_projects`
# and `ReconcileMsg`), and the *results* are written back here as plain
# collections. Per-key readiness is exposed via the memoized derived wrappers
# `derived_project_environment_ready` / `derived_ready_test_environment` /
# `derived_ready_standalone_project` (layer_environment.jl), which preserve
# fine-grained Salsa invalidation despite the collection being a single input.

# Set of project environments that have been fully indexed and are ready.
Salsa.@declare_input input_ready_project_environments(rt)::Set{WatchEnvironmentKey}

# Ready test environments, mapping each test-env key to the resulting test
# project URI.
Salsa.@declare_input input_ready_test_environments(rt)::Dict{WatchTestEnvironmentKey,URI}

# Created standalone package projects, mapping each standalone key to the
# resulting project URI.
Salsa.@declare_input input_standalone_projects(rt)::Dict{CreateStandaloneProjectKey,URI}

# Work items that failed terminally. Their artifacts (a test/standalone project
# URI) will never appear, so readiness gates treat these keys as settled and
# proceed best-effort with whatever symbol caches exist.
Salsa.@declare_input input_failed_dynamic_keys(rt)::Set{DJPKey}

Salsa.@declare_input input_package_metadata(rt, name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{Nothing,String})::Union{SymbolServer.Package,Nothing} function(ctx, name, uuid, version, git_tree_sha1)


    if ctx.dynamic_feature !== nothing
        cache_path = _package_cache_path(ctx.dynamic_feature.store_path, name, uuid, version, git_tree_sha1)

        # A corrupt cache comes back as `nothing` (and is deleted from disc), so
        # it takes the miss path below and gets re-indexed — reading it must not
        # throw out of a Salsa derivation, where the exception would surface as
        # an uncaught `DerivedFunctionException` at the top of the host process.
        package_data = _read_package_cache(cache_path, name, uuid)

        if package_data !== nothing
            # @info "Lazy load package metadata for" name uuid version git_tree_sha1 cache_path

            push!(ctx.dynamic_feature.loaded_pkg_metadata, PkgCacheKey((name, uuid, version, git_tree_sha1)))

            return package_data
        else
            push!(ctx.dynamic_feature.missing_pkg_metadata, PkgCacheKey((name, uuid, version, git_tree_sha1)))
            # @info "Queued package metadata loading" name uuid version git_tree_sha1
            return nothing
        end
    end

    @debug "No package metadata loading because dynamic feature is off" name=name uuid=uuid version=version git_tree_sha1=git_tree_sha1

    return nothing
end
