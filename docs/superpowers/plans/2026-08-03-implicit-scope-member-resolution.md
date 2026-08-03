# Implicit-Scope Member Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a name that a workspace module gets from its implicit `using Base`/`using Core` resolve when the module is reached through the module tree, so `Foo.println` and `Foo.Threads.nthreads()` get refs (and therefore hover, go-to-definition and completion) exactly as they already do when `Foo` is declared in the same file.

**Architecture:** One helper, `_implicit_member`, consulted at two existing *miss* points — `_get_field(::TreeModuleContext)` and `_member_lookup` — so a module's own declarations and its written imports keep shadowing `Base`. It returns the same ref shapes single-file mode already emits: a store value for a function/type, and a plain-data `TreeRef(:external_module, …)` stand-in for a module so the getfield chain can continue. Nothing is added to any cached Salsa value.

**Tech Stack:** Julia 1.12, CSTParser, SymbolServer store types, Salsa (`@derived` nodes), TestItemRunner.

## Global Constraints

- **Base: `main`.** `derived_module_is_bare` is already landed on this branch (`86486a6`). Do not re-add it.
- **The predicate is `exportednames`, never `publicnames`.** `:Filesystem in names(Base)` is `true` yet `Foo.Filesystem` is an `UndefVarError`, because `Filesystem` is `public` and not exported. Reading `publicnames` would resolve names Julia does not.
- **A module's own member wins; the implicit scope is a fallback.** Only ever consulted after the existing lookup misses.
- **`baremodule` gets nothing.** It has no implicit `using Base`/`using Core`.
- **Refs stored in `meta_dict` must be plain data.** A `ModuleStore` must never be setref'd; return the `TreeRef` stand-in instead. Store `FunctionStore`/`DataTypeStore` values are already normal ref shapes and are fine.
- **No enumeration changes.** Completions after `Foo.` and workspace-symbol search are explicit non-goals.
- **Run tests via julia-mcp in the dev env**, never by spawning julia:
  `Pkg.activate("/home/pfitzseb/git/julia-vscode/scripts/environments/development")`, then
  `TestItemRunner.run_tests("./test"; filter=ti->…)` from the package directory.
  Restart the Julia session after changing a struct or adding a `@derived` node.

### Correction to the spec, to apply in Task 2

The spec's parenthetical under **The helper** — "Order is not observable in practice: where `Base` and `Core` share a name they share the binding" — is **false**, measured:

| name | `Base.vals` | `Core.vals` | both exported |
|---|---|---|---|
| `Int` | `FunctionStore` | `DataTypeStore` | yes |

Base-first remains correct: a bare `Int` written in any file already resolves through the root scope's `Base` store to that same `FunctionStore`, so this reproduces bare-name resolution rather than diverging from it.

Consumers get from the constructor to the type through **`StaticLint.get_eventual_datatype(store, env)`**, which follows the `FunctionStore`'s `.extends` `VarRef` to the `DataTypeStore`, with `resolves_to_datatype(store, env)` as the boolean wrapper (`src/StaticLint/type_inf.jl:433-442`). Task 2 replaces the parenthetical with this fact.

---

## File Structure

| file | responsibility | change |
|---|---|---|
| `src/StaticLint/StaticLint.jl` | owns the root scope, therefore owns *which modules are implicitly in scope* | add `IMPLICIT_SCOPE_MODULES`; `semantic_pass` reads it |
| `src/layer_visibility.jl` | the documented env seam; already holds `_resolve_env` and `_resolve_external_module` | add `_implicit_member`; call it from `_member_lookup` |
| `src/layer_file_analysis.jl` | the per-file resolution bridge | call `_implicit_member` from `_get_field(::TreeModuleContext)` |
| `test/test_implicit_scope.jl` | **new** — the harness and every test for this slice | create |
| `docs/superpowers/specs/2026-08-03-implicit-scope-member-resolution-design.md` | the spec | one correction, Task 2 |

**Deviation from the spec, deliberate:** the spec suggested `layer_file_analysis.jl` for `_implicit_member`, reasoning that it is included after `StaticLint`. That reason does not bind — a function body resolves names at call time, so include order is irrelevant here. `layer_visibility.jl` is the better home: it is the file whose header declares it "the one place in the inventory architecture that reads the environment", and it already contains the two helpers `_implicit_member` is built from. `layer_file_analysis.jl` is included later and can call it.

---

