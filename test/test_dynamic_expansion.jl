# Reactor-level tests for macro expansion batches (no child processes): the
# settle-as-unavailable paths, the queue-until-Done behavior, and reconcile
# pruning. The live request path is covered by the end-to-end fixture test.

@testitem "Dynamic expansion: non-persistent mode settles entries as failed" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ExpansionBatchMsg,
        MacroExpansionsResult, WatchEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    df = DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> nothing)
    key = WatchEnvironmentKey("/ws/p1", UInt64(1))
    ek = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))

    handle!(df, ExpansionBatchMsg(key, "c1", String[], String[], ExpansionEntry[(key=ek, text="@m x")]))

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

    handle!(df, ExpansionBatchMsg(key, "c1", String[], String[], ExpansionEntry[(key=ek, text="@m x")]))

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
    handle!(df, ExpansionBatchMsg(key, "c1", String[], String[], ExpansionEntry[(key=ek1, text="@m x")]))
    handle!(df, ExpansionBatchMsg(key, "c1", String[], String[], ExpansionEntry[(key=ek2, text="@m y")]))
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

@testitem "Dynamic expansion: a test-environment key is revived for an expansion batch" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ExpansionBatchMsg, ReconcileMsg,
        ProcessIndexedMsg, TestEnvironmentReadyResult, MacroExpansionsResult,
        WatchTestEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))
    k = WatchTestEnvironmentKey("/ws/P", "P", UInt64(1))
    dir = "/scratch/test-env-P"

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    handle!(df, ProcessIndexedMsg(k, dir))
    ready = take!(df.out_channel)
    @test ready isa TestEnvironmentReadyResult
    @test ready.package == "P"
    @test length(launches) == 1
    @test k in df.done && haskey(df.procs, k)

    # The child is gone (evicted by the cap, say): the first batch for the
    # key relaunches it through the refresh path — the same revival a
    # cache-hit environment gets.
    delete!(df.procs, k)
    ek = ExpansionKey((UInt64(1), UInt64(2), UInt64(3)))
    handle!(df, ExpansionBatchMsg(k, "c1", ["using Test", "using P"], String[], ExpansionEntry[(key=ek, text="@safetestset \"x\" begin end")]))
    @test length(launches) == 2
    @test k in df.refreshing
    @test length(df.expansion_queue[k]) == 1
    @test !isready(df.out_channel)

    # The revived child re-materializes the test env: the ready result is
    # re-emitted (idempotent for the host), the batch stays queued for the
    # child to settle (the fake child never reaches Done), nothing failed.
    handle!(df, ProcessIndexedMsg(k, dir))
    again = take!(df.out_channel)
    @test again isa TestEnvironmentReadyResult
    @test again.test_project_uri == ready.test_project_uri
    @test !(k in df.refreshing)
    @test length(df.expansion_queue[k]) == 1
    @test !isready(df.out_channel)
end

