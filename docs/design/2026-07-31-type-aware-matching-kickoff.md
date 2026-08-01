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
1.4. **Infer a reassigned local's type from all its assignments** — agreeing
   assignments give that type, disagreeing ones give `Any`. Scheduled *before* 1.5
   because it fixes the one false positive slice 1 shipped with (§17b): `refof` is
   flow-insensitive, so `x = nothing` → `if x !== nothing` → `f(x)` infers `Nothing`
   at the call site and the store-resolved-argument guard cannot decline, since the
   wrong type is well resolved. Strictly better than today at every size of the
   assignment set. **Two costs:** `Binding` has no `prev`/`next`, so the assignments
   are not enumerable without a chain field — and it lives in the Salsa-cached
   `meta_dict`; and prefer `Any` over a union, since `_type_compare` has only a
   right-side union method, so a `FakeUnion` argument type would open a *new* FP
   class (any member that is a proper subtype of an abstract parameter). The
   any-member rule belongs in `_has_type_intersection`, never in `_issubtype`, which
   the `isa` check shares and which needs all-member semantics. Wants its own sweep:
   it moves diagnostics repo-wide in both directions, and it improves `isa`, hover
   and everything else reading `Binding.type`, not just this lint.

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

## Follow-up queue — status as of 2026-07-31, after slice 1 shipped

Slice 1 landed in `217f325..2689292`. Everything below is deferred work, in the
order I would take it. Several of these were found during slice 1's review loop and
exist nowhere in the code, so this list is their only record.

**Planned, not started.**

- **Slice 1.4 — reassigned locals infer to `Any` when assignments disagree.** Fixes
  the one false positive slice 1 shipped with (§17b). Plan written and committed:
  `docs/superpowers/plans/2026-07-31-slice-1-4-reassigned-local-types.md`. Ready to
  execute as-is.
- **Slice 1.5 — one signature record.** Specced in
  `docs/design/2026-08-01-slice-1-5-signature-record.md`; needs a task plan next.
  A structured `signature` field with parameter names, types and roles replaces
  *three* overlapping fields — `arity`, `param_types` and the string `signature` —
  and `MethodArity` becomes derived rather than stored. Two traps the spec turns
  into design rules: merge the storage but keep **two projections**, or a type-only
  edit stops backdating the count opinion; and withholding must blank the types
  *inside* a record rather than drop it, or the `eval` marker starts deleting arity
  coverage. Prerequisite for slice 2, which then becomes a resolver change rather
  than a schema change.

**The one check slice 1.5's gate could not perform.**

- **An incremental arm for `typesweep.jl`.** Every measurement backing the
  signature-record merge is a *cold build*, and that merge changed the dependency
  graph: arities now derive through signatures through a merged index, and a
  marker-fired root went from a constant empty dict to full contents. A backdating or
  invalidation defect yields *stale* diagnostics after an edit and is invisible to a
  from-cold comparison. On two or three marker-fired roots (TestItemServer,
  JuliaDynamicAnalysisProcess), apply a type-only, a count-changing and a body-only
  edit, re-collect the whole root's diagnostics, and require they equal a from-cold
  rebuild of the edited state. Small addition to a harness that already exists, and
  the only failure mode this slice can plausibly introduce that 74 cold roots cannot
  see. Numbers and rationale: `docs/perf/2026-08-01-slice-1-5-verification.md`.

**Bugs found during slice 1, not caused by it.**

- **`func_nargs` does not recognise an anonymous `::Vararg{T}`.** `f(x, ::Vararg{Int})`
  yields `(2,2)` instead of `(1, typemax)`, where the named `f(x, y::Vararg{Int})` is
  correct. Reproduced as an **arity** false positive on both the cross-file tree path
  ("Expected 2 arguments, got 3") and the local `sig_match_any` path, so it ships
  today, independent of type matching. Zero instances in the julia-vscode repo. Root
  cause: `is_explicit_vararg_decl` and the inline test at
  `StaticLint/linting/checks.jl:263` both require `isdeclaration`, which a unary `::`
  is not. Wants its own sweep, since it changes arity behaviour repo-wide.

**Latent widenings introduced by the signature record (slice 1.5) — queued, not bugs.**

Both are cases where slice 1 recorded *unknown* and the structured record now
resolves a real type. Both produce **true** positives, and both moved zero
diagnostics across the 74-root corpus — but a different workspace can see a new
(correct) diagnostic, so they are recorded rather than discovered later:

- **`@nospecialize(x::Int)`** — the record unwraps the macrocall and keeps `Int`.
  11 live typed spellings in the corpus, including a first-party one in JSONRPC.
- **`T{}` resolves like `T`** — `ParamType` cannot distinguish an *absent* curly
  from an *empty* one, so `x::Tuple{}` records as `["Tuple"]` exactly like a bare
  `x::Tuple`. 8 spellings; 5 are constructors neutralised by the struct kind gate,
  2 are live in JuliaFormatter. Fixing it properly means distinguishing the two in
  the record, which was judged too invasive to do late in a green refactor.

Whether to keep them (they are correct) or suppress them (they are unannounced) is
the decision; either way the next sweep over a wider corpus should expect movement.

**Refinements to slice 1, all measured and all optional.**

- **Narrow the `eval` marker to evals that could actually define a method.** 7 of the
  24 marker rows repo-wide are `Core.eval(@__MODULE__, :(global x::T))`,
  `eval(Meta.parse("public …"))` and a re-export block — none can define a method, yet
  each disables type checking for its whole root. Buys back **three** roots
  (CommonMark, Runic, Tokenize); JuliaDynamicAnalysisProcess and TestItemServer also
  carry a genuine `for … @eval <def>` and would stay disabled. Per-root figures in
  `docs/perf/2026-07-31-slice-1-sweep-results.md`.
- **Guard (c): treat an unresolved argument as `Any` per index** instead of declining
  the whole call. Equally false-positive-safe — `_isany` short-circuits — and it keeps
  the true positives where a *different*, resolved argument is a definite mismatch.
  Add the `Own <: MyAbs <: Integer` fixture in the same change, since that is where
  the false positive it guards against would return.
- **Move resolution below the cheap gates in `_tree_types_match`.** `tree_param_types`
  currently resolves before the keyword and resolved-argument checks, so ~719 of 4156
  invocations resolve and discard, and each reached site takes a dependency on the
  defining module's visible names. Mechanical reorder; natural to do during 1.5.
- **The mid-edit false positive (§17a hole 5), if it proves annoying in practice.**
  Prefer the consumer-side gate — decline when the *callee's defining file* failed to
  parse — over the marker, which would toggle the whole-root index and cost two
  full re-analyses per definition typed. Needs the records to carry the defining file,
  so 1.5 is the natural moment.

## Carried-over cautions

- The plan's own sample code is where defects hide — six of seven findings in the
  last run were plan defects, all in code blocks the prose contradicted.
- Assert lint behaviour through the **per-file** pass
  (`derived_file_analysis(...).meta`), never `derived_static_lint_meta_for_root`:
  the whole-closure query is the old per-root path and does not see anything wired
  into visibility.
- Ask of every test: what would have to break for this to fail? Two tests in the
  last run could not fail at all.
