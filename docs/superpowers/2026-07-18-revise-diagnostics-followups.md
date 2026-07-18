# Revise.jl false-diagnostics follow-ups (2026-07-18)

Plan for the remaining items from a pass over false diagnostics in
`/home/pfitzseb/git/Revise.jl`. Several sibling issues from the same list were
already fixed and committed on `sp/inventories` this session (see "Done" below);
this file captures what's left, each with a reproduction and a fix direction so a
future session can execute without re-deriving.

## Done this session (committed on `sp/inventories`, unpushed)
- **`global`/`local x::T` declaration binding** — StaticLint `mark_bindings!` + the
  inventory `:global` extractor both now handle the typed-declaration form, so
  Revise's module-wide `global juliadir::String` / `global basesrccache::String`
  resolve (same-file and cross-file). Commits `fix: bind declaration-only …` and
  `fix: extract declaration-only typed globals in the inventory`.
- **Core-in-Base re-export identity** — the CORE_BASE_NAMES_CONFUSION removal had
  regressed `check_call`/`check_kw_default`/`nothing`-equality by turning
  `Base.String`/`Base.Int`/`Base.nothing` into method-poor VarRefs or duplicate
  stores. Fixed the crawler's DataType branch (preserve seeded stores; parametric
  types get a DataTypeStore) and made `check_nothing_equality` accept the Base
  re-export. Restores `Ref(5.0)` too. Commits `fix: restore Core-in-Base re-export
  identity …` and `fix: carry methods for parametric Core types re-exported by Base`.
- **`invokelatest`/`invoke`/`invoke_in_world` keywords** — they forward `; kwargs...`
  but crawl to `kws == []`, so `invokelatest(showerror, io, err; blame_revise=false)`
  false-flagged. Marked with a keyword splat; `invoke`'s wrong crawled signature
  (spurious extra positional) replaced with its 3 documented forms. Commit
  `fix: correct invoke signature and let kwarg-forwarding builtins take keywords`.
- **Typed tuple-destructure element types** — `(file, line)::Tuple{AbstractString, Any}`
  now infers `file::AbstractString` / `line::Any` positionally instead of the whole
  tuple type. Commit `fix: infer element types of a typed tuple-destructure positionally`.
- **`FileWatching` dependency** — declared it (used by `src/CloudIndex/depot_lock.jl`),
  fixing the cloud-index depot-lock tests. Commit `fix: declare FileWatching …`.

`Base.Docs.doc` "0 methods" was **deliberately left** (user decision): its methods
live in the REPL stdlib, which `load_core` doesn't crawl, and REPL isn't an
always-available sysimage stdlib — 0 methods is arguably correct for scripts, and
it's only a hover cosmetic (`check_call` doesn't flag it).

---

## 1. Cross-file constructor type inference through a `TreeRef` callee *(highest value; root-caused)*

**Symptom.** In `Revise.jl/src/stale_load.jl:62`, `Base.insert_extension_triggers(key)`
is flagged **"Possible method call error."** because `key` (from `key = PkgId(M)` a
few lines up, inside `for M in newmods`) is inferred as **`String`** instead of `PkgId`.

**Root cause.** `PkgId` is imported in a *sibling* file (`using Base: PkgId` in
`packagedef.jl`) and used in `stale_load.jl`. Cross-file it correctly resolves — but to
a **`TreeRef`** (`kind = :external_symbol`, `origin_module = ["Base"]`, `name = "PkgId"`),
not a `Binding`/`DataTypeStore`. `infer_type_assignment_rhs`
(`src/StaticLint/type_inf.jl`, the `is_func_call(rhs)` branch, ~lines 94–111) only sets
the constructed type when the resolved callee `rb` is `rb isa Binding` (with a datatype
type) or `rb isa DataTypeStore`. A `TreeRef` matches neither, so `key` is left **untyped**
— and then `infer_type_by_use` derives `key::String` from `insert_extension_triggers`'s
store signature, which then makes the call itself flag.

Once the constructor sets `key::PkgId`, by-use inference never runs and both the wrong
`String` and the method-error disappear — so this is a single fix.

**Reproduction (must use the per-file, context-aware meta):**
```julia
root  = "module Root\nusing Base: PkgId\ninclude(\"stale.jl\")\nend\n"
stale = "function f(newmods)\n    for M in newmods\n        key = PkgId(M)\n        Base.insert_extension_triggers(key)\n    end\nend\n"
# add both files; root_uri = .../Root.jl, s = .../stale.jl
fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root_uri, s)   # NOT derived_static_lint_meta_for_root
md = fa.meta
# key binding type == Core.String (bug; want PkgId); fa.diagnostics == ["Possible method call error."]
# refof(the PkgId callee, md) isa StaticLint.TreeRef   (kind :external_symbol, origin_module ["Base"])
```
> ⚠️ **Testing gotcha (cost me an hour):** `derived_static_lint_meta_for_root(rt, uri)`
> analyzes a *non-root* file **standalone**, WITHOUT its module context, so cross-file
> imports/declarations don't resolve there (even a declared sibling `foo` misses). Use
> `derived_file_analysis(rt, root, uri).meta` for anything cross-file.

**Fix direction.**
- Add a helper in StaticLint that resolves a datatype-denoting `TreeRef` to its
  `SymStore` via `env`: walk `getsymbols(env)` by `tr.origin_module` to the
  `ModuleStore`, then `store.vals[Symbol(tr.name)]` (following a `VarRef` via
  `maybe_lookup`). This mirrors hover's `_resolve_external_module` +
  `store.vals[Symbol(tr.name)]` path (`src/layer_hover.jl:410`), but stays inside
  StaticLint (which already has `env`). Handle `kind === :external_symbol`; consider
  `:declared`/datatype tree kinds too (a cross-file *workspace* struct used as a
  constructor has the same shape — verify separately).
