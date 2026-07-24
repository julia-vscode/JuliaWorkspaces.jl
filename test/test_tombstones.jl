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

@testitem "Tombstones: child tombstones an un-indexable transitive dependency" begin
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    top_uuid = "aaaaaaaa-0000-0000-0000-000000000001"
    trans_uuid = "bbbbbbbb-0000-0000-0000-000000000002"
    top_tree = "1111111111111111111111111111111111111111"
    trans_tree = "2222222222222222222222222222222222222222"

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        # TopPkg is the only top-level dep; TransPkg is a transitive-only manifest
        # entry. Both are regular packages pinned to versions that aren't installed,
        # so neither can be cached.
        write(joinpath(proj, "Project.toml"), "[deps]\nTopPkg = \"$top_uuid\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.TopPkg]]
        deps = ["TransPkg"]
        git-tree-sha1 = "$top_tree"
        uuid = "$top_uuid"
        version = "1.0.0"

        [[deps.TransPkg]]
        git-tree-sha1 = "$trans_tree"
        uuid = "$trans_uuid"
        version = "2.0.0"
        """)

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

        top_tomb   = joinpath(store, "T", "TopPkg", top_uuid, "$top_tree.tombstone")
        trans_tomb = joinpath(store, "T", "TransPkg", trans_uuid, "$trans_tree.tombstone")

        # The top-level dep is tombstoned (already covered), and so is the
        # transitive-only dep — the launch gate checks the whole manifest, so every
        # un-indexable package must be covered or the env keeps re-launching.
        @test isfile(top_tomb)
        @test isfile(trans_tomb)
    end
end

@testitem "Tombstones: child attempts a deved package despite a current tombstone and clears it" begin
    using JuliaWorkspaces.SymbolServer: INDEXER_VERSION
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
        # pre-seed a CURRENT tombstone: a deved package must be attempted anyway
        write(tomb, "indexer_version = $(INDEXER_VERSION)\njulia_version = \"$(VERSION)\"\ntimestamp = $(round(Int, time()))\n")
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
        @test isfile(jstore)     # deved B cached despite a current tombstone (skip-read gate didn't apply)
        @test !isfile(tomb)      # its tombstone was cleared
    end
end

@testitem "Tombstones: child never tombstones a deved package that fails to load" begin
    b_uuid = "c9e8f6db-5b92-4b5b-c9d8-2f5b1e3c4d5f"
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    mktempdir() do root
        proj = joinpath(root, "proj"); bdir = joinpath(root, "B"); store = joinpath(root, "store")
        mkpath(joinpath(bdir, "src")); mkpath(proj); mkpath(store)
        write(joinpath(bdir, "Project.toml"), "name = \"B\"\nuuid = \"$b_uuid\"\nversion = \"0.1.0\"\n")
        write(joinpath(bdir, "src", "B.jl"), "module B\nerror(\"boom during load\")\nend\n")
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
        @test !isfile(jstore)    # failed to cache
        @test !isfile(tomb)      # deved → NOT tombstoned
    end
end

@testitem "Tombstones: parent classifier drops current-tombstoned packages" begin
    using JuliaWorkspaces: _get_missing_packages, _drop_tombstoned
    using JuliaWorkspaces.SymbolServer: tombstone_path, write_tombstone

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        reg_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        dev_uuid = "cccccccc-dddd-eeee-ffff-000000000000"
        tree = "abcdef0123456789abcdef0123456789abcdef01"
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.RegPkg]]
        git-tree-sha1 = "$tree"
        uuid = "$reg_uuid"
        version = "1.2.3"

        [[deps.DevPkg]]
        path = "../DevPkg"
        uuid = "$dev_uuid"
        version = "0.1.0"
        """)

        missing = _get_missing_packages(proj, store)
        @test any(p -> p.name == "RegPkg", missing)   # regular, no jstore → missing
        @test !any(p -> p.name == "DevPkg", missing)  # deved → skipped entirely

        # No tombstone yet: RegPkg still needs caching.
        @test any(p -> p.name == "RegPkg", _drop_tombstoned(missing, store))

        # Current tombstone for RegPkg → dropped (env can fast-lane, no DJP).
        cp = joinpath(store, "R", "RegPkg", reg_uuid, "$tree.jstore")
        write_tombstone(tombstone_path(cp))
        @test isempty(_drop_tombstoned(missing, store))

        # A version-mismatched tombstone does NOT drop it (retry).
        write(tombstone_path(cp), "indexer_version = 999\njulia_version = \"$(VERSION)\"\ntimestamp = $(round(Int, time()))\n")
        @test any(p -> p.name == "RegPkg", _drop_tombstoned(missing, store))
    end
end

@testitem "Tombstones: successful download clears the sibling tombstone" begin
    using JuliaWorkspaces: _download_single_cache, MissingPackage
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore,
        CACHE_STORE_VERSION, tombstone_path, write_tombstone

    # `return` does not skip a @testitem body (module-scope eval); gate with if.
    if !Sys.iswindows()   # file:// download pattern is exercised on POSIX
        mktempdir() do root
            store = joinpath(root, "store"); mkpath(store)
            up = joinpath(root, "upstream")
            name = "DownPkg"; uuid = "dddddddd-eeee-ffff-0000-111111111111"
            tree = "0123456789abcdef0123456789abcdef01234567"

            pkg = Package(name, ModuleStore(VarRef(nothing, Symbol(name)), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]), Base.UUID(uuid), nothing)
            srcdir = joinpath(root, "src_$tree"); mkpath(srcdir)
            jname = "$tree.jstore"
            open(io -> CacheStore.write(io, pkg), joinpath(srcdir, jname), "w")
            updir = joinpath(up, "store", CACHE_STORE_VERSION, "packages", "D", name, uuid); mkpath(updir)
            run(`tar -czf $(joinpath(updir, "$tree.tar.gz")) -C $srcdir $jname`)

            dest = joinpath(store, "D", name, uuid, "$tree.jstore")
            tomb = tombstone_path(dest)
            mkpath(dirname(dest)); write_tombstone(tomb)
            @test isfile(tomb)

            mp = MissingPackage((name, Base.UUID(uuid), "1.0.0", tree))
            @test _download_single_cache(mp, store, "file://" * up, mktempdir())
            @test isfile(dest)     # downloaded
            @test !isfile(tomb)    # tombstone cleared
        end
    end
end