@testitem "Dynamic expansion: the live-children cap evicts LRU idle children and eviction re-arms revival" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ExpansionBatchMsg, ReconcileMsg,
        ProcessIndexedMsg, ExpansionBatchFailedMsg, SetMaxAliveDjpsMsg, MacroExpansionsResult,
        WatchTestEnvironmentKey, DJPKey, ExpansionKey, ExpansionEntry, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir(); max_alive_djps=1,
        launcher=(df, djp) -> push!(launches, djp.key))
    # Test-env keys: their work message launches synchronously (a watch-env
    # key's goes through an async prep first, which these handler-level tests
    # do not run); the cap itself is kind-agnostic.
    a = WatchTestEnvironmentKey("/ws/a", "A", UInt64(1))
    b = WatchTestEnvironmentKey("/ws/b", "B", UInt64(2))
    batch(key, mac) = ExpansionBatchMsg(key, "c1", String[], String[], ExpansionEntry[(key=ExpansionKey((UInt64(1), UInt64(2), mac)), text="@m x")])
    drain_out!(df) = (while isready(df.out_channel); take!(df.out_channel); end)

    handle!(df, ReconcileMsg(Set{DJPKey}([a, b])))
    @test length(launches) == 2
    # Both children are launching: neither is idle, nothing to evict.
    @test haskey(df.procs, a) && haskey(df.procs, b)

    # `a` settles while `b` still works: one idle child is within a cap of
    # one — working children are never counted against it.
    handle!(df, ProcessIndexedMsg(a, "/ws/a"))
    @test haskey(df.procs, a) && haskey(df.procs, b)
    # `b` settles too: two idle children exceed the cap, the least recently
    # active (`a`) is evicted, its item stays done.
    handle!(df, ProcessIndexedMsg(b, "/ws/b"))
    @test !haskey(df.procs, a)
    @test a in df.done
    @test haskey(df.procs, b)
    drain_out!(df)

    # A batch for the evicted `a` revives it (the eviction cleared the
    # once-only guard); the launch itself evicts nothing.
    handle!(df, batch(a, UInt64(3)))
    @test length(launches) == 3 && launches[end] == a
    @test a in df.refreshing && haskey(df.procs, a)
    @test haskey(df.procs, b)
    @test !isready(df.out_channel)   # nothing settled as failed
    # The revived child settles; its batch is still queued (the fake child
    # never reaches Done), so it is not idle and `b` alone is within the cap.
    handle!(df, ProcessIndexedMsg(a, "/ws/a"))
    drain_out!(df)
    @test haskey(df.procs, a) && haskey(df.procs, b)

    # Raising the cap (here: lifting it) relaunches nothing; lowering it
    # evicts the least recently used idle child first.
    handle!(df, SetMaxAliveDjpsMsg(0))
    @test df.max_alive_djps[] == 0
    # (Stand in for the child having served `a`'s batch.)
    empty!(df.expansion_queue[a])
    df.procs[a].last_active = 1.0
    df.procs[b].last_active = 2.0
    handle!(df, SetMaxAliveDjpsMsg(1))
    @test !haskey(df.procs, a) && haskey(df.procs, b)
    @test a in df.done
    @test !(a in df.expansion_revive_attempted)

    # A later reconcile with the same required set does not re-spawn an
    # evicted key: its work is done.
    n = length(launches)
    handle!(df, ReconcileMsg(Set{DJPKey}([a, b])))
    @test length(launches) == n

    # Contrast: a child lost to a failed batch (crash path) keeps the guard —
    # its next batch settles `:failed` instead of relaunching a doomed child.
    handle!(df, batch(b, UInt64(5)))
    @test haskey(df.procs, b)
    push!(df.expansion_revive_attempted, b)   # as `_drain_expansion_queue!` records once it revived
    handle!(df, ExpansionBatchFailedMsg(b, ExpansionKey[ExpansionKey((UInt64(1), UInt64(2), UInt64(5)))], ErrorException("boom")))
    drain_out!(df)
    @test !haskey(df.procs, b)
    handle!(df, batch(b, UInt64(6)))
    msg = take!(df.out_channel)
    @test msg isa MacroExpansionsResult && msg.entries[1].status === :failed
    @test length(launches) == n
end

@testitem "Dynamic expansion: a resolved non-package environment's child is torn down after indexing" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ProcessIndexedMsg, ResolvedEnvironmentReadyResult, StandaloneProjectReadyResult,
        ResolveEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))
    env = ResolveEnvironmentKey("/ws/P/docs", UInt64(1))
    standalone = CreateStandaloneProjectKey("/ws/Q", UInt64(2))
    for key in (env, standalone)
        Threads.atomic_add!(df.pending_count, 1)
        push!(df.inflight, key)
        handle!(df, StandaloneProjectPrepDoneMsg(key, false))   # no usable dir: launch
    end
    @test length(launches) == 2

    # Nothing routes an expansion to a resolved env's child: it is killed once
    # its scratch project is indexed, even under DynamicPersistent, and its
    # item stays done.
    handle!(df, ProcessIndexedMsg(env, "/scratch/env-docs"))
    @test take!(df.out_channel) isa ResolvedEnvironmentReadyResult
    @test !haskey(df.procs, env)
    @test env in df.done
    # A standalone project's child serves its package's files: kept.
    handle!(df, ProcessIndexedMsg(standalone, "/scratch/Q"))
    @test take!(df.out_channel) isa StandaloneProjectReadyResult
    @test haskey(df.procs, standalone)
