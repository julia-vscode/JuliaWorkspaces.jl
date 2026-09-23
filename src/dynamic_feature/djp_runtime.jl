# ═══════════════════════════════════════════════════════════════════════════════
# Dynamic analysis process runtime
# ═══════════════════════════════════════════════════════════════════════════════
#
# Indexing children exist to *read* package metadata: `SymbolServer.get_store`
# imports every package that still lacks a `.jstore` and reflects over the
# resulting modules. Loading runs the top-level code of a package, which is
# unavoidable, but it does not by itself compile method bodies. That cost comes
# from *cache generation*: `Pkg.precompile` runs PrecompileTools
# `@compile_workload` blocks (gated on `jl_generating_output`, so they only fire
# while a cache is being written), infers and emits native code for everything
# they touch, and serializes the result. None of that produces a single extra
# symbol for the index.
#
# So children run with cache generation switched off:
#
#   * `JULIA_PKG_PRECOMPILE_AUTO=0` stops the `Pkg.instantiate`/`Pkg.develop`
#     calls on the test-env / scratch-env paths from precompiling the *whole*
#     environment, when the indexer only ever imports the handful of packages
#     that are missing a symbol cache.
#   * `--compiled-modules=existing` reuses any cache that already exists (the
#     working environment of the user is normally warm, so those imports stay
#     fast) but never writes a new one, so an uncached package is loaded from
#     source instead of triggering a full precompile.
#
# This is also what keeps child *processes* bounded: `Pkg.precompile` fans out
# up to one worker per core, so the `max_concurrent_djps` cap alone did not
# bound how many Julia processes indexing could put on the machine.
#
# The one environment that must stay precompiled is the one the child itself
# runs in: `--compiled-modules=existing` is process-wide, so without a cache for
# JuliaDynamicAnalysisProcess every child would re-load Revise,
# JuliaInterpreter and friends from source, on every launch.
#
# `djp_runtime` settles that with a single helper launch per host process that
# asks the child Julia directly. Only the child Julia can answer all of it:
# which environment it selects, whether it accepts the flag, and whether the
# caches in its own depot are current (`Base.isprecompiled` checks every include
# dependency, vendored packages included). The answer costs about a second, is
# memoized for the lifetime of the host, and is fetched when the reactor starts
# so that it overlaps with loading the workspace. Nothing is written to disc
# here; the only cache writes are the ordinary precompilation of the child
# environment, and only when the check finds it missing or stale.
#
# Nothing here assumes the child runs on the same Julia as this process: the
# version and the `--compiled-modules=existing` capability come from the child
# executable, never from `VERSION`.

"""
    DjpRuntime

Everything needed to launch a dynamic analysis child process, resolved once per
child Julia executable by [`djp_runtime`](@ref).

- `exe`: the Julia executable children are launched with.
- `version`: the version of that executable as reported by the check, or
  `nothing` when the check could not run (for instance because the executable
  rejects `--compiled-modules=existing`). Informational only.
- `project`: the child environment that executable selects, or `nothing` in the
  same cases. Only used to prepare that environment; the child script selects
  its environment itself.
- `use_existing_caches`: whether to pass `--compiled-modules=existing`. False
  when the child Julia is too old to accept it, or when preparing the child
  environment did not succeed.
"""
struct DjpRuntime
    exe::String
    version::Union{Nothing,VersionNumber}
    project::Union{Nothing,String}
    use_existing_caches::Bool
end

# The Julia executable used for indexing children. Deliberately a function, and
# deliberately the only place that choice is made: everything else derives from
# what the check reports about whatever this returns, so pointing children at a
# different Julia than the host later is a change here and nowhere else.
#
# `julia` from PATH may not resolve at all inside an editor-launched language
# server (which is started with an explicit executable path), so use the binary
# of the running process.
default_djp_julia_exe() = joinpath(Sys.BINDIR, Base.julia_exename())

_djp_root() = normpath(joinpath(@__DIR__, "..", "..", "juliadynamicanalysisprocess"))
_djp_environments_dir() = joinpath(_djp_root(), "environments")
_djp_main_script() = joinpath(_djp_root(), "app", "julia_dynamic_analysis_process_main.jl")

# ─── Child process environment ──────────────────────────────────────────────

