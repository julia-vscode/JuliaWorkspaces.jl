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
    # The standalone keys' fast-lane check runs off-reactor and hasn't reported
    # back yet, so the only synchronous kind grabs the sole slot first.
    @test length(launches) == 1
    @test launches[1] == first_up

    # Drain the two async standalone-prep decisions (both dirs are fresh, so
    # neither is fast-laned); with no free slot left, both simply queue.
    for _ in 1:2
        handle!(df, take!(df.in_channel))
    end
    @test Set(df.launch_queue) == Set([shallow_late, deep])

    handle!(df, ProcessIndexedMsg(first_up, "/tmp/x"))
    @test length(launches) == 2
    @test launches[2] == shallow_late           # depth 2 beats depth 4

    handle!(df, ProcessIndexFailedMsg(shallow_late, ErrorException("boom")))
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
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    fixture  = CreateStandaloneProjectKey("/ws/Pkg/test/testdata/Fix", UInt64(1))
    root_sa  = CreateStandaloneProjectKey("/ws/Pkg", UInt64(2))
    testenv  = WatchTestEnvironmentKey("/ws/Pkg", "Pkg", UInt64(3))

    handle!(df, ReconcileMsg(Set{DJPKey}([fixture, root_sa, testenv])))
    # The standalone keys' fast-lane check runs off-reactor and hasn't reported
    # back yet, so the only synchronous kind grabs the sole slot.
    @test launches == [testenv]

    # Drain the two async standalone-prep decisions (both dirs are fresh, so
    # neither is fast-laned); with no free slot left, both simply queue.
    for _ in 1:2
        handle!(df, take!(df.in_channel))
    end
    @test launches == [testenv]
    @test Set(df.launch_queue) == Set([root_sa, fixture])

    handle!(df, ProcessIndexedMsg(testenv, "/tmp/x"))
    @test launches == [testenv, root_sa]      # shallower standalone wins the freed slot
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

@testitem "Dynamic reconcile: standalone project dirs are hash-keyed and cleaned up" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, CreateStandaloneProjectKey,
        _standalone_project_dir

    store = mktempdir()
    df = DynamicFeature(DynamicPersistent, store; launcher=(df, djp) -> nothing)

    key1 = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0x1234))
    key2 = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0x5678))

    dir1 = _standalone_project_dir(df, key1)
    @test startswith(dir1, joinpath(dirname(store), "standalone-projects"))
    @test occursin("Pkg-", basename(dir1))
    @test _standalone_project_dir(df, key1) == dir1      # deterministic
    @test isdir(dir1)                                    # parent-created

    dir2 = _standalone_project_dir(df, key2)
    @test dir2 != dir1
    @test !isdir(dir1)      # old hash dir for the same package cleaned up
end

@testitem "Dynamic reconcile: standalone fast lane serves existing project without a child" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, CreateStandaloneProjectMsg,
        StandaloneProjectPrepDoneMsg, CreateStandaloneProjectKey, StandaloneProjectReadyResult,
        DJPKey, handle!, _standalone_project_dir

    launches = DJPKey[]
    store = mktempdir()
    df = DynamicFeature(DynamicPersistent, store; launcher=(df, djp) -> push!(launches, djp.key))

    key = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0xabc))
    dir = _standalone_project_dir(df, key)
    write(joinpath(dir, "Project.toml"), "name = \"scratch\"\n")
    write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n\n[deps]\n")

    # Drive the prep decision synchronously (the async prep task is exercised
    # end-to-end by the suites; reactor logic is what we test here).
    push!(df.inflight, key)
    handle!(df, StandaloneProjectPrepDoneMsg(key, true))

    @test isempty(launches)                       # no child
    @test key in df.done
    @test df.refresh_queue == [key]               # background refresh queued
    result = take!(df.out_channel)
    @test result isa StandaloneProjectReadyResult
end

@testitem "Dynamic reconcile: standalone prep miss launches through the cap" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    k1 = CreateStandaloneProjectKey("/ws/A", UInt64(1))
    k2 = CreateStandaloneProjectKey("/ws/B", UInt64(2))
    push!(df.inflight, k1); push!(df.inflight, k2)

    handle!(df, StandaloneProjectPrepDoneMsg(k1, false))
    handle!(df, StandaloneProjectPrepDoneMsg(k2, false))

    @test launches == [k1]
    @test df.launch_queue == [k2]
    @test isempty(df.refresh_queue)
end

@testitem "Dynamic reconcile: refresh runs at strict low priority and is not a work item" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ProcessIndexedMsg, ProcessIndexFailedMsg, CreateStandaloneProjectKey,
        WatchTestEnvironmentKey, WatchTestEnvironmentMsg, StandaloneProjectReadyResult, DJPKey,
        handle!, _standalone_project_dir

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    fast = CreateStandaloneProjectKey("/ws/Fast", UInt64(1))
    slow = WatchTestEnvironmentKey("/ws/Slow", "Slow", UInt64(2))

    # Fast-lane hit queues a refresh...
    push!(df.inflight, fast)
    handle!(df, StandaloneProjectPrepDoneMsg(fast, true))
    take!(df.out_channel)               # the served-stale ready result
    pending_after_serve = df.pending_count[]

    # ...but first-time work still wins the only slot.
    push!(df.inflight, slow)
    handle!(df, WatchTestEnvironmentMsg(slow))
    @test launches == [slow]

    # Slot frees with nothing left in the primary queue -> refresh launches.
    handle!(df, ProcessIndexedMsg(slow, "/tmp/x"))
    take!(df.out_channel)               # slow's ready result
    @test launches == [slow, fast]
    @test fast in df.refreshing
    @test df.pending_count[] == pending_after_serve - 1   # -1 is slow's own completion; refresh itself never counted

    # Refresh completion re-emits the ready result and frees the slot.
    handle!(df, ProcessIndexedMsg(fast, _standalone_project_dir(df, fast)))
    @test take!(df.out_channel) isa StandaloneProjectReadyResult
    @test !(fast in df.refreshing)

    # A refresh failure must not poison failed_projects.
    push!(df.inflight, fast)
    handle!(df, StandaloneProjectPrepDoneMsg(fast, true))
    take!(df.out_channel)
    handle!(df, ProcessIndexedMsg(WatchTestEnvironmentKey("/dummy", "D", UInt64(9)), "/tmp"))  # no-op drain trigger
    # drain directly: the queue drains on any slot release; fast is queued
    @test fast in df.refresh_queue || fast in df.refreshing
    if fast in df.refreshing
        handle!(df, ProcessIndexFailedMsg(fast, ErrorException("refresh boom")))
        @test !(fast in df.failed_projects)
        @test fast in df.done
    end
end

@testitem "Dynamic reconcile: reconcile purges dropped refresh entries" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ReconcileMsg, CreateStandaloneProjectKey, DJPKey, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    key = CreateStandaloneProjectKey("/ws/Gone", UInt64(7))
    push!(df.inflight, key)
    handle!(df, StandaloneProjectPrepDoneMsg(key, true))
    take!(df.out_channel)
    @test key in df.refresh_queue

    handle!(df, ReconcileMsg(Set{DJPKey}()))
    @test isempty(df.refresh_queue)
    @test isempty(df.refreshing)
end
