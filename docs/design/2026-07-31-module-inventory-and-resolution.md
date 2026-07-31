# The missing module inventory: resolving macros and types in the query graph

*2026-07-31 — discussion notes, not an implementation plan.*

*Every code claim below was checked against `main` at c5e4481 on 2026-07-31.
Three were checked by running the walker, the inventory classifier and
`collect_hints` rather than by reading; those are marked **measured**.*

## Summary

Two open problems in the analysis engine turn out to be one problem:

1. **Macros that declare callables the source never names.**
   `Salsa.@declare_input foo(rt, x::Int)::V` defines `foo`, `set_foo!` and
   `delete_foo!`. The analysis records *none* of the three (§1) — every use of
   any of them is a missing-reference diagnostic, and hover, completion and
   go-to-definition cannot see them either.
2. **Cross-file method matching stops at argument counts.** A call is checked
   against the *arity* of a callee declared in a sibling file, never against its
   parameter types.

Both need the same thing: a *name* recorded in a per-file, syntax-derived
summary must later be judged **semantically** — which module does this macro
name mean, which type does this annotation denote — and the judgement has to
happen somewhere legal in the query graph. For types there is such a place. For
macro-declared names there currently is not: the layer where the names must
appear is upstream of everything that could resolve them, and resolving them with
the machinery that exists closes a cycle.

The missing piece is a **per-module inventory**: a query keyed by
`(root, module path)` that answers "what does this module declare", sitting below
visibility and above the module tree's structure pass. rust-analyzer has exactly
this layer, defines it as *post-macro-expansion*, and builds it by fixed-point
iteration. We fused it into the tree walk, which is why there is nowhere to put
the judgement, and why item-level data is re-derived by four separate consumers.

One qualification the argument below arrives at: the macro half does not actually
need that layer. Once visibility *unions in* a separate module-keyed node rather
than reading everything through `declared` (§3, §14), macro-declared names have a
legal home without restructuring the tree. The per-module inventory is still worth
building — for §5's re-derivations and §17's signature records — but it is not what
unblocks `@declare_input`.

---

## Part I — The problem

### 1. Three macros, and where each one's difficulty actually lies

**`@kwdef` — modelled, and comfortable.** The struct is written out; only the
call *shape* is generated (`S(a, b)` plus `S(; a, b)`). The inventory records
what it sees; a consumer holding `env` and the module tree decides whether the
macro really is Base's before applying the generated shape. No information has to
flow backwards. This class is solved (§20, status).

**`@declare_input` — three names, none of which the analysis has.** The names
must reach the visibility index or every use is a false positive. That index is
upstream of everything that could resolve the macro. This is the hard case.

It is also worse than "two names are missing", **measured**: the statement
produces *no* inventory item at all, and `foo` is unresolved along with the other
two. The macrocall is transparent (it is not an
`_is_isolated_scope_macrocall`), so the walker descends and mints an id for the
*argument* `foo(rt, x::Int)::V` — but `_classify_item!` has no arm for a
`::`-headed statement, so it emits nothing; and StaticLint models
`@declare_input` nowhere (the string occurs only in `src/inputs.jl`), so no
binding is created either. On a fixture whose `@declare_input` is a locally
declared macro (so no failed wildcard `using` suppresses hints),
`collect_hints` flags both `foo` and `set_foo!` at their use sites. The
declaration-site `foo` is exempt via `in_macrocall_arg`, which is why the
declaration itself looks healthy.

Two consequences. The **primary** name has to be recorded too, not just the two
generated ones — and it is subject to the same confirmation (§14): a bare
`foo(rt, x)::V` at top level declares nothing in Julia, so `foo` exists only if the
wrapping macro is the one we think, exactly like `set_foo!`. All three names stand
or fall together. Second, because `foo` never reaches the module tree today,
cross-file uses of it fail structurally, so the visible symptom is not confined to
the two generated names — it is every use of every input.

**`@testitem` — names a macro injects, which the analysis models itself.**
`_handle_testitem` (`src/StaticLint/macros.jl`) builds a module-like scope for the
body and injects `Test` plus the enclosing package, simulating `using`. On the
live per-file path this never happens: `derived_file_analysis` calls

```julia
StaticLint.semantic_pass(file, cst, env, meta_dict, rt; module_context=ctx)
```

with no `workspace_packages` and no `self_package_name`, so
`state.self_package_name !== nothing` is always false and the package is never
injected. Measured against a fixture package exporting `bar`: inside a
`@testitem`, both `bar()` at the body's top level and `bar()` inside a nested
`function f()` have `hasref == false`, and hover returns `nothing` for both.