"""
    _djp_process_env(; disable_precompile_auto)

The environment shared by indexing children and the preparation process.

The preparation process is the one caller that must be allowed to write compile
caches, so it passes `disable_precompile_auto=false`; everything else about the
environment has to match, or it would warm a depot the children never read.
"""
function _djp_process_env(; disable_precompile_auto::Bool)
    env = copy(ENV)

    delete!(env, "JULIA_DEPOT_PATH")

    # An inherited JULIA_LOAD_PATH (e.g. from a Pkg app shim) would replace the
    # default load path in the child, so `@` no longer resolves and loading
    # JuliaDynamicAnalysisProcess fails.
    delete!(env, "JULIA_LOAD_PATH")
    delete!(env, "JULIA_PROJECT")

    # Ephemeral analysis workers must not run depot auto-gc: Pkg.gc rewrites
    # ~/.julia/logs/*_usage.toml non-atomically and races other processes
    # writing those files.
    env["JULIA_PKG_GC_AUTO"] = "false"

    if disable_precompile_auto
        # Indexing needs packages loadable, not precompiled; see the comment at
        # the top of this file.
        env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    else
        delete!(env, "JULIA_PKG_PRECOMPILE_AUTO")
    end

    return env
end

"""
    _djp_launch_flags(runtime) -> Vector{String}

Extra `julia` flags for an indexing child. Empty unless the runtime is prepared
for cache-free loading.
"""
_djp_launch_flags(runtime::DjpRuntime) =
    runtime.use_existing_caches ? ["--compiled-modules=existing"] : String[]

"""
    _djp_child_cmd(runtime, script, pipe_name, extra_args) -> Cmd

The exact command one indexing child is launched with.

Split out of `start` so the launch contract — cache-free loading plus the
precompile-free environment — can be asserted without spawning anything, and so
the child and the preparation process cannot drift apart silently.
"""
function _djp_child_cmd(runtime::DjpRuntime, script::AbstractString, pipe_name::AbstractString,
        extra_args::AbstractVector=String[])
    flags = _djp_launch_flags(runtime)
    env = _djp_process_env(disable_precompile_auto=true)
    # Lets the child notice when this process is gone; see the child script.
    env["JULIA_DJP_PARENT_PID"] = string(getpid())
    return Cmd(
        `$(runtime.exe) --startup-file=no --history-file=no --depwarn=no $flags $script $pipe_name $extra_args`,
        detach = false,
        env = env,
    )
end


# Run a short-lived helper process under a deadline, capturing both streams.
# A preparation process that hangs would otherwise wedge every indexing child
# behind it, since they all wait on the same resolution.
function _run_djp_helper(cmd::Cmd, timeout_seconds::Real)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    try
        proc = run(pipeline(ignorestatus(cmd); stdout=out_io, stderr=err_io); wait=false)
        if timedwait(() -> process_exited(proc), float(timeout_seconds); pollint=0.2) !== :ok
            try kill(proc) catch; end
            try kill(proc, Base.SIGKILL) catch; end
            return (false, "", "timed out after $(timeout_seconds)s")
        end
        close(out_io)
        close(err_io)
        out = try read(out_path, String) catch; "" end
        err = try read(err_path, String) catch; "" end
        return (proc.exitcode == 0, out, err)
    catch err
        return (false, "", sprint(showerror, err))
    finally
        try close(out_io) catch; end
        try close(err_io) catch; end
        try rm(out_path; force=true) catch; end
        try rm(err_path; force=true) catch; end
    end
end

# ─── Checking and preparation ───────────────────────────────────────────────

# Runs under `--compiled-modules=existing`, in the environment the child script
# would activate. The selection below must stay identical to the one in
# `julia_dynamic_analysis_process_main.jl`; the tests hold the two together.
# One value per line, because the project path may contain spaces.
const _DJP_CHECK_CODE = raw"""
    env_dir = ARGS[1]
    versioned = joinpath(env_dir, "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
    project = isfile(versioned) ? versioned : joinpath(env_dir, "fallback")
    Base.ACTIVE_PROJECT[] = project
    pkgid = Base.identify_package("JuliaDynamicAnalysisProcess")
    precompiled = pkgid !== nothing && isdefined(Base, :isprecompiled) && Base.isprecompiled(pkgid)
    println(VERSION)
    println(project)
    println(precompiled)
    """

