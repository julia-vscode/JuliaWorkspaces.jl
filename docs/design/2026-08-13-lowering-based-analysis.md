# A lowering-based analysis engine: JuliaSyntax v2 + JuliaLowering under Salsa

*2026-08-13 — design sketch. Not an implementation plan.*

*Code claims were checked against `main` at 0a72c65 and `origin/bodytree` at
bd5fa5a on 2026-08-13, and against `aviatesk/JETLS.jl` at 182749a (2026-08-11).
Re-checked against `main` at d4bd830 on 2026-08-15: the intervening commits touch
test-item discovery and include handling only, and the stable-id change there is
to `TestItemDetail` ids, not to the inventory item ids §2.1 and §7.3 depend on.
Nothing here has been measured; every number this design depends on is named as
owed in §9.2.*

## Summary

The roadmap has long said that CSTParser and StaticLint are the old generation
and that JuliaSyntax plus the Salsa model are the new one. What has been missing
is the *semantic* half of that replacement: JuliaSyntax gave us a parser, but
nothing to replace `semantic_pass` with.

JuliaLowering is that half. Running the first compiler stages — desugaring,
scope resolution, binding analysis, closure conversion, linear IR — against a
throwaway context module yields the information StaticLint reconstructs by hand,
computed by the same code the language uses.

The engine analyses source **without running it**. Where knowledge of a
dependency is needed it comes from the `.jstore` symbol cache, and where runtime
introspection structurally cannot produce that knowledge the *indexer* fills the
gap by parsing the package's sources at index time (§3). Macro expansion in a
live process (§4) is an optional extra, not the path the design is built around.

A prototype of roughly the bottom third already exists on `origin/bodytree`; §7
documents what it implements, in enough detail that this document stands alone.

---

## 1. The stack

One parse, nine layers.

| # | Layer | Key | Status |
| --- | --- | --- | --- |
| 0 | Inputs | — | exists |
| 1 | **Parse (v2)** — JuliaSyntax v2 `SyntaxTree` | `uri` | branch, not yet a query |
| 2 | **ItemTree** — position-free per-file item summary: kind, name, module path, syntactic signature, imports, exports, includes | `uri` | main, CST-derived |
| 3 | **BodyTree forest** + volatile `addr → range` maps | `uri`, `ItemRef` | branch |
| 4 | **Expansions** — a macrocall's expanded tree with call-site provenance (T2 only) | expansion key | new, optional |
| 5 | **DefMap** — per module: declarations, classified imports, exports, visible names; unions workspace items with `ExternalEnv` stores | `root, path` | new |
| 6 | **Body lowering** — passes 1–4 plus linear IR, against the empty anchor module | `ItemRef` | branch, partial |
| 7 | **Global resolution** — each unresolved global from L6 resolved against its module's DefMap | `ItemRef` | new |
| 8 | **Inference** — JW-owned abstract interpretation over L6's IR and L7's targets | `ItemRef` | new |
| 9 | **Features** — diagnostics, hover, completions, goto, references, signature help | per request | exists |

Two firewalls run the length of it, and both are already load-bearing on the
prototype.

**The position firewall.** L2–L8 values contain no byte offsets and no node
handles — only preorder *addresses*. Positions are reattached exclusively by L9,
through the volatile `derived_file_body_maps` / `derived_file_lowering_maps` /
`derived_item_positions` queries. This is what makes an edit inside one function
body stop at that item instead of invalidating the workspace.

**The world firewall.** No `Module`, `ModuleStore`, `Binding` or
`MethodInstance` ever enters a derived value — only names, ids, addresses and
store *fingerprints*. The prototype already enforces this: `LoweredBinding.mod`
is a `String`, never a `Module`.

### 1.1 Why the DefMap must exist

Today a module's declarations are a projection of a syntax walk over its own
files: `_build_tree_structure` writes `declared` inside a DFS, and every consumer
that needs more than one `ItemRef` per name goes back to the file inventories
independently.

That stops working as soon as a module's declarations can come from somewhere
other than that walk — an enriched store record telling us what a dependency's
macro declares (§3), or an expansion (§4). The syntax no longer contains the
answer, so a node keyed `(root, module path)` has to exist above both sources and
below visibility.

There is a secondary payoff. `ModuleNode.declared` collapses to one `ItemRef` per
name, so item-level data is currently re-derived four separate times — a kind
index, and three independent spliced-binding walks for method items, the arities
index, and external method extensions. A per-module declarations node absorbs all
four. That alone has never been enough to justify the work, and this document
does not claim otherwise; what forces the node is the first argument, and the
second comes along for free.

### 1.2 Capability tiers

The engine runs at three levels of available knowledge. This is the spine of the
design, so it is stated before anything depends on it.

- **T0 — pure static.** Workspace source plus the Base/Core/stdlib store baked
  into the precompile file by `load_core()`. No child process, no depot, nothing
  executed. T0 is deliberately **limited** — it does not pretend to know a
  third-party package — and its role is to be the **soundness floor**, not the
  operating point.
- **T1 — indexed.** Plus `.jstore` caches for dependencies, enriched at index
  time (§3). **This is the expected path, and the tier the design is optimised
  for.** jstore coverage is expected to be very high, so features should be
  designed assuming T1 and degrading at T0, not the reverse.
- **T2 — live expansion.** Plus on-demand macroexpansion in a child process
  (§4). Optional, and the design must never require it.

**The invariant: higher tiers add information and never change a verdict.**
findings(T0) ⊆ findings(T1) ⊆ findings(T2). Soundness is established at T0; the
tiers above buy coverage, never correctness. This is directly testable and is the
real content of parity gate 2 (§5.1).

Two consequences, because getting them wrong is how this design fails:

- **Blanket abstention is a bug when the abstaining case is common.** Suppressing
  every rule in an item because it contains one unmodelled macrocall is
  acceptable if that is rare and temporary. It is not acceptable as steady state.
  Suppression must be scoped to what the unknown construct could actually affect,
  which is why the three-valued discipline (C5) has to reach into individual
  analyses rather than gating whole items.
- **Analyses must produce useful partial answers under opacity.** The prototype
  parked use-before-definition analysis because an opaque macrocall's synthesized
  reads can precede the real assignment. Where opacity is normal, "wait for
  expansion" is not an answer; the answer is a three-valued CFG result —
  `nothing`, may or may not be defined — for anything downstream of an opaque
  macrocall, which ships at T0.

