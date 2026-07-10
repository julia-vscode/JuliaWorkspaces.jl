# Orchestration: bounded worker pool with resume, timeout, shard, JSONL logging,
# and optional packaging.

struct Result
    pv::PkgVersion
    status::Symbol        # :ok :failed :timeout :unsatisfiable  (or :pending for dry-run/report-missing worklist output)
    duration::Float64
    bytes::Int
    error::String
end

Base.@kwdef mutable struct IndexOpts
    store::String
    depot::String
    workdir::String
    jwroot::String                                  # the package's src/ dir
    jobs::Int = max(1, Sys.CPU_THREADS ÷ 2)
    timeout::Float64 = 600.0
    resume::Bool = true
    progress::Bool = true                           # one stderr line per completion
    launcher::Function = default_launcher
    # PATH-relative so a container launcher uses the image's own julia; on the
    # host it resolves to whatever `julia` is on PATH (the driver was launched
    # via one). Set to an absolute path if you need workers pinned to a specific
    # julia regardless of PATH.
    julia_exe::String = Base.julia_exename()
    logfile::Union{Nothing,String} = nothing
    done::Union{Nothing,Set{String}} = nothing
end

# Deterministic, process-independent hash for sharding (FNV-1a 64-bit).
function fnv1a(s::AbstractString)
    h = 0xcbf29ce484222325
    for b in codeunits(s)
        h = (h ⊻ b) * 0x100000001b3
    end
    return h
end

shard_select(rows::Vector{PkgVersion}, k::Int, n::Int) =
    filter(pv -> Int(fnv1a(string(pv.name, "@", pv.version)) % n) == k, rows)

function _jstr(s::AbstractString)
    buf = replace(String(s),
        '\\' => "\\\\", '"' => "\\\"", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t")
    # Escape any remaining control characters below 0x20 as \uXXXX.
    buf = join(UInt32(c) < 0x20 ? "\\u" * string(UInt32(c), base=16, pad=4) : string(c)
               for c in buf)
    return string('"', buf, '"')
end

function to_json_line(r::Result)
    return string("{",
        _jstr("name"), ":", _jstr(r.pv.name), ",",
        _jstr("uuid"), ":", _jstr(string(r.pv.uuid)), ",",
        _jstr("version"), ":", _jstr(string(r.pv.version)), ",",
        _jstr("treehash"), ":", _jstr(r.pv.tree_hash), ",",
        _jstr("status"), ":", _jstr(string(r.status)), ",",
        _jstr("duration_s"), ":", string(round(r.duration; digits=3)), ",",
        _jstr("bytes"), ":", string(r.bytes), ",",
        _jstr("error"), ":", _jstr(r.error),
        "}")
end

function _worker_cmd(pv::PkgVersion, env::String, opts::IndexOpts)
    worker = joinpath(opts.jwroot, "CloudIndex", "worker.jl")
    inner = `$(opts.julia_exe) --startup-file=no --history-file=no --compiled-modules=existing --project=$env $worker $(opts.jwroot) $(opts.store) $(string(pv.uuid)) $(pv.name) $(string(pv.version)) $(pv.tree_hash)`
    # Workers install into opts.depot (the first, writable entry); the trailing ':'
    # appends the default depots so they reuse the built-in precompiled Pkg/stdlib
    # caches (and the existing registry) instead of recompiling Pkg every worker.
    # Used by the default (host) launcher; a container launcher sets its own
    # JULIA_DEPOT_PATH (the template only splices argv, not this env).
    spec = LaunchSpec(addenv(inner, "JULIA_DEPOT_PATH" => string(opts.depot, ":")),
                      opts.depot, opts.store, env, opts.jwroot)
    return opts.launcher(spec)
end

function _run_one(pv::PkgVersion, opts::IndexOpts, cancelled::Ref{Bool} = Ref(false))
    env = mktempdir(opts.workdir)
    cmd = _worker_cmd(pv, env, opts)
    errlog = joinpath(env, "stderr.log")
    t0 = time()
    proc = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = errlog); wait = false)
    finished = try
        timedwait(() -> process_exited(proc), opts.timeout; pollint = 0.2)
    catch
        # Interrupted (or errored) while waiting — don't leave the worker orphaned.
        Base.process_running(proc) && (kill(proc); kill(proc, Base.SIGKILL))
        rethrow()
    end
    dur = time() - t0
    if finished === :timed_out
        kill(proc); kill(proc, Base.SIGKILL)
        wait(proc)
        return Result(pv, :timeout, dur, 0, "killed after $(opts.timeout)s")
    end
    ec = proc.exitcode
    # The signal that killed the worker, if any (process_signaled, or Julia's
    # 128+signal exit code from a caught InterruptException).
    sig = Base.process_signaled(proc) ? Int(proc.termsignal) :
          (128 < ec < 160 ? ec - 128 : nothing)
    # SIGINT means the batch was interrupted (Ctrl-C reaches the worker process
    # group); so does any signal once the batch is already shutting down. Those are
    # retryable: record :cancelled, don't tombstone. Any OTHER signal (SIGSEGV,
    # SIGKILL/OOM, ...) is the worker crashing on its own — a real failure.
    if sig == 2 || (sig !== nothing && cancelled[])
        return Result(pv, :cancelled, dur, 0, "killed by signal $sig")
    end
    status = sig !== nothing ? :failed : ec == 0 ? :ok : ec == 10 ? :unsatisfiable : :failed
    bytes = 0
    if status === :ok
        jstore = joinpath(opts.store, cache_relpath(pv.name, pv.uuid, pv.tree_hash)...)
        bytes = isfile(jstore) ? Int(filesize(jstore)) : 0
    end
    # Capture the worker's full stderr: the env dir is cleaned up on exit, so the
    # JSONL log is the only durable record, and the real error is usually buried
    # above the trailing precompile noise — so don't truncate.
    errmsg = status === :ok ? "" : (isfile(errlog) ? rstrip(read(errlog, String)) : "")
    sig === nothing || (errmsg = isempty(errmsg) ? "killed by signal $sig" :
                                 string("killed by signal ", sig, "\n", errmsg))
    # Tombstone deterministic failures so resume doesn't retry them. Timeouts are
    # left untombstoned (they may be transient and are worth retrying).
    if status === :failed || status === :unsatisfiable
        try
            tomb = joinpath(opts.store, tombstone_relpath(pv.name, pv.uuid, pv.tree_hash)...)
            mkpath(dirname(tomb))
            write(tomb, string(status, "\n"))
        catch err
            errmsg = string(errmsg, " | tombstone error: ", err)
        end
    end
    return Result(pv, status, dur, bytes, errmsg)
