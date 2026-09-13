@testitem "Dynamic status: snapshot classifies work items" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        ProcessIndexFailedMsg, ProcessProgressMsg, WatchTestEnvironmentKey, DJPKey,
        dynamic_status_snapshot, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> nothing)

    keys_ = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:3]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys_)))

    snap = dynamic_status_snapshot(df)
    @test !snap.indexing_done
    @test snap.pending_count == 3
    @test snap.max_concurrent_djps == 1
    @test length(snap.items) == 3
    @test issorted([item.path for item in snap.items])
    @test all(item -> item.kind === :watch_test_environment, snap.items)
    @test all(item -> item.package !== nothing, snap.items)
    @test count(item -> item.status === :running, snap.items) == 1
    @test count(item -> item.status === :queued, snap.items) == 2

    # Child progress lands on the running item.
    running_key = only(collect(df.launching))
    handle!(df, ProcessProgressMsg(running_key, "indexing...", 42))
    snap = dynamic_status_snapshot(df)
    running_item = only(filter(item -> item.status === :running, snap.items))
    @test running_item.progress == 42
    @test running_item.alive          # its (fake) child is in df.procs

    # Completion: the item turns :done (child kept alive under
    # DynamicPersistent) and the freed slot launches the next queued key.
    handle!(df, ProcessIndexedMsg(running_key, "/tmp/x"))
    snap = dynamic_status_snapshot(df)
    done_item = only(filter(item -> item.status === :done, snap.items))
    @test done_item.path == running_key.project_path
    @test done_item.alive
    @test done_item.progress === nothing   # cleared on completion
    @test count(item -> item.status === :running, snap.items) == 1
    @test count(item -> item.status === :queued, snap.items) == 1
    @test snap.pending_count == 2

    # A terminal (non-infra) failure carries its user-facing message.
    failed_key = only(collect(df.launching))
    handle!(df, ProcessIndexFailedMsg(failed_key, ErrorException("boom")))
    snap = dynamic_status_snapshot(df)
    failed_item = only(filter(item -> item.status === :failed, snap.items))
    @test failed_item.path == failed_key.project_path
    @test failed_item.failure_message !== nothing
    @test occursin("boom", failed_item.failure_message)
    @test !snap.indexing_done

    # The last item settles: with the initial reconcile recorded (production
    # sets this flag before sending the ReconcileMsg), the snapshot reports
    # indexing done right on the reactor. is_ready's saw_result cannot back
    # this field - it flips only when results are consumed, which happens
    # after the last reactor message, so the final snapshot would stay busy.
    df.reconciled_once[] = true
    last_key = only(collect(df.launching))
    handle!(df, ProcessIndexedMsg(last_key, "/tmp/y"))
    snap = dynamic_status_snapshot(df)
    @test snap.indexing_done
    @test snap.pending_count == 0
end

@testitem "Dynamic status: failed keys leave the snapshot when no longer required" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        ProcessIndexFailedMsg, WatchTestEnvironmentKey, DJPKey, dynamic_status_snapshot, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)

    key = WatchTestEnvironmentKey("/ws/p", "P", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([key])))
    handle!(df, ProcessIndexFailedMsg(key, ErrorException("boom")))
    @test only(dynamic_status_snapshot(df).items).status === :failed

    # `failed_projects` is never pruned, but a re-keying edit must not leave the
    # stale key's entry in the snapshot forever.
    rekeyed = WatchTestEnvironmentKey("/ws/p", "P", UInt64(2))
    handle!(df, ReconcileMsg(Set{DJPKey}([rekeyed])))
    snap = dynamic_status_snapshot(df)
    @test all(item -> item.status !== :failed, snap.items)
    @test key in df.failed_projects           # bookkeeping itself is untouched
end

@testitem "Dynamic status: fast-lane serve reports refresh states" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ProcessIndexedMsg, CreateStandaloneProjectKey, WatchTestEnvironmentKey,
        WatchTestEnvironmentMsg, DJPKey, dynamic_status_snapshot, handle!,
        _standalone_project_dir_path

    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> nothing)

    fast = CreateStandaloneProjectKey("/ws/Fast", UInt64(1))
    slow = WatchTestEnvironmentKey("/ws/Slow", "Slow", UInt64(2))

    # First-time work occupies the only slot (accounting driven as ReconcileMsg
    # would), so the fast-laned key's background refresh has to queue.
    push!(df.inflight, slow)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, WatchTestEnvironmentMsg(slow))

    push!(df.inflight, fast)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, StandaloneProjectPrepDoneMsg(fast, true))
    take!(df.out_channel)               # the served-stale ready result

    snap = dynamic_status_snapshot(df)
    fast_item = only(filter(item -> item.path == "/ws/Fast", snap.items))
    @test fast_item.status === :refresh_queued
    @test fast_item.kind === :create_standalone_project

    # The slot frees up: the refresh launches and reports :refreshing, taking
    # precedence over the item's `done` membership.
    handle!(df, ProcessIndexedMsg(slow, "/tmp/x"))
    take!(df.out_channel)
    snap = dynamic_status_snapshot(df)
    fast_item = only(filter(item -> item.path == "/ws/Fast", snap.items))
    @test fast_item.status === :refreshing
    @test fast in df.done

    # Refresh completion: back to a plain :done item.
    handle!(df, ProcessIndexedMsg(fast, _standalone_project_dir_path(df, fast)))
    take!(df.out_channel)
    snap = dynamic_status_snapshot(df)
    fast_item = only(filter(item -> item.path == "/ws/Fast", snap.items))
    @test fast_item.status === :done
end

@testitem "Dynamic status: reactor delivers snapshots only on change" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ShutdownMsg,
        ProcessIndexedMsg, WatchTestEnvironmentKey, DJPKey, DynamicStatusSnapshot

    snapshots = DynamicStatusSnapshot[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        launcher=(df, djp) -> nothing,
        status_callback=snap -> push!(snapshots, snap))

    key = WatchTestEnvironmentKey("/ws/p", "P", UInt64(1))
    put!(df.in_channel, ReconcileMsg(Set{DJPKey}([key])))
    put!(df.in_channel, ReconcileMsg(Set{DJPKey}([key])))   # changes nothing
    put!(df.in_channel, ProcessIndexedMsg(key, "/tmp/x"))
    put!(df.in_channel, ShutdownMsg())
    run(df)   # drive the reactor loop to completion on this task

    # One snapshot per observable change: launch, completion, shutdown (the
    # child is killed, flipping `alive`). The duplicate reconcile delivers none.
    @test length(snapshots) == 3
    @test only(snapshots[1].items).status === :running
    @test only(snapshots[2].items).status === :done
    @test only(snapshots[2].items).alive
    @test only(snapshots[3].items).status === :done
    @test !only(snapshots[3].items).alive
    @test snapshots[3].pending_count == 0
end

@testitem "Dynamic status: a throwing status callback does not stop the reactor" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ShutdownMsg,
        WatchTestEnvironmentKey, DJPKey

    calls = Ref(0)
    df = DynamicFeature(DynamicPersistent, mktempdir();
        launcher=(df, djp) -> nothing,
        status_callback=snap -> (calls[] += 1; error("consumer bug")))

    key = WatchTestEnvironmentKey("/ws/p", "P", UInt64(1))
    put!(df.in_channel, ReconcileMsg(Set{DJPKey}([key])))
    put!(df.in_channel, ShutdownMsg())
    run(df)   # must reach the ShutdownMsg despite the callback throwing

    @test calls[] >= 1
end
