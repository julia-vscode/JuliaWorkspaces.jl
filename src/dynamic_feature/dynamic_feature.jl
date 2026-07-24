"""
    @enum DynamicMode DynamicOff DynamicIndexingOnly DynamicPersistent

Controls how a [`JuliaWorkspace`](@ref) uses the out-of-process *dynamic
feature* that indexes package environments and resolves symbol information.

- `DynamicOff`: No dynamic feature is started. The workspace only relies on
  statically available information (parsed sources, `Project.toml`/`Manifest.toml`
  contents, and any locally cached symbol data). Environment-dependent
  diagnostics are suppressed because no environment can be resolved.
- `DynamicIndexingOnly`: Child Julia processes are spawned to index project and
  test environments (populating the on-disc symbol cache), but they are torn
  down once indexing completes. Use this for one-shot tools such as CI runs.
- `DynamicPersistent`: Like `DynamicIndexingOnly`, but the child processes are
  kept alive so the workspace can react to ongoing changes. Use this for
  long-running hosts such as a language server.

See also [`is_ready`](@ref), [`wait_until_ready`](@ref).
"""
@enum DynamicMode DynamicOff DynamicIndexingOnly DynamicPersistent

# The DJPKey identity types (`WatchEnvironmentKey`, `WatchTestEnvironmentKey`,
# `CreateStandaloneProjectKey`) and the reactor/result message types are defined
# in `dynamic_messages.jl` (included before this file). The FSM helpers live in
# `dynamic_fsm.jl`.

mutable struct DynamicJuliaProcess
    key::DJPKey
    project_path::String
    package::Union{Nothing,String}
    kind::Symbol
    proc::Union{Nothing, Base.Process}
    endpoint::Union{Nothing, JSONRPC.JSONRPCEndpoint}
    cancellation_source::CancellationTokens.CancellationTokenSource
    fsm::FSM{DynamicProcessPhase}
    task::Union{Nothing,Task}

    function DynamicJuliaProcess(key::DJPKey, project_path::String, package::Union{Nothing,String}, kind::Symbol)
        return new(
            key,
            project_path,
            package,
            kind,
            nothing,
            nothing,
            CancellationTokens.CancellationTokenSource(),
            dynamic_process_fsm("$(kind):$(project_path)"),
            nothing
        )
    end
end

function index_project(djp::DynamicJuliaProcess, store_path::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.index_project_request_type,
        JuliaDynamicAnalysisProtocol.IndexProjectParams(
            djp.project_path,
            djp.package,
            store_path
        )
    )
end

function create_standalone_project(djp::DynamicJuliaProcess, store_path::String, project_dir::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.create_standalone_project_request_type,
        JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams(
            djp.project_path,
            store_path,
            project_dir
        )
    )
end

# Exception thrown when the child process exits before establishing a connection.
struct DynamicProcessCrashException <: Exception
    key::DJPKey
    exitcode::Union{Int,Nothing}
end

# ─── Launch prioritization ───────────────────────────────────────────────────
#
# Environments higher up the directory tree resolve first, so a package's main
# environment is ready before its test environment, testdata fixtures, nested
# docs/benchmark projects, etc. At equal depth the main env beats a standalone
# project beats a test env (a package's test-env key carries the same path as
# its main-env key).

_key_path(key::WatchEnvironmentKey) = key.project_path
_key_path(key::WatchTestEnvironmentKey) = key.project_path
_key_path(key::CreateStandaloneProjectKey) = key.package_path

_kind_rank(::WatchEnvironmentKey) = 0
_kind_rank(::CreateStandaloneProjectKey) = 1
_kind_rank(::WatchTestEnvironmentKey) = 2

function _launch_priority(key::DJPKey)
    depth = count(c -> c == '/' || c == '\\', normpath(_key_path(key)))
    return (depth, _kind_rank(key))
end

# Dispatch handler for JSONRPC messages received FROM the dynamic analysis
# process. `ctx` is the `(reactor_channel, djp)` tuple passed by the message
# loop in `start`; all state mutation happens on the reactor, so this only
# translates notifications into reactor messages.
#
# Deliberately hand-written rather than a `JSONRPC.@message_dispatcher`: the
# generated dispatcher throws on unknown methods, which would unwind the
# message loop, kill the child mid-index, and permanently mark the project
# failed. Progress is cosmetic, so anything unexpected — an unknown method
# from a version-skewed child, or a malformed payload — is logged and ignored
# instead.
function dispatch_dynamicprocess_msg(endpoint, msg, ctx)
    reactor_channel, djp = ctx

    if msg.method == JuliaDynamicAnalysisProtocol.index_progress_notification_type.method
        params = try
            JuliaDynamicAnalysisProtocol.IndexProgressParams(msg.params)
        catch err
            @warn "Malformed indexProgress notification from dynamic analysis process" exception=err
            return nothing
        end
        put!(reactor_channel, ProcessProgressMsg(djp.key, params.message, params.percentage))
    else
        @debug "Ignoring unknown message from dynamic analysis process" method=msg.method
    end

    return nothing
end

