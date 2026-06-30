@testitem "CloudIndex: enumerate_registry reads versions, tree hashes, yanked, julia compat" begin
    using JuliaWorkspaces.CloudIndexApp: enumerate_registry, PkgVersion
    import Pkg

    mktempdir() do reg
        foo = joinpath(reg, "F", "Foo"); mkpath(foo)
        write(joinpath(reg, "Registry.toml"), """
        name = "Synth"
        uuid = "11111111-1111-1111-1111-111111111111"
        [packages]
        22222222-2222-2222-2222-222222222222 = { name = "Foo", path = "F/Foo" }
        """)
        write(joinpath(foo, "Package.toml"), """
        name = "Foo"
        uuid = "22222222-2222-2222-2222-222222222222"
        """)
        write(joinpath(foo, "Versions.toml"), """
        ["0.1.0"]
        git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        ["0.2.0"]
        git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        yanked = true

        ["1.0.0"]
        git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
        """)
        write(joinpath(foo, "Compat.toml"), """
        ["0"]
        julia = "1.6.0-1"

        ["1"]
        julia = "1.10.0-1"
        """)

        rows = enumerate_registry(reg)
        @test length(rows) == 3
        byv = Dict(r.version => r for r in rows)

        @test byv[v"0.1.0"].name == "Foo"
        @test byv[v"0.1.0"].uuid == Base.UUID("22222222-2222-2222-2222-222222222222")
        @test byv[v"0.1.0"].tree_hash == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        @test byv[v"0.1.0"].yanked == false
        @test byv[v"0.2.0"].yanked == true

        # julia compat: v0.1.0 allows 1.8 (in 1.6-1) but not 2.0; v1.0.0 needs >=1.10.
        @test v"1.8.0" in byv[v"0.1.0"].julia_compat
        @test !(v"2.0.0" in byv[v"0.1.0"].julia_compat)
        @test !(v"1.8.0" in byv[v"1.0.0"].julia_compat)
        @test v"1.11.0" in byv[v"1.0.0"].julia_compat
    end
end

@testitem "CloudIndex: breaking_key buckets 0.x by minor and >=1.0 by major" begin
    using JuliaWorkspaces.CloudIndexApp: breaking_key
    @test breaking_key(v"0.1.5") == (0, 1)
    @test breaking_key(v"0.2.0") == (0, 2)
    @test breaking_key(v"1.4.2") == (1, 0)
    @test breaking_key(v"2.0.0") == (2, 0)
end

@testitem "CloudIndex: apply_filters selection modes and row filters" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, FilterSpec, apply_filters

    nc = nothing  # julia_compat unconstrained
    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    rows = [
        PkgVersion("Foo", u, v"0.1.0", "h010", false, nc),
        PkgVersion("Foo", u, v"0.1.3", "h013", false, nc),
        PkgVersion("Foo", u, v"0.1.5", "h015", false, nc),
        PkgVersion("Foo", u, v"0.2.0", "h020", false, nc),
        PkgVersion("Foo", u, v"1.0.0", "h100", false, nc),
        PkgVersion("Foo", u, v"1.2.0", "h120", false, nc),
        PkgVersion("Foo", u, v"2.0.0", "h200", true,  nc),  # yanked
    ]

    # --newest 1 (default) drops yanked → newest overall is 1.2.0
    got = apply_filters(rows, FilterSpec())
    @test [r.version for r in got] == [v"1.2.0"]

    # --newest 3 (overall)
    got = sort(apply_filters(rows, FilterSpec(n=3)); by=r->r.version)
    @test [r.version for r in got] == [v"0.2.0", v"1.0.0", v"1.2.0"]

    # --all-versions (still drops yanked)
    got = apply_filters(rows, FilterSpec(all_versions=true))
    @test length(got) == 6

    # --per-break (N defaults to 1): newest per (0,1),(0,2),(1,0) lines
    got = sort(apply_filters(rows, FilterSpec(per_break=true)); by=r->r.version)
    @test [r.version for r in got] == [v"0.1.5", v"0.2.0", v"1.2.0"]

    # --newest 2 --per-break: newest 2 within each breaking line
    # (0,1)->0.1.5,0.1.3 ; (0,2)->0.2.0 ; (1,0)->1.2.0,1.0.0 ; drops 0.1.0
    got = sort(apply_filters(rows, FilterSpec(n=2, per_break=true)); by=r->r.version)
    @test [r.version for r in got] == [v"0.1.3", v"0.1.5", v"0.2.0", v"1.0.0", v"1.2.0"]

    # include yanked
    got = apply_filters(rows, FilterSpec(all_versions=true, skip_yanked=false))
    @test any(r -> r.version == v"2.0.0", got)
