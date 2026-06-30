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
