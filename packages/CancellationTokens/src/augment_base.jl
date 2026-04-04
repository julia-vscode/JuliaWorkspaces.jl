# Helper: get the condition variable that `wait(::Channel)` uses.
# Julia 1.9+ split this into a separate `cond_wait` field;
# older versions use `cond_take` for both wait and take!.
@static if :cond_wait in fieldnames(Channel{Any})
    _channel_wait_cond(c::Channel) = c.cond_wait
else
    _channel_wait_cond(c::Channel) = c.cond_take
end

# ---------------------------------------------------------------------------
# Base.sleep with cancellation
# ---------------------------------------------------------------------------

"""
    sleep(seconds::Real, token::CancellationToken)

Sleep for `seconds`, but wake up early with an
[`OperationCanceledException`](@ref) if `token` is cancelled.

# Examples

```julia
src = CancellationTokenSource()
@async begin sleep(1); cancel(src) end
sleep(60.0, get_token(src))  # throws OperationCanceledException after ~1 s
```
"""
function Base.sleep(sec::Real, token::CancellationToken)
    timer_src = CancellationTokenSource(sec)
    timer_token = get_token(timer_src)
    combined = CancellationTokenSource(timer_token, token)

    try
        wait(get_token(combined))
    finally
        # Ensure the timer is closed even if the external token cancelled us.
        # cancel() is idempotent and closes the internal Timer.
        cancel(timer_src)
    end

    # timer_src was cancelled by cancel() above regardless of who fired first,
    # so check the *original* token to decide the outcome.
    if is_cancellation_requested(token)
        throw(OperationCanceledException(token))
    end
end

# ---------------------------------------------------------------------------
# Base.readline with cancellation  (sockets only)
# ---------------------------------------------------------------------------

"""
    readline(socket::Union{Sockets.PipeEndpoint, Sockets.TCPSocket},
             token::CancellationToken; keep=false)

Read a line from `socket`, but throw [`OperationCanceledException`](@ref) if
`token` is cancelled before data arrives.

!!! warning "Cancellation closes the socket"
    When `token` is cancelled, the underlying socket is **closed** to unblock
    the read.  This means the socket is no longer usable after cancellation.

    This is the only safe way to interrupt a socket read without corrupting
    other tasks that may be waiting on the same socket condition variable.
    Closing the socket ensures all readers receive a clean I/O error rather
    than having a foreign `OperationCanceledException` injected into
    unrelated tasks.

    For most timeout use cases this is the desired behaviour — if a read
    timed out, the protocol-level state is typically indeterminate anyway
    and the connection should be re-established.

# Examples

```julia
src = CancellationTokenSource(5.0)  # 5 s timeout
try
    line = readline(socket, get_token(src))
catch ex
    if ex isa OperationCanceledException
        # socket has been closed; reconnect if needed
    end
end
```
"""
function Base.readline(s::Union{Sockets.PipeEndpoint,Sockets.TCPSocket}, token::CancellationToken; keep::Bool=false)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))

    # Register a callback that closes the socket on cancellation.
    # close() unblocks any pending reads, which we then detect and
    # translate into OperationCanceledException.
    # The callback is run via @_spawn to avoid deadlocking inside cancel(),
    # since register callbacks execute synchronously.
    reg = register(token) do
        @_spawn close(s)
    end

    try
        result = readline(s; keep=keep)
        # readline returns "" on a closed socket without throwing.
        # Only treat this as cancellation when the empty result was
        # caused by the cancellation callback closing the socket.
        # If real data arrived, return it even if the token was
        # cancelled in the meantime (.NET semantics: completed
        # operations are not retroactively cancelled).
        if result == "" && is_cancellation_requested(token)
            throw(OperationCanceledException(token))
        end
        return result
    catch ex
        # If cancellation caused the socket to close, translate the resulting
        # I/O error into OperationCanceledException.
        if ex isa OperationCanceledException
            rethrow()
        end
        if is_cancellation_requested(token)
            throw(OperationCanceledException(token))
        end
        rethrow()
    finally
        close(reg)
    end
