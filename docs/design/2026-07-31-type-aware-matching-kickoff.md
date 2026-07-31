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

## Do this first: the viability measurement

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

Three specs, not one — this is materially bigger than the macro-names project, and
it reaches into type inference, `check_call` and `subtypes.jl`:

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