---

## 2. Invalidation contracts

Six rules. Each is a lesson this codebase already paid for; §8 traces them.

**C1 — Analytic or volatile, never both.** Every query is one or the other.
Analytic queries (L2–L8) are position-free and may be depended on freely.
Volatile queries may be read **only** by the L9 emission join. The acceptance
test is uniform and cheap: insert a blank line above the item and assert the
value is still `isequal`.

The rule exists because volatile values never backdate. `derived_item_positions`
returns `CSTParser.EXPR`s, which compare by identity, so any edit anywhere in a
file produces a value that is never equal to its predecessor. Anything a later
layer needs must therefore be *recorded as plain data*, never recovered from
syntax. Request-time handlers may read positions; derived values may not.

**C2 — Cross-item dependency is allowed; cross-item *body analysis* is not.**
The existing rule is that a derived value may not depend on another file's
analysis, because `derived_file_analysis` is an expensive *per-file* pass and
checking one call would otherwise drag in most of a package. Per-item lowering
changes that arithmetic: pulling in one callee item is not pulling in its whole
file.

So the constraint is relaxed in exactly one place. L8 inference of a call
resolves the callee's **summary** — `derived_item_return_summary`, a small
plain-data value — never the callee's full lowering or inference. Summaries
backdate hard: editing a body without changing its return type invalidates
nothing downstream.

