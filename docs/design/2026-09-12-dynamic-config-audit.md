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
| `max_concurrent_djps` | **do next** | Pattern 1, an exact `SetMaxAliveDjpsMsg` clone: make `DynamicFeature.max_concurrent_djps` a `RefValue{Int}`, add `SetMaxConcurrentDjpsMsg` whose handler sets the value and calls `_drain_launch_queue!` (raising the cap launches queued keys immediately; lowering it applies as slots free up — no child needs killing). Maps to the LS setting `julia.maxConcurrentIndexingProcesses`, currently stored but inert (`workspace.jl:178`). Highest-value follow-up. |
| `resolve_workspace_environments` | **do next** | Already a Salsa input (`input_resolve_workspace_environments`) consulted by `derived_required_dynamic_projects`; it only lacks a public setter. Pattern 2: `set_resolve_workspace_environments!` = `process_from_dynamic` → `set_input_…!` → `_reconcile!`. The reconcile itself starts/kills DJPs as the required set grows/shrinks, and prunes `done` for departing keys — on/off both work without extra reactor support. Maps to `julia.enableWorkspaceEnvironmentResolution`. |
| `symbolcache_download` | worth doing | Pattern 1: `download_enabled` is read only inside the environment-prep closure, so a `RefValue{Bool}` + message applies to every future prep. For *immediate* effect on environments already settled best-effort without caches, reuse the wholesale reset that `set_dynamic_mode!` does on an Off→on upgrade (clear `done` + failure bookkeeping + force a reconcile). Maps to `julia.symbolCacheDownload`. |
| `symbolcache_upstream` | worth doing | Same shape as `symbolcache_download` (`upstream_url`, read in the same closure); the two should share one message. Maps to `julia.symbolserverUpstream`. |
| `max_failure_attempts` | cheap, low value | Pattern 1; read at exhaustion checks and the two failure handlers. No lifecycle enforcement needed — the new bound simply applies to future failures. No LS setting maps to it today. |
| `djp_request_timeout_seconds` | cheap, low value | Pattern 1; read per index request, so a new value applies to future requests. No LS setting maps to it today. |
| `store_path` | **keep construction-only** | The store path is baked into every loaded `input_package_metadata` entry, the `loaded_pkg_metadata`/`missing_pkg_metadata` bookkeeping, and every child's cache paths. Changing it means flushing all symbol state — that is restart territory, and no host wants it hot. |
| `progress_callback` | keep construction-only | Read from both the reactor and host tasks; hosts set it once at startup and no user setting maps to it. |
| `indirect_file_watch_callback` | keep construction-only | Immutable inside `SContext` inside the Salsa runtime; same reasoning. |

## LanguageServer wiring (separate PR, after the JW side lands)

Today `request_julia_config` (LanguageServer `src/requests/workspace.jl:147-180`)
re-fetches all nine `julia.*` settings on `workspace/didChangeConfiguration`
and stores them on the server, but explicitly does not reconfigure the running
`JuliaWorkspace` ("future work"). The plan:

- `julia.enableDynamicIndexing` → on change, call
  `JuliaWorkspaces.set_dynamic_mode!(server.workspace, enabled ? DynamicIndexingOnly : DynamicOff)`.
- `julia.maxConcurrentIndexingProcesses` → `set_max_concurrent_djps!` (once it
  exists).
- `julia.enableWorkspaceEnvironmentResolution` →
  `set_resolve_workspace_environments!` (once it exists).
- `julia.symbolCacheDownload` / `julia.symbolserverUpstream` → the symbolcache
  setters (once they exist).

Only call the setters when the value actually changed (compare against
`get_dynamic_mode` / the stored server fields) — every setter is a cheap no-op
for an unchanged value, but skipping avoids reconcile churn on unrelated
config updates. The existing `julia/setEnvironmentPath` →
`set_active_project!` notification path (`workspace.jl:129-145`) is the
template for how a pushed change flows into a live workspace.
