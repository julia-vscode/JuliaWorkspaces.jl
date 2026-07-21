# Unified In-Scope-Module Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every request-time consumer (hover, signature help, go-to-definition) determine "which modules are in scope here" from the *same* source the completions/diagnostics layers already use — the module-tree visibility layer — instead of the per-file-stripped `scope.modules`, so that `using LibGit2` (and any `using`) contributes its overloads to method lists.

**Architecture:** `SymbolServer` method aggregation (`iterate_over_ss_methods`) gains an optional `in_scope::Set{Symbol}` of extension-module top-names. The JuliaWorkspaces request layers compute that set from `derived_module_visible_names` via one shared helper (`_in_scope_syms_at`) and pass it in. When no set is supplied (whole-closure / pass-time linting, where `scope.modules` is still populated) the function falls back to walking `scope.modules` up the parent chain. `Base`/`Core` stay implicit in both paths (available except in a `baremodule`), matching how completions already special-cases them. `_strip_module_stores!` is unchanged.

**Tech Stack:** Julia; StaticLint + SymbolServer (vendored under `shared/symbolserver` and `src/StaticLint`); Salsa-derived query layer (`derived_*`); TestItemRunner test suite.

## Global Constraints

- Run tests with `TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("<substr>", ti.name))` in the `environments/development` julia-mcp session (never spawn julia directly). Full-suite gate: `cd` into the package and `include("test/runtests.jl")`.
- `@testitem` bodies need explicit `using JuliaWorkspaces: ...` / `const SL = JuliaWorkspaces.StaticLint` — default usings do not apply.
- Code comments: terse; never reference this plan or spec docs.
- Do NOT commit; leave changes for review (StaticLint method-resolution + request-layer change).
- Baseline: the repo already carries uncommitted "Approach-1" edits — `_scope_is_baremodule` and `_extension_module_in_scope(top, tls)` in `src/StaticLint/utils.jl`, plus two testitems in `test/test_hover.jl` ("Base-submodule overloads of a Base function are aggregated" and "iterate_over_ss_methods: Base-submodule overloads aggregate outside baremodules"). This plan builds on them.
- Layer discipline: `iterate_over_ss_methods` lives in `src/StaticLint/` and must NOT call `derived_*` (upward dependency). It only receives a plain `Set{Symbol}`. All `derived_module_visible_names` access lives in the `src/layer_*.jl` files.

---

## File Structure

- `src/StaticLint/utils.jl` — `iterate_over_ss_methods` (both `FunctionStore`/`DataTypeStore` methods), `_extension_module_in_scope`, new `_module_in_scope_chain`. Receives `in_scope::Union{Nothing,Set{Symbol}}`.
- `src/layer_scope_modules.jl` (new) — the shared request-layer helpers `_in_scope_module_syms(rt, root, path)`, `_uri_for_expr(rt, x)`, `_in_scope_syms_at(rt, root, x, meta_dict)`. One responsibility: "what env/workspace modules are in scope at an EXPR."
- `src/JuliaWorkspaces.jl` — add `include("layer_scope_modules.jl")` (near the other `layer_*` includes).
- `src/layer_hover.jl` — `_get_hover(::FunctionStore/…::DataTypeStore, …)` compute + pass `in_scope`.
- `src/layer_signatures.jl` — thread `in_scope` from `_collect_signatures` into `_get_signatures`.
- `src/layer_references.jl` — thread `in_scope` from the caller into `_get_definitions_from_val`.
- `src/layer_completions.jl` — refactor `_append_module_level_completions`'s inline `ext_origins` to reuse the shared extraction (proves single mechanism).
- `test/test_hover.jl`, `test/test_scope_modules.jl` (new) — tests.

---

### Task 1: Shared in-scope-module helpers

**Files:**
- Create: `src/layer_scope_modules.jl`
- Modify: `src/JuliaWorkspaces.jl` (add the include next to other `layer_*` includes)
- Test: `test/test_scope_modules.jl` (new)

