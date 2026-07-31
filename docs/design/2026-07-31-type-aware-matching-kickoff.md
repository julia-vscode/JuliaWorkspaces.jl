# §17/§2 kickoff: measure before designing

*2026-07-31 — a starting brief, written at the end of the macro-declared-names
work so the next session does not re-derive it. Read
`docs/design/2026-07-31-module-inventory-and-resolution.md` §2, §5, §11, §13, §17,
§18 first; this only records what that document cannot know.*

## The project

Cross-file method matching stops at argument counts (§2). §17 is the design that
takes it past arity: record a *syntactic* type per parameter, resolve it on demand
against the **defining** module, and let the call-site lint compare. §18's inverse
type-to-methods index depends on those same records and comes later.

## Two things settled since the document was written

**§17 does not depend on §13.** The per-module declarations node is not a
prerequisite — see §17's own corrected text and §13's annotation. The shape to use
is the one the arity path already has: records on `InventoryItem` (which carries
`signature` and `arity` today), a per-root index, per-`(path, name)` projections
for early cutoff, and resolution through `derived_module_visible_names_idfree` of
the defining module. §13 survives only on §5's consolidation, and has now twice
been claimed as a blocker and twice been shipped around.

**The subtype primitive already exists.** `src/StaticLint/subtypes.jl` has
`_issubtype` climbing `_super` with `_type_compare`, plus
`_has_type_intersection`, already driving the `isa` and method-call checks. §17
supplies the operand it lacks — a *workspace* method's parameter type. Note the
shape difference §18 records: `_issubtype` is a predicate over a pair, while an
index probe needs the ancestor chain *enumerated*, and that chain can leave the
store and pass through workspace-declared types.

## Do this first: the viability measurement — **DONE 2026-07-31**