Only the nested one is *reported*, which is why this looks like a nested-scope
bug. `in_macrocall_arg` (`src/StaticLint/linting/checks.jl`) suppresses
missing-ref hints inside a macrocall's arguments but stops at the first
user-written scope — deliberately: "if a user-written scope sits between the
identifier and the macrocall, we assume the macro respects normal Julia scoping".
So an unresolved name is silently exempt at the body's top level and flagged
inside `for` / `let` / `function`.

The whole-closure pass did populate those arguments — by calling
`derived_deved_package_meta` and `merge_meta_dict!`-ing **another file's meta**
into this one, which is precisely the cross-file channel the per-file design
exists to close (§3, constraint 2).

But that channel was needed only for the `Binding` half. The *name* half needs
nothing of the kind: `self_package_name` comes from `derived_package_for_file` +
`derived_package` (`layer_static_lint.jl:128-138`) — per-file/per-root queries,
no other file's analysis — and `StaticLint.workspace_package_context(ctx, name)`
already exists for exactly this, implemented for `TreeModuleContext`
(`layer_file_analysis.jl:285`) and documented as the cross-root, per-file-mode
replacement for the whole-closure `workspace_packages` dict. It is what already
resolves an explicit `using SomeWorkspacePackage` on the per-file path
(`imports.jl:251`).

So this one *is* mostly "pass the arguments": plumb `self_package_name` into the
per-file `semantic_pass` call and have `_handle_testitem` inject
`workspace_package_context` instead of a merged `Binding`. It is a contained fix,
buildable now, and it does not wait on Part IV — unlike `@declare_input`, whose
names have no first-class route into the module at all.

### 2. Cross-file method matching stops at arity

The inventory records a `MethodArity` per callable and the module tree indexes it
per `(module path, name)`, so a call in file B can be checked against the full
method set of a callee declared in file A. That works for one reason only:
**arity is countable from the text alone.** No resolution is needed to know that
`f(x, y)` takes two arguments.

Types are where the free ride ends. `::AbstractDict` is a *name*; what it denotes
depends on the defining module's imports, on the environment store, possibly on a
`const` alias, possibly on a type declared in a third file. To match a call
against it you must resolve it — and the place that wants the answer (a
diagnostic) cannot get it by re-reading the defining file's syntax (§3,
constraint 1).

### 3. Why these are one problem

**A name is not an identity.** `@declare_input` from another package declares
nothing. `::Runtime` means Salsa's `Runtime` in one file and something else in
another. A written qualifier narrows it but does not settle it: `src/inputs.jl`
writes `Salsa.@declare_input` twelve times — all qualified — yet the qualifier
`Salsa` is itself a name, resolved through `using Salsa` in
`src/JuliaWorkspaces.jl`, a *different file of the same module*. So even the
qualified form needs the declaring **module's** imports, which are module-level,
not file-level, and so unavailable where the names are recorded. The bare form
needs them too, and is the harder case, but it is not the case this repo
actually exhibits.

**Three invalidation constraints shape every possible answer.** They are
properties of this engine, verified in the tree as of today:

1. *A derived value may not depend on `derived_item_positions`.* Its docstring
   states the rule: "Volatile: recomputes on every reparse … Depending on this
   query from any layer-1/2/3 computation is a bug." It returns `CSTParser.EXPR`s,
   which compare by identity, so any edit anywhere in a file produces a value that
   never backdates. Consequence: whatever a later layer needs must be *recorded as
   plain data*, never recovered from syntax. Request-time handlers (hover,
   completion) may use it; derived values may not.
2. *A derived value may not depend on another file's analysis.*
   `derived_file_analysis` is the expensive pass; if checking a call in A required
   the analysis of every file declaring a callee used in A, linting one open file
   would drag in most of the package.
3. *Only structurally comparable values may enter a derived value.*
   `shared/symbolserver/faketypes.jl:177-190` defines `==` and `hash` for
   `FakeTypeName`, `VarRef`, `FakeUnion`, `FakeUnionAll`, `FakeTypeVar` and
   `FakeTypeofBottom`. `DataTypeStore`, `MethodStore`, `FunctionStore` and
   `ModuleStore` define neither, so they fall back to `===` — field-wise egality
   over `Vector` fields, which never holds for two separately built stores. They
   may be *consulted* at query time and never *stored*.

**The direction of information flow is what separates the two problems.**

Type resolution flows *downstream*. The consumer is a diagnostic, which already
holds `env`, the module tree and meta. Nothing upstream needs the answer, so
there is a legal home for the resolution and no cycle.

