# Bounds on repeated dynamic work, and how a failure is reported.
#
# Two gates keep a deterministically-failing project (an unsatisfiable test
# environment, an unregistered dependency, a vendored fixture that cannot
# resolve) from costing a child process over and over: `failed_projects` (this
# exact key, never pruned by reconcile) and `failure_attempts` (this project,
# content-hash-independent, bounded by `max_failure_attempts`).

@testitem "Dynamic failures: a failed key is not re-spawned after leaving the required set" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, DJPKey, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        launcher=(df, djp) -> push!(launches, djp.key))

    k = WatchTestEnvironmentKey("/ws/R", "R", UInt64(1))

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    @test length(launches) == 1

    handle!(df, ProcessIndexFailedMsg(k, ErrorException("unsatisfiable")))
    @test isready(df.out_channel)
    result = take!(df.out_channel)
    @test result isa FailedResult
    @test result.key == k
    @test occursin("unsatisfiable", result.message)

    # Reconcile used to prune `failed_projects` to the required set, so a key
    # that dropped out and came back was launched again — indefinitely, for a
    # project whose content hash oscillates.
    handle!(df, ReconcileMsg(Set{DJPKey}()))
    handle!(df, ReconcileMsg(Set{DJPKey}([k])))

    @test length(launches) == 1
    @test k in df.failed_projects
    @test df.pending_count[] == 0
    @test isempty(df.inflight)
end

@testitem "Dynamic failures: the budget is per project, not per content hash" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, DJPKey, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=2, launcher=(df, djp) -> push!(launches, djp.key))

    # One project, three content hashes — what editing a broken Project.toml
    # produces: a fresh key per keystroke, none of them ever seen before.
    k1, k2, k3 = (WatchTestEnvironmentKey("/ws/R", "R", UInt64(i)) for i in 1:3)

    for k in (k1, k2)
        handle!(df, ReconcileMsg(Set{DJPKey}([k])))
        handle!(df, ProcessIndexFailedMsg(k, ErrorException("unsatisfiable")))
        @test isready(df.out_channel)
        result = take!(df.out_channel)
        @test result isa FailedResult
        @test result.key == k
    end
    @test length(launches) == 2

    # Budget spent: the third key is still dispatched — so readiness settles —
    # but no child is launched for it.
    handle!(df, ReconcileMsg(Set{DJPKey}([k3])))
    @test length(launches) == 2
    @test isready(df.out_channel)
    result = take!(df.out_channel)
    @test result isa FailedResult
    @test result.key == k3
    # The exhausted-skip short-circuit replays the identity's recorded cause
    # rather than a generic sentence.
    @test occursin("unsatisfiable", result.message)
    @test df.pending_count[] == 0
    @test isempty(df.inflight)
end

@testitem "Dynamic failures: max_failure_attempts <= 0 disables the bound" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=0, launcher=(df, djp) -> push!(launches, djp.key))

    for i in 1:3
        k = WatchTestEnvironmentKey("/ws/R", "R", UInt64(i))
        handle!(df, ReconcileMsg(Set{DJPKey}([k])))
        handle!(df, ProcessIndexFailedMsg(k, ErrorException("boom")))
        @test isready(df.out_channel)
        take!(df.out_channel)
    end

    @test length(launches) == 3
end

@testitem "Dynamic failures: a success restores the project's budget" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        ProcessIndexedMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=2, launcher=(df, djp) -> push!(launches, djp.key))

    k1, k2, k3 = (WatchTestEnvironmentKey("/ws/R", "R", UInt64(i)) for i in 1:3)

    handle!(df, ReconcileMsg(Set{DJPKey}([k1])))
    handle!(df, ProcessIndexFailedMsg(k1, ErrorException("transient")))
    @test isready(df.out_channel)
    take!(df.out_channel)
    @test df.failure_attempts[(kind=:watch_test_environment, path="/ws/R", package="R")] == 1

    # A transient failure (crashed child, flaky download) must not be held
    # against the project once it succeeds.
    handle!(df, ReconcileMsg(Set{DJPKey}([k2])))
    handle!(df, ProcessIndexedMsg(k2, "/tmp/testenv"))
    @test isempty(df.failure_attempts)

    handle!(df, ReconcileMsg(Set{DJPKey}([k3])))
    @test length(launches) == 3
