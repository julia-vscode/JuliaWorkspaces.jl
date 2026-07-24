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
