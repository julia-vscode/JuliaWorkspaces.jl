# Untitled-file Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show diagnostics for untitled (non-`file` scheme) Julia buffers, using the active project as their fallback environment.

**Architecture:** Two gates suppress diagnostics for non-file URIs today. Add a value-stable `derived_file_language_id` query, use it to (a) admit untitled Julia buffers as roots in `derived_julia_files` and (b) gate the Julia-content branches of `derived_diagnostics` by language instead of by `uri.scheme == "file"`. Config/TOML diagnostics stay file-only. The environment already resolves to the active project for path-less files, so no environment code changes.

**Tech Stack:** Julia, Salsa (incremental derived queries), TestItemRunner (`@testitem`).

## Global Constraints

- Run tests through the julia MCP dev-env session (`env=environments/development`); never spawn `julia` or `Pkg.test` directly.
- Focus a run by name with the `JW_TEST_FILTER` env var (see `test/runtests.jl`), or the dev-env `run_tests("test/<file>.jl"; filter="<name substring>")` helper.
- Restart the MCP session after editing structs; these tasks edit no structs.
- `@testitem` bodies need explicit imports — default usings do not apply under `@run_package_tests`. Import every symbol the body uses.
- Comments: terse; never reference this plan or the spec doc.
- Commit message trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- `src/layer_files.jl` — add `derived_file_language_id`; extend `derived_julia_files`.
- `src/layer_diagnostics.jl` — add `_is_julia_uri`; guard `derived_lint_configuration`; restructure `derived_diagnostics`.
- `test/test_diagnostics.jl` — new `@testitem`s for the behaviors above.

---

### Task 1: Language query + admit untitled Julia buffers as roots

**Files:**
- Modify: `src/layer_files.jl` (`derived_julia_files`, currently lines 8-13; add `derived_file_language_id`)
- Test: `test/test_diagnostics.jl` (append new `@testitem`)

**Interfaces:**
- Produces: `derived_file_language_id(rt, uri) -> Union{String,Nothing}` — the file's `SourceText.language_id`, or `nothing` when the file has no content. Value-stable (returns only the string).
- Produces: `derived_julia_files(rt) -> Set{URI}` now also contains non-`file` URIs whose language is `"julia"`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_diagnostics.jl`:

```julia
@testitem "derived_julia_files admits untitled Julia buffers, not markdown" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    jl = URI("untitled:Untitled-1")
    md = URI("untitled:Untitled-2")
    add_file!(jw, TextFile(jl, SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(md, SourceText("# hi\n", "markdown")))

    julia_files = JuliaWorkspaces.derived_julia_files(jw.runtime)

    @test jl in julia_files
    @test !(md in julia_files)

    # value-stable language query
    @test JuliaWorkspaces.derived_file_language_id(jw.runtime, jl) == "julia"
    @test JuliaWorkspaces.derived_file_language_id(jw.runtime, md) == "markdown"
end
```

- [ ] **Step 2: Run test to verify it fails**

In the julia MCP dev-env session:
```julia
run_tests("test/test_diagnostics.jl"; filter="derived_julia_files admits untitled")
```
Expected: FAIL — `derived_file_language_id` is undefined (`UndefVarError`) and/or `jl` is not in `julia_files`.

- [ ] **Step 3: Add `derived_file_language_id` and extend `derived_julia_files`**

In `src/layer_files.jl`, add after `derived_julia_files` (or adjacent to it):

```julia
Salsa.@derived function derived_file_language_id(rt, uri)
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    return tf.content.language_id
end
```

Replace `derived_julia_files` (lines 8-13) with:

```julia
Salsa.@derived function derived_julia_files(rt)
    files = derived_text_files(rt)

    # File-scheme URIs keep the cheap suffix check; non-file buffers (e.g.
    # untitled) are Julia when their language id says so. The language query is
    # value-stable, so a keystroke in an untitled buffer never invalidates the
    # root set.
    return Set{URI}(file for file in files if
        endswith(string(file), ".jl") ||
        (file.scheme != "file" && derived_file_language_id(rt, file) == "julia"))
end
```

- [ ] **Step 4: Run test to verify it passes**

```julia
run_tests("test/test_diagnostics.jl"; filter="derived_julia_files admits untitled")
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_files.jl test/test_diagnostics.jl
git commit -m "feat: admit untitled Julia buffers as roots

Add value-stable derived_file_language_id and include non-file URIs
whose language is julia in derived_julia_files, so an untitled buffer
becomes a root (prerequisite for static-lint on it).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Lift the scheme gate for Julia-content diagnostics

**Files:**
- Modify: `src/layer_diagnostics.jl` (`derived_lint_configuration` lines 66-87; `derived_diagnostics` lines 116-185; add `_is_julia_uri`)
- Test: `test/test_diagnostics.jl` (append new `@testitem`)

**Interfaces:**
- Consumes: `derived_file_language_id` (Task 1).
- Produces: `_is_julia_uri(rt, uri) -> Bool` — file-scheme `.jl` files, or non-file URIs whose language is `"julia"`.
- Behavior: `derived_diagnostics` now returns syntax / testitem / static-lint / include diagnostics for non-file Julia buffers; TOML/config diagnostics remain file-only. `derived_lint_configuration` returns an empty `Dict` for non-file URIs.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_diagnostics.jl`:

```julia
@testitem "Untitled Julia buffer reports syntax diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    uri = URI("untitled:Untitled-1")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "julia")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 1
    @test diags[1].severity == :error
    @test diags[1].source == "JuliaSyntax.jl"
end

@testitem "Untitled markdown buffer reports no diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    uri = URI("untitled:Untitled-2")
    jw = JuliaWorkspace()
    # Content that is a Julia syntax error but the buffer is markdown: it must
    # not be parsed as Julia, so no diagnostics.
    add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "markdown")))

    diags = get_diagnostic(jw, uri)

    @test isempty(diags)