Macro-declared names flow *upstream*. They must land in
`derived_module_visible_names`, which is built from the module tree, which is
built from inventory items. Resolving the macro with the machinery that exists —
`_annotation_macro_points_to`, which consults
`derived_module_visible_names_idfree` — closes the loop:

```
visible_names → module_tree → items → (macro identity) → visible_names
```

That single line is the whole difficulty, and it is why the macro half cannot
simply copy the type half's answer.

Note precisely *which* edge closes it: `visible_names → declared`. Only the
`declared` map participates. A module's **classified imports** do not — pass 1
collects them verbatim and pass 2 classifies them without reading `declared`
(§13) — and neither does the environment.

That is the way out, and it is narrower than "put the judgement in the tree": the
judgement lives in its own node that reads classified imports and `env`, and
**visibility unions its result with `declared`** rather than the tree
incorporating it (§14). Nothing in that node reads `declared`, so the loop never
closes, ordering is enough, and nothing has to iterate (§15). It also confines the
env dependency to one small node instead of putting it under the whole tree.

---

## Part II — What the layering has today

### 4. The queries

| Query | Key | What it is |
| --- | --- | --- |
| `derived_file_inventory` | file | per-file, position-free, plain-data item summary |
| `derived_item_positions` | file | volatile id → EXPR/offset re-attachment (request time only) |
| `derived_module_tree` | root | structure *and* declarations: files, includes, nesting, exports, imports, `declared` |
| `derived_module_declared` / `_names` / `_imports` / `_exports` | root, path | straight projections of the tree |
| `derived_module_visible_names(_idfree)`, `derived_visible_item` | root, path | visibility, from `declared` + imports |
| `derived_method_items`, `derived_method_arities(_index)` | root(, path, name) | per-name projections over a splice walk |

What is missing is anything keyed **per module** that carries the module's
*items* — their kinds, arities, signatures.

### 5. Two symptoms of that gap

**Item-level data is re-derived four times.** `ModuleNode.declared` collapses to
one `ItemRef` per name, so each consumer needing more goes back to the file
inventories independently: `_build_kind_index` for kinds, and
`_walk_spliced_binding_items!` three separate times — for `derived_method_items`,
for the arities index, and for `derived_external_method_extensions_index`. Four
traversals of the same data, because there is no module-level place to put it.

One of those is the very pattern the arities docstring warns about:
`derived_method_items(rt, root, path, name)` is keyed **per name** and walks
every file in the root. It is defensible as it stands — its only four callers are
request-time handlers (hover, signature help, references,
`layer_{hover,signatures,references}.jl`), so nodes exist only for names a user
actually pointed at, not for the thousands a lint pass would touch. But it is
the same graph-size term, and a per-module declarations node would absorb it:
an independent win, available whatever else §13 becomes.

**There is nowhere a judgement can legally happen.**
`derived_module_imports(rt, root, path)` is exactly the input needed to decide
whether a macrocall is Salsa's — but it is a *projection of* the tree, while
`declared` is built *inside* it. Using it during the walk is circular.

The funnelling that does exist shows the cost model. From
`derived_method_arities_index`'s docstring:

> The walk reads the inventory of *every* file in the root, so computing it per
> name made each of the (many thousands of) per-name nodes depend on every file —
> the dominant term in the size of the dependency graph, hence in the cost of
> every incremental re-verification.

Any new per-item data has to answer that same question: where does it live so
that neither the graph nor the recompute cost explodes.

---

## Part III — Prior art: rust-analyzer

Quotes fetched from `rust-lang/rust-analyzer` master on 2026-07-31; names drift,
so treat them as of that date. It is the closest prior art available — the same
problem, and a Salsa of the same lineage as ours.

### 6. The firewall is the same, for the same stated reason

`ItemTree` "condenses a single `SyntaxTree` into a `summary` data structure, which
is stable over modifications to function bodies", under the invariant "typing
inside a function's body never invalidates global derived data". That is our
`FileInventory`; their `AstIdMap` is our `derived_item_positions`. Our constraints
1 and 2 are their invariant, arrived at independently.

### 7. Module scope is *defined* as post-expansion

`DefMap` "stores the module tree and the definitions that are in scope in every
module **after item-level macros have been expanded**"
(`hir-def/src/nameres.rs`). The module docs describe the algorithm as
"import-resolution/macro expansion" whose phases are "mutually recursive" with no
strict ordering.

So the layer that answers "what is in scope in this module" *is* the layer that
expands item-position macros. No earlier layer is asked to guess, and no later
layer has to inject.

### 8. The cycle is resolved by iterating, not by ordering

