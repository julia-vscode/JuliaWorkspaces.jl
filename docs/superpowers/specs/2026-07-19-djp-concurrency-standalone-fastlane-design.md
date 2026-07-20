# DJP reconcile concurrency + standalone-project fast lane — design

Perf-backlog item #2 (2026-07-18 doc). Two phases: **A** a concurrency cap on
dynamic-child launches (the thundering-herd fix), then **B2** a persistent
standalone-project fast lane with serve-stale + background refresh. The
test-environment fast lane (**C**) is explicitly out of scope (see Follow-ups).

## Problem

`handle!(df, ::ReconcileMsg)` dispatches every newly-required key immediately.
`WatchTestEnvironmentKey` and `CreateStandaloneProjectKey` work always spawns a
child Julia process (`Pkg.activate`+`TestEnv.activate` / `Pkg.develop`+`resolve`,
then `SymbolServer.get_store`); only `WatchEnvironmentKey` has a prep fast lane
(skip the child when all caches are present). The repro workspace produces 86
required keys → up to ~47 simultaneous child processes competing for CPU, disk,
and the depot. Additionally, standalone-project results live in the *child's*
tempdir (`mktempdir()`), so nothing is reusable across sessions — every LS
restart re-runs all 28 standalone resolves. (Today the tempdirs only outlive
the `DynamicIndexingOnly` child because `kill` skips Julia's atexit tempdir
cleanup — an accident, not a design.)

## Goals / non-goals

Goals:
- Bound the number of concurrently *working* dynamic children (setting-controlled).
- Make standalone projects restart-free when nothing changed: persistent,
  deterministic project dirs + a caches-present prep check; serve the stale env
  immediately and refresh it in the background through the capped queue.
- A setting that disables dynamic workspace resolution (standalone + test-env
  fabrication) entirely.

Non-goals:
- Test-environment persistence (C) — separate investigation (TestEnv owns its
  tempdir; manifest path fix-ups are the risk).
- Runtime reconfiguration of the workspace (settings stay constructor-time,
  matching `symbolcache_download` precedent).
- Capping the WatchEnvironment *prep* tasks (missing-check + cloud download) —
  they are IO-light and already fast-laned; only child launches are capped.

## Phase A — concurrency cap

### State (new fields on `DynamicFeature`)

- `max_concurrent_djps::Int` — constructor kwarg, threaded from
  `JuliaWorkspace(; max_concurrent_djps=4)`.
- `launch_queue::Vector{DJPKey}` — keys ready to launch but over the cap,
  drained in **priority order** (below), insertion order as the final tiebreak.
- `launching::Set{DJPKey}` — keys whose child is launched and whose work item
  has not reached a terminal message yet (the cap counts this set, *not*
  `df.procs`: persistent-mode children that finished indexing stay in `procs`
  but no longer occupy a slot).
- `launcher::Function` — defaults to `_launch_process!`; injectable so reactor
  tests observe launches without spawning processes (mirrors the
  `progress_callback` seam).

### Flow

The three launch sites (`EnvironmentPrepDoneMsg` when packages are missing,
`WatchTestEnvironmentMsg`, `CreateStandaloneProjectMsg`) call a new
`_request_launch!(df, key)` instead of constructing + launching directly:

```
_request_launch!(df, key):
    if length(df.launching) < df.max_concurrent_djps
        _launch_now!(df, key)          # construct DJP from key, launcher(df, djp)
    else
        push!(df.launch_queue, key)
        progress bar: "Queued (position N)..."
```

`_launch_now!` derives the `DynamicJuliaProcess` from the key type alone
(`WatchEnvironmentKey` → `:watch_environment`, etc.), so the queue stores bare
keys — no captured state to go stale.

### Launch priority

Environments higher up the directory tree resolve first, so a package's main
environment is ready before its test environment, `testdata` fixtures, nested
benchmark projects, etc.:

```
_launch_priority(key) = (path_depth(key), kind_rank(key))
```

- `path_depth`: number of segments of the key's normalized path
  (`project_path` for watch/test-env keys, `package_path` for standalone keys)
  — shallower launches first.
