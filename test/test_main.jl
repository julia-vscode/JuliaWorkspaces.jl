# ---------------------------------------------------------------------------
# CancellationTokenSource — construction and state
# ---------------------------------------------------------------------------

@testitem "CancellationTokenSource starts in non-cancelled state" begin
    src = CancellationTokenSource()
    @test !is_cancellation_requested(get_token(src))
end

@testitem "cancel sets is_cancellation_requested" begin
    src = CancellationTokenSource()
    cancel(src)
    @test is_cancellation_requested(get_token(src))
end

@testitem "cancel is idempotent" begin
    src = CancellationTokenSource()
    cancel(src)
    cancel(src)
    cancel(src)
    @test is_cancellation_requested(get_token(src))
end

@testitem "close cancels the source" begin
    src = CancellationTokenSource()
    close(src)
    @test is_cancellation_requested(get_token(src))
end

# ---------------------------------------------------------------------------
# CancellationToken — get_token and is_cancellation_requested
# ---------------------------------------------------------------------------

@testitem "get_token returns a token that supports is_cancellation_requested" begin
    src = CancellationTokenSource()
    token = get_token(src)
    @test !is_cancellation_requested(token)
end

@testitem "Token reflects source cancellation state" begin
    src = CancellationTokenSource()
    token = get_token(src)
    @test !is_cancellation_requested(token)
    cancel(src)
    @test is_cancellation_requested(token)
end

@testitem "Multiple tokens from the same source share state" begin
    src = CancellationTokenSource()
    t1 = get_token(src)
    t2 = get_token(src)
    cancel(src)
    @test is_cancellation_requested(t1)
    @test is_cancellation_requested(t2)
end

# ---------------------------------------------------------------------------
# wait(::CancellationToken)
# ---------------------------------------------------------------------------

@testitem "wait returns immediately when already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    # Should not block
    wait(get_token(src))
    @test true
end

@testitem "wait blocks until cancel is called" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    token = get_token(src)
    done = Ref(false)

    @spawn begin
        sleep(0.1)
        cancel(src)
    end

    wait(token)
    done[] = true
    @test done[]
    @test is_cancellation_requested(get_token(src))
end

@testitem "wait returns immediately when cancelled before wait but after token creation" begin
    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)
    wait(token)
    @test true
end

@testitem "Multiple waiters all unblock on cancel" setup=[SpawnHelper] begin
    src = CancellationTokenSource()
    token = get_token(src)
    results = Channel{Int}(10)

    for i in 1:5
        @spawn begin
            wait(token)
            put!(results, i)
        end
    end

    sleep(0.05)
    cancel(src)
    sleep(0.1)

    collected = Int[]
    while isready(results)
        push!(collected, take!(results))
    end
    @test sort(collected) == [1, 2, 3, 4, 5]
end

# ---------------------------------------------------------------------------
# CancellationTokenSource with timeout
# ---------------------------------------------------------------------------

@testitem "Timeout source cancels after specified duration" begin
    src = CancellationTokenSource(0.1)
    @test !is_cancellation_requested(get_token(src))
    wait(get_token(src))
    @test is_cancellation_requested(get_token(src))
end

@testitem "Timeout source can be cancelled early" begin
    src = CancellationTokenSource(10.0)
    @test !is_cancellation_requested(get_token(src))
    cancel(src)
    @test is_cancellation_requested(get_token(src))
end

@testitem "Timeout source - wait returns after timeout" begin
    t0 = time()
    src = CancellationTokenSource(0.1)
    wait(get_token(src))
    elapsed = time() - t0
    @test elapsed >= 0.05
    @test elapsed < 2.0
end

# ---------------------------------------------------------------------------
# Combined CancellationTokenSource
# ---------------------------------------------------------------------------

@testitem "Combined source cancels when first token cancels" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    @test !is_cancellation_requested(get_token(combined))
    cancel(src1)
    sleep(0.05)
    @test is_cancellation_requested(get_token(combined))
end

@testitem "Combined source cancels when second token cancels" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    cancel(src2)
    sleep(0.05)
    @test is_cancellation_requested(get_token(combined))
    # src1 should not be affected
    @test !is_cancellation_requested(get_token(src1))
end

@testitem "Combined source - wait unblocks on any parent cancel" setup=[SpawnHelper] begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    @spawn begin
        sleep(0.1)
        cancel(src2)
    end

    wait(get_token(combined))
    @test is_cancellation_requested(get_token(combined))
    @test !is_cancellation_requested(get_token(src1))
    @test is_cancellation_requested(get_token(src2))
end

@testitem "Combined source with already-cancelled token cancels immediately" begin
    src1 = CancellationTokenSource()
    cancel(src1)
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    sleep(0.05)
    @test is_cancellation_requested(get_token(combined))
end

@testitem "Combined source with already-cancelled token stress test" begin
    # Regression test: creating a combined source with an already-cancelled
    # parent must not corrupt Julia's task workqueue.  The bug manifested as
    # `TypeError(expected=Task, got=nothing)` in `popfirst!(Workqueue)`.
    for _ in 1:200
        src1 = CancellationTokenSource()
        cancel(src1)
        src2 = CancellationTokenSource()
        combined = CancellationTokenSource(get_token(src1), get_token(src2))
        @test is_cancellation_requested(get_token(combined))
        @test !is_cancellation_requested(get_token(src2))
    end
end

