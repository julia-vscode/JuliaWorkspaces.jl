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