end

# ---------------------------------------------------------------------------
# Base.read with cancellation  (sockets only)
# ---------------------------------------------------------------------------

"""
    read(socket::Union{Sockets.PipeEndpoint, Sockets.TCPSocket},
         nb::Integer, token::CancellationToken)

Read `nb` bytes from `socket`, but throw [`OperationCanceledException`](@ref)
if `token` is cancelled before enough data arrives.

!!! warning "Cancellation closes the socket"
    When `token` is cancelled, the underlying socket is **closed** to unblock
    the read.  This means the socket is no longer usable after cancellation.

    This is the only safe way to interrupt a socket read without corrupting
    other tasks that may be waiting on the same socket condition variable.
    Closing the socket ensures all readers receive a clean I/O error rather
    than having a foreign `OperationCanceledException` injected into
    unrelated tasks.

    For most timeout use cases this is the desired behaviour — if a read
    timed out, the protocol-level state is typically indeterminate anyway
    and the connection should be re-established.

# Examples

```julia
src = CancellationTokenSource(5.0)  # 5 s timeout
try
    data = read(socket, 1024, get_token(src))
catch ex
    if ex isa OperationCanceledException
        # socket has been closed; reconnect if needed
    end
end
```
"""
function Base.read(s::Union{Sockets.PipeEndpoint,Sockets.TCPSocket}, nb::Integer, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))

    reg = register(token) do
        @async close(s)
    end

    try
        result = read(s, nb)
        # read returns a short result on a closed socket without
        # throwing.  Only treat this as cancellation when the short
        # read was caused by the cancellation callback closing the
        # socket.  If all nb bytes arrived, return them even if the
        # token was cancelled in the meantime (.NET semantics:
        # completed operations are not retroactively cancelled).
        if length(result) < nb && is_cancellation_requested(token)
            throw(OperationCanceledException(token))
        end
        return result
    catch ex
        if ex isa OperationCanceledException
            rethrow()
        end
        if is_cancellation_requested(token)
            throw(OperationCanceledException(token))
        end
        rethrow()
    finally
        close(reg)
    end
end

# ---------------------------------------------------------------------------
# Base.wait(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

"""
    wait(c::Channel, token::CancellationToken)

Wait for `c` to have data available, but throw
[`OperationCanceledException`](@ref) if `token` is cancelled first.

The channel remains usable after cancellation.

# Examples

```julia
ch = Channel{Int}(1)
src = CancellationTokenSource(5.0)    # 5 s timeout
wait(ch, get_token(src))              # throws after 5 s if no data
```
"""
@static if VERSION >= v"1.2"

