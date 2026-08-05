# Testitem Support in the Per-File Analysis Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore `@testitem`/`@testmodule`/`@testsnippet` support (package-module injection, setup injection, and lint diagnostics inside the macro bodies) in the per-file analysis pipeline (`derived_file_analysis`), which replaced the whole-closure pipeline that used to carry this wiring.

**Architecture:** All cross-file facts flow as plain data through Salsa-derived selectors (the module-tree machinery), never as foreign EXPRs/Bindings. Package injection reuses the existing cross-root `workspace_package_context` + `derived_module_exports`, gated by a new export-filtering context wrapper. Setups become a plain-data per-package index (name → kind + bound names); snippet names are injected as synthetic bindings, testmodule members resolve through a new plain-data `TestSetupModuleRef`. Missing-ref suppression is lifted for the bodies of the five known test macros.

**Tech Stack:** Julia, Salsa.jl (derived queries), CSTParser EXPRs, the StaticLint submodule, TestItemRunner-driven test suite.

## Global Constraints

- **Frozen-meta purity:** nothing reachable from a frozen `FileAnalysis.meta` may hold a Salsa runtime handle (`AbstractModuleContext`) or another file's EXPRs/Bindings. Contexts placed in `scope.modules` during a pass are legal but MUST be stripped before freezing (`strip_module_contexts!` / `_strip_module_stores!`).
- **Plain data in derived values:** new structs stored in derived values use `@auto_hash_equals` and deterministic ordering (sorted `Vector`s).
- **Salsa cutoff discipline:** the per-file analysis frame must not gain whole-tree dependencies; use per-name/per-file selectors so unrelated edits backdate.
- **Design decisions (agreed with Sebastian, 2026-08-05):** C2 name-list representation for BOTH `@testmodule` and `@testsnippet` (no module-tree nodes for setups); `@testset`/`@safetestset` bodies also get missing-ref diagnostics; the old whole-closure testitem machinery is deleted; `@testitem` bodies stay inventory-opaque (nothing inside is visible outside).
- **CSTParser macrocall layout:** `args[1]` = macro name, `args[2]` = a `NOTHING` line-info placeholder, real arguments start at `args[3]`.
- **Test runs:** `JW_TEST_FILTER="<name substring>" julia --project=. test/runtests.jl` runs testitems whose name contains the substring. The full suite is `julia --project=. test/runtests.jl` (slow; use filters per task, full suite in Task 8/9).
- **Unit-test envs have no symbol caches:** `env.symbols` only contains Base/Core/Main in tests, so `Test`/`@test` never resolve there. Tests must not assert on `@test` resolution; production `Test` injection already works because `derived_environment` copies all baked stdlib stores.
- **Commit style:** `fix(staticlint): …` / `feat(staticlint): …` / `test(staticlint): …` matching recent history; end commit messages with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

## File Structure

- `src/StaticLint/linting/checks.jl` — `in_macrocall_arg` transparency change (Task 1).
- `src/StaticLint/macros.jl` — `_handle_testitem` / `_handle_testmodule` / `_handle_testsnippet` fixes and injection rewrite (Tasks 2, 4, 7).
- `src/StaticLint/StaticLint.jl` — interface stubs, `ExportFilteredContext`, `strip_module_contexts!` widening, `TestSetupInfo`/`TestSetupModuleRef` redefinition, `Toplevel` field removal (Tasks 3, 7).
- `src/StaticLint/references.jl` — `resolve_getfield` arm for `TestSetupModuleRef` (Task 7).
- `src/layer_file_analysis.jl` — `context_exported_names`/`test_setup_info` implementations for `TreeModuleContext`, `self_package_name` wiring, `_mark_import_arg` using-materialization (Tasks 3, 4, 5, 7).
- `src/layer_test_setups.jl` — NEW: plain-data setup scan + derived queries (Task 6).
- `src/layer_static_lint.jl` — old testitem machinery deletion (Task 8).
- `test/staticlint/test_testitem_analysis.jl` — NEW: all tests for this plan.

## Shared Test Fixture (created in Task 1, used by every task)

All tests live in `test/staticlint/test_testitem_analysis.jl` and share this snippet (create it in Task 1, extend only if a task says so):

```julia
@testsnippet TestItemAnalysisWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    const SL = JuliaWorkspaces.StaticLint
    const CST = JuliaWorkspaces.CSTParser

    const PKG = URI("file:///pkg")
    const PROJ = URI("file:///pkg/Project.toml")
    const MANIF = URI("file:///pkg/Manifest.toml")
    const ENTRY = URI("file:///pkg/src/MyPkg.jl")
    const TESTF = URI("file:///pkg/test/mytests.jl")

    const PROJECT_TOML = """
    name = "MyPkg"
    uuid = "12345678-1234-1234-1234-123456789012"
    version = "0.1.0"
    """
    const MANIFEST_TOML = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "0"
    """

    # A minimal workspace shaped like a real package: Project+Manifest so the
    # test-file root gets a project, an entry file so MyPkg is a workspace
    # package, and one test file whose analysis we assert on.
    function pkg_ws(; entry::String, testfile::String, extra::Dict{URI,String}=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(PROJ, SourceText(PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(MANIF, SourceText(MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(ENTRY, SourceText(entry, "julia")))
        add_file!(jw, TextFile(TESTF, SourceText(testfile, "julia")))
        for (u, s) in extra
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    const DEFAULT_ENTRY = """
    module MyPkg
    export efn
    efn() = 1
    ifn() = 2
    end
    """

    # The test file is its own analysis root (it is not included by anything).
    testf_diags(jw) = JuliaWorkspaces.derived_file_analysis(jw.runtime, TESTF, TESTF).diagnostics
    diag_messages(jw) = [d.message for d in testf_diags(jw)]
end
```

Rationale for asserting on `derived_file_analysis(...).diagnostics` directly: `get_diagnostic` gates env-dependent messages behind `derived_file_env_ready`, which is not set in unit tests; the raw analysis diagnostics are deterministic.

---

### Task 1: Lint transparency for known test-macro bodies

Missing-ref diagnostics are currently blanket-suppressed for any identifier under a macrocall argument (`in_macrocall_arg`, `src/StaticLint/linting/checks.jl:1132-1148`). The bodies of the five test macros we fully analyze (`@testitem`, `@testmodule`, `@testsnippet`, `@testset`, `@safetestset`) must be linted like ordinary code. Their *other* args (name string, kwargs like `tags=[:a]`) stay suppressed, and an enclosing *unknown* macro still suppresses everything.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl:1122-1148` (`in_macrocall_arg`)
- Create: `test/staticlint/test_testitem_analysis.jl` (fixture snippet above + tests below)

**Interfaces:**
- Consumes: `_is_testitem_scope_macrocall` (`src/StaticLint/utils.jl:236`), `is_scope_introducing_macrocall` (`src/StaticLint/scope.jl`, matches `@testitem`/`@testset`/`@safetestset` incl. `Module.@testset` forms).
- Produces: changed suppression behavior only; no new symbols.

- [ ] **Step 1: Write the failing tests**

Append to `test/staticlint/test_testitem_analysis.jl` (after the fixture snippet):

```julia
@testitem "missing refs are reported inside @testitem bodies" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        undefined_name_abc
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: undefined_name_abc" in msgs
end