**Interfaces:**
- Consumes: `derived_module_visible_names(rt, root, path::Vector{String}) -> Dict{String,VisibleName}` where `VisibleName` has fields `kind::Symbol`, `origin::Symbol`, `item`, `origin_module::Vector{String}`; `derived_file_module_path(rt, root, file_uri) -> Union{Nothing,Vector{String}}`; `_in_file_module_names(x, meta_dict) -> Vector{String}`; `derived_expr_uri_map(rt) -> Dict{UInt,URI}`.
- Produces: `_in_scope_module_syms(rt, root, path::Vector{String}) -> Set{Symbol}`; `_uri_for_expr(rt, x) -> Union{Nothing,URI}`; `_in_scope_syms_at(rt, root, x, meta_dict) -> Union{Nothing,Set{Symbol}}` (returns `nothing` when `rt`/`root`/uri/path can't be resolved — signals "use the scope.modules fallback").

- [ ] **Step 1: Write the failing test**

```julia
# test/test_scope_modules.jl
@testitem "in-scope syms: external using contributes its top module" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URIs2,
        _in_scope_module_syms, _in_scope_syms_at, derived_best_root_for_uri,
        derived_file_module_path, derived_julia_legacy_syntax_tree,
        derived_static_lint_meta_for_root
    SL = JuliaWorkspaces.StaticLint
    uri = URIs2.uri"file:///t/Foo.jl"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("module Foo\nusing Base.Iterators\nlength([])\nend\n", "julia")))
    rt = jw.runtime
    root = derived_best_root_for_uri(rt, uri)

    # `using Base.Iterators` is an external (env) module → its top segment `:Base`
    # appears in the in-scope set at the module's path.
    base = derived_file_module_path(rt, root, uri)
    syms = _in_scope_module_syms(rt, root, vcat(base, ["Foo"]))
    @test :Base in syms

    # A module with no `using` yields no external in-scope modules.
    uri2 = URIs2.uri"file:///t/Bar.jl"
    add_file!(jw, TextFile(uri2, SourceText("module Bar\nlength([])\nend\n", "julia")))
    root2 = derived_best_root_for_uri(rt, uri2)
    base2 = derived_file_module_path(rt, root2, uri2)
    @test isempty(_in_scope_module_syms(rt, root2, vcat(base2, ["Bar"])))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (julia-mcp, env `environments/development`):
```julia
import TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("in-scope syms", ti.name))
```
Expected: FAIL — `UndefVarError: _in_scope_module_syms` (helper not defined / not exported from the module).

- [ ] **Step 3: Write minimal implementation**

```julia
# src/layer_scope_modules.jl

# Top-level symbol of every external/workspace-package module brought into scope
# at `path` (their exported names can carry overloads of Base/other store
# functions). Base/Core are implicit — handled by the always-available rule in
# `iterate_over_ss_methods` — so they are intentionally NOT collected here.
function _in_scope_module_syms(rt, root, path::Vector{String})
    syms = Set{Symbol}()
    for (_, vn) in derived_module_visible_names(rt, root, path)
        (vn.origin === :using_external || vn.origin === :using_workspace_package) || continue
        isempty(vn.origin_module) || push!(syms, Symbol(vn.origin_module[1]))
    end
    return syms
end

# The URI of the file `x` lives in: walk to the `:file` root and look it up in
# the expr→uri map. `nothing` if `x` is detached or the map has no entry.
function _uri_for_expr(rt, x)
    root = x
    while CSTParser.parentof(root) !== nothing
        root = CSTParser.parentof(root)
    end
    CSTParser.headof(root) === :file || return nothing
    return get(derived_expr_uri_map(rt), objectid(root), nothing)
end