# Spawn and supervise a single child Julia analysis process. Modeled after
# `TestItemControllers.start(::TestProcessState, ...)`: a long-lived task that
# owns the child process for its whole lifetime, uses nested `try/finally`
# blocks to guarantee resource cleanup, drives cancellation via a
# `CancellationToken`, and runs a message loop that reads messages from the
# child. Lifecycle events are reported back to the reactor via `reactor_channel`.
function start(djp::DynamicJuliaProcess, reactor_channel::Channel, token::CancellationTokens.CancellationToken)
    # The reactor's `_launch_now!` already logged the categorized spawn reason.
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)
    try
        julia_dynamic_analysis_process_script = joinpath(@__DIR__, "../../juliadynamicanalysisprocess/app/julia_dynamic_analysis_process_main.jl")

        pipe_out = Pipe()
        try
            error_handler_file = nothing
            crash_reporting_pipename = nothing

            error_handler_file = error_handler_file === nothing ? [] : [error_handler_file]
            crash_reporting_pipename = crash_reporting_pipename === nothing ? [] : [crash_reporting_pipename]

            env_to_use = copy(ENV)

            if haskey(env_to_use, "JULIA_DEPOT_PATH")
                delete!(env_to_use, "JULIA_DEPOT_PATH")
            end

            # Use the same binary as the current process: `julia` from PATH may
            # not resolve at all inside an editor-launched language server (which
            # is started with an explicit executable path), or may resolve to a
            # different Julia version than the one this process runs on.
            julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())

            jl_process = open(
                pipeline(
                    Cmd(`$julia_exe --startup-file=no --history-file=no --depwarn=no $julia_dynamic_analysis_process_script $pipe_name $(error_handler_file...) $(crash_reporting_pipename...)`, detach=false, env=env_to_use),
                    stdout = pipe_out,
                    stderr = pipe_out
                )
            )

            proc_kill_registration = CancellationTokens.register(token) do
                @debug "Killing DynamicJuliaProcess due to cancellation" kind=djp.kind project_path=djp.project_path
                try kill(jl_process) catch end
            end

            try # This try/finally block closes the `proc_kill_registration`.
                # Async task: forward the child's stdout/stderr to the logger. We
                # don't need to distinguish per-test-item output here, so this is
                # a simple line-buffered logger (unlike TestItemControllers).
                @async try
                    buffer = ""
                    while !eof(pipe_out)
                        data = readavailable(pipe_out, token)
                        data_as_string = String(data)

                        buffer *= data_as_string

                        i = 1
                        current_line_start = 1
                        while i<=length(buffer)
                            if buffer[i] == '\n'
                                line = strip(buffer[current_line_start:prevind(buffer,i)])
                                if length(line) > 0
                                    @debug "Output from DynamicJuliaProcess" project_path=djp.project_path package=djp.package line=line
                                end
                                current_line_start = nextind(buffer, i)
                            end
                            i = nextind(buffer, i)
                        end

                        buffer = buffer[current_line_start:end]
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException
                        @debug "Output reading cancelled by token" project_path=djp.project_path
                    else
                        @error "Error reading DynamicJuliaProcess output" project_path=djp.project_path exception=(err, catch_backtrace())
                    end
                end

                abort_accept_due_to_startup_failure_source = CancellationTokens.CancellationTokenSource()
                abort_accept_due_to_startup_failure_token = CancellationTokens.get_token(abort_accept_due_to_startup_failure_source)

                # Watch for subprocess exit before connection — if the process
                # crashes during startup, cancel the accept to unblock it.
                connection_established = Ref(false)
                @async try
                    wait(jl_process)
                    if !connection_established[]
                        if CancellationTokens.is_cancellation_requested(token)
                            @debug "Dynamic process exited before connecting (cancellation requested)" project_path=djp.project_path exitcode=jl_process.exitcode
                        else
                            CancellationTokens.cancel(abort_accept_due_to_startup_failure_source)
                        end
                    end
                catch err
                    @error "Error waiting for dynamic process exit" project_path=djp.project_path exception=(err, catch_backtrace())
                end

                accept_combined_token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource(token, abort_accept_due_to_startup_failure_token))

                @debug "Waiting for connection from dynamic process" project_path=djp.project_path pipe_name
                try
                    socket = Sockets.accept(server, accept_combined_token)

                    try
                        connection_established[] = true

                        @debug "Connection established" project_path=djp.project_path

                        endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)
                        try
                            JSONRPC.start(endpoint)

                            put!(reactor_channel, ProcessLaunchedMsg(djp.key, jl_process, endpoint))

                            while true
                                msg = try
                                    JSONRPC.get_next_message(endpoint, token=token)
                                catch err
                                    if CancellationTokens.is_cancellation_requested(token) || err isa CancellationTokens.OperationCanceledException
                                        break
                                    else
                                        rethrow(err)
                                    end
                                end

                                dispatch_dynamicprocess_msg(endpoint, msg, (reactor_channel, djp))
                            end

                            put!(reactor_channel, ProcessTerminatedMsg(djp.key))
                        finally
                            close(endpoint)
                        end
                    finally
                        close(socket)
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException && CancellationTokens.is_cancellation_requested(abort_accept_due_to_startup_failure_token)
                        throw(DynamicProcessCrashException(djp.key, jl_process.exitcode))
                    else
                        rethrow(err)
                    end
                end
            catch err
                if !(err isa CancellationTokens.OperationCanceledException)
                    # Kill the child only via the cancellation source: cancelling
                    # fires `proc_kill_registration`, which is the single place
                    # that actually kills the Julia process.
                    CancellationTokens.cancel(djp.cancellation_source)
                    wait(jl_process)
                    put!(reactor_channel, ProcessIndexFailedMsg(djp.key, err))
                else
                    put!(reactor_channel, ProcessTerminatedMsg(djp.key))
                end
            finally
                close(proc_kill_registration)
            end
        finally
            close(pipe_out)
        end
    finally
        close(server)
    end
end

function Base.kill(djp::DynamicJuliaProcess)
    @debug "Killing DynamicJuliaProcess" kind=djp.kind project_path=djp.project_path package=djp.package

    # Killing the child process is done exclusively through the cancellation
    # source: `start` registers a callback on this source's token that performs
    # the actual `kill` on the Julia process. We must not kill `djp.proc`
    # directly here.
    CancellationTokens.cancel(djp.cancellation_source)

    djp.proc = nothing
    djp.endpoint = nothing

    if state(djp.fsm) != DynamicProcessDead
        transition!(djp.fsm, DynamicProcessDead; reason="killed")
    end
end

"""
    DEFAULT_SYMBOLCACHE_UPSTREAM

Default upstream URL from which precomputed package symbol caches are
downloaded when `symbolcache_download` is enabled on a [`JuliaWorkspace`](@ref).
Downloading a cached index avoids having to index a package locally.
"""
const DEFAULT_SYMBOLCACHE_UPSTREAM = "https://julia-symbolcache.org"

# Identity of one package's symbol cache on disc.
const PkgCacheKey = @NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}

