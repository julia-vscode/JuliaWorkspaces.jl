# Macro-declared names: recording and confirming names a macro mints

*2026-07-31 — spec. Derived from `docs/design/2026-07-31-module-inventory-and-resolution.md`,
which holds the analysis and the alternatives that were rejected. Revised after
review; the review's findings are folded in, and the record shape changed as a
result.*

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
| Record shape | `InventoryItem`s with an inert kind outside `_BINDING_ITEM_KINDS`. |
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
- `["Base"], "@deprecate"` → `[n]`, where `n` is the name of argument 1: a call's
  callee (`@deprecate f(x::Int) g(x)`), a bare identifier (`@deprecate old new`), or
  the callee under a `where` (`@deprecate f(x::T) where T g(x)`). Reuse
  `CSTParser.get_name` and `_symbol_name` rather than hand-rolling this, so operator
  names (`Base.@deprecate (+)(a,b) …`) come out right.

A derivation that finds no identifier yields no names. That is the only error path
at this layer.

"Argument 1" means `macrocall.args[3]`: `args[1]` is the macro name and `args[2]` a
zero-span placeholder. `_walk_macrocall!` already indexes from `margs[3:end]`.

The table lives at layer 1 because the walker needs the macro *names* to decide
what to record; the same entries carry the owner *paths*, which only the
confirmation node reads. One table, so the two halves cannot drift. This is a second
module-path macro table alongside StaticLint's `SIGNATURE_PRESERVING_MACROS`
(`linting/checks.jl:216`); they are deliberately separate because that one gates a
shape claim inside the linter while this one drives recording at layer 1, and
unifying them would put a layer-1 dependency on StaticLint.

### The record

The rows are `InventoryItem`s in `inv.items`, with a new kind, `:macro_declared`,
and a new field carrying the declaring macro as written:

```julia
const MacroSpelling = @NamedTuple{qualifier::Vector{String}, name::String}
# InventoryItem gains:
declared_by::Union{Nothing,MacroSpelling}   # nothing for every ordinary item
```

The back-compat constructor defaults it to `nothing`, exactly as it already does for
`arity`. The item's own `qualifier` stays empty — the declared name is unqualified —
and `signature`, `field_names` and `arity` are empty or `nothing`.

`:macro_declared` is **not** in `_BINDING_ITEM_KINDS` (`layer_module_tree.jl:160`),
whose comment states that any other kind is deliberately excluded. That single fact
is what makes this placement safe: `_declare!` (`:279`) and
`_walk_spliced_binding_items!` (`:761`) both gate on that tuple, so an unconfirmed
row cannot reach `declared`, the arities index, method items or external extensions.

Living in `items` is what makes the rest work. `_itemref_is_ambiguous` and
`_inventory_item_name` (`layer_file_analysis.jl:909,922`) read `items` only, so a
sibling record list would leave find-references falling back to an id-only join —
returning all three names' sites for any one of them — and would strand rename with
no target name at all. In `items`, the three rows sharing argument 1's id make
`_itemref_is_ambiguous` true, `_tree_restrict_name` returns the name, and
`_reference_target` (`layer_references.jl:261-266`) carries it, so references and
rename both match on name as well as id with no changes to those functions.

All names from one macrocall share argument 1's id and order — the shape `@enum`
members already use. That id is content-hashed on `(kind, name as written, module
path)`, so the twelve `@declare_input` statements in `src/inputs.jl` key apart by
input name and stay stable when one is inserted above the others (verified on the
walker: 8/8 ids byte-identical across an insertion).

### Emission point

`_classify_item!`, with **no walker change at all**. CSTParser populates parent
links at parse time, so the statement's position inside its macrocall survives:
for `Salsa.@declare_input foo(rt, x)::Int`, `CSTParser.parentof` of the `::`
statement is the macrocall, and `parent.args[3] === x` identifies it as argument 1
(`args[1]` is the macro name, `args[2]` a zero-span placeholder). Verified on a
freshly parsed CST.

So the arm is: take `p = CSTParser.parentof(x)`; require `CSTParser.ismacrocall(p)`
and `p.args[3] === x`; read the spelling with the existing helpers
`_macro_name_string(p.args[1])` and `_getfield_qualifier(p.args[1])`; look the bare
macro name up in the table; emit one row per derived name, all carrying `x`'s own
`order` and `id`.

