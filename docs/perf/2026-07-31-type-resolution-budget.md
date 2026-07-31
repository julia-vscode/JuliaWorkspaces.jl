# §17 viability measurement — the type-resolution budget (2026-07-31)

The one unbounded cost in §17 of
`docs/design/2026-07-31-module-inventory-and-resolution.md`: resolving a recorded
parameter type means asking the *defining* module about a name, so each per-file
analysis gains dependency edges. §17 asked for a measured budget before the design
is specified. This is it.

**Answer: §17 proceeds as designed. No cheap pre-gate is needed** — but only
because of a resolution-shape choice the design must now state explicitly (below).

## Method

In-process, per `docs/perf/lsbench/README.md`'s marginal-cost method — not lsbench.
A `JuliaWorkspace` over the whole julia-vscode repo (2682 text/toml files, **74
workspace package roots**, active project `scripts/environments/development`),
Julia 1.12, shared box. Script: `docs/perf/typebudget.jl`, committed here for the
same reason lsbench was.

Two halves, each mirroring the code path it stands in for:

- **Record side** — the same splice walk as `derived_method_arities_index`
  (`_walk_spliced_binding_items!`), but extracting each callable item's *syntactic*
  parameter type names from its defining EXPR instead of its argument counts.
  `where`-bound type variables are excluded (they are method-local and resolve
  against nothing); `where` **bounds** are included (`f(x::T) where T<:Real` cannot
  be compared until `Real` is known). Critically, it keeps the walk's `loc` — the
  module the method's *text* sits in — separately from the qualifier-resolved key
  path, because for `Base.foo(x::MyType)` written in module `M` it is **`M`**, not
  `Base`, that `MyType` resolves against.
- **Call side** — `check_call`'s exact gate, replayed over every `:call` in each
  file: `refof_call_func` yields a `Binding`/`TreeRef`, `_is_local_callee_binding`
  says no, the callee name is an identifier, and it is tree-visible at the **call
  site's** module path (`derived_module_visible_names_idfree`).

1056 (root, file) pairs measured.

**Env resolution was off**, so the store leg is not exercised. Validated as
harmless for the counts: re-running the gate with the meta requirement dropped
(visibility only — env-independent) changes the gated-call count by <0.1%
(CommonMark 3594 vs 3593; TestItemServer 8106 vs 7978). See the caveats for what
this does leave unmeasured.

## The counts

Distinct pairs per file, and the number that actually decides the design — **new
Salsa dependency edges** — under the two candidate resolution shapes:

| per (root, file) | p50 | p90 | p99 | max |
|---|---|---|---|---|
| distinct (defining module, type name) pairs | 5 | 24 | 59 | **66** |
| distinct **defining modules** | 1 | 1 | 2 | 4 |
| **new** module-map edges (strict) | **0** | **0** | 1 | **2** |

The strict row uses the narrowest defensible definition of "already depended on":
only the file's own splice path plus the call-site paths of calls that *pass* the
gate, which provably consult `derived_module_visible_names_idfree` today via
`tree_visible`. Under it, **47 of 1056 files add any edge at all**, mean 0.05.

The tail is not first-party code: the top 15 files by pair count are all
CommonMark (`citations.jl` and `interpolation.jl` at 66), a vendored dep whose
heavily-typed AST methods are exactly the shape that stresses §17. First-party
roots are milder — LanguageServer p50 1 / max 20, JuliaWorkspaces p50 9 / max 40.

On JuliaWorkspaces' own root: 1513 callable items, 1564 annotated parameters, 1829
type mentions → **161 distinct type names** (a ~11× collapse). §17's earlier figure
was 1675 → 194; the difference is scope — this counts tree-spliced callable items
only.

## The times

| | |
|---|---|
| warm memoized `derived_module_visible_names_idfree` hit | **0.46 µs** |
| 66 name lookups in an already-held map | **6.4 µs** |
| one env-store resolution (`maybe_lookup` + `get_eventual_datatype`) | **229 ns** |
| ⇒ whole resolution step, worst file in the repo | **≈10 µs** |
| parameter-type extraction, largest file (73 items) | **0.039 ms** |
| per-root index, body-only edit (the keystroke) | **0.013–0.030 ms** (backdates) |
| per-root index, declaration-changing edit | **1.3–3.1 ms** |

The last two are `derived_method_arities_index` measured as a same-shape proxy for
the signature index — same walk, same data, same key — and agree with the lsbench
README's 0.05 ms / 0.4–1.1 ms. Alongside them, per edit: inventory 2.1–3.4 ms, module
tree 0.65–2.1 ms (body-only) / 2.4–6.5 ms (declaration-changing).

Two traps, both of which produced wrong numbers on the first attempt:

- **Chain edits of the same kind.** A "body-only" edit applied on top of a
  declaration-changing one *removes* that declaration, so it is itself a
  declaration change and costs the full 1.3 ms. Measure a run of consecutive
  body-only edits and a separate run of consecutive declaration edits; interleaving
  them measures neither. Verify with the item and index-key counts, which must hold
  steady across a body-only chain (39 items / 1158 keys here) and move on a
  declaration one.
- **`string(::SourceText)` returns the `repr`, not the content** — round-tripping a
  file through it writes `SourceText("…")` into the workspace, the file stops
  parsing, its inventory silently goes to **0 items**, and every downstream number
  is quietly wrong. Read `.content`, or re-read from disk. A parse/item-count
  assertion after each `update_file!` catches it immediately.

