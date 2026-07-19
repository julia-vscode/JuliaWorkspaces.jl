@testitem "Package cache loading: loads once, skips disc thereafter" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _ensure_package_cache_loaded!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    name = :TestCachePkg
    uuid = Base.UUID("11111111-2222-3333-4444-555555555555")
    version = v"1.2.3"
    tree = "abcdef0123456789abcd"

    cache_dir = joinpath(store, "T", string(name), string(uuid))
    mkpath(cache_dir)
    pkg = Package(string(name),
        ModuleStore(VarRef(nothing, name), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        uuid, nothing)
    cache_file = joinpath(cache_dir, string(tree, ".jstore"))
    open(io -> CacheStore.write(io, pkg), cache_file, "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)

    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)
    @test input_package_metadata(jw.runtime, name, uuid, version, tree) !== nothing

    # Once loaded, the helper must not touch the disc again: with the cache
    # file gone, a re-read would fail, so returning true proves the skip.
    rm(cache_file)
    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)

    # A package with no cache on disc reports false.
    @test !_ensure_package_cache_loaded!(jw, :NoCachePkg,
        Base.UUID("99999999-2222-3333-4444-555555555555"), v"1.0.0", nothing)
end

@testitem "Package cache loading: lazy input loads are recorded" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _ensure_package_cache_loaded!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    name = :LazyCachePkg
    uuid = Base.UUID("22222222-2222-3333-4444-555555555555")
    version = v"0.1.0"
    tree = "0123456789abcdef0123"

    cache_dir = joinpath(store, "L", string(name), string(uuid))
    mkpath(cache_dir)
    pkg = Package(string(name),
        ModuleStore(VarRef(nothing, name), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        uuid, nothing)
    cache_file = joinpath(cache_dir, string(tree, ".jstore"))
    open(io -> CacheStore.write(io, pkg), cache_file, "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)

    # Probing the input triggers the lazy default, which reads the cache.
    @test input_package_metadata(jw.runtime, name, uuid, version, tree) !== nothing

    # That lazy load must be recorded: with the file gone the helper can only
    # return true if it skips the disc read.
    rm(cache_file)
    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)
end

@testitem "Package cache loading: missing set drains on success, keeps unavailable" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _load_missing_package_metadata!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    cached_uuid = Base.UUID("33333333-2222-3333-4444-555555555555")
    uncached_uuid = Base.UUID("44444444-2222-3333-4444-555555555555")
    tree = "fedcba9876543210fedc"

    cache_dir = joinpath(store, "C", "CachedPkg", string(cached_uuid))
    mkpath(cache_dir)
    pkg = Package("CachedPkg",
        ModuleStore(VarRef(nothing, :CachedPkg), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        cached_uuid, nothing)
    open(io -> CacheStore.write(io, pkg), joinpath(cache_dir, string(tree, ".jstore")), "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)
    df = jw.dynamic_feature

    cached_key = (name=:CachedPkg, uuid=cached_uuid, version=v"1.0.0", git_tree_sha1=tree)
    uncached_key = (name=:UncachedPkg, uuid=uncached_uuid, version=v"1.0.0", git_tree_sha1=nothing)
    push!(df.missing_pkg_metadata, cached_key)
    push!(df.missing_pkg_metadata, uncached_key)

    _load_missing_package_metadata!(jw)

    # The loadable entry is drained; the unavailable one stays for retry.
    @test collect(df.missing_pkg_metadata) == [uncached_key]
    @test input_package_metadata(jw.runtime, :CachedPkg, cached_uuid, v"1.0.0", tree) !== nothing
end
