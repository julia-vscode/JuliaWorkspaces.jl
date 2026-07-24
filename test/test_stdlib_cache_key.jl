@testitem "Stdlib key: _stdlib_cache_version maps stdlibs to the bundled version" begin
    using JuliaWorkspaces: _stdlib_cache_version
    import Pkg
    using UUIDs: UUID

    toml  = UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")   # stdlib (was registered pre-1.6)
    prefs = UUID("21216c6a-2e73-6563-6e65-726566657250")   # registered package, not a stdlib

    infos = Pkg.Types.stdlib_infos()
    @test _stdlib_cache_version(toml) isa VersionNumber
    @test _stdlib_cache_version(toml) == something(infos[toml].version, VERSION)  # matches the child's key
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