end

@testitem "CloudIndex: apply_filters name regex, jll, and julia-compat" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, FilterSpec, apply_filters
    import Pkg

    u1 = Base.UUID("22222222-2222-2222-2222-222222222222")
    u2 = Base.UUID("33333333-3333-3333-3333-333333333333")
    u3 = Base.UUID("44444444-4444-4444-4444-444444444444")
    only19 = Pkg.Versions.VersionSpec(Pkg.Versions.VersionRange("1.9"))  # 1.9.x only
    rows = [
        PkgVersion("Foo",       u1, v"1.0.0", "h1", false, nothing),
        PkgVersion("Bar_jll",   u2, v"1.0.0", "h2", false, nothing),
        PkgVersion("Old",       u3, v"1.0.0", "h3", false, only19),
    ]

    # jll skipped by default
    got = apply_filters(rows, FilterSpec(all_versions=true))
    @test Set(r.name for r in got) == Set(["Foo", "Old"])

    # include only names matching ^Foo
    got = apply_filters(rows, FilterSpec(all_versions=true, include=[r"^Foo"]))
    @test [r.name for r in got] == ["Foo"]

    # exclude Old
    got = apply_filters(rows, FilterSpec(all_versions=true, exclude=[r"Old"]))
    @test Set(r.name for r in got) == Set(["Foo"])

    # julia-compat: target 1.12 drops "Old" (1.9.x only); keeps Foo (unconstrained)
    got = apply_filters(rows, FilterSpec(all_versions=true, julia_version=v"1.12.0"))
    @test Set(r.name for r in got) == Set(["Foo"])

    # include_jll: target nothing, allow jll
    got = apply_filters(rows, FilterSpec(all_versions=true, skip_jll=false))
    @test "Bar_jll" in Set(r.name for r in got)
end

@testitem "CloudIndex: cache_relpath matches SymbolServer.get_cache_path" begin
    using JuliaWorkspaces.CloudIndexApp: cache_relpath
    using JuliaWorkspaces.SymbolServer: get_cache_path
    import Pkg

    uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    th = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
    # Minimal manifest dict shaped like Pkg's UUID->PackageEntry map.
    manifest = Dict(uuid => Pkg.Types.PackageEntry(
        name = "Example", version = v"0.5.3", tree_hash = Base.SHA1(th)))
    @test cache_relpath("Example", uuid, th) == String.(get_cache_path(manifest, uuid))
end

@testitem "CloudIndex: is_cached / find_missing honor .jstore and .unavailable tombstones" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, is_cached, find_missing,
                                         cache_relpath, tombstone_relpath

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    a = PkgVersion("Foo", u, v"1.0.0", "aaaa", false, nothing)   # cached (.jstore)
    b = PkgVersion("Foo", u, v"1.1.0", "bbbb", false, nothing)   # missing
    c = PkgVersion("Bar", Base.UUID("33333333-3333-3333-3333-333333333333"),
                   v"1.0.0", "cccc", false, nothing)             # tombstoned (.unavailable)

    mktempdir() do store
        p = joinpath(store, cache_relpath(a.name, a.uuid, a.tree_hash)...)
        mkpath(dirname(p)); write(p, "x")
        t = joinpath(store, tombstone_relpath(c.name, c.uuid, c.tree_hash)...)
        mkpath(dirname(t)); write(t, "unsatisfiable\n")

        @test is_cached(a, store)                      # success cache
        @test !is_cached(b, store)                     # nothing written
        @test is_cached(c, store)                      # failure tombstone counts as done
        @test find_missing([a, b, c], store) == [b]
    end