function Base.wait(c::Channel, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    isready(c) && return

    cond = _channel_wait_cond(c)

    done = Threads.Atomic{Bool}(false)
    # Ref{Bool} rather than a plain Bool: a reassigned local captured by a
    # closure is boxed as Core.Box (typed Any), causing type instability.
    # Ref{Bool} is concretely typed and is never itself reassigned.
    completed = Ref(false)  # guarded by the channel's lock

    # Register a callback that enqueues channel notification work.
    # Running lock/notify directly inside cancel() can deadlock because
    # register callbacks are executed synchronously by cancel().
    reg = register(token) do
        if !Threads.atomic_xchg!(done, true)
            @_spawn begin
                lock(c)
                try
                    # Only notify if the main operation hasn't finished yet.
                    if !completed[]
                        notify(cond)
                    end
                finally
                    unlock(c)
                end
            end
        end
    end

    lock(c)
    try
        while !isready(c)
            Base.check_channel_state(c)
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            wait(cond)
        end
    finally
        # Set the completion flag while still holding the channel lock.
        # The async notification task acquires the same lock, so it will
        # either see completed==true and skip the notify, or it will
        # notify while we are still in wait(cond) (correct behaviour).
        completed[] = true
        unlock(c)
        # Deregister the callback to prevent notification after completion.
        close(reg)
        # Signal to the callback that it should not notify if it fires anyway.
        Threads.atomic_xchg!(done, true)
    end
    nothing
end

else # VERSION < v"1.2" — Channels use plain Condition with no lock.

function Base.wait(c::Channel, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    isready(c) && return

    cond = _channel_wait_cond(c)

    # Register a callback that notifies the condition to wake us up.
    # On Julia < 1.2 there is only cooperative scheduling (no threads),
    # so no lock/completed guard is needed.
    reg = register(token) do
        @_spawn notify(cond)
    end

    try
        while !isready(c)
            Base.check_channel_state(c)
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            wait(cond)
        end
    finally
        close(reg)
    end
    nothing
end

end # @static if VERSION >= v"1.2"

# ---------------------------------------------------------------------------
# Base.take!(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

"""
    take!(c::Channel, token::CancellationToken)

Remove and return a value from `c`, but throw
[`OperationCanceledException`](@ref) if `token` is cancelled while waiting
for data.

The channel remains usable after cancellation. Only buffered channels are
supported; unbuffered (size-0) channels will raise an error.

# Examples

```julia
ch = Channel{Int}(10)
src = CancellationTokenSource()
@async begin sleep(1); put!(ch, 42) end
take!(ch, get_token(src))  # returns 42
```
"""
function Base.take!(c::Channel, token::CancellationToken)
    if Base.isbuffered(c)
        _take_buffered_cancellable(c, token)
    else
        _take_unbuffered_cancellable(c, token)
    end
end

@static if VERSION >= v"1.2"

function _take_buffered_cancellable(c::Channel, token::CancellationToken)
    lock(c)
    try
        done = Threads.Atomic{Bool}(false)
        # Ref{Bool} rather than a plain Bool: a reassigned local captured
        # by a closure is boxed as Core.Box (typed Any), causing type
        # instability. Ref{Bool} is concretely typed and never reassigned.
        completed = Ref(false)  # guarded by the channel's lock

        # Register a callback that enqueues channel notification work.
        # Running lock/notify directly inside cancel() can deadlock because
        # register callbacks are executed synchronously by cancel().
        reg = register(token) do
            if !Threads.atomic_xchg!(done, true)
                @_spawn begin
                    lock(c)
                    try
                        # Only notify if the main operation hasn't finished yet.
                        if !completed[]
                            notify(c.cond_take)
                        end
                    finally
                        unlock(c)
                    end
                end
            end
        end

        try
            while isempty(c.data)
                is_cancellation_requested(token) && throw(OperationCanceledException(token))
                Base.check_channel_state(c)
                wait(c.cond_take)
            end
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            v = popfirst!(c.data)
            @static if isdefined(Base, :_increment_n_avail)
                Base._increment_n_avail(c, -1)
            end
            notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
            return v
        finally
            # Set the completion flag while still holding the channel lock.
            # The async notification task acquires the same lock, so
            # mutual exclusion is guaranteed.
            completed[] = true
            # Deregister the callback to prevent notification after completion.
            close(reg)
            # Signal to the callback that it should not notify if it fires anyway.
            Threads.atomic_xchg!(done, true)
        end
    finally
        unlock(c)
    end
end

else # VERSION < v"1.2" — Channels use plain Condition with no lock.

function _take_buffered_cancellable(c::Channel, token::CancellationToken)
    # Register a callback that notifies cond_take to wake us up.
    # On Julia < 1.2 there is only cooperative scheduling (no threads),
    # so no lock/completed guard is needed.
    reg = register(token) do
        @_spawn notify(c.cond_take)
    end

    try
        while isempty(c.data)
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            Base.check_channel_state(c)
            wait(c.cond_take)
        end
        is_cancellation_requested(token) && throw(OperationCanceledException(token))
        v = popfirst!(c.data)
        notify(c.cond_put, nothing, false, false)
        return v
    finally
        close(reg)
    end
end

end # @static if VERSION >= v"1.2"

# 0-size channel
function _take_unbuffered_cancellable(c::Channel{T}, token::CancellationToken) where T
    error("Cancellable take! on unbuffered channels is not yet implemented")
end