## Task 1: `IMPLICIT_SCOPE_MODULES` in StaticLint

**Files:**
- Modify: `src/StaticLint/StaticLint.jl` (immediately above `semantic_pass`'s docstring)
- Test: `test/staticlint/test_staticlint.jl` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `StaticLint.IMPLICIT_SCOPE_MODULES::Tuple{Symbol,Symbol}` == `(:Base, :Core)`. Task 2 iterates it.

- [ ] **Step 1: Write the failing test**

Append to `test/staticlint/test_staticlint.jl`:

```julia
@testitem "IMPLICIT_SCOPE_MODULES is the root scope's module list" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: IMPLICIT_SCOPE_MODULES, scopeof, scopehasmodule

    # The fact that `Base` and `Core` are reachable without an import is a property
    # of the root scope `semantic_pass` seeds, so the list lives with it. Anything
    # else answering for a name no import accounts for must read this, not restate it.
    @test IMPLICIT_SCOPE_MODULES == (:Base, :Core)

    # ...and the pass really does seed exactly these into the root scope.
    cst, meta_dict = parse_and_pass("f(x) = x")
    sc = scopeof(cst, meta_dict)
    for m in IMPLICIT_SCOPE_MODULES
        @test scopehasmodule(sc, m)
    end

    # A bare exported Base name still resolves — the point of the seeding.
    cst2, meta_dict2 = parse_and_pass("f() = println(1)")
    @test isempty([x for (_, x) in StaticLint.collect_hints(cst2,
        JuliaWorkspaces.StaticLint.getenv(meta_dict2), Dict{String,Any}(), meta_dict2, :all)])
end
```

- [ ] **Step 2: Run it and confirm it fails**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("IMPLICIT_SCOPE_MODULES", ti.name))
```

Expected: FAIL — `UndefVarError: IMPLICIT_SCOPE_MODULES`.

If the third assertion also fails for an unrelated reason (`getenv` not being the right accessor for an env in that harness), replace those four lines with the simpler check that the pass ran at all: `@test scopehasmodule(scopeof(cst2, meta_dict2), :Base)`. The first two assertions are the ones this task is about.

- [ ] **Step 3: Add the const and make `semantic_pass` read it**

In `src/StaticLint/StaticLint.jl`, insert **above** `semantic_pass`'s existing docstring — *not* between that docstring and the `function` line, which makes the docstring try to document the const and the file fails to load with "cannot document the following expression":

```julia
"""
    IMPLICIT_SCOPE_MODULES

The modules every module can reach without an import. `semantic_pass` seeds them
into the root scope, which is what makes a bare `Int` resolve in any file; anything
else that has to answer for a name no written import accounts for is answering the
same question, and must read this list rather than restate it.
"""
const IMPLICIT_SCOPE_MODULES = (:Base, :Core)
```

Then replace the first line of `semantic_pass`'s body:

```julia
    root_modules = Dict{Symbol,Any}(m => env.symbols[m] for m in IMPLICIT_SCOPE_MODULES)
```

(was `Dict{Symbol,Any}(:Base => env.symbols[:Base], :Core => env.symbols[:Core])`)

- [ ] **Step 4: Restart the session, run the test**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("IMPLICIT_SCOPE_MODULES", ti.name))
```

Expected: PASS.

- [ ] **Step 5: Run the StaticLint suites — this touches every analysis**

```
TestItemRunner.run_tests("./test"; filter=ti->any(f->endswith(ti.filename, f),
    ("staticlint/test_staticlint.jl", "staticlint/test_inference.jl", "test_typeinf.jl")))
```