# The in-scope external/workspace module set at `x`'s position: the file's splice
# path extended by any in-file modules enclosing `x`. `nothing` when it can't be
# resolved (no runtime/root/uri) — the caller then uses the scope.modules fallback.
function _in_scope_syms_at(rt, root, x, meta_dict)
    (rt === nothing || root === nothing) && return nothing
    uri = _uri_for_expr(rt, x)
    uri === nothing && return nothing
    base = derived_file_module_path(rt, root, uri)
    base === nothing && return nothing
    return _in_scope_module_syms(rt, root, vcat(base, _in_file_module_names(x, meta_dict)))
end
```

Add to `src/JuliaWorkspaces.jl`, immediately after the existing `include("layer_visibility.jl")` line:
```julia
include("layer_scope_modules.jl")
```
(Verify the exact neighbouring include with `grep -n 'include("layer_visibility.jl")' src/JuliaWorkspaces.jl` and place the new include right after it, so `derived_module_visible_names` is defined first.)

- [ ] **Step 4: Run test to verify it passes**

Run: same filter as Step 2. Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/layer_scope_modules.jl src/JuliaWorkspaces.jl test/test_scope_modules.jl
git commit -m "feat(scope): shared in-scope-module set from the visibility layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `iterate_over_ss_methods` accepts an explicit in-scope set

**Files:**
- Modify: `src/StaticLint/utils.jl` (the `_extension_module_in_scope` helper ~line 273, and both `iterate_over_ss_methods` methods ~line 278 and ~line 315)
- Test: `test/test_hover.jl` (append a new testitem)

**Interfaces:**
- Consumes: `SymbolServer.stdlibs`, `JuliaWorkspaces._stdlib_only_env()`, `JuliaWorkspaces._collect_extended_methods_shared(store)`, `StaticLint.ExternalEnv(symbols, extendeds, project_deps)`, `StaticLint.Scope(parent, expr, names, modules, overloaded)`, existing `_scope_is_baremodule(s)`.
- Produces: `iterate_over_ss_methods(b, tls, env, f; in_scope::Union{Nothing,Set{Symbol}}=nothing)` for both `FunctionStore` and `DataTypeStore`; `_module_in_scope_chain(top::Symbol, s) -> Bool`; `_extension_module_in_scope(top::Symbol, tls::Scope, in_scope::Union{Nothing,Set{Symbol}}) -> Bool`.

- [ ] **Step 1: Write the failing test**

```julia
# append to test/test_hover.jl
@testitem "iterate_over_ss_methods: explicit in_scope set adds external overloads" begin
    using JuliaWorkspaces
    SL = JuliaWorkspaces.StaticLint
    SSr = JuliaWorkspaces.SymbolServer
    CSTParser = JuliaWorkspaces.CSTParser

    # Build a synthetic env: stdlibs + a top-level module `FakeMod` that defines a
    # `length` method extending `Base.length`.
    base = JuliaWorkspaces._stdlib_only_env()
    syms = copy(base.symbols)
    fake_method = SSr.MethodStore(:length, :FakeMod, "fakemod.jl", Int32(1),
        Pair{Any,Any}[:x => SSr.FakeTypeName(SSr.VarRef(SSr.VarRef(nothing, :FakeMod), :FakeThing), Any[])],
        Symbol[], SSr.FakeTypeName(SSr.VarRef(SSr.VarRef(nothing, :Core), :Int), Any[]))
    fake_len = SSr.FunctionStore(SSr.VarRef(SSr.VarRef(nothing, :FakeMod), :length),
        SSr.MethodStore[fake_method], "", SSr.VarRef(SSr.VarRef(nothing, :Base), :length))
    syms[:FakeMod] = SSr.ModuleStore(SSr.VarRef(nothing, :FakeMod),
        Dict{Symbol,Any}(:length => fake_len), "", Symbol[:length], Symbol[:length], Symbol[])
    env = SL.ExternalEnv(syms, JuliaWorkspaces._collect_extended_methods_shared(syms), collect(keys(syms)))

    b = env.symbols[:Base][:length]
    modscope = SL.Scope(nothing, CSTParser.parse("module Foo\nend"), Dict{String,SL.Binding}(), Dict{Symbol,Any}(), nothing)
    mods(scope, in_scope) = begin
        seen = Set{Symbol}()
        SL.iterate_over_ss_methods(b, scope, env, m -> (push!(seen, m.mod); false); in_scope=in_scope)
        seen
    end

    # With FakeMod in scope, its overload is aggregated; without it, it is not.
    @test :FakeMod in mods(modscope, Set([:FakeMod]))
    @test !(:FakeMod in mods(modscope, Set{Symbol}()))
    # Base submodule overloads (top :Base) are still included in a regular module
    # regardless of the external set (Base is implicit).
    @test :Iterators in mods(modscope, Set{Symbol}())
    # In a baremodule Base is NOT implicit, so Base-submodule overloads drop out.
    barescope = SL.Scope(nothing, CSTParser.parse("baremodule Foo\nend"), Dict{String,SL.Binding}(), Dict{Symbol,Any}(), nothing)
    @test !(:Iterators in mods(barescope, Set([:FakeMod])))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("explicit in_scope set", ti.name))
