# Implicit-scope member resolution for tree modules

Date: 2026-08-03

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
one helper serves all three call sites: a name the implicit `using` brings into `M`
becomes a binding of `M`, and that is exactly why `Foo.println` resolves at all.
Sites 1 and 2 ask it as a member question, site 3 as a scope question.

- Returns `nothing` when the module at `path` is a `baremodule`
  (`ModuleNode.bare`, already recorded by the tree — a field read, no new
  plumbing). This is correct for site 3 too: a bare `Int` written inside a
  `baremodule` does not resolve either.
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

Three, all consulting the one helper, and all only *after* the existing lookup
misses — so a module's own declarations and its written imports continue to shadow
`Base`, matching Julia.

1. `_get_field(par::TreeModuleContext, …)` at its `vn === nothing` return. Fixes
   `Foo.println` and `Foo.Threads.nthreads()`.
2. `_member_lookup`'s `:tree` and `:workspace_package` branches, at
   `!haskey(names, member_name)`, in place of returning `(:unknown, …)`. Fixes
   `using .Foo: println` binding the name with no kind and no declaration.
3. `_resolve_recorded_type`'s no-face case, folded into a candidate-qualifier
   walk over the same implicit list. Also closes `f(x::Iterators.Zip)` written
   with no import, which today resolves to no opinion because nothing brought
   `Iterators` in — `Base` exports it.

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

**Patching the three sites separately** is also rejected: three copies of a rule
carrying two easy-to-miss gates (export-vs-public, bare).

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
- `f(x::Iterators.Zip)` with no import producing a positional type opinion,
  covering call site 3.