@testitem "missing refs are reported inside @testset bodies" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testset "s" begin
        undefined_in_testset
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: undefined_in_testset" in msgs
end

@testitem "testitem kwargs and name args stay unsuppressed-free" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" tags=[:a] default_imports=true begin
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: tags", msgs)
    @test !any(m -> m == "Missing reference: default_imports", msgs)
end

@testitem "unknown macros still suppress missing refs in their args" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @some_unknown_macro begin
        xyz_inside_unknown
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: xyz_inside_unknown", msgs)
end

@testitem "an enclosing unknown macro suppresses even a nested @testset body" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @some_unknown_macro begin
        @testset "inner" begin
            nested_undefined_name
        end
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: nested_undefined_name", msgs)
end
```

- [ ] **Step 2: Run tests to verify the first two fail**

Run: `JW_TEST_FILTER="missing refs are reported inside" julia --project=. test/runtests.jl`
Expected: FAIL — the suppressed diagnostics are absent. (The kwarg/unknown-macro tests pass already; they are regression guards.)

- [ ] **Step 3: Implement the transparency rule**

Replace the whole `in_macrocall_arg` function in `src/StaticLint/linting/checks.jl` (keep its docstring, extend it) with:

```julia
"""
    in_macrocall_arg(x::EXPR)

True if walking up from `x` we reach a macrocall (with `x` in its argument list,
not the macroname) without first crossing a scope-introducing expression
(function/let/struct/...).

If a user-written scope sits between the identifier and the macrocall, we assume
the macro respects normal Julia scoping.

The BODY block of a fully-analyzed test macro (`@testitem`/`@testmodule`/
`@testsnippet` get prebuilt scopes, `@testset`/`@safetestset` ordinary scopes)
is linted like ordinary code, so reaching one of those through its body block
does not suppress — the walk continues so an enclosing unknown macro still
suppresses the whole construct. Their non-body args (name, kwargs) stay
suppressed.
"""
function in_macrocall_arg(x::EXPR)
    cur = x
    while parentof(cur) isa EXPR
        p = parentof(cur)
        if CSTParser.ismacrocall(p)
            if length(p.args) > 0 && p.args[1] === cur
                return false
            end
            if (_is_testitem_scope_macrocall(p) || is_scope_introducing_macrocall(p)) &&
               cur isa EXPR && headof(cur) === :block
                cur = p
                continue
            end
            return true
        end
        h = headof(p)
        if h === :function || h === :macro || h === :for || h === :while ||
           h === :let || h === :generator || h === :try || h === :do ||
           h === :module || h === :abstract || h === :primitive || h === :struct
            return false
        end
        cur = p
    end
    return false
end
```

- [ ] **Step 4: Run the new tests, verify all five pass**

Run: `JW_TEST_FILTER="testitem" julia --project=. test/runtests.jl` — the five new tests pass. Then run the staticlint suite for collateral damage: `JW_TEST_FILTER="" julia --project=. test/runtests.jl 2>&1 | tail -30`. Some existing tests may newly see missing refs inside `@testset` fixtures — inspect each; fixtures that now correctly get flagged should be updated (define the name or expect the diagnostic), not the rule reverted.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/linting/checks.jl test/staticlint/test_testitem_analysis.jl
git commit -m "fix(staticlint): lint the bodies of known test macros like ordinary code"
```

---

### Task 2: Macro-name refs + `@testmodule`/`@testsnippet` placeholder off-by-one

`@testitem`/`@testmodule`/`@testsnippet` macro-name identifiers get no ref, so Task 1's world reports `Missing reference: @testitem`. Also `_handle_testmodule` reads the name from `args[2]` — the `NOTHING` placeholder — so it bails before creating its isolating scope (testmodule bodies leak bindings into the file scope).

**Files:**
- Modify: `src/StaticLint/macros.jl:420-571` (`_handle_testitem`, `_handle_testmodule`, `_handle_testsnippet`, `_parse_testitem_kwargs` comment)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `setref!`, `Binding`, `noname`, `valofid` (all StaticLint-internal, already imported in macros.jl).
- Produces: `_mark_test_macro_name!(x, meta_dict)` helper used again in Task 4/7 versions of the handlers.

- [ ] **Step 1: Write the failing tests**

```julia
@testitem "test macro names are not missing references" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
    end
    @testmodule TM begin
    end
    @testsnippet TS begin
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: @testitem" in msgs)
    @test !("Missing reference: @testmodule" in msgs)
    @test !("Missing reference: @testsnippet" in msgs)
end

@testitem "@testmodule bodies do not leak bindings into the file scope" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        leaked_name = 1
    end
    leaked_name
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: leaked_name" in msgs
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `JW_TEST_FILTER="test macro names are not" julia --project=. test/runtests.jl` → FAIL (`Missing reference: @testitem` present). `JW_TEST_FILTER="do not leak bindings" ...` → FAIL (leaked_name resolves via the file scope).

- [ ] **Step 3: Implement**

In `src/StaticLint/macros.jl`, add the helper right below the `_is_testsnippet_macro` definition (line ~336):

```julia
# The testitem-family macros are recognized syntactically (the defining
# package is usually not in the analysis environment), so their macro-name
# identifiers can never resolve through the env. Give them a benign ref so
# they are not reported as missing references.
function _mark_test_macro_name!(x::EXPR, meta_dict)
    x.args === nothing && return
    length(x.args) >= 1 || return
    hasref(x.args[1], meta_dict) || setref!(x.args[1], Binding(noname, nothing, nothing, EXPR[]), meta_dict)
    return
end
```

At the top of `_handle_testitem`, `_handle_testmodule`, and `_handle_testsnippet` (first statement after the `meta_dict = state.meta_dict` line, adding that line to `_handle_testsnippet` if absent), insert:

```julia
    _mark_test_macro_name!(x, meta_dict)
```

Fix `_handle_testmodule`'s arg indexing — replace its arg extraction block:

```julia
    # args layout: args[1]=@testmodule, args[2]=NOTHING line-info placeholder,
    # args[3]=Name, args[4:end] contain the begin...end block
    x.args === nothing && return
    length(x.args) < 4 && return
    name_expr = x.args[3]
    body = nothing
    for i in 4:length(x.args)
        if x.args[i] isa EXPR && headof(x.args[i]) === :block
            body = x.args[i]
            break
        end
    end