This keeps the 5-argument `_foreach_toplevel_item` callback contract intact, so
`derived_item_positions` and the existing walker tests are untouched. The
`p.args[3] === x` test is also what excludes argument 2 — `g(x)` in
`@deprecate f(x::Int) g(x)` is walked and minted an id like any statement, and must
record nothing.

Matching here is **by bare macro name only**. Nothing at this layer judges
identity, and nothing here reads the environment.

### The two queries

Both in `layer_visibility.jl`, which already consults the environment (unlike
`layer_module_tree.jl`, which must stay env-free). They follow the shape of
`derived_method_arities_index` (`layer_module_tree.jl:855`):

```julia
derived_macro_declared_names_index(rt, root)        # (module path, name) => ItemRef
derived_module_macro_declared_names(rt, root, path) # name => ItemRef
```

The index does one splice walk over `:macro_declared` items, in the same DFS order
the module tree uses, so a duplicate name resolves last-in-splice-order-wins,
matching `_declare!`. It confirms each distinct `(module path, macro spelling)` once
through a node-local cache, so a root pays one lookup per spelling however many
macrocalls use it. The per-module query is a thin projection, which keeps early
cutoff at module granularity.

`_walk_spliced_binding_items!` gains a kind-filter parameter defaulting to
`_BINDING_ITEM_KINDS`; the index passes `(:macro_declared,)`. The default stays
exactly as it is — this adds a second explicit filter set rather than loosening the
existing one.

### Visibility union

The union goes in `_visible_names_impl_body` (`layer_visibility.jl:629`), the one
place every path reaches: `derived_module_visible_names`, its `_idfree` twin and
`derived_visible_item` are projections of it, and `_cross_root_visible_names`
(`:602`) routes through `_visible_names_impl` for the on-chain case.

Entries carry `origin = :declared` and `origin_module = path`, so `_tier` (`:114`)
scores them 3 without modification. A new origin symbol would score 1 and let pass
2's re-attempt (`:658`) overwrite a macro-declared name with a wildcard-import
bring-in — inverting the precedence below. Reusing `:declared` also keeps
`_IN_SCOPE_ORIGINS` (`layer_scope_modules.jl:10`) and `_tree_api_status_label`
working unchanged.

Precedence, concretely: a real `declared` entry beats a macro-declared name, because
that one is written text; a macro-declared name beats anything a wildcard import
brings in, because it is a declaration of this module; `import X: name` (tier 2) sits
between them, as it does for any declaration.

Because these entries claim `origin = :declared` without a matching
`derived_module_declared` entry, every consumer that branches on `origin ===
:declared` must tolerate a name absent from that dict. Auditing those sites is part
of this work, and one test covers it.

**Two consumers bypass visible names entirely** and need the same union applied:

- `_target_bring_ins`, `:tree` branch (`:142-166`), which reads
  `derived_module_names`, `derived_module_exports` and `derived_module_declared`.
  Without this, `using .Sub` never brings a generated name in.
- `_member_lookup`, `:tree` and `:workspace_package` branches (`:244-266`). Without
  this, `using .Sub: set_foo!` resolves but loses its kind and `ItemRef`, so hover
  and go-to-definition go dead.

The `:workspace_package` `using` branch needs nothing: it already routes through
`_cross_root_visible_names`.

The module tree itself is untouched.

### The invariant

The index may read the module tree and its projections — `derived_module_names`,
`derived_module_imports` — because no tree consumes the index. It must **never**
read visibility, which is what would close the cycle the discussion doc describes
in §3. This is asserted by a test, not left to review.

## Confirmation

Two sub-checks. Only the second touches the environment.

### 1. Does the spelling point at the owner?

Structural, from `derived_module_imports(rt, root, path)` — the module's own imports
only. Julia does not inherit an enclosing module's `using`, and
`_visible_names_pass1` (`:481-531`) agrees: it reads imports for `path` alone.

- Qualified `Salsa.@declare_input`: the qualifier must resolve to the owner.
- Bare `@declare_input`: the module must carry `using Salsa`,
  `using Salsa: @declare_input`, or an alias form of either.

In both cases the check is against the matching `ResolvedImport`'s **target**, not
its spelling: `target.sort` and `target.path` must be the owner. A submodule of this
root literally named `Salsa`, or a different workspace package of that name,
classifies as `:tree` or `:workspace_package` with a different path, and must not
confirm.

A local `macro declare_input` in the module makes the outcome **confirmed foreign**
— but only for the *bare* spelling. A qualified `Salsa.@declare_input` is not
shadowed by a local macro. Reading `declared` here is legal because no tree consumes
the index.

