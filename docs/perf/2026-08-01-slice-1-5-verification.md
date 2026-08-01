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

## The gap this does not close, stated accurately

**Every measurement above is a cold build**, and no from-cold comparison can observe a
*backdating* defect — one where a node fails to re-run after an edit and serves a stale
answer. Both arms rebuild from scratch, so the cache is never exercised across an edit.

What that gap is **not**: a record-equality problem. Backdating is safe here because a
record comparing equal implies every answer derived from it is equal, and that holds in
each place the record is deliberately coarse — `T{}` and bare `T` record identically
*and* resolve identically; the 255-clamp collapses different large ranges to one record
*and* both derive `(0, typemax)`; `shape_unknown` records share an empty `params` *and*
all derive the same permissive arity. Coarse record, equally coarse answer, in every
case. Blanking likewise preserves role, `names_vararg`, `kwsplat`, `shape_unknown` and
the `Vararg` bound — verified over 25,744 records with zero arity shifts and zero
judgeability flips.

(The `names_vararg` defect found in review is sometimes cited here; it does not belong.
That was a violation of *blanking invariance* — `_blank_param` erased the field
`_sig_is_judgeable` read — not of record equality. The record and its blanked form never
compared equal to each other.)

What survives is narrower: a **dropped dependency edge**. The merged index must register
everything the two old indices did — every file's inventory, the module tree, and
`_external_import_targets` for the withholding gate. If the merge lost one, an edit to
that input would not invalidate, and the stale value would be served indefinitely. A
cold sweep cannot see this because both arms register everything on a fresh build.

**There is no demonstrated instance. The argument is structural.** The queued check, if
run: on two or three marker-fired roots, apply a type-only edit, a count-changing edit
and a body-only edit, re-collect the whole root's diagnostics, and require they equal a
from-cold rebuild of the edited state — the rebuild being the oracle, so there is no
expected-value list to maintain. It is deferred deliberately; see the follow-up queue in
`docs/design/2026-07-31-type-aware-matching-kickoff.md`.
