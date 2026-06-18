# CancellationTokens.jl

```@docs
CancellationTokens
```

A Julia implementation of [.NET's cancellation framework](https://docs.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads) for cooperative cancellation of asynchronous and long-running operations.

## Overview

The package follows .NET's design:

1. Create a [`CancellationTokenSource`](@ref).
2. Obtain a [`CancellationToken`](@ref) with [`get_token`](@ref).
3. Pass the token to cancellable operations as the **last positional argument**.
4. Optionally [`register`](@ref) callbacks to run synchronously on cancellation.
5. Call [`cancel`](@ref) on the source when the operation should stop.
6. Operations throw an [`OperationCanceledException`](@ref) on cancellation.

```julia
using CancellationTokens

src = CancellationTokenSource()
token = get_token(src)

# Start a long-running operation in a task
t = @async begin
    try
        sleep(60.0, token)   # cancellable sleep
        println("Completed")
    catch ex
        if ex isa OperationCanceledException
            println("Cancelled!")
        end
    end
end

sleep(1.0)
cancel(src)   # the task prints "Cancelled!"
```

## Thread Safety

CancellationTokens.jl is thread-safe on all supported Julia versions:

- **Julia 1.7+**: Lock-free atomic operations (`@atomic`, `@atomicreplace`) matching .NET's `Interlocked.CompareExchange` and `volatile` patterns.
- **Julia < 1.7**: Falls back to `ReentrantLock` for safe concurrent access.

`cancel`, `is_cancellation_requested`, `wait`, and all cancellable Base function extensions are safe to call from any thread.

## Supported Julia Versions

The package supports Julia 1.0 and later, using version-specific optimisations behind `@static if VERSION` checks where beneficial.
