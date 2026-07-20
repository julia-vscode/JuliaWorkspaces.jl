# Inventories Milestone 3: `derived_file_analysis` — per-file semantics

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The per-file semantic layer: run StaticLint's single-file traversal against a module-tree-backed resolution context instead of the shared cross-file scope graph, producing per-file meta, a plain-data outbound-reference table, and per-file lint diagnostics — so a body edit re-analyzes exactly one file. No production consumer migrates yet (that is Milestone 4); this milestone lands the layer plus its acceptance proof.

**Architecture:** Three pieces. (1) *Selector queries* over the module tree — the value-level cutoff seam mandated by M2's final review: an id-free `derived_module_names` (name→kind) that survives item-id shifts, and id-carrying/import/export selectors for request-time needs. (2) A *tree resolution context*: a new value type that `resolve_ref_from_module` and `_get_field` learn to resolve through — visible names come from the module's declared names plus its classified imports (tree-module exports via selectors; workspace-package root exports cross-root; `:external` imports through the env stores at this layer, where env use is finally legitimate). Tree-resolved references get a new lightweight ref target carrying `(ItemRef, name, kind)` — never a live `Binding` from another file's analysis. (3) A *per-file traversal mode*: `Toplevel` gains a mode in which `followinclude` is inert and the file's top-level scope is parented to the tree context for the module path `tree.file_modules[file]`; `derived_file_analysis(rt, root, file)` runs it and freezes the outputs.