Expected: no *failures*. Errors reading `UndefVarError: JuliaWorkspace` / `get_diagnostic` are a known harness artifact of `run_tests` (those testitems rely on `@run_package_tests`' default imports) and appear on untouched files — ignore them, but do not ignore a `Fail`.

- [ ] **Step 6: Commit**

```bash
git add src/StaticLint/StaticLint.jl test/staticlint/test_staticlint.jl
git commit -m "refactor(staticlint): name the modules the root scope seeds

The fact that Base and Core are reachable without an import is a property of the
root scope semantic_pass builds, so it is stated there once and read by anything
that has to answer for a name no written import accounts for."
```

---

## Task 2: the `_implicit_member` helper

**Files:**
- Modify: `src/layer_visibility.jl` (after `_resolve_external_module`, before `_tier`)
- Modify: `docs/superpowers/specs/2026-08-03-implicit-scope-member-resolution-design.md` (the order parenthetical)
- Test: `test/test_implicit_scope.jl` (create)

**Interfaces:**
- Consumes: `StaticLint.IMPLICIT_SCOPE_MODULES` (Task 1); `derived_module_is_bare(rt, root, path)` and `_resolve_external_module(rt, root, path)`, both already present.
- Produces:

  ```julia
  _implicit_member(rt, root, path::Vector{String}, name::String) ->
      Union{Nothing,Tuple{Any,Vector{String}}}
  ```

  `nothing` when neither implicit module provides `name`, or `path` is a `baremodule`. Otherwise `(value, provider_path)` where `provider_path` is `["Base"]` or `["Core"]` and `value` is either
  - a `SymbolServer` store value (`FunctionStore`, `DataTypeStore`, …) for a non-module name, or
  - `StaticLint.TreeRef(name, :external_module, nothing, provider_path)` for a module.

  It returns the provider alongside the value because Task 4 needs it for `VisibleName.origin_module` and cannot recover it from a bare store value. Returning it here is what keeps Task 4 from re-scanning `exportednames` to find out. Tasks 3 and 4 both call exactly this signature; Task 3 discards the provider.

- [ ] **Step 1: Write the failing test**

Create `test/test_implicit_scope.jl`:

```julia
@testsnippet ImplicitScopeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TextFile, SourceText, add_file!, derived_file_analysis,
        derived_julia_legacy_syntax_tree, derived_stdlib_only_env, _implicit_member
    using JuliaWorkspaces.URIs2: URI
    const SL = JuliaWorkspaces.StaticLint
    const CP = JuliaWorkspaces.CSTParser
    const SS = JuliaWorkspaces.SymbolServer

    # A workspace of julia files, keyed by URI. The first pair is the root.
    function ws_files(pairs...)
        jw = JuliaWorkspace()
        for (u, s) in pairs
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    # The ref of every occurrence of `name` in `file`, analysed under `root`.
    function refs_of(jw, root::URI, file::URI, name::String)
        fa = derived_file_analysis(jw.runtime, root, file)
        cst = derived_julia_legacy_syntax_tree(jw.runtime, file)
        out = Any[]
        JuliaWorkspaces._walk_exprs(cst) do x
            CP.is_id_or_macroname(x) && CP.str_value(x) == name || return
            push!(out, SL.hasref(x, fa.meta) ? SL.refof(x, fa.meta) : nothing)
        end
        return out
    end

    diagnostics_of(jw, root::URI, file::URI) =
        [d.message for d in derived_file_analysis(jw.runtime, root, file).diagnostics]
end

@testitem "implicit scope: _implicit_member answers for Base/Core exports only" setup=[ImplicitScopeWS] begin
    root = URI("file:///is/src/T.jl")
    jw = ws_files(root => """
    module T
    module Foo
    f(x) = x
    end
    baremodule Bare
    end
    end
    """)
    rt = jw.runtime
    foo = ["T", "Foo"]

    # A function Base exports: the store value itself, the same shape a bare
    # `println` resolves to, paired with the module that provided it.
    val, prov = _implicit_member(rt, root, foo, "println")
    @test val isa SS.FunctionStore
    @test prov == ["Base"]

    # A module Base exports: NOT the ModuleStore — per-file meta must stay plain
    # data — but the `:external_module` TreeRef stand-in, which is what lets the
    # getfield chain continue past it.
    tr, tprov = _implicit_member(rt, root, foo, "Threads")
    @test tr isa SL.TreeRef
    @test tr.kind === :external_module
    @test tr.name == "Threads"
    @test tr.origin_module == ["Base"]
    @test tr.item === nothing
    @test tprov == ["Base"]

    # A type: `Base.vals[:Int]` is the CONSTRUCTOR (a FunctionStore) while
    # `Core.vals[:Int]` is the DataTypeStore. Assert what consumers actually ask —
    # `get_eventual_datatype`, which follows `.extends` — rather than the store type
    # Base happens to hold, so this passes whichever module answers first.
    env = derived_stdlib_only_env(rt)
    intval, _ = _implicit_member(rt, root, foo, "Int")
    @test SL.get_eventual_datatype(intval, env) isa SS.DataTypeStore
    @test SL.resolves_to_datatype(intval, env)

    # `public`, not exported: `using Base` does not bring it in, so neither does this.
    @test _implicit_member(rt, root, foo, "Filesystem") === nothing

    # Not a name either module provides.
    @test _implicit_member(rt, root, foo, "definitely_not_a_base_name") === nothing

    # A baremodule has no implicit `using`, so it gets nothing at all.
    bare = ["T", "Bare"]
    @test _implicit_member(rt, root, bare, "println") === nothing
    @test _implicit_member(rt, root, bare, "Threads") === nothing
    @test _implicit_member(rt, root, bare, "Int") === nothing
end
```

- [ ] **Step 2: Run it and confirm it fails**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("_implicit_member answers", ti.name))
```

Expected: FAIL — `UndefVarError: _implicit_member`.

- [ ] **Step 3: Write the helper**

In `src/layer_visibility.jl`, directly after `_resolve_external_module` and before the `_tier` line:

```julia
"""
    _implicit_member(rt, root, path::Vector{String}, name::String)

The member `name` of the tree module at `path` that comes from its implicit
`using Base`/`using Core`, as `(value, provider_path)` — or `nothing` when neither
provides it. The provider comes back with the value because a consumer recording
`origin_module` cannot recover it from a bare store value, and re-deriving it would
mean scanning `exportednames` twice.

Only *exported* names count: `using` brings in exports, so a `public`-but-not-exported
name like `Base.Filesystem` is unreachable as `Foo.Filesystem` — mirroring
`SymbolServer.maybe_getfield`, which gates its `used_modules` walk the same way. A
`baremodule` has no implicit `using` and so has no such members at all.

Modules are tried in `StaticLint.IMPLICIT_SCOPE_MODULES` order, first match wins.
The order IS observable — `Base.vals[:Int]` is the constructor `FunctionStore` while
`Core.vals[:Int]` is the `DataTypeStore` — and `Base` first is what reproduces bare
resolution, which reaches the same `FunctionStore` through the root scope's `Base`
store. Consumers reach the datatype through `get_eventual_datatype`, which follows
`.extends`, either way.

A module-valued member is returned as its plain-data `TreeRef` stand-in, never as a
`ModuleStore`: per-file meta must stay Salsa-pure, and the `:external_module` TreeRef
is the shape `qualified_module_target` already resolves, so `Foo.Threads.nthreads()`
continues past `Threads` exactly as it does in single-file mode.
"""
function _implicit_member(rt, root, path::Vector{String}, name::String)
    derived_module_is_bare(rt, root, path) && return nothing
    sym = Symbol(name)
    for m in StaticLint.IMPLICIT_SCOPE_MODULES
        mpath = [String(m)]
        store = _resolve_external_module(rt, root, mpath)
        store === nothing && continue
        (sym in store.exportednames && haskey(store.vals, sym)) || continue
        val = StaticLint.maybe_lookup(store.vals[sym], _resolve_env(rt, root))
        val === nothing && continue
        val isa SymbolServer.ModuleStore &&
            return (StaticLint.TreeRef(name, :external_module, nothing, mpath), mpath)
        return (val, mpath)
    end
    return nothing
