# Stable inventory item ids

Make an inventory item's id a function of *what the item is* rather than *where
it sits in the file*, so that inserting or reordering an unrelated top-level
statement stops renumbering everything after it.

## The problem

`_walk_one!` mints ids from a single dense counter
(`src/layer_inventory.jl:204-205`):

```julia
next_id[] += 1
f(item, next_id[], parent_module, item_offset)
```

So inserting *any* top-level statement renumbers every statement after it.
Verified directly on the walker: inserting `using Printf` above four
declarations moved them from ids 1,2,3,4 to 2,3,4,5 while the name set stayed
identical.

Ids are carried in `ItemRef` (`@NamedTuple{file::URI, id::Int}`,
`src/layer_module_tree.jl:21`), which is embedded in eleven Salsa derived
values — `derived_module_tree` (through `ModuleNode.declared`/`declared_at` and
`ResolvedImport.from`), `derived_module_declared`, `derived_module_imports`,
`derived_method_items`, `derived_external_method_extensions`,
`derived_module_visible_names`, `derived_visible_item`, `derived_file_analysis`
(through `TreeRef` inside the frozen `meta`, and `OutboundRef.target`) and their
index variants. A semantically inert edit therefore changes all of them, none
backdate, and every consumer re-runs. Measured on a 65-file root: **~1.4 s**,
against a 40–60 ms per-keystroke budget.

The cost is not only the re-run. The codebase has grown a layer of workarounds
whose only purpose is to route around volatile ids:

