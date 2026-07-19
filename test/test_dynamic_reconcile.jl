@testitem "Dynamic reconcile: launch priority orders by depth then kind" begin
    using JuliaWorkspaces: _launch_priority, WatchEnvironmentKey, WatchTestEnvironmentKey,
        CreateStandaloneProjectKey

    root_env   = WatchEnvironmentKey("/ws/Pkg", UInt64(1))
    testenv    = WatchTestEnvironmentKey("/ws/Pkg", "Pkg", UInt64(2))
    standalone = CreateStandaloneProjectKey("/ws/Pkg", UInt64(3))
    fixture    = CreateStandaloneProjectKey("/ws/Pkg/test/testdata/Fixture", UInt64(4))
    nested_env = WatchEnvironmentKey("/ws/Pkg/docs", UInt64(5))

    # shallower paths first
    @test _launch_priority(root_env) < _launch_priority(nested_env)
    @test _launch_priority(nested_env) < _launch_priority(fixture)
    # kind rank breaks ties at equal depth: env < standalone < test env
    @test _launch_priority(root_env) < _launch_priority(standalone)
    @test _launch_priority(standalone) < _launch_priority(testenv)
end

@testitem "Dynamic reconcile: cap limits concurrent launches" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=2, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))

    @test length(launches) == 2
    @test length(df.launch_queue) == 3
    @test length(df.launching) == 2
    @test df.pending_count[] == 5          # queued work still counts as pending
    @test isempty(intersect(Set(df.launch_queue), df.launching))
end

@testitem "Dynamic reconcile: cap 0 means unlimited" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=0, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))

    @test length(launches) == 5
    @test isempty(df.launch_queue)
end