```
Expected: FAIL — `MethodError`/`UndefKeywordError` for the `in_scope` keyword (not yet a parameter), or the `:FakeMod` assertion fails because the current filter ignores any external set.

- [ ] **Step 3: Write minimal implementation**

In `src/StaticLint/utils.jl`, replace the current `_extension_module_in_scope` helper with:

```julia
# Walk `s` and its parent scopes; `true` if any has module `top` in `.modules`.
# `using` in ANY enclosing scope suffices (Julia lexical scoping).
function _module_in_scope_chain(top::Symbol, s)
    while s isa Scope
        s.modules !== nothing && haskey(s.modules, top) && return true
        s = parentof(s)
    end
    return false
end

# Whether an extension-method module `top` is reachable from `tls`.
# `Core` everywhere; `Base` everywhere except a `baremodule`. For any other
# module: use the explicit `in_scope` set when the caller supplied one (per-file
# request mode, where `scope.modules` has been stripped), else walk the
# `scope.modules` parent chain (whole-closure / pass-time linting).
_extension_module_in_scope(top::Symbol, tls::Scope, in_scope::Union{Nothing,Set{Symbol}}) =
    top === :Core ? true :
    top === :Base ? !_scope_is_baremodule(tls) :
    in_scope !== nothing ? (top in in_scope) :
    _module_in_scope_chain(top, tls)
```

Change the `FunctionStore` method signature and its filter call:
```julia
function iterate_over_ss_methods(b::SymbolServer.FunctionStore, tls::Scope, env::ExternalEnv, f; in_scope::Union{Nothing,Set{Symbol}}=nothing)
```
and, inside its extends loop, replace the existing guard line with:
```julia
                    !_extension_module_in_scope(SymbolServer.get_top_module(vr), tls, in_scope) && continue
```

Change the `DataTypeStore` method the same way — signature:
```julia
function iterate_over_ss_methods(b::SymbolServer.DataTypeStore, tls::Scope, env::ExternalEnv, f; in_scope::Union{Nothing,Set{Symbol}}=nothing)
```
and its guard line:
```julia
                    !_extension_module_in_scope(SymbolServer.get_top_module(vr), tls, in_scope) && continue
