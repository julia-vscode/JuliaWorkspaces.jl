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

@testitem "Package cache loading: extends cache does not pin dropped module stores" begin
    using JuliaWorkspaces: _module_extends_contributions
    using JuliaWorkspaces.SymbolServer: ModuleStore, VarRef

    # A re-created/dropped package store must be collectable — the extends cache
    # holds only a WeakRef, so it never pins the store (and its whole symbol
    # table) for the process lifetime.
    function cache_an_ephemeral_store()
        ms = ModuleStore(VarRef(nothing, :Ephemeral), Dict{Symbol,Any}(), "", Symbol[], Symbol[], Symbol[])
        _module_extends_contributions(ms)   # populate the cache
        return WeakRef(ms)
    end

    wr = cache_an_ephemeral_store()
    GC.gc(true); GC.gc(true)
    @test wr.value === nothing              # collected ⇒ the cache did not pin it
end

@testitem "Package cache loading: a cache that does not fit in memory is skipped, not re-queued" begin
    using JuliaWorkspaces: JuliaWorkspaces, DynamicFeature, DynamicIndexingOnly, SContext, PkgCacheKey,
        _ensure_package_cache_loaded!, _package_cache_path, input_package_metadata
    using JuliaWorkspaces.Salsa: Runtime
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    name = :HugePkg
    uuid = Base.UUID("55555555-2222-3333-4444-555555555555")
    version = v"0.12.7"
    tree = "0123456789abcdef4567"
    key = PkgCacheKey((name, uuid, version, tree))

    cache_file = _package_cache_path(store, name, uuid, version, tree)
    mkpath(dirname(cache_file))
    pkg = Package(string(name), ModuleStore(VarRef(nothing, name), Dict{Symbol,Any}(), "", Symbol[], Symbol[], Symbol[]), uuid, nothing)
    open(io -> CacheStore.write(io, pkg), cache_file, "w")

    reads = Ref(0)
    df = DynamicFeature(DynamicIndexingOnly, store; cache_reader=p -> (reads[] += 1; throw(OutOfMemoryError())))
    rt = Runtime{SContext}(SContext(df))

    # The lazy input must neither throw nor treat this as a miss.
    result = @test_logs (:warn, r"Not enough memory to load the symbol cache for HugePkg") input_package_metadata(rt, name, uuid, version, tree)
    @test result === nothing
    @test reads[] == 2
    @test key in df.unloadable_pkg_metadata
    @test !(key in df.missing_pkg_metadata)
    @test !(key in df.loaded_pkg_metadata)
    @test isfile(cache_file)

    # The eager loaders skip it without touching the disc.
    @test !_ensure_package_cache_loaded!(rt, df, name, uuid, version, tree)
    @test reads[] == 2

    # A queued miss whose cache turns out not to fit leaves the missing set, so
    # `_load_missing_package_metadata!` does not retry it on every environment.
    other = PkgCacheKey((:OtherHugePkg, uuid, version, tree))
    other_file = _package_cache_path(store, other.name, uuid, version, tree)
    mkpath(dirname(other_file))
    cp(cache_file, other_file)
    push!(df.missing_pkg_metadata, other)
    @test !_ensure_package_cache_loaded!(rt, df, other.name, uuid, version, tree)
    @test other in df.unloadable_pkg_metadata
    @test !(other in df.missing_pkg_metadata)
    @test isfile(other_file)
end