struct DynamicFeature
    djp_mode::DynamicMode
    store_path::String
    download_enabled::Bool
    upstream_url::String
    in_channel::Channel{DynamicReactorMessage}
    out_channel::Channel{DynamicResultMessage}
    procs::Dict{DJPKey,DynamicJuliaProcess}
    failed_projects::Set{DJPKey}
    inflight::Set{DJPKey}
    # Keys whose work has fully completed (indexed / fast-laned). Under
    # DynamicIndexingOnly the process is killed but the key stays here so a
    # later reconcile carrying the same `required` set does not re-spawn it.
    done::Set{DJPKey}
    # The `required` set from the most recent reconcile, used by `_reconcile!`
    # to skip sending a `ReconcileMsg` when nothing changed.
    last_required::Set{DJPKey}
    missing_pkg_metadata::Set{PkgCacheKey}
    # Package caches whose metadata input is already populated; guards against
    # re-reading (and re-`set_input`ing) multi-MB cache files.
    loaded_pkg_metadata::Set{PkgCacheKey}
    pending_count::Threads.Atomic{Int}
    update_channel::Channel{Symbol}
    progress_callback::Union{Nothing,Function}
    # Last child-reported indexing percentage per work item (reactor-owned).
    # Used to keep each item's progress bar monotone across late/duplicate
    # child reports and to re-use the last percentage for reports without one.
    child_progress::Dict{DJPKey,Int}
    controller_fsm::FSM{DynamicControllerPhase}
    # ── Launch concurrency cap ──
    # Maximum number of concurrently *working* child processes (<= 0: unlimited).
    max_concurrent_djps::Int
    # Keys ready to launch but over the cap; drained best-`_launch_priority`
    # first, insertion order as the final tiebreak.
    launch_queue::Vector{DJPKey}
    # Keys whose child has been launched and whose work item has not reached a
    # terminal message yet — the set the cap counts (NOT `procs`: persistent
    # children that finished indexing stay in `procs` without holding a slot).
    launching::Set{DJPKey}
    # Launch implementation; injectable so reactor tests observe launches
    # without spawning processes (same seam pattern as `progress_callback`).
    launcher::Function
    # ── Background refresh of served-stale standalone envs ──
    # Strictly lower priority than `launch_queue`; never counts as a pending
    # work item (readiness must not wait on refreshes).
    refresh_queue::Vector{DJPKey}
    refreshing::Set{DJPKey}

    function DynamicFeature(djp_mode::DynamicMode, store_path::String;
            download_enabled::Bool=false, upstream_url::String=DEFAULT_SYMBOLCACHE_UPSTREAM,
            progress_callback::Union{Nothing,Function}=nothing,
            max_concurrent_djps::Int=4, launcher::Function=_launch_process!)
        return new(
            djp_mode,
            store_path,
            download_enabled,
            upstream_url,
            Channel{DynamicReactorMessage}(Inf),
            Channel{DynamicResultMessage}(Inf),
            Dict{DJPKey,DynamicJuliaProcess}(),
            Set{DJPKey}(),
            Set{DJPKey}(),
            Set{DJPKey}(),
            Set{DJPKey}(),
            Set{PkgCacheKey}(),
            Set{PkgCacheKey}(),
            Threads.Atomic{Int}(0),
            Channel{Symbol}(1),   # coalesced wakeup signal (see _complete_work_item!)
            progress_callback,
            Dict{DJPKey,Int}(),
            dynamic_controller_fsm("dynamic_controller"),
            max_concurrent_djps,
            Vector{DJPKey}(),
            Set{DJPKey}(),
            launcher,
            Vector{DJPKey}(),
            Set{DJPKey}(),
        )
    end
end

# Persistent, deterministic project dir for a standalone package: reused
# across sessions while the package's Project.toml (content hash) is
# unchanged. The dir name includes a path hash (not just
# `basename(package_path)`) so same-named packages under different paths (e.g.
# `packages/Foo` vs `packages-old/Foo`) get distinct dirs. The path-hash
# segment is also why sibling cleanup can match on a plain prefix without
# colliding with a differently-named package that merely starts with the same
# characters (e.g. `Pkg` vs `Pkg-extra`).
#
# `(parent, prefix, dir)` — pure, no filesystem mutation.
function _standalone_dir_components(df::DynamicFeature, key::CreateStandaloneProjectKey)
    parent = joinpath(dirname(df.store_path), "standalone-projects")
    name = basename(key.package_path)
    path_hash = string(hash(key.package_path) % UInt32, base=16, pad=8)
    prefix = string(name, "-", path_hash, "-")
    dir = joinpath(parent, string(prefix, string(key.content_hash, base=16, pad=16)))
    return (parent, prefix, dir)
end

# The deterministic dir path only — no filesystem mutation, so it is safe to
# call OFF the reactor (e.g. from a `ProcessLaunchedMsg` async task, where the
# destructive `_prepare_standalone_project_dir!` would race a concurrent
# resolve into a sibling content-hash's live dir).
_standalone_project_dir_path(df::DynamicFeature, key::CreateStandaloneProjectKey) =
    _standalone_dir_components(df, key)[3]

# Reactor-only: prepare the dir. Sibling dirs for the same package *path* under
# an *old* content hash are removed (a changed package gets a fresh resolve,
# and growth stays bounded), then the dir is `mkpath`ed. MUST run on the
# reactor — the `rm(...; recursive=true)` would otherwise delete a sibling
# dir that a newer content hash's child is actively resolving into.
function _prepare_standalone_project_dir!(df::DynamicFeature, key::CreateStandaloneProjectKey)
    parent, prefix, dir = _standalone_dir_components(df, key)
    if isdir(parent)
        for other in readdir(parent; join=true)
            if startswith(basename(other), prefix) && other != dir
                try rm(other; recursive=true) catch; end
            end
        end
    end
    mkpath(dir)
    return dir
end

"""
    _report_progress(df::DynamicFeature, key::String, message::String, percentage::Int)

Invoke `df.progress_callback` if one is registered. `key` identifies the
operation the report belongs to — each operation (downloading caches for a
project, indexing a project, loading caches, …) is its own progress bar with
the full 0–100 range, and a report with `percentage >= 100` ends it. This is
stateless, so it is safe to call from any task.
"""
function _report_progress(df::DynamicFeature, key::String, message::String, percentage::Int)
    df.progress_callback === nothing && return
    try
        df.progress_callback(key, message, percentage)
    catch err
        @warn "progress_callback threw" exception=(err, catch_backtrace())
    end
    return
end

# Progress-bar keys for the two phases of a work item. The content hash is
# deliberately excluded so a re-index of the same project reuses its bar.
_progress_key(phase::String, key::WatchEnvironmentKey) = string(phase, ":", key.project_path)
_progress_key(phase::String, key::WatchTestEnvironmentKey) = string(phase, ":", key.project_path, ":", key.package_name)
_progress_key(phase::String, key::CreateStandaloneProjectKey) = string(phase, ":", key.package_path)

const MissingPackage = @NamedTuple{name::String, uuid::UUID, version::String, git_tree_sha1::Union{String,Nothing}}