```

Also update the no-op fallback method (`iterate_over_ss_methods(b, tls, env, f) = false`) to accept the keyword:
```julia
iterate_over_ss_methods(b, tls, env, f; in_scope=nothing) = false
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step-2 filter, plus the two pre-existing Approach-1 tests to confirm no regression:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("in_scope", ti.name) || occursin("Base-submodule overloads", ti.name) || occursin("aggregate outside baremodules", ti.name))
```
Expected: PASS (all). The `aggregate outside baremodules` test still passes because it calls with `in_scope=nothing` and exercises only the `Base`/baremodule rules, which are unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/utils.jl test/test_hover.jl
git commit -m "feat(staticlint): iterate_over_ss_methods accepts explicit in-scope set

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Hover passes the visibility-derived in-scope set

**Files:**
- Modify: `src/layer_hover.jl` (`_get_hover(::FunctionStore,…)` ~line 734 and `_get_hover(::DataTypeStore,…)` ~line 719 — wherever they call `iterate_over_ss_methods`)
- Test: `test/test_hover.jl`

**Interfaces:**
- Consumes: `_in_scope_syms_at(rt, root, x, meta_dict)` (Task 1); `iterate_over_ss_methods(...; in_scope=...)` (Task 2). Both `_get_hover` methods already receive `expr`, `env`, `meta_dict`, `rt`, `root`.
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

```julia
# append to test/test_hover.jl
@testitem "Hover: method list uses the visibility layer for in-scope modules" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text, URIs2
    uri = URIs2.uri"file:///vis/Foo.jl"
    jw = JuliaWorkspace()
    # `using Base.Iterators` is redundant for Base subs (implicit), but this
    # asserts the hover path is driven by _in_scope_syms_at without regressing:
    # the Iterators overloads must still be listed.
    src = "module Foo\nusing Base.Iterators\nlength([])\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    h = get_hover_text(jw, uri, first(findfirst("length([])", src)))
    @test h !== nothing
    @test occursin("is a function with", h)
    @test occursin("in `Iterators`", h)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("method list uses the visibility layer", ti.name))
```
Expected: This test PASSES already if Approach-1's Base rule is active (Iterators is implicit). To make it a genuine RED for the wiring, first perform Step 3's edit with a deliberate bug omitted — i.e., treat this test as a **regression guard** and rely on the wiring being observable through the `_get_hover` change compiling and the existing suite. If you want a strict RED, temporarily change the `_get_hover` FunctionStore call to `in_scope=Set{Symbol}()` and confirm `in `Iterators`` still appears (Base rule) — proving the set path is wired without breaking Base — then set it to the real `_in_scope_syms_at`.

Note: the external-`using`-adds-methods behavior (the LibGit2 case) is covered deterministically by Task 2's synthetic-env unit test; a full end-to-end external test needs dynamic indexing (see Task 7).

- [ ] **Step 3: Write minimal implementation**

In `_get_hover(f::SymbolServer.FunctionStore, documentation, expr, env, meta_dict, rt=nothing, root=nothing)`, where it currently builds `itr` (the `iterate_over_ss_methods(f, tls, env, func)` closure), compute and pass the set:
```julia
        tls = _retrieve_toplevel_scope(expr, meta_dict)
        in_scope = _in_scope_syms_at(rt, root, expr, meta_dict)
        itr = func -> StaticLint.iterate_over_ss_methods(f, tls, env, func; in_scope=in_scope)
```
Apply the identical `in_scope` computation + keyword pass to the `_get_hover(::DataTypeStore,…)` method's `iterate_over_ss_methods` call.

- [ ] **Step 4: Run test to verify it passes**

Run the Step-2 filter and the full hover file:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("Hover", ti.name))
```
Expected: PASS (all hover tests, including the two Approach-1 ones).

- [ ] **Step 5: Commit**