end

@testitem "Dynamic failures: the budget is per kind and per package" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=1, launcher=(df, djp) -> push!(launches, djp.key))

    # A failed standalone project must not exhaust the test environment for the
    # same folder — they fail for different reasons, and one can succeed where
    # the other cannot.
    standalone = CreateStandaloneProjectKey("/ws/P", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([standalone])))
    handle!(df, take!(df.in_channel))                  # async standalone-prep decision
    handle!(df, ProcessIndexFailedMsg(standalone, ErrorException("boom")))
    @test isready(df.out_channel)
    take!(df.out_channel)

    test_a = WatchTestEnvironmentKey("/ws/P", "A", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([test_a])))
    @test test_a in launches

    # Nor may one package's test env exhaust its sibling's.
    handle!(df, ProcessIndexFailedMsg(test_a, ErrorException("boom")))
    @test isready(df.out_channel)
    take!(df.out_channel)

    test_b = WatchTestEnvironmentKey("/ws/P", "B", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([test_b])))
    @test test_b in launches
end

@testitem "Dynamic failures: an exhausted key still settles the readiness gate" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, FailedResult,
        WatchTestEnvironmentKey, process_from_dynamic, input_failed_dynamic_keys

    # The reconcile spawn loop dispatches exhausted keys rather than skipping
    # them: only the handler's `FailedResult` gets the key recorded here, and
    # only that lets `derived_file_env_ready` stop gating the project's files.
    # Skipping in the spawn loop would suppress their diagnostics forever.
    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    k = WatchTestEnvironmentKey("/ws/R", "R", UInt64(3))

    @test !(k in input_failed_dynamic_keys(jw.runtime))

    put!(jw.dynamic_feature.out_channel, FailedResult(k))
    process_from_dynamic(jw)

    @test k in input_failed_dynamic_keys(jw.runtime)
end

@testitem "Dynamic failures: ResetFailuresMsg clears the bookkeeping" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        ResetFailuresMsg, WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=1, launcher=(df, djp) -> push!(launches, djp.key))

    k1 = WatchTestEnvironmentKey("/ws/R", "R", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([k1])))
    handle!(df, ProcessIndexFailedMsg(k1, ErrorException("boom")))
    @test isready(df.out_channel)
    take!(df.out_channel)

    k2 = WatchTestEnvironmentKey("/ws/R", "R", UInt64(2))
    handle!(df, ReconcileMsg(Set{DJPKey}([k2])))
    @test length(launches) == 1                        # budget spent
    @test isready(df.out_channel)
    take!(df.out_channel)

    handle!(df, ResetFailuresMsg())
    @test isempty(df.failed_projects)
    @test isempty(df.failure_attempts)
    @test isempty(df.failure_messages)

    k3 = WatchTestEnvironmentKey("/ws/R", "R", UInt64(3))
    handle!(df, ReconcileMsg(Set{DJPKey}([k3])))
    @test length(launches) == 2
end

@testitem "Dynamic failures: a Pkg failure is reported as one readable line" begin
    using JuliaWorkspaces: WatchTestEnvironmentKey, WatchEnvironmentKey,
        CreateStandaloneProjectKey, DJPRequestTimeoutException, _humanize_djp_failure

    key = WatchTestEnvironmentKey(raw"c:\ws\packages-old\v1.5\Revise", "Revise", UInt64(0))

    # What actually arrives from the child: "Failed to index <what>: <cause>",
    # where <cause> carries the whole multi-line Pkg tree plus a stacktrace. A
    # user reading that in the middle of clean lint output concludes the tool is
    # broken, so only the first line of the cause is surfaced.
    child_msg = raw"Failed to index project at c:\ws\packages-old\v1.5\Revise (test env for package Revise): " *
        "Unsatisfiable requirements detected for package JuliaInterpreter [aa1ae85d]:\n" *
        " JuliaInterpreter [aa1ae85d] log:\n \u251c\u2500possible versions are: 0.1.1 - 0.11.4\n" *
        "Stacktrace:\n  [1] foo"
    msg = _humanize_djp_failure(key, ErrorException(child_msg))

    @test !occursin('\n', msg)
    @test occursin("test environment of package 'Revise'", msg)
    @test occursin("Unsatisfiable requirements detected for package JuliaInterpreter [aa1ae85d].", msg)
    @test !occursin("Stacktrace", msg)
    @test !occursin("Failed to index", msg)   # <what> only repeats what the key already says

    timed_out = _humanize_djp_failure(WatchEnvironmentKey(raw"c:\ws\P", UInt64(1)),
        DJPRequestTimeoutException(key, "indexProject", 300))
    @test occursin("did not answer `indexProject` within 300s.", timed_out)

    # An error with no recognizable wrapper still collapses to one line.
    plain = _humanize_djp_failure(CreateStandaloneProjectKey(raw"c:\ws\P", UInt64(1)), ErrorException("boom"))
    @test !occursin('\n', plain)
    @test occursin("boom.", plain)
