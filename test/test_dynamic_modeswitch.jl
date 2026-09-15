# Reactor-level tests for runtime dynamic-mode switches (`SetDynamicModeMsg`,
# no child processes), plus workspace-level tests for `set_dynamic_mode!`. The
# per-mode steady-state behavior is covered by test_dynamic_reconcile.jl; these
# cover the transitions.

@testitem "Dynamic mode switch: on -> off kills children and settles outstanding work" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, DynamicOff, SetDynamicModeMsg,
        ReconcileMsg, WatchEnvironmentKey, WatchTestEnvironmentKey, DJPKey,
        EnvironmentReadyResult, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))

    wkey = WatchEnvironmentKey("/ws/W", UInt64(1))
    tkey = WatchTestEnvironmentKey("/ws/T", "T", UInt64(2))

    # The test-env key launches synchronously; the watch-env key stays in its
    # async prep window (inflight, no process yet).
    handle!(df, ReconcileMsg(Set{DJPKey}([wkey, tkey])))
    @test launches == [tkey]
    @test haskey(df.procs, tkey)
    @test wkey in df.inflight && tkey in df.inflight
    @test df.pending_count[] == 2

    handle!(df, SetDynamicModeMsg(DynamicOff))
    @test df.djp_mode[] == DynamicOff
    @test isempty(df.procs)
    @test isempty(df.launching)
    @test isempty(df.inflight)
    @test df.pending_count[] == 0
    @test wkey in df.done && tkey in df.done
    @test df.saw_result[]

    # The synthesized terminal outcomes: the environment settles best-effort
    # ready, the test env (which needs a child) settles as skipped.
    results = []
    while isready(df.out_channel)
        push!(results, take!(df.out_channel))
    end
    @test count(r -> r isa EnvironmentReadyResult && r.project_path == "/ws/W", results) == 1
    @test count(r -> r isa FailedResult && r.key == tkey && r.message == "", results) == 1
    @test length(results) == 2
end

@testitem "Dynamic mode switch: off -> on forgets parked keys so they re-dispatch" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, DynamicIndexingOnly, SetDynamicModeMsg,
        ReconcileMsg, WatchTestEnvironmentMsg, StandaloneProjectPrepDoneMsg,
        WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, _djp_identity, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicOff, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))

    # Park a test-env key and a standalone key the way Off mode does (terminal
    # skip, remembered in `done`), plus some accumulated failure bookkeeping.
    tkey = WatchTestEnvironmentKey("/ws/T", "T", UInt64(1))
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, WatchTestEnvironmentMsg(tkey))
    skey = CreateStandaloneProjectKey("/ws/S", UInt64(2))
    push!(df.inflight, skey)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, StandaloneProjectPrepDoneMsg(skey, false))
    @test tkey in df.done && skey in df.done
    push!(df.failed_projects, tkey)
    df.failure_attempts[_djp_identity(tkey)] = 1
    while isready(df.out_channel); take!(df.out_channel); end

    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    @test df.djp_mode[] == DynamicIndexingOnly
    @test isempty(df.done)
    @test isempty(df.failed_projects)
    @test isempty(df.failure_attempts)
    @test isempty(df.failure_messages)

    # A reconcile with the same required set now launches a child for the
    # test-env key (the standalone key re-enters its async prep instead).
    handle!(df, ReconcileMsg(Set{DJPKey}([tkey, skey])))
    @test launches == [tkey]
    @test tkey in df.inflight && skey in df.inflight
end

@testitem "Dynamic mode switch: persistent -> indexing-only kills settled children and fails queued batches" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, DynamicIndexingOnly, SetDynamicModeMsg,
        ReconcileMsg, ProcessIndexedMsg, ExpansionBatchMsg, MacroExpansionsResult,
        TestEnvironmentReadyResult, WatchTestEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    k = WatchTestEnvironmentKey("/ws/P", "P", UInt64(1))

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    handle!(df, ProcessIndexedMsg(k, "/scratch/test-env-P"))
    @test take!(df.out_channel) isa TestEnvironmentReadyResult
    @test k in df.done && haskey(df.procs, k)   # settled child stays under Persistent

    # A batch queues on the settled child (the fake child never reaches Done).
    ek = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))
    handle!(df, ExpansionBatchMsg(k, "c1", String[], String[], ExpansionEntry[(key=ek, text="@m x")]))
    @test length(df.expansion_queue[k]) == 1

    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    @test !haskey(df.procs, k)                  # settled child killed
    @test k in df.done                          # completion is kept
    @test isempty(df.expansion_queue)
    msg = take!(df.out_channel)
    @test msg isa MacroExpansionsResult
    @test msg.entries[1].key == ek
    @test msg.entries[1].status === :failed