Also per the README: discard the first measurement after any edit. The recompute path
cost 101 ms (tree) / 50 ms (index) on its first run and 3 ms / 1.5 ms thereafter, and
one mid-run sample spiked to 87 ms on unchanged code.

## The three resolution legs

Where a recorded type name actually resolves, over 2324 distinct (defining module,
type name) pairs:

| leg | share | |
|---|---|---|
| defining module's visible-names map | **45.3%** | workspace-declared types |
| Base/Core store | **53.8%** | `String`, `Int`, `Vector`, `AbstractString`, … |
| neither → **unknown, permissive** | **0.9%** | 22 pairs / 20 names |

**The store leg adds no dependency edge either.** `derived_file_analysis` already
takes `env` as one edge to `derived_environment` (or `derived_stdlib_only_env`), so
store resolution reads inside a value already in hand — structurally identical to the
module-map leg, and the reason the edge counts above are unaffected by it.

It also needs **no warm store or DJP**: every one of the 53.8% is Base/Core, which
SymbolServer ships bundled and which is present even in the stdlib-only fallback env.
The 0.9% remainder is mostly stdlib (`Diagonal`, `Hermitian`, `DateTime`, `Period`,
`AbstractRNG`) plus a few dependency types (`Tangent`, `RuleConfig`), all of which a
resolved env would supply — so 0.9% is an upper bound on what stays unknown, and
unknown is permissive by §17's first rule.

One shape note for the Resolve slice: a bare `x::String` resolves to a
**`FunctionStore`** (the constructor), `x::AbstractString` to a **`VarRef`**, and
only `x::Vector` directly to a `DataTypeStore`. All 14 Base names measured reach a
`DataTypeStore` only *after* `maybe_lookup` (follow the `VarRef`) and
`get_eventual_datatype` (follow `FunctionStore.extends`). Code that tests for
`DataTypeStore` directly will conclude, wrongly, that `String` is not a type.

## The design consequence

The near-zero edge count is **not** a property of the workspace — it is a property
of resolving through the *whole module's* name map. The defining module of a
cross-file callee is almost always a module the analysis already queries (in a
single-module package it simply *is* the file's own splice path), so the map query
is an edge already paid for and each type name costs an O(1) dict lookup inside a
value already in hand.

So the design must state it: **resolution reads the defining module's
`derived_module_visible_names_idfree` map, and per-name resolution must NOT become
its own Salsa node.** Had §17 keyed a query per (module, type name), the same
workspace would hand `citations.jl` 66 new edges instead of 0 — the pairs row above
*is* that counterfactual. This is the same lesson as `derived_method_arities_index`,
one layer up: fan-in through one node per module, cut off at the projection.

Corollary: the `derived_external_extension_names`-style pre-gate that §17 held in
reserve is **not a prerequisite**. It remains available if the resolved-type
comparison (not the lookup measured here) turns out expensive.

## What this does not measure

- **A fully resolved env.** The store leg was measured against the stdlib-only env,
  which is sufficient because 53.8% of names are Base/Core and the 0.9% remainder is
  an upper bound (a resolved env can only shrink it). What a resolved env would change
  is the *split*, not the total: some of the 0.9% moves into the store leg. Invalidation
  is also unmeasured, though `ExternalEnv`'s `isequal` is entrywise store *identity*,
  so a rebuilt-but-unchanged env backdates.
- **Ancestor-chain enumeration.** Only the presence/identity lookup §17 needs is
  measured. §18's requirement — the supertype chain *enumerated*, possibly leaving
  the store and passing through workspace-declared types — is a different and
  unmeasured cost.
- **Comparison cost.** `_issubtype`/`_has_type_intersection` already exist and are
  already paid by the store-backed path; feeding them a workspace operand is
  assumed, not measured, to cost the same.
## Shape of what would be recorded

Across all 74 roots, **17650 annotated parameters**:

| shape | count | share |
|---|---|---|
| bare identifier (`x::Node`) | 14685 | **83.1%** |
| parametric (`x::Vector{Node}`) | 1954 | 11.1% |
| qualified (`x::CSTParser.EXPR`) | 824 | 4.7% |
| `where`-bound type variable | 201 | 1.1% |
| other | 8 | 0.0% |

This is the case for slicing the implementation by type-expression shape rather
than by layer: bare **and qualified** identifiers together are 87.8% and resolve the
same way (a name lookup, with a module-path walk in front for the qualified form), so
they belong in one slice; parametrics are the shape that needs different machinery.
Every shape not yet handled records as explicit unknown, which §17's first rule makes
*permissive* — so a partial implementation is correct, not merely incomplete.

Note that `citations.jl`, the worst file for pair count, happens to contain **zero**
qualified annotations; the repo has 824, so qualified handling is testable — do not
conclude otherwise from a single file.

**A recording hazard found while measuring: value positions inside a parametric type
must not be descended into.** `NamedTuple{(:envPath,),Tuple{String}}` yielded a
recorded "type name" `envPath`, because the walk recursed through the quoted symbol in
a *value* position. Two such pairs appeared in this repo. Harmless where the bogus
name simply fails to resolve (unknown → permissive), but `Val{:String}` would record
`String` and could then *match* — a false positive, the one outcome a linter must not
produce. This is the same trap as value-tuple types putting values in
`FakeTypeName.types`, one level up in the syntax. The harness skips `:quotenode`/
`:quote`; the Record slice must do at least as much.