`DefCollector::collect` runs a `resolution_loop()` over worklists —
`unresolved_imports`, `indeterminate_imports`, `unresolved_macros` — resolving
imports first, then expanding macros, so "newly-expanded macros can shadow
previously-resolved imports". Termination is bought with explicit fuel:
`FIXED_POINT_LIMIT = 8192`, `GLOB_RECURSION_LIMIT = 100`, and an expansion-depth
check against `recursion_limit()`. Macros that never resolve are not dropped
silently: `finish()` emits `unresolved_macro_call` diagnostics for each.

### 9. An expansion is a first-class file

`hir_expand` "implements a concept of `MacroFile` — a file whose syntax tree
originates not from the text of some `FileId`, but from some macro expansion".
`HirFileId` is an enum over a real file or an expansion, "allowing both to be
treated uniformly"; `parse_macro_expansion` is itself a tracked query returning
the tree plus a span map; `ExpansionInfo` maps tokens bidirectionally between
expansion and call site, which is what makes go-to-definition work across a
macro.

Generated items therefore need no special case downstream. They are items in a
file; only their provenance is unusual.

### 10. Items inside bodies get their own map

Every crate has one primary `DefMap` plus one per block expression
(`block_def_map`), computed lazily. A `@testitem` body is our block expression: a
scope that declares names, whose contents most files never need.

### 11. Types stay syntactic until a later query

`hir-def/src/hir/type_ref.rs`: "HIR for references to types. **Paths in these are
not yet resolved.** They can be directly created from an `ast::TypeRef`, without
further queries." `TypeRef` carries an `Error` variant for what it cannot
represent. Resolution happens in separate, later queries against a resolver built
from the def map — the record-then-resolve pattern, in their item layer.

Two further choices are worth borrowing the reasoning from:

- **Per-def, not crate-wide.** `hir-ty/src/variance.rs`: "rust-analyzer does not
  want a crate-wide analysis though as that would hurt incrementality too much",
  so the query is per item. Our arity index is deliberately the opposite (§5) for
  a reason their design does not face: a per-name node here would depend on every
  file, because we have no per-item identity to key on. Stable content-hashed item
  ids (landed) narrow that gap.
- **Interning removes our constraint 3.** Their HIR types are interned, so the
  structural cost of comparison is paid once at construction and equality is
  cheap. Our Salsa port has no interning and its early exit is `isequal` over the
  whole value, which is *why* constraint 3 binds us and not them. That makes
  "keep the recorded skeletons small" the right answer given our tooling — and
  interning in Salsa.jl the lever if type-level work keeps growing.

### 12. What they have that we don't, and the reverse

They *run* the macro. We model a handful by hand and must degrade gracefully for
every other macro — which is why `in_macrocall_arg` exists at all, and why our
answer for an unrecognised macro has to be "decline to judge".

Their macro also lives in a crate graph they own, so "which macro is this" is
answered entirely inside their own def maps. Ours may live in an indexed package
reachable only through the environment store — a second world, with its own
invalidation profile (§14).

---

## Part IV — What to build

### 13. A per-module inventory

Split what the module-tree walk currently fuses:

- **structure** — files, includes, nesting, exports, raw imports;
- **classification** — today's `_classify_imports!`, unchanged;
- **declarations** — a query keyed `(root, module path)` returning the module's
  items with kinds, arities and (later) signatures, computed from the spliced file
  inventories *plus* what the module's own (now classified) import records let it
  judge.

Visibility then reads declarations instead of `ModuleNode.declared`, and the four
independent re-derivations of §5 become consumers of one node. The seam sits below
visibility and above structure — which is exactly where a module-aware judgement
is legal, and where rust-analyzer's `DefMap` sits.

**The structure pass is not "unchanged", and that is where the work is.**
`_build_tree_structure` (pass 1) already writes `declared`, inside the DFS, via
`_declare!` — with the datatype-wins method-extension rule and last-splice-wins
ordering — while `_classify_imports!` (pass 2) runs *after* it. Getting classified
imports in hand before declarations are decided means lifting the declaring out
of the DFS, so the new declarations query has to reproduce that DFS's exact
interleaved splice order (rules 3/4/5, includes recursing in place) from outside
it. `_walk_spliced_binding_items!` already mirrors that order, so the machinery
exists; but **order equivalence against today's `ModuleNode.declared`, over real
trees, is the acceptance gate**, not an afterthought.