end

@testitem "Dynamic mode switch: persistent -> indexing-only keeps an in-flight child until it settles" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, DynamicIndexingOnly, SetDynamicModeMsg,
        ReconcileMsg, ProcessIndexedMsg, WatchTestEnvironmentKey, DJPKey, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    k = WatchTestEnvironmentKey("/ws/P", "P", UInt64(1))

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    @test haskey(df.procs, k) && k in df.inflight

    # Still indexing: the switch must not kill it.
    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    @test haskey(df.procs, k)

    # It settles under the new mode's rules: torn down after indexing.
    handle!(df, ProcessIndexedMsg(k, "/scratch/test-env-P"))
    @test !haskey(df.procs, k)
    @test k in df.done
    @test df.pending_count[] == 0
end

@testitem "Dynamic mode switch: indexing-only -> persistent keeps children that settle after the flip" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, DynamicPersistent, SetDynamicModeMsg,
        ReconcileMsg, ProcessIndexedMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))
    k = WatchTestEnvironmentKey("/ws/P", "P", UInt64(1))

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    @test launches == [k]

    handle!(df, SetDynamicModeMsg(DynamicPersistent))
    @test launches == [k]                       # no kills, no re-dispatch

    handle!(df, ProcessIndexedMsg(k, "/scratch/test-env-P"))
    @test haskey(df.procs, k)                   # stays alive under Persistent
    @test k in df.done
end

@testitem "Dynamic mode switch: setting the same mode is a no-op" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, SetDynamicModeMsg,
        ReconcileMsg, ProcessIndexedMsg, TestEnvironmentReadyResult, WatchTestEnvironmentKey, DJPKey, handle!

    df = DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> nothing)
    k = WatchTestEnvironmentKey("/ws/P", "P", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    handle!(df, ProcessIndexedMsg(k, "/scratch/test-env-P"))
    @test take!(df.out_channel) isa TestEnvironmentReadyResult
    @test k in df.done

    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    @test df.djp_mode[] == DynamicIndexingOnly
    @test k in df.done
    @test !isready(df.out_channel)
end

@testitem "Dynamic mode switch: a key in its prep window launches under the mode at prep-done time" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, DynamicIndexingOnly, SetDynamicModeMsg,
        EnvironmentPrepDoneMsg, WatchEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicOff, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))

    # A watch-env key caught in its async prep window while the mode is Off
    # (prep runs even under Off).
    wkey = WatchEnvironmentKey("/ws/W", UInt64(1))
    push!(df.inflight, wkey)
    Threads.atomic_add!(df.pending_count, 1)

    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    # Its prep completing with packages still missing now launches an indexer
    # instead of settling best-effort.
    handle!(df, EnvironmentPrepDoneMsg(wkey, true))
    @test launches == [wkey]
    @test haskey(df.procs, wkey)
end

@testitem "Dynamic mode switch: the off-with-download reactor upgrades to launching children" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, DynamicIndexingOnly, SetDynamicModeMsg,
        ReconcileMsg, WatchTestEnvironmentKey, DJPKey, handle!

    # `symbolcache_download=true` + `DynamicOff` used to be the only
    # configuration with a live reactor in Off mode; it must upgrade like any
    # other.
    launches = DJPKey[]
    df = DynamicFeature(DynamicOff, mktempdir(); download_enabled=true,
        launcher=(df, djp) -> push!(launches, djp.key))

    tkey = WatchTestEnvironmentKey("/ws/T", "T", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([tkey])))
    @test isempty(launches)                     # Off: settled as skipped
    @test tkey in df.done

    handle!(df, SetDynamicModeMsg(DynamicIndexingOnly))
    handle!(df, ReconcileMsg(Set{DJPKey}([tkey])))
    @test launches == [tkey]