### 2. Does the owner provide the macro?

Driven by the target that check 1 matched, not by the table's path:

- **`:external` target** (registry or stdlib owner) — walk `env.symbols` down the
  owner's module path, then a flat `haskey(store.vals, macro_name)` on the final
  `ModuleStore`. No re-export chain is walked explicitly; a re-exported macro
  still succeeds because `ModuleStore.vals` carries a `VarRef` for it, so
  `haskey` finds it anyway. This is the `Base.@deprecate` path; stdlib stores are
  baked in, so it is always available.
- **`:workspace_package` or `:tree` target** — the owner is a workspace package, so
  it is absent from `env.symbols` (`derived_environment` adds deved packages to
  `project_deps` only, `layer_environment.jl:176-184`). Ask its own tree instead:
  `derived_workspace_package_roots(rt)` (`layer_module_tree.jl:134`) gives the root,
  and `derived_module_names` on that root answers whether the module declares the
  macro. This is the `Salsa.@declare_input` path in this repo, and it is env-free.

Use `derived_workspace_package_roots`, not `derived_workspace_deved_packages`: the
latter is keyed by project URI and returns empty for a project-less root. Use
`derived_module_names`, not `derived_module_declared`: the former is id-free, so it
backdates, and it carries kinds, so the check can require `:macro`. Macro names are
stored with their `@`, so the key is `"@declare_input"`.

Mutual dev-dependencies cannot deadlock: the index reads only the owner's tree, and
no tree consumes any index, so A→B and B→A both terminate.

### Outcomes

| Outcome | Recorded | Effect |
| --- | --- | --- |
| Confirmed | The derived names | Uses resolve; navigation works |
| Confirmed foreign | Nothing | Uses are flagged, which is correct |
| Unknown | Nothing | Falls back to today's behaviour |

Recording nothing means the rows stay in `items` with their inert kind and simply
never enter the index, so nothing downstream sees them.

In the unknown case the owner is typically a missing external, and
`derived_module_unresolved_wildcard_using` already suppresses that module's bare
missing-reference hints — so the common shape stays quiet without help from this
work. That is a documented consequence, not an acceptance gate.

## Consumer behaviour

Most consumers need nothing, because `:macro_declared` falls out of their existing
gates. The ones that do need work:

- **Missing reference** — resolves, so no diagnostic. This is the point of the work.
- **Completions** (`_completion_kind_for_visible`, `layer_completions.jl:976`) —
  needs an arm returning `CompletionKinds.Method`; without it the name falls to the
  `else` and shows as a variable. No detail string, since there is no signature.
  Offering these names is safe precisely because identity was confirmed before
  recording.
- **Hover** (`layer_hover.jl:528`) — needs an arm to name the declaring macro. The
  default path is already correct and does *not* fabricate: `:macro_declared` falls
  through to `_tree_binding_hover` (`:571`), `_item_binding` finds no `Binding` on a
  `::` node, and `_tree_item_fallback_hover` renders the docstring with no
  signature. `item_documentation` finds the docstring because `_maybe_get_doc_expr`
  (`:260-266`) climbs through the macrocall.
- **Workspace symbols** (`layer_symbols.jl:299`) — needs a skip, right beside the
  existing `it.kind === :opaque_macrocall && continue`. Otherwise three rows sharing
  one range each appear in the outline. Listing generated names as symbols is a
  reasonable follow-up; it is not this change.
- **Rename** (`_can_rename`, `layer_references.jl:683`) — must **refuse**. Today it
  resolves no target at all and returns the token range unconditionally, so this
  needs a real addition: resolve the target as `_reference_target` does, look up the
  item's kind, and return `nothing` for `:macro_declared`. The definition site
  contains no token spelling `set_foo!`, so a rename has nothing to rewrite there.
  Family rename can land later as its own change.

Working already, no change needed, verified:

- **Go-to-definition** — `:macro_declared` falls out of `_DEF_METHOD_ITEM_KINDS`
  (`layer_references.jl:470`) into `_push_item_definition`, landing on argument 1.
- **Find references** — needs a change after all. `_itemref_is_ambiguous` →
  `_tree_restrict_name` supplies the name-matching join correctly, but
  `each_reference`'s declaring-file path additionally requires an old-style
  `StaticLint.Binding`, and a macro-declared name has none — nothing in
  `Salsa.@declare_input foo(rt, x)::V` spells `set_foo!`. Without a fallback, uses
  in the declaring file are silently dropped and the result is zero references.
  The fix is to fall back to the same tree-walk the cross-file path uses when no
  binding is found; it is reachable only for a name with no bound identifier at
  its own declaration site, so every ordinary declaration keeps the existing path.