**It also keeps looking load-bearing and keeps turning out not to be.** Twice now
a piece of work was filed as blocked on this node and then shipped without it: the
macro-declared names, once visibility unioned a separate node in beside `declared`
(§3, §14); and §17's type records, whose cutoff argument is answered at the
projection rather than the key (§17). What remains is the §5 motivation —
consolidating four traversals of the same data — which is real but is a refactor
with no user-visible change, so it earns its place on its own schedule rather than
by gating other work. Treat any future claim that something is blocked on §13 with
suspicion until the specific query it cannot otherwise get is named.

### 14. Where macro identity gets judged

There are three outcomes to distinguish, not two proofs to choose between. The
distinction that matters is **confirmed foreign** versus **unknown**; collapsing
them is what makes this look like a choice between a weak proof and an expensive
one.

1. **Confirmed** — the macrocall resolves to the macro we model. Record the names;
   everything downstream works.
2. **Confirmed foreign** — it resolves to something else, or the module imports
   nothing that could provide it. Record nothing, and `set_foo!` *is* a missing
   reference. Suppressing it here would be hiding a real error.
3. **Unknown** — the owner cannot be resolved at all. The only genuinely
   ambiguous case, and the one that must not fabricate names.

**Confirmation composes from two strong proofs, neither of them a guess.** The env
store (`macro_store_target`, which also follows re-export chains) answers for
registry dependencies. For a *path* dependency it cannot: manifest entries with a
`path` key are classified as deved (`layer_projects.jl:184`), and
`derived_environment` adds deved packages to `project_deps` only, never to
`new_store` (`layer_environment.jl:176-184`) — so `env.symbols[:Salsa]` does not
exist in this repo, where Salsa is a path dep in both the development and
languageserver manifests. That branch is answered structurally instead:
`workspace_package_context(ctx, "Salsa")` reaches the deved package's own tree, and
we ask whether *that* module declares the macro. Strong, env-free, cross-root, and
the same mechanism §1's `@testitem` fix uses. Between them the two proofs cover the
cases that occur; **import records are not a third proof** — they only say which
module to ask.

**The unknown case needs no new mechanism, because the existing one already fires.**
`derived_module_unresolved_wildcard_using` (`layer_visibility.jl:729-759`) is
module-scoped and env-aware: it fires when an `:external` wildcard target is missing
from the environment, and `collect_hints` then suppresses bare missing-ref hints
throughout that module. The same store gap that hides the macro also makes
`using Salsa` unresolvable, so the module is *already* flagged blind — **measured**:
against a stdlib-only env, `foo`, `set_foo!` and `delete_foo!` are all unflagged
today via that flag, with no macro handling whatsoever. So the unknown case records
nothing and stays quiet for a reason we already accept elsewhere. The residue worth
checking is the colon form (`using Salsa: @declare_input`) and `import Salsa`, which
set no wildcard flag — but if Salsa is resolvable at all, outcome 1 applies, so the
residue is narrow.

**Where the env edge lives.** Confirming identity at the seam means an env
dependency, but it need not sit under the tree. Put the judgement in its own node —
`derived_module_macro_declared_names(root, path)`, reading classified imports plus
env — and have **visibility union it with `declared`**. The module tree stays
env-free (it is today: `_classify_imports!` reaches only
`derived_workspace_package_roots`, and nothing in the tree touches
`derived_environment` — worth a test that keeps it so), the env edge is confined to
one small node, and that node reads no `declared`, so §3's loop stays open.

The invalidation cost of that edge is also smaller than it first appears:
`ExternalEnv` defines `isequal`/`hash` over entrywise store *identity*
(`StaticLint/StaticLint.jl:188-206`) specifically so a rebuilt-but-unchanged env
backdates. The edge costs invalidation at indexing transitions, not per keystroke.

**Shapes stay gated downstream even when identity is confirmed**, because we can
model which names a macro declares without modelling the exact arity or signature
it generates. The names flow up into visibility; the arity and signature records
travel as plain syntactic data and are applied only where a consumer is about to
make a claim — which is where `_effective_arity` already consults the env for
`@kwdef`. Two consequences:

- The gate's placement is **per consumer**, because the harm differs. A diagnostic
  declining to check produces nothing; a *completion list* omitting the name is
  right, while offering it fabricates a suggestion the user can accept — so
  existence in a completion list is itself a claim and gates
  (`_add_visible_name_completion`/`_completion_kind_for_visible`,
  `layer_completions.jl:976,1025`; note the LS has no `completionItem/resolve`
  handler, so the decision cannot be deferred). Hover renders the name without a
  synthesized signature rather than inventing one.