end

@testitem "Dynamic mode switch: set_dynamic_mode! updates the input and resets the off bookkeeping" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: input_dynamic_mode, input_failed_dynamic_keys, input_dynamic_failure_messages,
        set_input_failed_dynamic_keys!, set_input_dynamic_failure_messages!,
        WatchTestEnvironmentKey, DJPKey

    jw = JuliaWorkspace(dynamic=DynamicOff, store_path=mktempdir(), launcher=(df, djp) -> nothing)
    @test get_dynamic_mode(jw) == DynamicOff
    @test input_dynamic_mode(jw.runtime) == DynamicOff

    # Same mode: a no-op that must not touch the failure inputs.
    k = WatchTestEnvironmentKey("/ws/T", "T", UInt64(1))
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([k]))
    set_input_dynamic_failure_messages!(jw.runtime, Dict{DJPKey,String}(k => "boom"))
    set_dynamic_mode!(jw, DynamicOff)
    @test input_failed_dynamic_keys(jw.runtime) == Set{DJPKey}([k])

    # Off -> on clears the query-side failure record (mirroring the reactor's
    # wholesale reset) and switches the input.
    set_dynamic_mode!(jw, DynamicIndexingOnly)
    @test get_dynamic_mode(jw) == DynamicIndexingOnly
    @test isempty(input_failed_dynamic_keys(jw.runtime))
    @test isempty(input_dynamic_failure_messages(jw.runtime))

    # On -> off keeps failure records (only the off -> on direction resets).
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([k]))
    set_dynamic_mode!(jw, DynamicOff)
    @test get_dynamic_mode(jw) == DynamicOff
    @test input_failed_dynamic_keys(jw.runtime) == Set{DJPKey}([k])
end

@testitem "Dynamic mode switch: off -> on un-settles readiness until the re-dispatched work completes" begin
    using JuliaWorkspaces

    # A real project folder with a manifest, so the workspace requires a
    # watch-environment work item whose package caches are missing (fresh
    # store). Under Off it settles best-effort; after the switch it becomes
    # genuinely outstanding work again — and the fake launcher never
    # completes it, so a stale-readiness regression shows as `is_ready`
    # flipping back to `true`.
    proj = mktempdir()
    mkpath(joinpath(proj, "src"))
    write(joinpath(proj, "Project.toml"), """
    name = "Smoke"
    uuid = "11111111-2222-3333-4444-555555555555"
    version = "0.1.0"

    [deps]
    UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
    """)
    write(joinpath(proj, "Manifest.toml"), """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.Random]]
    deps = ["SHA"]
    uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
    version = "1.11.0"

    [[deps.SHA]]
    uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
    version = "0.7.0"

    [[deps.UUIDs]]
    deps = ["Random", "SHA"]
    uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
    version = "1.11.0"
    """)
    write(joinpath(proj, "src", "Smoke.jl"), "module Smoke\nusing UUIDs\nend\n")

    jw = workspace_from_folders([proj]; dynamic=DynamicOff, store_path=mktempdir(),
        launcher=(df, djp) -> nothing)
    wait_until_ready(jw)
    @test is_ready(jw)

    set_dynamic_mode!(jw, DynamicIndexingOnly)
    @test !is_ready(jw)
    @test get_dynamic_mode(jw) == DynamicIndexingOnly
end

@testitem "Dynamic mode switch: wait_until_ready settles on a fresh workspace under any mode" begin
    using JuliaWorkspaces

    # A fresh workspace has never reconciled, so `is_ready` is false; the
    # reactor now always runs, and `wait_until_ready` sends the first (empty)
    # reconcile itself, so this must return rather than block — including
    # under DynamicOff, which previously had no reactor at all.
    for mode in (DynamicOff, DynamicIndexingOnly)
        jw = JuliaWorkspace(dynamic=mode, store_path=mktempdir(), launcher=(df, djp) -> nothing)
        @test !is_ready(jw)
        wait_until_ready(jw)
        @test is_ready(jw)
    end
end