end

@testitem "CloudIndex: launchers pass through and substitute templates" begin
    using JuliaWorkspaces.CloudIndexApp: LaunchSpec, default_launcher, template_launcher

    inner = `julia --project=/tmp/env worker.jl /jw /store uuid Name 1.0.0 hash`
    s = LaunchSpec(inner, "/depot", "/store", "/tmp/env", "/jw")

    @test default_launcher(s) == inner

    f = template_launcher("docker run --rm -v {depot}:/d:ro -v {store}:/s {cmd}")
    out = f(s)
    argv = collect(out.exec)
    @test argv[1:6] == ["docker","run","--rm","-v","/depot:/d:ro","-v"]
    @test argv[7] == "/store:/s"
    # the inner julia invocation is spliced in verbatim after the wrapper args
    @test argv[8] == "julia"
    @test argv[end] == "hash"
end

@testitem "CloudIndex: host worker depot path appends defaults (trailing colon)" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, _worker_cmd

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    pv = PkgVersion("Foo", u, v"1.0.0", "hfoo", false, nothing)
    opts = IndexOpts(store="/s", depot="/d", workdir="/w", jwroot="/jw")  # default (host) launcher
    cmd = _worker_cmd(pv, "/tmp/env", opts)

    # Default launcher returns the inner cmd; its JULIA_DEPOT_PATH must end in ':'
    # so the worker reuses the default depots' built-in precompile caches.
    envline = only(filter(e -> startswith(e, "JULIA_DEPOT_PATH="), cmd.env))
    @test envline == "JULIA_DEPOT_PATH=/d:"
end