"""
    _get_missing_packages(project_path, store_path) -> Vector{MissingPackage}

Parse the Manifest.toml at `project_path` and return a list of regular and stdlib
packages whose .jstore cache files do not yet exist on disk. Deved packages are
skipped entirely (they have no git_tree_sha1 and are handled by StaticLint).
"""
function _get_missing_packages(project_path::String, store_path::String)
    manifest_path = joinpath(project_path, "Manifest.toml")
    isfile(manifest_path) || return MissingPackage[]

    manifest_content = try
        Pkg.TOML.parsefile(manifest_path)
    catch
        return MissingPackage[]
    end

    manifest_version_str = get(manifest_content, "manifest_format", "1.0")
    manifest_version = tryparse(VersionNumber, manifest_version_str)
    manifest_version === nothing && return MissingPackage[]

    manifest_deps = if manifest_version.major == 1
        manifest_content
    elseif manifest_version.major == 2 && haskey(manifest_content, "deps") && manifest_content["deps"] isa Dict
        manifest_content["deps"]
    else
        return MissingPackage[]
    end

    missing = MissingPackage[]

    for (k_entry, v_entry) in pairs(manifest_deps)
        v_entry isa Vector || continue
        length(v_entry) == 1 || continue
        v_entry[1] isa Dict || continue
        entry = v_entry[1]

        # Skip deved packages (have "path" key)
        haskey(entry, "path") && continue

        uuid_str = get(entry, "uuid", nothing)
        uuid_str === nothing && continue
        uuid = tryparse(UUID, uuid_str)
        uuid === nothing && continue

        stdlib_ver = haskey(entry, "version") ? _stdlib_cache_version(uuid) : nothing
        if stdlib_ver !== nothing
            # A stdlib recorded as registered (git-tree-sha1) or with a stale
            # version is resolved to the bundled stdlib by the child; key it there.
            filename = replace(string(stdlib_ver), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, string(stdlib_ver), nothing)))
            end
        elseif haskey(entry, "git-tree-sha1") && haskey(entry, "version")
            # Regular package
            ver = entry["version"]
            tree_sha = entry["git-tree-sha1"]
            filename = replace(string(something(tree_sha, ver)), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver, tree_sha)))
            end
        elseif !haskey(entry, "git-tree-sha1")
            # Stdlib package
            ver_str = get(entry, "version", nothing)
            ver_str === nothing && continue
            filename = replace(string(ver_str), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver_str, nothing)))
            end
        end
    end

    return missing
end

# Store-relative `.jstore` path for a missing package, matching the layout
# `_get_missing_packages` and `_download_single_cache` build inline.
function _jstore_path(pkg::MissingPackage, store_path::String)
    filename = replace(string(something(pkg.git_tree_sha1, pkg.version)), '+'=>'_')
    joinpath(store_path, uppercase(pkg.name[1:1]), pkg.name, string(pkg.uuid), string(filename, ".jstore"))
end

# Drop packages whose sibling tombstone says local caching was already tried and
# failed for this exact version under the current indexer/Julia and hasn't
# expired. A missing/mismatched/expired tombstone keeps the package (retry).
function _drop_tombstoned(pkgs::Vector{MissingPackage}, store_path::String)
    filter(pkgs) do pkg
        tomb = SymbolServer.tombstone_path(_jstore_path(pkg, store_path))
        !SymbolServer.tombstone_is_current(SymbolServer.read_tombstone(tomb))
    end
end