**The summary is a fixed point, not a projection**, and the document should not
pretend otherwise. Computing a callee's return type requires inferring its body,
which requires the summaries of everything *it* calls. Memoization means each
summary is computed once, so the steady-state cost is fine; the risk is the cold
path, where the first query into a densely-connected module drags in a large
transitive closure, and recursion in the call graph forces a fuel-limited fixed
point that degrades to "nothing known" (§4.2's discipline, applied to types).

This is the riskiest claim in the document, and the one cost here with no
proposed bound. It is measured before it is built (§5.2) — as edges *and* as
cold-query latency, because the two fail differently.

**C3 — Structurally comparable, and small.** Salsa.jl has no interning, so early
exit compares the whole value. Every new record gets `@auto_hash_equals` and an
explicit equality audit against the known traps:

- empty `UnitRange`s compare equal regardless of position, so any range-carrying
  record needs endpoint-aware equality or it backdates stale;
- leaf values must compare *typed* — `BodyTree` already does
  `typeof(a.val) === typeof(b.val)`, so `1` and `Int8(1)` differ;
- `FakeTypeName`, `VarRef`, `FakeUnion`, `FakeUnionAll`, `FakeTypeVar` and
  `FakeTypeofBottom` define `==` and `hash`; `DataTypeStore`, `MethodStore`,
  `FunctionStore` and `ModuleStore` define neither and fall back to `===`,
  field-wise egality over `Vector` fields, which never holds for two separately
  built stores. They may be consulted at query time and never stored. Store the
  minimal plain-data fingerprint a value actually depends on.

Keep records shallow — and note that the pressure starts at **L6, not L8**.
`ItemLowering` already carries a vector of 13-field `LoweredBinding`s plus every
`BindingUse`, which for a large function is hundreds of entries compared in full
on each early-exit check; StaticLint's per-item footprint was nothing like that.
The comparison fails fast whenever the bindings genuinely changed, so the
expensive path is exactly the one worth paying for — body changed, bindings did
not, e.g. editing a string literal — which makes the strain real but
self-limiting. Interning in Salsa.jl is the lever if that stops being true, and
L8's type values are where it would stop.

**C4 — Early cutoff lives at the projection, not at the key.** Per-root or
per-file index, plus tiny per-key projection queries. Never key a node per name
if computing it reads every file — that is the dominant term in the size of the
dependency graph, hence in the cost of every incremental re-verification. The
existing arities index is shaped this way for exactly that reason: keyed per
root, projected per `(path, name)`, so an untouched name's consumers backdate
even when the index itself changed.

**C5 — Three-valued everywhere.** *Known* / *confirmed absent* / *unknown*.
Unknown never fabricates and never flags. Tolerance is **per consumer**, because
the harm differs: a diagnostic that declines produces nothing, a completion list
that omits a name is right while one that invents a name is fabrication the user
can accept, and hover renders what it knows rather than synthesizing a signature
it does not have. Per §1.2, the three values must be carried *inside* analyses,
not used to gate whole items.

**C6 — The runtime is touched only on the dispatch loop.** Indexing results and
any expansion results arrive as inputs through `process_from_dynamic`, exactly
like environment readiness today. No derived query may request, spawn, or wait
for one.

### 2.1 Malformed input is the common case

Every contract above is stated for a well-formed file. In an editor the file is
malformed most of the time — mid-identifier, unclosed block, half-typed call —
so the behaviour of the boundaries under bad input is not an edge case, it is the
steady state. Two failure modes need answers.

**Item-id stability under error recovery.** Ids are content-hashed on
`(coarse kind, name as written, in-file module path)` with a positional bucket
among statements sharing that key. If the parser's error recovery reshapes item
boundaries — merging two statements, swallowing a following definition into an
unclosed block — ids downstream of the error can shift, and shifted ids collapse
the per-item boundary wholesale. A single character that briefly breaks the file
would then churn the whole file's analysis twice: once on breaking, once on
fixing. **The requirement is that a parse error must not shift the ids of
well-formed items elsewhere in the file**, and it is a test, not an aspiration
(§5.1, gate 3).

**Tolerance, not persistence.** The prototype's answer to an item it cannot lower
is `status = :error` with no findings, so diagnostics blink out while typing and
return when the file parses again. The tempting fix — keep serving the last good
result — cannot live in the query graph: a derived query is a pure function of
its inputs and has no way to express "prefer my previous value to this one".
Persistence would have to be an input, or the host's decision not to publish.

So the answer is to make the analysis *tolerant* rather than the cache sticky:
trim error nodes before lowering, retry with macrocalls removed when expansion
fails, and return a partial result for the parts that did lower. That produces a
good answer instead of no answer, keeps the query graph pure, and is what JETLS
already does (§6.2). Where tolerance genuinely cannot recover, the item
contributes nothing and the surrounding items are unaffected — which is only true
if the first requirement above holds.

---

## 3. Dependency knowledge: enrichment at index time

T1 is the expected path, so what the `.jstore` contains determines what the
engine can do. Today it contains what *runtime introspection* can see, and that
is the right primary source: `DataTypeStore` carries a resolved `super`,
`parameters` and field `types`; `MethodStore`s exist for methods created by
`@eval` loops, `Requires`, generated functions and `__init__`, which no parser
can see; `@static if VERSION` branches resolve to the branch actually taken; and
re-export chains are already resolved through `VarRef`.

Source parsing is *weaker* than introspection on all of that. In Julia
specifically — where metaprogramming is dense in a way it is not in Rust — a
source-only dependency index would systematically under-report. rust-analyzer
parses dependency sources because Rust's item structure is syntactically
manifest. Ours is not.

But three things are structurally absent from an introspected store, and no
amount of indexing effort will put them there:

1. **What a macro declares.** `@declare_input` appears as a `FunctionStore` with
   `MethodStore`s for the macro function itself. Its *expansion behaviour* is
   nowhere. This is the gap that matters most, because macro modelling is a core
   mechanism at T0/T1 rather than a fallback.
2. **Definition positions for non-method bindings.** Only `MethodStore` carries
   `file` and `line`. A dependency's `struct`, `const` or module has no position
   at all, so go-to-definition into one has nothing to aim at (a type's
   constructor methods approximate it; a `const` does not).
3. **Which names came from where** in a re-export or conditional-branch sense,
   beyond what `VarRef` already resolves.

**The decision (D8): fill these at indexing time by parsing the package's
sources, in the same pass that already loads it.** The indexer holds both the
loaded module and the source on disc at the same moment, so enrichment costs one
pass per package version, lands in an artifact that is already cached and
shared, and leaves exactly one code path at query time. A separate parallel index
would be a second thing to keep in sync for no gain.

### 3.1 What this adds, and what it costs

The store format goes v3 → v4, adding macro declaration records and definition
positions for `DataTypeStore` / `GenericStore` / `ModuleStore`. The existing
back-compat positional-constructor pattern in `symbols.jl` is the precedent for
the transition; old stores must keep loading.

**It must run in the cloud indexer as well as the local child.** Otherwise
downloaded caches become second-class — which matters more than usual, since they
are currently emitting exports-only stores.

**Two costs to measure rather than assume.** Indexing the julia-vscode workspace
took roughly 5.5 minutes for 134 environments and wrote ~94 MB of jstores when
last measured (2026-07-24). The macro half can be gated behind a cheap pre-scan
for files containing `macro `, but positions require parsing every file, and
per-binding positions grow the store. Both belong in §5.2's measurement.

### 3.2 The honest limit of the macro half

Deciding from `macro declare_input(ex)`'s source that it declares `foo`,
`set_foo!` and `delete_foo!` means reading the quoted body and recognising the
name-construction pattern — `$(esc(name))`, `Symbol("set_", name, "!")` and
friends. That is a mini-expansion: tractable for common shapes, not in general.

So enrichment **raises the ceiling** on macro modelling and turns hand-written
models into derived ones with partial coverage. It does not make the modelling
problem disappear, and unrecognised macros remain *unknown* (C5), never assumed
inert.

Main already confirms macro identity two ways, and one of them is fully
runtime-free: for a registry dependency it asks the environment store
(`macro_store_target`, following re-export chains), and for a path/deved
dependency — which has no store entry at all — it reaches the owner package's own
module tree and asks whether *that* module declares the macro. Enrichment
generalises the second, structural proof to registry dependencies.

---

## 4. The expansion protocol (T2, optional)

With §3 in place, live expansion's remaining job is narrow: macros whose
declaration shapes enrichment could not recognise, and expansions whose *content*
— not merely whose declared names — a consumer needs. The protocol is specified
here so the seam is right, and is explicitly not on the critical path.

C6 creates the central tension: a derived query *discovers* that it needs an
expansion, but may not ask for one. The resolution is that demand is discovered
purely, published on the loop, and served as an input.

```
derived_file_expansion_requests(uri)      pure: BodyTrees + DefMap identify the macro
        │
        │  read on the dispatch loop
        ▼
   _reconcile!  ──diff vs served──▶  ExpandMsg to the DJP child
        │                                    │
        │                                    ▼  macroexpand in the real environment
        │                            ◀───JSONRPC───
        ▼
   process_from_dynamic ──▶ input_expansions (one collection input)
        │
        ▼
   derived_expansion(key)                 tiny per-key wrapper: early cutoff
        │
        ▼
   derived_item_lowering                  splices the expansion in
```

Neither end is new machinery. `_reconcile!` already computes which dynamic
processes are required and notices when that set changes. A single collection
input with per-key derived wrappers is the pattern `inputs.jl` uses for the
readiness collections today.

**The expansion key is content-addressed**, never positional: `(macro name as
written, resolved owner, argument BodyTree hash, callsite module path,
environment fingerprint)`. Identical macrocalls share one expansion, and moving
code never re-requests one.

### 4.1 Four consequences that need deciding, not discovering

**`__source__` is a position.** A faithful expansion of `@__LINE__`, or of
`@test` recording its source, depends on where the call sits — which breaks C1
outright. The child expands with a **canonical sentinel `__source__`**, and
macro-synthesized nodes inherit the *call site's* address. Right shape,
meaningless line number inside expansions: the correct trade for analysis, and a
documented deviation from Julia semantics.

**Addresses become two-component.** The prototype anchors provenance with
`LineNumberNode(addr)`, which cannot distinguish address 7 in the item from
address 7 in an expansion. It widens to `(expansion_id, addr)`, with
`expansion_id = 0` meaning source.

**Scope layers and provenance must be serialized, not just the tree** (§6.2).

**Expansion runs arbitrary user code on the edit path.** The child already loads
packages, so the trust boundary is not new — but the *frequency* is. Mitigations:
per-expansion timeout, fuel and depth limits, a deny-list, the existing
child-death recovery path, and content-addressing to keep the request rate down.
This is also why T2 must remain optional rather than becoming the assumed path.

### 4.2 Pending, absent, unknown

An item whose expansion has not arrived is in exactly the state T0 and T1 are in
permanently, so it uses the same machinery: the modelled-macro tables, scoped
suppression, and three-valued analyses (§1.2). There is no separate "degraded
while waiting" mode, which is the main structural benefit of treating T2 as
optional.

"Macro confirmed not to exist" is a *different* outcome and is a real diagnostic.
A third state is still owed: a macro that cannot be resolved at all should
produce a **recorded** outcome rather than silence. Today the unknown case
records nothing and emits nothing, relying on the pre-existing
failed-wildcard-`using` suppression to stay quiet — which happens to work,
because the same store gap that hides the macro also makes `using Salsa`
unresolvable and flags the whole module blind. That coincidence is not a design.

### 4.3 The cycle, and why it does not close

A module's declarations must sit above enrichment and expansion, but identifying
*which* macro a macrocall means requires knowing the module's imports. Naively
that is circular:

```
visible_names → module_tree → items → (macro identity) → visible_names
```

Only one edge closes it: `visible_names → declared`. A module's *classified
imports* do not participate — they are collected verbatim in one pass and
classified in a second without reading `declared` — and neither does the
environment.

So the judgement lives in its own node that reads classified imports and `env`,
and **visibility unions its result with `declared`** rather than the tree
incorporating it. Nothing in that node reads `declared`, the loop never closes,
ordering suffices, and nothing has to iterate. It also confines the env
dependency to one small node instead of putting it under the whole tree — which
matters less than it sounds, because `ExternalEnv` defines `isequal`/`hash` over
entrywise store identity specifically so a rebuilt-but-unchanged env backdates:
the edge costs invalidation at indexing transitions, not per keystroke.

Julia's `@reexport using Foo` is the shape that would eventually force a real
fixed point. Build one round; keep the structure loop-friendly; do not build the
worklist yet.

---

## 5. Migration

Sliced by **observable case**, not by layer. The layer-shaped alternative reviews
badly and hides its defects until integration.

| Slice | Observable outcome | Depends on |
| --- | --- | --- |
| **S1** Unused bindings | `unused_binding` / `unused_function_argument` served by lowering | — (on branch, flagged) |
| **S2** ItemTree on v2 | *Refactor slice — see below* | S1 |
| **S3** DefMap + global resolution | `missing_reference` served by L5 + L7 | S2 |
| **S4** Store enrichment (v4) | go-to-definition into a dependency's `struct`/`const`; macro-declared names from registry dependencies | S3 |
| **S5** Undef / dead-store / unreachable | three-valued use-before-definition diagnostics | S1 |
| **S6** Linear IR + inference | a local's inferred type in hover → `x.` completions → cross-file type-aware method matching | S3, **measurement** |
| **S7** CSTParser removal | the memory number | S2–S6 |
| **S8** Live expansion (T2) | coverage for macros enrichment could not model | S4, optional |

**S2 is the one slice with no user-visible behaviour, and that is worth naming
rather than dressing up.** Its acceptance is measurement, not behaviour. Two
things go away with it: the double parse (§7.4), and the CST↔v2 byte-matching
layer (§7.3), whose failure mode is items silently vanishing from analysis.

**S5 no longer waits on expansion**, for the reason given in §1.2.

**S8 is last and optional.** Nothing above it may depend on it.

### 5.1 The parity gate

Identical for every takeover.

1. **Corpus sweep.** Both engines over the julia-vscode repo and a fixed registry
   package set. Every difference classified as fixed-FP / fixed-FN / **new-FP** /
   new-FN / message-only. Ship at zero new false positives, or with each one
   individually signed off.
2. **Tier containment.** Run the corpus at T0, T1 and T2 and assert
   findings(T0) ⊆ findings(T1) ⊆ findings(T2). A verdict that *changes* between
   tiers is a soundness bug at the lower tier, not an improvement at the higher
   one. Crossed with `DynamicOff` / `DynamicIndexingOnly` / `DynamicPersistent`,
   and with same-file / cross-file / cross-env.
3. **Backdating and malformed-input tests.** The blank-line test, per new
   analytic query. Plus, per §2.1: introduce a parse error in the middle of a
   file and assert that the ids of well-formed items elsewhere are byte-identical,
   and that their analysis backdates rather than recomputing.
4. **Graph budget.** Node and dependency-edge counts before and after on the
   julia-vscode repo. Superlinear edge growth is a rejection, not a follow-up.
5. **Latency and memory.** lsbench against the 2026-07-24 baseline.

`input_lowering_lint` generalises from a single flag to a per-rule takeover set,
so each slice flips and rolls back independently.

### 5.2 What must be measured, and when

**Before S4 ships**: added index time and added store size from enrichment, on
the julia-vscode workspace (baseline: ~5.5 min for 134 environments, ~94 MB of
jstores), separated into the macro half and the positions half so either can be
dropped on its own.

**Before S6 exists**: build only the **records and the index** — syntactic type
records per parameter, a per-root index, per-`(path, name)` projections, and
`derived_item_return_summary` — with no resolution and no inference. Then measure

- dependency edges added per item;
- re-verification time after a single keystroke in a hot file;
- **cold-query latency for the worst transitive closure** — the first query into
  the most densely-connected module in the corpus, since the summary is a fixed
  point rather than a projection (C2) and this is the term that fails separately
  from edge count;
- the summary layer's memory.

If the budget blows, C2's relaxation is withdrawn and inference falls back to
signature-only cross-item information. **That decision is made on numbers, before
any inference code exists.**

### 5.3 Risks

- **Memory goes negative before it goes positive.** Until S2 and S7 the workspace
  holds three trees per file — CSTParser, JuliaSyntax v1, JuliaSyntax v2 — plus
  BodyTrees. For scale: LS RSS on the julia-vscode repo measured 3.2–4.9 GB on
  2026-07-24, and a separate heap-composition analysis attributed roughly 869 MiB
  of that to holding *two* syntax trees per file. S2 and S7 are what pay for
  lowering; the third tree's real cost should be measured, not extrapolated.
- **Enrichment inflates the index**, in time and in bytes (§3.1, §5.2).
- **Upstream churn** in JuliaLowering and JuliaSyntax v2, mitigated by the
  vendoring discipline in §7.1.
- **Julia 1.12 is a hard floor** (D5). The language server runs in the *user's*
  Julia, so this is a support drop for 1.10 and 1.11 users, taken deliberately
  rather than implied.

---

## 6. Prior art

### 6.1 rust-analyzer

Quotes are from `rust-lang/rust-analyzer` master as fetched on 2026-07-31; names
drift, so treat them as of that date.

- **The firewall is the same, for the same stated reason.** `ItemTree`
  "condenses a single `SyntaxTree` into a `summary` data structure, which is
  stable over modifications to function bodies", under the invariant "typing
  inside a function's body never invalidates global derived data". That is our
  ItemTree/BodyTree split; their `AstIdMap` is our volatile position maps. C1 and
  C2 are their invariant, arrived at independently.
- **Module scope is defined as post-expansion.** `DefMap` "stores the module tree
  and the definitions that are in scope in every module **after item-level macros
  have been expanded**", and the phases of import resolution and macro expansion
  are described as "mutually recursive" with no strict ordering.
- **The cycle is resolved by iterating, with explicit fuel.**
  `DefCollector::collect` runs a `resolution_loop()` over worklists of unresolved
  imports and macros; `FIXED_POINT_LIMIT = 8192`, `GLOB_RECURSION_LIMIT = 100`,
  and an expansion-depth check. Macros that never resolve are *not* dropped
  silently — `finish()` emits `unresolved_macro_call` diagnostics. Our §4.3
  argument is that our edges make one round exact rather than merely adequate, so
  we need the fuel only if we later support macro-generated `using`; the recorded
  outcome we owe regardless (§4.2).
- **An expansion is a first-class file.** `HirFileId` is an enum over a real file
  or a `MacroFile`, "allowing both to be treated uniformly";
  `parse_macro_expansion` is a tracked query; `ExpansionInfo` maps tokens
  bidirectionally, which is what makes go-to-definition work across a macro.
- **Items inside bodies get their own map** (`block_def_map`, computed lazily) —
  our `@testitem` body is their block expression.
- **Types stay syntactic until a later query.** "Paths in these are not yet
  resolved. They can be directly created from an `ast::TypeRef`, without further
  queries", with an `Error` variant for what cannot be represented. Record, then
  resolve.
- **Per-def, not crate-wide**: "rust-analyzer does not want a crate-wide analysis
  though as that would hurt incrementality too much."
- **Interning removes our C3.** Their HIR types are interned, so comparison cost
  is paid once at construction. Our Salsa port has no interning and its early exit
  is `isequal` over the whole value, which is why C3 binds us and not them.

Where we deliberately diverge: they parse dependency sources and expand macros
eagerly, because Rust's item structure is syntactically manifest. Julia's is not,
so our dependency knowledge comes from introspection with source parsing filling
named gaps (§3) — the opposite arrangement, for a language-shaped reason. They
also *run* macros; we model a handful and must degrade gracefully for every
other, which is why "decline to judge" is a first-class outcome here and not
there.

### 6.2 JETLS.jl

`aviatesk/JETLS.jl` is a language server built on the same JuliaSyntax v2 and
JuliaLowering foundation, without Salsa. It is MIT licensed, and it has already
solved a large part of L6's surface.

| JETLS | What it provides | What it replaces here |
| --- | --- | --- |
| `jl_lower_for_scope_resolution` (`utils/binding.jl`) | passes 1–3 with `trim_error_nodes` and `recover_from_macro_errors` — on macro-expansion failure it trims macrocalls and retries | the prototype's blanket `try`/`catch` → `status = :error` (§7.6) |
| `trim_error_nodes`, `repair_after_trim` (`utils/ast.jl`) | lowering half-typed input, which an LS does constantly | nothing — the prototype simply errors the item |
| `compute_binding_occurrences` (`analysis/occurrence-analysis.jl`) | per-binding `:decl` / `:def` / `:method_def` / `:use` occurrences, with same-location merging for kwarg defaults, `@generated` static parameters and closure-duplicated patterns | the hand-rolled `decl_of` / `used_addrs` heuristic in §7.7, which reinvents this and handles fewer cases |
| `analyze_all_lambdas` (`analysis/cfg-analysis.jl`) | event-block CFG giving **three-valued** undef analysis, dead-store detection and unreachable-code detection | nothing — and its three-valued result is what makes S5 shippable under permanent macro opacity (§1.2) |
| `InertResolution`, `prepare_inert_template`, `quote_stage_depth`, `is_esc_call` | principled analysis of code inside quotes and macro bodies | `_collect_quoted_identifiers!` (§7.5), a blunt "everything mentioned counts as read" |
| `select_macrocall_binding`, `select_export_public_binding`, `select_import_using_binding`, `select_struct_inner_constructor_binding` | the awkward positions where lowering yields no binding: export lists, import clauses, inner constructors | the long tail that otherwise consumes months of goto/hover/rename bugs |
| `lowerable_toplevel_at`, `iterate_toplevel_tree`, `byte_ancestors` | cursor → enclosing lowerable top-level item | the fragile first-byte matching S2 removes (§7.3) |
| `is_relevant`, `binding_has_source_name` | hygiene filtering for completions: drop compiler- and macro-generated names | nothing |

**The integration constraint.** All of these take live
`ctx3::JL.VariableAnalysisContext` and `SyntaxTree` values — identity-compared,
position-carrying objects that must never enter a derived value (C3). They are
used *inside* the pure function that runs the passes and projects to plain data,
never at a query boundary. That is a clean fit, because they are pure functions
over lowering output.

**A finding that shapes §4.** JETLS's hygiene analysis is provenance-based.
`binding_scope_layer` walks `st3.source` chains looking for a
`SyntaxContext.layer`, with the comment *"JuliaLowering also throws away this
information in resolve_scopes. Go backwards through lowering to search for it."*
`binding_has_source_name` similarly walks `flattened_provenance`.

Those layers are created during **in-process macro expansion**. If a child ever
expands on our behalf (T2), the payload must carry scope layers and provenance
edges alongside the tree, or the parent cannot distinguish a macro-generated name
from a user-written one and every hygiene filter above stops working. At T0 and
T1 there is a single layer and the question does not arise — another reason the
static path is the simpler one.

A smaller note: JETLS lowers with `JL_OLD_SYNTAX_VERSION` where the prototype
uses `JL_NEW_SYNTAX_VERSION`. Which is right for us should be decided rather than
inherited.

**Not applicable.** `analysis/Analyzer.jl` and `analysis/full-analysis.jl` are
JET- and `Compiler.jl`-based abstract interpretation — the road not taken (D2).
`analysis/TypeAnnotation.jl` is worth revisiting when S6 comes up.

---

## 7. What the prototype implements

`origin/bodytree` is roughly 1,600 lines across 13 files excluding vendored code,
last touched 2026-08-12, and 26 commits behind main — though main's changes since
are almost entirely inside `src/StaticLint/`, which this design retires, so
rebase risk is low. It is described here in full so this document does not
require reading the branch.

### 7.1 Vendoring

`src/vendor_lowering.jl` defines a `VendoredLowering` module that includes the
vendored JuliaSyntax v2 verbatim (self-contained, stdlib imports only) and then a
`baremodule JuliaLowering` mirroring upstream's own module file. **Vendored files
are never patched**; the wrapper owns every deviation, and the deviation list is
kept in sync against a recorded upstream SHA. The deviations are:

1. `using ..JuliaSyntax` (the vendored sibling) instead of upstream's
   `parentmodule === Base` switch;
2. `isdefined` instead of `isdefinedglobal`;
3. `syntax_macros.jl` excluded — it defines new-style macro methods on Base macro
   functions, i.e. method-table additions to Base inside the LS process, and is
   unreachable with expansion off;
4. `precompile.jl` excluded and no `__init__` — kind registration at include time
   is baked into JW's pkgimage;
5. `_include` paths point into `packages/JuliaLowering/src/`;
6. `DEBUG = false` — drops assertion bodies and profiling zones, measurably
   cheaper to precompile and to run.

`packagedef.jl` binds `JS2`, `JL2` and `V2Kind` *before* including the lowering
layer, because that file's qualified string macros (`JS2.K"..."`) resolve `JS2`
at expansion time. `Project.toml` moves to `julia = "1.12"`.

### 7.2 BodyTree: the position firewall

```julia
struct BodyTree{K}
    kind::K
    val::Any
    children::Union{Nothing,Vector{BodyTree{K}}}
    hash::UInt64
end
```

`K` is a 16-bit primitive kind type — the registered JuliaSyntax `Kind` for the
parse-facing forest, the vendored v2 `Kind` for the lowering forest. Leaves carry
their parsed value; the structural hash is computed once at construction so
Salsa's early-exit comparison is cheap. Equality is structural and slightly
stricter than leaf `isequal`: leaf values must agree in *type*, so `1` and
`Int8(1)` compare unequal.

The contract: a `BodyTree` contains only plain data — never a byte offset, an
EXPR/SyntaxNode reference, an objectid, or a runtime handle. Two trees are
`isequal` iff the item's parsed content is identical, regardless of where the
item sits in the file or what whitespace and comments surround it. That is what
makes `derived_item_body` backdate.

Positions live in a parallel structure produced by the *same* preorder walk, so
addresses always line up: node address = preorder index, root = 1, and
`derived_file_body_maps(uri)` returns, per item id, a vector whose entry `i` is
the byte range of the node at address `i`.

Queries: `derived_file_body_forest(uri)` (one parse per recompute),
`derived_item_body(ref)` (per-item wrapper so early exit fires per item, not per
file), `derived_item_body_hash(ref)` (the cheap "did this item change" gate), and
the volatile `derived_file_body_maps(uri)`.

### 7.3 Item association, and why it is fragile

Item ids are minted by the CSTParser-based `_foreach_toplevel_item`, the single
source of truth for ids, while bodies are built from the JuliaSyntax parse of the
same content. The two are matched **by first byte** — CST offsets are 0-based,
JuliaSyntax bytes 1-based — with two corrections:

- `_content_start` advances past whitespace, because a node's byte range can
  begin on the trivia before its first token (`@inline f(x) = x` starts the `=`
  node on the space before `f`) while inventory offsets point at the token;
- the file's root `toplevel` node is skipped, since it shares its first byte with
  the first item and an outermost-wins rule would map that item to the whole file.

An item whose start byte has no matching node is **skipped silently** — absence,
not an error. Module items are deliberately given no body tree: it would
duplicate every inner item's tree and churn on any edit inside the module.

This matching layer exists solely to reconcile two parsers, and it is what S2
deletes.

### 7.4 The v2 forest

`layer_lowering.jl` carries a twin of the above against the vendored v2 parser:
`derived_file_lowering_forest`, `derived_item_lowering_body`, and the volatile
`derived_file_lowering_maps`. Two differences from the v1 twin matter.

**The v2 index keeps the WIDEST node per starting byte, not the first seen.**
Several nodes share a first byte — `f(x, y) = x` starts both `=` and `call` at
`f` — and only the widest is the whole item. Preorder order alone picked the
inner `call` for `@inline f(x, y) = x`, which materialised the signature without
its body and hid every binding in it.

**It stops descending under a macrocall it cannot interpret.** Below such a call
the macro decides what its arguments mean, so a nested definition must not be
analysed as one: `@define_diffrule Base.:+(x) = :(1)` looks like a method, but `x`
is pattern syntax that cannot be removed. This is deliberately a **blocklist**
(`DEFINITION_SHAPED_DSL_MACROS`: `define_diffrule`, `with_kw`, `with_kw_noshow`,
`attributes`), not "everything we cannot expand" — the broad rule was measured on
the corpus and cost far more than it saved, also suppressing definitions under
`@static if` and under `Core.@doc`, i.e. *every docstring'd definition*, adding
~353 false negatives to remove ~13 false positives.

Both forest and map call `JS2.parseall` inline through the same helper, so the v2
parse currently happens **twice per file and is not memoized**. S2 fixes this.

### 7.5 Materialisation

A `BodyTree` is turned back into an ephemeral v2 `SyntaxTree` before lowering.
Every node's `source` is `LineNumberNode(preorder address)`, so pass-output
provenance chains terminate at address anchors rather than at file positions.
This is the mechanism that lets the position firewall survive lowering, and it is
the prototype's central discovery.

Four cases are handled specially, and only in **evaluated positions**
(`qdepth == 0`; quote depth is tracked exactly as JuliaLowering does, with
`quote`/`syntaxquote` deepening and `$`/`syntaxunquote` unwrapping):

- **Structurally transparent macros** (`TRANSPARENT_MACRO_NAMES`: `inline`,
  `noinline`, `propagate_inbounds`, `generated`, `assume_effects`, `constprop`,
  `pure`, `nospecializeinfer`, `nospecialize`, `specialize`, `inbounds`) unwrap to
  the form they wrap, which is always the last argument. Names are matched on the
  trailing leaf and without the leading `@`, so `Base.@propagate_inbounds`
  matches. Skipped children still consume their addresses via `_bt_node_count` so
  numbering stays aligned with the volatile map. Without this, `@inline f(x, y) =
  x` hides the whole definition and `f(@nospecialize(x::Int), y) = 1` hides the
  whole signature — between them the largest single source of missed bindings in
  the corpus sweep.
- **Test-block macros** (`TEST_BLOCK_MACRO_NAMES`: `testitem`, `testset`,
  `safetestset`, `testmodule`, `testsnippet`) materialise their trailing block
  wrapped in a synthetic `let` with empty bindings, because a test block runs in
  its own scope and its assignments are locals rather than module globals. Only
  the *block* form qualifies: `@testset for i in …` binds its loop variable in the
  macro, so that shape stays opaque. This is deliberately **not** the same
  judgement as the inventory's isolated-scope rule, which governs whether
  definitions inside the block become module-level items; they stay isolated
  there.
- **Opaque macrocalls** become a `block` of the `Identifier` leaves found anywhere
  in their arguments, each kept at its *original* preorder address, terminated by
  a `Value(nothing)` placeholder carrying the macrocall's own address. Macro names
  themselves parse as identifiers spelled `@name` and are excluded. The rationale
  is StaticLint's transparent-traversal precedent — a macro may read whatever
  identifiers appear in its arguments — and it is conservative in the right
  direction for unused-binding analysis, causing false negatives only. It is also
  why the prototype parks use-before-definition analysis: a synthesized read may
  precede the real assignment. The block is the intended splice point for T2.
- **Quotes entering from evaluated code** are paired with plain reads of the
  identifiers they mention, the quote itself staying last so the block's value is
  unchanged. Lexically a variable used only inside a quote *is* unused, but that
  is the wrong answer for a linter: renaming it changes what the quoted code
  means, and for `@generated` bodies it breaks the generated method outright.

Inside a quote none of this applies — a macrocall there is data, never expanded,
and flattening it would destroy the `$` interpolation nodes the quote's own
expansion needs.

### 7.6 The lowering frame

`_lower_item(body)` is a pure function of the body value: no position map, no
file content, no runtime state escapes into its result.

```julia
world  = Base.get_world_counter()
anchor = Module(:JWLoweringAnchor)
ex0    = JL2.rebase_layers(st, anchor, JL2.JL_NEW_SYNTAX_VERSION)
ex1    = JL2.expand_forms_1(ex0, world, true)
ctx2, ex2 = JL2.expand_forms_2(ex1, world)
ctx3, ex3 = JL2.resolve_scopes(ctx2, ex2; soft_scope=false)
```

Macro expansion is skipped — macrocalls were already replaced during
materialisation. The anchor module is empty and throwaway, so every global
resolves against it and shows up with `mod == "JWLoweringAnchor"`; those are
precisely the names L7 will resolve. The emptiness is not a convenience: it is
what makes lowering an item in isolation sound, and therefore what makes the
per-item recomputation boundary legitimate (D4).

The projection to plain data:

```julia
struct LoweredBinding
    id::Int32; name::String; kind::Symbol   # :local | :global | :argument | :static_parameter
    addr::Int32                              # declaration site, 0 if unknown
    mod::Union{Nothing,String}               # a module NAME, never a Module
    is_internal::Bool; is_const::Bool; is_ssa::Bool; is_captured::Bool
    is_read::Bool; is_assigned::Bool; is_used_undef::Bool; is_ambiguous_local::Bool
end
struct BindingUse   addr::Int32; binding::Int32 end
struct LoweringFinding  addr::Int32; msg::String end
struct ItemLowering
    status::Symbol                           # :ok | :error
    findings::Vector{LoweringFinding}
    bindings::Vector{LoweredBinding}
    uses::Vector{BindingUse}
end
```

Uses are collected by walking for `K"BindingId"` nodes. Everything degrades: a
`LoweringError` contributes its first tree's address and first message, a
`MacroExpansionError` its node and message, anything else a truncated
`showerror`; a projection failure empties the bindings and records a finding.
Lowering never crashes the query. `derived_item_lowering(rt, ref)` depends *only*
on `derived_item_lowering_body`, never on a position map or on file content.

### 7.7 The lint takeover

`input_lowering_lint(rt)::Bool` gates everything. When false, nothing below the
gate is demanded and diagnostics behave exactly as before; the flag is checked
before the config so that with it off the only Salsa dependency is the flag
itself.

There are **no new rule ids**. The producer takes over
`LOWERING_TAKEOVER_RULES = {:unused_binding, :unused_function_argument}` from
StaticLint — same ids, severities, presets and `JuliaLint.toml` surface,
different engine. This is the mechanism every later slice reuses.

The query shape mirrors the syntax-rule engine: a position-free per-item query
that backdates (`derived_item_semantic_findings`), and a volatile per-file
emission join (`derived_semantic_lint_findings`) that is the only reader of the
address→range maps.

The interesting part is the used/unused judgement, because desugaring duplicates
a pattern into every closure or method it generates, and two cases pull opposite
ways:

```julia
[f(n) for (n, c) in d if g(c)]   # filter closure + body closure, each binding
                                 # both names and reading one; the variable IS used
f(a, b = default) = ...          # a forwarding method f(a) = f(a, d) that reads
                                 # `a` only to pass it on; an unused `a` IS unused
```

What separates them is *where* the read happens: a genuine use sits at a
different node than the declaration, while a synthesized forwarding read carries
the declaration's own address. So a declaration counts as used only when one of
its bindings is read at some **other** address. Bindings that are internal,
already read, address-less, or `_`-prefixed are skipped.

### 7.8 What this design changes in it

- L1 becomes a real memoized query; the two inline `parseall` calls go (S2, §7.4).
- Item ids move off the CSTParser walker, deleting §7.3's matching layer.
- Error handling adopts trim-and-retry rather than failing the item (§6.2).
- The §7.7 used/unused heuristic is replaced by proper occurrence analysis.
- `_collect_macrocall_identifiers!` and `_collect_quoted_identifiers!` are
  replaced by inert-resolution machinery — an upgrade of the same strategy, not
  an abandonment of it.
- Addresses widen to `(expansion_id, addr)` only if S8 is built.

**The macro tables are core assets, not fallbacks.** `TRANSPARENT_MACRO_NAMES`,
`TEST_BLOCK_MACRO_NAMES` and `DEFINITION_SHAPED_DSL_MACROS` are the T0/T1
mechanism, and the corpus evidence behind them (§7.4) is exactly the kind of
tuning the expected path lives on. Enrichment (§3) extends them with derived
entries; it does not retire them.

---

## 8. Lessons carried forward

Constraints this design inherits rather than rediscovers.

| Lesson | Where it binds |
| --- | --- |
| Volatile position queries must not be depended on by analysis — they return identity-compared values and never backdate | C1 |
| Cross-file analysis dependencies are what make linting one file drag in a package | C2, and the one deliberate relaxation |
| Only structurally comparable values may enter derived values; the stores compare by `===` | C3 |
| Store the minimal plain-data fingerprint, not the big object | C3 |
| Empty `UnitRange`s compare equal regardless of position, so cached structs backdate stale | C3's equality audit |
| Early cutoff lives at the projection, not at the node's key | C4 |
| Abstention beats guessing: guarded includes suppress all arms by design | C5 |
| …but blanket abstention is a bug when the abstaining case is the *normal* case | §1.2, §4.2 |
| Error tolerance is per consumer — a lint may decline where a completion may not fabricate | C5 |
| Only the dispatch loop may touch the Salsa runtime | C6 |
| Dependency-graph size is the dominant incremental cost term | C4, gate 4 |
| Item ids are content-hashed; same-keyed siblings still shift | regression test for any value carrying `ItemRef`s |
| Features must behave the same same-file, cross-file and cross-env | gate 2 |
| Vertical slices by case review well; layer specs with no observable behaviour do not | §5, with S2 named as the deliberate exception |
| Sample code inside a plan is where defects concentrate | the implementation plan, when it is written |
| `string(SourceText)` returns the repr and silently corrupts content in measurements | any harness written for §5.2 |
| A broad "suppress whatever we cannot understand" rule cost ~353 false negatives to remove ~13 false positives | §7.4, and the case for scoped suppression generally |

---

## 9. Decisions

Taken by Sebastian on 2026-08-13 and 2026-08-14.

- **D1 — Macro expansion in a live child process is optional (T2), not the
  baseline.** *Amended 2026-08-14; originally taken as the primary mechanism.*
  The engine must work as well as possible with nothing running. §4 keeps the
  protocol specified so the seam is right, and S8 schedules it last.
- **D2 — The pipeline runs through linear IR, with JW-owned abstract
  interpretation.** Lattice values are plain data backed by SymbolServer stores
  and workspace-declared types, reusing the existing subtype machinery. Rejected:
  stopping at scope resolution, and coupling to `Compiler.jl`'s
  `AbstractInterpreter`.
- **D3 — Full replacement, staged by rule and feature.** One tree, one semantic
  engine; item ids move off the CSTParser walker; StaticLint retires rule by rule
  through the takeover mechanism. Rejected: a permanent dual engine, and keeping
  the CST-derived item layer.
- **D4 — Globals resolve post-hoc against a JW-owned DefMap.** Lowering emits
  globals as named unresolved bindings; a separate query resolves them. The
  vendored JuliaLowering stays unpatched and the env edge stays confined to small
  nodes. Rejected: a resolver oracle inside lowering, and materialising real
  `Module`s.

  **This decision is load-bearing for the whole boundary structure, which is not
  obvious from either end.** Lowering one item in isolation is sound *only*
  because the anchor module is empty: globals come out unresolved by
  construction, so an item needs to know nothing about the rest of its module.
  Had the resolver-oracle option been taken, per-item lowering would have been
  incoherent — every item would depend on its module's name map — and the
  per-item boundary would collapse into a per-module one, taking the incremental
  story with it. Anything that later proposes resolving globals during lowering
  is proposing to delete that boundary.
- **D5 — Julia 1.12 is a hard floor**, documented as a support requirement.
  Rejected: a version-gated StaticLint fallback, and moving lowering into the
  child.
- **D6 — Propose a shared package to aviatesk** for the binding, scope and CFG
  utilities, rather than vendoring, reimplementing, or depending on JETLS
  wholesale. See §9.1.
- **D7 — T1 is the expected path.** T0 stays deliberately limited and serves as
  the soundness floor; features are designed for T1 and degrade at T0. jstore
  coverage is expected to be very high.
- **D8 — Missing dependency information is added to the jstore at index time by
  parsing package sources**, in the same pass that loads the package — not by a
  separate source-based index, and not left to query time. Format v4; must run in
  the cloud indexer as well as the local child. Rejected: a general source-based
  dependency index (weaker than introspection in a metaprogramming-dense
  language), and leaving the gaps unfilled.

### 9.1 Open questions

1. **Interim posture on the JETLS utilities.** D6 is the right long-term answer
   and the slowest to land, and it is not JW's decision alone. This design
   assumes the interim posture is *read as reference, implement against our own
   types, keep the boundary clean enough to swap for a shared package later* —
   deliberately not vendoring, because vendoring and then diverging is what makes
   a later extraction hard. **Stated, not decided**; needs confirmation, and the
   conversation with aviatesk should happen before S1 hardens.
2. **`JL_OLD_SYNTAX_VERSION` vs `JL_NEW_SYNTAX_VERSION`** (§6.2).
3. **Lowering granularity**: per top-level item, as the prototype does, or per
   body, as rust-analyzer does. Deferred; per-item is assumed throughout.
4. **How much of the macro-declaration pattern vocabulary to support** in
   enrichment (§3.2). A coverage/effort curve that wants corpus evidence.
5. **Whether enrichment should also emit a source-only store for packages that
   fail to load** — precompile failure, wrong platform, untriggered extension.
   Cheap given the parser is already there; out of scope until asked for.

### 9.2 Debts this design accepts

- A **recorded** outcome for macros that cannot be resolved, instead of the
  current silence-by-coincidence (§4.2).
- Recorded signatures for macro-generated methods. There is no expansion to
  re-print, so a renderer has nothing to work with; enrichment (§3) is where they
  would now come from.
- The measurements in §5.2 — the enrichment budget, and the cross-item dependency
  cost that C2's relaxation rests on.