end
```

- [ ] **Step 4: Restart the session, run the test**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("_implicit_member answers", ti.name))
```

Expected: PASS, 15 assertions.

- [ ] **Step 5: Correct the spec's order parenthetical**

In `docs/superpowers/specs/2026-08-03-implicit-scope-member-resolution-design.md`, replace:

```
  `publicnames` is deliberately never read — that is what keeps `Foo.Filesystem`
  unresolved. (Order is not observable in practice: where `Base` and `Core` share
  a name they share the binding.)
```

with:

```
  `publicnames` is deliberately never read — that is what keeps `Foo.Filesystem`
  unresolved. The order IS observable, contrary to this document's first draft:
  `Base.vals[:Int]` is the constructor `FunctionStore` while `Core.vals[:Int]` is
  the `DataTypeStore`. `Base` first is correct because it reproduces bare-name
  resolution, which reaches that same `FunctionStore` through the root scope's
  `Base` store; consumers reach the datatype via `get_eventual_datatype` either way.
```

- [ ] **Step 6: Commit**

```bash
git add src/layer_visibility.jl test/test_implicit_scope.jl \
        docs/superpowers/specs/2026-08-03-implicit-scope-member-resolution-design.md
git commit -m "feat(visibility): _implicit_member, the implicit using Base/Core lookup

Exports only, mirroring maybe_getfield's used_modules gate, so a public-but-not-
exported name stays unreachable; nothing for a baremodule; and a module comes back
as its plain-data TreeRef stand-in so the getfield chain can continue past it.

Corrects the spec: the Base/Core order is observable (Base.vals[:Int] is the
constructor FunctionStore, Core.vals[:Int] the DataTypeStore). Base first is what
reproduces bare-name resolution."
```