```

(The rest of `_handle_testmodule` — body/nothing check, `isidentifier` check, scope creation, Base/Core injection, binding registration — is unchanged.)

Also update the stale comment in `_parse_testitem_kwargs` from
`# args layout: args[1]=@testitem, args[2]=name_string, args[3..end]=kwargs and body` to
`# args layout: args[1]=@testitem, args[2]=NOTHING line-info placeholder, args[3]=name_string, args[4..end]=kwargs and body` (its loop from index 3 is already placeholder-safe — the placeholder and name string are neither kwargs nor blocks).

- [ ] **Step 4: Run tests to verify they pass**

Run: `JW_TEST_FILTER="testitem" julia --project=. test/runtests.jl` — all pass.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/macros.jl test/staticlint/test_testitem_analysis.jl
git commit -m "fix(staticlint): resolve test macro names and read @testmodule args past the line-info placeholder"
```

---

### Task 3: `ExportFilteredContext` + `context_exported_names` interface + handle-safe stripping

Package injection (Task 4) and testitem-local `using` (Task 5) need to bring EXPORTED names of a workspace package into a scope, resolved lazily through the module tree. This task builds the two mechanisms: a StaticLint-side context wrapper that gates resolution on an export set, and a JW-side interface method that reads a tree module's export list. It also widens `strip_module_contexts!` from key-based (`:__tree__` only) to value-based, because Tasks 4/5 will store contexts under package-name keys and no runtime handle may survive into frozen meta.

**Files:**
- Modify: `src/StaticLint/StaticLint.jl` (interface stub + `ExportFilteredContext` + `strip_module_contexts!` at line ~471)
- Modify: `src/StaticLint/imports.jl` (`_get_field` arm for the wrapper)
- Modify: `src/layer_file_analysis.jl` (`context_exported_names(::TreeModuleContext)`)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `derived_module_exports(rt, root, path) -> @NamedTuple{exports::Vector{String}, publics::Vector{String}}` (`src/layer_module_tree.jl:624`), `resolve_ref_from_module(x, ctx, state)` dispatch (`src/StaticLint/references.jl:144-157` iterates `scope.modules` values).
- Produces:
  - `StaticLint.context_exported_names(ctx) -> Union{Nothing,Vector{String}}` — new interface function; fallback returns `nothing`; `TreeModuleContext` method returns the tree module's export list.
  - `StaticLint.ExportFilteredContext(inner::AbstractModuleContext, names::Set{String}) <: AbstractModuleContext` — resolves a name iff it is in `names`, by delegating to `inner`.
  - `strip_module_contexts!` now removes EVERY `AbstractModuleContext` value from every scope's `.modules`, regardless of key.

- [ ] **Step 1: Write the failing tests**

```julia
@testitem "context_exported_names reads a workspace package's export list" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])
    @test SL.context_exported_names(ctx) == ["efn"]
end

@testitem "strip_module_contexts! removes contexts under any key" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])
    wrapped = SL.ExportFilteredContext(ctx, Set(["efn"]))

    fake = CST.parse("x = 1")
    md = Dict{UInt64,SL.Meta}()
    SL.setscope!(fake, SL.Scope(fake), md)
    sc = SL.scopeof(fake, md)
    sc.modules = Dict{Symbol,Any}(:__tree__ => ctx, :MyPkg => wrapped, :NotACtx => 1)

    SL.strip_module_contexts!(md)
    @test !haskey(sc.modules, :__tree__)
    @test !haskey(sc.modules, :MyPkg)
    @test haskey(sc.modules, :NotACtx)
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `JW_TEST_FILTER="context_exported_names" julia --project=. test/runtests.jl` → FAIL (`context_exported_names` undefined). Same for the strip test (`ExportFilteredContext` undefined).

- [ ] **Step 3: Implement**

In `src/StaticLint/StaticLint.jl`, near the `AbstractModuleContext` definition (find it with `grep -n "abstract type AbstractModuleContext" src/StaticLint/StaticLint.jl`), add:

```julia
"""
    context_exported_names(ctx) -> Union{Nothing,Vector{String}}

The names the module denoted by `ctx` exports, or `nothing` when unknown.
Interface for `AbstractModuleContext` implementations (the concrete method
for the tree-backed context lives in layer_file_analysis.jl).
"""
context_exported_names(@nospecialize(_)) = nothing

"""
    ExportFilteredContext(inner, names)

A module-context wrapper with `using` semantics: resolves a name through
`inner` only when the name is in `names` (the target's export list). Used to
inject a workspace package's exported names into a `@testitem` scope (or any
non-module-toplevel `using` site) without over-resolving internal names.
Holds `inner`'s runtime handle, so it must be stripped before meta is frozen
(`strip_module_contexts!` removes any `AbstractModuleContext` value).
"""
struct ExportFilteredContext{C<:AbstractModuleContext} <: AbstractModuleContext
    inner::C
    names::Set{String}
end
```

In `src/StaticLint/references.jl`, next to the existing `resolve_ref_from_module` methods (line ~159), add:

```julia
function resolve_ref_from_module(x1::EXPR, ctx::ExportFilteredContext, state::TraverseState)::Bool
    isidentifier(x1) || return false
    n = valofid(x1)
    n === nothing && return false
    n in ctx.names || return false
    return resolve_ref_from_module(x1, ctx.inner, state)
end
```

In `src/StaticLint/imports.jl`, next to the `_get_field(par, arg, state, visited)` generic (line ~199), add an arm ABOVE it (separate method):

```julia
function _get_field(par::ExportFilteredContext, arg, state, visited=Base.IdSet{Any}())
    name = CSTParser.str_value(arg)
    (name isa String && name in par.names) || return nothing
    return _get_field(par.inner, arg, state, visited)
end
```

In `src/StaticLint/StaticLint.jl:471`, replace `strip_module_contexts!`'s body (keep the docstring, update its text to say "Remove every `AbstractModuleContext` value from the scopes stored in `meta_dict`, under any key — the per-file pass seeds `:__tree__`, and testitem injection adds package-named entries."):

```julia
function strip_module_contexts!(meta_dict::Dict{UInt64,Meta})
    for m in values(meta_dict)
        s = m.scope
        s isa Scope || continue
        s.modules isa Dict || continue
        for (k, v) in collect(s.modules)
            v isa AbstractModuleContext && delete!(s.modules, k)
        end
    end
    return
end
```

In `src/layer_file_analysis.jl`, next to the other `StaticLint.` method implementations for `TreeModuleContext` (after `StaticLint.context_tree_ref` at line ~63), add:

```julia
StaticLint.context_exported_names(ctx::TreeModuleContext) =
    derived_module_exports(ctx.rt, ctx.root, ctx.path).exports
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `JW_TEST_FILTER="testitem" julia --project=. test/runtests.jl` — new tests pass, earlier tasks' tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/StaticLint.jl src/StaticLint/references.jl src/StaticLint/imports.jl src/layer_file_analysis.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): export-filtered module contexts and value-based context stripping"
```

---

### Task 4: Self-package injection in per-file mode

`derived_file_analysis` never passes `self_package_name`, so `_handle_testitem` cannot inject the package under test. Wire it through, and rewrite the injection block to go through the module tree (cross-root) instead of the old `state.workspace_packages` CST bindings.

