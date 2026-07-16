# Query-decomposed analysis for JuliaWorkspaces ("inventories")

## Problem

All semantic analysis for a root currently happens in one monolithic derived value:
`derived_static_lint_meta_for_root(root)` runs `StaticLint.semantic_pass` sequentially over
the root's whole include closure, building a single mutable scope/binding graph keyed by
CST-node `objectid`s. Consequences, measured on the JuliaWorkspaces.jl repro workspace
(792 files, 39 projects):

- Any edit — including a body edit or a comment keystroke — invalidates the whole root's
  meta. The first request after a keystroke pays a full root re-lint (~0.2 s for a 63-file
  root, ~0.6 s for a 182-file root; grows with root size).
- Dev'ed packages cascade: `derived_deved_package_meta` merges a package's meta into every
  dependent root, and its value can never compare equal (fresh mutable objects), so a body
  edit inside a dev'ed package re-lints every dependent root (51 of 166 roots in the
  repro ≈ 1.5 s per sweep).
- The shared mutable object graph (cross-file `Binding.refs` pushes, shared `Scope`s and
  `Meta`s between Salsa-cached values via `merge_meta_dict!`) is a recurring source of
  aliasing bugs.

A previous stale-serving fast path (branch `sp/perf`) attacked request latency by reusing
stale root meta; it is deliberately **not** part of this design. This architecture makes
staleness unnecessary: recomputation after an edit is scoped to the edited file, exactly.

## Design summary (rust-analyzer transplant)

Replace the monolith with query layers whose cross-file interfaces are position-free plain
data, so Salsa's early-exit ("backdating") stops invalidation at every file boundary that
didn't change its top-level API. This is rust-analyzer's ItemTree/DefMap/per-body-inference
architecture at file granularity, adapted to Julia's textual `include` semantics.

### Layer 1: `derived_file_inventory(rt, uri)` — the firewall

Per-file summary of top-level items. **Plain data only**: `Symbol`s, `String`s, `Int`s,
structs of those. Never an `EXPR` reference, never an `objectid`, never a byte offset,
never a docstring. Contents:

- items: ordered list of `(item_id::Int, name::String, kind::Symbol)` where kind ∈
  function/struct (incl. mutable/abstract/primitive)/const/global/module/baremodule/
  macro/using-target/…; `item_id` is a per-file counter over top-level item-like nodes in
  tree order.
- per-item detail needed by dependents: normalized signature strings for functions/macros
  (whitespace-insensitive re-print of the signature EXPR; used for cross-file signature
  help), struct field names, `export`/`public` markers.
- module structure: which items live inside which (possibly nested) module declaration,
  and each module's own exports.
- `using`/`import` statements (module paths, `as` aliases, explicit symbol lists),
  positioned by item_id so the module tree can model before/after-include ordering when it
  chooses to.
- include targets (resolved URIs, from the existing include analysis), positioned by
  item_id.
- macro-generated bindings extracted with exactly the conservatism of today's
  `mark_bindings!` (`@enum`, `@kwdef`, …). Where `mark_bindings!` gives up, the inventory
  gives up identically — the firewall must not be *more* precise than the analysis that
  consumes it, or invalidation will under-trigger.

Value equality: structural `isequal` on plain data. A body edit reparses the file, the
inventory recomputes, compares equal, and Salsa backdates — nothing downstream re-runs.
This is the same pattern `derived_file_include_data`/`derived_includes` already use for
the include graph (see the docstring at the top of `layer_includes.jl`).