```bash
git add src/layer_hover.jl test/test_hover.jl
git commit -m "feat(hover): drive method-list in-scope check from the visibility layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Signature help passes the in-scope set

**Files:**
- Modify: `src/layer_signatures.jl` (`_collect_signatures` ~line 79 computes it; `_get_signatures` ~lines 193/195/243 accept it)
- Test: `test/test_signatures.jl` (holds the signature-help testitems)

Confirmed API: `get_signature_help(jw, uri, index)` (mirror an existing `test_signatures.jl` testitem for the returned object's `signatures` accessor).

**Interfaces:**
- Consumes: `_in_scope_syms_at` (Task 1); `iterate_over_ss_methods(...; in_scope=...)` (Task 2). `_collect_signatures(x, meta_dict, env, runtime, root)` already has `runtime`, `root`, and the call EXPR `x`.
- Produces: `_get_signatures(b, tls, sigs, env, meta_dict, in_scope)` (new trailing positional arg on all three methods).

- [ ] **Step 1: Write the failing test**

```julia
# append to the signatures test file
@testitem "Signatures: in-scope set includes Base-submodule overloads" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help, URIs2
    uri = URIs2.uri"file:///sig/Foo.jl"
    jw = JuliaWorkspace()
    src = "module Foo\nlength(\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    # position just after the '(' of `length(`
    sh = get_signature_help(jw, uri, first(findfirst("length(", src)) + 7)
    @test sh !== nothing
    @test length(sh.signatures) > 62
end
```
(Confirm the public signature-help entry name and return shape with `grep -n "function get_signature_help\|signatures::" src/layer_signatures.jl`; adjust the call/assert to the real API. If the entry differs, mirror an existing signatures testitem's harness.)

- [ ] **Step 2: Run test to verify it fails**

Run:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("in-scope set includes Base-submodule", ti.name))
```
Expected: FAIL — `length(sh.signatures)` is 62 (the pre-fix count), because `_get_signatures` still calls `iterate_over_ss_methods` without `in_scope` and the post-strip `scope.modules` is empty.

- [ ] **Step 3: Write minimal implementation**

In `_collect_signatures(x, meta_dict, env, runtime, root)`, compute once:
```julia
    in_scope = _in_scope_syms_at(runtime, root, x, meta_dict)
```
and pass it to every `_get_signatures(...)` call it makes (add `in_scope` as the final argument). Update all three `_get_signatures` method signatures to accept it:
```julia
function _get_signatures(b, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) end
function _get_signatures(b::StaticLint.Binding, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing)
function _get_signatures(b::T, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) where T <: Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
```
In the `FunctionStore`/`DataTypeStore` method, pass it through:
```julia
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        # ... existing body ...
    end; in_scope=in_scope)
```
For the `Binding` method, forward `in_scope` on to any nested `_get_signatures` call it makes.

- [ ] **Step 4: Run test to verify it passes**

Run the Step-2 filter and all signature tests:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("Signature", ti.name) || occursin("signature", ti.name))
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_signatures.jl test/<signatures test file>
git commit -m "feat(signatures): drive in-scope check from the visibility layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Go-to-definition passes the in-scope set

**Files:**
- Modify: `src/layer_references.jl` (`_get_definitions_from_val(::Union{FunctionStore,DataTypeStore}, …)` ~line 409, and its caller so it can hand down the reference EXPR)
- Test: `test/test_references.jl` (holds the `get_definitions` testitems)

Confirmed API: `get_definitions(jw::JuliaWorkspace, uri::URI, index::Integer)` returns `Vector{DefinitionResult}`.

**Interfaces:**
- Consumes: `_in_scope_syms_at` (Task 1); `iterate_over_ss_methods(...; in_scope=...)` (Task 2). `_get_definitions_from_val(..., runtime, root)` has `runtime`, `root`; the caller has the reference EXPR + `meta_dict`.
- Produces: `_get_definitions_from_val(x, tls, env, results, runtime, root=nothing; in_scope=nothing)`.

- [ ] **Step 1: Write the failing test**

