# ═══════════════════════════════════════════════════════════════════════════════
# Dynamic analysis process runtime
# ═══════════════════════════════════════════════════════════════════════════════
#
# Indexing children exist to *read* package metadata: `SymbolServer.get_store`
# imports every package that still lacks a `.jstore` and reflects over the
# resulting modules. Loading runs a package's top-level code, which is
# unavoidable — but it does not, on its own, compile method bodies. That cost
# comes from *cache generation*: `Pkg.precompile` runs PrecompileTools
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
#     user's own working environment is normally warm, so those imports stay
#     fast) but never writes a new one, so an uncached package is loaded from
#     source instead of triggering a full precompile.
#
# This is also what keeps child *processes* bounded: `Pkg.precompile` fans out
# up to one worker per core, so the `max_concurrent_djps` cap alone did not
# bound how many Julia processes indexing could put on the machine.
#
# The one thing that must stay precompiled is the child's *own* environment —
# `--compiled-modules=existing` is process-wide, so without a cache for
# JuliaDynamicAnalysisProcess every child would re-load Revise, JuliaInterpreter
# and friends from source, on every launch. `djp_runtime` prepares that once and
# records the outcome in a stamp file, so the preparation process is skipped
# entirely on later runs — including across restarts of the host process.
#
# Nothing here assumes the child runs on the same Julia as this process: the
# version and the `--compiled-modules=existing` capability are *probed* from the
# child executable, never taken from `VERSION`.

"""
    DjpRuntime

Everything needed to launch a dynamic analysis child process, resolved once per
child Julia executable by [`djp_runtime`](@ref).

- `exe`: the Julia executable children are launched with.
- `version`: that executable's version — probed, not assumed.
- `project`: the child environment matching `version` (only used to prepare the
  child's own caches; the child script selects its environment itself).
- `use_existing_caches`: whether to pass `--compiled-modules=existing`. False
  when the child Julia is too old to accept it, or when preparing the child's
  own caches did not succeed.
"""
struct DjpRuntime
    exe::String
    version::VersionNumber
    project::String
    use_existing_caches::Bool
end

# The Julia executable used for indexing children. Deliberately a function, and
# deliberately the only place that choice is made: everything else derives from
# the *probed* properties of whatever this returns, so pointing children at a
# different Julia than the host later is a change here and nowhere else.
#
# `julia` from PATH may not resolve at all inside an editor-launched language
# server (which is started with an explicit executable path), so use the running
# process's own binary.
default_djp_julia_exe() = joinpath(Sys.BINDIR, Base.julia_exename())

_djp_root() = normpath(joinpath(@__DIR__, "..", "..", "juliadynamicanalysisprocess"))
_djp_environments_dir() = joinpath(_djp_root(), "environments")
_djp_main_script() = joinpath(_djp_root(), "app", "julia_dynamic_analysis_process_main.jl")
# `symbolserver.jl` in the child package includes these, so they are part of
# what its compile cache is built from.
_djp_shared_dir() = normpath(joinpath(@__DIR__, "..", "..", "shared", "symbolserver"))

"""
    _djp_project_for_version(version) -> String

The child environment for `version`, mirroring the selection the child script
makes for itself: a `vMAJOR.MINOR` directory when one exists, else `fallback`.
"""
function _djp_project_for_version(version::VersionNumber)
    env_dir = _djp_environments_dir()
    versioned = joinpath(env_dir, "v$(version.major).$(version.minor)")
    isfile(joinpath(versioned, "Project.toml")) && return versioned
    return joinpath(env_dir, "fallback")
end

