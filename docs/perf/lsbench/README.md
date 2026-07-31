# lsbench — the LS performance harness

A Python LSP client that drives a real language-server process against the
julia-vscode repository and records startup, sweep, request-latency and
typing-burst timings. Built 2026-07-24 for the baseline in
`docs/perf/2026-07-24-performance-investigation.md`; committed here 2026-07-31
because it had been living in a `/tmp` scratchpad and would have died with it.

`lsbench.py` is the driver, verbatim as it produced both the 2026-07-24 baseline
and the 2026-07-31 comparison in `runs-2026-07-31/` — deliberately not tidied,
so the numbers and the code that made them stay in step. `analyze.py` is a small
summary reader.

## What it measures

- `initialize` response time, and how long `initialized` blocks the dispatch loop
  (the synchronous initial sweep).
- First and last diagnostic publish during startup, and the publish count.
- Warm request latencies over N repeats: hover, documentSymbol, definition,
  completion, workspace/symbol, `julia/getModuleAt`, references.
- `didChange` → publish latency over 20 edits.
- A 30-keystroke burst at 33 ms intervals, with probe latencies through it.
- LS RSS, and child-process RSS when dynamic indexing is on.

## Prerequisites

Three pieces of state, all outside this repo:

| What | Where | Why |
| --- | --- | --- |
| Isolated depot | `~/.cache/claude-lsbench/depot` | Made with `cp -al ~/.julia`. DJP children strip `JULIA_DEPOT_PATH`, so isolation has to come from a fake `HOME`, not the env var. |
| Fake `HOME` | `~/.cache/claude-lsbench/fakehome` | Points the children at the sandboxed depot. |
| Warm symbol store | `~/.cache/claude-lsbench/store-dyn-abs` | Without it the LS indexes ~134 environments from cold, ≈5.5 min before anything is measurable. **Copy it per run** — a run mutates its store. |

A durable copy of this driver and the 2026-07-24 field notes also lives in
`~/.cache/claude-lsbench/driver/` and `~/.cache/claude-lsbench/baseline-2026-07-24/`.

The paths above, plus `REPO` and `JULIA`, are hardcoded near the top of
`lsbench.py`. Change them there for another machine.

## Running it

```bash
cp -a ~/.cache/claude-lsbench/store-dyn-abs /tmp/store-run1
python3 docs/perf/lsbench/lsbench.py \
  --label my-branch --store /tmp/store-run1 --outdir /tmp/lsbench-out/run1 \
  --runtime-suite --settle-timeout 900
```

`--runtime-suite` is **not** the default and is what produces every request
latency, the `didChange` series and the burst. Omitting it leaves only startup
numbers — an easy way to waste a run. Other flags: `--dynamic` (dynamic
indexing), `--download` (symbol-cache download), `--env-resolution`.

Results land in `<outdir>/summary.json`, with an event log in `events.jsonl` and
the server's stderr in `ls-stderr.log`. `events.jsonl` carries per-request
latencies, which `summary.json` does not — reach for it whenever a percentile
looks strange, because the raw series is what settles the question.

Each run takes ~2 min warm, plus precompilation if the package changed.

## Reading the output without fooling yourself

Five traps, all of which cost real time on 2026-07-31:

**Precompilation lands inside `initialize`.** After changing the package, the
first run pays for precompiling it — 87 s of a 92 s `initialize` in one measured
case. Always discard the first run after a code change, or compare only runs
whose `ls-stderr.log` has no `Precompiling` line.

**`timed()` sorts before indexing.** A cold first call therefore lands in `max`,
never in `p50`. That is usually what you want, but it means `p50` silently hides
warm-up rather than showing it.

**A branch with new code paths has a longer JIT tail, and at n=10 that inflates
the sorted p50.** One case: `main` reached its steady 16.9 ms on call 2 while the
branch descended 33.6 → 26.5 → 20.7 over calls 2-4, which pushed the branch's
`workspace_symbol` p50 up by ~5 ms and made a one-time compilation cost look like
a 36% regression. The warm *floor* differed by 1-2 ms. Read the raw series from
`events.jsonl` before believing any percentile at n=10.

**`p90` at n=10 is the second-slowest sample.** It swung 406 → 124 ms across two
runs of identical code. It is not a stable statistic here.

**Run-to-run variance exceeds small deltas.** On a shared box, `t_first_publish`
came in at 116.6 / 69.9 / 116.5 s for comparable work, and RSS at 1.96 / 2.09 GB
for identical code. An 8 ms difference in a keystroke median across n=2 per arm
does not survive that.

## Attributing a delta to a specific query

lsbench can tell you *that* something changed; it is a poor tool for *why*.
For attribution, measure the marginal cost in-process instead — this is what
refuted the suspected cause of the 2026-07-31 keystroke delta in minutes:

1. Build a `JuliaWorkspace` over the relevant package(s) — including any
   workspace package the code under test needs, or confirmation paths silently
   fail and you measure nothing.
2. Warm every query you intend to time, so JIT is out of the way.
3. `update_file!` the file whose edit you want to simulate. Distinguish a
   **body-only** edit (the inventory backdates — the common keystroke) from a
   **declaration-changing** edit (inventories and the tree really recompute).
4. Time the queries **in dependency order**, cheapest upstream first, so each one
   pays only its own marginal work rather than its dependencies'.

Measured that way on 2026-07-31, a new per-root index cost 0.05 ms on a body-only
edit and 0.4-1.1 ms on a declaration-changing one, against 0.6-3.7 ms for the
module tree — enough to rule it out as the source of an 8 ms difference.

## Baselines

- 2026-07-24, `main@454fa4b`: `docs/perf/2026-07-24-performance-investigation.md`.
- 2026-07-31, `main@c5e4481` vs `sp/module-inventory-design`: `runs-2026-07-31/`
  (`main.json`, `main2.json`, `branch2.json`, `branch3.json` — two runs per arm,
  DynamicOff, warm store). Conclusion: no attributable steady-state regression;
  ~180 ms of one-time JIT for the new code paths.