- A parallel set of **id-free cutoff faces**, each duplicating a query's
  selection minus the ids: `derived_module_names`
  (`src/layer_module_tree.jl:569`, docstring: *"Id-free by construction — this
  is the cutoff seam the inventories milestone rests on"*),
  `derived_module_visible_names_idfree` (`src/layer_visibility.jl:699`, with a
  whole `VisibleNameFace` record), `derived_method_arities`/`_index`,
  `derived_external_extension_names`, `derived_tree_files`,
  `derived_module_exports`, `derived_module_exists`, `derived_file_module_path`,
  `derived_module_unresolved_wildcard_using`.
- The cross-file method matching design
  (`2026-07-29-cross-file-method-matching-design.md`) cannot put an `ItemRef` in
  its index at all, and pays for it with a "Why no `item` field" section, a
  re-resolve-by-`(module path, name)` indirection for every
  declaration-reaching consumer, and a per-root funnel node standing in for the
  per-item queries a stable id would allow.
- `TreeRef` (`src/StaticLint/StaticLint.jl:137-142`) embeds an `ItemRef` and is
  `@auto_hash_equals`, so a positional shift in file B changes file A's frozen
  analysis.

## Prior art

rust-analyzer had this exact problem and fixed it at the root. Commit
`4bcf03e28` ("Use stable AST IDs", 2025-05-21):

> Instead of simple numbering, we hash important bits, like the name of the
> item. This will allow for much better incrementality, e.g. when you add an
> item. Currently, this invalidates the IDs of all following items, which
> invalidates pretty much everything.

Ids became `(kind, hash(name[, parent]), disambiguator)` packed into 16+11+5
bits (`crates/span/src/ast_id.rs:164-191`). Their statement of the stakes
(`ast_id.rs:6-14`) matches the measurement above:

> If one of them invalidates, its interned ID invalidates, and this can cause
> *a lot* to be recomputed […] which is pretty much the worst thing that can
> happen incrementality wise.

Only unnamed kinds (`use`, `extern` blocks) still number sequentially there, and
that residue is an acknowledged FIXME (`ast_id.rs:141-148`). Their regression
test is our scenario exactly: `crates/hir-ty/src/tests/incremental.rs:374`
(`adding_use_query_log`) prepends a `use` and asserts only parse, ast-id-map,
item-tree and def-map re-run.

## What today's id is actually doing

It carries **three** jobs at once. Only one of them wants to be stable.

### 1. Identity — the job that should be content-based

`ItemRef` lookups, `derived_item_positions`' `Dict{Int,…}` key
(`src/layer_inventory.jl:770`), the `(id, name)` composite key in
`_build_kind_index` (`src/layer_module_tree.jl:531`), `_inventory_item_name`
(`src/layer_file_analysis.jl:911`), `_itemref_is_ambiguous` (`:922`).

### 2. Source order — the job that must stay positional

Two sort sites recover Julia's textual-splice semantics purely from id order:

- `src/layer_module_tree.jl:296` — the tree build merges **all five** record
  kinds into one event stream and sorts it:
  `sort!(events; by=e -> (e[1], e[2] === :include ? 0 : 1), alg=MergeSort)`.
- `src/layer_module_tree.jl:762` — `_walk_spliced_binding_items!` does the same
  for items plus includes.

Everything downstream of those sorts is order-dependent: `_declare!`'s
later-declaration-wins and its datatype-vs-method-extension rule
(`src/layer_module_tree.jl:199-207`), `node.declared_at`'s last-splice-wins
(`:310`), depth-first include splicing (`:325-341`), export/publics **list
order** (`:318`) and raw-import order (`:324`) — both of which are inside
`@auto_hash_equals` values and so are part of Salsa's comparison —
`derived_method_items`' documented "splice order" (`:782`), the arity vector
order in `derived_method_arities_index` (`:861`), and
`ExternalExtension`'s "splice order, workspace-wide" (`:927`).

A content hash cannot do this job. It gets its own field.

### 3. Statement grouping — a property to preserve exactly

Ids are **not** unique per record. Four constructs deliberately mint one id for
several records:

| construct | records | site |
|---|---|---|
| tuple destructure `a, b = …` | one `InventoryItem` per bound name | `layer_inventory.jl:591-593` |
| `@enum E a b` | the type plus every member | `:737`, `:745` |
| `const DATA = include("d.jl")` | an `InventoryItem` **and** an `InventoryInclude` | `:610-613` |
| `using A.X, B.Y` | one `InventoryImport` per target | `:723` |

Consumers rely on it: `_itemref_is_ambiguous`, `_tree_restrict_name`
(`src/layer_references.jl:258`), the `(id, name)` composite key, and
`item.id == tr.item.id && item.name == tr.name`
(`src/layer_completions.jl:1207`). The include-first sort tie-break exists
solely for the `const DATA = include(…)` case, and
`test/test_module_tree.jl:295` is the assertion that detects a regression.

Grouping is preserved for free by minting **per statement**, which is where the
counter already sits.

## Design

### `ItemRef` becomes a struct

```julia
const ItemRef = @NamedTuple{file::URI, id::Int}   # before

@auto_hash_equals struct ItemRef                   # after
    file::URI
    id::Int
end
```

An `ItemRef` is the identity of a declaration and appears in eleven derived
values; a `@NamedTuple` alias makes it structurally indistinguishable from any
other `(file, id)` pair, so nothing stops an unrelated named tuple from being
accepted where a declaration reference is meant, and the type name never appears
in a method signature's dispatch. Naming it makes the id change below safer to
review: every construction site has to be visited, rather than continuing to
type-check by shape.

`@auto_hash_equals` is required, not decorative. Without it an immutable struct
falls back to `===`, which is field-wise egality — and `URI` has its own
`==`/`hash` (`src/URIs2/URIs2.jl`) that must be the one used. Salsa's early exit
is `isequal` on the whole value (`Salsa/src/default_storage.jl:275`), so getting
this wrong silently breaks cutoff rather than erroring.

Verified before committing to this: nothing sorts, compares with `isless`,
splats, iterates, or serializes an `ItemRef`, so the NamedTuple's free
`isless`/iteration protocols are not load-bearing. Field access `.file`/`.id` is
unchanged. Six production construction sites become `ItemRef(F, id)`
(`src/layer_module_tree.jl:301`, `:310`, `:313`, `:467`, `:811`, `:964`), plus
three test fixtures (`test/test_module_tree.jl:9`, `:11`, `:12`).
`ExternalExtension` stays a `@NamedTuple`; only its inner `ref` value changes.

### Splitting id from order

`id` splits into two fields on all five record types (`InventoryItem`,
`InventoryImport`, `InventoryExport`, `InventoryInclude`, `InventoryModule`):

```julia
order::Int   # dense, positional, monotone in source order — ordering only
id::Int      # stable content hash — identity only
```

Both participate in `@auto_hash_equals`. `order` must: a pure reorder of two
statements changes declaration precedence, and an inventory that compared equal
across it would let `_declare!` compute last-wins from a stale value.

`ItemRef` keeps its `@NamedTuple{file::URI, id::Int}` shape, so every identity
site keeps working unchanged — it just becomes stable. Both sort sites switch
from `.id` to `.order`, keeping the same numbers under a new name.

### The id

Per statement, in the walker:

```
key = (kind_class, dotted_name, parent_module)
id  = (hash46(key) << 16) | disambiguator
```

- **`kind_class`** — a coarse `Symbol` derived from the EXPR alone
  (`:module`, `:import`, `:export`, `:include`, `:struct`, `:function`,
  `:macro`, `:assignment`, `:macrocall`, `:other`).
- **`dotted_name`** — the name as written, qualifier included, so
  `Base.foo` and `foo` differ. `""` when the statement binds no name.
- **`parent_module`** — the in-file module path, so same-named declarations in
  two modules of one file do not share a bucket.
- **`disambiguator`** — how many earlier statements in this file produced the
  same `key`, so `f(x::Int)` and `f(x::String)` get 0 and 1.
- **46 bits of hash, 16 of disambiguator** — `(2^46-1) << 16 < 2^62`, comfortably
  inside `Int64` and positive.

Deliberately **not** in the key: the signature, the body, the byte offset. An
annotation edit must not move an item's id — that is the churn the matching
design is trying to avoid.

### Why an imperfect discriminator is safe

Correctness comes from the disambiguator, not from the hash. Two statements with
the same `key` get different disambiguators; two statements with different keys
that collide in 46 bits are resolved the same way (below). So a coarse or even
wrong `kind_class`/`dotted_name` costs *stability*, never *uniqueness* — the
degenerate case where every statement produces `key = (:other, "", [])` is
exactly today's positional numbering.

That is what makes this change safe to land incrementally: the walker's key
extraction does not have to agree with the inventory classifier's much larger
dispatch. It only has to be a pure function of `(EXPR, parent_module)`, so that
`derived_file_inventory` and `derived_item_positions` — which both drive the
same walker (`src/layer_inventory.jl:157-158`: *"This walker is the single
source of truth for item ids: the inventory extractor and the position map both
use it, so ids always agree"*) — keep agreeing.

### Uniqueness within a file

Ids are per-file, never per-root: the counter resets per walk
(`src/layer_inventory.jl:161`) and every consumer keys on the `(file, id)` pair.
So collisions only matter within one file.

The allocator keeps a per-file `Set{Int}` of assigned ids. If a computed id is
already taken — a 46-bit hash collision between different keys, or a
disambiguator past `0xFFFF` — it increments until free. Deterministic under a
fixed walk order, and it degrades gracefully rather than aliasing two
statements onto one id.

## Implementation

### Commit 1 — `ItemRef` becomes a struct (no behaviour change)

1. Replace the alias with the `@auto_hash_equals struct` above, keeping it in
   `src/layer_module_tree.jl` so `StaticLint`'s `import ..ItemRef`
   (`src/StaticLint/StaticLint.jl:6`) is untouched.
2. Convert the six production construction sites and three test fixtures.
3. Full suite passes unchanged.

### Commit 2 — separate order from identity (no behaviour change)

1. Add `order::Int` as the first field of all five record types; keep `id::Int`.
2. Thread `order` through the walker exactly as `next_id` is threaded today, and
   have the mint site pass both, with `id == order` for now.
3. Point both sort sites (`layer_module_tree.jl:296`, `:762`) and their
   event-tuple construction at `.order`.
4. Update the two hand-built test fixtures (`test/test_inventory.jl:7-22`,
   `test/test_module_tree.jl:9-12`) for the new arity.

The full suite must pass unchanged — that is the check that the rename is inert.

### Commit 3 — make `id` a content hash

1. Replace the `Ref{Int}` counter with an allocator struct carrying the order
   counter, the `key => count` table, and the assigned-id set.
2. Add `_statement_id_key(x, parent_module)` and `_pack_item_id(hash, dis)`.
3. Mint per statement as above.
4. Migrate the tests below.

## Test plan

### New tests

1. **Insertion stability.** A file with four declarations; prepend
   `using Printf`; assert every pre-existing item's `id` is unchanged and its
   `order` shifted. This is the whole point of the change, and rust-analyzer's
   `adding_use_query_log` in miniature.
2. **Insertion does not invalidate.** The same edit, with a Salsa execution
   recorder: `derived_module_tree` recomputes (a new import genuinely changed
   the tree) but `derived_module_declared` for an untouched name backdates.
3. **Reorder stability.** Swap two same-kind, differently-named declarations;
   assert both ids are unchanged and that declaration precedence still follows
   `order`.
4. **Signature edits do not move ids.** `f(x::Int)` → `f(x::String)` leaves the
   item's `id` equal.
5. **Same-name methods get disambiguators.** Two methods of one generic in one
   file get distinct ids; inserting a third *before* them shifts only their
   disambiguators, not the ids of other names in the file.
6. **Statement grouping preserved.** For each of the four constructs in the
   table above, the records minted from one statement still share an id — with
   `const DATA = include("d.jl")` asserted explicitly, since the sort tie-break
   depends on it.
7. **Per-file uniqueness.** For a file exercising every classifier branch, all
   minted ids are distinct.
8. **Collision fallback.** Unit-test the allocator directly: feed it two keys
   forced to the same packed slot and assert distinct ids out.

### Existing tests that must change

Enumerated from a full sweep, so the migration is not discovered piecemeal:

| test | current assertion | change |
|---|---|---|
| `test/test_inventory.jl:54` | `[v.id for v in visited] == collect(1:7)` | assert on `order`; keep an `allunique(id)` check |
| `test/test_inventory.jl:105` | `… == collect(1:5)` | same |
| `test/test_inventory.jl:716` | `… == collect(1:3)` | same |
| `test/test_module_tree.jl:751-752` | `declared_after["f"].id != before["f"].id` | **inverts** to `==` — the reorder no longer moves ids |
| `test/test_module_tree.jl:755` | `counts["probe_declared"] == 1` | expect `0`; the value now backdates |
| `test/test_file_analysis.jl:735` | `new_a != old_a` | inverts |
| `test/test_file_analysis.jl:996-997` | `after["a"] != before["a"]` | inverts |
| `test/test_file_analysis.jl:732`, `:983`, `:987` | re-execution counts `== 1` | expect `0` |
| `test/test_inventory.jl:7-22`, `test/test_module_tree.jl:9-12` | hand-built fixtures with literal ids | new field arity (already touched in commits 1-2) |

`test/test_file_analysis.jl:998` (`after["c"] == before["c"]`) and
`test/test_inventory.jl:294` (offset shifted, id used only as a key) hold
unchanged. `test/test_inventory.jl:656`'s `length(pos) <= 4 + 1` holds because
the count of minted ids is unchanged.

The splice-semantics tests are the safety net for the `order` rename and must
pass untouched: `test/test_module_tree.jl:185`, `:197`, `:260`, `:265`, `:279`,
`:295`, `:1348-1362`, `:1382`, and `test/test_hover.jl:845` (exact byte order of
two method signature blocks).

## Non-goals

- **Not** removing the id-free cutoff faces. They become redundant, but deleting
  them is a separate change with its own risk.
- **Not** touching `TreeRef`. It benefits automatically.
- **Not** changing the cross-file matching design. Its workarounds stay correct;
  the conditional it records (per-item signature queries instead of fields on
  `InventoryItem`) becomes available once this lands.
- **Not** introducing per-item derived queries. That is the follow-on this
  unblocks.

## Risks

- **Key extraction drifts from the classifier.** Mitigated structurally: a wrong
  key costs stability, not correctness. Test 7 pins per-file uniqueness across
  every classifier branch.
- **Same-name method churn.** Inserting a method of `f` shifts the
  disambiguators of `f`'s later methods. Strictly better than today (where it
  shifts every later statement in the file), but it is the residue, and it is
  the same residue rust-analyzer accepts for unnamed items.
- **Opaque ids in fixtures and logs.** Ids become large numbers. Tests must
  assert relationships, not values — which is the point of the migration table.
- **`order` keeps the inventory value churning on insertion.** Cutoff moves one
  level up: the inventory changes, and `derived_module_tree` recomputes and
  backdates. The win is that its *value* stops changing, so nothing downstream
  re-runs.
