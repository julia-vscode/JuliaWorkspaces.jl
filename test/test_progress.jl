@testitem "_report_progress basics" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    calls = Tuple{String,String,Int}[]
    cb = (key, msg, pct) -> push!(calls, (key, msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)
    @test df.progress_callback === cb

    _report_progress(df, "some-op", "Working...", 10)
    @test calls == [("some-op", "Working...", 10)]

    # No callback — should be a no-op without errors
    df2 = DynamicFeature(DynamicIndexingOnly, store_path)
    _report_progress(df2, "some-op", "Working...", 10)
end

@testitem "Progress callback error resilience" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    # A callback that throws
    bad_cb = (key, msg, pct) -> error("callback exploded")

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=bad_cb)

    # Should not propagate the error
    @test_logs (:warn, "progress_callback threw") _report_progress(df, "some-op", "test", 1)
end

@testitem "Per-operation progress bars" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ProcessProgressMsg, PrepProgressMsg,
        WatchEnvironmentKey, WatchTestEnvironmentKey, handle!, _complete_work_item!

    store_path = mktempdir()

    calls = Tuple{String,String,Int}[]
    cb = (key, msg, pct) -> push!(calls, (key, msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)
    df.pending_count[] = 1

    key = WatchEnvironmentKey("/some/project", UInt64(1))
    push!(df.inflight, key)

    # Download-phase reports land on the item's download bar with the phase's
    # own 0-100 range.
    handle!(df, PrepProgressMsg(key, "Downloading caches (5/20)...", 0.25))
    @test calls[end] == ("download:/some/project", "Downloading caches (5/20)...", 25)
    handle!(df, PrepProgressMsg(key, "Downloaded caches", 1.0))
    @test calls[end] == ("download:/some/project", "Downloaded caches", 100)

    # Child indexing percentages pass through onto the item's index bar,
    # capped below 100 (completion ends the bar).
    handle!(df, ProcessProgressMsg(key, "Indexing Foo (1/2)...", 50))
    @test calls[end] == ("index:/some/project", "Indexing Foo (1/2)...", 50)

    # A report without a percentage re-uses the last one.
    handle!(df, ProcessProgressMsg(key, "Extracting symbols...", missing))
    @test calls[end] == ("index:/some/project", "Extracting symbols...", 50)

    # A report with a lower percentage must not move the bar backwards.
    handle!(df, ProcessProgressMsg(key, "Late report", 25))
    @test calls[end] == ("index:/some/project", "Late report", 50)

    # Progress for a key that is not in flight is ignored.
    stale_key = WatchEnvironmentKey("/other/project", UInt64(2))
    n_calls = length(calls)
    handle!(df, ProcessProgressMsg(stale_key, "Should be ignored", 10))
    handle!(df, PrepProgressMsg(stale_key, "Should be ignored", 0.5))
    @test length(calls) == n_calls

    # Completing the work item ends its bars.
    _complete_work_item!(df, key)
    @test ("download:/some/project", "Done", 100) in calls
    @test calls[end] == ("index:/some/project", "Done", 100)
    @test key ∉ keys(df.child_progress)
end

@testitem "Refresh progress lands on the refresh bar" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ProcessProgressMsg,
        CreateStandaloneProjectKey, handle!

    store_path = mktempdir()

    calls = Tuple{String,String,Int}[]
    cb = (key, msg, pct) -> push!(calls, (key, msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)

    # A refreshing key has already completed its work item, so it is in
    # `refreshing`, not `inflight`.
    key = CreateStandaloneProjectKey("/some/pkg", UInt64(1))
    push!(df.refreshing, key)

    handle!(df, ProcessProgressMsg(key, "Indexing Foo (1/2)...", 50))
    @test calls[end] == ("refresh:/some/pkg", "Indexing Foo (1/2)...", 50)

    # child_progress is cleared when the refresh ends so a later refresh of the
    # same key starts fresh.
    delete!(df.refreshing, key)
    delete!(df.child_progress, key)
    @test key ∉ keys(df.child_progress)
end

@testitem "Concurrent work items get independent bars" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ProcessProgressMsg,
        WatchEnvironmentKey, WatchTestEnvironmentKey, handle!, _complete_work_item!

    store_path = mktempdir()

    calls = Tuple{String,String,Int}[]
    cb = (key, msg, pct) -> push!(calls, (key, msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)
    df.pending_count[] = 2

    key_a = WatchEnvironmentKey("/some/project", UInt64(1))
    key_b = WatchTestEnvironmentKey("/some/project", "SomePackage", UInt64(1))
    push!(df.inflight, key_a); push!(df.inflight, key_b)

    # Each item's reports go to its own key; neither masks the other.
    handle!(df, ProcessProgressMsg(key_a, "Indexing Foo (1/2)...", 50))
    @test calls[end] == ("index:/some/project", "Indexing Foo (1/2)...", 50)
    handle!(df, ProcessProgressMsg(key_b, "Indexing test env...", 30))
    @test calls[end] == ("index:/some/project:SomePackage", "Indexing test env...", 30)
    handle!(df, ProcessProgressMsg(key_a, "Indexing Bar (2/2)...", 80))
    @test calls[end] == ("index:/some/project", "Indexing Bar (2/2)...", 80)

    # Completing one item ends only its own bar; the sibling is untouched.
    _complete_work_item!(df, key_a)
    @test calls[end] == ("index:/some/project", "Done", 100)
    handle!(df, ProcessProgressMsg(key_b, "Indexing test env...", 60))
    @test calls[end] == ("index:/some/project:SomePackage", "Indexing test env...", 60)
    _complete_work_item!(df, key_b)
    @test calls[end] == ("index:/some/project:SomePackage", "Done", 100)
end
