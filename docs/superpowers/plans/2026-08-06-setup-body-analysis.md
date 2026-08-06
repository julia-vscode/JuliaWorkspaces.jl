# Setup Bodies Analyzed As Virtual Files — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled CST name-scan for `@testmodule`/`@testsnippet` bodies with a run of the normal StaticLint passes over the body subtree, so wildcard `using` of a resolvable package brings real names into referencing `@testitem`s instead of disabling missing-ref checks.

**Architecture:** `derived_test_setups_in_file` (src/layer_test_setups.jl) extracts each setup's `:block` body from the file CST and runs `StaticLint.semantic_pass` + `mark_unresolved_imports!` over it with the same env/tree-context frame `derived_file_analysis` uses, then flattens the resulting scope into plain data (`TestSetupData`). `_handle_testitem` (src/StaticLint/macros.jl) re-attaches a snippet's resolved wildcard packages into the item scope via the env store or the module tree, falling back to bare-ref suppression only when something is genuinely unresolvable.

**Tech Stack:** Julia; Salsa derived queries; vendored CSTParser/StaticLint inside this package (`src/StaticLint/`); TestItemRunner-style tests in `test/staticlint/`.

**Spec:** `docs/superpowers/specs/2026-08-06-setup-body-analysis-design.md`

## Global Constraints

- Run tests through the julia MCP dev-env session (`mcp__julia__julia_eval`), e.g. `run_tests("test/staticlint/test_testitem_analysis.jl"; filter="<testitem name substring>")`. NEVER spawn a `julia` process or `Pkg.test`.
- Tasks 2 and 3 redefine structs (`TestSetupData`, `TestSetupInfo`): restart the julia session (`mcp__julia__julia_restart`) BEFORE the first test run of each of those tasks, or stale struct definitions will produce confusing method errors.
- `@testitem` bodies need explicit `using JuliaWorkspaces: ...` imports; the existing `TestItemAnalysisWS` snippet provides `SL` (StaticLint), `CST` (CSTParser), the URI consts, and `pkg_ws`/`diag_messages` helpers.
- Code comments: terse, and never reference the spec/plan documents.
- Commit messages describe the change; no test counts, no branch bookkeeping. End with the Claude co-author line.
- Edit repo files directly with Edit/Write; no bulk-rewrite scripts.
- Git commands run in `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces` (a submodule — never the julia-vscode root). All file paths below are relative to this directory.

---

### Task 1: `strip_contexts` keyword on `semantic_pass`

The extraction query (Task 2) must read `scope.modules` AFTER the pass, but `semantic_pass` strips every module-context entry when a `module_context` is given (they are runtime handles that must not outlive the pass **when the meta is frozen into a derived value**). The extraction discards its meta locally, so it may skip the strip.

**Files:**
- Modify: `src/StaticLint/StaticLint.jl:458` (signature) and `:503` (final strip line)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: existing `semantic_pass(uri, cst, env, meta_dict, rt, modified_expr=nothing; workspace_packages, self_package_name, module_context)`.
- Produces: same function with additional keyword `strip_contexts::Bool = true`. Default behavior unchanged; `strip_contexts=false` leaves `:__tree__`/context entries in the scopes of the (caller-local) `meta_dict`. Task 2 calls it with `strip_contexts=false`.

- [ ] **Step 1: Write the failing test**

Append to `test/staticlint/test_testitem_analysis.jl`:

```julia
@testitem "semantic_pass strip_contexts=false keeps module contexts" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    env = JuliaWorkspaces.derived_stdlib_only_env(jw.runtime)
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])

    cst = CST.parse("x = 1", true)
    md = Dict{UInt64,SL.Meta}()
    SL.semantic_pass(TESTF, cst, env, md, jw.runtime; module_context=ctx, strip_contexts=false)
    @test haskey(SL.scopeof(cst, md).modules, :__tree__)

    cst2 = CST.parse("x = 1", true)
    md2 = Dict{UInt64,SL.Meta}()
    SL.semantic_pass(TESTF, cst2, env, md2, jw.runtime; module_context=ctx)
    @test !haskey(SL.scopeof(cst2, md2).modules, :__tree__)
end
```

- [ ] **Step 2: Run test to verify it fails**