- `kind_rank` breaks ties at equal depth — relevant because a package's
  test-env key carries the *same* path as its main-env key:
  `WatchEnvironmentKey` (0) before `CreateStandaloneProjectKey` (1) before
  `WatchTestEnvironmentKey` (2).
- Insertion order is the final tiebreak (stable).

The priority applies everywhere launch order is decided: `ReconcileMsg`
dispatches newly-required keys sorted by `_launch_priority` (so the first
`cap` immediate launches are the shallowest ones, not Set-iteration-order
luck), and `_drain_launch_queue!` always picks the best-priority queued key
(O(n) scan; the queue is ≤ ~100 entries).

Slots free in exactly the places a work item reaches a terminal state with a
launched child: `ProcessIndexedMsg`, `ProcessIndexFailedMsg`,
`ProcessTerminatedMsg` (unexpected death), and the reconcile kill path. Each
removes the key from `launching` and calls `_drain_launch_queue!(df)`, which
launches best-priority-first while `length(launching) < cap`, skipping keys
that are no longer in `inflight` (killed/stale).

`ReconcileMsg` additionally purges no-longer-required keys from
`launch_queue` (balancing their accounting via `_complete_work_item!`, same as
the kill path — a queued key is inflight bookkeeping-wise).

### Invariants

- `launching ⊆ keys(procs)` at all times; `launch_queue ∩ launching = ∅`.
- Every key in `launch_queue` is also in `inflight` (its pending work item was
  registered at reconcile time; queueing does not affect `pending_count`, so
  `is_ready` still waits for queued work — required for correct readiness
  gating).
- A key never appears twice in the queue (reconcile's `known` check already
  guarantees dispatch-once; the queue inherits it).

### Setting

`julia.maxConcurrentIndexingProcesses` (number, default **4**, `0` = unlimited
to keep an escape hatch). Plumbing: VS Code config → `ConfigurationItem` fetch
in `init.jl`/`workspace.jl` → `server.max_concurrent_indexing_processes` →
`JuliaWorkspace(; max_concurrent_djps=...)` → `DynamicFeature` field. The
extension's `package.json` needs the setting declared (julia-vscode repo,
companion change; the LS default covers clients that don't).

## Phase B2 — standalone fast lane (serve stale + background refresh)

### Persistent project dirs

`_standalone_project_dir(df, key) =
joinpath(dirname(store_path), "standalone-projects",
"<basename(package_path)>-<first16hex(content_hash)>")`.

Content-hash keying means: package `Project.toml` changed → new dir → full
resolve; unchanged → same dir reused across sessions. Old-hash dirs for the
same package are deleted opportunistically when a new hash's dir is created
(bounded growth). The dir is created by the *parent* (`mkpath`) and passed to
the child.

### Protocol change

`CreateStandaloneProjectParams` gains `projectDir::String`. The child does
`Pkg.activate(params.projectDir)` instead of `mktempdir()` (develop + resolve +
`get_store` unchanged; the child continues to return
`dirname(Base.active_project())`). Parent and child ship from the same tree —
no version-skew concern.

### Fast lane + refresh flow

`handle!(df, ::CreateStandaloneProjectMsg)` becomes WatchEnvironment-shaped —
prep on an async task, decision back on the reactor:

```
prep task:
    dir = _standalone_project_dir(df, key)
    usable = isfile(dir/Project.toml) && isfile(dir/Manifest.toml)
    missing = usable ? _get_missing_packages(dir, store_path) : nothing
    (download missing caches if enabled, as WatchEnvironment does)
    put!(in_channel, StandaloneProjectPrepDoneMsg(key, usable && isempty(missing)))

reactor, StandaloneProjectPrepDoneMsg:
    if fast-lane hit:
        emit StandaloneProjectReadyResult(dir)     # serve stale immediately
        push!(done, key); _complete_work_item!     # readiness unblocked
        push!(refresh_queue, key)                  # background refresh
        _drain_launch_queue!(df)
    else:
        _request_launch!(df, key)                  # first-time / changed: as today
```

### Refresh semantics