end


# One line of the worker's stderr for the progress output: prefer the terse
# `jwcloudindex-worker:` summary the worker prints on failure, else the first
# non-empty line; truncated so a resolver conflict dump cannot flood the log.
function _error_snippet(errmsg::AbstractString; maxlen::Int = 200)
    lines = split(errmsg, '\n')
    i = findfirst(l -> startswith(l, "jwcloudindex-worker:"), lines)
    i === nothing && (i = findfirst(l -> !isempty(strip(l)), lines))
    i === nothing && return ""
    s = strip(lines[i])
    return length(s) <= maxlen ? String(s) : string(first(s, maxlen - 1), "…")
end

# CI-friendly progress: one plain, newline-terminated line per completion (no
# cursor control / carriage returns), e.g. "[  3/120] ok            Foo@1.2.0  (23.1s)".
# Non-ok results carry a one-line error snippet so systemic failures (broken
# network/mounts in the worker environment) are visible without results.jsonl.
function _progress_line(done::Int, total::Int, r::Result)
    w = ndigits(total)
    line = string("[", lpad(done, w), "/", total, "] ",
                  rpad(string(r.status), 13), " ",
                  r.pv.name, "@", r.pv.version, "  (", round(r.duration; digits = 1), "s)")
    snip = r.status === :ok || r.status === :cancelled ? "" : _error_snippet(r.error)
    return isempty(snip) ? line : string(line, "  — ", snip)
end

"""
    run_index(rows, opts) -> Vector{Result}

Run workers over `rows` with at most `opts.jobs` concurrent. Resume (skip cached)
is applied first. Each result is appended to `opts.logfile` (JSONL) as it completes.
"""
function run_index(rows::Vector{PkgVersion}, opts::IndexOpts)
    mkpath(opts.store); mkpath(opts.workdir); mkpath(opts.depot)
    todo = !opts.resume ? rows :
           opts.done !== nothing ? find_missing(rows, opts.done) :
           find_missing(rows, opts.store)
    total = length(todo)
    if opts.progress
        skipped = length(rows) - total
        println(stderr, "jwcloudindex: indexing ", total, " version(s) with ",
                opts.jobs, " worker(s)",
                skipped > 0 ? string(" (", skipped, " already cached, skipped)") : "")
        flush(stderr)
    end
    loglock = ReentrantLock()
    logio = opts.logfile === nothing ? nothing : open(opts.logfile, "a")
    done = 0
    cancelled = Ref(false)
    try
        function log_and_return(r::Result)
            lock(loglock) do
                done += 1
                if logio !== nothing
                    println(logio, to_json_line(r)); flush(logio)
                end
                if opts.progress
                    println(stderr, _progress_line(done, total, r)); flush(stderr)
                end
            end
            return r
        end
        results = asyncmap(todo; ntasks = opts.jobs) do pv
            # Once interrupted, don't start new work — let the batch wind down ASAP.
            cancelled[] && return Result(pv, :cancelled, 0.0, 0, "")
            t0 = time()
            r = try
                _run_one(pv, opts, cancelled)
            catch err
                # An interrupt must stop the whole batch, not be swallowed as a
                # per-item failure that lets the pool move on to the next version.
                if err isa InterruptException
                    cancelled[] = true
                    rethrow()
                end
                Result(pv, :failed, time() - t0, 0, sprint(showerror, err))
            end
            log_and_return(r)
        end
        return collect(Result, results)
    catch err
        # A child task's InterruptException surfaces wrapped (TaskFailedException/
        # CompositeException), so detect the interrupt via the flag the closure set
        # and normalize to a clean InterruptException for callers.
        (cancelled[] || err isa InterruptException) || rethrow()
        println(stderr, "jwcloudindex: interrupted — no new workers; $done version(s) done (see log).")
        throw(InterruptException())
    finally
        logio === nothing || close(logio)
    end
end
