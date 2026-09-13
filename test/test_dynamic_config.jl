# Runtime config setters (no child processes): the reactor-side semantics of
# SetMaxConcurrentDjpsMsg / SetSymbolcacheMsg / SetMaxFailureAttemptsMsg /
# SetDjpRequestTimeoutMsg, and the workspace-level setters built on them plus
# set_resolve_workspace_environments!. Mode *transitions* are covered by
# test_dynamic_modeswitch.jl.

@testitem "Dynamic config: raising the concurrency cap launches queued keys" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        SetMaxConcurrentDjpsMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=2, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))
    @test length(launches) == 2
    @test length(df.launch_queue) == 3

    handle!(df, SetMaxConcurrentDjpsMsg(4))
    @test df.max_concurrent_djps[] == 4
    @test length(launches) == 4
    @test length(df.launch_queue) == 1

    # <= 0 means unlimited, like the constructor kwarg.
    handle!(df, SetMaxConcurrentDjpsMsg(0))
    @test length(launches) == 5
    @test isempty(df.launch_queue)
end

@testitem "Dynamic config: lowering the concurrency cap gates future launches only" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        SetMaxConcurrentDjpsMsg, ProcessIndexedMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=3, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))
    @test length(launches) == 3

    # Nothing is killed; the live count transiently exceeds the lowered cap.
    handle!(df, SetMaxConcurrentDjpsMsg(1))
    @test length(df.launching) == 3
    @test length(launches) == 3

    # Completions do not refill until the count is below the new cap.
    handle!(df, ProcessIndexedMsg(launches[1], "/tmp/x"))
    handle!(df, ProcessIndexedMsg(launches[2], "/tmp/x"))
    @test length(launches) == 3            # still 1 launching, cap is 1
    handle!(df, ProcessIndexedMsg(launches[3], "/tmp/x"))
    @test length(launches) == 4            # a slot opened, one queued key goes
end

@testitem "Dynamic config: setting the same concurrency cap is a no-op" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        SetMaxConcurrentDjpsMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))
    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:2]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))
    @test length(launches) == 1 && length(df.launch_queue) == 1

    handle!(df, SetMaxConcurrentDjpsMsg(1))
    @test df.max_concurrent_djps[] == 1
    @test length(launches) == 1
    @test length(df.launch_queue) == 1
end

@testitem "Dynamic config: enabling downloads re-preps done watch-env keys only" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, SetSymbolcacheMsg, ReconcileMsg,
        EnvironmentPrepDoneMsg, WatchTestEnvironmentMsg, StandaloneProjectPrepDoneMsg,
        WatchEnvironmentKey, WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicOff, mktempdir(); launcher=(df, djp) -> push!(launches, djp.key))

    # Park one key of each kind in `done` the way Off mode does, plus a
    # terminal failure.
    wkey = WatchEnvironmentKey("/ws/W", UInt64(1))
    push!(df.inflight, wkey)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, EnvironmentPrepDoneMsg(wkey, true))
    tkey = WatchTestEnvironmentKey("/ws/T", "T", UInt64(2))
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, WatchTestEnvironmentMsg(tkey))
    skey = CreateStandaloneProjectKey("/ws/S", UInt64(3))
    push!(df.inflight, skey)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, StandaloneProjectPrepDoneMsg(skey, false))
    fkey = WatchTestEnvironmentKey("/ws/F", "F", UInt64(4))
    push!(df.failed_projects, fkey)
    @test wkey in df.done && tkey in df.done && skey in df.done
    while isready(df.out_channel); take!(df.out_channel); end

    handle!(df, SetSymbolcacheMsg(true, nothing))
    @test df.download_enabled[]
    # Only the watch-env key re-preps: its prep is the one place downloads
    # happen. Failures stay barred.
    @test !(wkey in df.done)
    @test tkey in df.done && skey in df.done
    @test fkey in df.failed_projects

    # A reconcile with the unchanged required set re-dispatches exactly the
    # watch-env key (async prep; no synchronous launch).
    handle!(df, ReconcileMsg(Set{DJPKey}([wkey, tkey, skey])))
    @test wkey in df.inflight
    @test !(tkey in df.inflight) && !(skey in df.inflight)
    @test isempty(launches)
end