- A name recorded without a shape must be inert by construction — the confirmed-
  identity, unmodelled-shape case. `arity === nothing` and `signature === nothing`
  are already skipped by `derived_method_arities_index` (`layer_module_tree.jl:863`)
  and by the signature renderers, so such a row can only ever remove an output. The
  one leak to close: the item `kind` must be a new inert value rather than
  `:function`, or the ~5 item-kind switch sites in hover, completions, symbols and
  references will treat it as callable and start rendering shapes for it.

### 15. Fixed point, or one round?

There is not even a fixed point to reach. The judgement node reads classified
imports and `env`, neither of which depends on declarations (§3), and visibility
unions its result in — so the phases are strictly ordered and "one round" is exact
rather than merely adequate. Iteration becomes *necessary* only if we start
supporting macro-generated `using`, or if a modelled macro's names could themselves
bring a macro into scope. Nobody should build a worklist yet.

One round also suffices semantically: a name declared by `@declare_input` cannot
itself bring a macro into scope. But the seam should not *preclude* iteration —
rust-analyzer's fuel constants exist because the general case needs them, and one
`@reexport`-style macro would put us there.
Build one round; keep the shape loop-friendly; if a macro never resolves, follow
§8 and make that a *recorded* outcome rather than silence.

### 16. Identity for names that were never written

We do not need `MacroFile`. Our `ItemRef` is `(file, id)`; macro-declared names
can share the declaring statement's id exactly as `@enum`'s members already do,
and `_itemref_is_ambiguous` exists for that shape.

The id that gets shared is stable enough for this, **measured**. Ids are
content-hashed on `(coarse kind, name as written, in-file module path)` with a
16-bit positional bucket among statements sharing that key, so `src/inputs.jl`'s
twelve `@declare_input` statements key apart by name: inserting one above the
others leaves the rest's ids byte-identical. What *does* shift is a same-keyed
sibling (a second method of the same name in the same module) — which is the
regression test to write for any derived value that ends up carrying these refs.

What we forgo by having no
virtual file is span mapping *into* the expansion: hover and go-to-definition land
on the macrocall rather than on a generated signature. For `@declare_input` that
is arguably the better target — but it is also why a generated method's signature
must be **recorded**: there is no expansion to re-print, and the renderers that
would normally re-print a definition's own signature have nothing to work with.

### 17. Types on the same seam

What a signature record needs to contain, given the constraints: for each
parameter, a *syntactic* type — a name plus optional qualifier and parameters, or
an explicit "unknown" — never a resolved store value (constraint 3), never
recovered from syntax later (constraint 1). Resolution happens where the
diagnostic runs, against the *defining* module's names.

Three rules fall out, and rust-analyzer independently holds all three:

- **Unknown must be permissive.** Declining to flag is the only safe direction;
  their `TyKind::Error` relates against anything for the same reason.
- **Degrade on cycles at the query level**, returning "nothing known" rather than
  a truncated answer: a truncated supertype chain is a false *positive*, which is
  the one outcome a linter must not produce.
- **Do not elaborate early.** Materialising ancestry during recording invites
  cycles; resolve on demand.

The cost is the honest part: resolving a recorded type name means asking the
*defining* module about it, so each per-file analysis gains dependency edges to
other modules' name maps — one per type mentioned in a cross-file signature. That
is the same graph-size question §5 quotes, spread over many more nodes, and it is
the reason the current design stops at arity. This is the one cost here with no
proposed bound, so it wants a measured budget on the julia-vscode repo (the
baseline and lsbench tooling exist) *before* type-aware matching is built, not a
graph-shape argument.

**These records do not need §13.** An earlier draft called the per-module
declarations node their natural home, on the strength of "coarser than per-name,
finer than per-root". Neither half of that survives scrutiny. The coarseness
argument does not hold for the dominant shape: in a single-module package,
`derived_module_declarations(root, ["Pkg"])` depends on every file spliced into
that module, which is every file in the root — exactly the root-level dependency
set. And the fineness argument is answered a layer lower than the key:
`derived_method_arities(root, path, name)` is a `get` into the per-root index, so
when the index's value changes the projection re-runs, returns the same value for
an untouched name, and *its* consumers backdate. Early cutoff lives at the
projection, not at the node's key.

So the shape §17 wants is the one the arity path already uses, and it needs
nothing new structurally: a syntactic type record per parameter on
`InventoryItem` (which already carries `signature` and `arity`), a per-root
signature index, per-`(path, name)` projections for cutoff, and resolution
through the id-free `derived_module_visible_names_idfree` of the *defining*
module. §13 would buy one fewer traversal (§5) and one home for per-item data
instead of a second index beside arities — tidiness, not a prerequisite.

### 18. The inverse direction: from a type to its methods

