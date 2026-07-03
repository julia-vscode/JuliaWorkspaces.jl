@testitem "SymbolCache client: cache_key / cache_key_from_path" begin
    using JuliaWorkspaces.SymbolServer: cache_key, cache_key_from_path
    @test cache_key("abc-uuid", "deadbeef") == "abc-uuid/deadbeef"
    # get_cache_path shape: [Initial, Name, uuid, "<stem>.jstore"]
    @test cache_key_from_path(["E", "Example", "abc-uuid", "deadbeef.jstore"]) == "abc-uuid/deadbeef"
end

@testitem "SymbolCache client: parse_availability_index" begin
    using JuliaWorkspaces.SymbolServer: parse_availability_index
    text = "u1/h1\nu2/h2\n\n  u3/h3  \n"
    s = parse_availability_index(text)
    @test s == Set(["u1/h1", "u2/h2", "u3/h3"])      # trims, drops blank lines
    @test parse_availability_index(IOBuffer(text)) == s
    @test isempty(parse_availability_index(""))
end

@testitem "SymbolCache client: fetch_availability_index loads a real index tarball" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.SymbolServer: fetch_availability_index
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    mktempdir() do up
        # lay out <up>/store/<version>/index.tar.gz containing index.txt
        d = mkpath(joinpath(up, "store", V))
        idxtxt = joinpath(up, "index.txt"); write(idxtxt, "u1/h1\nu2/h2\n")
        run(`tar -czf $(joinpath(d, "index.tar.gz")) -C $up index.txt`)
        got = fetch_availability_index("file://" * up)
        @test got == Set(["u1/h1", "u2/h2"])
    end
    # unreachable upstream -> nothing (graceful)
    @test fetch_availability_index("file:///no/such/path/xyz") === nothing
end

@testitem "SymbolCache client: keep_available! intersects with the index" begin
    using JuliaWorkspaces.SymbolServer: keep_available!, cache_key_from_path, get_cache_path, read_manifest
    using Base: UUID

    # Write a minimal manifest_format "2.0" with two packages
    mktempdir() do dir
        manifest_path = joinpath(dir, "Manifest.toml")
        u1 = "11111111-1111-1111-1111-111111111111"
        u2 = "22222222-2222-2222-2222-222222222222"
        write(manifest_path, """
manifest_format = "2.0"

[[deps.PkgA]]
uuid = "$u1"
git-tree-sha1 = "aabbccdd00000000000000000000000000000001"

[[deps.PkgB]]
uuid = "$u2"
git-tree-sha1 = "aabbccdd00000000000000000000000000000002"
""")
        manifest = read_manifest(manifest_path)
        @test manifest !== nothing

        to_download = collect(manifest)

        # Build index containing only PkgA's cache key
        pkgA_key = cache_key_from_path(get_cache_path(manifest, UUID(u1)))
        index = Set([pkgA_key])

        keep_available!(to_download, manifest, index)

        @test length(to_download) == 1
        @test first(to_download).first == UUID(u1)
    end
end

@testitem "SymbolCache client: _download_missing_caches trusts the availability index" begin
    using JuliaWorkspaces: MissingPackage, _download_missing_caches
    using JuliaWorkspaces.SymbolServer: write_cache, Package, ModuleStore, VarRef, CACHE_STORE_VERSION
    using Base: UUID

    V = CACHE_STORE_VERSION
    mktempdir() do tmp
        bucket = joinpath(tmp, "bucket")
        name, uuid, stem, letter = "Foo", "764a87c0-6b3e-53db-9096-fe964310641d", "deadbeef", "F"

        # Server layout: a valid .jstore artifact for Foo + an index listing only Foo.
        js = joinpath(tmp, "$stem.jstore")
        mod = ModuleStore(VarRef(nothing, Symbol(name)), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
        write_cache(UUID(uuid), Package(name, mod, UUID(uuid), nothing), js)
        pkgdir = mkpath(joinpath(bucket, "store", V, "packages", letter, name, uuid))
        run(`tar -czf $(joinpath(pkgdir, "$stem.tar.gz")) -C $tmp $stem.jstore`)

        idxdir = mkpath(joinpath(tmp, "idx"))
        write(joinpath(idxdir, "index.txt"), "$uuid/$stem\n")
        mkpath(joinpath(bucket, "store", V))
        run(`tar -czf $(joinpath(bucket, "store", V, "index.tar.gz")) -C $idxdir index.txt`)

        upstream = "file://" * bucket
        store = mkpath(joinpath(tmp, "store"))

        available = MissingPackage((name, UUID(uuid), "1.0.0", stem))
        # absent from the index — simulates a private / uncached package
        private = MissingPackage(("Secret", UUID("00000000-0000-0000-0000-0000000000ff"), "2.0.0", "cafef00d"))

        still = _download_missing_caches([available, private], store, upstream)

        # Only the indexed package was fetched, unpacked, and stored.
        @test isfile(joinpath(store, letter, name, uuid, "$stem.jstore"))
        # The unlisted package was never requested (no dir for it) and stays missing.
        @test !ispath(joinpath(store, "S"))
        @test [p.name for p in still] == ["Secret"]
    end

    # Index unavailable → no downloads attempted; everything stays missing.
    mktempdir() do tmp
        store = mkpath(joinpath(tmp, "store"))
        pkg = MissingPackage(("Foo", UUID("764a87c0-6b3e-53db-9096-fe964310641d"), "1.0.0", "deadbeef"))
        still = _download_missing_caches([pkg], store, "file:///no/such/upstream/xyz")
        @test still == [pkg]
        @test isempty(readdir(store))
    end
end