Via `mcp__julia__julia_eval`: `run_tests("test/staticlint/test_testitem_analysis.jl"; filter="strip_contexts")`
Expected: FAIL — `MethodError`/`UndefKeywordError`: `semantic_pass` has no keyword `strip_contexts`.

- [ ] **Step 3: Implement**

In `src/StaticLint/StaticLint.jl:458`, add the keyword to the signature:

```julia
function semantic_pass(uri, cst, env, meta_dict, rt, modified_expr = nothing; workspace_packages = Dict{String,Any}(), self_package_name::Union{Nothing,String} = nothing, module_context::Union{Nothing,AbstractModuleContext} = nothing, strip_contexts::Bool = true)
```

Replace the final line (`:503`):

```julia
    module_context === nothing || strip_module_contexts!(meta_dict)
```

with:

```julia
    # strip_contexts=false is only safe when the caller discards meta_dict
    # instead of freezing it into a derived value (contexts hold the runtime).
    (module_context === nothing || !strip_contexts) || strip_module_contexts!(meta_dict)
```

- [ ] **Step 4: Run test to verify it passes**

Via `mcp__julia__julia_eval`: `run_tests("test/staticlint/test_testitem_analysis.jl"; filter="strip_contexts")`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/StaticLint.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): allow semantic_pass callers to keep module contexts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Extract setup data by running the normal passes over the body

Replaces the hand-rolled name scan with a real analysis run and re-shapes the data through the whole pipeline (`TestSetupData` → `TestSetupInfo` → `_handle_testitem`). Behavior landing here: `begin`/`if`-block bindings found, `@enum` names enumerated, `import X` binds `X`, testmodule wildcards stop suppressing item-side checks, no macrocall conservatism. Wildcard `using` in snippets keeps an interim conservative rule (any wildcard suppresses) that Task 3 replaces with real re-attachment.

**Files:**
- Modify: `src/layer_test_setups.jl` (struct at `:24-31`, delete helpers `:33-190` except `_setup_unwrap_doc`/`_setup_export_names!`/`_setup_toplevel_export_names`, rewrite `derived_test_setups_in_file` at `:198-229`)
- Modify: `src/StaticLint/StaticLint.jl:170-188` (`TestSetupInfo` docstring + struct)
- Modify: `src/layer_file_analysis.jl:71-77` (`test_setup_info` conversion)
- Modify: `src/StaticLint/macros.jl:498-503` (consumer: replace the `fully_enumerable` rule)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `semantic_pass(...; module_context, strip_contexts=false)` from Task 1; existing queries `derived_julia_legacy_syntax_tree(rt, uri)`, `derived_best_root_for_uri(rt, uri)`, `derived_project_uri_for_root(rt, root)`, `derived_environment(rt, project_uri)`, `derived_stdlib_only_env(rt)`, `derived_file_module_path(rt, root, uri)`, `TreeModuleContext(rt, root, path)`; `StaticLint.mark_unresolved_imports!(x, env, meta_dict)`.
- Produces:
  - `TestSetupData(name::Symbol, kind::Symbol, file::URI, bound_names::Vector{String}, exported_names::Vector{String}, wildcard_packages::Vector{String}, has_unresolved_wildcard::Bool)`
  - `StaticLint.TestSetupInfo(kind::Symbol, names::Set{String}, exports::Set{String}, wildcard_packages::Vector{String}, has_unresolved_wildcard::Bool)`
  - Task 3 relies on `info.wildcard_packages` / `info.has_unresolved_wildcard` inside `_handle_testitem`.

- [ ] **Step 1: Write the failing tests**

In `test/staticlint/test_testitem_analysis.jl`, REPLACE the `@testitem "derived_test_setups indexes testmodules and testsnippets as plain data"` (currently asserting `bound_names` only) with:

```julia
@testitem "derived_test_setups analyzes setup bodies with the normal passes" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        tmf() = 1
        const TC = 2
        struct TS_t end
        begin
            inblock = 3
        end
        @enum Color Red Green
        import MyPkg
        export tmf
    end
    @testsnippet TS begin
        sx = 1
        sy, sz = 2, 3
        using MyPkg
        using NoSuchPkg_xyz
    end
    """)
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test Set(keys(setups)) == Set([:TM, :TS])

    tm = setups[:TM]
    @test tm.kind == :module
    @test tm.file == TESTF
    # normal-pass bindings: block interiors, @enum members, and `import X`
    # (which binds X itself, as in any file) included
    @test issubset(["Color", "Green", "MyPkg", "Red", "TC", "TS_t", "inblock", "tmf"], tm.bound_names)
    @test tm.exported_names == ["tmf"]
    @test tm.wildcard_packages == String[]
    @test !tm.has_unresolved_wildcard

    ts = setups[:TS]
    @test ts.kind == :snippet
    @test issubset(["sx", "sy", "sz"], ts.bound_names)
    # resolved wildcard recorded by name; unresolved one sets the flag
    @test ts.wildcard_packages == ["MyPkg"]
    @test ts.has_unresolved_wildcard

    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :TM) == tm
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :Nope) === nothing
end
```

Append these new testitems:

```julia
@testitem "testmodule wildcards do not suppress item-side missing refs" setup=[TestItemAnalysisWS] begin
    # A wildcard `using` inside a @testmodule stays contained in the module
    # at runtime: the item sees only TM's explicit exports, so item-side
    # checking must stay fully enabled even when the wildcard is unresolvable.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM] begin
            tmf()
            TM.anything_goes()
            undefined_in_item
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            using NoSuchPkg_xyz
            export tmf
            tmf() = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: tmf" in msgs)
    @test !("Missing reference: anything_goes" in msgs)
    @test "Missing reference: undefined_in_item" in msgs
end

@testitem "known binding macros in setups enumerate instead of suppressing" setup=[TestItemAnalysisWS] begin
    # @enum used to make the whole setup unenumerable; the normal passes
    # bind its members, so the item resolves them and keeps full checking.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            x = Red
            undefined_after_enum
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            @enum Color Red Green
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: Red" in msgs)
    @test "Missing reference: undefined_after_enum" in msgs
end

@testitem "block-nested setup bindings reach referencing items" setup=[TestItemAnalysisWS] begin
    # the old top-level-only scan silently dropped these
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            inblock
            inbranch
            undefined_next_to_blocks
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            begin
                inblock = 1
            end
            if true
                inbranch = 2
            end
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: inblock" in msgs)
    @test !("Missing reference: inbranch" in msgs)
    @test "Missing reference: undefined_next_to_blocks" in msgs
end

@testitem "same-file setup references do not cycle" setup=[TestItemAnalysisWS] begin
    # a @testitem next to its @testmodule is the common layout; the setup
    # index must come from the raw CST, never from this file's own analysis
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        export tmf
        tmf() = 1
    end
    @testitem "t" default_imports=false setup=[TM] begin
        tmf()
        undefined_same_file
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: tmf" in msgs)
    @test "Missing reference: undefined_same_file" in msgs
end

@testitem "unresolvable snippet wildcards still suppress item missing refs" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            could_come_from_the_wildcard
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            using NoSuchPkg_xyz
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: could_come_from_the_wildcard" in msgs)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Restart the session first (struct changes come next, but the baseline must be clean): `mcp__julia__julia_restart`, then via `mcp__julia__julia_eval`:
`run_tests("test/staticlint/test_testitem_analysis.jl")`
Expected: the replaced/new testitems FAIL (`TestSetupData` has no field `wildcard_packages`; suppression/enumeration assertions fail); all previously existing testitems PASS.

- [ ] **Step 3: Re-shape the structs and the conversion**

`src/layer_test_setups.jl:6-31` — replace docstring + struct:

```julia
"""
    TestSetupData

One `@testmodule` or `@testsnippet` declaration, as plain data flattened
from a normal-passes analysis of the body: `kind` is `:module`/`:snippet`,
`file` the declaring file, `bound_names` the sorted names the body scope
binds, `exported_names` the sorted names a top-level `export a, b` makes
public (relevant for `:module` setups: TestItemRunner injects a testmodule
via `using ..Setups.TM`, which brings TM's EXPORTS — not its full member
set — into the referencing testitem). `wildcard_packages` are the packages
a wildcard `using X` resolved against (env store or module tree); a
referencing `@testitem` re-attaches them into its own scope.
`has_unresolved_wildcard` is `true` when a wildcard `using` resolved
against nothing — the item must then suppress bare missing-ref checks
rather than trust the name sets.
"""
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol
    file::URI
    bound_names::Vector{String}
    exported_names::Vector{String}
    wildcard_packages::Vector{String}
    has_unresolved_wildcard::Bool