§17's records are keyed callable → parameter types. Several features want the
inverse — given a type, which callables accept it — and it is worth writing down
what that costs, because the answer is "one projection", not "a second design".

**The subtype walk is not new work.** `src/StaticLint/subtypes.jl` already has it:
`_issubtype` climbing `_super` with `_type_compare` at each step, plus
`_has_type_intersection`, driving today's `isa` and method-call checks. §17 does not
add the walk — it supplies the operand the walk is currently missing, a *workspace*
method's parameter type. The forward matcher (§2) and the inverse index therefore
share one primitive and neither pays for it twice.

One shape difference is worth naming. `_issubtype` is a predicate over a pair; an
index probe needs the ancestor chain *enumerated*, to look up each ancestor by name.
`_super` already gives the step, so the enumerator is the more primitive of the two
and the predicate falls out of it. The chain can also leave the store and pass
through workspace-declared types — a struct whose supertype is an abstract type in
the project — so the enumerator has to walk both worlds. That is exactly what
§17's per-module resolution provides and what `_super` alone does not.

**The index.** Per root, from a *syntactic* first-parameter type name to the items
written that way. Plain data: no resolution, no env, so it backdates on every edit
that neither adds nor removes such a method. Resolving at index-build time would put
the env underneath the index and turn every type mention into a dependency; deferring
keeps §11/§17's record-then-resolve discipline.

**How a consumer uses it**: enumerate the receiver type's ancestors, probe the index
by name, then resolve and verify only what comes back. The name lookup is the cheap
gate and verification is paid on a handful rather than on every callable in scope —
the same gate-then-verify split as `derived_external_extension_names`.

Probing by exact name alone is the failure to avoid: a method written
`::AbstractVector` never surfaces for a `Vector{Int}` receiver, and unannotated
methods — most of them — never surface at all. Whether unannotated and `::Any`
methods belong in the answer is a product question, not a graph one.

A twin index over the env's stores, keyed the same way and memoized per
environment, turns the store half from a scan of every visible name into a lookup.
The env backdates when unchanged (§14), so it survives most edits.

**Consumers**, all wanting the same two indices:

- **Receiver-first method discovery** — "what can I do with this value". Without the
  workspace half it is blind to the project's own functions, which is the half that
  matters most to someone working inside their own package.
- **Overload ranking** in signature help and hover: order by which methods the
  argument types can actually match, instead of by splice order.
- **The argument-type half of the method-call lint** (§2, §17) — the forward
  direction over the same records.
- **Navigation**: show the overloads that apply to a given type.

**Error tolerance belongs to the consumer, not to the index.** Discovery wants
generosity — an offered method that turns out not to apply costs a glance, a missing
one is invisible — while the lint must not over-claim. Same split as §14, and the
reason the index stores spellings rather than verdicts. The line to hold is that
generosity applies to type *matching*, never to name existence: over-including a real
method is a suggestion, inventing a name is fabrication.

Cost: one more consumer of the declarations node, so no extra walk when built
alongside it, and per-root keying puts its dependency set on the root's files —
the same profile as the arities index.

---

## Part V — Decisions and status

### 19. Open decisions

1. **Where the env edge lives** (§14) — not whether to have one. Identity has to be
   confirmed before names are recorded, so the judgement needs `env` (for registry
   owners) and the deved package's tree (for path owners). The open question is
   whether it sits in its own node that visibility unions in, or under the module
   tree. *Leaning: its own node — the tree stays env-free, and §3's loop stays open
   because that node reads no `declared`.* Import records are not a candidate
   proof; they only name the module to ask.
2. **Exports or all visible names** for an injected package (`@testitem`'s
   implicit `using PackageName`). A module context resolves everything visible in
   the module; `using` brings only exports. The loose choice under-reports; the
   strict one needs an exports projection at the seam. *Leaning: exports if the
   projection is cheap, otherwise loose — under-reporting is the safe direction
   (§17).*
3. **One round or a loop** (§15). *Settled by §3's edge analysis: one round, no
   loop — the judgement node reads no `declared`, so nothing can close the cycle.*
4. **Does visibility move to the declarations node**, or does `declared` stay its
   input? **SUPERSEDED.** Visibility now *unions* a separate module-keyed node in
   beside `declared` (§14, shipped), which is neither option: `declared` stays the
   input it always was, and the new names arrive alongside it. The question only
   returns if §13 is built for §5's sake, and then it is a refactor decision rather
   than a design one.
