# Runtime-changeable configuration: audit and plan

*2026-09-12. Companion to the change that made the dynamic mode a runtime-
switchable Salsa input (`set_dynamic_mode!`).*

Every `JuliaWorkspace` constructor keyword is a candidate for becoming
changeable at runtime, so that hosts (in particular the LanguageServer) can
apply configuration changes without a restart. This document classifies each
one and sketches the implementation for the ones worth doing.

Two established patterns cover everything below:

1. **Reactor-owned knob** (`set_max_alive_djps!`, `set_v2_enabled!`,
   `set_dynamic_mode!`): store the value in a `Base.RefValue` field of
   `DynamicFeature`, mutate it only inside a reactor `handle!` for a dedicated
   message, and post that message from a public `set_*!` function *before*
   calling `_reconcile!` so the next reconcile runs under the new rules.
   Add a Salsa input alongside when the host (or a future derived query)
   needs to read the value back.
2. **Salsa-input knob** (`set_active_project!`, `set_macro_expansion!`):
   `process_from_dynamic` → `set_input_*!` → `_reconcile!`. Sufficient when
   the value is only read by derived queries and the reconcile itself
   enforces the consequences.

## Classification

| Constructor kwarg | Verdict | Notes |
|---|---|---|
| `dynamic` | **done** | `set_dynamic_mode!` / `get_dynamic_mode`, this change. |
| `max_alive_djps` | **done** (pre-existing) | `set_max_alive_djps!`. The LS never calls it yet. |
| `max_concurrent_djps` | **done** | `set_max_concurrent_djps!` → `SetMaxConcurrentDjpsMsg`; the handler sets the `RefValue` and calls `_drain_launch_queue!` (raising the cap launches queued keys immediately; lowering it applies as slots free up — no child needs killing). Maps to the LS setting `julia.maxConcurrentIndexingProcesses`. |
| `resolve_workspace_environments` | **done** | `set_resolve_workspace_environments!`, pattern 2 (input + reconcile; the reconcile itself starts/kills DJPs and prunes `done` for departing keys). Enabling additionally forces the reconcile through and un-settles readiness (see decisions below). Also now forwarded by `workspace_from_folders`, which had missed it. Maps to `julia.enableWorkspaceEnvironmentResolution`. |
| `symbolcache_download` | **done** | `set_symbolcache!(jw; download, upstream)` — one setter and one `SetSymbolcacheMsg` for both values (they are read at a single prep site and change in one config event). Maps to `julia.symbolCacheDownload`. |
| `symbolcache_upstream` | **done** | Covered by `set_symbolcache!` (see above). Maps to `julia.symbolserverUpstream`. |
| `max_failure_attempts` | **done** | `set_max_failure_attempts!` → `SetMaxFailureAttemptsMsg`; applies at the next exhaustion check, no lifecycle enforcement. No LS setting maps to it today. |
| `djp_request_timeout_seconds` | **done** | `set_djp_request_timeout!` → `SetDjpRequestTimeoutMsg`; read per index request, so it applies to the next request. No LS setting maps to it today. |
| `store_path` | **keep construction-only** | The store path is baked into every loaded `input_package_metadata` entry, the `loaded_pkg_metadata`/`missing_pkg_metadata` bookkeeping, and every child's cache paths. Changing it means flushing all symbol state — that is restart territory, and no host wants it hot. |
| `progress_callback` | keep construction-only | Read from both the reactor and host tasks; hosts set it once at startup and no user setting maps to it. |
| `indirect_file_watch_callback` | keep construction-only | Immutable inside `SContext` inside the Salsa runtime; same reasoning. |

## Decisions recorded with the setters change

- **One symbolcache setter, one message.** `set_symbolcache!(jw; download,
  upstream)` with `nothing` meaning "unchanged": both values are read at a
  single prep site, hosts change them in one config event, and one message
  means one atomic re-prep decision instead of two racing ones.
- **Selective symbolcache re-prep, not the wholesale reset** this document
  originally sketched. When downloads become newly effective (off→on, or a
  new upstream while on), the handler drops only `done ∩ WatchEnvironmentKey`
  — the one key kind whose prep downloads. The wholesale Off→on-style reset
  would respawn scratch/test children whose prep never downloads and forgive
  real failures. Failure bookkeeping is kept in all cases;
  `retry_failed_dynamic_projects!` stays the lever.
- **Readiness un-settles on enable** for `set_resolve_workspace_environments!`
  and the effective-download flip of `set_symbolcache!`: `is_ready` reads
  `saw_result`/`pending_count`, which only the reactor updates, so between
  the host's `_reconcile!` and the reactor's `handle!` it would report a
  stale `true` — the exact window `set_dynamic_mode!` closes on its Off→on
  upgrade. The forced reconcile (`empty!(last_required)` +
  `reconciled_once=false`) and `saw_result=false` travel together: the reset
  alone would deadlock `wait_until_ready` on a workspace where the required
  set does not change, since nothing would re-settle readiness. Disabling
  directions need neither.
- **Idempotence guards** on every new handler (the `SetV2LifecycleMsg`
  style); `SetMaxAliveDjpsMsg` keeps its guard-free shape (its body is
  idempotent) rather than being retrofitted.
- **`set_djp_request_timeout!`** drops the `_seconds` suffix of its kwarg;
  the unit lives in the argument name and docstring, which cross-reference
  the `djp_request_timeout_seconds` constructor kwarg.

## LanguageServer wiring (separate PR, after the JW side lands)

Today `request_julia_config` (LanguageServer `src/requests/workspace.jl:147-180`)
re-fetches all nine `julia.*` settings on `workspace/didChangeConfiguration`
and stores them on the server, but explicitly does not reconfigure the running
`JuliaWorkspace` ("future work"). The plan:

- `julia.enableDynamicIndexing` → on change, call
  `JuliaWorkspaces.set_dynamic_mode!(server.workspace, enabled ? DynamicIndexingOnly : DynamicOff)`.
- `julia.maxConcurrentIndexingProcesses` → `set_max_concurrent_djps!`.
- `julia.enableWorkspaceEnvironmentResolution` →
  `set_resolve_workspace_environments!`.
- `julia.symbolCacheDownload` / `julia.symbolserverUpstream` → a *single*
  `set_symbolcache!(server.workspace; download=..., upstream=...)` call per
  config event.

`set_dynamic_mode!`, `set_resolve_workspace_environments!` and
`set_symbolcache!` early-return on unchanged values themselves, so calling
them unconditionally is safe; for the message-posting setters
(`set_max_concurrent_djps!`, `set_max_failure_attempts!`,
`set_djp_request_timeout!`) the unchanged-value guard lives reactor-side and
merely skips work, so comparing against the stored server fields before
calling only saves a queued message. The existing `julia/setEnvironmentPath`
→ `set_active_project!` notification path (`workspace.jl:129-145`) is the
template for how a pushed change flows into a live workspace.