end
```

`src/StaticLint/StaticLint.jl:170-188` — replace the `TestSetupInfo` docstring's last sentence block (`fully_enumerable` explanation) and struct with:

```julia
Plain-data description of a `@testmodule` or `@testsnippet` a `@testitem`
references via `setup=[...]`: `kind` is `:module`/`:snippet`, `names` the
names the setup's body scope binds, `exports` the names a `:module` setup's
top-level `export` makes public (TestItemRunner injects a testmodule via
`using ..Setups.TM`, which brings in TM's exports, not its full member
set). `wildcard_packages` are packages a snippet's wildcard `using`
resolved against, for re-attachment into the item scope;
`has_unresolved_wildcard` is `true` when a wildcard resolved against
nothing, so the item must suppress bare missing-ref checks instead.
Produced by the `test_setup_info(ctx, name)` interface (backed by a Salsa
query outside StaticLint); safe to reach from frozen meta.
"""
@auto_hash_equals struct TestSetupInfo
    kind::Symbol
    names::Set{String}
    exports::Set{String}
    wildcard_packages::Vector{String}
    has_unresolved_wildcard::Bool
end
```

`src/layer_file_analysis.jl:76` — replace the conversion return:

```julia
    return StaticLint.TestSetupInfo(s.kind, Set{String}(s.bound_names), Set{String}(s.exported_names), s.wildcard_packages, s.has_unresolved_wildcard)
```

`src/StaticLint/macros.jl:498-502` — replace

```julia
            # The setup's name/export sets are not exhaustive (a wildcard
            # using/import or unrecognized macrocall at its top level) —
            # suppress bare missing-ref checks in the whole item body rather
            # than risk flagging a name the setup actually provides.
            info.fully_enumerable || (item_scope.unresolved_wildcard_import = true)
```

with (interim until the re-attachment task; testmodule wildcards stay
contained in the module at runtime, so only snippets can suppress):

```julia
            # A snippet's wildcard `using` brings unknown-to-us names into the
            # item body — suppress bare missing-ref checks there. Testmodule
            # wildcards stay contained in the module (only its literal exports
            # reach the item), so they never suppress.
            if info.kind === :snippet && (info.has_unresolved_wildcard || !isempty(info.wildcard_packages))
                item_scope.unresolved_wildcard_import = true
            end
```

- [ ] **Step 4: Rewrite the extraction query**

In `src/layer_test_setups.jl`, DELETE `_setup_bound_name`, `_setup_lhs_names!`, `_setup_collect_names!`, `_setup_import_colon_form`, `_import_colon_leaf_name`, `_setup_import_bound_names!`, `_setup_unenumerable_toplevel_stmt`, `_setup_toplevel_bound_names`, `_setup_toplevel_fully_enumerable` (lines 33-81, 107-173, 184-190). KEEP `_setup_unwrap_doc` and `_setup_export_names!`/`_setup_toplevel_export_names` (exports have no reusable record in the pass; the scan is exact for literal `export a, b` lists).

Replace the body of `derived_test_setups_in_file` (`:198-229`) with:

```julia
Salsa.@derived function derived_test_setups_in_file(rt, uri)
    @debug "derived_test_setups_in_file" uri=uri

    result = TestSetupData[]
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst.args === nothing && return result

    # One env/tree frame for all setups in the file, built lazily so files
    # without setups (the common case) never pay for the env lookup.
    frame = nothing
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

        if frame === nothing
            root = derived_best_root_for_uri(rt, uri)
            project_uri = root === nothing ? nothing : derived_project_uri_for_root(rt, root)
            env = project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
            path = root === nothing ? nothing : derived_file_module_path(rt, root, uri)
            frame = (env, root, path)
        end
        env, root, path = frame

        # A setup body is a file at runtime (a bare module for @testmodule,
        # spliced file-toplevel code for @testsnippet) — run the normal
        # passes over it and flatten the resulting scope to plain data. The
        # meta is local and discarded, so the pass may keep its context
        # handles (strip_contexts=false), which the wildcard flattening
        # below needs to see in scope.modules.
        ctx = path === nothing ? nothing : TreeModuleContext(rt, root, path)
        meta_dict = Dict{UInt64,StaticLint.Meta}()
        StaticLint.semantic_pass(uri, body, env, meta_dict, rt; module_context=ctx, strip_contexts=false)
        StaticLint.mark_unresolved_imports!(body, env, meta_dict)

        scope = StaticLint.scopeof(body, meta_dict)
        bound = String[]
        wildcards = String[]
        unresolved = false
        if scope isa StaticLint.Scope
            append!(bound, keys(scope.names))
            if scope.modules isa Dict
                for k in keys(scope.modules)
                    # Base/Core are pass-seeded, :__tree__ is the context handle;
                    # everything else got there through a wildcard `using`.
                    k in (:Base, :Core, :__tree__) && continue
                    push!(wildcards, String(k))
                end
            end
            unresolved = scope.unresolved_wildcard_import
        end
        push!(result, TestSetupData(Symbol(setup_name), kind, uri,
            sort!(unique!(bound)), _setup_toplevel_export_names(body),
            sort!(unique!(wildcards)), unresolved))
    end
    return result
end
```

Also update the file-header comment (`src/layer_test_setups.jl:1-4`) to say the index is flattened from a normal-passes run over each body (still: never another file's EXPRs in a frozen FileAnalysis).

- [ ] **Step 5: Run the test file**

`mcp__julia__julia_restart`, then `run_tests("test/staticlint/test_testitem_analysis.jl")`.
Expected: ALL testitems PASS — including the pre-existing ones ("setup testmodules and testsnippets inject into @testitem scopes cross-file", "testmodule exports inject into @testitem scopes bare", "snippet using-leaves inject into @testitem scopes", "end to end: …"). If `keys(scope.names)` turns out to include unexpected extras for these fixtures, investigate before adjusting any assertion — extras indicate frame or scope-seeding mistakes, not test staleness.

- [ ] **Step 6: Run the neighboring suites to catch ripples**

`run_tests("test/staticlint")` and `run_tests("test/test_file_analysis.jl")`.
Expected: PASS (nothing else constructs `TestSetupData`/`TestSetupInfo`; `grep -rn "fully_enumerable" src/ test/` must come back empty).

- [ ] **Step 7: Commit**

```bash
git add src/layer_test_setups.jl src/layer_file_analysis.jl src/StaticLint/StaticLint.jl src/StaticLint/macros.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): analyze test-setup bodies with the normal passes

A @testmodule body is a file containing a bare module; a @testsnippet body
is spliced file-toplevel code. Running semantic_pass over the body subtree
replaces the hand-rolled top-level name scan: block/if interiors and known
binding macros (@enum) now bind, import X binds X, and testmodule wildcard
usings no longer suppress missing-ref checks in referencing testitems.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Re-attach a snippet's resolved wildcard packages in the item scope

Replaces Task 2's interim "any snippet wildcard suppresses" rule: packages the setup-side analysis resolved are re-attached into the item scope (env store or module tree), so their exports resolve bare — with hover/method info — and checking stays fully enabled. Only genuine unresolvability (setup-side flag, or an item-side re-attachment miss) suppresses.

**Files:**
- Modify: `src/StaticLint/macros.jl` (the `setup=[...]` loop in `_handle_testitem`, `:478-504` after Task 2)
- Test: `test/staticlint/test_testitem_analysis.jl`

**Interfaces:**
- Consumes: `info.wildcard_packages::Vector{String}` / `info.has_unresolved_wildcard::Bool` from Task 2; existing `getsymbols(state)`, `_add_module_public_names!(scope, mod_store, state)`, `workspace_package_context(tctx, name::String)`, `context_tree_ref(wp)`, `context_exported_names(wp)`, `ExportFilteredContext(inner, names::Set{String})`, `Binding`, `noname`, `CoreTypes.Module`.
- Produces: final item-scope injection semantics; no new interfaces.

- [ ] **Step 1: Write the failing test**

Append to `test/staticlint/test_testitem_analysis.jl`:

```julia
@testitem "resolvable snippet wildcards re-attach instead of suppressing" setup=[TestItemAnalysisWS] begin
    # `using MyPkg` in the snippet resolves through the module tree, so the
    # item gets MyPkg's exports (export-filtered: internals still flagged)
    # and full missing-ref checking stays on.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            efn()
            MyPkg.ifn()
            ifn()
            undefined_beside_wildcard
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            using MyPkg
        end
        """))
    msgs = diag_messages(jw)
    # exported name resolves bare; the package name resolves qualified
    @test !("Missing reference: efn" in msgs)
    @test !("Missing reference: MyPkg" in msgs)
    # non-exported internals and genuine unknowns are still flagged
    @test "Missing reference: ifn" in msgs
    @test "Missing reference: undefined_beside_wildcard" in msgs
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/staticlint/test_testitem_analysis.jl"; filter="re-attach")`
Expected: FAIL — the interim rule suppresses everything, so `"Missing reference: ifn"` and `"Missing reference: undefined_beside_wildcard"` are absent.

