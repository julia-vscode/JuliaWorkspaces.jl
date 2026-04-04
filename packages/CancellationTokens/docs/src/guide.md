# Guide

## Basic Usage

Create a source, get a token, pass it to operations:

```julia
using CancellationTokens

src = CancellationTokenSource()
token = get_token(src)

# Later, from another task or thread:
cancel(src)
```

Check whether cancellation has been requested without blocking:

```julia
if is_cancellation_requested(token)
    # clean up
end
```

Or block until cancellation occurs:

```julia
wait(token)  # returns when cancel(src) is called
```

## Timeout-Based Cancellation

A source can auto-cancel after a given number of seconds:

```julia
src = CancellationTokenSource(5.0)   # cancels after 5 seconds
wait(get_token(src))                 # blocks for ~5 s
```

This is useful for implementing timeouts on operations that accept a token:

```julia
# Give the operation at most 10 seconds
src = CancellationTokenSource(10.0)
result = take!(channel, get_token(src))
```

## Combined / Linked Sources

A combined source cancels when **any** of its parent tokens is cancelled:

```julia
timeout_src = CancellationTokenSource(30.0)
manual_src  = CancellationTokenSource()

combined = CancellationTokenSource(get_token(timeout_src), get_token(manual_src))
token = get_token(combined)

# `token` will be cancelled if the timeout expires OR if manual_src is cancelled
sleep(60.0, token)
```

The parent sources are not affected when the combined source is cancelled through one of them — cancellation only flows downward.

## Handling OperationCanceledException

Cancellable functions throw [`OperationCanceledException`](@ref) when their token is cancelled. Catch it to perform cleanup:

```julia
try
    data = take!(channel, token)
    process(data)
catch ex
    if ex isa OperationCanceledException
        println("Operation was cancelled")
        # The channel is still usable after cancellation
    else
        rethrow()
    end
end
```

Retrieve the token that caused the exception with [`get_token`](@ref):

```julia
catch ex::OperationCanceledException
    tok = get_token(ex)
    @info "Cancelled" is_cancellation_requested(tok)
end
```

## Building Custom Cancellable Operations

Use `wait(token)` and `is_cancellation_requested(token)` to add cancellation support to your own functions:

```julia
function my_long_computation(token::CancellationToken)
    result = 0
    for i in 1:1_000_000
        # Periodically check for cancellation
        if i % 1000 == 0
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
        end
        result += expensive_step(i)
    end
    return result
end
```

For operations that block on a condition variable or event, spawn a monitoring task that wakes up the waiter on cancellation:

```julia
function my_blocking_op(token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))

    done = Threads.Event()
    result = Ref{Any}(nothing)

    # Worker
    worker = @async begin
        result[] = do_work()
        notify(done)
    end

    # Cancellation monitor
    monitor = @async begin
        wait(token)
        notify(done)
    end

    wait(done)

    if is_cancellation_requested(token)
        throw(OperationCanceledException(token))
    end
    return result[]
end
```

## Callback Registration

Instead of spawning a task to watch for cancellation, you can register a
callback that is invoked synchronously when `cancel` is called — matching
.NET's `CancellationToken.Register(Action)`:

```julia
src = CancellationTokenSource()
token = get_token(src)

reg = register(token) do
    println("Cancelled!")
end

cancel(src)   # prints "Cancelled!" immediately, inline with cancel()
```

Callbacks are invoked synchronously during `cancel()`, so they should be
non-blocking and fast.

If the token is already cancelled when `register` is called, the callback is
invoked immediately before `register` returns.

### Deregistration

`register` returns a [`CancellationTokenRegistration`](@ref) handle.  Call
`close` on it to prevent the callback from being invoked:

```julia
src = CancellationTokenSource()
reg = register(get_token(src)) do
    error("should not run")
end

close(reg)     # deregister
cancel(src)    # callback is NOT invoked
```

Deregistration is idempotent — calling `close` multiple times is safe.

### Use Cases

Callback registration is useful when you need to perform a side effect on
cancellation without spawning a monitoring task:

```julia
# Close a socket when cancelled
reg = register(token) do
    close(socket)
end

try
    process(socket)
finally
    close(reg)   # clean up registration if we finish normally
end
```

It is also how combined sources (`CancellationTokenSource(token1, token2, ...)`)
are implemented internally — each parent token registers a callback instead of
spawning a monitoring task.

## Socket readline Cancellation

[`readline(socket, token)`](@ref) supports cancellation on `TCPSocket` and
`PipeEndpoint`.  When the token is cancelled, the socket is **closed** to
unblock the pending read:

```julia
src = CancellationTokenSource(5.0)
try
    line = readline(socket, get_token(src))
    process(line)
catch ex
    if ex isa OperationCanceledException
        @info "Read timed out — socket has been closed"
        # Reconnect if needed
    else
        rethrow()
    end
end
```

!!! note "Why the socket is closed"
    Closing the socket is the only safe way to interrupt a blocking read
    without corrupting other tasks.  The previous approach injected an error
    into the socket's shared condition variable, which would crash **all**
    tasks waiting on the same socket — not just the one that requested
    cancellation.  Closing the socket gives every reader a clean I/O error
    instead.

    For typical timeout use cases this is the right behaviour: if a read
    timed out, the protocol state is usually indeterminate and the
    connection should be re-established.

## Socket read Cancellation

[`read(socket, nb, token)`](@ref) supports cancellation on `TCPSocket` and
`PipeEndpoint`, reading a fixed number of bytes.  Like `readline`, the
socket is **closed** when the token is cancelled:

```julia
src = CancellationTokenSource(5.0)
try
    data = read(socket, 1024, get_token(src))
    process(data)
catch ex
    if ex isa OperationCanceledException
        @info "Read timed out — socket has been closed"
        # Reconnect if needed
    else
        rethrow()
    end
end
```

The same rationale applies: closing the socket is the only safe way to
interrupt a blocking read without corrupting other tasks on the same
socket.

## Resource Cleanup

[`CancellationTokenSource`](@ref) implements `close`, which is equivalent to [`cancel`](@ref). This enables `do`-block patterns for scoped cancellation:

```julia
src = CancellationTokenSource()
try
    run_operation(get_token(src))
finally
    close(src)  # ensures timer and callbacks are cleaned up
end
```
