# Performance — remaining work (2026-07-18)

Follow-up backlog after the inventories refactor + the reverse-include-map/kind-index/cross-root-memoization work. Ordered by impact. Numbers are from the repro workspace `/home/pfitzseb/git/JuliaWorkspaces.jl` (792 text files / 544 Julia files / 215 roots / 39 projects), dynamic analysis OFF, unless noted.

## Already handled (context — don't redo)
- **Per-edit re-analysis** is now one file, ~7 ms (was a 0.9–3.4 s full-workspace relint). Body edit in a sibling ⇒ 0 re-executions elsewhere (per-file analysis firewall).
- **`get_diagnostics` sweep**: 455 → **67 ms** warm via `derived_reverse_include_map` (inverted include graph; dependency edges 338k → 58k, `derived_roots_for_uri` 539 → 2 deps/file).
- **`derived_module_names`** O(n²) `_declared_item_kind` scan → per-file kind index (module-names sweep 22.7 → 4.6 ms).
- **Cross-root visibility** memoized (a shared package's visible names computed once, not per consuming module per revision), cycle-guard preserved.
- **Salsa trace-pool** poisoning fixed (fast-path memoized_lookup ~3.8 µs → ~0.5–0.7 µs).
- **Cross-package method double/triple counting** in `iterate_over_ss_methods` de-duped (was up to 3× for `rand` with `using Random`).
- **Workspace symbols** re-expressed directly over inventories (no whole-root static-lint pass per file) — killed a many-env sweep pain point.

---

## 1. LS-side per-keystroke sweep — the debounce  *(highest impact; parked, ready to port)*

Everything JuliaWorkspaces-side is fast now, but the **LanguageServer package still runs a full-workspace diagnostics/testitem sweep twice per `didChange`**, synchronously on the serial dispatch loop.

Flow (`LanguageServer/src/requests/textdocument.jl` — `didOpen`:4, `didClose`:37, `didChange`:90):
1. `mark_current_diagnostics_testitems(jw)` — snapshots hashes of **every** file's diagnostics+testitems (before the edit).
2. edit applied.
3. `publish_diagnostics_testitems(...)` → `get_files_with_updated_diagnostics_testitems(jw)` — snapshots **again** and diffs to find which files changed.

Each of mark and diff calls `get_diagnostics(jw)` + `get_test_items(jw)` over all files (`testitem_diagnostic_marking.jl:2,4,11,30`). Other sweep sites: `languageserverinstance.jl:404`, `workspace.jl:187`.

Cost breakdown (measured):
- `get_diagnostics(jw)` warm post-edit sweep: **~67 ms** (was ~455 ms pre reverse-include-map). It's pure Salsa **verification** of `derived_all_diagnostics`' 793 deps (all per-file `derived_diagnostics`), each walking the static-lint subtree; nothing recomputes except the edited file.
- `get_test_items(jw)`: **~5 ms** (shallow syntax-level deps).
- The **mark** (before-snapshot) usually hits the memoized floor (~0.02 ms) because the revision hasn't advanced since the last publish — so effective cost is ~1 sweep/keystroke. BUT with dynamic analysis ON, background work (`process_from_dynamic`, watched-file reconciles) can advance the revision between keystrokes, making the mark pay a full sweep too.

Why it's redundant: the mark re-derives the before-state the LS *already published* last keystroke.

**Fix: port the parked LanguageServer commit `d83bcc2` (`sp/perf`).** Persistent `server._published_hashes` replaces the mark/diff double-sweep; `didChange` publishes only the edited file immediately and schedules a debounced `:publish_sweep` queue message (`SWEEP_DEBOUNCE_SECONDS`=0.4 trailing, `SWEEP_MAX_LATENCY_SECONDS`=3.0 cap, generation counter for staleness, drain guard re-enqueues behind queued messages). Watcher reconcile stays synchronous in `didOpen`/`didClose` (`test_indirect_files` depends on it). `jr_endpoint` widened to `Any` so tests inject a recording endpoint. Tests in `test/test_publish_debounce.jl`.

Notes: this is a **LanguageServer.jl change** (the inventories work deliberately left LS.jl unmodified), independent of the inventories work and separately mergeable to main. The `get_diagnostics` it wraps is now the fast new engine, so the debounce + reverse-map compound. Decide via measured end-to-end keystroke latency whether 67 ms/sweep already suffices or the debounce is worth it.

## 2. `derived_environment` per-project `recursive_copy`  *(biggest memory item; needs fresh work)*

`derived_environment` (`src/layer_environment.jl`) does `SymbolServer.recursive_copy(stdlibs)` **per project**: ~19 MiB / ~37 ms each → **~740 MiB across 39 projects**, ~**1.46 GiB** retained after one sweep (DynamicOff).

Two problems:
- **Memory**: N deep copies of the (large, immutable) baked stdlibs store.
- **No backdating**: the fresh copy defeats `isequal` (identity), so `derived_environment` never back-dates even when the resolved env is structurally unchanged — which is why the whole per-file analysis layer had to extract *plain data* from env rather than depend on the env value.

Fix directions: layer the small per-project package/dep overlay **on top of a shared immutable stdlibs base** instead of copying the whole store; or give the env a content-version stamp so `isequal` is O(1) and back-dates. See the "store the minimal plain-data fingerprint" note in `AGENTS.md` for why sharing beats copying here.

## 3. DJP reconcile concurrency  *(startup cost in many-env workspaces; needs fresh work)*

`derived_required_dynamic_projects` = **86** items in the repro (39 `WatchEnvironment` / 19 `WatchTestEnvironment` / 28 `CreateStandaloneProject`, incl. testdata, packages-old, environments/v1.0–v1.13). The `ReconcileMsg` handler dispatches them **all at once, with no concurrency cap**, and only `WatchEnvironment` has a caches-present fast-lane — test-env/standalone entries always spawn a child Julia doing `Pkg.develop`/`resolve`/`TestEnv.activate` + `SymbolServer.get_store`. Dominates startup/reconcile in big multi-env workspaces.

Fix: a concurrency cap on the reconcile dispatch + extend the caches-present fast-lane to test-env/standalone (not just `WatchEnvironment`).

## 4. Targeted follow-ups  *(lower impact)*

- **Reverse-*import* index for find-references.** `each_reference` (`src/layer_references.jl`) scans **all** roots (`derived_roots(rt)`) because `derived_roots_for_uri` follows `include` only and misses `import`-consuming deved-package roots. Cold references = **4.86 s** (one-time `derived_file_analysis` warming of the whole workspace, shared with diagnostics); warm ~3 ms, walk-only ~6 ms. A reverse-import map (analog to `derived_reverse_include_map`) mapping imported-package → consuming-roots would scope the walk to relevant roots. It's a *cold* cost, not per-keystroke → lower priority. Do NOT cache the aggregation in an ItemRef-keyed / whole-root-keyed derived value (volatile by design).
- **`hash(::DerivedKey)`** (`Salsa/src/dependency_keys.jl`) calls `string(F)` per hash (~1 µs / 496 B), on the Set-based dep-dedup path during recomputation. Hash by the type object / cache the string.

## Not a runtime perf item
Milestone 5 (deleting the old whole-closure pass: `derived_static_lint_meta_for_root` and everything under it) is **code hygiene** — that pass is already *dead* (zero live callers, verified; not in the executed Salsa graph), so removing it doesn't change runtime cost, only precompile/source footprint.

## Measurement tooling
`benchmark/interactive_latency.jl` (parked on the `sp/perf` JuliaWorkspaces branch; port if useful) drives a workspace, does a body edit, and reports re-execution counts + warm/cold sweep times — works on any package/workspace. Re-execution counting via `Salsa.TraceLogging` + a `CountReceiver`; dependency-edge stats by iterating `rt.storage.derived_function_maps` and summing `.dependencies`; which dep invalidated a node via comparing `changed_at` to `current_revision`.
