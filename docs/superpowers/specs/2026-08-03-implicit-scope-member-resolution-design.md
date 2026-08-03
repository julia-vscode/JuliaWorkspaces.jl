# Implicit-scope member resolution for tree modules

Date: 2026-08-03. Revised the same day: base and scope settled, see **Scope and
base**; a second consumer for the `baremodule` gate found, see **The helper**.

## Scope and base

**Base: `main`.** Everything the two valuable call sites need is already there —
checked, not assumed:

| prerequisite | `main` | notes |
|---|---|---|
| `_get_field(::TreeModuleContext)` | ✓ | call site 1 |
| `TreeRef` kind `:external_module` | ✓ | the plain-data stand-in this returns |
| `qualified_module_target` | ✓ | what continues the chain past a module |
| `_member_lookup` | ✓ | call site 2 |
| `_resolve_recorded_type` | **✗** | only on the type-matching branch |

So this slice depends on neither feature branch. The third call site
(`_resolve_recorded_type`, the cross-file positional type check) becomes a **rider
commit on the type-matching branch**, carrying with it the `f(x::Iterators.Zip)`
case — an annotation written with no import, which today resolves to no opinion
because nothing brought `Iterators` in even though `Base` exports it.

Two branches will meet this one at a shared line; see **Precedence at a shared
miss point**.

## Problem

Member access into a workspace module does not resolve names the module gets from
its implicit `using Base`. `Foo.println(2)` and `Foo.Threads.nthreads()` carry no
ref at all when `Foo` is declared in a sibling file, so hover, go-to-definition,
signature help and the type paths all have nothing to work with.

No diagnostic is emitted for the unresolved names, so this is missing capability
rather than a false positive. Nothing regresses today; features silently do
nothing on these spellings.

## The rule, and who already implements it

A member of module `M` is:

1. `M`'s own declaration — regardless of whether `M` exports it, because
   qualified access reaches a module's own non-exported names; or
2. an **exported** name of any module `M` `using`s — `public`-but-not-exported
   does not count, because `using` brings in exports only.

Every module implicitly `using`s `Base` and `Core`, except a `baremodule`.

Verified against the language (Julia 1.12): `Foo.Threads` → `Base.Threads`;
`Foo.println` → `println`; `Foo.Filesystem` → `UndefVarError`, even though
`:Filesystem in names(Base)` is `true`, because `Filesystem` is `public` and not
exported; `Bare.println` → `UndefVarError` for a `baremodule`.

Two of the three resolution modes already implement exactly this:

- **`Scope`** (single-file): `semantic_pass` seeds `root_modules` with the `Base`
  and `Core` stores, and the scope walk consults them after the lexical chain.
- **stores** (cross-env): `SymbolServer.maybe_getfield` returns `m.vals[k]` if
  present, else walks `m.used_modules` and accepts `k` only when
  `k in submod.exportednames && haskey(submod.vals, k)`.

The **module tree** records a module's *written* `using` statements but not the
two implicit ones. That single omission is the entire defect.

## Measured before-state

Four spellings against a module `Foo` that declares only `f`, in each mode.
`X.own` is `Foo.f`; `X.export` is `Foo.println`; `X.export_mod` is `Foo.Threads`
followed by `.nthreads()`; `X.public` is `Foo.Filesystem`.

| mode | machinery | `X.own` | `X.export` | `X.export_mod` → chain | `X.public` |
|---|---|---|---|---|---|
| single-file | `Scope` / `root_modules` | `Binding` | `FunctionStore` | `TreeRef(:external_module, origin=["Base"])` → `FunctionStore` | no ref |
| cross-file | tree / `_get_field(TreeModuleContext)` | `TreeRef` | **no ref** | **no ref** → **no ref** | no ref |
| cross-env | store / `maybe_getfield` | `m.vals` | via `used_modules` | via `used_modules` | no ref |

Exactly one row deviates, and `X.public` being unresolved everywhere is the
built-in negative control: it must stay that way.

## Design

### The helper

```
_implicit_member(rt, root, path::Vector{String}, name::String) -> Union{Nothing,Any}
```

