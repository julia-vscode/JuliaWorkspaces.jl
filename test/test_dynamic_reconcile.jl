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