"""
    _download_single_cache(pkg, store_path, upstream_url, download_dir) -> Bool

Download a single .jstore.tar.gz from the cloud, unpack it, and move it to the
store path. Returns true on success, false on failure.
"""
function _download_single_cache(pkg::MissingPackage, store_path::String, upstream_url::String, download_dir::String)
    name, uuid, version, git_tree_sha1 = pkg

    letter = uppercase(name[1:1])
    filename = string(replace(string(something(git_tree_sha1, version)), '+'=>'_'), ".jstore")

    dest_dir = joinpath(store_path, letter, name, string(uuid))
    dest_filepath = joinpath(dest_dir, filename)
    dest_filepath_unavailable = string(first(splitext(dest_filepath)), ".unavailable")

    # Skip if we already know it's unavailable
    if isfile(dest_filepath_unavailable)
        @debug "Cloud cache unavailable marker exists, skipping" name=name
        return false
    end

    link = string(upstream_url, "/store/", SymbolServer.CACHE_STORE_VERSION, "/packages/", letter, "/", name, "/", string(uuid), "/", first(splitext(filename)), ".tar.gz")
    @debug "Downloading package cache from cloud" name = name version = version url = link

    pkg_download_dir = joinpath(download_dir, string(name, "_", uuid, "_", version))

    try
        @info "Downloading package cache" name=name version=version
        Pkg.PlatformEngines.download_verify_unpack(link, nothing, pkg_download_dir)

        download_filepath = joinpath(pkg_download_dir, filename)
        download_filepath_unavailable = string(first(splitext(download_filepath)), ".unavailable")

        if !isfile(download_filepath) && isfile(download_filepath_unavailable)
            mkpath(dest_dir)
            mv(download_filepath_unavailable, dest_filepath_unavailable, force=true)
            @debug "Cloud cache unavailable for package" name=name
            return false
        end

        if !isfile(download_filepath)
            @debug "Expected file not found in tarball" name=name expected=download_filepath
            return false
        end

        # Patch PLACEHOLDER paths
        cache = try
            open(download_filepath, "r") do io
                SymbolServer.CacheStore.read(io)
            end
        catch
            @warn "Couldn't read downloaded cache file" name=name
            return false
        end

        pkg_entry = Base.locate_package(Base.PkgId(uuid, name))
        if pkg_entry !== nothing && isfile(pkg_entry)
            pkg_src = dirname(pkg_entry)
            SymbolServer.modify_dirs(cache.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", pkg_src))
        end

        mkpath(dest_dir)
        open(dest_filepath, "w") do io
            SymbolServer.CacheStore.write(io, cache)
        end

        @info "Successfully downloaded cache" name=name version=version
        SymbolServer.delete_tombstone(SymbolServer.tombstone_path(dest_filepath))
        return true
    catch err
        @warn "Failed to download cache" name=name version=version exception=(err, catch_backtrace())
        return false
    finally
        try rm(pkg_download_dir, recursive=true, force=true) catch; end
    end
end

"""
    _download_missing_caches(missing_pkgs, store_path, upstream_url; df=nothing) -> Vector{MissingPackage}

Download missing package caches from the cloud. Consults the server's
availability index and only requests packages it advertises as cached; anything
absent from the index (private, uncached, or tombstoned) is skipped, which also
keeps private package names off the wire. Returns the list of packages still
missing after download. If `report` is provided, it is called as
`report(message::String, fraction::Float64)` with the download phase's
completion fraction (0..1) after each finished download attempt.
"""
function _download_missing_caches(missing_pkgs::Vector{MissingPackage}, store_path::String, upstream_url::String; report::Union{Nothing,Function}=nothing)
    index = SymbolServer.fetch_availability_index(upstream_url)
    if index === nothing
        @warn "Could not fetch availability index from $(upstream_url), skipping cloud downloads"
        return missing_pkgs
    end

    # Keep only what the index advertises as cached; a package absent from it is
    # never requested. Key matches the artifact path: <uuid>/<treehash, + → _>.
    downloadable = filter(missing_pkgs) do pkg
        stem = replace(string(something(pkg.git_tree_sha1, pkg.version)), '+' => '_')
        SymbolServer.cache_key(pkg.uuid, stem) in index
    end

    num_downloadable = length(missing_pkgs) - length(downloadable)

    @info "Downloading $(length(downloadable)) cache files ($(num_downloadable) not available in cloud cache)..."

    isempty(downloadable) && return missing_pkgs

    download_dir_parent = joinpath(store_path, "_downloads")
    mkpath(download_dir_parent)

    downloaded_set = Set{MissingPackage}()
    total_downloadable = length(downloadable)
    downloaded_count = Threads.Atomic{Int}(0)

    mktempdir(download_dir_parent) do download_dir
        for batch in Iterators.partition(downloadable, 100)
            @sync for pkg in batch
                @async begin
                    yield()
                    if _download_single_cache(pkg, store_path, upstream_url, download_dir)
                        push!(downloaded_set, pkg)
                    end
                    Threads.atomic_add!(downloaded_count, 1)
                    if report !== nothing
                        report("Downloading caches ($(downloaded_count[])/$total_downloadable)...", downloaded_count[] / total_downloadable)
                    end
                    yield()
                end
            end
        end
    end

    # Return packages still missing
    return filter(pkg -> pkg ∉ downloaded_set, missing_pkgs)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Reactor event loop
# ═══════════════════════════════════════════════════════════════════════════════

# Decrement bookkeeping for exactly one queued work item. `inflight` membership
# is the single source of truth for "this work item is still pending", which
# makes the call idempotent: a duplicate terminal message (e.g. an index task
# failure that races with the process-termination path) is a no-op.
function _complete_work_item!(df::DynamicFeature, key::DJPKey)
    key in df.inflight || return false
    delete!(df.inflight, key)
    Threads.atomic_sub!(df.pending_count, 1)
    delete!(df.child_progress, key)
    # End the item's progress bars. Ending a bar that was never opened (e.g.
    # the download bar of an item that had nothing to download) is a no-op on
    # the consumer side.
    key isa WatchEnvironmentKey && _report_progress(df, _progress_key("download", key), "Done", 100)
    _report_progress(df, _progress_key("index", key), "Done", 100)
    # `update_channel` is a coalesced wakeup: one pending signal is enough, and
    # this runs on the reactor task, so it must never block. A blocking `put!`
    # to a full bounded channel (consumer not keeping up / stopped) would wedge
    # the reactor. Skip when a signal is already queued.
    isready(df.update_channel) || try put!(df.update_channel, :data_available) catch; end
    return true
end

# Transition a freshly-created DJP into its supervised `start` task.
function _launch_process!(df::DynamicFeature, djp::DynamicJuliaProcess)
    transition!(djp.fsm, DynamicProcessStarting; reason="launching")
    token = CancellationTokens.get_token(djp.cancellation_source)
    djp.task = @async try
        start(djp, df.in_channel, token)
    catch err
        # `start` reports errors from its supervised region itself; this catches
        # failures outside it (e.g. the process spawn throwing because the Julia
        # binary can't be executed), which would otherwise die silently with the
        # task and leave the work item inflight forever.
        @error "DynamicJuliaProcess failed to launch" key=djp.key exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(djp.key, err))
    end
    return
end

_has_free_slot(df::DynamicFeature) =
    df.max_concurrent_djps <= 0 || length(df.launching) < df.max_concurrent_djps

# Construct the DJP for `key` and launch it, occupying a slot. The DJP is
# derived from the key alone so queued keys carry no state that can go stale.
# The trailing path segments of `path`, for logs/progress that would otherwise
# show a bare basename — ambiguous when same-named projects live under different
# roots (no workspace root is threaded into the reactor to relativize against).
function _short_path(path::AbstractString; segments::Int=3)
    parts = splitpath(path)
    length(parts) <= segments && return path
    return joinpath(parts[end-segments+1:end]...)
end

# The reason a child is running and the path it targets, shared by the spawn and
# completion logs so they stay in sync. Package-cache tombstones only avoid the
# watch-environment first index; test environments and standalone refreshes
# always need a child, so those keep spawning across restarts by design.
# `target` is always a real path so callers can `_short_path` it.
function _djp_reason_target(df::DynamicFeature, key::DJPKey)
    if key in df.refreshing
        ("refreshing served standalone project (background; picks up changes)", key.package_path)
    elseif key isa WatchEnvironmentKey
        ("indexing packages that still lack a symbol cache", key.project_path)
    elseif key isa WatchTestEnvironmentKey
        ("materializing the '$(key.package_name)' test environment (only a child can produce it)", key.project_path)
    else
        ("creating a standalone project (only a child can produce it)", key.package_path)
    end
end

function _launch_now!(df::DynamicFeature, key::DJPKey)
    djp = if key isa WatchEnvironmentKey
        DynamicJuliaProcess(key, key.project_path, nothing, :watch_environment)
    elseif key isa WatchTestEnvironmentKey
        DynamicJuliaProcess(key, key.project_path, key.package_name, :watch_test_environment)
    else
        DynamicJuliaProcess(key, key.package_path, nothing, :create_standalone_project)
    end
    df.procs[key] = djp
    push!(df.launching, key)
    reason, target = _djp_reason_target(df, key)
    @info "Spawning indexing child process for $(_short_path(target)): $(reason)"
    df.launcher(df, djp)
    return
end

# Launch `key` if a slot is free, otherwise queue it.
function _request_launch!(df::DynamicFeature, key::DJPKey)
    if _has_free_slot(df)
        _launch_now!(df, key)
    else
        _report_progress(df, _progress_key("index", key), "Queued for indexing...", 0)
        push!(df.launch_queue, key)
    end
    return
end

