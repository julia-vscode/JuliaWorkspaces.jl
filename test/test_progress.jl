@testitem "ProgressState basics" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, ProgressState, _report_progress

    # Direct ProgressState tests
    ps = ProgressState()
    @test ps.total_items == 0
    @test ps.completed_items == 0
    @test ps.current_sub_progress == 0.0
    @test ps.current_message == ""
end

@testitem "DynamicFeature with progress_callback" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    # Collect all progress calls
    calls = Tuple{String,Int}[]
    cb = (msg, pct) -> push!(calls, (msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)

    @test df.progress_callback === cb
    @test df.progress_state.total_items == 0

    # Simulate: 2 items dispatched
    df.progress_state.total_items = 2

    # First item starts downloading (sub_progress = 0.25 → 25% of item 1 of 2)
    df.progress_state.current_sub_progress = 0.25
    _report_progress(df, "Downloading caches (5/20)...")
    @test length(calls) == 1
    @test calls[end][1] == "Downloading caches (5/20)..."
    @test calls[end][2] == 12  # floor((0 + 0.25) / 2 * 100)

    # First item finishes download, starts indexing (sub_progress = 0.5)
    df.progress_state.current_sub_progress = 0.5
    _report_progress(df, "Indexing project...")
    @test calls[end][2] == 25  # floor((0 + 0.5) / 2 * 100)

    # First item done
    df.progress_state.completed_items = 1
    df.progress_state.current_sub_progress = 0.0
    _report_progress(df, "Item 1 done")
    @test calls[end][2] == 50  # floor((1 + 0) / 2 * 100)

    # Second item at sub_progress 0.5
    df.progress_state.current_sub_progress = 0.5
    _report_progress(df, "Indexing project 2...")
    @test calls[end][2] == 75  # floor((1 + 0.5) / 2 * 100)

    # All done
    df.progress_state.completed_items = 2
    df.progress_state.current_sub_progress = 0.0
    _report_progress(df, "Indexing complete")
    @test calls[end][2] == 100
end

@testitem "DynamicFeature without progress_callback" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    # No callback — should not error
    df = DynamicFeature(DynamicIndexingOnly, store_path)
    @test df.progress_callback === nothing

    df.progress_state.total_items = 1
    df.progress_state.current_sub_progress = 0.5
    # This should be a no-op without errors
    _report_progress(df, "Should not crash")
end

@testitem "Progress callback error resilience" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    # A callback that throws
    bad_cb = (msg, pct) -> error("callback exploded")

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=bad_cb)
    df.progress_state.total_items = 1

    # Should not propagate the error
    _report_progress(df, "test")
end

@testitem "Progress with zero total_items" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, _report_progress

    store_path = mktempdir()

    calls = Tuple{String,Int}[]
    cb = (msg, pct) -> push!(calls, (msg, pct))

    df = DynamicFeature(DynamicIndexingOnly, store_path; progress_callback=cb)

    # total_items == 0 — should report 0% without division error
    _report_progress(df, "Nothing to do")
    @test length(calls) == 1
    @test calls[1][2] == 0
end