- [ ] **Step 3: Implement the re-attachment**

In `_handle_testitem`'s setup loop (src/StaticLint/macros.jl), extend the `elseif info.kind === :snippet` arm and DELETE the interim suppression block Task 2 added at the loop's tail. The arm becomes:

```julia
            elseif info.kind === :snippet
                for n in info.names
                    haskey(item_scope.names, n) ||
                        (item_scope.names[n] = Binding(noname, nothing, nothing, EXPR[]))
                end
                # Re-attach the snippet's resolved wildcard `using`s: the env
                # store where available (full member info), the module tree
                # otherwise (export-filtered, like the default-imports path).
                # An attachment miss means the item can't enumerate what the
                # snippet sees — suppress bare missing-ref checks then.
                symbols = getsymbols(state)
                for pkgname in info.wildcard_packages
                    pkg_sym = Symbol(pkgname)
                    attached = false
                    if haskey(symbols, pkg_sym)
                        item_scope.modules[pkg_sym] = symbols[pkg_sym]
                        _add_module_public_names!(item_scope, symbols[pkg_sym], state)
                        attached = true
                    else
                        wp = workspace_package_context(tctx, pkgname)
                        if wp !== nothing
                            haskey(item_scope.names, pkgname) ||
                                (item_scope.names[pkgname] = Binding(noname, context_tree_ref(wp), CoreTypes.Module, EXPR[]))
                            exps = context_exported_names(wp)
                            if exps !== nothing
                                item_scope.modules[pkg_sym] = ExportFilteredContext(wp, Set{String}(exps))
                                attached = true
                            end
                        end
                    end
                    attached || (item_scope.unresolved_wildcard_import = true)
                end
                info.has_unresolved_wildcard && (item_scope.unresolved_wildcard_import = true)
            end
```