**Result: §17 proceeds as designed; no pre-gate needed.** New dependency edges per
file came in at p50 0 / max 2 over 1056 (root, file) pairs of the julia-vscode repo,
and the worst file's whole resolution step at ≈7 µs. The catch is that the answer
depends on a shape the design had not pinned down: resolution must read the defining
module's *whole* visible-names map, never a per-name Salsa node — keyed per name the
same tail file costs 66 edges instead of 0. Numbers, method and the unmeasured legs
(env-store fall-through, §18's ancestry) in
`docs/perf/2026-07-31-type-resolution-budget.md`; harness at `docs/perf/typebudget.jl`.
The rest of this section is the brief as written, kept for the reasoning.

§17's one unbounded cost is that resolving a recorded type name means asking the
*defining* module, so each per-file analysis gains dependency edges — one per type
mentioned in a cross-file signature. Whether that is affordable decides the design,
so measure it before specifying anything.

**The number to get:** for a single file's analysis, how many *distinct*
`(defining module, type name)` pairs would it have to resolve? Not mentions —
distinct pairs, since those are what memoize. On this package's own root, 1675
annotated parameters collapse to 194 distinct type names, a ~9× collapse; the
per-file figure is the one that matters and is unmeasured.

**How to measure it** — the in-process marginal-cost method, which is documented in
`docs/perf/lsbench/README.md` and which refuted a wrong hypothesis in minutes on
2026-07-31. Do not reach for lsbench: it can tell you *that* something changed, not
*why*, and its percentiles mislead at small n (same README).

Sketch: build a `JuliaWorkspace` over a realistic root; for each file, walk the
calls its analysis checks; for each callee resolvable cross-file, collect the
distinct `(module path, type name)` pairs its recorded parameters would need. Report
the distribution across files, not the mean — the tail file is what sets the budget.
Then time one resolution to convert the count into milliseconds.

**The decision it feeds:** if a typical file touches single digits, §17 proceeds as
designed. If the tail runs to hundreds, the design needs a cheap gate first — the
precedent is `derived_external_extension_names`, a stable per-root `Set` that lets a
call to a name with no workspace overload skip the machinery entirely.

## Likely decomposition

**Superseded 2026-07-31, after the measurement: slice vertically, not horizontally.**
Record and Resolve have no observable behaviour, so neither can be validated except
through Wire — three specs would mean reviewing two-thirds of a system against the
criterion "the data looks right", which is the mode that made 6 of 7 last-run
findings plan defects. The two decisions that justified staging (pre-gate? resolution
shape?) are now both answered, so what remains between the layers is a function call,
not a decision.

Slice by type-expression shape instead, one plan, each slice end-to-end and
shippable — of the repo's 17672 annotated parameters, 83.1% are bare identifiers,
4.7% qualified, 11.1% parametric (`docs/perf/2026-07-31-type-resolution-budget.md`):

1. **Bare *and* qualified identifiers** — 87.8% together. They resolve the same way:
   a name lookup, with a module-path walk in front for the qualified form, so
   splitting them buys nothing. Everything else records as explicit unknown, which
   §17's first rule already makes permissive, so this ships end-to-end as a linter
   that catches less and false-positives never — and is manually testable on its own.
1.5. **Merge the arity and type records into one signature record** — one walk, one
   per-root index, one closure. Added after slice 1's implementation showed that type
   matching is *not* strictly more powerful than arity matching: it runs only after an
   arity matched, and all-`Any` types match everything, so a pure count error is
   invisible to it. The redundancy is in the plumbing (two Salsa indices, same walk,
   same triggers, 1.3–3.1 ms each on a declaration-changing edit), not in the check.
   **The trap:** every withholding mechanism slice 1 added blanks the *type* opinion
   while deliberately leaving the *count* opinion intact, so the merged record must
   carry two independently gated opinions — collapse them and the `eval` marker
   silently deletes arity coverage. Gate: byte-identical diagnostics over this
   package. Full reasoning in the slice-1 plan's trailing section.

2. **Parametrics** — resolve the head, recurse the arguments, and do **not** descend
   into value positions (`Val{:String}` must not record `String`). The real design
   work, and the shape that needs machinery slice 1 does not. Wants 1.5 first, since
   `match_method`'s `MethodStore` overload — count and types compared in one pass — is
   the model, and Vararg/optional positions are what parametrics need modelled.

§18 stays separate: different cost profile, ancestry enumeration unmeasured.

The env-store leg no longer needs its own decision point — **measured**: it adds zero
dependency edges (`derived_file_analysis` already holds `env` as one edge), costs
229 ns per name, and 53.8% of all names take it. It needs no warm store, since those
names are Base/Core, which ships bundled. Slice 1 must therefore handle it from the
start, including the `VarRef` → `FunctionStore.extends` → `DataTypeStore` hops that
`x::String` requires.

The original three-layer split is kept below for its reasoning about *where* the work
reaches, which still holds:

1. **Record** — a structured syntactic parameter type on `InventoryItem`, plus the
   per-root index and projections. Plain data only: no store values (they compare
   by identity and would never backdate), nothing recovered from
   `derived_item_positions`.
2. **Resolve** — on demand, against the defining module's id-free visible names,
   with §17's three rules: unknown is permissive, degrade on cycles at the query
   level rather than returning a truncated answer, and do not elaborate ancestry
   early.
3. **Wire** — into `check_call`, past the arity gate. A truncated supertype chain
   yields a false *positive*, the one outcome a linter must not produce, so the
   permissive direction has to be the default at every step.

## Carried-over cautions

- The plan's own sample code is where defects hide — six of seven findings in the
  last run were plan defects, all in code blocks the prose contradicted.
- Assert lint behaviour through the **per-file** pass
  (`derived_file_analysis(...).meta`), never `derived_static_lint_meta_for_root`:
  the whole-closure query is the old per-root path and does not see anything wired
  into visibility.
- Ask of every test: what would have to break for this to fail? Two tests in the
  last run could not fail at all.