5. **Where macro-identity constants live.** Today's are in StaticLint
   (`SIGNATURE_PRESERVING_MACROS`), but the inventory needs the same names for its
   name-only half, and layer 1 is included before StaticLint. **DECIDED, the other
   way.** What shipped is ONE table in layer 1 carrying both the macro names and
   their owner *paths* — the walker reads the names, the confirmation node reads the
   paths — rather than bare names in layer 1 with StaticLint keying a module-path
   table off them. One table cannot drift against itself; two can. It does mean a
   second macro table lives alongside StaticLint's `SIGNATURE_PRESERVING_MACROS`,
   deliberately, because unifying them would put a layer-1 dependency on StaticLint.
6. **Per-def vs per-module keying for signatures** (§11), now that content-hashed
   item ids exist. **ANSWERED by §17's correction:** neither. Records live per item
   in the per-file inventory; a per-root index funnels them; per-`(path, name)`
   projections give the cutoff. That is the arity path's existing shape, and it makes
   the keying question moot.

### 20. Status

**On main.** The independent bugfixes (PR #175): inner-constructor arity and
matching, parametric `fieldnames` in the symbol cache, core-type recognition on
every store name carrier, store-datatype destructuring, the docstring/arity
interaction, the field-docstring miscount, the `@atomic` field-modifier unwrap,
and one doc-macro predicate instead of two.

**Parked on `sp/reported-staticlint-fixes`.** `MethodArity.macro_annotations` —
the wrapping macro names as written, qualifier kept — plus `_effective_arity`,
which resolves them via `_annotation_macro_points_to` (module tree + env store)
before trusting a recorded count; `@kwdef`'s generated shape; `SIGNATURE_PRESERVING_MACROS`
as module paths with `macro_store_target`; `Salsa.@derived`; and the
`@declare_input` attempt whose layer-1 name comparison prompted this document.
That mechanism is right for the `@kwdef` class (answer flows downstream) and
mis-homed for the `@declare_input` class: the *proof* it performs is the one §14
wants, but it runs where only a shape claim can consume it, while the names have to
reach visibility. What changes is the home, not the mechanism. A stash on that
branch holds the hover fallback for a method whose defining node is a macrocall —
independent of where identity gets resolved, so it survives whatever §13 becomes.

**Built, on `sp/module-inventory-design`.** The macro-declared names, end to end:
a two-entry rule table in layer 1 (`Salsa.@declare_input`, `Base.@deprecate`);
inert `:macro_declared` inventory rows outside `_BINDING_ITEM_KINDS`; the
confirmation predicate with both strong proofs (env store for a registry owner,
the owner package's own tree for a workspace one); a per-root index with a
per-module projection; and visibility unioning the confirmed names in beside
`declared` (§3, §14, §15, §16). Missing-reference suppression, hover, completions,
go-to-definition and find-references all work; rename is deliberately refused.
Confirmed with 26 commits, ten reviewed tasks and a whole-branch review. §13 was
NOT needed, which is the finding §13 and §17 are now annotated with.

Three gaps between this document and what shipped, worth knowing:

- §15 asks that a macro which never resolves become a *recorded* outcome rather
  than silence, following §8. It did not. The unknown case records nothing and
  emits nothing, relying on the pre-existing failed-wildcard-`using` suppression
  to stay quiet. A deliberate v1 simplification, still owed.
- §16 argues a generated method's signature must be **recorded**, since there is
  no expansion to re-print. v1 records no signature at all and hover deliberately
  prints none, rather than re-printing the input's own signature as the generated
  name's.
- Find-references needed a change §16 did not anticipate: `each_reference`'s
  declaring-file path requires a `StaticLint.Binding`, which a macro-declared name
  never has, so same-file uses were dropped entirely until a fallback was added.

**Not built, and not blocked on anything.** The **`@testitem` injection on the
per-file path** (§1): `self_package_name` plus
`StaticLint.workspace_package_context`; no meta merging, no per-module inventory,
no macro identity. Also the arity/signature half of the macro work — v1 recorded
names only, so `set_foo!(rt)` still gets no argument-count check.

**Not built, and NOT blocked on §13** (corrected — see §17). Cross-file
type-aware method matching (§2, §17) and the inverse type-to-methods index (§18).
§17 wants its dependency-edge cost measured before it is built; §18 depends on
§17's records.

**Not built, motivated only by §5.** The per-module inventory itself. Twice it has
been filed as a prerequisite and twice the work shipped without it.

**Separate, and not part of this.** Completions throw inside any `@testitem`
body: `_get_tls_arglist` (`src/layer_completions.jl`) handles only `:file` and
`:module` toplevel scopes and calls bare `error()` otherwise, and a `@testitem`
scope is a toplevel scope whose expr head is `:macrocall`. A contained crash fix.