- **Arity lint** — declines because `is_something_with_methods` is false for any
  `TreeRef` (`linting/checks.jl:371`), reached after `:macro_declared` falls out of
  the tree gate at `:410`. The `arity === nothing` guard in the arities index is
  *not* the mechanism: that index never sees these rows at all.
- **Type inference** — `type_inf.jl:93` returns `nothing` for a non-`:external_symbol`
  ref kind, which is the permissive default.

## Edge cases

- A modelled macrocall in a nested module: names land in that module, not the parent.
- The same input declared twice in one module: last in splice order wins.
- A generated name that a real declaration also defines: the real one wins and keeps
  its own arity and signature.
- An explicit `export set_foo!`: needs no work. `_tree_api_status_label`
  (`layer_completions.jl:388`) reads `derived_module_exports`, which comes from a real
  `InventoryExport` record regardless of how the name was declared.
- `Base.@deprecate old new` **exports** `old`, and `@deprecate old new false` does
  not — confirmed by `macroexpand`. v1 does not model that implicit export, so a
  generated name is under-reported as non-exported and will not resolve through
  `using ThatModule` in another module. Under-reporting is the safe direction; this is
  a known gap, not an irrelevance.
- Two `@deprecate` statements in one module share an id key and are separated only by
  the 16-bit positional bucket, so inserting one shifts the other's id. `@declare_input`
  does not have this problem because the input name is part of the key.
- A non-identifier input name: derivation still concatenates, and `_tree_name_label`
  handles the quoting.

## Degradation

Every failure records nothing, which can only leave today's behaviour in place: a
derivation that finds no identifier, a macrocall with no arguments, an unresolvable
owner, an owner whose root is not in the workspace.

- A modelled macro used INSIDE its own owner module is never confirmed. Bare use
  is rejected by the local-shadow check: the owner's own `macro declare_input`
  reads as a foreign shadow of itself. Qualified use is rejected because a
  module's self-binding is not an import, and `_macro_owner_import` inspects
  imports only. Degradation-only, and irrelevant for `Base.@deprecate` (a
  module never IS `Base`).
- `@deprecate Base.foo bar` derives `["foo"]` with an empty qualifier, so `foo`
  becomes visible in the CURRENT module rather than in `Base`, suppressing a
  legitimate missing-reference diagnostic for a bare `foo` there. A rare shape,
  accepted.

## Testing

**Fixtures**, one per outcome and edge case: confirmed through the store branch
(`Base.@deprecate`); confirmed through the workspace-package branch (a package folder
with `Project.toml` and `src/Name.jl` declaring the macro — no manifest needed, since
`derived_workspace_package_roots` is workspace-wide); confirmed foreign through a
local `macro declare_input` shadowing a bare use; confirmed foreign through a
submodule named `Salsa`; unknown; nested module; duplicate name; collision with a real
declaration; collision with a wildcard-import bring-in, asserting the precedence
above; both `@deprecate` forms plus the `where` form; a derivation that finds nothing.
Assertions go through `collect_hints` and `derived_file_analysis`, since a
project-less root publishes no diagnostics.

**Regressions specific to this change:**

- **The declaration site.** `input_a` in `input_a(rt)::Int` is unresolved today and
  exempt via `in_macrocall_arg`; afterwards it resolves to a `TreeRef` and is not a
  definition signature, so it is treated as a *call*. Assert no new
  `IncorrectCallArgs` appears at the declaration.
- **Id stability.** Inserting a `@declare_input` above others leaves the rest's ids
  unchanged; two `@deprecate` in one module do shift. The index carries `ItemRef`s, so
  this is the test §16 of the discussion doc asks for.
- **`_idfree` backdating.** `derived_module_visible_names_idfree` is unchanged when
  only the macrocall's argument id shifts — the whole point of that seam.
- **Cross-root qualified access.** `JuliaWorkspaces.set_input_text_file!` through
  `qualified_module_target` → `_get_field(::TreeModuleContext)` →
  `derived_module_visible_names_idfree` (`layer_file_analysis.jl:194-199`), which is
  the shape the language server itself uses.
- **`origin === :declared` consumers.** A macro-declared name must not break any
  consumer that assumes that origin implies a `derived_module_declared` entry.

