# Unresolved-Import Missing-Refs Tolerance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tolerate imports of unresolvable modules (synthetic bindings for explicitly written names, scope-level suppression for wildcard `using`), flag the import statement itself with a new `UnresolvedImport` diagnostic, and flip the `missing-refs` default from `"symbols"` to `"all"`.

**Architecture:** Synthetic bindings are created eagerly in `resolve_import_block`'s failure branch and filled in place if the ResolveOnly retry succeeds. A read-only post-pass (`mark_unresolved_imports!`, run alongside `resolve_remaining_getfields!` after `semantic_pass`) marks still-unresolved import components with `UnresolvedImport` and sets an `unresolved_wildcard_import` flag on scopes containing unresolved wildcard `using`s; `collect_hints` consumes the flag to suppress bare missing-ref hints.

**Tech Stack:** Julia, CSTParser-based StaticLint inside the JuliaWorkspaces package, Salsa derived queries, TestItemRunner tests.

**Spec:** `docs/superpowers/specs/2026-07-14-unresolved-import-missing-refs-design.md` (read it first).

## Global Constraints

- All paths below are relative to `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces` (a git submodule; run git commands from inside it). Work on branch `sp/unresolved-import-missing-refs`.
- Run tests with the repo-root dev environment:
  `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="<substring of testitem name>" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
  Julia startup + package load takes ~1–2 minutes; do not kill runs early. An empty `JW_TEST_FILTER` runs the whole suite (very slow — only in Task 5).
- Diagnostic messages (copy verbatim):
  - Wildcard: `` Failed to resolve `NAME`. Missing-reference checks are disabled in this scope and all nested scopes. ``
  - Non-wildcard: `` Failed to resolve `NAME`. Anything imported through this statement is assumed to exist and will not be checked. ``
- Append `UnresolvedImport` at the END of the `LintCodes` enum (never reorder existing members).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- CST shapes (verified empirically): each import path is an EXPR with head = operator `.` and args = components (`IDENTIFIER`s, plus leading `OPERATOR "."` leaves for relative imports). Colon form: statement's `args[1]` has head = operator `:`; its `args[1]` is the module path, `args[2:end]` are name paths. `as` form: head `:as`, `args[1]` = path, `args[2]` = alias IDENTIFIER.

---

### Task 1: Synthetic bindings for names bound by unresolved imports

**Files:**
- Modify: `src/StaticLint/imports.jl` (failure branches of `resolve_import_block` / `resolve_import`, new helpers)
- Test: `test/test_diagnostics.jl` (append)

**Interfaces:**
- Consumes: existing `resolve_import_block`, `_mark_import_arg`, `_get_field`, `maybe_lookup`, `_typeof`, `Binding`, `setref!`, `ensuremeta`, `getmeta`, `hasref`, `refof`, `hasbinding` (all already in the `StaticLint` module).
- Produces: `is_synthetic_import_binding(b) -> Bool` and `ensure_synthetic_import_binding!(block::EXPR, state)` in `src/StaticLint/imports.jl`, used by Task 2's post-pass. Synthetic bindings are `Binding(arg, nothing, nothing, [])` attached to the final component of an import path; "synthetic" is detectable as `b.val === nothing && b.type === nothing` on a binding whose name sits inside a `using`/`import` statement.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_diagnostics.jl`:

```julia
# ──────────────────────────────────────────────────────────────────────
# unresolved-import tolerance tests
# ──────────────────────────────────────────────────────────────────────

@testitem "unresolved import: explicit names are bound, uses silent" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresExpl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee21"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresExpl
    using NotARealPackage: foo, bar
    import AlsoNotReal
    function f()
        foo(bar) + AlsoNotReal.thing + genuine_typo
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresexpl/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresexpl/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresexpl/src/UnresExpl.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresexpl/src/UnresExpl.jl"))

    # Uses of the explicitly imported names resolve to synthetic bindings
    @test !any(d -> d.message == "Missing reference: foo", diags)
    @test !any(d -> d.message == "Missing reference: bar", diags)
    @test !any(d -> d.message == "Missing reference: AlsoNotReal", diags)
    # A genuine typo in the same scope is still reported
    @test any(d -> d.message == "Missing reference: genuine_typo", diags)
end

@testitem "unresolved import: self-import using M: M tolerates M.foo" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresSelf"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresSelf
    using NotARealPackage: NotARealPackage
    function f()
        NotARealPackage.foo(1)
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresself/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresself/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresself/src/UnresSelf.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresself/src/UnresSelf.jl"))

    @test !any(d -> d.message == "Missing reference: foo", diags)
    # the downstream use of NotARealPackage must not be flagged
    # (the import statement itself may still carry a diagnostic)
    missing_narp = filter(d -> d.message == "Missing reference: NotARealPackage", diags)
    @test length(missing_narp) <= 1  # at most the import statement itself (removed in Task 2)
end

@testitem "unresolved import: late-resolving sibling module fills binding" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresLate"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresLate
    using .Sib: bar
    function f()
        bar()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreslate/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslate/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslate/src/UnresLate.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreslate/src/UnresLate.jl"))

    # Everything resolves after the retry: no missing refs at all
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: late-resolved module lacking the name stays silent for uses" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresLateMiss"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee24"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresLateMiss
    using .Sib: baz
    function f()
        baz()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreslatemiss/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslatemiss/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslatemiss/src/UnresLateMiss.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreslatemiss/src/UnresLateMiss.jl"))

    # uses of baz resolve to the (never-filled) synthetic binding
    @test !any(d -> d.message == "Missing reference: baz", diags)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved import" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: FAIL — "Missing reference: foo", "Missing reference: baz", etc. are currently produced.

- [ ] **Step 3: Implement synthetic bindings in `src/StaticLint/imports.jl`**

Add helpers at the end of the file:

```julia
"""
    is_synthetic_import_binding(b)

Is `b` a binding created by `ensure_synthetic_import_binding!` for a name an
unresolved import statement would bind? Real import bindings created by
`_mark_import_arg` always carry a non-nothing `val`, so `val === nothing &&
type === nothing` on a binding whose name sits inside a `using`/`import`
statement identifies the synthetic ones.
"""
is_synthetic_import_binding(b) = b isa Binding && b.val === nothing && b.type === nothing &&
    b.name isa EXPR && is_in_fexpr(b.name, y -> headof(y) === :using || headof(y) === :import)

# Attach a synthetic binding to the name `block` (an import path) would bind:
# the alias for `as` blocks, otherwise the last path component. The user has
# asserted this name exists, so downstream references resolve to the import
# site instead of being reported as missing.
function ensure_synthetic_import_binding!(block::EXPR, state)
    if headof(block) === :as
        length(block.args) == 2 && _ensure_synthetic_import_binding_on!(block.args[2], state)
        return
    end
    (block.args === nothing || isempty(block.args)) && return
    _ensure_synthetic_import_binding_on!(last(block.args), state)
    return
end

function _ensure_synthetic_import_binding_on!(arg::EXPR, state)
    meta_dict = state.meta_dict
    CSTParser.is_id_or_macroname(arg) || return
    (hasbinding(arg, meta_dict) || hasref(arg, meta_dict)) && return
    ensuremeta(arg, meta_dict)
    b = Binding(arg, nothing, nothing, [])
    getmeta(arg, meta_dict).binding = b
    setref!(arg, b, meta_dict)
    return
end

# Late (ResolveOnly-retry) resolution: fill a synthetic binding in place so
# every reference already pointing at this Binding object sees the real target.
function fill_synthetic_import_binding!(b::Binding, val, state)
    val = maybe_lookup(val, state)
    val === b && return b # never create a self-referential binding
    b.val = val
    b.type = _typeof(val, state)
    return b
end
```

In `resolve_import_block`, replace the identifier-component branch body (currently `cand = hasref(...) ... if cand === nothing ... return`) with:

```julia
        elseif isidentifier(arg) || (i == n && (CSTParser.ismacroname(arg) || isoperator(arg)))
            cand = hasref(arg, meta_dict) ? refof(arg, meta_dict) : _get_field(root, arg, state)
            if hasref(arg, meta_dict) && is_synthetic_import_binding(cand)
                # A previous pass bound this name synthetically; retry the real
                # lookup and, on success, fill the same Binding object in place
                # so existing references see the real target. On failure the
                # synthetic binding must stay (uses keep resolving to it).
                # (The hasref guard ensures `cand` is this arg's own synthetic
                # binding, not one that `_get_field` fished out of scope.names.)
                newcand = _get_field(root, arg, state)
                newcand !== nothing && newcand !== cand && fill_synthetic_import_binding!(cand, newcand, state)
            end
            if cand === nothing
                # Cannot resolve now (e.g. sibling not yet defined). Schedule a retry.
                if state isa Toplevel
                    # the import/using expression
                    imp = StaticLint.get_parent_fexpr(arg, y -> headof(y) === :using || headof(y) === :import)
                    imp !== nothing && (imp ∈ state.resolveonly || push!(state.resolveonly, imp))
                    # the enclosing module (so we re-resolve refs within it)
                    mod = StaticLint.maybe_get_parent_fexpr(imp, CSTParser.defines_module)
                    mod !== nothing && (mod ∈ state.resolveonly || push!(state.resolveonly, mod))
                    # bind the name this path would have bound so downstream
                    # references to it resolve (the user asserted it exists)
                    markfinal && ensure_synthetic_import_binding!(x, state)
                end
                return
            end