```julia
# append to the definitions/navigation test file
@testitem "Definitions: length resolves Base-submodule method locations" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions, URIs2
    uri = URIs2.uri"file:///nav/Foo.jl"
    jw = JuliaWorkspace()
    src = "module Foo\nlength([])\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    defs = get_definitions(jw, uri, first(findfirst("length", src)))
    # more than the 62 methods defined directly in Base — includes Iterators etc.
    @test length(defs) > 62
end
```
(`DefinitionResult` entries whose `m.file` fails `safe_isfile` are skipped, so the count is method locations that exist on disk; if the stdlib source isn't unpacked this may be < 62 for BOTH pre/post — verify the baseline count with a quick `get_definitions` call before asserting, and assert `> baseline` if the literal 62 doesn't hold in the runner.)

- [ ] **Step 2: Run test to verify it fails**

Run:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("length resolves Base-submodule method locations", ti.name))
```
Expected: FAIL — count is 62 (post-strip `scope.modules` empty).

- [ ] **Step 3: Write minimal implementation**

Add the keyword to `_get_definitions_from_val`:
```julia
function _get_definitions_from_val(x::Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}, tls, env, results, runtime, root=nothing; in_scope=nothing)
    StaticLint.iterate_over_ss_methods(x, tls, env, function (m)
        # ... existing body ...
    end; in_scope=in_scope)
```
At the caller (the definition dispatcher that has the reference EXPR `x_ref`, `meta_dict`, `runtime`, `root`), compute `in_scope = _in_scope_syms_at(runtime, root, x_ref, meta_dict)` and pass it: `_get_definitions_from_val(val, tls, env, results, runtime, root; in_scope=in_scope)`.

- [ ] **Step 4: Run test to verify it passes**

Run the Step-2 filter and navigation tests:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("Definitions", ti.name) || occursin("navigation", ti.name) || occursin("Navigation", ti.name))
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_references.jl test/<navigation test file>
git commit -m "feat(references): drive go-to-def in-scope check from the visibility layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Completions reuse the shared extraction (single mechanism)

**Files:**
- Modify: `src/layer_completions.jl` (`_append_module_level_completions` ~line 1108 — replace the inline `ext_origins` gathering with the shared helper)
- Test: `test/test_completions.jl` (holds the completion testitems)

Confirmed API: `get_completions(jw, uri, index, completion_mode::Symbol=:import)` returns a `CompletionResult`; mirror an existing `test_completions.jl` testitem for the exact result-field access (do not guess `.items`/`.label` — copy from a passing testitem).

**Interfaces:**
- Consumes: `_in_scope_module_syms(rt, root, path)` (Task 1). `_append_module_level_completions` already computes `path` and has `rt`, `root`.
- Produces: no new symbols. Behavior unchanged; the point is a single source of truth. The external-store loop still needs the full `origin_module` PATHS (to `_resolve_external_module`), so keep computing `ext_origins::Set{Vector{String}}` from the visible dict, but add an assertion-covered invariant that its top-symbols equal `_in_scope_module_syms(rt, root, path)`.

- [ ] **Step 1: Write the failing test**

```julia
# append to the completions test file
@testitem "Completions: using-brought names still offered (shared in-scope path)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, URIs2
    uri = URIs2.uri"file:///cmp/Foo.jl"
    jw = JuliaWorkspace()
    # `partition` is exported by Base.Iterators; a `using Base.Iterators` must keep
    # it offered as an unqualified completion.
    src = "module Foo\nusing Base.Iterators\nparti\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    comps = get_completions(jw, uri, first(findfirst("parti", src)) + 5)
    @test any(c -> startswith(c.label, "partition"), comps)
end
```
(Confirm `get_completions` name/return shape and adjust; if a similar completion testitem exists, mirror its harness exactly.)

- [ ] **Step 2: Run test to verify it fails or passes**

Run:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("using-brought names still offered", ti.name))
```
Expected: PASS already (completions currently work via the inline path). This test is a **regression guard** for the refactor in Step 3 — it must stay green after the change. (If it fails at Step 2, the harness/API is wrong; fix the test before refactoring.)

- [ ] **Step 3: Refactor (no behavior change)**