@testitem "Dynamic config: an upstream change re-preps while downloads are on, not while off" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, SetSymbolcacheMsg,
        EnvironmentPrepDoneMsg, WatchEnvironmentKey, handle!

    park!(df, wkey) = begin
        push!(df.inflight, wkey)
        Threads.atomic_add!(df.pending_count, 1)
        handle!(df, EnvironmentPrepDoneMsg(wkey, true))
        take!(df.out_channel)
    end

    df_on = DynamicFeature(DynamicOff, mktempdir(); download_enabled=true,
        launcher=(df, djp) -> nothing)
    w1 = WatchEnvironmentKey("/ws/W", UInt64(1))
    park!(df_on, w1)
    handle!(df_on, SetSymbolcacheMsg(nothing, "https://other.example"))
    @test df_on.upstream_url[] == "https://other.example"
    @test !(w1 in df_on.done)

    df_off = DynamicFeature(DynamicOff, mktempdir(); launcher=(df, djp) -> nothing)
    w2 = WatchEnvironmentKey("/ws/W", UInt64(2))
    park!(df_off, w2)
    handle!(df_off, SetSymbolcacheMsg(nothing, "https://other.example"))
    @test df_off.upstream_url[] == "https://other.example"
    @test w2 in df_off.done                     # downloads not effective: no re-prep
end

@testitem "Dynamic config: disabling downloads and unchanged symbolcache values change nothing" begin
    using JuliaWorkspaces: DynamicFeature, DynamicOff, SetSymbolcacheMsg,
        EnvironmentPrepDoneMsg, WatchEnvironmentKey, handle!

    df = DynamicFeature(DynamicOff, mktempdir(); download_enabled=true,
        launcher=(df, djp) -> nothing)
    wkey = WatchEnvironmentKey("/ws/W", UInt64(1))
    push!(df.inflight, wkey)
    Threads.atomic_add!(df.pending_count, 1)
    handle!(df, EnvironmentPrepDoneMsg(wkey, true))
    take!(df.out_channel)

    handle!(df, SetSymbolcacheMsg(false, nothing))
    @test !df.download_enabled[]
    @test wkey in df.done                       # only future preps are affected

    upstream_before = df.upstream_url[]
    handle!(df, SetSymbolcacheMsg(false, nothing))   # unchanged: early return
    @test !df.download_enabled[]
    @test df.upstream_url[] == upstream_before
    @test wkey in df.done
end

@testitem "Dynamic config: lowering the failure budget exhausts an identity immediately" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        ProcessIndexFailedMsg, SetMaxFailureAttemptsMsg, WatchTestEnvironmentKey,
        DJPKey, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=3, launcher=(df, djp) -> push!(launches, djp.key))

    k1, k2, k3 = (WatchTestEnvironmentKey("/ws/R", "R", UInt64(i)) for i in 1:3)
    for k in (k1, k2)
        handle!(df, ReconcileMsg(Set{DJPKey}([k])))
        handle!(df, ProcessIndexFailedMsg(k, ErrorException("unsatisfiable")))
        take!(df.out_channel)
    end
    @test length(launches) == 2

    # Two attempts recorded; a budget of 2 exhausts the identity right away.
    handle!(df, SetMaxFailureAttemptsMsg(2))
    @test df.max_failure_attempts[] == 2
    handle!(df, ReconcileMsg(Set{DJPKey}([k3])))
    @test length(launches) == 2
    result = take!(df.out_channel)
    @test result isa FailedResult
    @test result.key == k3
    @test occursin("unsatisfiable", result.message)
    @test df.pending_count[] == 0
end

@testitem "Dynamic config: raising the failure budget un-exhausts an identity" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        ProcessIndexFailedMsg, SetMaxFailureAttemptsMsg, WatchTestEnvironmentKey,
        DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=1, launcher=(df, djp) -> push!(launches, djp.key))

    k1, k2, k3 = (WatchTestEnvironmentKey("/ws/R", "R", UInt64(i)) for i in 1:3)
    handle!(df, ReconcileMsg(Set{DJPKey}([k1])))
    handle!(df, ProcessIndexFailedMsg(k1, ErrorException("unsatisfiable")))
    take!(df.out_channel)

    # Budget spent: the second hash short-circuits without a launch.
    handle!(df, ReconcileMsg(Set{DJPKey}([k2])))
    @test length(launches) == 1
    take!(df.out_channel)

    handle!(df, SetMaxFailureAttemptsMsg(3))
    handle!(df, ReconcileMsg(Set{DJPKey}([k3])))
    @test length(launches) == 2                # un-exhausted: launched again
    # The exact failed key stays barred regardless of the budget.
    handle!(df, ReconcileMsg(Set{DJPKey}([k1])))
    @test length(launches) == 2
end