# ─── Stamp ──────────────────────────────────────────────────────────────────
#
# Preparation costs two child process launches, so its result is cached on disc
# under a fingerprint of everything that can invalidate it. A *hit* means zero
# extra processes, which is the whole point: the common case is an unchanged
# extension on an unchanged Julia, restarted many times.
#
# The fingerprint covers the child executable (path, size, mtime — so a juliaup
# channel update or an in-place upgrade invalidates it) and the child package's
# own source tree plus the shared symbolserver sources it includes. It does NOT
# cover the vendored packages under `scripts/packages/`, which the child package
# includes: fingerprinting those means stat-ing ~2200 files, which costs tens of
# seconds on a cold Windows filesystem and would dwarf what the stamp saves. An
# extension update rewrites the child tree too, so released versions are
# covered; editing a vendored package in a *development* checkout is the one
# case that needs the stamp directory deleted by hand.

const _DJP_STAMP_FORMAT = "1"

_djp_runtime_dir(store_path::AbstractString) = joinpath(dirname(store_path), "djp-runtime")

_djp_stamp_path(store_path::AbstractString, fingerprint::UInt64) =
    joinpath(_djp_runtime_dir(store_path), string(string(fingerprint, base=16, pad=16), ".stamp"))

# Fold every file under `root` into `h`. Sorted by path so the hash does not
# depend on directory iteration order, and tolerant of IO errors: an unreadable
# tree yields a different-but-stable hash rather than throwing.
function _fingerprint_tree(h::UInt64, root::AbstractString)
    isdir(root) || return hash(:missing, h)
    entries = Tuple{String,Int64,Float64}[]
    try
        for (dir, _, files) in walkdir(root; onerror = _ -> nothing)
            for f in files
                path = joinpath(dir, f)
                st = try
                    stat(path)
                catch
                    continue
                end
                push!(entries, (relpath(path, root), st.size, st.mtime))
            end
        end
    catch
        return hash(:unreadable, h)
    end
    sort!(entries)
    for entry in entries
        h = hash(entry, h)
    end
    return h
end

function _djp_runtime_fingerprint(exe::AbstractString)
    h = hash(_DJP_STAMP_FORMAT, hash("djp-runtime"))
    h = hash(exe, h)
    h = try
        st = stat(exe)
        hash((st.size, st.mtime), h)
    catch
        hash(:no_exe, h)
    end
    h = _fingerprint_tree(h, _djp_root())
    h = _fingerprint_tree(h, _djp_shared_dir())
    return h
end

# Three fixed lines: format tag, child Julia version, launch mode. A plain
# line-based format because the payload carries no text that would need
# escaping, and a stamp that cannot be parsed is simply treated as absent.
function _read_djp_stamp(path::AbstractString)
    isfile(path) || return nothing
    lines = try
        readlines(path)
    catch
        return nothing
    end
    length(lines) >= 3 || return nothing
    strip(lines[1]) == _DJP_STAMP_FORMAT || return nothing
    version = tryparse(VersionNumber, strip(lines[2]))
    version === nothing && return nothing
    mode = strip(lines[3])
    mode in ("existing", "plain") || return nothing
    return (version, mode == "existing")
end

# Written only for a *definitive* outcome, so a transient preparation failure
# retries on the next run instead of locking in the degraded launch mode.
# Stale siblings are pruned: one stamp would otherwise accumulate per update.
function _write_djp_stamp(path::AbstractString, version::VersionNumber, use_existing::Bool)
    try
        dir = dirname(path)
        mkpath(dir)
        for other in readdir(dir; join=true)
            endswith(other, ".stamp") && other != path && try rm(other; force=true) catch; end
        end
        tmp = string(path, ".", getpid(), ".tmp")
        open(tmp, "w") do io
            println(io, _DJP_STAMP_FORMAT)
            println(io, version)
            println(io, use_existing ? "existing" : "plain")
        end
        mv(tmp, path; force=true)
    catch err
        # A stamp we cannot write only costs the preparation launches again.
        @debug "Could not write dynamic analysis runtime stamp" path exception=(err, catch_backtrace())
    end
    return nothing
end

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
    return Cmd(
        `$(runtime.exe) --startup-file=no --history-file=no --depwarn=no $flags $script $pipe_name $extra_args`,
        detach = false,
        env = _djp_process_env(disable_precompile_auto=true),
    )
end

