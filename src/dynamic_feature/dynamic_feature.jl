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

function create_standalone_project(djp::DynamicJuliaProcess, store_path::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.create_standalone_project_request_type,
        JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams(
            djp.project_path,
            store_path
        )
    )
end

# Exception thrown when the child process exits before establishing a connection.
struct DynamicProcessCrashException <: Exception
    key::DJPKey
    exitcode::Union{Int,Nothing}
end

# Dispatch handler for JSONRPC messages received FROM the dynamic analysis
# process. The protocol currently defines no child→parent notifications, so this
# is a placeholder that keeps the message loop functional and future-proof.
function dispatch_dynamicprocess_msg(endpoint, msg, ctx)
    @debug "Received message from dynamic analysis process" method=msg.method
    return nothing
end

# Spawn and supervise a single child Julia analysis process. Modeled after
# `TestItemControllers.start(::TestProcessState, ...)`: a long-lived task that
# owns the child process for its whole lifetime, uses nested `try/finally`
# blocks to guarantee resource cleanup, drives cancellation via a
# `CancellationToken`, and runs a message loop that reads messages from the
# child. Lifecycle events are reported back to the reactor via `reactor_channel`.
function start(djp::DynamicJuliaProcess, reactor_channel::Channel, token::CancellationTokens.CancellationToken)
    @info "Starting DynamicJuliaProcess" kind=djp.kind project_path=djp.project_path package=djp.package

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

            jl_process = open(
                pipeline(
                    Cmd(`julia --startup-file=no --history-file=no --depwarn=no $julia_dynamic_analysis_process_script $pipe_name $(error_handler_file...) $(crash_reporting_pipename...)`, detach=false, env=env_to_use),
                    stdout = pipe_out,
                    stderr = pipe_out
                )
            )

            proc_kill_registration = CancellationTokens.register(token) do
                @info "Killing DynamicJuliaProcess due to cancellation" kind=djp.kind project_path=djp.project_path
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
    @info "Killing DynamicJuliaProcess" kind=djp.kind project_path=djp.project_path package=djp.package

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

const DEFAULT_SYMBOLCACHE_UPSTREAM = "https://www.julia-vscode.org/symbolcache"

mutable struct ProgressState
    total_items::Int
    completed_items::Int
    current_sub_progress::Float64
    current_message::String
end

ProgressState() = ProgressState(0, 0, 0.0, "")

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
    missing_pkg_metadata::Set{@NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}}
    pending_count::Threads.Atomic{Int}
    update_channel::Channel{Symbol}
    progress_callback::Union{Nothing,Function}
    progress_state::ProgressState
    controller_fsm::FSM{DynamicControllerPhase}

    function DynamicFeature(djp_mode::DynamicMode, store_path::String; download_enabled::Bool=false, upstream_url::String=DEFAULT_SYMBOLCACHE_UPSTREAM, progress_callback::Union{Nothing,Function}=nothing)
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
            Set{@NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}}(),
            Threads.Atomic{Int}(0),
            Channel{Symbol}(100),
            progress_callback,
            ProgressState(),
            dynamic_controller_fsm("dynamic_controller")
        )
    end
end

"""
    _report_progress(df::DynamicFeature, message::String)

Compute the aggregated progress percentage from `df.progress_state` and invoke
`df.progress_callback` if one is registered.
"""
function _report_progress(df::DynamicFeature, message::String)
    df.progress_callback === nothing && return
    ps = df.progress_state
    ps.current_message = message
    if ps.total_items == 0
        pct = 0
    else
        pct = floor(Int, (ps.completed_items + ps.current_sub_progress) / ps.total_items * 100)
        pct = clamp(pct, 0, 100)
    end
    try
        df.progress_callback(message, pct)
    catch err
        @warn "progress_callback threw" exception=(err, catch_backtrace())
    end
    return