```

(`markfinal` is false for the module path of a colon-form import — those components never get synthetic bindings, which Task 2's detection relies on.)

In `resolve_import`, extend the colon-form failure branch so the explicitly listed names are bound even though the name blocks are never visited:

```julia
            root2 = resolve_import_block(x.args[1].args[1], state, root, false, false)
            if root2 === nothing
                # schedule a retry like above
                if state isa Toplevel
                    push!(state.resolveonly, x)
                    mod = StaticLint.maybe_get_parent_fexpr(x, CSTParser.defines_module)
                    mod !== nothing && push!(state.resolveonly, mod)
                    # bind the explicitly listed names (`using A: b, c as d`)
                    for i = 2:length(x.args[1].args)
                        ensure_synthetic_import_binding!(x.args[1].args[i], state)
                    end
                end
                return
            end
```

Known accepted limitation (document with a comment in `resolve_import_block`'s `:as` branch, no code change): for `import A as B` that late-resolves, `B`'s binding is a *copy* made before the fill, so it stays value-unknown. No diagnostics are affected; only hover/goto-def stay degraded for that rare form.

- [ ] **Step 4: Run the new tests, verify they pass**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved import" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS (all 4 new testitems).

- [ ] **Step 5: Run neighboring regression tests**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="missing-refs" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/StaticLint/imports.jl test/test_diagnostics.jl
git commit -m "feat: synthetic bindings for names bound by unresolved imports

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `UnresolvedImport` diagnostic on the import statement

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`LintCodes` enum ~line 39, `LintCodeDescriptions` ~line 76, `collect_hints` ~line 778)
- Modify: `src/StaticLint/imports.jl` (append post-pass functions)
- Modify: `src/layer_static_lint.jl` (call post-pass ~line 164; diagnostic construction ~line 207)
- Modify: `src/layer_diagnostics.jl` (`_is_env_dependent_diagnostic` ~line 12)
- Test: `test/test_diagnostics.jl` (append + extend Task 1's self-import testitem)

**Interfaces:**
- Consumes: `is_synthetic_import_binding` (Task 1), `retrieve_scope`, `maybe_get_parent_fexpr`, `seterror!`, `haserror`, `hasref`, `refof`, `quoted`, `unquoted`.
- Produces: `StaticLint.mark_unresolved_imports!(x::EXPR, meta_dict)` (post-pass entry point), `StaticLint.is_in_wildcard_import(x::EXPR) -> Bool` (message selection), `StaticLint.UnresolvedImport::LintCodes`. Task 3 extends `mark_unresolved_import_stmt!` to set the scope flag.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_diagnostics.jl`:

```julia
@testitem "unresolved import: statement flagged with UnresolvedImport" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresFlag"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee25"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresFlag
    using NotARealPackage
    import AlsoNotReal: thing
    using Base: not_a_real_base_name_xyz
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresflag/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflag/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflag/src/UnresFlag.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresflag/src/UnresFlag.jl"))

    wildcard = filter(d -> d.message == "Failed to resolve `NotARealPackage`. Missing-reference checks are disabled in this scope and all nested scopes.", diags)
    @test length(wildcard) == 1
    @test wildcard[1].severity == :warning

    explicit = filter(d -> d.message == "Failed to resolve `AlsoNotReal`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test length(explicit) == 1

    # module resolvable but name missing: flagged on the name, immediately
    @test any(d -> startswith(d.message, "Failed to resolve `not_a_real_base_name_xyz`"), diags)
    @test !any(d -> startswith(d.message, "Failed to resolve `Base`"), diags)

    # no generic missing refs inside the import statements
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: name missing from late-resolved module is flagged" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresFlagLate"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee26"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresFlagLate
    using .Sib: baz
    function f()
        baz()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresflaglate/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflaglate/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflaglate/src/UnresFlagLate.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresflaglate/src/UnresFlagLate.jl"))

    # flagged on `baz` (the name), not on `Sib` (the module resolved)
    @test any(d -> startswith(d.message, "Failed to resolve `baz`"), diags)
    @test !any(d -> startswith(d.message, "Failed to resolve `Sib`"), diags)
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: diagnostic suppressed while env not ready" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresEnv"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee27"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresEnv
    using NotARealPackage
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresenv/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresenv/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresenv/src/UnresEnv.jl"), SourceText(source, "julia")))
    # NOTE: env deliberately NOT marked ready

    diags = get_diagnostic(jw, URI("file:///unresenv/src/UnresEnv.jl"))

    @test !any(d -> startswith(d.message, "Failed to resolve"), diags)
end
```

Also tighten the Task 1 self-import testitem now that the generic report is gone — replace its final two lines with:

```julia
    @test !any(d -> d.message == "Missing reference: foo", diags)
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
    @test any(d -> startswith(d.message, "Failed to resolve `NotARealPackage`"), diags)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved import" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: FAIL — no "Failed to resolve" diagnostics exist yet.

- [ ] **Step 3: Add the lint code**

In `src/StaticLint/linting/checks.jl`, append `UnresolvedImport,` as the LAST member of the `@enum(LintCodes, ...)` block (after `FunctionHasNoMethods,`), and add to `LintCodeDescriptions`:

```julia
    FunctionHasNoMethods => "Called function has no methods.",
    UnresolvedImport => "Failed to resolve import.",
```

(The description is a fallback; the real message is built in `layer_static_lint.jl`.)

- [ ] **Step 4: Add the post-pass to `src/StaticLint/imports.jl`**

```julia
"""
    mark_unresolved_imports!(x::EXPR, meta_dict, isquoted=false)

Post-`semantic_pass` marking of import statements that still failed to
resolve: the first unresolved component of each import path gets an
`UnresolvedImport` error. Must run after all resolution retries (i.e.
alongside `resolve_remaining_getfields!`), because in-pass failures may
still be retried via `state.resolveonly`.
"""
function mark_unresolved_imports!(x::EXPR, meta_dict, isquoted=false)
    if quoted(x)
        isquoted = true
    elseif isquoted && unquoted(x)
        isquoted = false
    end
    if !isquoted && (headof(x) === :using || headof(x) === :import)
        mark_unresolved_import_stmt!(x, meta_dict)
        return x
    end
    if x.args !== nothing
        for a in x.args
            mark_unresolved_imports!(a, meta_dict, isquoted)
        end
    end
    return x
end

function mark_unresolved_import_stmt!(x::EXPR, meta_dict)
    x.args === nothing && return
    if length(x.args) > 0 && isoperator(headof(x.args[1])) && valof(headof(x.args[1])) == ":"
        colon_expr = x.args[1]
        failed = first_unresolved_import_component(colon_expr.args[1], meta_dict)
        if failed !== nothing
            # the whole module path is unknown; one error there covers the
            # statement (the listed names carry synthetic bindings)
            seterror!(failed, UnresolvedImport, meta_dict)
        else
            for i = 2:length(colon_expr.args)
                nfailed = first_unresolved_import_component(colon_expr.args[i], meta_dict)
                nfailed === nothing && continue
                seterror!(nfailed, UnresolvedImport, meta_dict)
            end
        end
    else
        for path in x.args
            failed = first_unresolved_import_component(path, meta_dict)
            failed === nothing && continue
            seterror!(failed, UnresolvedImport, meta_dict)
        end
    end
    return
end

# First component of an import path that is still unresolved after all
# passes: module-path components show up as ref-less (they never get
# synthetic bindings), bound-name components as still-synthetic bindings.
function first_unresolved_import_component(path::EXPR, meta_dict)
    headof(path) === :as && return first_unresolved_import_component(path.args[1], meta_dict)
    path.args === nothing && return nothing
    for arg in path.args
        isoperator(arg) && valof(arg) == "." && continue
        # already diagnosed some other way (e.g. RelativeImportTooManyDots)
        haserror(arg, meta_dict) && return nothing
        hasref(arg, meta_dict) || return arg
        is_synthetic_import_binding(refof(arg, meta_dict)) && return arg
    end
    return nothing
