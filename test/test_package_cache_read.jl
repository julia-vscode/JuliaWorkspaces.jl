# Reading one package's `.jstore` symbol cache. A cache on disc is untrusted
# input: it can be truncated by a killed indexer or a host crash, or left over
# in an older serialization format. Every read path must treat that as a plain
# cache miss, never as an error, because both the lazy Salsa input and the eager
# loader run where a thrown exception would take down the whole host process.

@testitem "Package cache: a corrupt .jstore is a miss and is deleted" begin
    using JuliaWorkspaces: _package_cache_path, _read_package_cache, _try_load_package_cache
    using UUIDs: UUID

    store = mktempdir()
    uuid = UUID("00000000-0000-0000-0000-000000000001")
    path = _package_cache_path(store, :Foo, uuid, v"1.0.0", nothing)

    mkpath(dirname(path))
    write(path, "not a jstore at all")

    @test _read_package_cache(path, :Foo, uuid) === nothing
    # Deleted, not merely skipped: the miss feeds the normal re-index path, so
    # the store heals instead of failing identically on every future run.
    @test !isfile(path)

    # Second read of the now-absent file is still a plain miss.
    @test _read_package_cache(path, :Foo, uuid) === nothing
    @test _try_load_package_cache(store, :Foo, uuid, v"1.0.0", nothing) === nothing
end

@testitem "Package cache: a missing .jstore is a miss without touching disc" begin
    using JuliaWorkspaces: _package_cache_path, _read_package_cache
    using UUIDs: UUID

    store = mktempdir()
    uuid = UUID("00000000-0000-0000-0000-000000000002")
    path = _package_cache_path(store, :Bar, uuid, v"2.1.0", nothing)

    @test !isfile(path)
    @test _read_package_cache(path, :Bar, uuid) === nothing
    @test !isdir(dirname(path))
end

@testitem "Package cache: the path layout matches between reader and writer" begin
    using JuliaWorkspaces: _package_cache_path, _jstore_path, MissingPackage
    using UUIDs: UUID

    uuid = UUID("00000000-0000-0000-0000-000000000003")
    store = "/store"

    # The git_tree_sha1 wins over the version when present, and `+` is escaped
    # because it is not portable in a filename.
    @test basename(_package_cache_path(store, :Baz, uuid, v"1.0.0", "abc123")) == "abc123.jstore"
    @test basename(_package_cache_path(store, :Baz, uuid, v"1.0.0+2", nothing)) == "1.0.0_2.jstore"
    @test occursin(joinpath("B", "Baz", string(uuid)), _package_cache_path(store, :Baz, uuid, v"1.0.0", nothing))

    # The writer side must land on exactly the same file as the reader side.
    pkg = MissingPackage((name="Baz", uuid=uuid, version="1.0.0", git_tree_sha1="abc123"))
    @test _jstore_path(pkg, store) == _package_cache_path(store, :Baz, uuid, v"1.0.0", "abc123")
end

@testitem "Package cache: writes are atomic" begin
    using JuliaWorkspaces.SymbolServer: write_cache_atomic, Package, ModuleStore, VarRef
    using JuliaWorkspaces.SymbolServer.CacheStore: read as cache_read
    using UUIDs: UUID

    dir = mktempdir()
    out = joinpath(dir, "nested", "Foo.jstore")

    mod = ModuleStore(VarRef(nothing, :Foo), Dict{Symbol,Any}(), "", Symbol[], Symbol[], Symbol[])
    pkg = Package("Foo", mod, UUID("00000000-0000-0000-0000-000000000004"), nothing)
    @test write_cache_atomic(pkg, out) == out
    @test isfile(out)

    roundtripped = open(cache_read, out)
    @test roundtripped.name == "Foo"

    # No temp files left behind, and overwriting an existing cache still leaves
    # exactly one file: an in-place truncating write is what produced the
    # corrupt caches this guards against.
    @test write_cache_atomic(pkg, out) == out
    @test readdir(dirname(out)) == ["Foo.jstore"]
end
