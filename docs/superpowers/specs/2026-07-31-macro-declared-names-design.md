# Macro-declared names: recording and confirming names a macro mints

*2026-07-31 — spec. Derived from `docs/design/2026-07-31-module-inventory-and-resolution.md`,
which holds the analysis and the alternatives that were rejected.*

## Problem

`Salsa.@declare_input foo(rt, x::Int)::V` declares `foo`, `set_foo!` and
`delete_foo!`. The analysis records none of them: the macrocall is transparent, so
the walker descends and mints an id for the argument `foo(rt, x::Int)::V`, but
`_classify_item!` has no arm for a `::`-headed statement and emits nothing, and
StaticLint models the macro nowhere. Every use of all three names is therefore a
missing-reference diagnostic, and hover, completion and go-to-definition see
nothing. `Base.@deprecate` has the same shape: both its forms record nothing today.

The names have to reach `derived_module_visible_names`, which sits upstream of
everything that could resolve the macro. That is the whole difficulty, and the
resolution is to record the names in a node *beside* `declared` that visibility
unions in, rather than inside the module tree.

## Scope

**In:** recording the names a modelled macro declares, confirming the macro's
identity before recording, unioning confirmed names into visibility, and the
consumer behaviour that follows — missing-reference suppression, hover,
completions, go-to-definition, find-references, and a deliberate refusal to
rename.

**Out:** arity or signature records for generated names (§17 of the discussion);
the per-module declarations node (§13); the type-to-methods reverse index (§18);
the `@testitem` per-file injection; per-name landing inside a synthesized
signature, which needs span mapping into an expansion we do not have.

## Decisions taken

| Decision | Resolution |
| --- | --- |
| Mechanism generality | A table of rules, seeded with two entries. |
| v1 payload | Names only. No arity, no signature. |
| Where identity is confirmed | In a dedicated node, not in the module tree. |
| How visibility gets the names | Visibility unions the node's result with `declared`. |
| Keying | One per-root index plus a thin per-module projection. |
| Rename | Refused for any macro-declared name. |

## Architecture

### The rule table

A const vector in `layer_inventory.jl`. Each rule carries the owner module path,
the macro name, and a derivation function from the macrocall's first argument to
the names it declares:

- `["Salsa"], "@declare_input"` → `[n, "set_$(n)!", "delete_$(n)!"]`, where argument
  1 must be a `::` expression whose left side is a call, and `n` is that call's
  callee name. Salsa itself asserts that form, so anything else yields no names.
- `["Base"], "@deprecate"` → `[n]`, where `n` is the callee name of argument 1 when
  it is a call (`@deprecate f(x::Int) g(x)`) or the identifier itself when it is not
  (`@deprecate old new`). A third argument is irrelevant.

A derivation that finds no identifier yields no names. That is the only error path
at this layer.

The table lives at layer 1 because the walker needs the macro *names* to decide
what to record; the same entries carry the owner *paths*, which only the
confirmation node reads. One table, so the two halves cannot drift.

### The inventory record

A sibling of `imports`/`exports`/`includes` on `FileInventory`:

```julia
@auto_hash_equals struct InventoryMacroDeclaration
    order::Int
    id::Int64                        # id of the macrocall's FIRST argument
    name::String                     # the derived name
    macro_qualifier::Vector{String}  # as written: ["Salsa"], or [] when bare
    macro_name::String
    parent_module::Vector{String}
end
```

`FileInventory` gains `macro_declarations::Vector{InventoryMacroDeclaration}`.
Plain data throughout, so it backdates like the rest of the inventory.

All names from one macrocall share argument 1's id — the shape `@enum` members
already use, so `_itemref_is_ambiguous` covers it. That id is content-hashed on
`(kind, name as written, module path)`, so the twelve `@declare_input` statements in
`src/inputs.jl` key apart by input name and stay stable when one is inserted above
the others.

### Emission point

The walker, `_walk_one!`. It is the single source of truth for ids, and the only
place that still knows an argument's position within its macrocall — by the time
`_classify_item!` sees `f(x::Int)`, the fact that it was argument 1 of
`@deprecate` is gone, and both arguments have been minted ids.

