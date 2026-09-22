@testitem "DJP runtime: child environment selection follows the child script" begin
    using JuliaWorkspaces: _djp_project_for_version, _djp_environments_dir

    # The child script picks its own environment from its own VERSION; the
    # parent has to make the identical choice when it prepares that
    # environment caches, or it would warm one the child never activates.
    env_dir = _djp_environments_dir()
    @test isdir(env_dir)

    for entry in readdir(env_dir)
        startswith(entry, "v") || continue
        version = tryparse(VersionNumber, entry[2:end])
        version === nothing && continue
        @test _djp_project_for_version(version) == joinpath(env_dir, entry)
    end

    # No versioned directory for a far-future Julia, so it must fall back
    # rather than hand out a path that does not exist.
    far_future = _djp_project_for_version(v"99.99.0")
    @test far_future == joinpath(env_dir, "fallback")
    @test isdir(far_future)
end

@testitem "DJP runtime: children never precompile, preparation always may" begin
    using JuliaWorkspaces: _djp_process_env

    child = _djp_process_env(disable_precompile_auto=true)
    warmup = _djp_process_env(disable_precompile_auto=false)

    # The point of the whole change: an indexing child imports packages to read
    # their metadata, so it must not drag a full environment precompile (and
    # its one-worker-per-core fan-out) along with every `Pkg.instantiate`.
    @test child["JULIA_PKG_PRECOMPILE_AUTO"] == "0"
    # The preparation process is the one caller that must be allowed to build
    # caches; inheriting a 0 from the host would silently defeat it.
    @test !haskey(warmup, "JULIA_PKG_PRECOMPILE_AUTO")

    for env in (child, warmup)
        # Depot auto-gc races other processes rewriting the usage TOML files.
        @test env["JULIA_PKG_GC_AUTO"] == "false"
        # An inherited load path/project would stop the child resolving @.
        @test !haskey(env, "JULIA_LOAD_PATH")
        @test !haskey(env, "JULIA_PROJECT")
        @test !haskey(env, "JULIA_DEPOT_PATH")
    end

    # Preparation must warm the same depot the children read, so the rest of
    # the environment has to be identical.
    @test setdiff(keys(child), keys(warmup)) == Set(["JULIA_PKG_PRECOMPILE_AUTO"])
end

@testitem "DJP runtime: cache-free launch flags are opt-in" begin
    using JuliaWorkspaces: DjpRuntime, _djp_launch_flags

    @test _djp_launch_flags(DjpRuntime("julia", v"1.12.0", "p", true)) ==
        ["--compiled-modules=existing"]
    # An unprepared runtime must launch children the old way, so a child whose
    # own environment has no caches can still build them instead of re-loading
    # Revise and friends from source on every single launch.
    @test _djp_launch_flags(DjpRuntime("julia", v"1.12.0", "p", false)) == String[]
end

@testitem "DJP runtime: stamp round-trips, prunes and rejects garbage" begin
    using JuliaWorkspaces: _djp_stamp_path, _read_djp_stamp, _write_djp_stamp, _djp_runtime_dir

    mktempdir() do root
        store = joinpath(root, "store")
        path = _djp_stamp_path(store, 0xdeadbeefcafe1234)

        @test _read_djp_stamp(path) === nothing

        _write_djp_stamp(path, v"1.12.7", true)
        @test _read_djp_stamp(path) == (v"1.12.7", true)

        _write_djp_stamp(path, v"1.9.4", false)
        @test _read_djp_stamp(path) == (v"1.9.4", false)

        # One stamp would otherwise accumulate per extension update.
        other = _djp_stamp_path(store, 0x1111111111111111)
        _write_djp_stamp(other, v"1.0.0", false)
        _write_djp_stamp(path, v"1.12.7", true)
        @test filter(f -> endswith(f, ".stamp"), readdir(_djp_runtime_dir(store))) ==
            [basename(path)]

        # Anything unparseable must read as "not prepared". Preparing again is
        # cheap, but trusting a corrupt stamp would launch every child with
        # --compiled-modules=existing against caches that may not exist.
        bad = joinpath(_djp_runtime_dir(store), "bad.stamp")
        for content in ("1\nnot-a-version\nexisting\n", "9\n1.12.7\nexisting\n",
                        "1\n1.12.7\nweird\n", "1\n1.12.7\n", "")
            write(bad, content)
            @test _read_djp_stamp(bad) === nothing
        end
    end
end

