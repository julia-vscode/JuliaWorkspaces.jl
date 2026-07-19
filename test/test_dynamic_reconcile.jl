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

@testitem "Dynamic reconcile: dropped keys are purged from queue and accounting balances" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:3]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))
    @test length(launches) == 1
    @test length(df.launch_queue) == 2

    # Second reconcile keeps only the launched key: queued keys must vanish
    # without ever launching, and their pending work items must be balanced.
    handle!(df, ReconcileMsg(Set{DJPKey}([launches[1]])))
    @test isempty(df.launch_queue)
    @test df.pending_count[] == 1

    handle!(df, ProcessIndexedMsg(launches[1], "/tmp/x"))
    @test df.pending_count[] == 0
    @test length(launches) == 1
end

@testitem "Dynamic reconcile: initial dispatch launches shallowest keys first" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=2, launcher=(df, djp) -> push!(launches, djp.key))

    fixture  = CreateStandaloneProjectKey("/ws/Pkg/test/testdata/Fix", UInt64(1))
    root_sa  = CreateStandaloneProjectKey("/ws/Pkg", UInt64(2))
    testenv  = WatchTestEnvironmentKey("/ws/Pkg", "Pkg", UInt64(3))

    handle!(df, ReconcileMsg(Set{DJPKey}([fixture, root_sa, testenv])))
    @test launches == [root_sa, testenv]      # standalone(1) then testenv(2) at depth 2
    @test df.launch_queue == [fixture]
end

@testitem "Dynamic reconcile: resolve_workspace_environments=false keeps only real envs" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_required_dynamic_projects, WatchEnvironmentKey
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "P"
    uuid = "11111111-1111-1111-1111-111111111111"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc"

    [deps]
    """
    # A workspace project (watch-env key) plus a manifest-less package
    # (standalone key) with a runtests.jl (test-env key).
    files = [
        TextFile(URI("file:///ws/Proj/Project.toml"), SourceText(project_toml, "toml")),
        TextFile(URI("file:///ws/Proj/Manifest.toml"), SourceText(manifest_toml, "toml")),
        TextFile(URI("file:///ws/Proj/src/P.jl"), SourceText("module P end", "julia")),
        TextFile(URI("file:///ws/Bare/Project.toml"), SourceText(replace(project_toml, "\"P\"" => "\"Bare\"", "1111\"" => "2222\""), "toml")),
        TextFile(URI("file:///ws/Bare/src/Bare.jl"), SourceText("module Bare end", "julia")),
        TextFile(URI("file:///ws/Bare/test/runtests.jl"), SourceText("using Test", "julia")),
    ]

    jw_on = JuliaWorkspace()
    foreach(f -> add_file!(jw_on, f), files)
    req_on = derived_required_dynamic_projects(jw_on.runtime)

    jw_off = JuliaWorkspace(resolve_workspace_environments=false)
    foreach(f -> add_file!(jw_off, f), files)
    req_off = derived_required_dynamic_projects(jw_off.runtime)

    @test any(k -> !(k isa WatchEnvironmentKey), req_on)      # sanity: fabrication happens
    @test all(k -> k isa WatchEnvironmentKey, req_off)        # ...and is fully disabled
    @test !isempty(req_off)                                   # real projects still watched
end