**Files:**
- Modify: `src/layer_file_analysis.jl:745` (the `semantic_pass` call in `derived_file_analysis`)
- Modify: `src/StaticLint/macros.jl` (`_handle_testitem`'s injection block)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `semantic_pass(uri, cst, env, meta_dict, rt; …, self_package_name)` kwarg (exists, `src/StaticLint/StaticLint.jl:413`), `enclosing_tree_context(scope)` (`src/StaticLint/scope.jl:104`), `workspace_package_context(ctx, name)` (implemented for `TreeModuleContext` in `src/layer_file_analysis.jl:305`), `context_tree_ref(ctx)`, `context_exported_names(ctx)` + `ExportFilteredContext` (Task 3), `derived_package_for_file(rt, uri)`, `derived_package(rt, folder)` (`.name::String`).
- Produces: testitem scopes where (a) the package name resolves as a module (`MyPkg.anything` resolves through `qualified_module_target`), (b) the package's exported names resolve bare.

- [ ] **Step 1: Write the failing tests**

```julia
@testitem "default_imports injects the package under test into @testitem scopes" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        efn()
        ifn()
        MyPkg.ifn()
    end
    """)
    msgs = diag_messages(jw)
    # exported name resolves bare
    @test !("Missing reference: efn" in msgs)
    # the package name itself resolves
    @test !("Missing reference: MyPkg" in msgs)
    # the internal name is flagged exactly once: the bare use. The qualified
    # use resolves through the tree.
    @test count(==( "Missing reference: ifn"), msgs) == 1
end

@testitem "default_imports=false suppresses the package injection" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false begin
        efn()
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: efn" in msgs
end
```

- [ ] **Step 2: Run to verify the first fails**

Run: `JW_TEST_FILTER="default_imports injects" julia --project=. test/runtests.jl` → FAIL (`Missing reference: efn` present, `Missing reference: ifn` counted twice). The `default_imports=false` test should already pass (regression guard).

- [ ] **Step 3: Wire `self_package_name` into the per-file pass**

In `src/layer_file_analysis.jl`, in `derived_file_analysis`, directly above the `ctx = TreeModuleContext(rt, root, path)` line (~744), insert:

```julia
    # The enclosing package's name, for @testitem default-imports injection
    # (TestItemRunner evaluates each testitem body with `using Test` and
    # `using <PackageName>` in effect).
    self_package_name = nothing
    pkg_folder = derived_package_for_file(rt, file)
    if pkg_folder !== nothing
        pkg = derived_package(rt, pkg_folder)
        pkg !== nothing && (self_package_name = pkg.name)
    end
```

and change the `semantic_pass` call to:

```julia
    StaticLint.semantic_pass(file, cst, env, meta_dict, rt; module_context=ctx, self_package_name)
```

- [ ] **Step 4: Rewrite `_handle_testitem`'s package-injection block**

In `src/StaticLint/macros.jl`, replace the block starting `# Inject the parent package module (simulating using PackageName)` (the whole `if state.self_package_name !== nothing … end` inside the `if default_imports` branch, currently lines ~445-464) with:

```julia
        # Inject the parent package module (simulating `using PackageName`)
        if state.self_package_name !== nothing
            pkg_sym = Symbol(state.self_package_name)
            if haskey(symbols, pkg_sym)
                # Indexed (env-backed) package store
                item_scope.modules[pkg_sym] = symbols[pkg_sym]
                _add_module_public_names!(item_scope, symbols[pkg_sym], state)
            else
                # Workspace package: resolve through the module tree,
                # cross-root. The binding's val is the plain-data module
                # TreeRef (qualified `Pkg.x` goes through
                # `qualified_module_target`); bare exported names resolve via
                # an export-filtered context in scope.modules, which
                # `strip_module_contexts!` removes before meta is frozen.
                tctx = enclosing_tree_context(state.scope)
                if tctx !== nothing
                    wp = workspace_package_context(tctx, state.self_package_name)
                    if wp !== nothing
                        item_scope.names[state.self_package_name] =
                            Binding(noname, context_tree_ref(wp), CoreTypes.Module, EXPR[])
                        exps = context_exported_names(wp)
                        exps !== nothing &&
                            (item_scope.modules[pkg_sym] = ExportFilteredContext(wp, Set{String}(exps)))
                    end
                end
            end
        end
```

Note: `_handle_testitem` runs while `state.scope` is still the FILE scope (the item scope is not yet pushed), so `enclosing_tree_context(state.scope)` finds the `:__tree__` handle the per-file pass seeded there.

- [ ] **Step 5: Run tests to verify they pass**

Run: `JW_TEST_FILTER="default_imports" julia --project=. test/runtests.jl` — both pass. Also `JW_TEST_FILTER="testitem" ...` for the earlier tasks.

- [ ] **Step 6: Commit**

```bash
git add src/layer_file_analysis.jl src/StaticLint/macros.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): inject the package under test into @testitem scopes in per-file mode"
```

---

### Task 5: `using` inside test-macro bodies materializes its bring-ins

`StaticLint._mark_import_arg(arg, par::TreeModuleContext, …)` (`src/layer_file_analysis.jl:323`) skips `scope.modules` for `using` on the assumption that usings are module-toplevel and covered by the visible-names face. Inside a testitem body that is false (the inventory keeps these macrocalls opaque), so `using MyPkg` binds the name and brings in nothing.

**Files:**
- Modify: `src/layer_file_analysis.jl:323-338` (`StaticLint._mark_import_arg(::TreeModuleContext)`)
- Modify: `src/StaticLint/utils.jl` (add `is_module_toplevel_scope` helper)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `ExportFilteredContext`, `context_exported_names` (Task 3), `add_to_imported_modules(scope, name, val)` (`src/StaticLint/imports.jl:176`).
- Produces: `StaticLint.is_module_toplevel_scope(s::Scope) -> Bool`.

- [ ] **Step 1: Write the failing test**

```julia
@testitem "using the package inside a @testitem brings in its exports" setup=[TestItemAnalysisWS] begin
    # default_imports=false so this passes only if the explicit `using` works
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false begin
        using MyPkg
        efn()
        ifn()
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: efn" in msgs)
    @test "Missing reference: ifn" in msgs
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `JW_TEST_FILTER="using the package inside" julia --project=. test/runtests.jl` → FAIL (`Missing reference: efn` present).

- [ ] **Step 3: Implement**

In `src/StaticLint/utils.jl`, below `is_toplevel_scope` (line ~230), add:

```julia
# Is `s` the scope of a module's top level (a file's root scope or a
# `module`/`baremodule` scope)? Distinguishes places where a `using`'s
# bring-ins are part of the module's visible-names face from places where
# they are not (e.g. a `@testitem` body).
is_module_toplevel_scope(s::Scope) =
    s.expr isa EXPR && (headof(s.expr) === :file || CSTParser.defines_module(s.expr))
```

In `src/layer_file_analysis.jl`, in `StaticLint._mark_import_arg(arg, par::TreeModuleContext, state, usinged, meta_dict)`, replace the comment paragraph "No `scope.modules` entry is added for `using` …" (above the function) with an updated one, and change the function so the `usinged` case is handled. Full replacement function:

```julia
# Import-arg marking for a component that resolved to a module context:
# mirrors the whole-closure `_mark_import_arg`, minus everything that would
# leak the handle or another file's objects into meta. The binding's val is
# the context's plain-data `TreeRef` (leaf components that resolve directly
# to a TreeRef take the GENERIC `_mark_import_arg`, which stores them the
# same way — `Binding.val` admits `TreeRef`).
#
# For `using` at module toplevel no `scope.modules` entry is needed: the
# bring-ins are part of the module's `derived_module_visible_names` face and
# the seeded `:__tree__` context covers them. A `using` anywhere else (a
# `@testitem`/`@testset` body — those macrocalls are opaque to the
# inventory) has no face to lean on, so its exported names are materialized
# as an export-filtered context on the current scope; the wrapper holds a
# runtime handle and is removed by `strip_module_contexts!` before freezing.
function StaticLint._mark_import_arg(arg, par::TreeModuleContext, state, usinged, meta_dict)
    CSTParser.is_id_or_macroname(arg) || return
    if StaticLint.bindingof(arg, meta_dict) === nothing
        StaticLint.ensuremeta(arg, meta_dict)
        StaticLint.getmeta(arg, meta_dict).binding = StaticLint.Binding(arg, _context_tree_ref(par), StaticLint.CoreTypes.Module, [])
        StaticLint.setref!(arg, StaticLint.bindingof(arg, meta_dict), meta_dict)
    end
    if usinged
        if !StaticLint.is_module_toplevel_scope(state.scope)
            exps = StaticLint.context_exported_names(par)
            if exps !== nothing
                nm = StaticLint.valofid(arg)
                nm !== nothing && StaticLint.add_to_imported_modules(
                    state.scope, Symbol(nm), StaticLint.ExportFilteredContext(par, Set{String}(exps)))
            end
        end
    else
        # import binds the name in the current scope — except under `as`,
        # where only the alias is bound (matching `_mark_import_arg`)
        if !(CSTParser.parentof(arg) isa CSTParser.EXPR && CSTParser.parentof(CSTParser.parentof(arg)) isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(CSTParser.parentof(arg))) === :as)
            state.scope.names[StaticLint.valofid(arg)] = StaticLint.bindingof(arg, meta_dict)
        end
    end
    return
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `JW_TEST_FILTER="using the package inside" julia --project=. test/runtests.jl` → PASS. Then `JW_TEST_FILTER="testitem" ...` and the file-analysis suite: `JW_TEST_FILTER="file analysis" ...` (the `_mark_import_arg` change touches every per-file import).

