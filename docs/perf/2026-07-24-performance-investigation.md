# Performance investigation — julia-vscode repo as workspace (2026-07-24)

End-to-end measurement of LanguageServer + JuliaWorkspaces `main` (454fa4b) on the
`/home/pfitzseb/git/julia-vscode` repo: **4362 text files / 2188 .jl files / 363
Project.toml / 134 environments with a Manifest.toml** — roughly 4× the repro workspace
used in the 2026-07-18 doc. Julia 1.12.6, shared 128-thread machine (numbers taken after
clearing ~34 cores of leaked spinning DJP orphans; ambient load from other users remains).

Method: a Python LSP driver (`lsbench.py`, session scratchpad) spawns the LS exactly like
the extension (same args/env/cwd), speaks LSP over stdio, answers `workspace/configuration`
/ progress-create / registration requests, logs every message with monotonic timestamps,
and sends `documentSymbol` probes every 0.5 s to measure dispatch-loop availability.
Depot isolated via `cp -al ~/.julia` + a fake `HOME` (note: DJP children *delete*
`JULIA_DEPOT_PATH` from their env — `dynamic_feature.jl:156` — so `HOME` is the only
isolation that reaches them). In-process profiling via a REPL session with the dev env.
Push-diagnostics client (no pull, no refresh capability), `julialangTestItemIdentification`
on, defaults otherwise (dynamic on, download on, cap 4, env resolution off).

## Headline numbers

| | DynamicOff | Dynamic, warm store | Dynamic, cold store |
|---|---|---|---|
| spawn → `initialize` response | 4.5 s | 4.5 s | 4.5 s |
| `initialized` blocks dispatch loop | 59.9 s | 73.7 s | 113.3 s |
| first `publishDiagnostics` | 64 s | 79 s | 118 s |
| indexing complete | — | 20 s (fast lane) | ~5.5 min |
| post-startup background churn | none | ~10 min refresh tail | ~10 min + 30 s flip loop |
| LS RSS after suite | 3.2 GB | 3.4 GB | 4.9 GB |

Warm request latencies (p50, n=20): hover 0.5–1.0 ms, documentSymbol 1.0–1.5 ms,
definition 0.35–0.7 ms, completion 0.65–1.3 ms, `julia/getModuleAt` 0.06–0.23 ms,
references 3.5–7.8 ms (cold-first ~1.0–1.1 s), workspace/symbol 15–29 ms.
First-request JIT stalls: hover 1.2–2.0 s, references ~1.1 s, sweep hash-diff 334 ms.

## Where startup time goes

The `initialized` handler runs synchronously on the dispatch loop: folder walk + read
(1.2 s), `add_files!` (4.1 s), then the initial `run_publish_sweep` = the cold
full-workspace lint. In-process (DynamicOff, JIT-warm): **46 s, 18 GiB allocated, ~29% of
wall time in GC** (JIT-cold in a fresh session: 90 s / 24 GiB).

Cold-sweep profile composition (2502 samples):

- `derived_new_static_lint_diagnostics` **67%**, of which `derived_file_analysis` 61%;
  inside that, `check_all` 45% of the whole sweep — dominated by `check_call` (~1017
  samples) and `sig_match_any` (571).
- **`derived_package_for_file` + `derived_project_for_file` ≈ 20%** — almost all of it
  `splitpath` → regex `match`. `layer_projects.jl:252-292` re-splits every candidate
  folder per file and re-splits `splitpath(file_path)` *inside the filter closure, once
  per candidate*: ≈ 2186 files × ~360 folders × 2 functions ≈ 1.6 M `splitpath` calls
  ≈ 15 M regex matches, ~1–2 GiB of the allocation (RegexMatch ~1 GiB extrapolated).
  Cheap fix: derived per-revision folder-parts table + hoist the file split (or replace
  with plain string-prefix comparison).
- `derived_testitems` 14%; parsing (JuliaSyntax + legacy) ~8% — the per-keystroke
  double parse (2026-07-18 doc item 4) is now minor relative to `check_all`.
- Allocation by type (sampled ×5000): VisibleName containers ~3.7 GiB, InventoryItem
  ~2.5 GiB, SubString/String/RegexMatch ~3.4 GiB.

Time-to-first-analysis fix shape: cold *single-file* diagnostics cost 2.5 s for the first
file (env + its root warm-up) and 0.03 s for files in other roots. Publishing open files
first, then running the initial sweep in self-re-enqueueing chunks on the dispatch loop
(off-loop touches of the Salsa runtime are forbidden) would turn 64–118 s perceived TTFA
into ~14 s (4.5 s init + ~7 s load + 2.5 s first file).

## Dynamic indexing lifecycle

- Cold: 134 envs indexed in ~5.5 min at cap 4 (download on; 94 MB of jstores written).
  During indexing the dispatch loop hiccups continuously (40/456 probes >100 ms,
  typical 200–500 ms) from cache loads + indexing-complete refresh sweeps.
