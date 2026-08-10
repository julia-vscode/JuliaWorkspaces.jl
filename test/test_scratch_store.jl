@testitem "Scratch usage stamping is rate limited" begin
    import JuliaWorkspaces.Scratch
    TOML = JuliaWorkspaces.Pkg.TOML

    scratch_key = "store_path_$(JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION)"
    jw_uuid = string(Base.PkgId(JuliaWorkspaces).uuid)

    # Fresh depot without a marker: the first call stamps usage and creates
    # the marker.
    mktempdir() do depot
        pushfirst!(Base.DEPOT_PATH, depot)
        try
            empty!(Scratch.scratch_access_timers)

            usage_file = joinpath(depot, "logs", "scratch_usage.toml")
            marker = joinpath(depot, "scratchspaces", jw_uuid, scratch_key, ".usage_stamped")

            path = JuliaWorkspaces.get_scratch_rate_limited(scratch_key)
            @test isdir(path)
            @test isfile(marker)
            @test isfile(usage_file)
            usage = TOML.parsefile(usage_file)
            @test haskey(usage, path)

            # Recent marker: subsequent calls leave the usage log untouched.
            # Reset Scratch's in-process timer so suppression really comes
            # from the marker, not from Scratch's own per-process rate limit.
            content_before = read(usage_file, String)
            empty!(Scratch.scratch_access_timers)
            path2 = JuliaWorkspaces.get_scratch_rate_limited(scratch_key)
            @test path2 == path
            @test read(usage_file, String) == content_before

            # Marker gone: usage gets stamped again.
            rm(marker)
            empty!(Scratch.scratch_access_timers)
            JuliaWorkspaces.get_scratch_rate_limited(scratch_key)
            @test isfile(marker)
            @test read(usage_file, String) != content_before
        finally
            popfirst!(Base.DEPOT_PATH)
            empty!(Scratch.scratch_access_timers)
        end
    end

    # Pre-existing fresh marker (the parallel-test-worker scenario): no usage
    # log write at all.
    mktempdir() do depot
        pushfirst!(Base.DEPOT_PATH, depot)
        try
            empty!(Scratch.scratch_access_timers)

            usage_file = joinpath(depot, "logs", "scratch_usage.toml")
            scratch_dir = joinpath(depot, "scratchspaces", jw_uuid, scratch_key)
            mkpath(scratch_dir)
            touch(joinpath(scratch_dir, ".usage_stamped"))

            path = JuliaWorkspaces.get_scratch_rate_limited(scratch_key)
            @test isdir(path)
            @test !isfile(usage_file)
        finally
            popfirst!(Base.DEPOT_PATH)
            empty!(Scratch.scratch_access_timers)
        end
    end
end