# Launch queued keys, best `_launch_priority` first (stable: strict `<` keeps
# insertion order among equals), while slots are free. Skips keys whose work
# was cancelled while queued.
function _drain_launch_queue!(df::DynamicFeature)
    while _has_free_slot(df) && !isempty(df.launch_queue)
        best = 1
        for i in 2:length(df.launch_queue)
            if _launch_priority(df.launch_queue[i]) < _launch_priority(df.launch_queue[best])
                best = i
            end
        end
        key = df.launch_queue[best]
        deleteat!(df.launch_queue, best)
        key in df.inflight || continue
        _launch_now!(df, key)
    end

    # Refreshes fill remaining slots only when no first-time work wants them.
    # `pending_count` (not just `launch_queue`) gates this: it covers queued,
    # launched, and prep-in-flight work items, so the completion of the last
    # first-time item -- including a fast-lane serve itself -- is what
    # releases refreshes to run.
    while _has_free_slot(df) && df.pending_count[] <= 0 && isempty(df.launch_queue) && !isempty(df.refresh_queue)
        best = 1
        for i in 2:length(df.refresh_queue)
            if _launch_priority(df.refresh_queue[i]) < _launch_priority(df.refresh_queue[best])
                best = i
            end
        end
        key = df.refresh_queue[best]
        deleteat!(df.refresh_queue, best)
        push!(df.refreshing, key)
        _report_progress(df, _progress_key("refresh", key), "Refreshing environment...", 0)
        _launch_now!(df, key)
    end
    return
end

# A launched child reached a terminal state: release its slot and refill.
function _free_slot!(df::DynamicFeature, key::DJPKey)
    delete!(df.launching, key)
    _drain_launch_queue!(df)
    return
end

"""
    Base.run(df::DynamicFeature)

The dynamic-feature reactor loop. Modeled after `TestItemControllers`' reactor:
it pulls typed [`DynamicReactorMessage`](@ref)s off `df.in_channel` and dispatches
each to a type-specialized `handle!` method. A handler returning `true` stops
the loop.
"""
function Base.run(df::DynamicFeature)
    while true
        msg = take!(df.in_channel)
        @debug "Reactor msg" msg_type=typeof(msg).name.name

        should_stop = handle!(df, msg)
        should_stop === true && break
    end
end

function start(df::DynamicFeature)
    @async try
        Base.run(df)
    catch err
        flush(stderr)
        bt = catch_backtrace()
        Base.display_error(err, bt)
        flush(stderr)
    end
end

# ─── Work messages ──────────────────────────────────────────────────────────

function handle!(df::DynamicFeature, msg::WatchEnvironmentMsg)
    key = msg.key
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed project" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    # Offload the (potentially slow) missing-package check + cloud download to a
    # task so the reactor stays responsive. The result is fed back as an
    # `EnvironmentPrepDoneMsg`, so all state mutation stays on the reactor.
    project_path = key.project_path
    @async try
        missing_pkgs = _get_missing_packages(project_path, df.store_path)

        if !isempty(missing_pkgs) && df.download_enabled
            # Progress is routed through the reactor as `PrepProgressMsg`s
            # carrying the download phase's own completion fraction; the
            # reactor reports them onto the item's dedicated download bar.
            put!(df.in_channel, PrepProgressMsg(key, "Downloading caches for $(basename(project_path))...", 0.0))
            missing_pkgs = _download_missing_caches(missing_pkgs, df.store_path, df.upstream_url;
                report = (message, fraction) -> put!(df.in_channel, PrepProgressMsg(key, message, fraction)))
            put!(df.in_channel, PrepProgressMsg(key, "Downloaded caches for $(basename(project_path))", 1.0))
        end

        # A package we can neither cache nor download is dropped if it carries a
        # current tombstone, so a permanently-uncacheable pin stops re-launching a DJP.
        missing_pkgs = _drop_tombstoned(missing_pkgs, df.store_path)
        put!(df.in_channel, EnvironmentPrepDoneMsg(key, !isempty(missing_pkgs)))
    catch err
        @error "Environment prep failed" project_path=project_path exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(key, err))
    end

    return false
end

function handle!(df::DynamicFeature, msg::PrepProgressMsg)
    if msg.key ∉ df.inflight
        @debug "Stale PrepProgressMsg; ignoring" key=msg.key
        return false
    end

    _report_progress(df, _progress_key("download", msg.key), msg.message, round(Int, 100 * clamp(msg.fraction, 0.0, 1.0)))

    return false
end

