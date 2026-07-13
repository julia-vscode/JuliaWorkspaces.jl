# Pidfile-based cross-process mutex for Pkg installs into a shared depot.
#
# Pkg replaces an existing packages/<name>/<slug> tree with
# `mv(unpacked, version_path; force = true)`: the destination is deleted and
# (across filesystems) recopied non-atomically, so concurrent installs of the
# same version corrupt each other (readdir ENOENT / rm ENOTEMPTY). The pidfile
# lives on the shared depot mount, so it serializes workers across containers
# too.
#
# stale_age matters: containers have distinct hostnames and PID namespaces, so
# waiters can't check a holder's liveness and fall back to mtime — a live
# holder re-touches the file every stale_age/2 s (Timer), and a lock whose
# holder died (e.g. SIGKILL on worker timeout) is broken after ~5*stale_age.
# The default stale_age=0 would deadlock forever on a dead holder's file.
#
# Standalone include (worker.jl and tests); defines no module.

using FileWatching.Pidfile: mkpidlock, trymkpidlock

const DEPOT_INSTALL_LOCK_STALE_AGE = 60

# Run f while holding the depot-wide exclusive install lock; blocks until the
# lock is free. Released (and the lock file removed) even when f throws.
function with_depot_install_lock(f, depot::AbstractString)
    mkpath(depot)
    lockpath = joinpath(depot, ".pkg-install.lock")
    held = trymkpidlock(lockpath; stale_age = DEPOT_INSTALL_LOCK_STALE_AGE)
    if held === false
        # Not `jwcloudindex-worker:` — the driver lifts the first line with
        # that prefix into its failure summary.
        println(stderr, "jwcloudindex-worker (info): waiting for the depot install lock (another worker is installing)")
        return mkpidlock(f, lockpath; stale_age = DEPOT_INSTALL_LOCK_STALE_AGE)
    end
    try
        return f()
    finally
        close(held)
    end
end