@testitem "Combined source with single token" begin
    src = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src))

    @test !is_cancellation_requested(get_token(combined))
    cancel(src)
    sleep(0.05)
    @test is_cancellation_requested(get_token(combined))
end

@testitem "Combined source with three tokens" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    src3 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2), get_token(src3))

    cancel(src3)
    sleep(0.05)
    @test is_cancellation_requested(get_token(combined))
    @test !is_cancellation_requested(get_token(src1))
    @test !is_cancellation_requested(get_token(src2))
end

@testitem "Combined source with timeout token" begin
    timeout_src = CancellationTokenSource(0.1)
    manual_src = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(timeout_src), get_token(manual_src))

    wait(get_token(combined))
    @test is_cancellation_requested(get_token(combined))
    @test is_cancellation_requested(get_token(timeout_src))
    @test !is_cancellation_requested(get_token(manual_src))
end

# ---------------------------------------------------------------------------
# OperationCanceledException
# ---------------------------------------------------------------------------

@testitem "OperationCanceledException carries the token" begin
    src = CancellationTokenSource()
    token = get_token(src)
    ex = OperationCanceledException(token)
    @test ex isa Exception
    @test get_token(ex) === token
end

@testitem "OperationCanceledException is a subtype of Exception" begin
    @test OperationCanceledException <: Exception
end

# ---------------------------------------------------------------------------
# register / CancellationTokenRegistration
# ---------------------------------------------------------------------------

@testitem "register callback invoked on cancel" begin
    src = CancellationTokenSource()
    called = Ref(false)
    register(get_token(src)) do
        called[] = true
    end
    @test !called[]
    cancel(src)
    @test called[]
end

@testitem "register on already-cancelled token invokes immediately" begin
    src = CancellationTokenSource()
    cancel(src)
    called = Ref(false)
    register(get_token(src)) do
        called[] = true
    end
    @test called[]
end

@testitem "register with source directly errors" begin
    src = CancellationTokenSource()
    @test_throws MethodError register(src) do
        nothing
    end
end

@testitem "deregistration prevents callback invocation" begin
    src = CancellationTokenSource()
    called = Ref(false)
    reg = register(get_token(src)) do
        called[] = true
    end
    close(reg)
    cancel(src)
    @test !called[]
end

@testitem "deregistration is idempotent" begin
    src = CancellationTokenSource()
    reg = register(get_token(src)) do
        nothing
    end
    close(reg)
    close(reg)  # should not error
    @test true
end

@testitem "multiple callbacks all invoked" begin
    src = CancellationTokenSource()
    results = Int[]
    for i in 1:5
        register(get_token(src)) do
            push!(results, i)
        end
    end
    cancel(src)
    @test sort(results) == [1, 2, 3, 4, 5]
end

@testitem "callback error does not prevent other callbacks" begin
    src = CancellationTokenSource()
    called = Ref(false)
    register(get_token(src)) do
        error("boom")
    end
    register(get_token(src)) do
        called[] = true
    end
    cancel(src)
    @test called[]
end

@testitem "combined source uses register (no tasks spawned)" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    # Cancellation should propagate synchronously via callbacks
    @test !is_cancellation_requested(get_token(combined))
    cancel(src1)
    # No sleep needed — callback is synchronous
    @test is_cancellation_requested(get_token(combined))
end

@testitem "combined source propagates synchronously from second parent" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    cancel(src2)
    @test is_cancellation_requested(get_token(combined))
    @test !is_cancellation_requested(get_token(src1))
end

@testitem "register returns CancellationTokenRegistration" begin
    src = CancellationTokenSource()
    reg = register(get_token(src)) do
        nothing
    end
    @test reg isa CancellationTokenRegistration
end

# ---------------------------------------------------------------------------
# Type stability — @inferred checks for all public methods
# ---------------------------------------------------------------------------

@testitem "Type stability (@inferred) of all public methods" begin
    import Sockets

    # --- Core constructors ---
    src = @inferred CancellationTokenSource()
    timeout_src = @inferred CancellationTokenSource(0.5)
    cancel(timeout_src)  # clean up timer

    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = @inferred CancellationTokenSource(get_token(src1), get_token(src2))
    cancel(src1)

    # --- get_token ---
    token = @inferred get_token(src)

    # --- is_cancellation_requested ---
    @test @inferred(is_cancellation_requested(token)) == false

    # --- register / close(registration) ---
    reg = @inferred register(() -> nothing, token)
    @inferred close(reg)

    # --- cancel / close(source) ---
    @inferred cancel(src)
    @inferred close(src)

    # --- wait(::CancellationToken) on already-cancelled token ---
    @inferred wait(token)

    # --- OperationCanceledException ---
    ex = @inferred OperationCanceledException(token)
    @test @inferred(get_token(ex)) === token

    # --- Channel operations ---
    ch = Channel{Int}(10)
    put!(ch, 42)
    put!(ch, 43)

    src3 = CancellationTokenSource()
    @inferred wait(ch, get_token(src3))
    @test @inferred(take!(ch, get_token(src3))) == 42

    # --- sleep (normal completion, zero duration) ---
    src4 = CancellationTokenSource()
    @inferred sleep(0.0, get_token(src4))

    # --- read (socket — just test that the method signature is inferrable
    #     via precompile; can't call without a real socket) ---
    @test precompile(read, (Sockets.TCPSocket, Int, CancellationToken))
    @test precompile(read, (Sockets.PipeEndpoint, Int, CancellationToken))

    cancel(src3)
    cancel(src4)
end