Lives in `layer_file_analysis.jl`, which is included after `StaticLint` and so can
reach both the env and the tree.

"Member of `M`" and "name in scope at `M`" are the same lookup here, which is why
one helper serves every call site: a name the implicit `using` brings into `M`
becomes a binding of `M`, and that is exactly why `Foo.println` resolves at all.
Sites 1 and 2 ask it as a member question; the type-branch rider asks it as a scope
question.

- Returns `nothing` when the module at `path` is a `baremodule`, which has no
  implicit `using Base` — correct for the rider too, since a bare `Int` written
  inside a `baremodule` does not resolve either.

  The gate reads a **new `derived_module_is_bare(rt, root, path)`** projection in
  `layer_module_tree.jl`, shaped exactly like `derived_module_exists` (three lines
  over `module_node(...).bare`, which the tree already records correctly —
  measured `false` for `module T` and `true` for `baremodule T`). A per-module node
  rather than a `ModuleNode` field read, because there is a **second consumer**:
  `_macro_owner_confirmed`'s implicit-owner branch treats `Base` as unconditionally
  in scope, so it confirms `@deprecate` inside a `baremodule` and mints a phantom
  declared name. Measured on the macro-declared-names branch:

  ```
  module T     + @deprecate f g   ->  confirmed: ["f"]   correct
  baremodule T + @deprecate f g   ->  confirmed: ["f"]   wrong
  baremodule T + Base.@deprecate  ->  confirmed: ["f"]   wrong (Base isn't in scope either)
  ```

  **The node is landed on this branch**, with a test that exercises it directly
  rather than through either consumer. The confirmation fix itself could not land
  with it: `_macro_owner_confirmed` does not exist on `main`, only on
  `sp/macro-declared-names`. Its shape, for whoever applies it — most likely as
  part of this branch's rebase after that one merges — is to make the
  implicit-owner branch available only to a non-bare module and otherwise **fall
  through to requiring a real import**, which then handles
  `baremodule T; using Base; @deprecate …` by construction rather than by accident.
  It must consume `derived_module_is_bare` rather than growing a second copy of the
  gate.
- Otherwise, walks `StaticLint.IMPLICIT_SCOPE_MODULES` **in order, first match
  wins**, accepting `name` only when it is in that store's `exportednames` **and**
  present in its `vals`. This mirrors `maybe_getfield`'s inner test.
  `publicnames` is deliberately never read — that is what keeps `Foo.Filesystem`
  unresolved. (Order is not observable in practice: where `Base` and `Core` share
  a name they share the binding.)
- Resolves a `VarRef` value through the env before returning it, as the store path
  does via `maybe_lookup`.
- Returns the store value, except a module-valued one, which is returned as
  `TreeRef(name, :external_module, nothing, providing_path)` — the plain-data
  stand-in the per-file purity rule requires, and the shape single-file mode
  already emits for the same spelling. `providing_path` is the path of the module
  that provided the name, i.e. the `origin_module` prefix convention
  `_context_tree_ref` uses: `Foo.Threads` yields `name = "Threads"`,
  `origin_module = ["Base"]`, denoting `Base.Threads` — measured to be exactly what
  single-file mode emits.

`StaticLint.IMPLICIT_SCOPE_MODULES` is a new `const (:Base, :Core)` in
`StaticLint.jl`, which `semantic_pass` also reads when building `root_modules`, so
the fact is stated once in the module that owns it. Place the `const` *above*
`semantic_pass`'s docstring: inserted between that docstring and the function, the
docstring tries to document the `const`'s own docstring and the file fails to load.

### Call sites

Two in this slice, both consulting the one helper, and both only *after* the
existing lookup misses — so a module's own declarations and its written imports
continue to shadow `Base`, matching Julia.

1. `_get_field(par::TreeModuleContext, …)` at its `vn === nothing` return. Fixes
   `Foo.println` and `Foo.Threads.nthreads()`.
2. `_member_lookup`'s `:tree` and `:workspace_package` branches, at
   `!haskey(names, member_name)`, in place of returning `(:unknown, …)`. Fixes
   `using .Foo: println` binding the name with no kind and no declaration.

