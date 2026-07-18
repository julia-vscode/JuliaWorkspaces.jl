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
- **Completion store sweep**: measured, deemed acceptable, and the real bug fixed instead. The per-keystroke Base+Core (+ per-`using`-ed-package) sweep costs ~3.4 ms/store warm (~5–15 ms/keystroke worst case) — well below perception, so the sorted prefix index and matcher rewrite were **rejected as unnecessary**. The actual defect: the fuzzy branch of `is_completion_match` never fired (`REPL.fuzzyscore` is normalized to [0,1], cutoff was 3) — cutoff is now `_FUZZY_MATCH_CUTOFF = 0.6` (real typos score ≥ 0.75; noise ≤ ~7 items/store, ranked at the bottom via `_match_rank`), so completions gained working typo tolerance at zero added cost. Escalation path if GC pressure from the ~10k `String(::Symbol)`+`lowercase` allocs/store ever shows in profiles: cache a per-store name vector (`IdDict{ModuleStore,Vector{String}}`), not the full index.

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

## 2. Salsa verification fast path — cut the per-dep constant factor  *(same 67 ms sweep as #1, attacked from the cost side)*

`still_valid` checks each dep via `key_changed_at` → the full public `memoized_lookup` (`Salsa/src/default_storage.jl:334-346`). Each of the ~800+ dep-checks per sweep pays, instead of a dict lookup + revision compare:
- a trace-pool acquire/release (`new_trace_runtime!`/`destruct_trace!`, incl. a trace-lock in `empty_trace!`);
- the **global `storage.lock` taken twice** — once at `default_storage.jl:191`, again reentrantly inside `get_map_for_key` (`:109`);
- shared-atomic ops on `derived_functions_active` (cache-line bouncing);
- a `haskey` + `getindex` **double hash-probe** of the args tuple (`:196`/`:206`) — string keys, so the URI is hashed twice per node.

Fix: a dedicated lightweight "changed_at" lookup that takes the lock once per verification walk (or goes lock-free using the existing `derived_functions_active == 0` invariant relied on at `:211-218`), no trace, single `get`. Should cut per-node cost several-fold and compounds with the #1 debounce the same way the reverse-include-map did. Cheap standalone wins on the same path: `haskey`+`getindex` → `get` everywhere hot; the backdating `isequal` at `:275` structurally compares entire aggregated values (e.g. the 792-entry `derived_all_diagnostics` Dict is rebuilt **and fully compared** whenever the aggregator recomputes). Note the global lock also serializes concurrent requests entirely.

## 3. `derived_environment` per-project `recursive_copy`  *(biggest memory item; needs fresh work)*

`derived_environment` (`src/layer_environment.jl`) does `SymbolServer.recursive_copy(stdlibs)` **per project**: ~19 MiB / ~37 ms each → **~740 MiB across 39 projects**, ~**1.46 GiB** retained after one sweep (DynamicOff).

Two problems:
- **Memory**: N deep copies of the (large, immutable) baked stdlibs store.
- **No backdating**: the fresh copy defeats `isequal` (identity), so `derived_environment` never back-dates even when the resolved env is structurally unchanged — which is why the whole per-file analysis layer had to extract *plain data* from env rather than depend on the env value.

Fix directions: layer the small per-project package/dep overlay **on top of a shared immutable stdlibs base** instead of copying the whole store; or give the env a content-version stamp so `isequal` is O(1) and back-dates. See the "store the minimal plain-data fingerprint" note in `AGENTS.md` for why sharing beats copying here.

Also part of this item:
- each per-project env additionally pays a full-store `collect_extended_methods(new_store)` walk (`src/layer_environment.jl:98`) — a shared-base design should share that too;
- the `project === nothing` fallback *inside* `derived_environment` (`src/layer_environment.jl:63`) makes a fresh stdlib copy instead of reusing the memoized `derived_stdlib_only_env(rt)` — a stray ~19 MiB per non-project key (callers already guard the `project_uri === nothing` case correctly).

## 4. DJP reconcile concurrency  *(startup cost in many-env workspaces; needs fresh work)*

`derived_required_dynamic_projects` = **86** items in the repro (39 `WatchEnvironment` / 19 `WatchTestEnvironment` / 28 `CreateStandaloneProject`, incl. testdata, packages-old, environments/v1.0–v1.13). The `ReconcileMsg` handler dispatches them **all at once, with no concurrency cap**, and only `WatchEnvironment` has a caches-present fast-lane — test-env/standalone entries always spawn a child Julia doing `Pkg.develop`/`resolve`/`TestEnv.activate` + `SymbolServer.get_store`. Dominates startup/reconcile in big multi-env workspaces.