@testitem "CloudIndex: worker indexes a path-deved package and scrubs to PLACEHOLDER" begin
    using JuliaWorkspaces.SymbolServer: CacheStore

    b_uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
    jwroot = abspath(joinpath(@__DIR__, "..", "src"))
    worker = joinpath(jwroot, "CloudIndex", "worker.jl")
    @test isfile(worker)

    mktempdir() do root
        proj = joinpath(root, "proj"); bdir = joinpath(root, "B"); store = joinpath(root, "store")
        mkpath(joinpath(bdir, "src")); mkpath(proj); mkpath(store)
        write(joinpath(bdir, "Project.toml"), """
        name = "B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)
        write(joinpath(bdir, "src", "B.jl"), """
        module B
        struct BType end
        Base.show(io::IO, ::BType) = print(io, "B")
        "Docs for myfunc." myfunc(x) = x
        end # module B
        """)
        write(joinpath(proj, "Project.toml"), """
        [deps]
        B = "$b_uuid"
        """)
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.B]]
        path = "../B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)

        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        cmd = `$jl --startup-file=no --history-file=no --project=$proj $worker $jwroot $store $b_uuid B 0.1.0 deadbeef`
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(ignorestatus(cmd))
        end
        @test proc.exitcode == 0

        # B is a path dep → tree_hash is nothing → get_store names it by version.
        cache_path = joinpath(store, "B", "B", b_uuid, "0.1.0.jstore")
        @test isfile(cache_path)

        pkg = open(CacheStore.read, cache_path)
        # The package's own method file path must have been scrubbed to PLACEHOLDER,
        # i.e. the real fixture src dir no longer appears.
        m = pkg.val[:myfunc]
        @test occursin("PLACEHOLDER", m.methods[1].file)
        @test !occursin(bdir, m.methods[1].file)
    end
end

@testitem "CloudIndex: fnv1a is deterministic and shard_select partitions disjointly" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, fnv1a, shard_select

    @test fnv1a("Foo@1.0.0") == fnv1a("Foo@1.0.0")
    @test fnv1a("Foo@1.0.0") != fnv1a("Foo@1.0.1")

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    rows = [PkgVersion("P$i", u, VersionNumber(i, 0, 0), "h$i", false, nothing) for i in 1:50]
    n = 4
    shards = [shard_select(rows, k, n) for k in 0:n-1]
    total = sum(length, shards)
    @test total == length(rows)                          # exhaustive
    allids = vcat([[r.name for r in s] for s in shards]...)
    @test length(allids) == length(unique(allids))       # disjoint
end

@testitem "CloudIndex: parse_args validates shard range" begin
    using JuliaWorkspaces.CloudIndexApp: parse_args

    # valid: k=0, n=4
    cfg = parse_args(["--shard", "0/4"])
    @test cfg.shard == (0, 4)

    # invalid: k == n (out of range)
    @test_throws ErrorException parse_args(["--shard", "4/4"])

    # invalid: k > n
    @test_throws ErrorException parse_args(["--shard", "5/4"])

    # invalid: n == 0
    @test_throws ErrorException parse_args(["--shard", "0/0"])
end

@testitem "CloudIndex: to_json_line escapes and is well-formed" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, Result, to_json_line
    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    r = Result(PkgVersion("Foo", u, v"1.0.0", "hash", false, nothing),
               :failed, 1.2345, 0, "bad \"quote\"\nnewline")
    line = to_json_line(r)
    @test occursin("\\\"quote\\\"", line)
    @test occursin("\\n", line)
    @test startswith(line, "{") && endswith(line, "}")
end

@testitem "CloudIndex: run_index contains per-item _run_one exceptions" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    good = PkgVersion("Good", u, v"1.0.0", "hgood", false, nothing)
    bad  = PkgVersion("Bad",  u, v"1.0.0", "hbad",  false, nothing)

    mktempdir() do root
        store = joinpath(root, "store"); work = joinpath(root, "work"); depot = joinpath(root, "depot")
        jwfake = joinpath(root, "jw", "CloudIndex"); mkpath(jwfake)

        # Stub: Good exits 0; Bad exits normally too, but we force _run_one to throw
        # by passing a non-existent julia_exe so run(...) raises an exception.
        stub = joinpath(jwfake, "worker.jl")
        write(stub, "exit(0)\n")

        log = joinpath(root, "results.jsonl")
        opts = IndexOpts(store=store, depot=depot, workdir=work,
                         jwroot=joinpath(root, "jw"), jobs=2, timeout=10.0,
                         logfile=log, resume=false, progress=false,
                         julia_exe="/nonexistent/julia_does_not_exist")

        results = run_index([good, bad], opts)
        @test length(results) == 2
        @test all(r -> r.status === :failed, results)
        # both failures logged
        @test count(!isempty, readlines(log)) == 2
    end
end

@testitem "CloudIndex: run_index respects resume, timeout, and logs JSONL" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index, cache_relpath

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    fast = PkgVersion("Fast", u, v"1.0.0", "hfast", false, nothing)
    slow = PkgVersion("Slow", u, v"1.0.0", "hslow", false, nothing)
    done = PkgVersion("Done", u, v"1.0.0", "hdone", false, nothing)

    mktempdir() do root
        store = joinpath(root, "store"); work = joinpath(root, "work"); depot = joinpath(root, "depot")
        jwfake = joinpath(root, "jw", "CloudIndex"); mkpath(jwfake)
        mkpath(store)
        # pre-cache `done` so resume skips it
        p = joinpath(store, cache_relpath(done.name, done.uuid, done.tree_hash)...)
        mkpath(dirname(p)); write(p, "x")

        # Stub worker: writes the expected .jstore and exits 0; "Slow" sleeps to trip timeout.
        stub = joinpath(jwfake, "worker.jl")
        write(stub, raw"""
        jwroot, store, uuid, name, version, th = ARGS
        if name == "Slow"; sleep(30); end
        rp = joinpath(store, uppercase(name[1:1]), name, uuid, th * ".jstore")
        mkpath(dirname(rp)); write(rp, "indexed")
        exit(0)
        """)

        log = joinpath(root, "results.jsonl")
        opts = IndexOpts(store=store, depot=depot, workdir=work,
                         jwroot=joinpath(root, "jw"), jobs=2, timeout=3.0, logfile=log,
                         progress=false,
                         julia_exe=joinpath(Sys.BINDIR, Base.julia_exename()))

        results = run_index([fast, slow, done], opts)
        byname = Dict(r.pv.name => r for r in results)

        # `done` was pre-cached → resume removed it from the worklist entirely.
        @test !haskey(byname, "Done")
        @test byname["Fast"].status == :ok
        @test byname["Fast"].bytes > 0
        # Timed-out workers are killed and classified :timeout on Unix; Windows'
        # process-kill/exit semantics surface it as :failed, so assert only there.
        if !Sys.iswindows()
            @test byname["Slow"].status == :timeout
        end

        # JSONL log has one line per run result.
        @test count(!isempty, readlines(log)) == 2
    end
end

@testitem "CloudIndex: failures write a tombstone that resume honors" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index, tombstone_relpath, cache_relpath

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    pv = PkgVersion("Bad", u, v"1.0.0", "hbad", false, nothing)

    mktempdir() do root
        store = joinpath(root, "store"); work = joinpath(root, "work"); depot = joinpath(root, "depot")
        jwfake = joinpath(root, "jw", "CloudIndex"); mkpath(jwfake); mkpath(store)
        # Stub worker that fails with the index/scrub exit code (20 -> :failed).
        write(joinpath(jwfake, "worker.jl"), "exit(20)\n")

        opts = IndexOpts(store=store, depot=depot, workdir=work,
                         jwroot=joinpath(root, "jw"), jobs=1, timeout=30.0, progress=false,
                         julia_exe=joinpath(Sys.BINDIR, Base.julia_exename()))

        r1 = run_index([pv], opts)
        @test length(r1) == 1 && r1[1].status == :failed
        # No success cache, but a .unavailable tombstone was written.
        @test !isfile(joinpath(store, cache_relpath(pv.name, pv.uuid, pv.tree_hash)...))
        tomb = joinpath(store, tombstone_relpath(pv.name, pv.uuid, pv.tree_hash)...)
        @test isfile(tomb)
        @test occursin("failed", read(tomb, String))

        # Resume (default) now skips the tombstoned version: nothing left to run.
        r2 = run_index([pv], opts)
        @test isempty(r2)
    end
end

@testitem "CloudIndex: SIGINT is :cancelled; a worker crash is :failed and tombstoned" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index,
                                         tombstone_relpath, find_missing

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    jl = joinpath(Sys.BINDIR, Base.julia_exename())

    mktempdir() do root
        store = joinpath(root, "store"); work = joinpath(root, "work"); depot = joinpath(root, "depot")
        jwfake = joinpath(root, "jw", "CloudIndex"); mkpath(jwfake); mkpath(store)

        function run_stub(body, hash)
            write(joinpath(jwfake, "worker.jl"), body)
            pv = PkgVersion("Foo", u, v"1.0.0", hash, false, nothing)
            r = only(run_index([pv], IndexOpts(store=store, depot=depot, workdir=work,
                jwroot=joinpath(root, "jw"), jobs=1, resume=false, progress=false, julia_exe=jl)))
            tomb = isfile(joinpath(store, tombstone_relpath(pv.name, pv.uuid, pv.tree_hash)...))
            retryable = !isempty(find_missing([pv], store))
            (r.status, tomb, retryable)
        end

        # SIGINT (Ctrl-C reaches the worker): batch interrupt — retryable, not tombstoned.
        st, tomb, retry = run_stub("exit(130)\n", "hint")   # exit 128+SIGINT
        @test st == :cancelled
        @test !tomb && retry

        # OOM SIGKILL: the worker crashed on its own — a real failure, tombstoned.
        # raise(9) is POSIX-only; on Windows it doesn't terminate the process.
        if !Sys.iswindows()
            st2, tomb2, retry2 = run_stub("ccall(:raise, Cint, (Cint,), 9)\n", "hkill")
            @test st2 == :failed
            @test tomb2 && !retry2
        end

        # A crash signaled via a 128+signal exit code: also a real failure,
        # tombstoned. This path is cross-platform (plain exit code, no signal).
        st3, tomb3, retry3 = run_stub("exit(139)\n", "hsegv")
        @test st3 == :failed
        @test tomb3 && !retry3
    end
end

@testitem "CloudIndex: run_index stops scheduling on interrupt" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    rows = [PkgVersion("P$i", u, VersionNumber(i, 0, 0), "h$i", false, nothing) for i in 1:6]

    # A launcher that raises InterruptException on its first call, simulating a
    # Ctrl-C during the run. The interrupt must abort the batch (rethrown) rather
    # than be recorded as a per-item failure, and no further items should be
    # scheduled. jobs=1 makes this deterministic.
    calls = Ref(0)
    boom = function (spec)
        calls[] += 1
        calls[] == 1 && throw(InterruptException())
        spec.cmd
    end

    mktempdir() do root
        opts = IndexOpts(store=joinpath(root, "store"), depot=joinpath(root, "depot"),
                         workdir=joinpath(root, "work"), jwroot=joinpath(root, "jw"),
                         jobs=1, resume=false, progress=false, launcher=boom,
                         julia_exe="/bin/true")
        @test_throws InterruptException run_index(rows, opts)
        @test calls[] < length(rows)        # stopped scheduling; didn't touch every item
    end
end

@testitem "CloudIndex: run_index emits CI-friendly progress lines" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, IndexOpts, run_index

    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    pv = PkgVersion("Foo", u, v"1.2.0", "hfoo", false, nothing)

    mktempdir() do root
        store = joinpath(root, "store"); work = joinpath(root, "work"); depot = joinpath(root, "depot")
        jwfake = joinpath(root, "jw", "CloudIndex"); mkpath(jwfake); mkpath(store)
        write(joinpath(jwfake, "worker.jl"), raw"""
        jwroot, store, uuid, name, version, th = ARGS
        rp = joinpath(store, uppercase(name[1:1]), name, uuid, th * ".jstore")
        mkpath(dirname(rp)); write(rp, "x"); exit(0)
        """)

        errfile = joinpath(root, "stderr.txt")
        open(errfile, "w") do io
            redirect_stderr(io) do
                run_index([pv], IndexOpts(store=store, depot=depot, workdir=work,
                    jwroot=joinpath(root, "jw"), jobs=1, resume=false,
                    julia_exe=joinpath(Sys.BINDIR, Base.julia_exename())))
            end
        end
        out = read(errfile, String)

        # plain, newline-terminated, no carriage returns (CI-friendly)
        @test !occursin('\r', out)
        @test occursin("indexing 1 version(s)", out)
        @test occursin("[1/1]", out)
        @test occursin("ok", out)
        @test occursin("Foo@1.2.0", out)
    end
end

@testitem "CloudIndex: parse_args maps flags to FilterSpec and config" begin
    using JuliaWorkspaces.CloudIndexApp: parse_args

    cfg = parse_args(["--registry", "/r", "--store", "/s",
                      "--newest", "2", "--per-break", "--include", "^Foo", "--exclude", "Bar",
                      "--include-yanked", "--include-jll", "--julia-version", "1.10.0",
                      "--jobs", "8", "--timeout", "120", "--shard", "1/4",
                      "--launcher", "docker {cmd}", "--no-resume", "--no-progress",
                      "--report-missing", "--out", "/tmp/m.jsonl"])

    @test cfg.registry == "/r"
    @test cfg.store == "/s"
    @test cfg.filter.n == 2
    @test cfg.filter.per_break == true
    @test cfg.filter.all_versions == false
    @test cfg.filter.skip_yanked == false
    @test cfg.filter.skip_jll == false
    @test cfg.filter.julia_version == v"1.10.0"
    @test occursin("^Foo", cfg.filter.include[1].pattern)
    @test cfg.jobs == 8
    @test cfg.timeout == 120.0
    @test cfg.shard == (1, 4)
    @test cfg.launcher_template == "docker {cmd}"
    @test cfg.resume == false
    @test cfg.progress == false
    @test cfg.mode == :report_missing
    @test cfg.out == "/tmp/m.jsonl"

    # defaults: newest 1 overall, yanked+jll skipped, resume+progress on, index mode
    d = parse_args(String[])
    @test d.filter.n == 1 && !d.filter.per_break && !d.filter.all_versions
    @test d.resume && d.progress
    @test d.filter.skip_yanked && d.filter.skip_jll
    @test d.resume && d.mode == :index
end

@testitem "CloudIndex: cli_main --report-missing over a synthetic registry" begin
    using JuliaWorkspaces.CloudIndexApp: cli_main, enumerate_registry, apply_filters,
                                         FilterSpec, cache_relpath

    mktempdir() do root
        reg = joinpath(root, "reg"); store = joinpath(root, "store")
        foo = joinpath(reg, "F", "Foo"); mkpath(foo); mkpath(store)
        write(joinpath(reg, "Registry.toml"), """
        name = "Synth"
        uuid = "11111111-1111-1111-1111-111111111111"
        [packages]
        22222222-2222-2222-2222-222222222222 = { name = "Foo", path = "F/Foo" }
        """)
        write(joinpath(foo, "Package.toml"), "name = \"Foo\"\nuuid = \"22222222-2222-2222-2222-222222222222\"\n")
        write(joinpath(foo, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["1.1.0"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"
        """)

        # Pre-cache the newest (1.1.0) so report-missing should report nothing under newest=1.
        u = Base.UUID("22222222-2222-2222-2222-222222222222")
        p = joinpath(store, cache_relpath("Foo", u, "2222222222222222222222222222222222222222")...)
        mkpath(dirname(p)); write(p, "x")

        outfile = joinpath(root, "missing.jsonl")
        rc = cli_main(["--registry", reg, "--store", store, "--newest", "1",
                       "--report-missing", "--out", outfile])
        @test rc == 0
        @test count(!isempty, readlines(outfile)) == 0   # newest already cached

        # all-versions report-missing → 1.0.0 is missing
        rc = cli_main(["--registry", reg, "--store", store, "--all-versions",
                       "--report-missing", "--out", outfile])
        @test rc == 0
        @test count(!isempty, readlines(outfile)) == 1
    end