end

@testitem "Dynamic failures: an index request is bounded by its deadline" begin
    using JuliaWorkspaces: DynamicJuliaProcess, DJPRequestTimeoutException, _send_djp_request,
        WatchEnvironmentKey, JuliaDynamicAnalysisProtocol
    using JuliaWorkspaces: JSONRPC

    # An unanswered request used to block forever, holding its launch slot and
    # keeping the work item pending, so `is_ready` never became true.
    key = WatchEnvironmentKey("/ws/P", UInt64(1))
    djp = DynamicJuliaProcess(key, "/ws/P", nothing, :watch_environment)

    # An endpoint whose peer accepts the request and never answers: nothing is
    # ever written to the inbound stream, so the response never arrives.
    inbound = Base.BufferStream()
    outbound = Base.BufferStream()
    djp.endpoint = JSONRPC.JSONRPCEndpoint(outbound, inbound)
    JSONRPC.start(djp.endpoint)

    try
        err = nothing
        try
            _send_djp_request(djp, 1,
                JuliaDynamicAnalysisProtocol.index_project_request_type,
                JuliaDynamicAnalysisProtocol.IndexProjectParams("/ws/P", nothing, "/tmp/store", nothing))
        catch e
            err = e
        end

        @test err isa DJPRequestTimeoutException
        @test err.timeout_seconds == 1
        @test err.key == key
        @test occursin("indexProject", err.method)
    finally
        # Close the streams first: the endpoint's reader task is parked on
        # `inbound` and only unwinds on EOF, so closing the endpoint before its
        # streams would wait on it forever.
        try close(inbound) catch end
        try close(outbound) catch end
    end
end

@testitem "Dynamic failures: a depot lock collision is classed as infrastructure" begin
    using JuliaWorkspaces: _is_infra_failure
    using JuliaWorkspaces: JSONRPC

    # Raised by the parent's own store work, so the exception itself is
    # available to inspect: `mkpath`/`mktempdir`/`isfile` all throw `IOError`.
    @test _is_infra_failure(Base.IOError("mkdir(\"…/_downloads\"): permission denied (EACCES)", Base.UV_EACCES))
    @test _is_infra_failure(Base.IOError("unlink(\"…/manifest_usage.toml.pid\"): resource busy or locked (EBUSY)", Base.UV_EBUSY))
    @test !_is_infra_failure(Base.IOError("open: no such file or directory (ENOENT)", Base.UV_ENOENT))
    @test !_is_infra_failure(Base.IOError("open(\"/workspace/Project.toml\"): permission denied (EACCES)", Base.UV_EACCES))

    # Raised in the child, where only the rendered text crosses the boundary.
    @test _is_infra_failure(JSONRPC.JSONRPCError(-32000,
        "Failed to index project at /ws/P: IOError: stat(\"…/manifest_usage.toml.pid\"): permission denied (EACCES)", nothing))
    @test !_is_infra_failure(JSONRPC.JSONRPCError(-32000,
        "Failed to index project at /ws/P: IOError: open(\"/ws/P/Project.toml\"): permission denied (EACCES)", nothing))
    @test !_is_infra_failure(JSONRPC.JSONRPCError(-32000,
        "Failed to index project at /ws/P: Unsatisfiable requirements detected", nothing))

    # A project failure that merely quotes those words is the project's problem.
    @test !_is_infra_failure(ErrorException("IOError: EACCES"))
end
