# Slice 1.5 verification — the signature-record merge (2026-08-01)

What was checked before merging the consolidation that replaced `InventoryItem.arity`
and `.param_types` with one `method_sig` record. Preserved here because the numbers
lived in a git-ignored execution ledger, as slice 1's did.

The claim under test was narrow and total: **not one diagnostic may change.**

## The gate

Both-direction sweep (`docs/perf/typesweep.jl`) over all 74 roots of the julia-vscode
repo, against a *fixed corpus snapshot* — this package is itself one of the 74 roots,
so a live-tree sweep would have the two arms linting different source.

| | |
|---|---|
| diagnostics, branch vs `main` | **3779 vs 3779** |
| present on branch, absent on `main` | **0** |
| present on `main`, absent on branch | **0** |
| roots with any movement | **0** |
| runs | 2 |

`compared` rose 7092 → 22925, which is an accounting change rather than a behaviour
one: blanked records now reach the comparison and match trivially on `Any`, where the
old index deleted the key outright. The number that would have moved on a real change
is `rejected`, and it held at **1** — slice 1's known, accepted `Revise`
`find_from_hash` false positive.

## The stronger evidence

A cold sweep shows that nothing moved on one corpus. These establish *equivalence*:

- **Arity faithfulness, whole tree.** `_arity_of` against `func_nargs`/`struct_nargs`
  over all of `scripts/`: **23,445 methods and 2,299 structs, 0 mismatches.** The
  committed oracle tests cover this package only (~1,240 methods / 115 structs).
- **Judgeability equivalence.** The shipped `all(r -> r.judgeable, recs)` gate against
  a re-implementation of `main`'s deleted extractors, joined over **21,338 method
  items**: **0** cases where the new code judges what the old declined; 18
  removal-only declines, all `@nospecialize(x...)`; 46 recorded-type differences.
- **Blanking is arity-invariant.** Over **25,744 records**: 0 arity shifts and 0
  judgeability flips under `_blank_types`. This is the property the whole
  count/type-opinion separation rests on.
- **The judgeability-signal hoist.** Pre-fix vs post-fix rules compared record by
  record across all 74 roots' post-withholding records: **15,433 records, 0
  disagreements.**

## Performance, corrected

The merge does **not** halve the index recompute, as the design doc originally
claimed. Declaration-changing edit, median of 9:

| root | before | after | |
|---|---|---|---|
| TestItemServer | 20.28 ms | 15.59 ms | −23% |
| JuliaDynamicAnalysisProcess | 26.59 | 14.33 | −46% (noisy base) |
| JuliaWorkspaces | 14.69 | 11.26 | −23% |
| CommonMark | 7.35 | 6.26 | −15% |
| LanguageServer | 2.76 | 2.43 | −12% |

Median ≈**23%**. The arity walk was the cheap one and had already been absorbed into
the signature walk, so the merge only removes the parameter-type walk on top.

Two *new* costs on a root where the `:opaque_definitions` marker fires: blanking costs
0.33–0.66 ms and 0.54–1.17 MiB per build, which the old empty-dict short-circuit never
paid; and the old parameter-type index had **zero keys** there, so its value was
constant and backdated on every edit, whereas the merged index carries full contents
and invalidates 1089/902/468 per-name signature nodes on any declaration edit.
End-to-end including fan-out: 27.4→25.7, 25.9→23.9, 10.3→7.7 ms.

## The gap this does not close

**Every measurement above is a cold build.** The refactor changed the dependency graph
— arities now derive through signatures through a merged index, and a marker-fired
root went from a constant empty dict to full contents. A backdating or invalidation
defect produces *stale* diagnostics after an edit and is invisible to a from-cold
comparison. The unit tests cover the mechanism on single-file fixtures; nothing covers
it at pipeline scale.

The check that would close it is queued: an **incremental arm** for `typesweep.jl` —
on two or three marker-fired roots, apply a type-only edit, a count-changing edit and
a body-only edit, re-collect diagnostics for the whole root, and require they equal a
from-cold rebuild of the edited state.
