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