**Tech Stack:** Julia; JuliaWorkspaces (branch `sp/inventories`), StaticLint (vendored inside it), Salsa + TraceLogging, AutoHashEquals, TestItemRunner.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-16-inventory-architecture-design.md`, section "Layer 3". Read it first.
- Repo: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces`, branch `sp/inventories`. Commit there; do NOT push. The user's two pre-existing uncommitted files (`src/types.jl`, `src/layer_static_lint.jl`) must never appear in commits.
- Run Julia ONLY via `mcp__julia__julia_eval` (env_path=/home/pfitzseb/git/julia-vscode/scripts/environments/development); `import Revise, TestItemRunner` FIRST in fresh sessions; NEVER CLI julia. Struct/const changes require `mcp__julia__julia_restart`. JuliaWorkspaces is also dev'ed in the global env, so ad-hoc `@run_package_tests filter=...` works; full-suite gates still use the canonical `include("test/runtests.jl")` (baseline at milestone start: **4871 pass / 0 fail / 1 pre-existing Runic error / 7 pre-existing broken**).
- Layer discipline: selector queries depend only on `derived_module_tree`. The visibility/analysis queries MAY depend on `derived_environment` (this is the sanctioned env seam — note their values must still be meaningful under `isequal`, so **never store `ModuleStore`/`ExternalEnv` objects inside a derived value**; extract plain data such as `Vector{Symbol}` of exported names at query time). Nothing in this milestone may depend on `derived_item_positions`.
- The old pass (`derived_static_lint_meta_for_root` and everything under it) stays untouched and green — it is still the production path and the differential oracle.
- Ref-target rule (spec's `Binding.val` plumbing): references resolved through the tree must NOT point at `Binding`/`EXPR` objects from other files' analyses. They carry plain `(ItemRef, name, kind)` data; EXPR materialization is request-time work via `derived_item_positions` (Milestone 4).
- Do NOT "fix" import anchoring to real-Julia semantics — the outward walk deliberately matches StaticLint (see the rule-2 NOTE in `layer_module_tree.jl`).
- Commit messages: conventional commits, no issue refs, backtick macro names.

## Carried-over parity ledger (Task 1)

From M1/M2 final reviews, all additive to `layer_inventory.jl`:
(a) destructuring splats (`a, b... = f()`), nested tuples, and property destructuring (`(; a, b) = cfg` — `:tuple` with a `:parameters` child) — StaticLint binds all of these at module level (`mark_binding!`, StaticLint/bindings.jl:131-151); the inventory handles plain identifiers only;
(b) the duplicate-include single-splice divergence gets a sentence in the spec's compatibility section (sanctioned-change list);
(c) the no-op-update zero-execution acceptance test (update a file with IDENTICAL content → zero re-executions anywhere, TraceLogging);
(d) a one-line comment on the trace-baseline pattern where M3's acceptance tests copy the CountReceiver scaffolding.

---

### Task 1: Parity ledger openers

**Files:** Modify `src/layer_inventory.jl`, `docs/superpowers/specs/2026-07-16-inventory-architecture-design.md`; test `test/test_inventory.jl`.

- [ ] **Step 1 (TDD for (a)):** failing testitem "inventory parity: destructuring splats, nested tuples, property forms" — `a, b... = f()` → items "a", "b" (shared id); `(x, (y, z)) = w` → "x","y","z"; `(; f1, f2) = cfg` → "f1","f2"; `const` variants. Explore the CST shapes first (`:tuple` heads, `:...` splat wrapper, `:parameters` child); mirror `mark_binding!`'s recursion (bindings.jl:131-151).
- [ ] **Step 2:** RED → implement in the tuple-destructuring arm → GREEN.
- [ ] **Step 3 ((b)+(d)):** spec sentence in the compatibility contract section: "Sanctioned divergence: a file included from two places is spliced once, at its first include site in source order (Julia splices twice); the DuplicateInclude diagnostic already flags such code." Comment on the trace-baseline pattern added where Task 6 will copy it (leave a `# NOTE(trace-baseline):` in the existing module-tree acceptance testitem).
- [ ] **Step 4 ((c)):** acceptance testitem "no-op update: identical content re-executes nothing downstream" — `update_file!` with byte-identical content; TraceLogging asserts `derived_file_inventory` executes once (content input changed) and `derived_module_tree` + a probe execute zero times.
- [ ] **Step 5:** inventory filter green; commit `fix: close destructuring parity gaps and document sanctioned include divergence`.

---

### Task 2: Per-module selector queries (the cutoff seam)

**Files:** Modify `src/layer_module_tree.jl` (append); test `test/test_module_tree.jl`.

**Interfaces (produces):**
- `derived_module_names(rt, root, path::Vector{String}) -> Dict{String,Symbol}` — name → kind for the module's declared names. **Id-free**: this is what analysis resolves against, and its value survives item-id shifts (the M2 review's key demand).
- `derived_module_declared(rt, root, path) -> Dict{String,ItemRef}` — id-carrying, for request-time materialization (M4).
- `derived_module_exports(rt, root, path) -> @NamedTuple{exports::Vector{String}, publics::Vector{String}}`.
- `derived_module_imports(rt, root, path) -> Vector{ResolvedImport}`.
- All are thin `Salsa.@derived` projections of `derived_module_tree(rt, root)` (the `derived_includes`-selector pattern, layer_includes.jl docstring); missing module path → empty values, plain data throughout.

- [ ] **Step 1 (TDD):** failing testitem "module selectors: projections and id-shift survival" — fixture package; assert each selector's content; then the load-bearing assertion: **insert a new top-level item mid-file above existing ones** (shifts ids → tree value changes) and prove via TraceLogging that a probe consuming `derived_module_names` does NOT re-execute (names/kinds unchanged) while a probe consuming `derived_module_declared` DOES (ItemRefs changed).
- [ ] **Step 2:** RED (UndefVarError) → implement → GREEN; module-tree filter green.
- [ ] **Step 3:** commit `feat: add per-module selector queries as the analysis cutoff seam`.

---

### Task 3: Module visibility — names reachable through imports

