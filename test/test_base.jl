# ---------------------------------------------------------------------------
# Base.sleep with cancellation token
# ---------------------------------------------------------------------------

@testitem "sleep completes normally without cancellation" begin
    src = CancellationTokenSource()
    t0 = time()
    sleep(0.1, get_token(src))
    elapsed = time() - t0
    @test elapsed >= 0.05
    @test !is_cancellation_requested(get_token(src))
end

@testitem "sleep throws OperationCanceledException on cancel" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException sleep(20.0, get_token(src))
end

@testitem "sleep - exception carries the correct token" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    token = get_token(src)
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    try
        sleep(20.0, token)
        @test false  # should not reach here
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "sleep - cancel before sleep throws immediately" begin
    src = CancellationTokenSource()
    cancel(src)
    @test_throws OperationCanceledException sleep(20.0, get_token(src))
end

@testitem "sleep - cancellation returns faster than timeout" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    t0 = time()
    try
        sleep(60.0, get_token(src))
    catch ex
        @test ex isa OperationCanceledException
    end
    elapsed = time() - t0
    @test elapsed < 5.0
end

@testitem "sleep - zero duration completes immediately" begin
    src = CancellationTokenSource()
    sleep(0.0, get_token(src))
    @test !is_cancellation_requested(get_token(src))
end

# ---------------------------------------------------------------------------
# Base.wait(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

@testitem "wait(Channel) returns when channel becomes ready" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    @spawn begin
        sleep(0.1)
        put!(ch, 42)
    end
    wait(ch, get_token(src))
    @test isready(ch)
    @test !is_cancellation_requested(get_token(src))
end

@testitem "wait(Channel) throws on cancellation" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException wait(ch, get_token(src))
end

@testitem "wait(Channel) returns immediately if channel already has data" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    put!(ch, 1)
    wait(ch, get_token(src))
    @test true
end

@testitem "wait(Channel) throws immediately if already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    ch = Channel{Int}(1)
    @test_throws OperationCanceledException wait(ch, get_token(src))
end

@testitem "wait(Channel) exception carries correct token" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    token = get_token(src)
    ch = Channel{Int}(1)
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    try
        wait(ch, token)
        @test false
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "wait(Channel) - closed channel throws" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    close(ch)
    @test_throws InvalidStateException wait(ch, get_token(src))
end

# ---------------------------------------------------------------------------
# Base.take!(::Channel, ::CancellationToken) — buffered
# ---------------------------------------------------------------------------

@testitem "take!(Channel) returns value when data available" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    put!(ch, 42)
    v = take!(ch, get_token(src))
    @test v == 42
end

@testitem "take!(Channel) blocks and returns when data arrives" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    @spawn begin
        sleep(0.1)
        put!(ch, 99)
    end
    v = take!(ch, get_token(src))
    @test v == 99
end

@testitem "take!(Channel) throws on cancellation" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(Inf)
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException take!(ch, get_token(src))
end

@testitem "take!(Channel) throws immediately if already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    ch = Channel{Int}(Inf)
    put!(ch, 1)
    # Even though data is available, the token is already cancelled
    @test_throws OperationCanceledException take!(ch, get_token(src))
end

@testitem "take!(Channel) exception carries correct token" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    token = get_token(src)
    ch = Channel{Int}(Inf)
    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    try
        take!(ch, token)
        @test false
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "take!(Channel) preserves FIFO order" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    for i in 1:5
        put!(ch, i)
    end
    for i in 1:5
        @test take!(ch, get_token(src)) == i
    end
end

# ---------------------------------------------------------------------------
# Regression tests for data race fix (issue #23)
# Ensure that cancellation callbacks don't inject spurious notifications
# into shared condition variables after the main operation completes.
# ---------------------------------------------------------------------------

@testitem "wait(Channel) - cancel after data arrives does not leak notifications" begin
    # Simulate: data arrives, then cancel fires immediately after.
    # A second waiter on the same channel must NOT be spuriously woken.
    for _ in 1:50  # repeat to exercise timing
        ch = Channel{Int}(1)
        src = CancellationTokenSource()

        # Put data so that wait returns, then cancel right after.
        put!(ch, 1)
        wait(ch, get_token(src))
        cancel(src)
        yield()  # let any stray async tasks run

        # A second wait with a fresh token must still block (channel was
        # not taken from, so data is still there — isready returns true
        # and wait returns immediately). This verifies no error was injected.
        src2 = CancellationTokenSource()
        wait(ch, get_token(src2))
        @test isready(ch)
    end
end

@testitem "take!(Channel) - cancel after take succeeds does not leak notifications" begin
    for _ in 1:50
        ch = Channel{Int}(1)
        src = CancellationTokenSource()

        put!(ch, 42)
        v = take!(ch, get_token(src))
        @test v == 42
        cancel(src)
        yield()

        # A second waiter should block normally, not get a spurious wakeup.
        src2 = CancellationTokenSource(0.1)
        @test_throws OperationCanceledException take!(ch, get_token(src2))
    end
end

@testitem "wait(Channel) - concurrent cancel and data arrival" setup=[SpawnHelper] begin
    for _ in 1:20
        ch = Channel{Int}(1)
        src = CancellationTokenSource()
        token = get_token(src)

        # Race: put data and cancel at roughly the same time.
        @spawn begin
            yield()
            put!(ch, 1)
        end
        @spawn begin
            yield()
            cancel(src)
        end

        # Should either return normally or throw OperationCanceledException.
        try
            wait(ch, token)
        catch ex
            @test ex isa OperationCanceledException
        end

        # Channel must still be usable regardless of outcome.
        if isready(ch)
            @test take!(ch) == 1
        end
    end
end

@testitem "take!(Channel) - concurrent cancel and data arrival" setup=[SpawnHelper] begin
    for _ in 1:20
        ch = Channel{Int}(1)
        src = CancellationTokenSource()
        token = get_token(src)

        @spawn begin
            yield()
            put!(ch, 99)
        end
        @spawn begin
            yield()
            cancel(src)
        end

        try
            v = take!(ch, token)
            @test v == 99
        catch ex
            @test ex isa OperationCanceledException
        end
    end
end

@testitem "take!(Channel) - closed empty channel throws" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    close(ch)
    @test_throws InvalidStateException take!(ch, get_token(src))
end

@testitem "take!(Channel) - closed channel with remaining data returns data" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    put!(ch, 1)
    put!(ch, 2)
    close(ch)
    @test take!(ch, get_token(src)) == 1
    @test take!(ch, get_token(src)) == 2
    @test_throws InvalidStateException take!(ch, get_token(src))
end

@testitem "take!(Channel) on unbuffered channel throws not-implemented" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(0)
    @test_throws ErrorException take!(ch, get_token(src))
end

@testitem "take!(Channel) - channel usable after cancelled take!" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)

    @spawn begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException take!(ch, get_token(src))

    # Channel should still work normally
    put!(ch, 42)
    @test take!(ch) == 42
end

@testitem "take!(Channel) with typed channel" begin
    src = CancellationTokenSource()
    ch = Channel{String}(10)
    put!(ch, "hello")
    v = take!(ch, get_token(src))
    @test v == "hello"
    @test v isa String
end

@testitem "take!(Channel) - multiple sequential takes with token" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    @spawn begin
        for i in 1:3
            sleep(0.05)
            put!(ch, i)
        end
    end
    results = [take!(ch, get_token(src)) for _ in 1:3]
    @test results == [1, 2, 3]
end