end

# Is `x` a component of a wildcard `using` (no explicit-name colon form)?
# Decides which UnresolvedImport message the diagnostics layer shows.
function is_in_wildcard_import(x::EXPR)
    imp = maybe_get_parent_fexpr(x, y -> headof(y) === :using || headof(y) === :import)
    imp === nothing && return false
    headof(imp) === :using || return false
    return !(imp.args !== nothing && length(imp.args) > 0 &&
             isoperator(headof(imp.args[1])) && valof(headof(imp.args[1])) == ":")
end
```

- [ ] **Step 5: Wire the post-pass into `src/layer_static_lint.jl`**

In `derived_static_lint_meta_for_root`, directly after the `StaticLint.resolve_remaining_getfields!(cst2, env, workspace_packages, meta_dict)` line, add:

```julia
        # Late import-failure marking. Runs here (not in-pass) because
        # resolve_import failures may be retried via state.resolveonly.
        StaticLint.mark_unresolved_imports!(cst2, meta_dict)
```

- [ ] **Step 6: Build the diagnostic message in `src/layer_static_lint.jl`**

In `derived_static_lint_diagnostics_for_root`, insert a branch BEFORE the generic `elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) isa StaticLint.LintCodes` branch:

```julia
            elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) === StaticLint.UnresolvedImport
                name = CSTParser.str_value(err[2])
                msg = if StaticLint.is_in_wildcard_import(err[2])
                    "Failed to resolve `$name`. Missing-reference checks are disabled in this scope and all nested scopes."
                else
                    "Failed to resolve `$name`. Anything imported through this statement is assumed to exist and will not be checked."
                end
                push!(current_res, Diagnostic(rng, :warning, msg, nothing, Symbol[], "StaticLint.jl"))
```

- [ ] **Step 7: Reorder `collect_hints` and exclude import-statement identifiers**

In `src/StaticLint/linting/checks.jl`, `collect_hints`: swap the two branches of the `elseif !isquoted` arm so lint errors win over bare missing-refs, and exclude identifiers inside import statements from the missing-ref branch:

```julia
    elseif !isquoted
        if haserror(x, meta_dict) && errorof(x, meta_dict) isa StaticLint.LintCodes
            # collect lint hints
            push!(errs, (pos, x))
        elseif missingrefs != :none && isidentifier(x) && !hasref(x, meta_dict) &&
            !(valof(x) == "var" && parentof(x) isa EXPR && isnonstdid(parentof(x))) &&
            !((valof(x) == "stdcall" || valof(x) == "cdecl" || valof(x) == "fastcall" || valof(x) == "thiscall" || valof(x) == "llvmcall") && is_in_fexpr(x, x -> iscall(x) && isidentifier(x.args[1]) && valof(x.args[1]) == "ccall")) &&
            !in_macrocall_arg(x) &&
            # inside using/import statements the UnresolvedImport marking
            # pass is the sole reporter
            !is_in_fexpr(x, y -> headof(y) === :using || headof(y) === :import)
            push!(errs, (pos, x))
        end
```

- [ ] **Step 8: Gate on environment readiness in `src/layer_diagnostics.jl`**

In `_is_env_dependent_diagnostic`, after the `startswith(d.message, "Missing reference:")` line, add:

```julia
    startswith(d.message, "Failed to resolve `") && return true
```

- [ ] **Step 9: Run the tests, verify they pass**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved import" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS (all testitems from Tasks 1–2, including the tightened self-import one).

- [ ] **Step 10: Run neighboring regression tests**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="Diagnostics" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Then: `JW_TEST_FILTER="missing-refs" ...` (same command shape).
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/StaticLint/linting/checks.jl src/StaticLint/imports.jl src/layer_static_lint.jl src/layer_diagnostics.jl test/test_diagnostics.jl
git commit -m "feat: flag unresolvable imports with UnresolvedImport diagnostic

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Wildcard scope suppression

**Files:**
- Modify: `src/StaticLint/scope.jl` (Scope struct, lines 1–8)
- Modify: `src/StaticLint/imports.jl` (`mark_unresolved_import_stmt!` from Task 2)
- Modify: `src/StaticLint/linting/checks.jl` (`collect_hints` missing-ref branch, new helper)
- Test: `test/test_diagnostics.jl` (append)

**Interfaces:**
- Consumes: `mark_unresolved_import_stmt!` (Task 2), `retrieve_scope`, `parentof(::Scope)`.
- Produces: `Scope.unresolved_wildcard_import::Bool` field (default `false`), `in_unresolved_wildcard_import_scope(x::EXPR, meta_dict) -> Bool` in checks.jl.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_diagnostics.jl`:

```julia
@testitem "unresolved wildcard using: bare missing refs suppressed in scope" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresWild"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee28"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresWild
    using NotARealPackage
    function f(x)
        some_unknown_export(x) + another_mystery
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreswild/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswild/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswild/src/UnresWild.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreswild/src/UnresWild.jl"))

    @test !any(d -> startswith(d.message, "Missing reference"), diags)
    @test count(d -> startswith(d.message, "Failed to resolve `NotARealPackage`"), diags) == 1
end

@testitem "unresolved wildcard using: sibling and nested modules" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresWildMod"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee29"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresWildMod
    module Inner1
    using NotARealPackage
    f() = mystery_name()
    end
    module Inner2
    g() = obvious_typo()
    end
    module Inner3
    using NotARealPackage
    module Nested
    h() = nested_typo()
    end
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreswildmod/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswildmod/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswildmod/src/UnresWildMod.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreswildmod/src/UnresWildMod.jl"))

    # Inner1: suppressed by its own unresolved wildcard using
    @test !any(d -> d.message == "Missing reference: mystery_name", diags)
    # Inner2: no unresolved using -> still checked
    @test any(d -> d.message == "Missing reference: obvious_typo", diags)
    # Nested module inside Inner3 does NOT inherit the suppression
    @test any(d -> d.message == "Missing reference: nested_typo", diags)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved wildcard" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: FAIL — "Missing reference: some_unknown_export" etc. still produced.

- [ ] **Step 3: Add the Scope field**

In `src/StaticLint/scope.jl` replace the struct and convenience constructor:

```julia
mutable struct Scope
    parent::Union{Scope,Nothing}
    expr::EXPR
    names::Dict{String,Binding}
    modules::Union{Nothing,Dict{Symbol,Any}}
    overloaded::Union{Dict,Nothing}
    # a wildcard `using X` in this scope failed to resolve: any unresolved
    # identifier in this scope could be an export of the unknown module
    unresolved_wildcard_import::Bool
end
Scope(parent, expr, names, modules, overloaded) = Scope(parent, expr, names, modules, overloaded, false)
Scope(expr) = Scope(nothing, expr, Dict{Symbol,Binding}(), nothing, nothing)
```

(The three 5-positional-arg call sites — `src/StaticLint/StaticLint.jl:233`, `src/StaticLint/macros.jl:34`, `src/layer_static_lint.jl:346` — keep working through the new 5-arg outer constructor.)

- [ ] **Step 4: Set the flag in the marking pass**

In `mark_unresolved_import_stmt!` (Task 2, `src/StaticLint/imports.jl`), extend the non-colon loop:

```julia
        for path in x.args
            failed = first_unresolved_import_component(path, meta_dict)
            failed === nothing && continue
            seterror!(failed, UnresolvedImport, meta_dict)
            if headof(x) === :using
                # wildcard using of an unknown module: suppress bare
                # missing-ref reporting in this scope (see collect_hints)
                scope = retrieve_scope(x, meta_dict)
                scope isa Scope && (scope.unresolved_wildcard_import = true)
            end
        end
```

- [ ] **Step 5: Consume the flag in `collect_hints`**

In `src/StaticLint/linting/checks.jl` add:

```julia
# Is `x` inside a scope whose missing-ref checks are disabled by an
# unresolved wildcard `using`? Stops at module boundaries, mirroring
# `resolve_ref`: a nested `module` does not inherit its parent's usings.
function in_unresolved_wildcard_import_scope(x::EXPR, meta_dict)
    sc = retrieve_scope(x, meta_dict)
    while sc isa Scope
        sc.unresolved_wildcard_import && return true
        CSTParser.defines_module(sc.expr) && return false
        sc = parentof(sc)
    end
    return false
end
```

and append to the missing-ref branch conditions in `collect_hints` (after the `!is_in_fexpr(... :using ... :import)` line from Task 2):

```julia
            !in_unresolved_wildcard_import_scope(x, meta_dict)