"""
    _check_djp_julia(exe) -> Union{Nothing,Tuple{VersionNumber,String,Bool}}

Ask `exe`, launched exactly the way cache-free children are, which version it
is, which child environment it selects, and whether that environment is
precompiled.

`nothing` means the launch did not succeed. The usual reason is that the
executable does not accept `--compiled-modules=existing` (Julia exits non-zero
before running anything). That is established by trying rather than by
comparing against the version that introduced the flag, so the answer stays
correct for Julia versions released after this code was written.
"""
function _check_djp_julia(exe::AbstractString)
    cmd = Cmd(
        `$exe --startup-file=no --history-file=no --compiled-modules=existing -e $_DJP_CHECK_CODE $(_djp_environments_dir())`,
        detach = false,
        env = _djp_process_env(disable_precompile_auto=true),
    )
    ok, out, err = _run_djp_helper(cmd, 120)
    if !ok
        @debug "Indexing Julia cannot run cache-free; children launch with default caching" exe stderr=err
        return nothing
    end
    lines = strip.(readlines(IOBuffer(out)))
    length(lines) >= 3 || return nothing
    version = tryparse(VersionNumber, lines[end-2])
    precompiled = tryparse(Bool, lines[end])
    (version === nothing || precompiled === nothing) && return nothing
    return (version, String(lines[end-1]), precompiled)
end

# Runs in the child environment, so `identify_package` resolves against it.
# `Pkg.precompile` is skipped when the cache is already good, so losing a race
# with another host process preparing the same environment costs nothing.
const _DJP_WARMUP_CODE = raw"""
    import Pkg
    pkgid = Base.identify_package("JuliaDynamicAnalysisProcess")
    pkgid === nothing && exit(2)
    if isdefined(Base, :isprecompiled)
        Base.isprecompiled(pkgid) || Pkg.precompile()
        exit(Base.isprecompiled(pkgid) ? 0 : 3)
    else
        Pkg.precompile()
        exit(0)
    end
    """

"""
    _warm_djp_runtime(exe, project) -> Bool

Build the compile caches for the child's own environment, so children launched
with `--compiled-modules=existing` find it warm. Returns whether the child
package is precompiled afterwards.
"""
function _warm_djp_runtime(exe::AbstractString, project::AbstractString)
    cmd = Cmd(`$exe --startup-file=no --history-file=no --project=$project -e $_DJP_WARMUP_CODE`,
        detach=false, env=_djp_process_env(disable_precompile_auto=false))
    ok, out, err = _run_djp_helper(cmd, 900)
    ok || @debug "Preparing the dynamic analysis runtime failed" project stdout=out stderr=err
    return ok
end

function _resolve_djp_runtime(exe::AbstractString, progress)
    checked = _check_djp_julia(exe)
    checked === nothing && return DjpRuntime(exe, nothing, nothing, false)

    version, project, precompiled = checked
    precompiled && return DjpRuntime(exe, version, project, true)

    @info "Preparing the Julia indexing runtime (precompiling the indexer environment)..."
    progress === nothing || progress("Preparing the Julia indexing runtime...", 0)
    prepared = try
        _warm_djp_runtime(exe, project)
    finally
        progress === nothing || progress("Done", 100)
    end
    prepared || @warn "Could not prepare the Julia indexing runtime; indexing processes will fall back to building their own caches."
    return DjpRuntime(exe, version, project, prepared)
end

const _DJP_RUNTIME_LOCK = ReentrantLock()
const _DJP_RUNTIME_CACHE = Dict{String,DjpRuntime}()

"""
    djp_runtime(exe; progress=nothing) -> DjpRuntime

Resolve, and if necessary prepare, the runtime indexing children launch with.

Memoized per executable for the lifetime of the process, so the whole cost is
one helper launch per host session, plus one precompilation of the child
environment when the check finds it missing or stale.

Never call this on the reactor: the first caller may block for as long as
preparing the child environment takes, and concurrent callers queue behind it
rather than each checking and preparing the same thing. `progress`, a
`(message, percentage)` callback, is only invoked when preparation actually
runs, so the common case shows nothing.
"""
function djp_runtime(exe::AbstractString; progress=nothing)
    return lock(_DJP_RUNTIME_LOCK) do
        get!(_DJP_RUNTIME_CACHE, String(exe)) do
            _resolve_djp_runtime(exe, progress)
        end
    end
end

# Test seam: drop the in-process memo so a test can exercise resolution again.
function _reset_djp_runtime_cache!()
    lock(_DJP_RUNTIME_LOCK) do
        empty!(_DJP_RUNTIME_CACHE)
    end
    return nothing
end