end

# The live end-to-end slice: real child process, real indexing, real
# macroexpand. Spawns a Julia child and takes ~30s warm, so it only runs when
# explicitly requested via JW_E2E_DYNAMIC=1.
@testitem "Dynamic expansion: end-to-end through a live env child" skip=(get(ENV, "JW_E2E_DYNAMIC", "") == "") begin
    using JuliaWorkspaces, Pkg
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, DynamicPersistent
    using JuliaWorkspaces.URIs2: filepath2uri

    fixdir = joinpath(mktempdir(), "MacroFix")
    mkpath(joinpath(fixdir, "src"))
    write(joinpath(fixdir, "Project.toml"),
        "name = \"MacroFix\"\nuuid = \"b1f7ee10-72c9-4c39-9e29-e6a2ba0b3e51\"\nversion = \"0.1.0\"\n")
    write(joinpath(fixdir, "src", "MacroFix.jl"), """
    module MacroFix
    export @double
    macro double(x)
        return :(2 * \$(esc(x)))
    end
    include("use.jl")
    end
    """)
    write(joinpath(fixdir, "src", "use.jl"), """
    function usedouble(x)
        y = @double x
        return y
    end
    """)
    old = Base.active_project()
    Pkg.activate(fixdir, io=devnull); Pkg.instantiate(io=devnull); Pkg.activate(old, io=devnull)

    jw = JuliaWorkspace(dynamic=DynamicPersistent, store_path=mktempdir())
    for f in ["Project.toml", "Manifest.toml"]
        add_file!(jw, TextFile(filepath2uri(joinpath(fixdir, f)),
            SourceText(read(joinpath(fixdir, f), String), "toml")))
    end
    for f in [joinpath(fixdir, "src", "MacroFix.jl"), joinpath(fixdir, "src", "use.jl")]
        add_file!(jw, TextFile(filepath2uri(f), SourceText(read(f, String), "julia")))
    end
    JW.set_v2_enabled!(jw, true)
    JW.set_macro_expansion!(jw, true)
    @test length(JW.derived_required_macro_expansions(jw.runtime)) == 1

    # Wait for the batch to settle (env child revived on demand, indexes from
    # caches, then expands).
    t0 = time()
    while time() - t0 < 300
        JW.process_from_dynamic(jw)
        isempty(JW.input_macro_expansions(jw.runtime)) || break
        sleep(2)
    end
    exps = collect(values(JW.input_macro_expansions(jw.runtime)))
    @test length(exps) == 1
    @test exps[1].status === :ok
    @test occursin("2", exps[1].text) && occursin("x", exps[1].text)

    # The expansion reaches lowering: `*` is a read at address 0 (macro-
    # generated, rule-exempt side), the user bindings keep their addresses.
    use_uri = filepath2uri(joinpath(fixdir, "src", "use.jl"))
    inv = JW.derived_v2_file_inventory(jw.runtime, use_uri)
    ref = JW.V2ItemRef(use_uri, inv.items[1].id)
    low = JW.derived_item_lowering(jw.runtime, ref)
    @test low.status === :ok
    by_name = Dict(b.name => b for b in low.bindings)
    @test haskey(by_name, "*") && by_name["*"].addr == 0 && by_name["*"].is_read
    @test by_name["x"].is_read
    @test by_name["y"].addr != 0

    jw.dynamic_feature === nothing || put!(jw.dynamic_feature.in_channel, JW.ShutdownMsg())
end