```

- [ ] **Step 6: Run the tests, verify they pass**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="unresolved" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS (all testitems from Tasks 1–3).

- [ ] **Step 7: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/StaticLint/scope.jl src/StaticLint/imports.jl src/StaticLint/linting/checks.jl test/test_diagnostics.jl
git commit -m "feat: suppress missing refs in scopes with unresolved wildcard usings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Flip the `missing-refs` default to `"all"`

**Files:**
- Modify: `src/layer_diagnostics.jl` (`_missingrefs_from_config`, ~line 103)
- Test: `test/test_diagnostics.jl` (append)

**Interfaces:**
- Consumes: everything above.
- Produces: default missing-refs level `:all` (both for absent config and as the invalid-value fallback).

- [ ] **Step 1: Write the failing test**

Append to `test/test_diagnostics.jl`:

```julia
@testitem "missing-refs: default is all (getfield refs checked)" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "MissRefAll"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2a"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module MissRefAll
    using NotARealPackage
    function f()
        Base.this_name_surely_does_not_exist_xyz
    end
    end
    """

    # Default config: getfield refs into resolved modules are checked, even
    # though an unresolved wildcard using suppresses bare missing refs here
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///missrefall/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///missrefall/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///missrefall/src/MissRefAll.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///missrefall/src/MissRefAll.jl"))
    @test any(d -> d.message == "Missing reference: this_name_surely_does_not_exist_xyz", diags)

    # With missing-refs = "symbols", the getfield ref is not checked
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///missrefall2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/src/MissRefAll.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/JuliaLint.toml"), SourceText("missing-refs = \"symbols\"", "toml")))
    JuliaWorkspaces.set_input_env_ready!(jw2.runtime, true)

    diags2 = get_diagnostic(jw2, URI("file:///missrefall2/src/MissRefAll.jl"))
    @test !any(d -> d.message == "Missing reference: this_name_surely_does_not_exist_xyz", diags2)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="default is all" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: FAIL — the first `@test` fails because the default is still `"symbols"`.

- [ ] **Step 3: Flip the default**

In `src/layer_diagnostics.jl` replace `_missingrefs_from_config`:

```julia
function _missingrefs_from_config(lint_config::Dict)
    val = get(lint_config, "missing-refs", "all")
    val == "none" && return :none
    val == "symbols" && return :id
    val == "all" && return :all
    return :all  # fallback
end
```

Also update the now-stale comment in the existing testitem `"missing-refs: none suppresses vs default allows (with env_ready)"` in `test/test_diagnostics.jl`: change `# With env_ready = true and default missing-refs ("symbols"), missing refs should appear` to `# With env_ready = true and default missing-refs ("all"), missing refs should appear`.

- [ ] **Step 4: Run the tests, verify they pass**

Run: `cd /home/pfitzseb/git/julia-vscode && JW_TEST_FILTER="missing-refs" julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/layer_diagnostics.jl test/test_diagnostics.jl
git commit -m "feat: default missing-refs lint level to all

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Full-suite validation

**Files:**
- Possibly modify: any test with changed expectations (report each; do not silently weaken assertions).

- [ ] **Step 1: Run the full JuliaWorkspaces suite**

Run: `cd /home/pfitzseb/git/julia-vscode && julia --project=. scripts/packages/JuliaWorkspaces/test/runtests.jl`
Expected: PASS. This is slow (tens of minutes); let it finish.

Failure triage guidance:
- Failures mentioning "Missing reference" in *existing* tests are most likely caused by the `:all` default now checking getfield refs (`Foo.bar`) — inspect whether the test source genuinely contains an unknown getfield name. If the diagnostic is correct, update the test expectation; if it is a false positive, STOP and report — do not paper over it.
- Failures in navigation/hover/completion tests would point at synthetic bindings leaking somewhere unexpected — STOP and report; do not fix ad hoc.

- [ ] **Step 2: Run the LanguageServer test suite (JuliaWorkspaces consumer)**

Run: `cd /home/pfitzseb/git/julia-vscode && julia --project=. scripts/packages/LanguageServer/test/runtests.jl`
Expected: PASS. Note: the LanguageServer submodule currently has unrelated in-flight modifications — do not touch its source; only report failures caused by the JuliaWorkspaces changes.

- [ ] **Step 3: Commit any test-expectation updates**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add -u test/
git commit -m "test: update expectations for missing-refs all default

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Skip if nothing changed.)