- [ ] **Step 5: Commit**

```bash
git add src/layer_file_analysis.jl src/StaticLint/utils.jl test/staticlint/test_testitem_analysis.jl
git commit -m "fix(staticlint): materialize using bring-ins for non-module-toplevel scopes in per-file mode"
```

---

### Task 6: Plain-data test-setup index

A per-package, plain-data index of `@testmodule`/`@testsnippet` declarations: name → kind, declaring file, and the names the setup binds at its top level. Per-file sub-query so an edit in one file backdates everything else.

**Files:**
- Create: `src/layer_test_setups.jl`
- Modify: `src/packagedef.jl` (add `include("layer_test_setups.jl")` directly after the `include("layer_static_lint.jl")` line — find it with `grep -n "layer_static_lint" src/packagedef.jl`)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `derived_all_julia_files(rt)`, `derived_julia_legacy_syntax_tree(rt, uri)`, `uri2filepath`, `@auto_hash_equals`.
- Produces:
  - `TestSetupData` — `@auto_hash_equals struct` with `name::Symbol`, `kind::Symbol` (`:module`/`:snippet`), `file::URI`, `bound_names::Vector{String}` (sorted, unique).
  - `derived_test_setups_in_file(rt, uri) -> Vector{TestSetupData}`
  - `derived_test_setups(rt, package_folder_uri) -> Dict{Symbol,TestSetupData}`
  - `derived_test_setup(rt, package_folder_uri, name::Symbol) -> Union{Nothing,TestSetupData}` (per-name cutoff face)

- [ ] **Step 1: Write the failing tests**

```julia
@testitem "derived_test_setups indexes testmodules and testsnippets as plain data" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        tmf() = 1
        const TC = 2
        struct TS_t end
    end
    @testsnippet TS begin
        sx = 1
        sy, sz = 2, 3
    end
    """)
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test Set(keys(setups)) == Set([:TM, :TS])
    @test setups[:TM].kind == :module
    @test setups[:TM].file == TESTF
    @test setups[:TM].bound_names == ["TC", "TS_t", "tmf"]
    @test setups[:TS].kind == :snippet
    @test setups[:TS].bound_names == ["sx", "sy", "sz"]
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :TM) == setups[:TM]
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :Nope) === nothing
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `JW_TEST_FILTER="derived_test_setups indexes" julia --project=. test/runtests.jl` → FAIL (`derived_test_setups` undefined).

- [ ] **Step 3: Implement `src/layer_test_setups.jl`**

```julia
# Plain-data index of @testmodule/@testsnippet declarations, per package.
# The per-file analysis injects setups into @testitem scopes from this index
# (via StaticLint.test_setup_info) — never from another file's EXPRs, which
# must not survive into a frozen FileAnalysis.

"""
    TestSetupData

One `@testmodule` or `@testsnippet` declaration, as plain data: `kind` is
`:module`/`:snippet`, `file` the declaring file, `bound_names` the sorted,
unique names the setup's top level binds (declarations and assignments; names
introduced by macros or `using` inside the setup are not enumerable here, so
member misses must stay un-flagged downstream).
"""
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol
    file::URI
    bound_names::Vector{String}
end

# The name an EXPR binds at a setup's top level, or `nothing`.
function _setup_bound_name(a)
    a isa CSTParser.EXPR || return nothing
    if CSTParser.defines_function(a) || CSTParser.defines_struct(a) ||
       CSTParser.defines_abstract(a) || CSTParser.defines_primitive(a) ||
       CSTParser.defines_macro(a) || CSTParser.defines_module(a)
        nm = CSTParser.get_name(a)
        return nm isa CSTParser.EXPR && CSTParser.isidentifier(nm) ? StaticLint.valofid(nm) : nothing
    elseif CSTParser.isassignment(a)
        return nothing # handled by _setup_collect_names! (tuple lhs binds several)
    elseif (CSTParser.headof(a) === :const || CSTParser.headof(a) === :global) &&
           a.args !== nothing && length(a.args) >= 1
        return _setup_bound_name(a.args[1])
    end
    return nothing
end

