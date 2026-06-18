# API Reference

## Types

```@docs
CancellationTokenSource
CancellationToken
CancellationTokenRegistration
OperationCanceledException
```

## Functions

```@docs
cancel
get_token
is_cancellation_requested
register
Base.wait(::CancellationTokens.CancellationToken)
Base.close(::CancellationTokens.CancellationTokenSource)
Base.close(::CancellationTokens.CancellationTokenRegistration)
```