@testitem "Dynamic config: the request timeout is a live Ref" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, SetDjpRequestTimeoutMsg, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    handle!(df, SetDjpRequestTimeoutMsg(7))
    @test df.djp_request_timeout_seconds[] == 7
    handle!(df, SetDjpRequestTimeoutMsg(7))    # same value: early return
    @test df.djp_request_timeout_seconds[] == 7
    # The per-request read sites (`ProcessLaunchedMsg`'s index calls) forward
    # the Ref's value into `_send_djp_request`, whose deadline mechanics are
    # covered by "an index request is bounded by its deadline" in
    # test_dynamic_failures.jl.
end

@testitem "Dynamic config: set_resolve_workspace_environments! re-dispatches fabricated keys" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_required_dynamic_projects, input_resolve_workspace_environments,
        input_failed_dynamic_keys, set_input_failed_dynamic_keys!,
        WatchEnvironmentKey, WatchTestEnvironmentKey, DJPKey
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
    files = [
        TextFile(URI("file:///ws/Proj/Project.toml"), SourceText(project_toml, "toml")),
        TextFile(URI("file:///ws/Proj/Manifest.toml"), SourceText(manifest_toml, "toml")),
        TextFile(URI("file:///ws/Proj/src/P.jl"), SourceText("module P end", "julia")),
        TextFile(URI("file:///ws/Bare/Project.toml"), SourceText(replace(project_toml, "\"P\"" => "\"Bare\"", "1111\"" => "2222\""), "toml")),
        TextFile(URI("file:///ws/Bare/src/Bare.jl"), SourceText("module Bare end", "julia")),
        TextFile(URI("file:///ws/Bare/test/runtests.jl"), SourceText("using Test", "julia")),
    ]

    jw = JuliaWorkspace(resolve_workspace_environments=false, launcher=(df, djp) -> nothing)
    foreach(f -> add_file!(jw, f), files)
    @test all(k -> k isa WatchEnvironmentKey, derived_required_dynamic_projects(jw.runtime))

    # Unchanged-value call is a no-op that must not touch anything.
    k = WatchTestEnvironmentKey("/ws/X", "X", UInt64(1))
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([k]))
    set_resolve_workspace_environments!(jw, false)
    @test input_failed_dynamic_keys(jw.runtime) == Set{DJPKey}([k])
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}())

    set_resolve_workspace_environments!(jw, true)
    @test input_resolve_workspace_environments(jw.runtime)
    # The fabricated work never settles (fake launcher), so readiness stays
    # deterministically un-settled — a stale-readiness regression would show
    # as `true` here.
    @test !is_ready(jw)
    @test any(k -> !(k isa WatchEnvironmentKey), derived_required_dynamic_projects(jw.runtime))

    set_resolve_workspace_environments!(jw, false)
    @test all(k -> k isa WatchEnvironmentKey, derived_required_dynamic_projects(jw.runtime))
end

@testitem "Dynamic config: enabling resolution with nothing to fabricate still settles readiness" begin
    using JuliaWorkspaces

    jw = JuliaWorkspace(resolve_workspace_environments=false, launcher=(df, djp) -> nothing)
    wait_until_ready(jw)
    @test is_ready(jw)

    # The required set does not change (nothing to fabricate); the forced
    # reconcile must re-settle readiness rather than leave it un-settled.
    set_resolve_workspace_environments!(jw, true)
    wait_until_ready(jw)
    @test is_ready(jw)
end

@testitem "Dynamic config: set_symbolcache! updates the inputs and re-preps the open workspace" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: input_symbolcache_download, input_symbolcache_upstream

    # A real project folder with a manifest whose package caches are missing
    # (fresh store): under Off it settles best-effort; enabling downloads must
    # re-prep it, un-settling readiness until the (failing, offline) download
    # attempt settles it best-effort again.
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
    @test !input_symbolcache_download(jw.runtime)

    # The unreachable upstream keeps the test offline: the download attempt
    # fails, the env re-settles best-effort under Off.
    set_symbolcache!(jw, download=true, upstream="http://127.0.0.1:1")
    @test !is_ready(jw)
    @test input_symbolcache_download(jw.runtime)
    @test input_symbolcache_upstream(jw.runtime) == "http://127.0.0.1:1"

    set_symbolcache!(jw, download=true, upstream="http://127.0.0.1:1")   # no-op
    wait_until_ready(jw)
    @test is_ready(jw)
end

@testitem "Dynamic config: workspace_from_folders forwards resolve_workspace_environments" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: input_resolve_workspace_environments

    jw = workspace_from_folders([mktempdir()]; resolve_workspace_environments=false,
        launcher=(df, djp) -> nothing)
    @test !input_resolve_workspace_environments(jw.runtime)
end