# Collect the names an assignment lhs binds (identifier, x::T, tuple).
function _setup_lhs_names!(names, l)
    l isa CSTParser.EXPR || return
    if CSTParser.isidentifier(l)
        n = StaticLint.valofid(l)
        n !== nothing && push!(names, n)
    elseif CSTParser.isdeclaration(l) && l.args !== nothing && length(l.args) >= 1
        _setup_lhs_names!(names, l.args[1])
    elseif (CSTParser.istuple(l) || CSTParser.isbracketed(l)) && l.args !== nothing
        for el in l.args
            _setup_lhs_names!(names, el)
        end
    end
    return
end

function _setup_collect_names!(names, a)
    a isa CSTParser.EXPR || return
    if CSTParser.isassignment(a) && a.args !== nothing && length(a.args) >= 1
        _setup_lhs_names!(names, a.args[1])
    elseif (CSTParser.headof(a) === :const || CSTParser.headof(a) === :global) &&
           a.args !== nothing && length(a.args) >= 1
        _setup_collect_names!(names, a.args[1])
    else
        n = _setup_bound_name(a)
        n !== nothing && push!(names, n)
    end
    return
end

function _setup_toplevel_bound_names(body::CSTParser.EXPR)
    names = String[]
    body.args === nothing && return names
    for a in body.args
        _setup_collect_names!(names, a)
    end
    return sort!(unique!(names))
end

"""
    derived_test_setups_in_file(rt, uri) -> Vector{TestSetupData}

The `@testmodule`/`@testsnippet` declarations at `uri`'s top level. Per-file
so a keystroke in one file backdates every other file's contribution.
"""
Salsa.@derived function derived_test_setups_in_file(rt, uri)
    @debug "derived_test_setups_in_file" uri=uri

    result = TestSetupData[]
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst.args === nothing && return result
    for arg in cst.args
        (CSTParser.ismacrocall(arg) && arg.args !== nothing && length(arg.args) >= 4) || continue
        mname = arg.args[1]
        CSTParser.isidentifier(mname) || continue
        n = CSTParser.valof(mname)
        kind = n == "@testmodule" ? :module : n == "@testsnippet" ? :snippet : nothing
        kind === nothing && continue
        # args[2] is CSTParser's NOTHING line-info placeholder; the name is args[3]
        name_expr = arg.args[3]
        CSTParser.isidentifier(name_expr) || continue
        setup_name = CSTParser.str_value(name_expr)
        setup_name isa AbstractString || continue
        body = nothing
        for i in 4:length(arg.args)
            if arg.args[i] isa CSTParser.EXPR && CSTParser.headof(arg.args[i]) === :block
                body = arg.args[i]
                break
            end
        end
        body === nothing && continue
        push!(result, TestSetupData(Symbol(setup_name), kind, uri, _setup_toplevel_bound_names(body)))
    end
    return result
end

"""
    derived_test_setups(rt, package_folder_uri) -> Dict{Symbol,TestSetupData}

All test setups declared in files under `package_folder_uri`. On duplicate
names the lexicographically smallest file URI wins (deterministic; the
runner rejects duplicates anyway).
"""
Salsa.@derived function derived_test_setups(rt, package_folder_uri)
    @debug "derived_test_setups" package_folder_uri=package_folder_uri

    result = Dict{Symbol,TestSetupData}()
    package_folder_path = lowercase(uri2filepath(package_folder_uri))
    files = sort(collect(derived_all_julia_files(rt)); by=string)
    for uri in files
        uri.scheme == "file" || continue
        startswith(lowercase(uri2filepath(uri)), package_folder_path) || continue
        for s in derived_test_setups_in_file(rt, uri)
            haskey(result, s.name) || (result[s.name] = s)
        end
    end
    return result
end

"""
    derived_test_setup(rt, package_folder_uri, name) -> Union{Nothing,TestSetupData}

Per-name face over `derived_test_setups`: consumers depend on ONE setup's
value, so an edit that changes a different setup backdates them.
"""
Salsa.@derived function derived_test_setup(rt, package_folder_uri, name::Symbol)
    return get(derived_test_setups(rt, package_folder_uri), name, nothing)
end
```

Add the include to `src/packagedef.jl` right after the `include("layer_static_lint.jl")` line:

```julia
include("layer_test_setups.jl")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `JW_TEST_FILTER="derived_test_setups indexes" julia --project=. test/runtests.jl` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_test_setups.jl src/packagedef.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat: plain-data per-package index of @testmodule/@testsnippet declarations"
```

---

### Task 7: Setup injection into `@testitem` scopes

Replace the EXPR-carrying `TestSetupInfo` flow with the plain-data index: `_handle_testitem` asks the tree context for each `setup=[…]` name; testmodules become a name binding whose members resolve through a new plain-data `TestSetupModuleRef`; snippet names become synthetic bindings. Removes `Toplevel.test_setups` and the `test_setups` kwarg of `semantic_pass`.

**Files:**
- Modify: `src/StaticLint/StaticLint.jl` (`TestSetupInfo` redefinition at line ~209-230, `TestSetupModuleRef`, `Toplevel` struct at ~240-266, convenience constructor, `semantic_pass` at ~413-417, `test_setup_info` interface stub)
- Modify: `src/StaticLint/macros.jl` (`_handle_testitem` setup loop)
- Modify: `src/StaticLint/references.jl` (`resolve_getfield` arms)
- Modify: `src/StaticLint/linting/checks.jl` (`should_mark_missing_getfield_ref` guard)
- Modify: `src/layer_file_analysis.jl` (`StaticLint.test_setup_info(::TreeModuleContext, ::Symbol)`)
- Modify: `src/layer_static_lint.jl:152` (drop the `test_setups`/`self_package_name` kwargs from the old pipeline's `semantic_pass` call; the dict it built is deleted in Task 8)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `derived_test_setup(rt, pkg_folder, name)` and `TestSetupData` (Task 6), `derived_package_for_file(rt, uri)`, `enclosing_tree_context`.
- Produces:
  - `StaticLint.TestSetupInfo` — REDEFINED as `struct TestSetupInfo; kind::Symbol; names::Set{String}; end` (plain data).
  - `StaticLint.TestSetupModuleRef` — `struct TestSetupModuleRef; name::String; members::Set{String}; end` (plain data, lives in frozen meta as a `Binding.val`).
  - `StaticLint.test_setup_info(ctx, name::Symbol) -> Union{Nothing,TestSetupInfo}` — interface; fallback `nothing`; `TreeModuleContext` method backed by `derived_test_setup`.
  - `semantic_pass` WITHOUT the `test_setups` kwarg; `Toplevel` WITHOUT the `test_setups` field.

- [ ] **Step 1: Write the failing tests**

```julia
@testitem "setup testmodules and testsnippets inject into @testitem scopes cross-file" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM, TS] begin
            TM.tmf()
            TM.not_a_member()
            sx
            totally_undefined
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            tmf() = 1
        end
        @testsnippet TS begin
            sx = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: TM" in msgs)
    @test !("Missing reference: tmf" in msgs)
    # member sets are not enumerable in general (macros, usings inside the
    # setup) — unknown members must NOT be flagged
    @test !("Missing reference: not_a_member" in msgs)
    @test !("Missing reference: sx" in msgs)
    # ordinary missing refs in the same body still fire
    @test "Missing reference: totally_undefined" in msgs