The third, `_resolve_recorded_type`'s no-face case folded into a
candidate-qualifier walk over the same implicit list, is the rider described under
**Scope and base**.

### Precedence at a shared miss point

Both call sites are miss-points that another branch also extends, so the order has
to be stated rather than discovered in a merge:

- `_member_lookup`'s `!haskey(names, member_name)` is where the macro-declared-names
  branch adds its own fallback (`derived_module_macro_declared_names`).
- `_get_field`'s `vn === nothing` is the same shape.

**A module's confirmed macro-declared names come first; the implicit scope second.**
A name a modelled macro declares in *this* module is a declaration of this module,
and a module's own declarations beat the implicit `using Base` — the rule real Julia
applies when a local `f` shadows `Base.f`, and the same one
`_macro_owner_confirmed`'s local-shadow check already encodes. Concretely:
`using .Foo: println` where `Foo` macro-declares its own `println` must resolve to
Foo's, not to `Base.println`.

Whichever branch merges second is responsible for landing the fallbacks in that
order.

### No downstream changes

Both returned shapes already exist and are already handled. `qualified_module_target`
maps an `:external_module` `TreeRef` back to its `ModuleStore`, which is how
single-file mode's `nthreads` resolves through `Foo.Threads` today. No new ref
kind, no consumer changes in hover, navigation, references or signatures.

## Rejected alternative, and why

**Model the implicit `using` in the tree itself** — have the module tree record a
synthetic implicit import for every non-bare module, so
`derived_module_visible_names` gains the names and every consumer is fixed at once
with no per-site work.

This is the more faithful model. It is rejected on **memoization cost, not
correctness**: `_target_bring_ins` materializes one `VisibleName` per exported
name, so each module would gain ~1108 entries (Base's `exportednames`) inside a
cached Salsa dict that is equality-compared on every invalidation — on the order
of 550k entries for a 500-module workspace, plus the compare cost on every
visibility recompute. It would also change what completions and workspace-symbol
search enumerate, which is out of scope below.

Recording this explicitly per the standing constraint that a mode may only be
treated differently with sign-off: the sign-off here is for the resolve-on-miss
implementation of a rule that is otherwise identical across all three modes.

**Patching each site separately** is also rejected: a copy per site of a rule
carrying two easy-to-miss gates (export-vs-public, bare) — and the `baremodule`
gate already has a second consumer outside this slice, which is why it lands as a
node rather than as inline field reads.

## Non-goals

- **Completion enumeration after `Foo.`.** Julia's REPL lists `names(Foo)` — the
  module's own names, not Base's 1108 exports — so not offering them is
  defensible UX rather than a parity gap. Enumeration behaviour across the three
  modes will be measured separately and any real asymmetry filed on its own.
- **Workspace-symbol search**, for the same reason.
- **Cross-file workspace-type ancestry** (a sibling's `struct` participating in
  the positional type check). Same parity family, different mechanism — it needs a
  tree-backed operand in `subtypes.jl` — and it is tracked separately.

## Testing

The parity matrix is the test shape. For each of the four spellings, assert the
cross-file mode now produces the same resolution as single-file, cell for cell,
including that `Foo.Threads.nthreads()` resolves *both* components so the chain
continuation is pinned rather than just the first hop.

Plus:

- a `baremodule` case asserting all four spellings stay unresolved;
- `Foo.Filesystem` staying unresolved, which fails if the implementation reads
  `publicnames` or the full `vals`;
- a module that declares its own `println`, asserting the declaration shadows
  `Base` (the lookup order);
- `using .Foo: println` resolving to a kind and a declaration rather than
  `:unknown`;
- `derived_module_is_bare` answering `false`/`true` for `module`/`baremodule`,
  directly — it is a shared node with a consumer outside this slice, so it wants a
  test that does not depend on either consumer.

Deferred to the rider on the type-matching branch: `f(x::Iterators.Zip)` with no
import producing a positional type opinion.

The precedence rule under **Precedence at a shared miss point** is tested by
whichever branch lands second, since neither fallback exists without the other.
