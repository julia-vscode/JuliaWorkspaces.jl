# Base Function Extensions

CancellationTokens.jl extends several Base functions with an additional
[`CancellationToken`](@ref) argument. These are **new method signatures** (different
arity), so they cause zero method invalidations.

## sleep

```julia
sleep(seconds, token)
```

```@docs
Base.sleep(::Real, ::CancellationTokens.CancellationToken)
```

## wait(::Channel)

```julia
wait(channel, token)
```

```@docs
Base.wait(::Channel, ::CancellationTokens.CancellationToken)
```

## take!(::Channel)

```julia
take!(channel, token)
```

```@docs
Base.take!(::Channel, ::CancellationTokens.CancellationToken)
```

## readline (sockets)

```julia
readline(socket, token; keep=false)
```

```@docs
Base.readline(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::CancellationTokens.CancellationToken)
```

## accept (sockets)

```julia
Sockets.accept(server, token)
Sockets.accept(server, client, token)
```

```@docs
Sockets.accept(::Sockets.TCPServer, ::CancellationTokens.CancellationToken)
Sockets.accept(::Sockets.PipeServer, ::CancellationTokens.CancellationToken)
Sockets.accept(::Sockets.TCPServer, ::Sockets.TCPSocket, ::CancellationTokens.CancellationToken)
Sockets.accept(::Sockets.PipeServer, ::Sockets.PipeEndpoint, ::CancellationTokens.CancellationToken)
```

## read (sockets)

```julia
read(socket, nb, token)
```

```@docs
Base.read(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::Integer, ::CancellationTokens.CancellationToken)
```

## readavailable

```julia
readavailable(socket, token)
readavailable(pipe, token)
```

```@docs
Base.readavailable(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::CancellationTokens.CancellationToken)
Base.readavailable(::Base.Pipe, ::CancellationTokens.CancellationToken)
```