# ─── Probing and preparation ────────────────────────────────────────────────

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

"""
    _probe_djp_julia(exe) -> Union{Nothing,Tuple{VersionNumber,Bool}}

Ask `exe` what version it is and whether it accepts `--compiled-modules=existing`.

Capability is established by *trying* the flag rather than comparing against the
version that introduced it: an unsupported value makes Julia exit non-zero
before running anything, so one launch answers both questions and the answer
stays correct for Julia versions released after this code was written.
"""
function _probe_djp_julia(exe::AbstractString)
    for (extra, supports_existing) in ((["--compiled-modules=existing"], true), (String[], false))
        cmd = `$exe --startup-file=no --history-file=no $extra -e "print(VERSION)"`
        ok, out, _ = _run_djp_helper(cmd, 120)
        if ok
            version = tryparse(VersionNumber, strip(out))
            version === nothing || return (version, supports_existing)
        end
    end
    return nothing
end

# Runs in the child environment, so `identify_package` resolves against it.
# `Pkg.precompile` is skipped when the cache is already good, which makes a
# stamp that was lost (but whose caches survive) cheap to rebuild.
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

function _resolve_djp_runtime(exe::AbstractString, store_path::AbstractString, on_prepare)
    fingerprint = _djp_runtime_fingerprint(exe)
    stamp = _djp_stamp_path(store_path, fingerprint)

    stamped = _read_djp_stamp(stamp)
    if stamped !== nothing
        version, use_existing = stamped
        @debug "Reusing prepared dynamic analysis runtime" exe version use_existing
        return DjpRuntime(exe, version, _djp_project_for_version(version), use_existing)
    end

    on_prepare === nothing || on_prepare()

    probed = _probe_djp_julia(exe)
    if probed === nothing
        # Nothing about the child executable could be established. Launch
        # children the conservative way (they still select their own
        # environment) and do not stamp, so this is retried next time.
        @warn "Could not determine the version of the Julia used for indexing; launching indexing processes with conservative settings." exe
        return DjpRuntime(exe, VERSION, _djp_project_for_version(VERSION), false)
    end

    version, supports_existing = probed
    project = _djp_project_for_version(version)

    if !supports_existing
        # Definitive: this Julia will never accept the flag.
        @debug "Indexing Julia does not support --compiled-modules=existing" exe version
        _write_djp_stamp(stamp, version, false)
        return DjpRuntime(exe, version, project, false)
    end

    @info "Preparing the Julia indexing runtime (one-time; later sessions reuse it)..."
    if _warm_djp_runtime(exe, project)
        _write_djp_stamp(stamp, version, true)
        return DjpRuntime(exe, version, project, true)
    end

    # Possibly transient (a busy depot, a killed process), so no stamp: let
    # children build their own caches this session and try again next time.
    @warn "Could not prepare the Julia indexing runtime; indexing processes will fall back to building their own caches."
    return DjpRuntime(exe, version, project, false)
end

const _DJP_RUNTIME_LOCK = ReentrantLock()
const _DJP_RUNTIME_CACHE = Dict{String,DjpRuntime}()

"""
    djp_runtime(exe, store_path; on_prepare=nothing) -> DjpRuntime

Resolve — and if necessary prepare — the runtime indexing children launch with.

Memoized per executable for the lifetime of the process, and persisted across
restarts by a stamp file under `store_path`, so the steady state costs no extra
process launches at all.

Called from each child's own launch task, never from the reactor: the first
caller may block for as long as preparing the child environment takes, and
concurrent callers queue behind it rather than each preparing the same thing.
`on_prepare` is invoked (once) only when that slow path is actually taken, so a
caller can report progress without flashing a message in the common case.
"""
function djp_runtime(exe::AbstractString, store_path::AbstractString; on_prepare=nothing)
    return lock(_DJP_RUNTIME_LOCK) do
        get!(_DJP_RUNTIME_CACHE, String(exe)) do
            _resolve_djp_runtime(exe, store_path, on_prepare)
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