`_walk_one!`'s callback gains an optional macro context: `nothing`, or
`(qualifier, macro_name, arg_index)`. `_classify_item!` emits records when the
context says "argument 1 of a table-matched macrocall".

Matching here is **by bare macro name only**. Nothing at this layer judges
identity, and nothing here reads the environment.

### The two queries

Both in `layer_visibility.jl`, following `derived_method_arities_index`:

```julia
derived_macro_declared_names_index(rt, root)        # (module path, name) => ItemRef
derived_module_macro_declared_names(rt, root, path) # name => ItemRef
```

The index does one splice walk over the new records, in the same DFS order the
module tree uses, so a duplicate name resolves last-in-splice-order-wins, matching
`_declare!`. It confirms each distinct `(module path, macro spelling)` once through
a node-local cache, so a root pays one lookup per spelling however many macrocalls
use it. The per-module query is a thin projection, which keeps early cutoff at
module granularity.

`_walk_spliced_binding_items!` currently walks `items`; it gains a parameter for
which record list to walk, or a sibling walker, so both traversals share one
ordering implementation.

### Visibility union

`derived_module_visible_names`, `derived_module_visible_names_idfree` and
`derived_visible_item` union the per-module projection in at declaration
precedence, which fixes the order concretely: a real `declared` entry beats a
macro-declared name, because that one is written text, and a macro-declared name
beats anything a wildcard import brings in, because it is a declaration of this
module. The module tree is untouched: it splices `items` only and never sees these
records, so a name that was never confirmed cannot reach `declared`.

### The invariant

The index may read the module tree and its projections — `derived_module_declared`,
`derived_module_imports` — because no tree consumes the index. It must **never**
read visibility, which is what would close the cycle the discussion doc describes
in §3. This is asserted by a test, not left to review.

## Confirmation

Two sub-checks. Only the second touches the environment.

### 1. Does the spelling point at the owner?

Structural, from the module's classified imports and those of its enclosing
modules:

- Qualified `Salsa.@declare_input`: the qualifier must resolve to the owner path.
- Bare `@declare_input`: the module or an enclosing one must carry `using Salsa`,
  `using Salsa: @declare_input`, or an alias form of either.

A local `macro declare_input` declared in the module makes the outcome **confirmed
foreign**, not unknown — this is the shadowing case, and it is legal to check here
because reading `declared` does not close the loop.

### 2. Does the owner provide the macro?

- **Registry or stdlib owner** — look the owner up in `env.symbols` and check it
  provides the macro name, following re-export chains. This is the
  `Base.@deprecate` path; stdlib stores are baked in, so it is always available.
- **Path (deved) owner** — the owner is absent from `env.symbols` entirely, because
  `derived_environment` adds deved packages to `project_deps` only and never to the
  store. Ask its own tree instead: `derived_workspace_deved_packages` gives the
  entry URI, and `derived_module_declared` on that root answers whether the module
  declares the macro. This is the `Salsa.@declare_input` path, and it is env-free.

Mutual dev-dependencies cannot deadlock: the index reads only the owner's tree, and
no tree consumes any index, so A→B and B→A both terminate.

### Outcomes

| Outcome | Recorded | Effect |
| --- | --- | --- |
| Confirmed | The derived names | Uses resolve; navigation works |
| Confirmed foreign | Nothing | Uses are flagged, which is correct |
| Unknown | Nothing | Falls back to today's behaviour |

In the unknown case the owner is typically a missing external, and
`derived_module_unresolved_wildcard_using` already suppresses that module's bare
missing-reference hints — so the common shape stays quiet without help from this
work. That is a documented consequence, not an acceptance gate.

## Consumer behaviour

The recorded row carries no arity and no signature, so every shape-consuming path
skips it by existing guards: `derived_method_arities_index` returns early on
`arity === nothing`, and the signature renderers on `signature === nothing`. The
item kind is a new value, `:macro_declared`, and the kind-switch sites in hover,
completions, symbols and references each get an explicit arm rather than falling
through to a default.

- **Missing reference** — resolves, so no diagnostic. This is the point of the work.
- **Hover** — the name, the declaring macro as written, and the macrocall's
  docstring if it has one. **No signature.** Argument 1's id materialises to
  `foo(rt, x::Int)::V`, so re-printing the defining EXPR would show the input's
  signature for `set_foo!`, which is a fabrication.
