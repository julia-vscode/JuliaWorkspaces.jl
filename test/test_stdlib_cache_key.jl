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