**Files:** Modify `src/layer_module_tree.jl` or new `src/layer_visibility.jl` (implementer's call; if new file, include it after layer_module_tree.jl); test `test/test_module_tree.jl` (append).

**Interfaces (produces):** `derived_module_visible_names(rt, root, path) -> Dict{String,VisibleName}` where
```julia
@auto_hash_equals struct VisibleName
    kind::Symbol          # item kind, or :module for modules, or :external_symbol
    origin::Symbol        # :declared | :using_tree | :using_workspace_package | :using_external | :import_binding
    item::Union{Nothing,ItemRef}          # for tree-declared names (from derived_module_declared of the ORIGIN module)
    origin_module::Vector{String}         # tree path / [package] / external path segments
end
```
Semantics (normative):
1. Start from the module's own `derived_module_names`/`derived_module_declared` (origin `:declared`).
2. For each `ResolvedImport` of the module (from `derived_module_imports`):
   - `kind == :import` with symbols/alias: bind exactly the listed names (alias wins) — origin `:import_binding`.
   - `kind == :using`, target `:tree`: bring in the target module's **exported** names (its `derived_module_exports` ∩ its `derived_module_names`), plus the target module's own name.
   - target `:workspace_package`: resolve cross-root — `derived_workspace_package_roots(rt)[pkg]` gives the entry file; the package's top module path in ITS tree is `[pkg]`; bring in `derived_module_exports(rt, entry, [pkg])`-gated names (and for sub-paths `["Pkg","Sub"]`, the corresponding sub-module). Guard cross-root recursion with a visited set (packages can circularly dev each other) — on a cycle, skip with origin recorded as unresolved.
   - target `:external`: consult `derived_environment(rt, derived_project_uri_for_root(rt, root))` — if `haskey(env.symbols, Symbol(first_segment))`, walk sub-segments through the `ModuleStore` and bring in `mod_store.exportednames` as `:external_symbol` entries (plain Symbols extracted — NEVER store the ModuleStore). Missing module → contribute nothing (missing-ref lint parity comes from the analysis, not here).
   - target `:unresolved`: **the M2 ledger case** — re-attempt resolution here where more context exists: if the path's post-anchor first segment names a VISIBLE name in the anchor module whose origin is an import of a module (the `using ..SymbolServer` pattern), resolve through that; implementers: iterate to a small fixed depth (2 passes) rather than a full fixpoint, and document.
3. Precedence on collision: declared > import_binding > using-derived (matches Julia: explicit bindings shadow `using`).
- Also produce `derived_module_self_and_parents(rt, root, path) -> Vector{Vector{String}}` (the enclosing-module chain, for the shim's outward walk).

- [ ] **Step 1 (TDD):** failing tests: declared shadowing a using'd name; `using .Child` exports visible; `import Foo.Bar as FB` binds FB only; workspace package exports visible cross-root; circular dev'ed packages terminate; external `using Base64` brings `base64encode` (env-backed — this test needs a real env: use `derived_environment(rt, nothing)`'s stdlib-only store, which contains Base64? verify; if not, pick a stdlib present in `SymbolServer.stdlibs`); and the ledger case: parent module does `using ..SymbolServer`-style import of an external module, child does `using ..SymbolServer` → resolves via pass-2 re-attempt.
- [ ] **Step 2:** RED → implement → GREEN; filters green. **Step 3:** commit `feat: compute per-module visible names through classified imports`.

---

### Task 4: The tree resolution context + per-file traversal mode

**Files:** Modify `src/StaticLint/StaticLint.jl` (Toplevel mode flag), `src/StaticLint/references.jl` (+1 `resolve_ref_from_module` method), `src/StaticLint/imports.jl` (+`_get_field` method), new `src/layer_file_analysis.jl` (context type + plumbing; include after the visibility layer); tests in new `test/test_file_analysis.jl`.

**Interfaces (produces):**
- `TreeModuleContext` (in `layer_file_analysis.jl`): holds `rt`, `root::URI`, `path::Vector{String}` — a RESOLUTION HANDLE, deliberately not plain data (it is never stored in a derived value; it lives only inside a running analysis, like `Toplevel.runtime` does today).
- `StaticLint.resolve_ref_from_module(x, ctx::TreeModuleContext, state) -> Bool`: looks up the name in `derived_module_visible_names(ctx.rt, ctx.root, ctx.path)`; on hit, `setref!` with a **`TreeRef`** — new plain-data ref target `@auto_hash_equals struct TreeRef; name::String; kind::Symbol; item::Union{Nothing,ItemRef}; origin_module::Vector{String}; end` (defined in StaticLint so `Meta.ref::Union{Nothing,Binding,SymbolServer.SymStore}` widens to include it — widen that field's type annotation and audit `refof` consumers in StaticLint itself for exhaustive dispatch; production request handlers are M4's problem, but StaticLint-internal consumers like `check_call`/`collect_hints` run in THIS milestone's pass and must at minimum not crash on a `TreeRef` — `hasref` is what missing-ref lint checks, and it only tests presence).
- `StaticLint._get_field(par::TreeModuleContext, arg, state)` for import resolution inside the per-file pass (imports in the analyzed file re-resolve through the tree context rather than scope walks).
- Per-file mode: `Toplevel` gains `follow_includes::Bool` (default `true`; constructors updated) — `followinclude` returns immediately when false. The file's root scope construction for the per-file pass: `semantic_pass` gains kwarg `module_context::Union{Nothing,TreeModuleContext}=nothing`; when given, the seeded root scope's `.modules` Dict contains `:__tree__ => module_context` **in addition to** Base/Core stores (so `resolve_ref`'s existing scope.modules loop reaches it with zero changes to the loop), and `follow_includes=false`.

Normative behavior: names not local to the file resolve in this order (all falling out of existing mechanics): file-local scopes → Base/Core stores → the tree context (module-visible names). Module-boundary semantics inside the file (nested modules declared IN the analyzed file) work as today — a nested module's scope stops the parent walk, and its `using`s resolve via `_get_field(::TreeModuleContext, ...)` when they reference tree paths (construct child contexts with the nested path).

- [ ] **Step 1 (TDD):** failing tests (drive via a raw `semantic_pass` call with `module_context`, before the derived query exists): reference to a sibling-file name gets a `TreeRef` with the right ItemRef; reference to a `using`'d external name gets a TreeRef with kind `:external_symbol`; unresolved name has no ref (missing-ref parity); `follow_includes=false` → an `include("x.jl")` statement in the file does NOT pull x.jl's names into the local scope (they come from the tree instead — assert the ref on a name declared in x.jl is a TreeRef, not a Binding); a module declared inside the analyzed file resolves its own names locally.
- [ ] **Step 2:** RED → implement → GREEN; the FULL staticlint + lint filter must stay green (the old pass must be unaffected — `follow_includes` defaults true, `module_context` defaults nothing, `Meta.ref` widening is additive).
- [ ] **Step 3:** commit `feat: add the tree resolution context and per-file traversal mode`.

---

### Task 5: `derived_file_analysis(rt, root, file)`

**Files:** Modify `src/layer_file_analysis.jl`; test `test/test_file_analysis.jl` (append).

**Interfaces (produces):**
```julia
@auto_hash_equals struct OutboundRef
    name::String
    target::Union{Nothing,ItemRef}   # nothing for external/env targets
    origin_module::Vector{String}
    count::Int                        # occurrences in this file (positions are request-time work)
end

# NOT @auto_hash_equals for meta (it holds EXPR-keyed local meta — identity is fine
# and intended: the value is keyed on this file's content):
struct FileAnalysis
    meta::Dict{UInt64,StaticLint.Meta}       # local scopes/bindings/refs, THIS file's EXPRs only
    outbound::Vector{OutboundRef}            # plain data, sorted by (name, origin_module)
    diagnostics::Vector{Diagnostic}          # per-file lint: check_all + local collect_hints
end
```
`Salsa.@derived derived_file_analysis(rt, root, file)`:
1. `path = derived_module_tree(rt, root).file_modules[file]` — NO: that depends on the whole tree value. Instead add a Task-2-style selector `derived_file_module_path(rt, root, file)` (id-free: `Union{Nothing,Vector{String}}`) and use it. Missing (file not spliced under this root) → empty analysis.
2. Build `TreeModuleContext(rt, root, path)`; run `semantic_pass(file, cst, env, meta, rt; module_context=ctx)` with `env = derived_environment(rt, derived_project_uri_for_root(rt, root))` (guard nothing → `derived_stdlib_only_env(rt)`).
3. Late passes: `resolve_remaining_getfields!` + `mark_unresolved_imports!` over this file only, then `check_all` with the root's lint config (mirror the per-file slice of `derived_static_lint_meta_for_root`'s tail, layer_static_lint.jl:154-169) and `collect_hints` for THIS file.
4. Extract `outbound` from the meta: every `TreeRef`-valued ref aggregated by (name, origin_module) with counts.
- Cutoff analysis (document in the docstring): the query depends on this file's CST + the id-free path selector + visible-names of the modules it touches + env. A body edit in a SIBLING file: inventory backdates → tree backdates → selectors backdate → this analysis untouched. A top-level edit in a sibling that doesn't change name/kind sets: `derived_module_names`/visible-names backdate → this analysis untouched (the id-shift survival from Task 2 pays off here). 

- [ ] **Step 1 (TDD):** failing tests: analysis of a file referencing sibling + external + undefined names — meta has refs, outbound has the sibling entry with ItemRef, diagnostics contain the missing-ref for the undefined name and NOT for the resolved ones; a file not in the root → empty analysis.
- [ ] **Step 2:** RED → implement → GREEN. **Step 3:** commit `feat: add per-file semantic analysis over the tree context`.

---

### Task 6: Invalidation acceptance (the milestone's point)

**Files:** test `test/test_file_analysis.jl` (append).

TraceLogging + probe, assertions (spec acceptance criteria — fix bugs under TDD, never weaken):
1. Body edit in file A ⇒ `derived_file_analysis(root, A)` re-executes; `derived_file_analysis(root, B)` zero; `derived_module_tree` zero.
2. Top-level edit in A that shifts ids but preserves name/kind sets (insert item mid-file with a NEW unique name — wait, that changes the name set; correct fixture: REORDER two adjacent same-kind items? ids swap, name set identical, kinds identical → `derived_module_names` backdates) ⇒ analysis of B zero re-executions, module tree re-executes once (value changed — ItemRefs), `derived_module_names` re-executes but backdates.
3. Adding an export/new name in A ⇒ analysis of B (which references it) re-executes and its missing-ref diagnostic disappears.
4. The keystroke-cost claim, measured: on a fixture with 10 files, body edit + re-pull all analyses ⇒ exactly 1 analysis execution.

- [ ] **Step 1:** write; **Step 2:** run (fix under TDD if red); **Step 3:** canonical full suite (baseline + all M3 tests, 0 fail); **Step 4:** commit `test: per-file analysis invalidation properties`.

---

### Task 7: Real-workspace smoke + mini-differential (report-only)

**Files:** none (fixes only if bugs surface).

- [ ] **Step 1:** on `/home/pfitzseb/git/JuliaWorkspaces.jl`: compute `derived_file_analysis` for every (root, file) pair of 3 representative roots (main src root, packages/JSON's root, a script root); report timing (expect per-file ms), outbound-ref totals, and TreeRef resolution rate.
- [ ] **Step 2: mini-differential:** for those roots, compare missing-ref diagnostic SETS per file against the old pass (`derived_static_lint_diagnostics`) — collect (file, message) pairs both ways; report the diff with each discrepancy triaged: new-architecture bug (fix under TDD) vs. known sanctioned divergence (cite which) vs. old-pass bug (document). This is the first real differential-harness data point; expect discrepancies from the known parity ledger — the triage list is the deliverable.
- [ ] **Step 3:** body-edit keystroke measurement on the real workspace: one file's analysis re-execution only, timed.

---

## Self-review notes (already applied)

- The M2 final review's two mandates are structural here: Task 2 is the selector seam (with the id-shift survival test), and Task 5 step 1 explicitly routes the file→path lookup through an id-free selector rather than the whole tree value.
- The env seam is now legitimately open (Global Constraints) with the one hard rule that derived values must never store `ModuleStore`/`ExternalEnv` — only extracted plain data.
- `TreeRef` widens `Meta.ref`'s type — the audit of StaticLint-internal `refof` consumers is inside Task 4's step 2 gate (old pass stays green), and production handlers are explicitly M4.
- The `:unresolved` re-attempt (Task 3 rule 2, imports-of-import-bound-names) is bounded (2 passes) rather than a fixpoint, with the 15/16 real-workspace cases as its acceptance target in Task 7's differential.
- `FileAnalysis.meta` deliberately skips `@auto_hash_equals` (EXPR-keyed; the value's identity semantics are correct because it's keyed on file content) — outbound/diagnostics are the plain-data faces other queries may consume.