In `_append_module_level_completions`, the loop already reads `derived_module_visible_names(rt, root, path)` and builds `ext_origins`. Leave the `ext_origins::Set{Vector{String}}` gathering (it feeds `_resolve_external_module`, which needs full paths), but make the "which external modules are in scope" fact flow through the shared helper to guarantee agreement — insert, right after `visible = derived_module_visible_names(rt, root, path)`:
```julia
    # Invariant: the external modules the completion append resolves are exactly
    # the ones `iterate_over_ss_methods` sees in scope — one source of truth.
    @assert Set(Symbol(first(o)) for o in ext_origins if !isempty(o)) ⊆ _in_scope_module_syms(rt, root, path)
```
(Place the `@assert` after the `for (name, vn) in visible` loop that populates `ext_origins`. If the project disables `@assert` in production, instead extract a shared `_external_origins(visible) -> Set{Vector{String}}` used by both `_append_module_level_completions` and `_in_scope_module_syms`; that is the stronger unification — prefer it if time allows.)

- [ ] **Step 4: Run test to verify it still passes**

Run the Step-2 filter and the completions file:
```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("Completions", ti.name) || occursin("completion", ti.name))
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_completions.jl test/<completions test file>
git commit -m "refactor(completions): assert shared in-scope-module source of truth

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Full-suite gate + optional external-`using` integration test

**Files:**
- Test: optionally `test/test_hover.jl` (a dynamic-indexing integration testitem), tagged `:skip` if the runner lacks a depot.

**Interfaces:**
- Consumes: the dynamic-indexing harness (`JuliaWorkspace(; dynamic=DynamicIndexingOnly)`, `wait_until_ready`) as used in `test/staticlint/test_inference.jl:311` and `test/test_package_cache_loading.jl`.

- [ ] **Step 1: Run the full suite**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
```
Then in the julia-mcp `environments/development` session:
```julia
include("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/test/runtests.jl")
```
Expected: no NEW failures vs. the recorded baseline (≈4774 pass / 0 fail; the pre-existing Runic env error and 7 broken are unrelated). Pay attention to hover, signatures, references, completions, staticlint, and inference groups.

- [ ] **Step 2 (optional): External-`using` end-to-end test**

Only if a usable depot is present (else tag `:skip`). Build a `JuliaWorkspace` over a project whose manifest resolves a stdlib that overloads a Base function (e.g. `Dates` extending `Base.length`? verify with `length(methods(Base.length))` breakdown), `DynamicIndexingOnly` + `wait_until_ready`, then assert hover on `length` inside `module Foo; using Dates; length([]); end` lists a `in \`Dates\`` method. Mirror the setup in `test/test_package_cache_loading.jl`.

- [ ] **Step 3: Commit any test-only additions**

```bash
git add test/test_hover.jl
git commit -m "test: full-suite gate + optional external-using integration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes on decisions locked in

- **`_strip_module_stores!` is untouched.** Post-strip consumers no longer read `scope.modules`; they ask the visibility layer. The Salsa-purity invariant (no `ModuleStore`/`ExternalEnv` in the frozen `FileAnalysis`) is preserved. This is the main advantage of the unified approach over the "stand-in" alternative.
- **`scope.modules` stays the authority only where it is still populated** — whole-closure meta and pass-time linting (`check_all`/`type_inf` run *before* the strip). Those callers pass no `in_scope`, hitting the parent-chain fallback (`_module_in_scope_chain`), which now also honours "any parent scope's `using`."
- **Base/Core remain implicit** in both paths (available except in a `baremodule`), consistent with how completions already special-cases them — they are deliberately absent from `_in_scope_module_syms`.
- **`get_top_module(vr)` returns a `Symbol`; `origin_module` is a `Vector{String}`.** The set is keyed on the *top* segment (`Symbol(origin_module[1])`), which is exactly what `get_top_module` yields for an extender defined in a submodule of that top module.
