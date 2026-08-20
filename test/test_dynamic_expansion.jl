# Reactor-level tests for macro expansion batches (no child processes): the
# settle-as-unavailable paths, the queue-until-Done behavior, and reconcile
# pruning. The live request path is covered by the end-to-end fixture test.

@testitem "Dynamic expansion: non-persistent mode settles entries as failed" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ExpansionBatchMsg,
        MacroExpansionsResult, WatchEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    df = DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> nothing)
    key = WatchEnvironmentKey("/ws/p1", UInt64(1))
    ek = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))

    handle!(df, ExpansionBatchMsg(key, "c1", String[], ExpansionEntry[(key=ek, text="@m x")]))

    msg = take!(df.out_channel)
    @test msg isa MacroExpansionsResult
    @test length(msg.entries) == 1
    @test msg.entries[1].key == ek
    @test msg.entries[1].status === :failed
    @test isempty(df.expansion_queue)
end

@testitem "Dynamic expansion: no child forthcoming settles entries as failed" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ExpansionBatchMsg,
        MacroExpansionsResult, WatchEnvironmentKey, ExpansionKey, ExpansionEntry, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    key = WatchEnvironmentKey("/ws/p1", UInt64(1))   # never required, never launched
    ek = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))

    handle!(df, ExpansionBatchMsg(key, "c1", String[], ExpansionEntry[(key=ek, text="@m x")]))

    msg = take!(df.out_channel)
    @test msg isa MacroExpansionsResult
    @test msg.entries[1].status === :failed
end

@testitem "Dynamic expansion: batches queue until the child settles; reconcile prunes" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, DynamicJuliaProcess,
        ExpansionBatchMsg, MacroExpansionsResult, ReconcileMsg,
        WatchEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    key = WatchEnvironmentKey("/ws/p1", UInt64(1))

    # A child exists but is not settled yet (Created): the batch must queue,
    # not send (sending needs an endpoint) and not settle.
    df.procs[key] = DynamicJuliaProcess(key, "/ws/p1", nothing, :watch_environment)
    ek1 = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))
    ek2 = ExpansionKey((UInt64(1), UInt64(2), UInt64(4)))
    handle!(df, ExpansionBatchMsg(key, "c1", String[], ExpansionEntry[(key=ek1, text="@m x")]))
    handle!(df, ExpansionBatchMsg(key, "c1", String[], ExpansionEntry[(key=ek2, text="@m y")]))
    @test length(df.expansion_queue[key]) == 2
    @test !isready(df.out_channel)

    # The env leaves the required set: the child is killed and every queued
    # entry settles as failed.
    handle!(df, ReconcileMsg(Set{DJPKey}()))
    @test !haskey(df.expansion_queue, key)
    settled = Set{ExpansionKey}()
    while isready(df.out_channel)
        msg = take!(df.out_channel)
        msg isa MacroExpansionsResult || continue
        for e in msg.entries
            @test e.status === :failed
            push!(settled, e.key)
        end
    end
    @test settled == Set([ek1, ek2])
end

@testitem "Dynamic expansion: the process FSM allows Done → Indexing round trips" begin
    using JuliaWorkspaces: dynamic_process_fsm, transition!, state,
        DynamicProcessStarting, DynamicProcessConnected, DynamicProcessIndexing, DynamicProcessDone

    fsm = dynamic_process_fsm("test")
    transition!(fsm, DynamicProcessStarting)
    transition!(fsm, DynamicProcessConnected)
    transition!(fsm, DynamicProcessIndexing)
    transition!(fsm, DynamicProcessDone)
    # A settled persistent child serves an expansion batch and settles again.
    transition!(fsm, DynamicProcessIndexing)
    transition!(fsm, DynamicProcessDone)
    @test state(fsm) == DynamicProcessDone
end