end

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

        if haskey(entry, "git-tree-sha1") && haskey(entry, "version")
            # Regular package
            ver = entry["version"]
            tree_sha = entry["git-tree-sha1"]
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), string(k_entry, "_", uuid), string("v", ver, "_", tree_sha, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver, tree_sha)))
            end
        elseif !haskey(entry, "git-tree-sha1")
            # Stdlib package
            ver_str = get(entry, "version", nothing)
            ver_str === nothing && continue
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), string(k_entry, "_", uuid), string("v", ver_str, "_nothing.jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver_str, nothing)))
            end
        end
    end

    return missing
end

const GENERAL_REGISTRY_UUID = UUID("23338594-aafe-5451-b93e-139f81909106")

"""
    _get_general_registry_packages() -> Dict{UUID, NamedTuple}

Return a dict mapping UUID => (;name) for all packages in the General registry.
Used to filter out private packages from cloud download requests.
"""
function _get_general_registry_packages()
    dp_before = copy(Base.DEPOT_PATH)
    try
        push!(empty!(Base.DEPOT_PATH), joinpath(homedir(), ".julia"))
        regs = Pkg.Types.Context().registries
        i = findfirst(r -> r.name == "General" && r.uuid == GENERAL_REGISTRY_UUID, regs)
        i === nothing && return Dict{UUID,@NamedTuple{name::String}}()
        return Dict{UUID,@NamedTuple{name::String}}(
            uuid => (;name=info.name) for (uuid, info) in regs[i].pkgs
        )
    catch err
        @warn "Failed to read General registry" exception=(err, catch_backtrace())
        return Dict{UUID,@NamedTuple{name::String}}()
    finally
        append!(empty!(Base.DEPOT_PATH), dp_before)
    end
end

"""
    _download_single_cache(pkg, store_path, upstream_url, download_dir) -> Bool

Download a single .jstore.tar.gz from the cloud, unpack it, and move it to the
store path. Returns true on success, false on failure.
"""
function _download_single_cache(pkg::MissingPackage, store_path::String, upstream_url::String, download_dir::String)
    name, uuid, version, git_tree_sha1 = pkg
    tree_hash_str = git_tree_sha1 === nothing ? "nothing" : git_tree_sha1

    letter = uppercase(name[1:1])
    name_uuid = string(name, "_", uuid)
    filename = string("v", version, "_", tree_hash_str, ".jstore")

    dest_dir = joinpath(store_path, letter, name_uuid)
    dest_filepath = joinpath(dest_dir, filename)
    dest_filepath_unavailable = string(first(splitext(dest_filepath)), ".unavailable")

    # Skip if we already know it's unavailable
    if isfile(dest_filepath_unavailable)
        @debug "Cloud cache unavailable marker exists, skipping" name=name
        return false
    end

    link = string(upstream_url, "/store/v1/packages/", letter, "/", name_uuid, "/", first(splitext(filename)), ".tar.gz")

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

Download missing package caches from the cloud. Filters to General registry
packages only (to avoid leaking private package names via URL requests).
Returns the list of packages still missing after download.
If `df` is provided, progress is reported through its callback.
"""
function _download_missing_caches(missing_pkgs::Vector{MissingPackage}, store_path::String, upstream_url::String; df::Union{Nothing,DynamicFeature}=nothing)
    general_pkgs = _get_general_registry_packages()
    if isempty(general_pkgs)
        @warn "Could not read General registry, skipping cloud downloads"
        return missing_pkgs
    end

    # Filter to General registry packages with tree_hash (no stdlibs, no _jll)
    downloadable = filter(missing_pkgs) do pkg
        pkg.git_tree_sha1 === nothing && return false  # stdlibs
        endswith(pkg.name, "_jll") && return false     # JLL packages
        info = get(general_pkgs, pkg.uuid, nothing)
        info === nothing && return false                # not in General
        info.name != pkg.name && return false           # UUID/name mismatch
        return true
    end

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
                    if df !== nothing
                        df.progress_state.current_sub_progress = downloaded_count[] / total_downloadable * 0.5
                        _report_progress(df, "Downloading caches ($(downloaded_count[])/$total_downloadable)...")
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
    df.progress_state.completed_items += 1
    df.progress_state.current_sub_progress = 0.0
    if df.pending_count[] == 0
        _report_progress(df, "Indexing complete")
        # Reset for the next round of indexing
        df.progress_state.total_items = 0
        df.progress_state.completed_items = 0
    end
    try put!(df.update_channel, :data_available) catch; end
    return true
end

# Transition a freshly-created DJP into its supervised `start` task.
function _launch_process!(df::DynamicFeature, djp::DynamicJuliaProcess)
    transition!(djp.fsm, DynamicProcessStarting; reason="launching")
    token = CancellationTokens.get_token(djp.cancellation_source)
    djp.task = Threads.@async start(djp, df.in_channel, token)
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
    Threads.@async try
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
    key = WatchEnvironmentKey(msg.project_path, msg.content_hash)
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
    project_path = msg.project_path
    content_hash = msg.content_hash
    Threads.@async try
        missing_pkgs = _get_missing_packages(project_path, df.store_path)

        if !isempty(missing_pkgs) && df.download_enabled
            @info "Downloading missing package caches" count=length(missing_pkgs)
            _report_progress(df, "Downloading caches for $(basename(project_path))...")
            missing_pkgs = _download_missing_caches(missing_pkgs, df.store_path, df.upstream_url; df=df)
        end

        put!(df.in_channel, EnvironmentPrepDoneMsg(project_path, content_hash, !isempty(missing_pkgs)))
    catch err
        @error "Environment prep failed" project_path=project_path exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(key, err))
    end

    return false
end

function handle!(df::DynamicFeature, msg::EnvironmentPrepDoneMsg)
    key = WatchEnvironmentKey(msg.project_path, msg.content_hash)
    df.progress_state.current_sub_progress = 0.5

    if !msg.still_missing
        @info "All package caches available, skipping DJP" project_path=msg.project_path
        _report_progress(df, "All caches available for $(basename(msg.project_path))")
        put!(df.out_channel, EnvironmentReadyResult(msg.project_path, msg.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
    elseif df.djp_mode != DynamicOff
        @info "Launching DJP for remaining missing packages" project_path=msg.project_path
        _report_progress(df, "Indexing $(basename(msg.project_path))...")
        djp = DynamicJuliaProcess(key, msg.project_path, nothing, :watch_environment)
        df.procs[key] = djp
        _launch_process!(df, djp)
    else
        @info "Some packages missing but DJP disabled, proceeding with best-effort" project_path=msg.project_path
        put!(df.out_channel, EnvironmentReadyResult(msg.project_path, msg.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
    end

    return false
end

function handle!(df::DynamicFeature, msg::WatchTestEnvironmentMsg)
    key = WatchTestEnvironmentKey(msg.project_path, msg.package, msg.content_hash)
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed test environment" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    _report_progress(df, "Indexing test environment for $(msg.package)...")
    djp = DynamicJuliaProcess(key, msg.project_path, msg.package, :watch_test_environment)
    df.procs[key] = djp
    _launch_process!(df, djp)

    return false
end

function handle!(df::DynamicFeature, msg::CreateStandaloneProjectMsg)
    key = CreateStandaloneProjectKey(msg.package_path, msg.content_hash)
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed standalone project" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    _report_progress(df, "Creating standalone project for $(basename(msg.package_path))...")
    djp = DynamicJuliaProcess(key, msg.package_path, nothing, :create_standalone_project)
    df.procs[key] = djp
    _launch_process!(df, djp)

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
    Threads.@async try
        result_dir = if key isa CreateStandaloneProjectKey
            create_standalone_project(djp, df.store_path)
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

function handle!(df::DynamicFeature, msg::ProcessIndexedMsg)
    key = msg.key
    if key ∉ df.inflight
        @debug "Stale/duplicate ProcessIndexedMsg; ignoring" key
        return false
    end

    djp = get(df.procs, key, nothing)
    if djp !== nothing && state(djp.fsm) == DynamicProcessIndexing
        transition!(djp.fsm, DynamicProcessDone; reason="indexed")
    end

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

    _complete_work_item!(df, key)
    return false
end

function handle!(df::DynamicFeature, msg::ProcessIndexFailedMsg)
    key = msg.key
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

    _complete_work_item!(df, key)
    return false
end

function handle!(df::DynamicFeature, msg::ProcessTerminatedMsg)
    key = msg.key
    djp = get(df.procs, key, nothing)
    djp === nothing && return false

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
            end
        end
    end

    # Drop completion/failure bookkeeping for keys that are no longer required,
    # so the same key becoming required again later re-spawns its work.
    filter!(k -> k in required, df.done)
    filter!(k -> k in required, df.failed_projects)

    # ── Spawn work for newly-required keys ─────────────────────────────────
    known = union(Set(keys(df.procs)), df.inflight, df.done, df.failed_projects)
    for key in required
        key in known && continue

        # Accounting that previously lived in the lazy inputs: register one
        # pending work item before dispatching the corresponding work message.
        Threads.atomic_add!(df.pending_count, 1)
        df.progress_state.total_items += 1
        _report_progress(df, "Preparing to index...")

        if key isa WatchEnvironmentKey
            handle!(df, WatchEnvironmentMsg(key.project_path, key.content_hash))
        elseif key isa WatchTestEnvironmentKey
            handle!(df, WatchTestEnvironmentMsg(key.project_path, key.package_name, key.content_hash))
        elseif key isa CreateStandaloneProjectKey
            handle!(df, CreateStandaloneProjectMsg(key.package_path, key.content_hash))
        end
    end

    return false
end
