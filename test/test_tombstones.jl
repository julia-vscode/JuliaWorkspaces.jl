@testitem "Tombstones: path swap, round-trip, currency" begin
    using JuliaWorkspaces.SymbolServer: tombstone_path, read_tombstone,
        tombstone_is_current, write_tombstone, delete_tombstone, INDEXER_VERSION

    cp = joinpath("store", "F", "Foo", "uuid", "abcdef.jstore")
    @test tombstone_path(cp) == joinpath("store", "F", "Foo", "uuid", "abcdef.tombstone")
    # only the trailing extension is swapped
    @test tombstone_path(joinpath("a", "b.jstore.jstore")) == joinpath("a", "b.jstore.tombstone")

    mktempdir() do d
        p = joinpath(d, "sub", "x.tombstone")   # nested dir: write must mkpath
        @test read_tombstone(p) === nothing      # absent → nothing

        @test write_tombstone(p) == p
        t = read_tombstone(p)
        @test t !== nothing
        @test t.indexer_version == INDEXER_VERSION
        @test t.julia_version == string(VERSION)
        @test tombstone_is_current(t)                       # fresh + matching
        @test tombstone_is_current(read_tombstone(p))

        write(p, "this is not = valid = toml = [[")         # malformed → nothing
        @test read_tombstone(p) === nothing

        delete_tombstone(p)
        @test !isfile(p)
        delete_tombstone(p)                                  # idempotent on absent
    end
end

@testitem "Tombstones: mismatch and staleness are not current" begin
    using JuliaWorkspaces.SymbolServer: tombstone_is_current, INDEXER_VERSION,
        TOMBSTONE_TTL_SECONDS

    now = round(Int, time())
    @test !tombstone_is_current(nothing)
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION + 1, julia_version=string(VERSION), timestamp=now))
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version="0.0.0", timestamp=now))
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version=string(VERSION), timestamp=now - TOMBSTONE_TTL_SECONDS - 1))
    @test  tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version=string(VERSION), timestamp=now))
end

@testitem "Tombstones: child writes, skips, and retries an uncacheable package" begin
    using JuliaWorkspaces.SymbolServer: read_tombstone, tombstone_is_current, INDEXER_VERSION

    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))
    @test isfile(symbolserver_jl)

    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    tree = "abcdef0123456789abcdef0123456789abcdef01"

    function run_get_store(proj, store)
        runner = tempname() * ".jl"
        write(runner, """
        include(raw"$symbolserver_jl")
        using Pkg
        Pkg.activate(raw"$proj"; io=devnull)
        SymbolServer.get_store(raw"$store", nothing)
        """)
        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        out = IOBuffer()
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(pipeline(ignorestatus(`$jl --startup-file=no --project=$proj $runner`), stdout=out, stderr=out))
        end
        (exitcode=proc.exitcode, log=String(take!(out)))
    end

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        write(joinpath(proj, "Project.toml"), "[deps]\nFakeRegPkg = \"$uuid\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.FakeRegPkg]]
        git-tree-sha1 = "$tree"
        uuid = "$uuid"
        version = "1.2.3"
        """)

        jstore = joinpath(store, "F", "FakeRegPkg", uuid, "$tree.jstore")
        tomb   = joinpath(store, "F", "FakeRegPkg", uuid, "$tree.tombstone")

        # First run: the package can't load → no jstore, a current tombstone appears.
        r1 = run_get_store(proj, store)
        @test r1.exitcode == 0
        @test !isfile(jstore)
        @test isfile(tomb)
        @test tombstone_is_current(read_tombstone(tomb))

        # Second run: the current tombstone makes the child skip the package.
        r2 = run_get_store(proj, store)
        @test r2.exitcode == 0
        @test occursin("tombstoned as uncacheable, skipping", r2.log)
        @test isfile(tomb)
        @test !isfile(jstore)

        # A version-mismatched tombstone is retried (re-attempted) and re-stamped.
        write(tomb, "indexer_version = 999\njulia_version = \"$(VERSION)\"\ntimestamp = $(round(Int, time()))\n")
        r3 = run_get_store(proj, store)
        @test r3.exitcode == 0
        @test occursin("Will cache package", r3.log)
        @test read_tombstone(tomb).indexer_version == INDEXER_VERSION
    end
end

@testitem "Tombstones: child clears a stale tombstone when a package caches" begin
    b_uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    mktempdir() do root
        proj = joinpath(root, "proj"); bdir = joinpath(root, "B"); store = joinpath(root, "store")
        mkpath(joinpath(bdir, "src")); mkpath(proj); mkpath(store)
        write(joinpath(bdir, "Project.toml"), "name = \"B\"\nuuid = \"$b_uuid\"\nversion = \"0.1.0\"\n")
        write(joinpath(bdir, "src", "B.jl"), "module B\nf(x) = x\nend\n")
        write(joinpath(proj, "Project.toml"), "[deps]\nB = \"$b_uuid\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.B]]
        path = "../B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)

        cache_dir = joinpath(store, "B", "B", b_uuid); mkpath(cache_dir)
        jstore = joinpath(cache_dir, "0.1.0.jstore")
        tomb   = joinpath(cache_dir, "0.1.0.tombstone")
        write(tomb, "indexer_version = 1\njulia_version = \"stale\"\ntimestamp = 1\n")  # pre-seed
        @test isfile(tomb)

        runner = joinpath(root, "run.jl")
        write(runner, """
        include(raw"$symbolserver_jl")
        using Pkg
        Pkg.activate(raw"$proj"; io=devnull)
        SymbolServer.get_store(raw"$store", nothing)
        """)
        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(ignorestatus(`$jl --startup-file=no --project=$proj $runner`))
        end
        @test proc.exitcode == 0
        @test isfile(jstore)     # deved B cached successfully
        @test !isfile(tomb)      # its stale tombstone was cleared
    end
end