- Warm: the fast lane serves all 134 envs in ~7 s and the download bar completes from
  cache — indexing bar done at t≈20 s. **But a background refresh tail then re-resolves
  every env for ~10 minutes** (publishes trickle until t≈670 s), every restart, even when
  no manifest changed. Interactive requests colliding with refresh sweeps show max
  latencies of 600–850 ms (definition/completion/workspace-symbol) and 193–223 ms
  (getModuleAt). Gating refreshes on manifest content change would remove nearly all of
  this.

## Typing / didChange behavior

- Per keystroke the LS runs single-file `get_diagnostic` + `get_test_items` and publishes
  only on hash change. Cost on this workspace: **~40–60 ms** (profile: ~60% re-lint of
  the edited file via `check_all`, ~35% Salsa verification walk). The hash gate verifiably
  works (no-op edits produce zero publishes).
- The debounced full sweep costs **~365 ms median (DynamicOff)** — pure Salsa
  verification; ~26% of samples are `Dict` probes in `_probe_derived` — but
  **~1.8–2.0 s with dynamic indexing on** (measured as keystroke feedback delayed
  2.2–2.4 s when queued behind it; unattributed, top follow-up). Because the sweep runs
  on the dispatch loop, the *next* keystroke's feedback waits behind it: observed
  worst-case didChange→publish 0.9–1.4 s (DynamicOff) / 2.2–2.4 s (dynamic).
- A 30-keystroke burst at 30 cps saturates the loop (probes blocked ~1.2–1.5 s);
  at realistic typing rates the ~40–60 ms/keystroke floor is ~30% loop utilization.
- Post-edit sweep test-items cost: 1.3 ms. `run_publish_sweep`'s hash-diff over all 4362
  files: ~6 ms warm (334 ms first call — JIT, not covered by the precompile workload).

## Pathologies found

1. **DJP child leak (production)**: 49 orphaned `julia_dynamic_analysis_process_main.jl`
   children (ppid 1, oldest 8.3 days) totalling **44.8 GiB RSS and ~3400% CPU** (the
   readline-SpinLock livelock). Live LS sessions on the same box each carry 3–4 resident
   ~900 MB children, some spinning. Each LS restart leaks ~1 GiB + most of a core.
2. **Oscillating diagnostics (dynamic on)**: `JuliaWorkspaces/src/layer_file_analysis.jl`
   and `layer_static_lint.jl` flip between 3 and 4 diagnostics **every ~30 s,
   indefinitely** (observed t=350…743+ s, both warm and cold runs). DynamicOff shows 3
   hints each → the 4th is env-dependent; some environment input alternates between two
   states. Each flip advances the revision → sweep + republish: permanent idle churn.
   No child respawns or progress events coincide; root cause open.
3. **Malformed request crashes the whole server**: `julia/getModuleAt` without a
   `version` field → `KeyError` in the typed-params constructor escapes `dispatch_msg`
   and exits the LS (`languageserverinstance.jl` dispatch loop). Param construction
   should fail the request, not the server.
4. Push-mode startup publishes all 2186 workspace files, **1027 of them with zero
   diagnostics** — wasted traffic for clients without diagnostic-refresh support.
5. A relative symbol-store path resolves against the LS cwd (`scripts/languageserver`);
   the extension always passes absolute, but other clients can pollute the install tree.
6. Long-lived sessions grow: a day-old real LS instance on this workspace sits at
   **12.3 GB RSS** (vs 3.2–4.9 GB fresh) — consistent with Salsa's no-eviction design
   plus refresh churn (2026-07-18 doc item 5).
7. LS RSS on this workspace is ~3.2 GB immediately after startup with DynamicOff —
   1.8 GiB of it live heap of analysis state (biggest: per-file analysis artifacts,
   VisibleName/InventoryItem aggregates).

## Ranked follow-ups

1. Attribute and fix the ~2 s dynamic-mode publish sweep (vs ~365 ms DynamicOff);
   or chunk sweeps so interactive messages interleave.
2. Open-files-first + chunked initial sweep → TTFA ~14 s.
3. `splitpath` hotspot in `layer_projects.jl` (~20% of cold sweep, ~afternoon fix).
4. Manifest-change gating for warm-restart refreshes (removes the 10-min tail).
5. Root-cause the 30 s env flap; fix DJP livelock reaping (steady-state drains).
6. Extend the precompile workload: `run_publish_sweep` hash-diff, references,
   `getModuleAt`, store-backed hover.
7. Harden typed-param construction against malformed requests.
8. Skip startup publishes for files that never had diagnostics.

## Reproduction

- Driver + event logs + summaries: session scratchpad (`lsbench.py`, `run*/events.jsonl`,
  `run*/summary.json`, `findings-notes.md`).
- Isolated depot: `~/.cache/claude-lsbench/{depot,fakehome}` (hardlink copy; disposable).
- Warm symbol store: scratchpad `store-dyn-abs`.
- In-process numbers: REPL with the dev env; `JuliaWorkspace(dynamic=DynamicOff)` +
  `read_path_into_textdocuments` over the repo; edit via `update_file!` with a body-edit
  marker; `Profile`/`Profile.Allocs` for composition.
