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

@testitem "Dynamic reconcile: finished work frees a slot for the best-priority queued key" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        ProcessIndexFailedMsg, WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    shallow_late = CreateStandaloneProjectKey("/ws/A", UInt64(1))          # standalone, depth 2
    deep         = CreateStandaloneProjectKey("/ws/A/test/data/B", UInt64(2))
    first_up     = WatchTestEnvironmentKey("/ws/C/sub", "C", UInt64(3))    # depth 3

    # Insertion order deliberately not priority order.
    handle!(df, ReconcileMsg(Set{DJPKey}([deep, first_up, shallow_late])))
    @test length(launches) == 1
    @test launches[1] == shallow_late          # dispatch is priority-sorted (Task 4 asserts too)

    handle!(df, ProcessIndexedMsg(launches[1], "/tmp/x"))
    @test length(launches) == 2
    @test launches[2] == first_up              # depth 3 beats depth 4

    handle!(df, ProcessIndexFailedMsg(launches[2], ErrorException("boom")))
    @test length(launches) == 3
    @test launches[3] == deep
    @test isempty(df.launch_queue)
    @test df.pending_count[] == 1              # only `deep` still pending
end
