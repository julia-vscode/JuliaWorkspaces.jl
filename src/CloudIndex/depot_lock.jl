# flock(2)-based cross-process mutex for Pkg installs into a shared depot.
#
# Pkg replaces an existing packages/<name>/<slug> tree with
# `mv(unpacked, version_path; force = true)`: the destination is deleted and
# (across filesystems) recopied non-atomically, so concurrent installs of the
# same version corrupt each other (readdir ENOENT / rm ENOTEMPTY). flock works
# across containers sharing the depot bind mount — the lock lives on the inode
# in the host kernel — where pidfile locks can't validate liveness across PID
# namespaces.
#
# Standalone include (worker.jl and tests); defines no module.

const FLOCK_EX = Cint(2)   # exclusive
const FLOCK_NB = Cint(4)   # non-blocking

# Retries EINTR. For FLOCK_NB attempts returns false when the lock is held
# elsewhere; throws on any other failure.
function try_flock(fd::RawFD, op::Cint)
    while true
        ret = ccall(:flock, Cint, (RawFD, Cint), fd, op)
        ret == 0 && return true
        err = Libc.errno()
        err == Libc.EINTR && continue
        (op & FLOCK_NB) != 0 && err == Libc.EAGAIN && return false
        throw(Base.SystemError("flock", err))
    end
end

# Run f while holding the depot-wide exclusive install lock; blocks until the
# lock is free. Closing the handle releases the lock even when f throws.
function with_depot_install_lock(f, depot::AbstractString)
    mkpath(depot)
    io = open(joinpath(depot, ".pkg-install.lock"); write = true, create = true)
    try
        if !try_flock(Base.fd(io), FLOCK_EX | FLOCK_NB)
            # Not `jwcloudindex-worker:` — the driver lifts the first line with
            # that prefix into its failure summary.
            println(stderr, "jwcloudindex-worker (info): waiting for the depot install lock (another worker is installing)")
            try_flock(Base.fd(io), FLOCK_EX)
        end
        return f()
    finally
        close(io)
    end
end