end

@testitem "unknown setup names inject nothing" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false setup=[NoSuchSetup] begin
        whatever_name
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: whatever_name" in msgs
end
```

- [ ] **Step 2: Run to verify the first fails**

Run: `JW_TEST_FILTER="setup testmodules and testsnippets" julia --project=. test/runtests.jl` → FAIL (`Missing reference: TM`, `tmf`, `sx` all present).

- [ ] **Step 3: Redefine the StaticLint data types and interface**

In `src/StaticLint/StaticLint.jl`, replace the `TestSetupInfo` struct AND its docstring (lines ~209-230) with:

```julia
"""
    TestSetupInfo

Plain-data description of a `@testmodule` or `@testsnippet` a `@testitem`
references via `setup=[...]`: `kind` is `:module`/`:snippet`, `names` the
names the setup binds at its top level. Produced by the
`test_setup_info(ctx, name)` interface (backed by a Salsa query outside
StaticLint); safe to reach from frozen meta.
"""
struct TestSetupInfo
    kind::Symbol
    names::Set{String}
end

"""
    TestSetupModuleRef

The `Binding.val` for a `@testmodule` name injected into a `@testitem` scope:
qualified members (`Foo.x`) resolve against `members`. Plain data — member
misses are NOT flagged (the set is not enumerable in general; see
`should_mark_missing_getfield_ref`).
"""
struct TestSetupModuleRef
    name::String
    members::Set{String}
end

"""
    test_setup_info(ctx, name::Symbol) -> Union{Nothing,TestSetupInfo}

The test setup registered under `name` for the package the analyzed file
belongs to, or `nothing`. Interface for `AbstractModuleContext`
implementations (concrete method in layer_file_analysis.jl).
"""
test_setup_info(@nospecialize(_), ::Symbol) = nothing
```

Remove the `test_setups::Dict{Symbol,TestSetupInfo}` field from `Toplevel` (line ~251) and drop the corresponding argument from BOTH the convenience constructor (line ~266) and the `Toplevel(...)` call inside `semantic_pass` (line ~417). Change `semantic_pass`'s signature (line ~413) from

```julia
function semantic_pass(uri, cst, env, meta_dict, rt, modified_expr = nothing; workspace_packages = Dict{String,Any}(), test_setups = Dict{Symbol,TestSetupInfo}(), self_package_name::Union{Nothing,String} = nothing, module_context::Union{Nothing,AbstractModuleContext} = nothing)
```

to

```julia
function semantic_pass(uri, cst, env, meta_dict, rt, modified_expr = nothing; workspace_packages = Dict{String,Any}(), self_package_name::Union{Nothing,String} = nothing, module_context::Union{Nothing,AbstractModuleContext} = nothing)
```

Then in `src/layer_static_lint.jl:152` drop the removed kwargs from the old pipeline's call:

```julia
    StaticLint.semantic_pass(uri, cst, env, meta_dict, rt; workspace_packages)
```

(The `test_setups`/`self_package_name` values it built are dead from here on; Task 8 deletes their computation.)

Check for further construction sites: `grep -rn "test_setups" src/ | grep -v layer_test_setups` must show only the sites edited in this task; fix any stragglers the same way.

- [ ] **Step 4: Rewrite `_handle_testitem`'s setup loop**

In `src/StaticLint/macros.jl`, replace the block from `# Resolve setup=[...] references from pre-computed test_setups registry.` down to (and including) `state.scope = s0` with:

```julia
    # Resolve setup=[...] references through the plain-data setup index
    # (test_setup_info interface). Testmodules bind their name — members
    # resolve via TestSetupModuleRef; snippet names are injected directly
    # (TestItemRunner splices snippet code into the testitem body).
    tctx = enclosing_tree_context(state.scope)
    if tctx !== nothing
        for setup_name in setup_names
            info = test_setup_info(tctx, setup_name)
            info === nothing && continue
            if info.kind === :module
                item_scope.names[String(setup_name)] =
                    Binding(noname, TestSetupModuleRef(String(setup_name), info.names), CoreTypes.Module, EXPR[])
            elseif info.kind === :snippet
                for n in info.names
                    haskey(item_scope.names, n) ||
                        (item_scope.names[n] = Binding(noname, nothing, nothing, EXPR[]))
                end
            end
        end
    end
```

(The `s0 = state.scope` juggling and `process_EXPR(expr, state)` of foreign snippet EXPRs disappear — that was the stale-EXPR channel.)

- [ ] **Step 5: getfield resolution and the miss guard**

In `src/StaticLint/references.jl`, inside `resolve_getfield(x::EXPR, b::Binding, state)` (line ~341), add a branch after the `b.val isa TreeRef` branch:

```julia
    elseif b.val isa TestSetupModuleRef
        resolved = resolve_getfield(x, b.val, state)
```

and add the arm next to the `TreeRef` arm (line ~386):

```julia
function resolve_getfield(x::EXPR, tm::TestSetupModuleRef, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    CSTParser.is_id_or_macroname(x) || return false
    n = valofid(x)
    if n !== nothing && n in tm.members
        setref!(x, TreeRef(n, :test_setup_member, nothing, [tm.name]), meta_dict)
        return true
    end
    return false
end
```

In `src/StaticLint/linting/checks.jl`, in `should_mark_missing_getfield_ref` (line ~1269), inside the `lhsref isa Binding` branch, add as its FIRST check (before the `lhsref.val isa Binding` unwrap):

```julia
        if lhsref.val isa TestSetupModuleRef
            # @testmodule member sets are not enumerable in general
            # (macro-generated names, usings inside the setup) — never flag.
            return false
        end
```

- [ ] **Step 6: Implement the interface for `TreeModuleContext`**

In `src/layer_file_analysis.jl`, next to `StaticLint.context_exported_names` (Task 3), add:

```julia
# ctx.root is the analyzed file's root; for test files the root IS the file,
# and for src files it is the package entry — both live under the package
# folder, which keys the setup index.
function StaticLint.test_setup_info(ctx::TreeModuleContext, name::Symbol)
    pkg_folder = derived_package_for_file(ctx.rt, ctx.root)
    pkg_folder === nothing && return nothing
    s = derived_test_setup(ctx.rt, pkg_folder, name)
    s === nothing && return nothing
    return StaticLint.TestSetupInfo(s.kind, Set{String}(s.bound_names))
end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `JW_TEST_FILTER="setup testmodules" julia --project=. test/runtests.jl` and `JW_TEST_FILTER="unknown setup names" ...` → PASS. Then the whole testitem file and the staticlint suite (the `semantic_pass` signature change touches everything): `julia --project=. test/runtests.jl 2>&1 | tail -30`.

- [ ] **Step 8: Commit**

```bash
git add src/StaticLint/StaticLint.jl src/StaticLint/macros.jl src/StaticLint/references.jl src/StaticLint/linting/checks.jl src/layer_file_analysis.jl src/layer_static_lint.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): inject test setups into @testitem scopes from the plain-data index"
```

---

### Task 8: Delete the old whole-closure testitem machinery

The old pipeline (`derived_static_lint_meta_for_root`) remains the test harness's backbone (`test/staticlint/test_staticlint.jl` `parse_and_pass`) and keeps its non-testitem behavior. Only its testitem machinery goes: the EXPR-based setup registry and the self-package workspace merge that existed solely for `@testitem` resolution.

**Files:**
- Modify: `src/layer_static_lint.jl` (deletions listed below)
- Modify: `src/layer_file_analysis.jl:844-850` (drop the now-false "Test-setup parity" paragraph from `derived_new_static_lint_diagnostics`'s docstring)
- Test: full suite

**Interfaces:**
- Consumes: nothing new.
- Produces: removals only — `derived_test_setup_bindings`, `_find_test_macros_in_cst`, `_get_body_block`, `_collect_body_exprs` cease to exist.

- [ ] **Step 1: Verify there are no remaining consumers**

Run: `grep -rn "derived_test_setup_bindings\|_find_test_macros_in_cst\|_get_body_block\|_collect_body_exprs" src/ test/ docs/src 2>/dev/null`
Expected: hits only inside `src/layer_static_lint.jl` (and possibly `src/precompile.jl` — if precompile references any of these, delete those precompile statements too).

- [ ] **Step 2: Delete**

In `src/layer_static_lint.jl`:
- Delete the block in `derived_static_lint_meta_for_root` starting at the comment `# Pre-compute test setup bindings (@testmodule/@testsnippet) for the enclosing package` through the closing `end` of the `if package_folder_uri !== nothing` block (currently lines ~127-150; it computes `test_setups`, `self_package_name`, and merges the self package into `workspace_packages` — all of it existed for `@testitem` resolution only).
- The `semantic_pass` call there was already reduced to `StaticLint.semantic_pass(uri, cst, env, meta_dict, rt; workspace_packages)` in Task 7 — confirm it.
- Delete `derived_test_setup_bindings` and its docstring, plus the helpers `_find_test_macros_in_cst`, `_get_body_block`, `_collect_body_exprs` and the section banner `# Test setup pre-computation (@testmodule / @testsnippet)`.

In `src/layer_file_analysis.jl`, in the docstring of `derived_new_static_lint_diagnostics`, delete the paragraph beginning `Test-setup parity: the whole-closure pass feeds` (it documents a state this plan has removed).

- [ ] **Step 3: Run the full suite**

Run: `julia --project=. test/runtests.jl 2>&1 | tail -30`
Expected: PASS. Watch specifically the old/new parity tests (`test/test_file_analysis.jl:1832-1870`, `test/test_diagnostics.jl:1738-1790`) and `test/test_projects.jl:94` — none of their fixtures contain testitems, so removing the old testitem block must not change their results. If one fails, inspect whether its fixture relied on the deleted self-package merge; fix the fixture expectation, not the deletion.

- [ ] **Step 4: Commit**

```bash
git add src/layer_static_lint.jl src/layer_file_analysis.jl
git commit -m "refactor: drop the whole-closure pipeline's EXPR-based testitem machinery"
```

---

### Task 9: End-to-end fixture + repo smoke check

One test that exercises the whole feature surface together, plus a manual smoke check against this repository (the original bug report).

**Files:**
- Test: `test/staticlint/test_testitem_analysis.jl`

- [ ] **Step 1: Write the end-to-end test**

```julia
@testitem "end to end: default imports, explicit using, setups, and real missing refs" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "full" setup=[TM, TS] begin
            using MyPkg: ifn
            efn()
            ifn()
            MyPkg.ifn()
            TM.tmf()
            sx
            oops_undefined
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            tmf() = 1
        end
        @testsnippet TS begin
            sx = 1
        end
        """))
    msgs = diag_messages(jw)
    missing_refs = filter(m -> startswith(m, "Missing reference:"), msgs)
    @test missing_refs == ["Missing reference: oops_undefined"]
end
```

- [ ] **Step 2: Run it**

Run: `JW_TEST_FILTER="end to end" julia --project=. test/runtests.jl`
Expected: PASS. If extra missing refs appear, each one is a real bug in an earlier task — fix there, not by loosening this assertion.

- [ ] **Step 3: Smoke-check against this repository**

In a Julia session (`julia --project=.`):

```julia
using JuliaWorkspaces
using JuliaWorkspaces.URIs2: filepath2uri
jw = JuliaWorkspaces.workspace_from_folders(["/home/pfitzseb/git/JuliaWorkspaces.jl"])
uri = filepath2uri("/home/pfitzseb/git/JuliaWorkspaces.jl/test/test_testitems.jl")
fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, uri, uri)
msgs = sort!(unique([d.message for d in fa.diagnostics]))
foreach(println, msgs)
```

Expected: NO `Missing reference:` entries for `SourceText`, `add_file!`, `TextFile`, `JuliaWorkspace`, `get_test_env`, `@testitem`, `@testmodule`, or `@testsnippet`. (`Missing reference: @test` may remain in this headless session — no symbol caches, `Test` not in the env — that is environmental, not a regression; verify `@test` resolves in a session with caches or in VS Code.)

- [ ] **Step 4: Full suite + commit**

Run: `julia --project=. test/runtests.jl 2>&1 | tail -5`
Expected: PASS.

```bash
git add test/staticlint/test_testitem_analysis.jl
git commit -m "test(staticlint): end-to-end coverage for testitem analysis in per-file mode"
```

---

## Self-Review Notes

- Spec coverage: root causes 1 (no wiring) → Tasks 4/7; 2 (`using` bring-ins) → Task 5; 3 (placeholder off-by-one) → Tasks 2/6; 4 (suppression + macro names) → Tasks 1/2. Decisions: C2 → Tasks 6/7; `@testset` → Task 1; deletion → Task 8; inventory opacity → no task touches the inventory walker (intentional).
- Known deferred gaps (documented, not planned): go-to-definition into setup declarations (`TestSetupModuleRef`/snippet bindings carry no `ItemRef`s — needs inventory items for setups, which conflicts with none of the decisions and can be a follow-up); names a setup gains via macros or `using` inside its body are not enumerable (mitigated by never flagging setup-member misses and snippet names being additive-only).
- Type consistency: `TestSetupData.bound_names::Vector{String}` (sorted) feeds `TestSetupInfo.names::Set{String}` via the Task 7 conversion; `test_setup_info` takes `Symbol`, `derived_test_setup` takes `Symbol` — consistent throughout.