function handle!(df::DynamicFeature, msg::EnvironmentPrepDoneMsg)
    key = msg.key

    # The key may have been reaped (re-keyed / no longer required) while its prep
    # ran; drop the stale result rather than launch or mark it ready.
    if key ∉ df.inflight
        @debug "Stale EnvironmentPrepDoneMsg; ignoring" key
        return false
    end

    if !msg.still_missing
        put!(df.out_channel, EnvironmentReadyResult(key.project_path, key.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
        # This fast lane never occupies a launch slot, so it cannot rely on
        # `_free_slot!` to drain queued refreshes. Without this, the last
        # outstanding first-time item completing this way (the common
        # warm-restart ordering where standalone preps finish fast and
        # watch-env preps finish last) would leave queued refreshes stalled
        # forever.
        _drain_launch_queue!(df)
    elseif df.djp_mode != DynamicOff
        @info "$(_short_path(key.project_path)) not fully resolved, enqueueing local indexing process..."
        _report_progress(df, _progress_key("index", key), "Enqueueing indexer for $(basename(key.project_path))...", 0)
        _request_launch!(df, key)
    else
        @info "$(_short_path(key.project_path)) not fully resolved, but local indexing is disabled"
        put!(df.out_channel, EnvironmentReadyResult(key.project_path, key.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
        _drain_launch_queue!(df)
    end

    return false
end

function handle!(df::DynamicFeature, msg::WatchTestEnvironmentMsg)
    key = msg.key
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed test environment" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    # A test environment can only be produced by a child process; without
    # dynamic indexing this work is terminal (best-effort readiness, like the
    # watch-env DynamicOff branch).
    if df.djp_mode == DynamicOff
        @info "Test environment needs a dynamic child process but dynamic indexing is disabled; skipping" key
        put!(df.out_channel, FailedResult(key))
        push!(df.done, key)
        _complete_work_item!(df, key)
        _drain_launch_queue!(df)
        return false
    end

    _report_progress(df, _progress_key("index", key), "Starting indexer for the test environment of $(key.package_name)...", 0)
    _request_launch!(df, key)

    return false
end

function handle!(df::DynamicFeature, msg::CreateStandaloneProjectMsg)
    key = msg.key
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed standalone project" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    _report_progress(df, _progress_key("index", key), "Checking standalone project for $(basename(key.package_path))...", 0)

    # Offload the (IO-bound) dir + missing-package check to a task so the
    # reactor stays responsive; the decision comes back as a
    # `StandaloneProjectPrepDoneMsg` so all state mutation stays on the reactor.
    dir = _prepare_standalone_project_dir!(df, key)
    store_path = df.store_path
    @async try
        usable = isfile(joinpath(dir, "Project.toml")) && isfile(joinpath(dir, "Manifest.toml"))
        fast_lane = usable && isempty(_drop_tombstoned(_get_missing_packages(dir, store_path), store_path))
        put!(df.in_channel, StandaloneProjectPrepDoneMsg(key, fast_lane))
    catch err
        @error "Standalone project prep failed" key exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(key, err))
    end

    return false
end

function handle!(df::DynamicFeature, msg::StandaloneProjectPrepDoneMsg)
    key = msg.key

    # Reaped (re-keyed / no longer required) while prep ran; drop the stale result.
    if key ∉ df.inflight
        @debug "Stale StandaloneProjectPrepDoneMsg; ignoring" key
        return false
    end

    if msg.fast_lane
        @info "Serving existing standalone project; refreshing in background" package_path=key.package_path
        dir = _standalone_project_dir_path(df, key)
        put!(df.out_channel, StandaloneProjectReadyResult(filepath2uri(key.package_path), filepath2uri(dir), key.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
        # A refresh needs a child process, which dynamic-off mode never runs;
        # the served (possibly stale) environment is all it gets.
        df.djp_mode != DynamicOff && push!(df.refresh_queue, key)
        _drain_launch_queue!(df)
    elseif df.djp_mode == DynamicOff
        # Creating the standalone project needs a child process; terminal
        # without one (files fall back to the active project's environment).
        @info "Standalone project needs a dynamic child process but dynamic indexing is disabled; skipping" key
        put!(df.out_channel, FailedResult(key))
        push!(df.done, key)
        _complete_work_item!(df, key)
        _drain_launch_queue!(df)
    else
        _report_progress(df, _progress_key("index", key), "Creating standalone project for $(basename(key.package_path))...", 0)
        _request_launch!(df, key)
    end

    return false
end

# ─── Process-lifecycle messages ─────────────────────────────────────────────

function handle!(df::DynamicFeature, msg::ProcessLaunchedMsg)
    key = msg.key
    djp = get(df.procs, key, nothing)
    if djp === nothing
        @debug "ProcessLaunchedMsg for unknown/stale process; ignoring" key
        return false
    end

    djp.proc = msg.proc
    djp.endpoint = msg.endpoint
    transition!(djp.fsm, DynamicProcessConnected; reason="connected")
    transition!(djp.fsm, DynamicProcessIndexing; reason="indexing")

    # Send the (blocking) index/standalone request from its own task so the
    # reactor stays responsive while the child computes. The result is fed back
    # as a `ProcessIndexedMsg`/`ProcessIndexFailedMsg`.
    @async try
        result_dir = if key isa CreateStandaloneProjectKey
            # Pure path only: the reactor already prepared (cleaned + created)
            # this dir in `CreateStandaloneProjectMsg`. Recomputing the
            # destructive prepare here — off the reactor — could `rm` a sibling
            # content-hash's dir that another child is resolving into.
            create_standalone_project(djp, df.store_path, _standalone_project_dir_path(df, key))
        else
            index_project(djp, df.store_path)
        end
        put!(df.in_channel, ProcessIndexedMsg(key, result_dir))
    catch err
        @error "Dynamic index request failed" key exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(key, err))
    end

    return false
end

function handle!(df::DynamicFeature, msg::ProcessProgressMsg)
    key = msg.key
    # Refreshes run a child too, but sit in `refreshing`, not `inflight`; their
    # progress belongs on the refresh bar.
    refreshing = key in df.refreshing
    if !refreshing && key ∉ df.inflight
        @debug "Stale ProcessProgressMsg; ignoring" key
        return false
    end

    # Keep monotone across late/duplicate reports, cap below 100 (completion ends
    # the bar), and re-use the last percentage for reports that don't carry one.
    last = get(df.child_progress, key, 0)
    pct = msg.percentage === missing ? last : max(last, clamp(msg.percentage, 0, 99))
    df.child_progress[key] = pct
    _report_progress(df, _progress_key(refreshing ? "refresh" : "index", key), msg.message, pct)

    return false
end

function handle!(df::DynamicFeature, msg::ProcessIndexedMsg)
    key = msg.key

    if key in df.refreshing
        # Background refresh finished: re-emit the (idempotent) ready result —
        # freshness lands via the rewritten Manifest and the result path's
        # package-cache loading. Never touches pending_count.
        reason, target = _djp_reason_target(df, key)   # before clearing df.refreshing
        @info "Indexing child process done for $(_short_path(target)): $(reason)"
        delete!(df.refreshing, key)
        delete!(df.child_progress, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing && state(djp.fsm) == DynamicProcessIndexing
            transition!(djp.fsm, DynamicProcessDone; reason="refreshed")
        end
        put!(df.out_channel, StandaloneProjectReadyResult(filepath2uri(key.package_path), filepath2uri(msg.result_dir), key.content_hash))
        if df.djp_mode == DynamicIndexingOnly && djp !== nothing
            kill(djp)
            delete!(df.procs, key)
        end
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end

    if key ∉ df.inflight
        @debug "Stale/duplicate ProcessIndexedMsg; ignoring" key
        return false
    end

    djp = get(df.procs, key, nothing)
    if djp !== nothing && state(djp.fsm) == DynamicProcessIndexing
        transition!(djp.fsm, DynamicProcessDone; reason="indexed")
    end

    reason, target = _djp_reason_target(df, key)
    @info "Indexing child process done for $(_short_path(target)): $(reason)"

    if key isa WatchEnvironmentKey
        put!(df.out_channel, EnvironmentReadyResult(key.project_path, key.content_hash))
    elseif key isa WatchTestEnvironmentKey
        test_project_uri = filepath2uri(msg.result_dir)
        put!(df.out_channel, TestEnvironmentReadyResult(filepath2uri(key.project_path), key.package_name, test_project_uri, key.content_hash))
    elseif key isa CreateStandaloneProjectKey
        standalone_project_uri = filepath2uri(msg.result_dir)
        put!(df.out_channel, StandaloneProjectReadyResult(filepath2uri(key.package_path), standalone_project_uri, key.content_hash))
    end

    # Mark the work complete. Under DynamicIndexingOnly the child process is no
    # longer needed, so it is torn down; under DynamicPersistent (and the
    # default) the process is kept alive in `df.procs` and only the reconcile
    # path may later kill it.
    push!(df.done, key)
    if df.djp_mode == DynamicIndexingOnly && djp !== nothing
        kill(djp)
        delete!(df.procs, key)
    end

    # Decrement pending_count before freeing the slot: the free-slot drain
    # reads pending_count to decide whether a queued refresh may launch, so it
    # must see this item's own completion, not a stale pre-decrement value.
    _complete_work_item!(df, key)
    _free_slot!(df, key)
    return false
end

function handle!(df::DynamicFeature, msg::ProcessIndexFailedMsg)
    key = msg.key

    if key in df.refreshing
        # The served stale environment keeps working; do not poison
        # failed_projects over a refresh.
        @warn "Background environment refresh failed" key exception=(msg.err,)
        delete!(df.refreshing, key)
        delete!(df.child_progress, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing
            try kill(djp) catch; end
            delete!(df.procs, key)
        end
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end

    if key ∉ df.inflight
        @debug "Stale/duplicate ProcessIndexFailedMsg; ignoring" key
        return false
    end

    @error "DynamicJuliaProcess failed" key exception=(msg.err, catch_backtrace())
    # Mark this project as failed so we don't retry with the same content hash.
    push!(df.failed_projects, key)
    put!(df.out_channel, FailedResult(key))

    djp = get(df.procs, key, nothing)
    if djp !== nothing
        try kill(djp) catch; end
        delete!(df.procs, key)
    end

    # Same ordering rationale as ProcessIndexedMsg: decrement before draining.
    _complete_work_item!(df, key)
    _free_slot!(df, key)
    return false
end

function handle!(df::DynamicFeature, msg::ProcessTerminatedMsg)
    key = msg.key
    djp = get(df.procs, key, nothing)
    djp === nothing && return false

    if key in df.refreshing && state(djp.fsm) in (DynamicProcessStarting, DynamicProcessConnected, DynamicProcessIndexing)
        @warn "Background refresh process terminated unexpectedly" key
        delete!(df.refreshing, key)
        delete!(df.child_progress, key)
        try kill(djp) catch; end
        delete!(df.procs, key)
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end

    # A termination while the work item is still in flight means the process
    # died before its index request completed — treat as a failure.
    if key in df.inflight && state(djp.fsm) in (DynamicProcessStarting, DynamicProcessConnected, DynamicProcessIndexing)
        @warn "Dynamic process terminated unexpectedly" key
        push!(df.failed_projects, key)
        put!(df.out_channel, FailedResult(key))
        try kill(djp) catch; end
        delete!(df.procs, key)
        _complete_work_item!(df, key)
    end

    _free_slot!(df, key)
    return false
end

# ─── Controller messages ────────────────────────────────────────────────────

function handle!(df::DynamicFeature, ::ShutdownMsg)
    @info "Shutting down dynamic feature, terminating $(length(df.procs)) process(es)"
    transition!(df.controller_fsm, DynamicControllerShuttingDown; reason="shutdown requested")

    for (key, djp) in collect(df.procs)
        try kill(djp) catch; end
        delete!(df.procs, key)
    end

    transition!(df.controller_fsm, DynamicControllerStopped; reason="shutdown complete")
    return true
end

# ─── Reconcile ──────────────────────────────────────────────────────────────

"""
    handle!(df::DynamicFeature, msg::ReconcileMsg)

Drive the set of running dynamic processes towards `msg.required`:

  * Processes whose key is no longer required are killed and forgotten. If such
    a process was still in flight, its work item is completed so the
    pending/progress accounting stays balanced.
  * Completed (`done`) and `failed_projects` bookkeeping is pruned to the
    required set, so a key that becomes required again later is re-spawned.
  * Each required key that is not already running, in flight, completed, or
    failed is dispatched to the appropriate work handler (which performs the
    fast-lane missing-package check and, when needed, launches a child process).

This is the single place that starts and stops dynamic processes; nothing is
triggered as a side effect of Salsa input reads any more.
"""
function handle!(df::DynamicFeature, msg::ReconcileMsg)
    required = msg.required

    # ── Cancel processes that are no longer required ───────────────────────
    for (key, djp) in collect(df.procs)
        if key ∉ required
            @info "Killing stale DynamicJuliaProcess" key=key
            try kill(djp) catch; end
            delete!(df.procs, key)
            # If the work was still in flight, balance the accounting now — the
            # process's eventual ProcessTerminatedMsg is ignored once the proc
            # has been removed from `df.procs`.
            if key in df.inflight
                _complete_work_item!(df, key)
                delete!(df.launching, key)
            end
        end
    end

    # Drop completion/failure bookkeeping for keys that are no longer required,
    # so the same key becoming required again later re-spawns its work.
    filter!(k -> k in required, df.done)
    filter!(k -> k in required, df.failed_projects)

    # Queued-but-not-launched keys that are no longer required never launch;
    # balance their pending work items like the kill path above.
    filter!(df.launch_queue) do k
        k in required && return true
        _complete_work_item!(df, k)
        return false
    end

    # Refresh bookkeeping for keys that are no longer required: queued entries
    # just vanish (they are not work items); launched ones are killed.
    filter!(k -> k in required, df.refresh_queue)
    for key in collect(df.refreshing)
        key in required && continue
        delete!(df.refreshing, key)
        delete!(df.child_progress, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing
            try kill(djp) catch; end
            delete!(df.procs, key)
        end
        delete!(df.launching, key)
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
    end

    # Work items caught in their async prep window (in `inflight`, but with no
    # process, queue entry, or refresh yet) are invisible to the cancel loops
    # above. Without this a re-key orphans the stale key in `inflight` —
    # inflating `pending_count` and leaving its progress bar open forever.
    for key in collect(df.inflight)
        key in required && continue
        _complete_work_item!(df, key)
    end

    # ── Spawn work for newly-required keys ─────────────────────────────────
    known = union(Set(keys(df.procs)), df.inflight, df.done, df.failed_projects)
    for key in sort!(collect(required); by=_launch_priority)
        key in known && continue

        # Accounting that previously lived in the lazy inputs: register one
        # pending work item before dispatching the corresponding work message.
        Threads.atomic_add!(df.pending_count, 1)
        _report_progress(df, _progress_key("index", key), "Preparing to index...", 0)

        if key isa WatchEnvironmentKey
            handle!(df, WatchEnvironmentMsg(key))
        elseif key isa WatchTestEnvironmentKey
            handle!(df, WatchTestEnvironmentMsg(key))
        elseif key isa CreateStandaloneProjectKey
            handle!(df, CreateStandaloneProjectMsg(key))
        end
    end

    _drain_launch_queue!(df)

    return false
end