- **Completions** — offered as callable, with no detail string. Offering them is
  safe precisely because identity was confirmed before recording; an unconfirmed
  name is never recorded, so completion never invents one.
- **Go-to-definition** — lands on the declaring macrocall's first argument, via the
  recorded `ItemRef` and `derived_item_positions`, the same path tree-declared names
  use. All names from one macrocall land on the same spot.
- **Find references** — works, and must match on name as well as id, since the
  shared id makes `_itemref_is_ambiguous` true for these refs.
- **Rename** — **refused** when the resolved item's kind is `:macro_declared`,
  checked at the same point rename resolves the target. The definition site contains
  no token spelling `set_foo!`, so a rename has nothing to rewrite there and would
  leave the code broken. Family rename can land later as its own change.
- **Document symbols** — unchanged. Symbols list what `items` lists, and these rows
  are not items.
- **Arity lint** — finds no arity for the name and declines to check.

## Edge cases

- A modelled macrocall in a nested module: names land in that module, not the parent.
- The same input declared twice in one module: last in splice order wins.
- A generated name that a real declaration also defines: the real one wins and keeps
  its own arity and signature.
- A generated name in the module's `export` list: exported-ness must be marked
  through the same path `_tree_api_status_label` uses.
- A non-identifier input name: derivation still concatenates, and `_tree_name_label`
  handles the quoting.
- `@deprecate old new false`: the third argument is irrelevant.

## Degradation

Every failure records nothing, which can only leave today's behaviour in place: a
derivation that finds no identifier, a macrocall with no arguments, an unresolvable
owner, a deved owner whose root is not in the workspace.

## Testing

**Fixtures**, one per outcome and edge case: confirmed through the store branch
(`Base.@deprecate`); confirmed through the workspace-tree branch (a deved package
declaring the macro); confirmed foreign through a local `macro declare_input`
shadowing the import; unknown; nested module; duplicate name; collision with a real
declaration; both `@deprecate` forms; a derivation that finds nothing. Assertions go
through `collect_hints` and `derived_file_analysis`, since a project-less root
publishes no diagnostics.

**The cycle invariant** gets a real test: compute `derived_module_visible_names` for
a module that has both a modelled macrocall and imports. If the index ever reads
visibility, that computation recurses and Salsa raises a cycle error, so the test
fails loudly on exactly the regression that matters.

**Acceptance gates:**

1. **Real-repo LS check** — open julia-vscode in the language server. `src/inputs.jl`
   and every cross-file use of the twelve inputs are diagnostic-free, and no new
   diagnostics appear elsewhere. This exercises the deved-owner confirmation path end
   to end, which fixtures can only simulate.
2. **Visibility differential** — `derived_module_visible_names` is `isequal` to its
   pre-change value for every module with no modelled macrocall, so the union cannot
   perturb existing resolution. `isequal` is the right comparison because it is what
   Salsa's early exit uses.
3. **Perf** — lsbench against the 2026-07-24 baseline shows no measurable change in
   module-tree or visibility recompute time. The new work is one extra splice walk
   (measured at 1.4 ms on a 68-file root) plus one lookup per distinct macro
   spelling.

## Risks

The item-kind arms are the likeliest source of regressions: the recorded failure
class in this codebase is a consumer that does not handle a new kind and silently
does the wrong thing. Every switch site gets an explicit arm.

The cross-root query adds a dependency from one root's index to another root's tree,
so editing Salsa invalidates JuliaWorkspaces' index. That is acceptable — such edits
are rare — and it is confined to the index node.

## Files touched

- `src/layer_inventory.jl` — rule table, `InventoryMacroDeclaration`,
  `FileInventory` field, walker macro context, `_classify_item!` arm.
- `src/layer_module_tree.jl` — `_walk_spliced_binding_items!` parameterised over the
  record list.
- `src/layer_visibility.jl` — the two new queries, the union in the three visibility
  entry points.
- `src/layer_hover.jl`, `src/layer_completions.jl`, `src/layer_symbols.jl`,
  `src/layer_references.jl` — item-kind arms; rename refusal.
- `test/` — fixtures, the cycle invariant test, the visibility differential.