- `refresh_queue::Vector{DJPKey}` + `refreshing::Set{DJPKey}` on
  `DynamicFeature`. `_drain_launch_queue!` serves `launch_queue` first;
  refreshes launch only into slots the primary queue doesn't want (strict
  priority), still bounded by the same cap.
- A refresh is **not** a work item: no `pending_count` increment (readiness
  must not wait on it), its own progress bar ("Refreshing environment…"), and
  the terminal handlers treat `key ∈ refreshing` separately from
  `key ∈ inflight`: on `ProcessIndexedMsg` re-emit
  `StandaloneProjectReadyResult(dir)` (same URI — idempotent for
  `input_standalone_projects`; freshness lands via the rewritten Manifest and
  the result path's package-cache loading), free the slot, kill the child under
  `DynamicIndexingOnly`. On failure: log, drop from `refreshing`, do **not**
  poison `failed_projects` (the served stale env keeps working).
- Reconcile purges `refresh_queue`/`refreshing` entries whose key is no longer
  required (kill the child if launched).

### Setting

`julia.enableWorkspaceEnvironmentResolution` (bool, default **true**; final
name to be confirmed). When `false`, `derived_required_dynamic_projects` emits
only `WatchEnvironmentKey`s — no standalone projects, no test environments.
Plumbed as `JuliaWorkspace(; resolve_workspace_environments=true)` → a Salsa
input (`input_resolve_workspace_environments`) read by
`derived_required_dynamic_projects`, so flipping it in a future
runtime-reconfig world invalidates correctly. Files needing an env that was
never resolved keep the current pre-DJP behavior (env-dependent diagnostics
gated off by `derived_file_env_ready`).

## Testing (TDD)

All reactor logic is testable synchronously via `handle!` with the injected
`launcher` recording launches (pattern: `test_progress.jl`). New
`test/test_dynamic_reconcile.jl`, written test-first:

Phase A:
1. Reconcile with N > cap keys → exactly `cap` launches; rest queued; progress
   shows queued state; `pending_count == N`.
2. `ProcessIndexedMsg` for a launched key → the best-priority queued key
   launches next.
2a. Priority ordering: a mixed reconcile (root project, nested test env,
   `testdata` fixture package) launches shallowest-first; at equal path depth
   the main env beats standalone beats test env; insertion order breaks
   remaining ties.
3. `ProcessIndexFailedMsg` / `ProcessTerminatedMsg` free slots identically.
4. Reconcile that drops queued keys → they never launch; accounting balanced
   (`pending_count` returns to 0 after all terminals).
5. `max_concurrent_djps = 0` → unlimited (all launch immediately).
6. WatchEnvironment fast-lane completions (`EnvironmentPrepDoneMsg` with
   nothing missing) never occupy a slot.

Phase B2:
7. Prep with existing dir + all caches present → ready result emitted, no
   launch, key lands in `refresh_queue`; refresh launches only when the
   primary queue is empty and a slot is free.
8. Prep with missing dir (or missing caches, downloads off) → normal capped
   launch; child receives the persistent `projectDir`.
9. Refresh completion re-emits the ready result and never touches
   `pending_count`; refresh failure leaves `done`/readiness intact and does
   not enter `failed_projects`.
10. Reconcile dropping a key purges it from `refresh_queue`/`refreshing`.
11. `resolve_workspace_environments = false` →
    `derived_required_dynamic_projects` contains only `WatchEnvironmentKey`s.
12. Dir naming: content-hash change → different dir; old dir cleaned up.

End-to-end (non-TDD validation): full JuliaWorkspaces + LanguageServer suites;
manual repro-workspace run observing capped process count and second-session
fast-lane hits. Any test that exercises real children must use a copied
depot/registry, never `~/.julia`.

## Follow-ups

- **C — test-env fast lane**: persist TestEnv's generated project the same way;
  requires controlling/copying its env dir and verifying manifest path
  portability. Own spec.
- Extension `package.json` declarations for both settings (julia-vscode repo).
- The cold-start item's `missing_pkg_metadata` drain (backlog #3) compounds
  with B2: fast-laned standalone envs load caches through the same path.
