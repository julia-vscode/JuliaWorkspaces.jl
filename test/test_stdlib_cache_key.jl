@testitem "Stdlib key: _stdlib_cache_version maps stdlibs to the bundled version" begin
    using JuliaWorkspaces: _stdlib_cache_version
    using JuliaWorkspaces.SymbolServer: _stdlib_bundled_version
    using UUIDs: UUID

    toml  = UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")   # stdlib (was registered pre-1.6)
    prefs = UUID("21216c6a-2e73-6563-6e65-726566657250")   # registered package, not a stdlib

    @test _stdlib_cache_version(toml) isa VersionNumber
    # Matches the child's key: same cross-Julia bundled-version lookup get_cache_path uses.
    @test _stdlib_cache_version(toml) == something(_stdlib_bundled_version(toml), VERSION)
    @test _stdlib_cache_version(prefs) === nothing                                 # non-stdlib → no normalization
end

@testitem "Stdlib key: _get_missing_packages keys a tree-sha'd stdlib by the bundled version" begin
    using JuliaWorkspaces: _get_missing_packages, _stdlib_cache_version
    using UUIDs: UUID

    toml  = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    dates = "ade2ca70-3891-5945-98fb-dc099432e06a"     # versionless stdlib in the manifest
    sv = _stdlib_cache_version(UUID(toml))              # bundled TOML version, e.g. v"1.0.3"

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        # v1 manifest: TOML recorded as a registered package (git-tree-sha1);
        # Dates recorded versionless.
        write(joinpath(proj, "Manifest.toml"), """
        [[Dates]]
        deps = ["Printf"]
        uuid = "$dates"

        [[TOML]]
        deps = ["Dates"]
        git-tree-sha1 = "d0ac7eaad0fb9f6ba023a1d743edca974ae637c4"
        uuid = "$toml"
        version = "1.0.0"
        """)

        # No cache: TOML is missing, but keyed by the bundled version with no tree-sha.
        missing = _get_missing_packages(proj, store)
        tomlmiss = only(filter(p -> p.name == "TOML", missing))
        @test tomlmiss.git_tree_sha1 === nothing
        @test tomlmiss.version == string(sv)
        @test !any(p -> p.name == "Dates", missing)     # versionless stdlib still skipped

        # A jstore at the bundled-version key (what the child writes) satisfies it.
        jdir = joinpath(store, "T", "TOML", toml); mkpath(jdir)
        touch(joinpath(jdir, "$(sv).jstore"))
        @test !any(p -> p.name == "TOML", _get_missing_packages(proj, store))
    end
end

@testitem "Stdlib key: derived_project classifies a tree-sha'd stdlib as stdlib" begin
    using JuliaWorkspaces: workspace_from_folders, derived_project, get_projects,
        filepath2uri, _stdlib_cache_version
    using UUIDs: UUID

    toml = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    sv = _stdlib_cache_version(UUID(toml))

    mktempdir() do root
        proj = joinpath(root, "proj"); mkpath(proj)
        write(joinpath(proj, "Project.toml"), "[deps]\nTOML = \"$toml\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        [[TOML]]
        git-tree-sha1 = "d0ac7eaad0fb9f6ba023a1d743edca974ae637c4"
        uuid = "$toml"
        version = "1.0.0"
        """)

        jw = workspace_from_folders([proj])
        p = derived_project(jw.runtime, first(get_projects(jw)))
        @test p !== nothing
        @test haskey(p.stdlib_packages, "TOML")             # reclassified as stdlib
        @test p.stdlib_packages["TOML"].version == string(sv)
        @test !haskey(p.regular_packages, "TOML")           # not keyed by the tree-sha
    end
end

@testitem "Stdlib key: child caches a tree-sha'd stdlib at the bundled version and the parent finds it" begin
    using JuliaWorkspaces: _get_missing_packages, _stdlib_cache_version
    using UUIDs: UUID

    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    toml = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    tree = "d0ac7eaad0fb9f6ba023a1d743edca974ae637c4"   # TOML's git-tree-sha1 in the fixture manifest
    sv = _stdlib_cache_version(UUID(toml))

    mktempdir() do root
        # The real UsesPreferences fixture records TOML (a stdlib) with a
        # git-tree-sha1, the exact case that used to relaunch. Copy the whole
        # Preferences package so its `[sources]`-deved `../..` path still resolves,
        # and index a temp store — a hand-written manifest can't be loaded by the
        # child on all Julia versions.
        cp(joinpath(@__DIR__, "..", "packages", "Preferences"), joinpath(root, "Preferences"))
        proj = joinpath(root, "Preferences", "test", "UsesPreferences")
        store = joinpath(root, "store"); mkpath(store)

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

        # The child cached TOML at the bundled-version key, NOT the manifest tree-sha.
        @test isfile(joinpath(store, "T", "TOML", toml, "$(sv).jstore"))
        @test !isfile(joinpath(store, "T", "TOML", toml, "$tree.jstore"))

        # The parent's launch gate keys TOML the same way and finds it (no relaunch).
        @test !any(p -> p.name == "TOML", _get_missing_packages(proj, store))
    end
end