Fix: a concurrency cap on the reconcile dispatch + extend the caches-present fast-lane to test-env/standalone (not just `WatchEnvironment`).

## 5. Cold start beyond the DJP herd  *(startup latency; mix of JW + LS.jl fixes)*

The DJP thundering herd (#4) is only one of the cold-start costs. The startup spine: `initialized_notification` (LS `src/requests/init.jl:189-323`) runs synchronously on the single dispatch loop — read all files (`:293`), batched `add_files!` (`:312`), a second folder walk (`:316-318`), then `publish_diagnostics_testitems` (`:322`). Everything below blocks the first interactive response. Ranked:

- **Package symbol caches re-deserialized N×.** `_load_missing_package_metadata!` (`src/types.jl:441-462`) iterates the entire `missing_pkg_metadata` set — which is **never drained** — once per `EnvironmentReadyResult` (`types.jl:502`), i.e. up to 39×. After project 1 loads its caches, project 2's env-ready re-reads them all again, etc. → O(projects × cumulative-missing-packages) synchronous `CacheStore.read` of multi-MB `.jstore` files on the consumer task. `_load_package_caches_for_project!` (`types.jl:404-430`, test-env/standalone paths `:520`/`:533`) has the same shape: no already-loaded guard, so shared deps are re-read per project. Each redundant `set_input_package_metadata!` additionally pays Salsa's deep structural `isequal` against the cached store (`Salsa/src/default_storage.jl:457-462`). Salsa itself dedups fine (input keyed by name/uuid/version/tree-sha) — the waste is entirely the redundant reads. Fix: drain `missing_pkg_metadata` after a successful load; skip packages whose input is already populated; do the reads off the dispatch loop.
- **Initial full-workspace lint runs synchronously on the dispatch loop.** `init.jl:322` → `get_diagnostics(jw)` + `get_test_items(jw)` cold = the ~4.9 s full static-lint of all 544 files, inside one `dispatch_msg` — queued didOpen/completion wait the whole time. The `env_ready` gate (`layer_diagnostics.jl:150-155`) only *filters emission*; `derived_new_static_lint_diagnostics` runs regardless. The `yield()` per file lets the reactor run but not other client requests (single-threaded dispatch). Fix: compute the initial sweep on a worker task and enqueue publishes / return from `initialized_notification` first; prefer the pull-diagnostics path where the client supports it.
- **Every finished progress bar triggers a full republish.** `progress.jl:55-58` enqueues `:jw_indexing_complete` whenever any progress key hits 100% — ~80+ events for 39 projects (download/index/test-env/package-caches bars). For clients without `workspace/diagnostic/refreshSupport`, each event (`languageserverinstance.jl:400-408`) re-derives `get_diagnostics` and re-sends diagnostics for **all** files → O(events × files) work + JSON-RPC traffic during the same window the caches are churning. Refresh-capable clients get a single `workspace/diagnosticRefresh` (fine). Fix: coalesce/debounce the events; publish only changed URIs (reuse `get_files_with_updated_diagnostics_testitems`).
- **The workspace tree is walked 3× at init.** Per folder: `read_path_into_textdocuments` (`fileio.jl:109-142` — `walkdir` + `read` of all 792 files, **no `yield()`**), `has_too_many_files` (`init.jl:62-83`, full `walkdir` count), and `load_folder` (`init.jl:107-122`, another `walkdir` for `server._workspace_files`), plus per-level `readdir` in `isjuliabasedir`. Painful on cold/network filesystems. Fix: one walk feeding all three consumers; yield during content reads.
- **No precompile workload.** `LanguageServer/src/precompile.jl:5-19` has the `@compile_workload` commented out ("starts background tasks"); only `precompile(runserver, ())` remains, so first-request JIT sits on top of everything above. A `DynamicOff` in-memory workspace driven through parse → semantic pass → completions/hover would precompile the hot paths without spawning tasks.

## 6. Double full-file parse per keystroke  *(per-keystroke floor for the edited file)*

Each `didChange` fully reparses the edited file **twice**: JuliaSyntax (`src/layer_syntax_trees.jl:1`, for syntax diagnostics + testitems) and CSTParser (`:44`, the legacy tree that inventory/module-tree/file-analysis consume). Correctly firewalled to the edited file only, but it's the true per-keystroke floor. Unifying on one tree — e.g. deriving the legacy tree from the JuliaSyntax one via the converter — halves it; incremental reparse is the long-term answer but a much bigger project.

## 7. Salsa never evicts stale derived keys  *(memory; slow leak over session churn)*

`delete_input!` (`Salsa/src/default_storage.jl:464-481`) removes the input entry, but derived values keyed by dead URIs stay in `derived_function_maps` forever — memory grows with files touched over the session (open/close/rename churn), not instantaneous workspace size. Old *revisions* are fine (`DerivedValue` is mutated in place, no value history). Fix: periodic sweep dropping derived entries whose args reference no live input. Related: `inputs_map` stores abstract `InputValue` (boxed, type-unstable access; `default_storage.jl:76`, and the `InputMapType` alias at `:53` doesn't match the field type).

## 8. Targeted follow-ups  *(lower impact)*

- **Reverse-*import* index for find-references.** `each_reference` (`src/layer_references.jl`) scans **all** roots (`derived_roots(rt)`) because `derived_roots_for_uri` follows `include` only and misses `import`-consuming deved-package roots. Cold references = **4.86 s** (one-time `derived_file_analysis` warming of the whole workspace, shared with diagnostics); warm ~3 ms, walk-only ~6 ms. A reverse-import map (analog to `derived_reverse_include_map`) mapping imported-package → consuming-roots would scope the walk to relevant roots. It's a *cold* cost, not per-keystroke → lower priority. Do NOT cache the aggregation in an ItemRef-keyed / whole-root-keyed derived value (volatile by design).
- **`hash(::DerivedKey)`** (`Salsa/src/dependency_keys.jl`) calls `string(F)` per hash (~1 µs / 496 B), on the Set-based dep-dedup path during recomputation. Hash by the type object / cache the string. Verified it does **not** fire on the verification path (derived caches are keyed by the args *tuple*) — only on the recompute dedup-Set (`push_key!`, `Salsa/src/trace.jl:62-75`, which also takes a per-dep trace lock) and `InputKey` map lookups.
- **Doc-word search** (`src/layer_hover.jl:881-927`) walks every symbol of every env with 2× `lowercase` + `REPL.levenshtein` per symbol — multi-second on the repro workspace, but an explicit action, not per-keystroke. An index or cheaper prefilter would fix it.
- **`position_at`** (`src/types.jl:230`) has a `# TODO` reverse linear scan over `line_indices` — O(lines) per offset→Position conversion, paid per reported range at request time. Binary search.
- **`RT = Any` for all derived returns** (`Salsa/src/default_storage.jl:172`, `derived_macro.jl:108`): every `@derived` call returns `Any` (dynamic dispatch + boxing everywhere, including the hot valid path). Deliberate workaround for a compiler hang — re-test whether current Julia still hangs with `::RT` restored.

## Confirmed fine (scanned, don't chase)
- The per-file analysis firewall genuinely stops *verification*, not just re-execution: a sibling body edit doesn't even re-execute the module tree; top-level edits backdate at the id-free projections (`derived_module_visible_names_idfree` etc.). Residual by-design cost: a top-level edit re-executes `derived_module_tree` per containing root and pays a whole-`ModuleTree` structural compare.
- Workspace symbols (`src/layer_symbols.jl:281`): all-files loop but memoized per-file fetches + cheap `startswith` — fine.
- Signature help: bounded to the one resolved callee's method items — no store sweep.
- Trace-pool freelist / `@trace` spans: zero-cost when disabled; `_TracingRuntime` is isbits by design.
- Cold start: `add_files!` (`public.jl:146`) already batches the initial load (one reconcile per batch, not per file); `derived_project` TOML parsing is lazy, memoized, and not invalidated by `.jl` adds; `derived_required_dynamic_projects` is O(projects²) + an `isfile` per package but memoized and ~1.5k iterations at this scale — fine below hundreds of projects.

## Not a runtime perf item
Milestone 5 (deleting the old whole-closure pass: `derived_static_lint_meta_for_root` and everything under it) is **code hygiene** — that pass is already *dead* (zero live callers, verified; not in the executed Salsa graph), so removing it doesn't change runtime cost, only precompile/source footprint.

## Measurement tooling
`benchmark/interactive_latency.jl` (parked on the `sp/perf` JuliaWorkspaces branch; port if useful) drives a workspace, does a body edit, and reports re-execution counts + warm/cold sweep times — works on any package/workspace. Re-execution counting via `Salsa.TraceLogging` + a `CountReceiver`; dependency-edge stats by iterating `rt.storage.derived_function_maps` and summing `.dependencies`; which dep invalidated a node via comparing `changed_at` to `current_revision`.