- In `infer_type_assignment_rhs`' constructor branch, when `refof(callname)` is a
  `TreeRef`, resolve it with that helper and, if it yields a `DataTypeStore`,
  `settype!(binding, store)` (the destructuring arm too).
- Do the parallel change in `infer_type_decl` (both the 3-arg and 4-arg forms) so a
  cross-file `::PkgId`-style annotation narrows the same way. Note `Binding.type`
  can't carry a `TreeRef` (see `declared_type_is_tree_backed`, ~line 237) — the value
  set should be the resolved `DataTypeStore`, not the `TreeRef`.

**Related sub-gap (same area, cheaper):** a *qualified* constructor `key = Base.PkgId(mod)`
(getfield callee) also infers nothing, because the branch guards on
`isidentifier(callname)` and a getfield callee isn't an identifier. Extend it to the
`is_getfield_w_quotenode(callname)` case (resolve via `resolve_getfield` /
`refof_maybe_getfield`), reusing the same "resolved callee → DataTypeStore → settype"
tail. Bare imported `PkgId(mod)` already works.

**Tests:** add to `test/staticlint/test_inference.jl` — a two-file workspace exercising
`derived_file_analysis(rt, root, uri).meta`, asserting `key::PkgId` and no diagnostic on
a following `f(key)` where `f`'s arg is that type; plus the qualified-callee single-file case.

## 2. Loop-variable eltype inference from a typed collection *(was "#5 case 2"; broad, benign)*

**Symptom.** `for (; reeval, mod, …) in reeval_infos` (property destructure) yields no
types for the destructured fields. But it's broader: **even `for x in xs` with
`xs::Vector{Int}` infers nothing** for `x`.

**Root cause.** `infer_eltype` (`src/StaticLint/type_inf.jl`, ~line 511) only derives an
element type from an *assignment-RHS* binding (`r.val` is an `=` EXPR); it does not use a
binding's declared/inferred **type** (`Vector{Int}` → `Int`). So typed collections don't
propagate an eltype, and the property-destructure-in-loop case (which would layer
`infer_destructuring_type` on top of the eltype) never gets started.

**Fix direction.** Teach `infer_eltype` to peel one container layer from a binding's
*type* (a `DataTypeStore`/parametric `FakeTypeName` for `AbstractArray`/`Dict`/…): return
the element/`valtype` parameter. Then wire the for-loop property-destructure path (it goes
through `is_loop_iter_assignment` in `infer_type_assignment_rhs`) to run
`infer_destructuring_type` against that eltype. This is a genuine feature, not a small
patch — scope it deliberately. Benign until then (no *wrong* type, just unknown).

## 3. Method definition through a type alias (`ModuleExprsInfos`) *(needs reproduction)*

**Context.** `Revise.jl/src/types.jl:247` — `const ModuleExprsInfos =
OrderedDict{Module,ExprsInfos}` (a `const` alias to a parametric type owned by
OrderedCollections). Methods are defined *through* the alias:
- constructor-style: `ModuleExprsInfos(mod::Module) = ModuleExprsInfos(mod=>ExprsInfos())`
  (`types.jl:259`),
- extensions: `Base.isempty(fm::ModuleExprsInfos) = …` (`types.jl:261`),
  `FileInfo(fm::ModuleExprsInfos, …) = …` (`types.jl:295,306`),
- args typed `::ModuleExprsInfos` in several signatures (`parsing.jl:15`, …).

**Hypothesis (unverified).** Defining/adding a method whose name is a `const` alias of a
foreign parametric type (`ModuleExprsInfos(mod) = …` adds an `OrderedDict` constructor via
the alias) is likely mis-handled — e.g. `CannotDefineFuncAlreadyHasValue`, or the alias not
recognized as a datatype so the method/arg doesn't resolve. **First step: reproduce** — a
single file with `const A = Dict{Int,Int}` then `A(x::Int) = A()` and `g(a::A) = a`; check
`errorof` on the definitions and whether `::A` args resolve to the datatype. Then trace
into `bindings.jl` (`mark_typealias_bindings!`, the datatype/`add_binding` path) and
`check_call`/type resolution for alias-typed args.

## 4. Hardcode `invokelatest`/`invoke_in_world` signatures for param names *(task #53; cosmetic)*

Their crawled methods are the lenient generic `(x...)` (correct for `check_call`, already
carry the keyword splat from item under "Done"), but hover/signature-help shows `x...`
instead of meaningful names. In `load_core` (`shared/symbolserver/symbols.jl`, next to the
`invoke` replacement), replace their `cache[:Core][name].methods` with the documented
forms — `invokelatest(f, args...; kwargs...)`, `invoke_in_world(world, f, args...; kwargs...)`
— keeping `[Symbol("kwargs...")]`. Requires a session restart to rebake `const stdlibs`.
Purely a signature-help nicety; the functional behavior is already correct.

---

### Working notes
- After editing `shared/symbolserver/symbols.jl` (`load_core`), the running store is the
  precompile-baked `const stdlibs` — verify with a fresh `SymbolServer.load_core()`, and
  **restart** the julia-mcp session to rebake before checking the `derived_*` pipeline.
- StaticLint/inventory/type-inf edits are picked up by Revise without a restart, but build a
  **fresh `JuliaWorkspace`** per check (new runtime ⇒ no stale Salsa memoization).
- Cross-file behavior: `derived_file_analysis(rt, root, uri).meta`, not
  `derived_static_lint_meta_for_root`.
