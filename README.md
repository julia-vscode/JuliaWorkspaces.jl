# CancellationTokens.jl

[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://davidanthoff.github.io/CancellationTokens.jl/)
[![Julia CI](https://github.com/davidanthoff/CancellationTokens.jl/actions/workflows/juliaci.yml/badge.svg)](https://github.com/davidanthoff/CancellationTokens.jl/actions/workflows/juliaci.yml)
[![codecov](https://codecov.io/gh/davidanthoff/CancellationTokens.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/davidanthoff/CancellationTokens.jl)

A Julia implementation of .NET's [Cancellation Framework](https://devblogs.microsoft.com/pfxteam/net-4-cancellation-framework/) for cooperative cancellation of asynchronous and long-running operations. See also the [.NET documentation](https://docs.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads).

Thread-safe on all Julia versions: Julia 1.7+ uses lock-free atomic operations; older versions fall back to `ReentrantLock`.

## Quick Start

```julia
using CancellationTokens

# Create a source and hand out a token
src = CancellationTokenSource()
token = get_token(src)

# Cancel after 1 second from another task
@async begin
    sleep(1)
    cancel(src)
end

# Cancellable sleep — throws OperationCanceledException when cancelled
try
    sleep(60.0, token)
catch e::OperationCanceledException
    println("Operation was cancelled!")
end
```

## Cancellable Operations

The package extends several Base functions to accept a `CancellationToken` as the last argument:

- `sleep(seconds, token)` — cancellable sleep
- `wait(channel, token)` — wait for data on a `Channel`
- `take!(channel, token)` — take from a buffered `Channel`
- `readline(socket, token)` — read a line from a `TCPSocket` or `PipeEndpoint`
- `read(socket, nb, token)` — read `nb` bytes from a `TCPSocket` or `PipeEndpoint`

All of these throw an `OperationCanceledException` if the token is cancelled before the operation completes.

## Timeout and Combined Sources

```julia
# Auto-cancel after 5 seconds
src = CancellationTokenSource(5.0)

# Cancel when any parent token fires
combined = CancellationTokenSource(get_token(src1), get_token(src2))
```