---

## Task 3: call site 1 — qualified member access

**Files:**
- Modify: `src/layer_file_analysis.jl` — `StaticLint._get_field(par::TreeModuleContext, …)`, its `vn === nothing && return nothing` line
- Test: `test/test_implicit_scope.jl` (append)

**Interfaces:**
- Consumes: `_implicit_member(rt, root, path, name)` (Task 2).
- Produces: no new names. Behaviour: `Foo.println` and `Foo.Threads.nthreads()` resolve for a tree module `Foo`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_implicit_scope.jl`:

```julia
@testitem "implicit scope: cross-file member access matches single-file, cell for cell" setup=[ImplicitScopeWS] begin
    # The parity matrix. `Foo` is declared in a sibling file, so every lookup goes
    # through the module tree; single-file mode already resolves all of these, and
    # this asserts the tree path now agrees.
    root = URI("file:///is2/src/T.jl")
    a = URI("file:///is2/src/a.jl")
    b = URI("file:///is2/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => """
        g1() = Foo.f(1)
        g2() = Foo.println(2)
        g3() = Foo.Threads.nthreads()
        g4() = Foo.Filesystem
        """,
    )

    # The module's own member: unchanged.
    @test only(refs_of(jw, root, b, "f")) isa SL.TreeRef

    # A Base export reached as a member: the store value, as in single-file mode.
    @test only(refs_of(jw, root, b, "println")) isa SS.FunctionStore

    # A Base-exported MODULE, and the chain continuing past it — the second hop is
    # what proves the stand-in is resolvable and not just present.
    tr = only(refs_of(jw, root, b, "Threads"))
    @test tr isa SL.TreeRef
    @test tr.kind === :external_module
    @test tr.origin_module == ["Base"]
    @test only(refs_of(jw, root, b, "nthreads")) isa SS.FunctionStore

    # `public`, not exported: still unresolved, and this is the assertion that fails
    # if the implementation reads `publicnames` or the full `vals`.
    @test only(refs_of(jw, root, b, "Filesystem")) === nothing

    # Nothing new is flagged.
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a module's own declaration shadows the implicit scope" setup=[ImplicitScopeWS] begin
    # `Foo` declares its own `println`, so `Foo.println` must be Foo's, not Base's.
    # The fallback is consulted only after the tree lookup misses.
    root = URI("file:///is3/src/T.jl")
    a = URI("file:///is3/src/a.jl")
    b = URI("file:///is3/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nprintln(x) = x\nend\n",
        b => "g() = Foo.println(2)\n",
    )
    r = only(refs_of(jw, root, b, "println"))
    @test r isa SL.TreeRef
    @test r.kind !== :external_module
    @test r.item !== nothing && r.item.file == a
end

@testitem "implicit scope: a baremodule member stays unresolved" setup=[ImplicitScopeWS] begin
    root = URI("file:///is4/src/T.jl")
    a = URI("file:///is4/src/a.jl")
    b = URI("file:///is4/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "baremodule Bare\nf(x) = x\nend\n",
        b => "g1() = Bare.f(1)\ng2() = Bare.println(2)\ng3() = Bare.Threads\n",
    )
    # Its own member still resolves...
    @test only(refs_of(jw, root, b, "f")) isa SL.TreeRef
    # ...but it has no implicit `using`, so these do not.
    @test only(refs_of(jw, root, b, "println")) === nothing
    @test only(refs_of(jw, root, b, "Threads")) === nothing
end
```

- [ ] **Step 2: Run and confirm the new assertions fail**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("implicit scope:", ti.name))
```

Expected: the `_implicit_member` testitem PASSES; `cell for cell` FAILS on `println` (`nothing isa FunctionStore` is false). The shadow and baremodule testitems should already pass — they assert behaviour that must *not* change.

- [ ] **Step 3: Add the fallback**

In `src/layer_file_analysis.jl`, in `StaticLint._get_field(par::TreeModuleContext, arg, state, visited=Base.IdSet{Any}())`, replace:

```julia
    vn = get(visible, name, nothing)
    vn === nothing && return nothing
```

with:

```julia
    vn = get(visible, name, nothing)
    if vn === nothing
        # Not a name the tree module declares or imports — but every non-bare module
        # implicitly `using`s Base and Core, and those members are reachable as
        # `Foo.println` / `Foo.Threads`. Consulted only on the miss, so a real
        # declaration or import always wins. The provider path is for the import
        # side; a use site only needs the value.
        im = _implicit_member(par.rt, par.root, par.path, name)
        return im === nothing ? nothing : first(im)
    end
```

- [ ] **Step 4: Restart the session, run the tests**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("implicit scope:", ti.name))
```

Expected: PASS, all four testitems.

- [ ] **Step 5: Run every suite that consumes refs**

```
TestItemRunner.run_tests("./test"; filter=ti->any(f->endswith(ti.filename, f),
    ("test_file_analysis.jl", "test_hover.jl", "test_navigation.jl", "test_references.jl",
     "test_completions.jl", "test_signatures.jl", "test_module_tree.jl", "test_inventory.jl")))
```

Expected: no `Fail`. This change makes previously-unresolved names resolve, so a test that asserted "no ref" or "missing reference" for a Base name reached through a tree module would now legitimately fail — if one does, read it carefully: it is either a test that encoded the old limitation (update it, and say so in the commit) or a genuine over-reach of the fallback (fix the code).

- [ ] **Step 6: Commit**

```bash
git add src/layer_file_analysis.jl test/test_implicit_scope.jl
git commit -m "fix(analysis): a tree module's Base members resolve on qualified access

Foo.println and Foo.Threads.nthreads() carried no ref when Foo was declared in a
sibling file, so hover, go-to-definition and completion had nothing to work with,
while the same spellings resolved when Foo was in the same file. The tree recorded
a module's written usings but not the implicit ones."
```

---

## Task 4: call site 2 — colon-list import members

**Files:**
- Modify: `src/layer_visibility.jl` — `_member_lookup`, the `:tree` and `:workspace_package` branches
- Test: `test/test_implicit_scope.jl` (append)

**Interfaces:**
- Consumes: `_implicit_member(rt, root, path, name)` (Task 2).
- Produces: `_implicit_member_lookup(rt, root, tp, member_name)` -> the same 4-tuple `_member_lookup` returns. Behaviour: `using .Foo: println` binds `println` with kind `:external_symbol` and `origin_module == ["Base"]` instead of `:unknown`/`nothing`.

Note on the returned tuple: `_member_lookup` returns `(kind, item, origin_module, module_target)`, and the third slot becomes `VisibleName.origin_module`, which is what `StaticLint.resolve_treeref_store` later walks to find the name in the env. It must therefore be the **providing** module (`["Base"]`), not the tree module's path — matching the existing `:external` branch, which likewise returns the providing module's path.

- [ ] **Step 1: Write the failing test**

Append to `test/test_implicit_scope.jl`:

```julia
@testitem "implicit scope: a colon-list member can come from the implicit scope" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    root = URI("file:///is5/src/T.jl")
    a = URI("file:///is5/src/a.jl")
    b = URI("file:///is5/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => "module Consumer\nusing ..Foo: println, f\ng() = println(f(1))\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer"])

    # `f` is Foo's own declaration: unchanged.
    @test haskey(vis, "f")
    @test vis["f"].origin_module == ["T", "Foo"]

    # `println` came from Foo's implicit `using Base`, so it binds as an external
    # symbol whose origin module is the PROVIDER — that is the path
    # resolve_treeref_store walks to find it in the env.
    @test haskey(vis, "println")
    @test vis["println"].kind === :external_symbol
    @test vis["println"].origin_module == ["Base"]
    @test vis["println"].item === nothing

    # ...and both occurrences resolve — the name in the colon list and the call site
    # in `g` — rather than being reported as missing references.
    prefs = refs_of(jw, root, b, "println")
    @test length(prefs) == 2
    @test all(r -> r !== nothing, prefs)
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a colon-list member that is public-not-exported stays unknown" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    root = URI("file:///is6/src/T.jl")
    a = URI("file:///is6/src/a.jl")
    b = URI("file:///is6/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => "module Consumer\nusing ..Foo: Filesystem\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer"])

    # Julia binds the name lexically even when the import is wrong, so the entry
    # exists — but it must stay `:unknown`, NOT resolve to Base.Filesystem.
    @test haskey(vis, "Filesystem")
    @test vis["Filesystem"].kind === :unknown
end
```

- [ ] **Step 2: Run and confirm the first fails**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("colon-list member", ti.name))
```

Expected: the `public-not-exported` testitem PASSES already; the first FAILS on `vis["println"].kind === :external_symbol` (it is `:unknown` today).

- [ ] **Step 3: Add the fallback to both branches**

In `src/layer_visibility.jl`, in `_member_lookup`, replace the `:tree` branch's

```julia
        names = derived_module_names(rt, root, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
```

with

```julia
        names = derived_module_names(rt, root, tp)
        haskey(names, member_name) ||
            return _implicit_member_lookup(rt, root, tp, member_name)
```

and the `:workspace_package` branch's

```julia
        names = derived_module_names(rt, entry, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
```

with the same call against `entry` rather than `root` — a workspace package's names
resolve in the package's own env, so its implicit modules must be looked up there:

```julia
        names = derived_module_names(rt, entry, tp)
        haskey(names, member_name) ||
            return _implicit_member_lookup(rt, entry, tp, member_name)
```

Both branches need the identical `_member_lookup`-shaped answer, differing only in
which root resolves it, so write it once. Add this next to `_implicit_member` in
`src/layer_visibility.jl`:

```julia
# `_member_lookup`'s answer for a member that came from the implicit scope, or its
# `:unknown` answer when nothing did. `origin_module` is the PROVIDER, like the
# `:external` branch's, so `resolve_treeref_store` can find the name in the env; a
# module-valued member also gets an `:external` target so a chain can continue
# through it.
function _implicit_member_lookup(rt, root, tp::Vector{String}, member_name::String)
    im = _implicit_member(rt, root, tp, member_name)
    im === nothing && return (:unknown, nothing, tp, nothing)
    val, prov = im
    mt = val isa StaticLint.TreeRef ?
        ImportTarget(:external, vcat(prov, [member_name])) : nothing
    return (:external_symbol, nothing, prov, mt)
end
```

- [ ] **Step 4: Restart the session, run the tests**

```
TestItemRunner.run_tests("./test"; filter=ti->occursin("implicit scope:", ti.name))
```

Expected: PASS, all six testitems.

- [ ] **Step 5: Run the import-resolution suites**

```
TestItemRunner.run_tests("./test"; filter=ti->any(f->endswith(ti.filename, f),
    ("test_module_tree.jl", "test_file_analysis.jl", "test_scope_modules.jl",
     "test_completions.jl", "test_hover.jl", "test_references.jl", "test_inventory.jl",
     "test_navigation.jl", "test_signatures.jl", "test_diagnostics.jl")))
```

Expected: no `Fail`.

- [ ] **Step 6: Commit**

```bash
git add src/layer_visibility.jl test/test_implicit_scope.jl
git commit -m "fix(visibility): a colon-list member can come from the implicit scope

using .Foo: println bound the name as :unknown, with no kind and no way to reach
it, because the tree records a module's written usings but not the implicit
using Base. origin_module is the provider, matching the :external branch, so
resolve_treeref_store can find the name in the env."
```

---

## Deliberately not in this plan

- **Enumeration** (what `Foo.` offers in completions, workspace-symbol search) — non-goals in the spec: Julia's REPL lists `names(Foo)`, not Base's 1108 exports.
- **`_resolve_recorded_type`** — it exists only on `sp/type-aware-matching`; the spec makes it a rider commit there, carrying the `f(x::Iterators.Zip)` case.
- **The `_macro_owner_confirmed` baremodule fix** — `_macro_owner_confirmed` exists only on `sp/macro-declared-names`. Decided: that branch ships the bug; this branch's rebase fixes it, consuming `derived_module_is_bare`.
- **Precedence against macro-declared names** — both call sites here are misses that `sp/macro-declared-names` also extends. When these two branches meet, the module's own macro-declared names go first and the implicit scope second; whichever merges second lands them in that order and tests it.

## Known cost, accepted

`_implicit_member` does a linear `in` over `exportednames` (1108 for Base, then 120 for Core if Base misses — measured) on each miss. Returning the provider with the value is what keeps that to one scan rather than two. Misses are the uncommon branch in valid code, and this is microseconds on a request/analysis path — measure before replacing it with a cached `Set`, which would need a per-root derived node and a place to live.