end

@testitem "CloudIndex: --emit-index writes the index and exits 0" begin
    using JuliaWorkspaces.CloudIndexApp: cli_main
    mktempdir() do root
        store = joinpath(root, "store")
        mk(p) = (mkpath(dirname(p)); write(p, "x"))
        mk(joinpath(store, "E", "Example", "uuid-a", "h1.jstore"))
        out = joinpath(root, "index.txt")
        rc = cli_main(["--store", store, "--emit-index", out])
        @test rc == 0
        @test read(out, String) == "uuid-a/h1\n"
    end
end

@testitem "CloudIndex: find_missing(rows, done-set) filters by uuid/treehash key" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, find_missing, done_key
    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    rows = [PkgVersion("A", u, v"1.0.0", "h1", false, nothing),
            PkgVersion("B", u, v"1.0.0", "h2", false, nothing)]
    done = Set(["$(u)/h1"])
    left = find_missing(rows, done)
    @test length(left) == 1 && left[1].tree_hash == "h2"
    @test done_key(rows[1]) == "$(u)/h1"

    # '+' in tree_hash must map to '_' in done_key
    pv_plus = PkgVersion("C", u, v"1.0.0", "a+b", false, nothing)
    @test endswith(done_key(pv_plus), "a_b")
end

@testitem "CloudIndex: build_index lists one <uuid>/<stem> per .jstore" begin
    using JuliaWorkspaces.CloudIndexApp: build_index, write_index
    mktempdir() do store
        mk(p) = (mkpath(dirname(p)); write(p, "x"))
        mk(joinpath(store, "E", "Example", "uuid-a", "h1.jstore"))
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h2.jstore"))
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h2.unavailable"))  # tombstone: ignored
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h3.jstore.tmp"))   # not a .jstore: ignored

        idx = build_index(store)
        @test idx == ["uuid-a/h1", "uuid-b/h2"]      # sorted, unique, .jstore only

        io = IOBuffer(); write_index(store, io)
        @test String(take!(io)) == "uuid-a/h1\nuuid-b/h2\n"
    end
end