end
```

- [ ] **Step 2: Run tests to verify they fail**

```julia
run_tests("test/test_diagnostics.jl"; filter="Untitled Julia buffer reports syntax")
run_tests("test/test_diagnostics.jl"; filter="Untitled markdown buffer reports no")
```
Expected: the syntax test FAILS (`length(diags) == 1` is `0` — non-file URI currently returns empty). The markdown test may already pass; keep it as a regression guard.

- [ ] **Step 3: Add `_is_julia_uri` and guard `derived_lint_configuration`**

In `src/layer_diagnostics.jl`, add near the top helpers (e.g. after `_is_env_dependent_diagnostic`):

```julia
# A URI whose content should be treated as Julia: a file-scheme `.jl` path, or
# a non-file buffer (e.g. untitled) whose language id is "julia".
function _is_julia_uri(rt, uri)
    if uri.scheme == "file"
        return is_path_julia_file(uri2filepath(uri))
    else
        return derived_file_language_id(rt, uri) == "julia"
    end
end
```

Guard `derived_lint_configuration` — add as its first line (after the `@debug`):

```julia
    # Non-file buffers have no folder-based config; defaults apply.
    uri.scheme == "file" || return Dict{String,Any}()
```

- [ ] **Step 4: Restructure `derived_diagnostics`**

Replace the body of `derived_diagnostics` (from `lint_config = ...` through `return results`) with:

```julia
    lint_config = derived_lint_configuration(rt, uri)

    results = Diagnostic[]

    # Julia-content diagnostics run for file-scheme .jl files AND non-file
    # (e.g. untitled) buffers whose language is julia.
    if _is_julia_uri(rt, uri)
        if get(lint_config, "syntax-errors", true) == true || get(lint_config, "syntax-warnings", false) == true
            syntax_diagnostics = derived_julia_syntax_diagnostics(rt, uri)

            if get(lint_config, "syntax-errors", true) == true
                append!(results, i for i in syntax_diagnostics if i.severity==:error)
            end

            if get(lint_config, "syntax-warnings", false) == true
                append!(results, i for i in syntax_diagnostics if i.severity==:warning)
            end
        end

        if get(lint_config, "testitem-errors", true) == true
            tis = derived_testitems(rt, uri)
            append!(results, Diagnostic(i.range, :error, i.message, nothing, Symbol[], "Testitem") for i in tis.testerrors)
        end

        if get(lint_config, "static-lint", true) == true
            sl = derived_new_static_lint_diagnostics(rt, uri)
            env_ready = derived_file_env_ready(rt, uri)
            if env_ready
                append!(results, sl)
            else
                append!(results, d for d in sl if !_is_env_dependent_diagnostic(d))
            end

            # Include-graph diagnostics (DuplicateInclude / IncludeLoop /
            # MissingFile) are a purely structural analysis that does not depend
            # on a project/environment, so they are reported independently of the
            # semantic static-lint pass above.
            append!(results, derived_include_diagnostics(rt, uri))
        end
    end

    # Config/TOML diagnostics are filesystem-file only.
    if uri.scheme == "file"
        if (is_path_lintconfig_file(uri2filepath(uri)) || is_path_formatconfig_file(uri2filepath(uri)) || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri)) ) && get(lint_config, "toml-syntax-errors", true) == true
            toml_syntax_errors = derived_toml_syntax_diagnostics(rt, uri)
            append!(results, toml_syntax_errors)
        end

        if is_path_lintconfig_file(uri2filepath(uri)) && get(lint_config, "lint-config-errors", true) == true
            lint_config_errors = derived_lintconfig_diagnostics(rt, uri)
            append!(results, lint_config_errors)
        end

        if is_path_formatconfig_file(uri2filepath(uri)) && get(lint_config, "format-config-errors", true) == true
            format_config_errors = derived_formatconfig_diagnostics(rt, uri)
            append!(results, format_config_errors)
        end
    end

    return results
