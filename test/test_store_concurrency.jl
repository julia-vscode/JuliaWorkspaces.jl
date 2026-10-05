# The symbol store is shared by every process using the same depot: a language
# server and a CLI lint run, or several lint runs, all index into it and read
# from it at once. Windows refuses to rename over or delete a file another
# process holds open, so a writer must never need to: a valid cache is never
# replaced unless its content legitimately changes (deved packages), and a
# transient sharing violation is retried or treated as a miss, never as an error.

@testitem "Store concurrency: a writer never replaces a cache another process holds open" begin
    using JuliaWorkspaces.SymbolServer: write_cache_atomic, Package, ModuleStore, VarRef
    using JuliaWorkspaces.SymbolServer.CacheStore: read as cache_read
    using UUIDs: UUID

    uuid = UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf")
    mk(doc) = Package("SparseArrays",
        ModuleStore(VarRef(nothing, :SparseArrays), Dict{Symbol,Any}(), doc, Symbol[], Symbol[], Symbol[]),
        uuid, nothing)
    out = joinpath(mktempdir(), "S", "SparseArrays", string(uuid), "1.13.0.jstore")

    @test write_cache_atomic(mk("first"), out) == out

    # An open `IOStream` is what a reading process holds; on Windows it denies
    # both rename-over and delete, which used to fail the writer with EBUSY.
    io = open(out)
    try
        @test write_cache_atomic(mk("second"), out) == out
    finally
        close(io)
    end
    # First writer wins: the valid cache was neither replaced nor deleted, and
    # the loser's temp file is gone.
    @test open(cache_read, out).val.doc == "first"
    @test readdir(dirname(out)) == ["1.13.0.jstore"]

    # A deved cache must be replaced; a reader that lets go in time is waited out.
    io = open(out)
    closer = @async (sleep(0.5); close(io))
    @test write_cache_atomic(mk("third"), out; replace=true) == out
    wait(closer)
    @test open(cache_read, out).val.doc == "third"
    @test readdir(dirname(out)) == ["1.13.0.jstore"]
end

@testitem "Store concurrency: concurrent writers and readers of shared stdlib caches never fail" begin
    using UUIDs: UUID

    # Several processes run the indexer-child write and the parent read of the
    # same stdlib-keyed caches in lockstep, as on a cold store shared by
    # several hosts. Separate processes, because file system calls are
    # synchronous: tasks within one process cannot overlap them.
    worker = tempname() * ".jl"
    write(worker, raw"""
        using JuliaWorkspaces: _read_package_cache
        using JuliaWorkspaces.SymbolServer: write_cache_atomic, Package, ModuleStore, VarRef
        using UUIDs: UUID

        store, go, nfiles = ARGS[1], ARGS[2], parse(Int, ARGS[3])
        uuid = UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf")
        # Large enough that a read holds the file open for a noticeable time.
        vals = Dict{Symbol,Any}(Symbol("f", i) => VarRef(VarRef(nothing, :SparseArrays), Symbol("f", i)) for i in 1:20_000)
        pkg = Package("SparseArrays", ModuleStore(VarRef(nothing, :SparseArrays), vals, "doc", Symbol[], Symbol[], Symbol[]), uuid, nothing)

        while !isfile(go)
            sleep(0.01)
        end
        for k in 1:nfiles
            path = joinpath(store, "S", "SparseArrays", string(uuid), "1.13.$k.jstore")
            write_cache_atomic(pkg, path)
            for _ in 1:3
                r = _read_package_cache(path, :SparseArrays, uuid)
                r isa Package || error("reading $path returned $(repr(r))")
            end
        end
        """)

    store = mktempdir()
    go = joinpath(store, "go")
    nfiles = 30
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $worker $store $go $nfiles`
    logs = [IOBuffer() for _ in 1:4]
    procs = [run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=log); wait=false) for log in logs]
    touch(go)
    foreach(wait, procs)

    for (p, log) in zip(procs, logs)
        @test p.exitcode == 0
        p.exitcode == 0 || println(String(take!(log)))
    end

    dir = joinpath(store, "S", "SparseArrays", "2f01184e-e22b-5df5-ae63-d93ebab69eaf")
    # Every cache published intact, and no writer left a temp file behind.
    @test sort(readdir(dir)) == sort(["1.13.$k.jstore" for k in 1:nfiles])
end

@testitem "Store concurrency: a transient read error is a miss, not an exception" begin
    using JuliaWorkspaces: _package_cache_path, _read_package_cache
    using JuliaWorkspaces.SymbolServer: write_cache_atomic, Package, ModuleStore, VarRef
    using UUIDs: UUID

    store = mktempdir()
    uuid = UUID("00000000-0000-0000-0000-000000000011")
    path = _package_cache_path(store, :Foo, uuid, v"1.0.0", nothing)
    pkg = Package("Foo", ModuleStore(VarRef(nothing, :Foo), Dict{Symbol,Any}(), "", Symbol[], Symbol[], Symbol[]), uuid, nothing)
    write_cache_atomic(pkg, path)

    # The file vanished between the existence check and the open.
    gone = _ -> throw(Base.IOError("open: no such file or directory (ENOENT)", Base.UV_ENOENT))
    @test _read_package_cache(path, :Foo, uuid; read_cache=gone) === nothing
    # Opening an `IOStream` reports the same as a `SystemError`.
    gone_crt = _ -> throw(SystemError("opening file", Libc.ENOENT))
    @test _read_package_cache(path, :Foo, uuid; read_cache=gone_crt) === nothing
    @test isfile(path)

    if Sys.iswindows()
        # Another process briefly holds the file, or it was just renamed over
        # and is pending deletion: retried, then read.
        calls = Ref(0)
        flaky = p -> (calls[] += 1) == 1 ?
            throw(Base.IOError("open: resource busy or locked (EBUSY)", Base.UV_EBUSY)) :
            calls[] == 2 ? throw(SystemError("opening file", Libc.EACCES)) :
            open(JuliaWorkspaces.SymbolServer.CacheStore.read, p)
        r = _read_package_cache(path, :Foo, uuid; read_cache=flaky)
        @test r isa Package
        @test calls[] == 3

        # Never released: a miss, and the valid file is kept.
        busy = _ -> throw(Base.IOError("open: permission denied (EACCES)", Base.UV_EACCES))
        @test _read_package_cache(path, :Foo, uuid; read_cache=busy) === nothing
        @test isfile(path)
    end
end

@testitem "Store concurrency: a corrupt-cache cleanup never deletes a cache replaced meanwhile" begin
    using JuliaWorkspaces: _package_cache_path, _read_package_cache
    using JuliaWorkspaces.SymbolServer: write_cache_atomic, Package, ModuleStore, VarRef
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError
    using UUIDs: UUID

    store = mktempdir()
    uuid = UUID("00000000-0000-0000-0000-000000000012")
    path = _package_cache_path(store, :Foo, uuid, v"1.0.0", nothing)
    mkpath(dirname(path))
    write(path, "not a jstore at all")

    # While this reader decodes the corrupt file, a writer publishes a valid one.
    pkg = Package("Foo", ModuleStore(VarRef(nothing, :Foo), Dict{Symbol,Any}(), "", Symbol[], Symbol[], Symbol[]), uuid, nothing)
    racing = p -> (write_cache_atomic(pkg, p; replace=true); throw(CacheCorruptedError("torn")))
    @test _read_package_cache(path, :Foo, uuid; read_cache=racing) === nothing
    @test isfile(path)
    @test _read_package_cache(path, :Foo, uuid) isa Package
end