(The loop already guards `tctx !== nothing` at its top, so `workspace_package_context(tctx, …)` is safe.)

- [ ] **Step 4: Run the full test file**

`run_tests("test/staticlint/test_testitem_analysis.jl")`
Expected: ALL PASS — including Task 2's "unresolvable snippet wildcards still suppress item missing refs" (now via `has_unresolved_wildcard` instead of the interim rule).

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/macros.jl test/staticlint/test_testitem_analysis.jl
git commit -m "feat(staticlint): re-attach resolved snippet wildcard usings in testitem scopes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full-suite verification

**Files:** none (verification only).

**Interfaces:** n/a.

- [ ] **Step 1: Run the surrounding suites**

`mcp__julia__julia_restart`, then via `mcp__julia__julia_eval`, one call each (session timeouts kill the run — do NOT lump them into one call):
- `run_tests("test/staticlint")`
- `run_tests("test/test_file_analysis.jl")`
- `run_tests("test/test_diagnostics.jl")`
- `run_tests("test/test_inventory.jl")`

Expected: PASS everywhere. Report any failure verbatim instead of patching tests to green.

- [ ] **Step 2: Confirm the dead code is gone**

Run: `grep -rn "fully_enumerable\|_setup_collect_names\|_setup_toplevel_bound_names\|_setup_import_colon_form" src/ test/`
Expected: no matches.

- [ ] **Step 3: Commit (only if stragglers were fixed)**

Nothing to commit when Steps 1-2 are clean.
