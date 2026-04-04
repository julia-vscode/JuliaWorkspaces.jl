# Changelog

All notable changes to CancellationTokens.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-03-17

### Breaking

- Removed `is_cancellation_requested(::CancellationTokenSource)`. Use `is_cancellation_requested(get_token(src))` instead. The public API now consistently operates on tokens, not sources.
- Removed `register(callback, ::CancellationTokenSource)`. Use `register(callback, get_token(src))` instead.

### Added

- `Base.read(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::Integer, ::CancellationToken)` for cancellable fixed-byte socket reads (closes socket on cancellation, like `readline`).

### Changed

- Use `Threads.@spawn` instead of `@async` on Julia 1.3+ for internal async work in cancellation callbacks, avoiding task-pinning pitfalls.
- Improved type stability and added precompile directives for faster time-to-first-use.

### Fixed

- `MethodError` on Julia 1.0 and 1.1 when using cancellable `take!(::Channel, ...)` or `wait(::Channel, ...)`, caused by `lock(::Channel)` not existing before Julia 1.2. These methods now use a simpler cooperative-scheduling path on Julia < 1.2.
- Data race where cancellation callbacks could inject spurious notifications into shared channel condition variables after the main operation completes.
- Potential crash in cancellable `readline` on closed sockets.

## [1.2.1] - 2026-03-12

### Changed

- Improved robustness of cancellable `Base` overloads (`readline`, `wait(::Channel, ...)`, and `take!(::Channel, ...)`) by using callback registration that enqueues notifications asynchronously and deregisters callbacks on completion to avoid deadlock-prone cancellation paths.

## [1.2.0] - 2026-03-10

### Added

- `register(callback, token)` to register a callback that is invoked synchronously when `cancel` is called, matching .NET's `CancellationToken.Register(Action)`. If the token is already cancelled, the callback is invoked immediately.
- `CancellationTokenRegistration` struct returned by `register`, with `close(registration)` for deregistration (matching .NET's `CancellationTokenRegistration.Dispose()`).
- Expanded test suite for callback registration.

### Changed

- Combined `CancellationTokenSource(tokens...)` now uses synchronous callbacks (`register`) instead of spawning monitoring tasks (`Threads.@spawn`/`@async`). Cancellation propagation is now immediate and deterministic, and eliminates `InterruptException` errors from orphaned monitoring tasks.
- `CancellationTokenSource` struct now includes `_callbacks` and `_next_callback_id` fields for callback registration (internal; no public API change beyond the new `register` function).
- `_internal_notify` now invokes registered callbacks synchronously during cancellation, after notifying the event. Each callback is wrapped in `try/catch` so one failure does not prevent others from running.

### Fixed

- `InterruptException` in monitoring tasks spawned by `CancellationTokenSource(tokens...)`. These tasks had no error handling and could throw when interrupted during cleanup. Fixed by replacing task-based monitoring with synchronous callback registration.

## [1.1.1] - 2026-03-10

### Fixed

- Race condition in `wait(::CancellationToken)` where `cancel()` could fire between the `is_cancellation_requested` check and the `wait(event)` call, causing a hang. Fixed via double-check after event installation on Julia 1.7+ and lock-based atomic check on older versions.

## [1.1.0] - 2026-03-09

### Added

- `CancellationToken` is now an explicit export (previously usable but not exported).
- `Base.take!(::Channel, ::CancellationToken)` for cancellable channel take operations (buffered channels only).
- `Base.wait(::Channel, ::CancellationToken)` for cancellable channel wait operations.
- `Base.readline(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::CancellationToken)` for cancellable socket reads.
- `Base.close(::CancellationTokenSource)` as an alias for `cancel`, enabling `do`-block resource patterns.
- `WaitCanceledException` internal exception for clean task teardown in combined sources and cancellable operations.
- Thread safety via lock-free atomic (`@atomic`) operations on Julia 1.7+, matching .NET's `Interlocked.CompareExchange` pattern. Older Julia versions fall back to `ReentrantLock`.
- Lock-free `wait(::CancellationToken)` using CAS on Julia 1.7+ with double-check to prevent missed notifications.
- Documentation site via Documenter.jl with API reference, base method overloads, and usage guide.
- Thread-safety tests (`test_threads.jl`).
- Expanded test suite for base method overloads, channels, sockets, and core functionality.
- `Sockets` stdlib dependency for cancellable `readline`.

### Changed

- `CancellationTokenSource` struct now includes a `_lock::ReentrantLock` field (internal; no public API change).
- `_internal_notify` is now thread-safe, using CAS on Julia 1.7+ and lock-based state transitions on older versions.
- `_waithandle` / event creation uses CAS on Julia 1.7+ so multiple threads cannot create duplicate events.
- `Base.sleep(::Real, ::CancellationToken)` now uses `try/finally` to ensure the internal timer is always closed, and calls `cancel` for cleanup rather than checking `is_cancellation_requested` on the timer source.
- Timer constructor now calls `cancel(x)` (public API) instead of `_internal_notify(x)` directly.
- CI updated to use `TestItemRunner` workflow.

## [1.0.0] - 2021-07-11

### Added

- `CancellationTokenSource` for creating cancellation signal sources.
- `CancellationToken` lightweight immutable handle.
- `cancel(::CancellationTokenSource)` to signal cancellation.
- `get_token(::CancellationTokenSource)` to obtain tokens from a source.
- `get_token(::OperationCanceledException)` to retrieve the token from an exception.
- `is_cancellation_requested(::CancellationTokenSource)` and `is_cancellation_requested(::CancellationToken)` for non-blocking cancellation checks.
- `wait(::CancellationToken)` to block until cancellation.
- `OperationCanceledException` for signaling cancelled operations.
- `CancellationTokenSource(seconds::Real)` constructor for auto-cancellation after a timeout.
- `CancellationTokenSource(tokens::CancellationToken...)` constructor for combined/linked sources.
- `Base.sleep(::Real, ::CancellationToken)` for cancellable sleep.
- `Event` polyfill for Julia < 1.1.
- Support for Julia 1.0+.

[2.0.0]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.2.1...v2.0.0
[1.2.1]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/davidanthoff/CancellationTokens.jl/releases/tag/v1.0.0