```

Leave the two early guards above `lint_config` (`derived_is_indirect_file` and the `derived_text_files` membership check) unchanged.

- [ ] **Step 5: Run the new tests and the full diagnostics file**

```julia
run_tests("test/test_diagnostics.jl"; filter="Untitled Julia buffer reports syntax")
run_tests("test/test_diagnostics.jl"; filter="Untitled markdown buffer reports no")
run_tests("test/test_diagnostics.jl")
```
Expected: the two new tests PASS; the full `test_diagnostics.jl` run stays green (regression check for the restructure — file-scheme behavior is unchanged).

- [ ] **Step 6: Commit**

```bash
git add src/layer_diagnostics.jl test/test_diagnostics.jl
git commit -m "feat: report diagnostics for untitled Julia buffers

Gate the Julia-content diagnostics (syntax, testitems, static-lint,
include) on language rather than uri.scheme==file, and skip folder-based
lint config for non-file URIs. Config/TOML diagnostics stay file-only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Static-lint on an untitled buffer via the fallback (active) project

**Files:**
- Test only: `test/test_diagnostics.jl` (append new `@testitem`)

**Interfaces:**
- Consumes: Task 1 (untitled buffer is a root) + Task 2 (gate lifted). No new production code — the environment already resolves a path-less file to `input_active_project` in `derived_project_uri_for_root`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_diagnostics.jl` (mirrors the loose-file active-project pattern at the end of this file, using an untitled URI):

```julia
@testitem "Untitled buffer uses active project as fallback environment" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText,
        set_active_project!, set_input_env_ready!, derived_project_uri_for_root
    using JuliaWorkspaces.URIs2: URI

    env_dir = URI("file:///env")
    uri = URI("untitled:Untitled-1")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///env/Project.toml"), SourceText("""
    name = "Env"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0013"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///env/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(uri, SourceText("import JSON\n", "julia")))
    set_active_project!(jw, env_dir)
    set_input_env_ready!(jw.runtime, true)

    # The untitled buffer's project is the active project (fallback env).
    @test derived_project_uri_for_root(jw.runtime, uri) == env_dir

    # With the env ready, the unresolvable package import now flags.
    diags = get_diagnostic(jw, uri)
    @test any(d -> d.source == "StaticLint.jl", diags)
    @test any(d -> occursin("JSON", d.message), diags)
end
```

- [ ] **Step 2: Run test to verify it passes**

```julia
run_tests("test/test_diagnostics.jl"; filter="Untitled buffer uses active project")
```
Expected: PASS (Tasks 1 and 2 already provide the behavior; this test locks it in). If it FAILS on the diagnostic assertions, confirm Tasks 1 and 2 are committed and the session was restarted after their edits.

- [ ] **Step 3: Commit**

```bash
git add test/test_diagnostics.jl
git commit -m "test: static-lint on untitled buffer via active-project fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Run the full diagnostics and testitems suites**

```julia
run_tests("test/test_diagnostics.jl")
run_tests("test/test_testitems.jl")
```
Expected: both green. `test_testitems.jl` includes the existing untitled-URI test from commit 28f54e9, which must still pass.