@testitem "DJP runtime: the fingerprint tracks the executable and the child sources" begin
    using JuliaWorkspaces: _djp_runtime_fingerprint, default_djp_julia_exe, _fingerprint_tree

    exe = default_djp_julia_exe()
    baseline = _djp_runtime_fingerprint(exe)

    # Deterministic, or every restart would redo the preparation it is meant
    # to skip.
    @test _djp_runtime_fingerprint(exe) == baseline
    # Pointing children at a different Julia must invalidate the stamp: its
    # recorded version and flag support describe that executable only.
    @test _djp_runtime_fingerprint(joinpath("some", "other", "julia")) != baseline

    # An edit anywhere under a tracked tree has to change the hash, because a
    # stale stamp means children load their own package from source forever.
    mktempdir() do root
        tree = joinpath(root, "tree")
        mkpath(joinpath(tree, "nested"))
        write(joinpath(tree, "nested", "a.jl"), "x = 1")
        before = _fingerprint_tree(UInt64(0), tree)
        @test _fingerprint_tree(UInt64(0), tree) == before

        write(joinpath(tree, "nested", "a.jl"), "x = 1234567")
        @test _fingerprint_tree(UInt64(0), tree) != before

        write(joinpath(tree, "nested", "b.jl"), "y = 2")
        @test _fingerprint_tree(UInt64(0), tree) != before

        # A missing tree is stable rather than an error, so a partial install
        # degrades to "prepare again" instead of taking down the reactor.
        @test _fingerprint_tree(UInt64(0), joinpath(root, "absent")) ==
            _fingerprint_tree(UInt64(0), joinpath(root, "also-absent"))
    end
end

@testitem "DJP runtime: capability is probed from the executable, not assumed" begin
    using JuliaWorkspaces: _probe_djp_julia, default_djp_julia_exe

    # Probing rather than comparing against the version that introduced
    # --compiled-modules=existing is what keeps this correct when children run
    # on a different Julia than the host, which they will.
    probed = _probe_djp_julia(default_djp_julia_exe())
    @test probed !== nothing
    version, supports_existing = probed
    @test version == VERSION
    @test supports_existing == (VERSION >= v"1.11")

    # An executable that cannot answer must not be guessed at.
    @test _probe_djp_julia(joinpath("nonexistent", "julia-does-not-exist")) === nothing
end

@testitem "DJP runtime: preparation is skipped once stamped, across processes" begin
    using JuliaWorkspaces: djp_runtime, default_djp_julia_exe, _reset_djp_runtime_cache!,
        _read_djp_stamp, _djp_stamp_path, _djp_runtime_fingerprint

    exe = default_djp_julia_exe()
    mktempdir() do root
        store = joinpath(root, "store")
        prepared = Ref(0)
        count_prepare = () -> (prepared[] += 1)

        _reset_djp_runtime_cache!()
        try
            first_result = djp_runtime(exe, store; on_prepare=count_prepare)
            @test first_result.exe == exe
            @test first_result.version == VERSION
            @test prepared[] == 1

            # Same process: the memo answers, nothing is launched.
            second = djp_runtime(exe, store; on_prepare=count_prepare)
            @test second == first_result
            @test prepared[] == 1

            # A restart of the host is the case that matters: dropping the memo
            # must still cost zero child launches, or every reopened window
            # would pay for preparation all over again.
            _reset_djp_runtime_cache!()
            third = djp_runtime(exe, store; on_prepare=count_prepare)
            @test third == first_result
            @test prepared[] == 1

            # Only a definitive outcome is stamped. Preparation can legitimately
            # fail (a busy depot), and that case must stay unstamped so it is
            # retried rather than locked in.
            stamp = _djp_stamp_path(store, _djp_runtime_fingerprint(exe))
            if first_result.use_existing_caches
                @test _read_djp_stamp(stamp) == (VERSION, true)
            end
        finally
            _reset_djp_runtime_cache!()
        end
    end
end

@testitem "DJP runtime: the child command carries the cache-free contract" begin
    using JuliaWorkspaces: DjpRuntime, _djp_child_cmd

    script = joinpath("app", "main.jl")
    pipe = "pipe-name"

    prepared = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", true), script, pipe)
    args = collect(prepared.exec)
    @test args[1] == "jlx"
    @test "--compiled-modules=existing" in args
    # Order matters: julia stops parsing options at the script path.
    @test findfirst(==("--compiled-modules=existing"), args) < findfirst(==(script), args)
    @test args[end] == pipe
    # Whatever else changes, a child must never precompile an environment.
    @test "JULIA_PKG_PRECOMPILE_AUTO=0" in prepared.env

    # An unprepared runtime still launches, just without cache-free loading.
    plain = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", false), script, pipe)
    @test !("--compiled-modules=existing" in collect(plain.exec))
    @test "JULIA_PKG_PRECOMPILE_AUTO=0" in plain.env

    # Trailing child arguments (error handler, crash pipe) keep their order
    # after the pipe name.
    with_extra = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", true), script, pipe,
        String["handler.jl", "crashpipe"])
    @test collect(with_extra.exec)[end-2:end] == [pipe, "handler.jl", "crashpipe"]
end