**The cycle invariant.** Compute `derived_module_visible_names` for a module with both
a modelled macrocall and imports; if the index ever reads visibility, Salsa raises
`DependencyCycleException` and the test fails. Assert `Salsa.Debug.debug_enabled()` in
the test first: cycle detection is gated on debug mode, and
`layer_visibility.jl:562-565` documents that without it the failure is unbounded
recursion rather than an exception. Cover the cross-root edge (root A's index → root
B's tree) and the mutual dev-dependency case as separate cases.

**Acceptance gates:**

1. **Real-repo LS check** — open julia-vscode in the language server. `src/inputs.jl`
   and every cross-file use of the twelve inputs are diagnostic-free, and no new
   diagnostics appear elsewhere. Note that all twelve uses are *qualified*
   (`Salsa.@declare_input`), so this gate exercises only that path; the bare spelling
   needs its own fixture, listed above.
2. **Visibility differential** — for a module with no modelled macrocall the union
   step is a no-op: the projection is empty and the resulting dict is `isequal` to the
   pre-union one. `isequal` because that is what Salsa's early exit uses.
3. **Perf** — lsbench against the 2026-07-24 baseline shows no measurable change in
   module-tree or visibility recompute time. The new work is one extra splice walk
   plus one lookup per distinct macro spelling. For scale: on this package as a root
   (68 files, 1751 spliced items, warm inventories) one full splice walk measured
   1.4 ms, median of 7, in a dev-env session on 2026-07-31.

## Follow-ups

Deferred, in the order I would do them.

**Family-aware find-references.** References on `input_text_file` should also
report uses of `set_input_text_file!` and `delete_input_text_file!`, and vice
versa: one macrocall declares all three, so they are one logical entity, and a
user asking "where is this input used" means the family. Today each name matches
only its own spelling — `_itemref_is_ambiguous` makes `_tree_restrict_name`
return the name, which is what stops the shared id from conflating them. The
fix is to make that restriction family-aware rather than name-exact: from any
member, recover the declaring row's whole derived-name set (the rule that
produced them is in the table, and `declared_by` names it) and match on any of
them.

**Family rename**, which needs the same primitive. It is the reason rename is
refused today rather than partially implemented: renaming one member leaves the
others dangling. With the family known, renaming any member can rewrite the
primary name at the macrocall plus every use of every derived spelling.

**The `_is_macro_declared_target` precedence bug.** It matches any inventory row
sharing the target's `(id, name)` without requiring the *target's own* kind to be
`:macro_declared`, so where a real declaration shares an id with a same-named
inert sibling (the invalid-but-parseable `@deprecate f(x) = 1` shape) rename is
wrongly refused for the genuine function. Fix: require that no
non-`:macro_declared` item shares that `(id, name)`, mirroring the precedence
`_build_kind_index` now applies. Latent — no valid code reaches the shape.

## Risks

The `origin = :declared` reuse is the subtlest risk: it buys correct precedence for
free but asserts something not backed by `derived_module_declared`. The audit and its
test are what make it safe.

The cross-root query adds a dependency from one root's index to another root's tree,
so editing Salsa invalidates JuliaWorkspaces' index. That is acceptable — such edits
are rare — and using the id-free `derived_module_names` keeps it from firing on every
id shift.

## Files touched

- `src/layer_inventory.jl` — rule table, name derivation, `:macro_declared` kind,
  `declared_by` field on `InventoryItem`, and the `_classify_item!` arm. The walker
  and the `_foreach_toplevel_item` callback contract are unchanged.
- `src/layer_module_tree.jl` — kind-filter parameter on
  `_walk_spliced_binding_items!`; a `_build_kind_index` arm if the new kind needs one.
- `src/layer_visibility.jl` — the two new queries, the union in
  `_visible_names_impl_body`, and the `:tree` branches of `_target_bring_ins` and
  `_member_lookup`.
- `src/layer_completions.jl` — `_completion_kind_for_visible` arm.
- `src/layer_hover.jl` — arm naming the declaring macro.
- `src/layer_symbols.jl` — skip `:macro_declared` rows.
- `src/layer_references.jl` — rename refusal in `_can_rename`.
- `test/` — fixtures, the regression tests, the cycle invariant, the differential.

No changes needed in `src/layer_file_analysis.jl` or `src/StaticLint/` — with the rows
in `items`, ambiguity and name lookup work as they stand, and every StaticLint gate
already defaults to the permissive branch for an unknown ref kind.