**Item-id stability**: ids are assigned in top-level tree order (module-level items before
nested-module items, mirroring rust-analyzer's breadth-first AstId numbering). Editing a
body never shifts ids. Inserting a new top-level item shifts subsequent ids — which
changes the inventory and invalidates downstream, correctly, since the item set changed.

### Layer 2: `derived_module_tree(rt, root)` — the DefMap analog

Built purely from inventories (of the root's include closure) plus the environment:

- walks include targets starting at the root, splicing each included file's items into the
  module scope active at its include site (Julia's textual include semantics);
- produces the module hierarchy and, per module, a name table
  `name::String → ItemRef = (file::URI, item_id::Int)` plus the module's resolved
  imports: `using`/`import` resolved against the env's `SymbolServer` stores, sibling
  modules, and **other roots' module trees** (for workspace/dev'ed packages);
- handles multi-file modules (a module opened in one file whose body `include`s others)
  and relative module paths (`using ..Sibling`) via a fixpoint over the module hierarchy,
  like rust-analyzer's DefMap collector;
- name-table construction is order-insensitive within a module (matching StaticLint's
  delayed-resolution behavior today); include-order information is retained in the tree
  for consumers that need it, but resolution does not depend on it.

Depends only on inventories + env ⇒ recomputes only when some file's top-level API
changed, and even then compares equal (backdates) unless the *resulting* tables differ.

### Layer 3: `derived_file_analysis(rt, root, file)` — per-file semantics

The per-file semantic pass, reusing StaticLint's existing single-file traversal machinery
(scope building, binding marking, ref resolution, lint checks) with its cross-file lookups
redirected: instead of resolving through a shared in-memory scope graph, module-level
names resolve through `derived_module_tree(root)` and env stores. Outputs, per file:

- local meta (scopes/bindings/refs for nodes inside the file — may reference this file's
  own EXPRs freely; the value is keyed on this file's content so its objectids are stable
  for exactly as long as the value is valid);
- an **outbound reference table** (plain data): every reference this file makes to a
  module-level name, as `(ItemRef, ref_site_descriptor)` — replaces cross-file
  `Binding.refs` pushes;
- per-file lint diagnostics (the `check_all` results that don't need cross-file
  aggregation).

Keyed on `(root, file)` because a file's analysis depends on which root's module tree it
resolves against (files reachable from multiple roots keep today's per-root behavior).

A body edit in file A ⇒ inventory(A) backdates ⇒ module tree untouched ⇒ only
`derived_file_analysis(root, A)` re-runs. Keystroke cost = one file's analysis.

### Position reattachment: `derived_item_positions(rt, uri)`

Maps `item_id → (EXPR reference, byte offset)` for the file's current CST. Volatile
(changes on every edit), cheap (single-file walk), and **leaf-level**: nothing in layers
1–3 depends on it. Consulted only by request handlers at the last mile — rendering a
definition location, fetching a docstring (hover pulls docs from the defining file's
syntax on demand; docs are deliberately outside the inventory so docstring edits don't
invalidate dependents), or materializing the defining EXPR for detail rendering.

### Aggregations (cross-file features)

- find-references / rename / highlights for module-level names: aggregate the outbound
  reference tables of the relevant root(s), then reattach positions per file.
- unused-binding lint for module-level names: a per-root aggregate over the same tables.
- workspace symbols: over inventories directly (cheaper than today).
- testitem error marking and `derived_test_setup_bindings` consumers: re-expressed over
  inventories + per-file analyses.

### What gets deleted

`derived_static_lint_meta_for_root` (as whole-closure walker), `derived_deved_package_meta`
and `merge_meta_dict!` (dev'ed packages resolve through their own module trees — the
cascade dies by construction), the cross-file `Binding.refs` push model, and the
whole-closure `ensuremeta` pre-seeding. `get_roots_for_uri`/`get_best_root_for_uri` are
public API and stay; their derived implementations are re-expressed over module-tree /
include ownership (which also retires the current O(N²) per-file forward BFS on `main`).

## Compatibility contract

**User-visible behavior stays the same in most cases.** The existing test suite runs
throughout, but assertions that codify implementation idiosyncrasies (order-dependent
resolution corner cases, ref accumulation order, duplicate-ref artifacts, internal
representation checks) may change freely — each such change is listed with justification
for review. LS-facing API of JuliaWorkspaces (`get_completions`, `get_diagnostics`,
`get_references`, `get_static_lint_data` consumers, …) keeps its signatures and result
types; the LanguageServer package is not modified.

## Non-goals

- No staleness/fast-path mechanisms. Requests are always exact.
- No rewrite of CSTParser or of StaticLint's single-file traversal internals.
- No changes to the environment/SymbolServer layer, symbol caches, or the dynamic feature.
- No LanguageServer.jl changes (it is a validation consumer only).
- Salsa stays as-is except one cherry-pick (below); durability-style features are noted as
  future work, not built here.

## Salsa

The trace-pool fix (`perf: don't let wide traces poison the trace pool`, cherry-picked to
Salsa branch `sp/inventories` as `aec21c3`) is a prerequisite: the aggregation queries
introduced here are exactly the wide-trace shape that triggers the pooling pathology.
No other Salsa changes.

## Testing strategy

1. **Suite as amended contract**: the JuliaWorkspaces suite stays green throughout; every
   changed assertion is collected in a reviewed change-list with one-line justifications.
2. **Differential harness**: a script comparing old vs new user-visible outputs —
   diagnostics sets, completion label sets, signature results, reference/definition
   locations — over real workspaces (this repo's checkout, the JuliaWorkspaces.jl repro),
   old outputs captured from a pre-refactor checkout. Diffs triaged: bug vs sanctioned
   semantic change.
3. **Invalidation properties** (TraceLogging-receiver style, the load-bearing acceptance
   tests):
   - body edit in file A ⇒ zero recomputation of `derived_module_tree`, zero
     `derived_file_analysis` for files ≠ A;
   - body edit in a dev'ed package ⇒ zero recomputation in dependent roots;
   - top-level API edit ⇒ module tree recomputes; only files whose resolution actually
     changed re-analyze (value-level cutoff on the name tables);
   - adding an `include` ⇒ the new file gets analyzed, siblings don't.
4. **Performance acceptance** via `benchmark/interactive_latency.jl` (to be ported to this
   branch): post-keystroke completion latency on the repro workspace at single-file cost
   (target: ≤ 50 ms for leaf and hub files alike, vs 0.2–0.6 s today), full-sweep cost
   after a body edit bounded by one file's analysis + aggregation re-verification.
5. **LanguageServer.jl suite as external-behavior gate**: run LS.jl's full test suite
   against the refactored JuliaWorkspaces to verify externally visible behavior is
   consistent. The LS suite is expensive (~10 min, 165k+ assertions) — run it **only once
   JuliaWorkspaces itself is in a good state** (its own suite + differential harness
   green), not per-milestone.

## Migration shape

Wholesale replacement on branch `sp/inventories` (JuliaWorkspaces): the old pass is
deleted in the same branch, no runtime flag, no dual engines. The branch is internally
staged so every milestone compiles and is unit-testable:

1. Inventory query + item-ids + position maps (+ their invalidation/stability tests).
2. Module tree (single-root, then imports/exports fixpoint, then cross-root).
3. Per-file analysis: redirect StaticLint's module-level resolution to the module tree;
   produce per-file meta + outbound-ref tables + per-file lint.
4. Consumer migration in order: diagnostics/missing-ref lint → completions → signatures →
   hover → definitions → references/rename/highlights (aggregations) → document/workspace
   symbols → testitems/actions/inlay hints.
5. Deletions (`semantic_pass` closure walker, `derived_deved_package_meta`,
   `merge_meta_dict!`, obsolete gating) + suite change-list finalization.
6. Differential harness + performance acceptance + LS.jl suite gate.

## Future work (explicitly out of scope for this branch, but design-compatible)

- **Full cancellation support.** rust-analyzer treats cancellation as load-bearing: an
  edit cancels all in-flight queries (salsa unwinds them) and requests re-run against the
  new revision, so a slow request can never serve — or block — a stale world. The
  equivalent here: thread a `CancellationTokens.CancellationToken` through every
  JuliaWorkspaces request entry point (the vendored `CancellationTokens` package and a
  few token-accepting APIs like `get_diagnostics_blocking` already exist), have Salsa
  check a runtime-level token at `memoized_lookup` boundaries and unwind via a dedicated
  cancellation exception, and have the LS cancel outstanding request tokens on every
  `didChange` (plus honor client-side `$/cancelRequest`). The query decomposition built
  here is what makes this cheap: query boundaries are natural, frequent cancellation
  checkpoints, and unwinding is safe because query values are immutable plain data —
  there is no shared mutable graph to leave half-updated. Design hook honored now: no
  derived function may swallow a foreign exception class blindly (`catch`-all blocks must
  rethrow non-local exceptions), so a future cancellation unwind passes through cleanly.
- **Salsa durability.** rust-analyzer marks slow-changing inputs (sysroot, crates.io
  sources) as high-durability so revision-validation walks skip entire subgraphs. The
  analog here: `input_package_metadata`, symbol-store contents, and project/manifest-
  derived environment data are high-durability (change on env events, not keystrokes),
  while file contents are low-durability. With durability in Salsa, the per-keystroke
  verification walk would skip the env/store-dependent subgraph wholesale instead of
  re-verifying it edge by edge. Design hook honored now: environment-derived data flows
  through a small number of dedicated query nodes (`derived_module_tree`'s import
  resolution consults env stores through one seam), so a later durability annotation
  has a single place to attach.

## Known risks

- **Macro opacity**: top-level macro calls can generate bindings the inventory can't see.
  Mitigation: inherit `mark_bindings!`'s exact behavior; the firewall is then precisely as
  blind as today's analysis, no blinder. Testitem macros (`@testitem`/`@testmodule`/
  `@testsnippet`) get explicit inventory handling mirroring current special cases. (Note:
  the pre-existing `args[2]` off-by-one in testsetup detection — see follow-ups from the
  `sp/perf` work — should be fixed as part of re-expressing testsetups here, since the
  inventory extractor must not replicate a known bug.)
- **`Binding.val::EXPR` plumbing**: handlers that dereference defining EXPRs must go
  through `derived_item_positions`. This is the widest mechanical change; the consumer
  migration order above keeps it reviewable.
- **Multi-file modules and include-order corners**: covered by dedicated module-tree
  fixtures (module split across includes, `using` before/after include site, relative
  module paths through include boundaries).
- **Files in multiple roots**: `(root, file)` keying preserves today's semantics; memory
  cost is bounded by what the current per-root metas already pay.
- **Suite assertions relying on object identity** (e.g. shared `Binding` identity across
  files) will fail structurally and land on the change-list — expected, to be justified
  individually.
