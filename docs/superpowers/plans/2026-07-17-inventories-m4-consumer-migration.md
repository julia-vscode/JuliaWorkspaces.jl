# Inventories Milestone 4: consumer migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate every production consumer of the whole-closure StaticLint pass onto the per-file queries (`derived_file_analysis`, module-tree selectors, `derived_item_positions`), in the spec's order — diagnostics → completions → signatures → hover → definitions → references/rename/highlights → symbols → actions/inlay hints — so the ~7 ms keystroke cost becomes user-visible and the old pass loses its last caller (deletion itself is Milestone 5).

**Architecture:** Request handlers stop reading the merged cross-file `meta_dict` and instead compose three sources: (1) `derived_file_analysis(rt, root, uri).meta` for everything anchored to the current file's EXPRs (scope chains, local bindings, refs); (2) module-tree/visibility selectors for module-level name sets (completions, import placement); (3) `derived_item_positions(rt, uri)` at the last mile to materialize an `ItemRef` into an EXPR/offset (definitions, hover docs, reference locations). Cross-file "who references X" is a request-time aggregation over per-file `outbound` tables joined on `target::ItemRef`.

**Tech Stack:** Julia; JuliaWorkspaces (branch `sp/inventories`), StaticLint (vendored), Salsa + TraceLogging, AutoHashEquals, TestItemRunner.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-16-inventory-architecture-design.md` — "Aggregations", "Position reattachment", "Migration shape" step 4, compatibility contract + sanctioned-divergence list. Read first.
- Repo: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces`, branch `sp/inventories` (M4 starts at `9d8ffca`). Commit there; do NOT push. The user's two pre-existing uncommitted files (`src/types.jl`, `src/layer_static_lint.jl`) must never appear in commits.
- Run Julia ONLY via `mcp__julia__julia_eval` (env_path=/home/pfitzseb/git/julia-vscode/scripts/environments/development); `import Revise, TestItemRunner` FIRST in fresh sessions; NEVER CLI julia. Struct/const changes require `mcp__julia__julia_restart`. File edits with Edit/Write tools only — never sed or python scripts.
- Canonical full-suite baseline at milestone start: **5197 pass / 0 fail / 1 pre-existing Runic error / 7 pre-existing broken** (canonical entry: `cd` package dir + `include("test/runtests.jl")`).
- **The suite is the migration contract.** The per-feature test files (test_completions.jl 22, test_hover.jl 12, test_references.jl 9, test_signatures.jl 9, test_diagnostics.jl 39, staticlint/* 217, test_symbols.jl 3, test_actions.jl 8, test_navigation.jl 3, test_misc.jl 7, test_typeinf.jl 11) currently exercise the OLD path; after each task they exercise the NEW path. Every changed assertion goes into the change-list (`docs/superpowers/specs/…` compatibility section reviews them) with a one-line justification. Known non-gold old-pass outputs (do NOT chase parity with these; cite the ledger): getfield-RHS hints (verified old false positive `unique_files` IS a `FrameCode` field), the 4 wp-import "could not be indexed" statement warnings, the 8 method-call-error pairs (F2 sanctioned conservatism).
- The old pass (`derived_static_lint_meta_for_root` + its diagnostics queries) stays compiling and its own unit tests green until Milestone 5. Consumers leave it one task at a time.
- Derived values stay plain data: never store `ModuleStore`/`ExternalEnv`/`TreeModuleContext`/live foreign `Binding`/`EXPR` in a derived value. Request-time aggregation helpers may hold anything while running.
- **Join on `target::ItemRef`, never on row name** when aggregating outbound tables (cross-file aliases surface under the BOUND name with the source's ItemRef as target; same-file aliases under the source name — `_collect_outbound` docstring).
- Visibility dicts include each module's self-binding (`Foo` visible in `module Foo`, kind `:module`, origin `:declared`) — consumers must tolerate it (it is correct Julia).
- Macro names are `@`-prefixed everywhere (inventory, selectors, visibility, exports).
- Commit messages: conventional commits, no issue refs, backtick macro names.

## Shared interfaces (produced by M1–M3, consumed throughout)

- `derived_file_analysis(rt, root::URI, file::URI) -> FileAnalysis` with `meta::Dict{UInt64,StaticLint.Meta}` (this file's EXPRs only; scopes stripped of `:__tree__` contexts), `outbound::Vector{OutboundRef}` (`name::String, target::Union{Nothing,ItemRef}, origin_module::Vector{String}, count::Int`, sorted by (name, origin_module)), `diagnostics::Vector{Diagnostic}`.
- `derived_file_module_path(rt, root, file) -> Union{Nothing,Vector{String}}` (id-free), `derived_module_visible_names(rt, root, path) -> Dict{String,VisibleName}` (full, ItemRef-carrying — request-time use is fine), `derived_module_visible_names_idfree`, `derived_visible_item(rt, root, path, name)`, `derived_module_names`, `derived_module_declared`, `derived_module_exports`, `derived_module_self_and_parents`, `derived_workspace_package_roots(rt)`, `derived_module_exists`, `derived_module_declared_at`.
- `derived_file_inventory(rt, uri) -> FileInventory` (items with `id, name, qualifier, kind, signature, field_names, parent_module`), `derived_item_positions(rt, uri) -> Dict{Int, @NamedTuple{expr::EXPR, offset::Int}}` (volatile leaf; nothing in layers 1–3 depends on it — request handlers only).
- `ItemRef = @NamedTuple{file::URI, id::Int}`; `TreeRef` (StaticLint): `name::String, kind::Symbol, item::Union{Nothing,ItemRef}, origin_module::Vector{String}` — appears as `Meta.ref` and as `Binding.val` in per-file metas; kind `:external_module` marks env-module stand-ins.
- Old-pass shapes still present until M5: `derived_static_lint_meta_for_root(rt, root) -> (meta_dict, workspace_packages)`, `derived_static_lint_diagnostics(rt, uri) -> Set{Diagnostic}`, `derived_static_lint_diagnostics_for_root(rt, root) -> Dict{URI,Set{Diagnostic}}`.

---

### Task 1: Qualified-use resolution through a TreeRef lhs (substrate opener)

**Files:** Modify `src/StaticLint/imports.jl` (or references.jl — wherever `resolve_getfield` methods live; implementer locates the `resolve_getfield(x, parent, state)` family), `src/layer_file_analysis.jl` (member lookup + outbound); test `test/test_file_analysis.jl` (append).

**Why first:** `Sib.f()` currently produces no ref, no outbound row, and no member checks in per-file mode (Task-4 substrate gap, ledgered). Definitions, hover, references, and dot-completions on qualified names all need it; land it before any consumer migrates.

**Interfaces (produces):** `resolve_getfield` gains a method for a lhs whose `refof` is a `TreeRef` with `kind === :module` (or `:external_module`): look the field name up in `derived_module_visible_names(rt, root, origin_module-as-path)` (tree modules) or the env store (external stand-ins) via the seeded tree context; on hit `setref!` with a `TreeRef` carrying the member's kind/item/origin. Members of qualified uses then flow into `outbound` (a `Sib.f()` file gets BOTH a `Sib` row and an `f` row with `f`'s ItemRef).

Semantics (normative):
1. Tree-module lhs (`TreeRef.item !== nothing` or origin_module names a tree path in the current root): member lookup through the module's visible names (exact key; `@`-prefixed macros); miss ⇒ no ref (missing-ref parity with old getfield hints — but remember old is not gold here).
2. `:external_module` stand-in lhs: member lookup through the env `ModuleStore` exactly as the old `resolve_getfield(x, ::ModuleStore, state)` does; extract plain TreeRef, never store the store.
3. Workspace-package module lhs (origin_module = [pkg] cross-root): resolve through the package's own tree (`derived_workspace_package_roots`), reusing the visibility layer's cross-root machinery.
4. Only active in per-file mode (state carries the tree context); the old pass is untouched.

- [ ] **Step 1 (TDD):** failing tests: fixture `module Sib; export f; f() = 1; struct T; x::Int; end; end` + sibling file `using .Sib` + body `Sib.f()`, `Sib.T` — assert `refof` on `f`/`T` is a TreeRef with the declaring ItemRef; outbound has rows for `Sib` AND `f`/`T` with targets; `Sib.nope()` gets no ref; external `Base.Iterators.take` still resolves (store path); an M2-era differential regression guard: the 22 JDAP only-old pairs' class (qualified getfield RHS) — pick ONE real shape from task-7-report-m3.md and pin its new behavior.
- [ ] **Step 2:** RED → implement → GREEN; file-analysis + staticlint/lint filters green (old pass proof).
- [ ] **Step 3:** re-run the Task-7 full-diagnostic differential on the main root of /home/pfitzseb/git/JuliaWorkspaces.jl; expect the 22-pair only-old class to shrink; triage every delta (bucket A fix / sanctioned / old-not-gold), append to the task report.
- [ ] **Step 4:** commit `feat: resolve qualified uses through tree-backed module references`.

---

### Task 2: Diagnostics migration

**Files:** Modify `src/layer_static_lint.jl` is FORBIDDEN (user-dirty file; the old queries live there and stay) — instead modify `src/layer_file_analysis.jl` (new query) and `src/layer_diagnostics.jl:149` (the consumer switch); test `test/test_diagnostics.jl` + `test/test_file_analysis.jl` (append).

**Interfaces (produces):** `derived_new_static_lint_diagnostics(rt, uri) -> Set{Diagnostic}` in layer_file_analysis.jl: for each root in `derived_roots_for_uri(rt, uri)`, take `derived_file_analysis(rt, root, uri).diagnostics`, union into a `Set` (cross-root dedup = old behavior). `derived_diagnostics(rt, uri)` (layer_diagnostics.jl:149) calls it instead of `derived_static_lint_diagnostics`. Env-readiness gating (`derived_file_env_ready`, `_is_env_dependent_diagnostic`) and include-diagnostics stay untouched around it.

Notes (binding):
- Test-setup parity: the old pass feeds `derived_test_setup_bindings` into `semantic_pass(test_setups=…)`; the per-file pass passes none. This is behavior-identical TODAY because setup detection has a verified pre-existing off-by-one (`args[2]` line-info placeholder — setups are never recognized on this lineage; ledger follow-up). Add a one-line code comment at the new query citing this, and a differential check in Step 3. Do NOT fix the off-by-one here (it re-opens the stale-EXPR channel; ledgered follow-up).
- `get_diagnostics`/`get_diagnostics_blocking`/`get_diagnostic` (public.jl) flow through `derived_diagnostics` and need no changes.

- [ ] **Step 1 (TDD):** failing tests: a file with a missing ref + a lint hint gets the same `Set{Diagnostic}` from the new query as from `derived_static_lint_diagnostics` on a clean fixture; a file in TWO roots unions both roots' sets; a file in no root ⇒ empty set; invalidation: body edit in sibling B ⇒ `derived_new_static_lint_diagnostics(uri)` for A does not re-execute (TraceLogging probe — the whole point).
- [ ] **Step 2:** RED → implement → switch layer_diagnostics.jl:149 → GREEN. test_diagnostics.jl (39) + staticlint suites (217) + test_typeinf (11) green; assertions that break get change-list entries (expect the sanctioned classes: F2 method-call conservatism, wp-import improvement, `absent`).
- [ ] **Step 3:** real-workspace check: `get_diagnostics` output on the main root equals the Task-7 post-fix-wave differential state (0 unexplained).
- [ ] **Step 4:** commit `feat: publish diagnostics from per-file analyses`.

---

### Task 3: Completions

**Files:** Modify `src/layer_completions.jl` (meta source + scope-top bridge); test `test/test_completions.jl`.

**Interfaces (consumes):** `derived_file_analysis(rt, best_root, uri).meta` replaces the merged `meta_dict` at layer_completions.jl:1184-1185. Module-level names for the unqualified completion list come from `derived_module_visible_names(rt, root, derived_file_module_path(rt, root, uri))` — labels from keys, completion kinds mapped from `VisibleName.kind` (`:struct`/`:function`/`:macro`/`:module`/`:external_symbol`/…). Base/Core exported names keep coming from the env stores as today.

Semantics (normative):
1. The scope-chain walk from the cursor (`_collect_completions`) runs on the per-file meta and naturally stops at the file's root scope (contexts are stripped) — module-level completion entries are then appended from the visibility dict for the file's module path (and for nested in-file modules, the nested path). Dedupe: file-local bindings shadow visibility entries of the same name.
2. Dot-completions (`_get_dot_completion`): lhs `refof` is now possibly a `TreeRef` — `kind === :module` ⇒ enumerate `derived_module_visible_names` of the target module path, gated to exported names when the module is not an enclosing module of the file (matches old ModuleStore behavior of offering exported names; old offered ALL names for workspace modules via scope — check the old behavior in a probe FIRST and match it, noting which in the report); `:external_module` ⇒ env store enumeration as today; struct-kind TreeRef ⇒ field names from the inventory item's `field_names` (fetch via `derived_file_inventory(target.file)`).
3. `:import`-mode completions and the "add using" edit path (`_get_preexisting_using_stmts`, `_retrieve_toplevel_scope`, `get_expr_location`) operate on the current file's CST/meta only — port to per-file meta; the known pre-existing crash (`:import`-mode inside `@testitem` bodies, ledgered) stays a follow-up, do not fix here.
4. Self-bindings appear in visibility dicts — do not emit a duplicate completion for the enclosing module's own name.

- [ ] **Step 1 (probe, then TDD):** probe the OLD behavior for dot-completion on a workspace module (all names or exported-only?) and record it. Failing tests: unqualified completion in a file sees a sibling-file function; dot-completion on `Sib.` lists its exports incl. `@`-macros; dot-completion on an external module still works; a file-local binding shadows a same-named visibility entry (single completion item); `:import`-mode unchanged on a stdlib.
- [ ] **Step 2:** RED → implement → GREEN. test_completions.jl (22) green; changed assertions → change-list.
- [ ] **Step 3:** keystroke-latency spot check (julia-mcp, real workspace): time `get_completions` on a leaf file post-body-edit; record in report (expect ≪ the old 0.2–0.6 s; target ≤ 50 ms per spec).
- [ ] **Step 4:** commit `feat: serve completions from per-file analyses and module visibility`.

---

### Task 4: Signature help

**Files:** Modify `src/layer_signatures.jl:361` region; add selector in `src/layer_module_tree.jl` (append); test `test/test_signatures.jl` + `test/test_module_tree.jl` (append).

**Interfaces (produces):** `derived_method_items(rt, root, path, name::String) -> Vector{ItemRef}` — id-carrying request-time selector: all inventory items declaring or extending `name` in module `path` across the module's files (declared items with that name + qualified extensions whose `qualifier` resolves to `path`), in splice order. Thin projection of `derived_module_tree` + per-file inventories; plain data.

Semantics (normative):
1. `_collect_signatures`: callee `refof` is a local `Binding` ⇒ old code path unchanged (per-file meta). Callee is a `TreeRef` (or Binding whose `.val isa TreeRef`) ⇒ collect method signatures from `derived_method_items` of the origin module: each ItemRef's inventory item carries `signature` (the normalized signature string from M1) — parse parameter names/counts from it for `_resolve_call_param_names`; when richer detail is needed (default values), materialize the defining EXPR via `derived_item_positions(rt, item.file)[item.id].expr` (request-time, allowed).
2. External callees (env `FunctionStore`/`DataTypeStore`) unchanged.
3. Constructor calls on a tree struct: the struct item's `field_names` provide the implicit constructor signature; explicit inner/outer constructors come from `derived_method_items` (the F1 rule keeps the struct as declared winner; extensions are separate items).

- [ ] **Step 1 (TDD):** failing tests: selector — a function with 2 methods in different files returns both ItemRefs in splice order, plus a `Base.foo` extension NOT included for path `["Pkg"]` unless it extends `Pkg.foo`; signature help on a cross-file callee shows both signatures with parameter names; on a tree struct shows the field-based constructor; on `Base.println` unchanged.
- [ ] **Step 2:** RED → implement → GREEN. test_signatures.jl (9) green; change-list for deltas.
- [ ] **Step 3:** commit `feat: serve signature help through inventory method items`.

---

### Task 5: Hover

**Files:** Modify `src/layer_hover.jl:570` region; add request-time helper in `src/layer_file_analysis.jl`; test `test/test_hover.jl`.

**Interfaces (produces):** `item_documentation(rt, ref::ItemRef) -> Union{Nothing,String}` (plain function, request-time): materialize the defining EXPR via `derived_item_positions(rt, ref.file)[ref.id]`, check its parent chain in the defining file's CST for a doc-wrapper macrocall, and reuse the existing docstring extraction (`_get_hover`'s Binding.val::EXPR arm) on it. Docs deliberately live outside the inventory (spec: docstring edits must not invalidate dependents) — this helper is the sanctioned path.

Semantics (normative):
1. `_get_hover_text` reads per-file meta (`derived_file_analysis(rt, best_root, uri).meta`); hovered EXPR resolution unchanged (`get_expr1`).
2. Ref target is a local Binding ⇒ old rendering unchanged. TreeRef with `item` ⇒ render from the inventory item (name, kind, signature) + `item_documentation`; TreeRef `:external_symbol`/`:external_module` ⇒ env-store docs as today (the frozen meta already carries the store-backed leaf refs for those).
3. Operator resolution (`_resolve_op_ref`) and `_get_fcall_position` arg docs port to per-file meta + `derived_method_items` (from Task 4) for cross-file callees.
4. No-root files keep the `_empty_hover_meta_dict`/`_empty_hover_env` fallback.

- [ ] **Step 1 (TDD):** failing tests: hover on a sibling-file function with a docstring shows the docstring + signature; hover on a sibling struct shows fields; hover on `base64encode`-class env symbol unchanged; hover on a local variable unchanged; docstring edit in the DEFINING file does not re-execute the hovering file's analysis (TraceLogging — the docs-outside-inventory property).
- [ ] **Step 2:** RED → implement → GREEN. test_hover.jl (12) green; change-list for deltas.
- [ ] **Step 3:** commit `feat: render hover from inventory items and defining-file docstrings`.

---

### Task 6: Definitions + module-at

**Files:** Modify `src/layer_references.jl:297-330` (`_get_definitions`, `_get_definitions_from_val`), `src/layer_navigation.jl:188` (`_get_module_at`); test `test/test_navigation.jl` + `test/test_references.jl`.

Semantics (normative):
1. `_get_definitions`: per-file meta; `refof(x)` local Binding ⇒ existing chain (`_resolve_shadow_binding`, `_canonical_local_definition`) unchanged within the file. TreeRef with `item` ⇒ location = `derived_item_positions(rt, item.file)[item.id]` → `(uri=item.file, offset)`; for functions, ALL locations from `derived_method_items` (go-to-definition on a 2-method function offers both). Store-backed targets (`FunctionStore` etc.) unchanged.
2. `_get_module_at`: per-file meta scope chain gives in-file nesting; the enclosing path prefix comes from `derived_file_module_path(rt, best_root, uri)` (the old code read it off the merged scope chain, which crossed files). Join: `join(vcat(file_path, in_file_names), ".")`.
3. `_get_file_loc`/`derived_expr_uri_map` keep working for local targets (per-file meta EXPRs belong to the same CST objects the map indexes — assert this in a test rather than assuming).

- [ ] **Step 1 (TDD):** failing tests: go-to-def on a sibling-file function lands at the right file/offset (compare against `derived_item_positions` ground truth); on a 2-method function returns both; on a local shadowing binding returns the local one; `_get_module_at` inside a nested in-file module of an included file returns the full dotted path (file prefix + nesting); qualified `Sib.f` definition works (Task 1 substrate).
- [ ] **Step 2:** RED → implement → GREEN. test_navigation.jl (3) + the definitions testitems in test_references.jl green; change-list for deltas.
- [ ] **Step 3:** commit `feat: resolve definitions through item positions`.

---

### Task 7: References / rename / highlights (the aggregation)

**Files:** Modify `src/layer_references.jl` (`_for_each_ref` + the three entry points); add aggregation helper in `src/layer_file_analysis.jl`; add file-list selector in `src/layer_module_tree.jl` if absent; test `test/test_references.jl` (+ new invalidation testitem in `test/test_file_analysis.jl`).

**Interfaces (produces):**
- `derived_tree_files(rt, root) -> Vector{URI}` — id-free thin selector: the root's spliced files in DFS order (from `ModuleTree.file_modules` keys; check whether an equivalent selector already exists before adding).
- `each_reference(f, rt, target::ItemRef)` (plain request-time function): for every root in the union of `derived_roots_for_uri(rt, target.file)`, for every file in `derived_tree_files(rt, root)`, skip unless `derived_file_analysis(rt, root, file).outbound` has a row with `row.target == target` (**join on target, never name** — alias rows carry the bound name); then walk that file's meta refs collecting EXPRs whose `refof` is a TreeRef with `item == target` OR a Binding whose `.val isa TreeRef` with `item == target` (import statements + alias bindings), and call `f(file, offset)` per site (offset via the existing `_get_file_loc`). ALSO: in the declaring file itself, the declaration's local refs (the old `loose_refs` within-file behavior) — per-file meta of `target.file`.
- The three entry points: identifier at cursor resolves to (a) local non-module-level Binding ⇒ old `loose_refs` walk on the per-file meta (current file only — locals can't escape the file); (b) module-level name ⇒ obtain its `ItemRef` (from `refof` TreeRef, or for the declaration site itself from `derived_module_declared`/`derived_visible_item` of the file's module path) ⇒ `each_reference`. Rename applies the same walk + the macro `@`-normalization; prepare-rename (`_can_rename`) is already inventory-clean. Highlights stay CURRENT-FILE: per-file meta `loose_refs` + outbound-target matches within this file only.

Notes (binding):
- Cost model: `each_reference` verifies one `derived_file_analysis` per file per root — plain-data outbound checks, mostly backdated; this is a request-time cold walk, NOT a per-keystroke path. Do not cache it in a derived value keyed on the whole root (ItemRef-keyed values are volatile by design).
- Cross-root: a workspace package's item is referenced by files in roots that splice or import it; `derived_roots_for_uri(target.file)` covers the roots that include the declaring file. Match old reachability (old merged deved-package meta per deving root); add a two-root fixture test.

- [ ] **Step 1 (TDD):** failing tests: references of a sibling-declared function found across 3 files with exact offsets (compare old vs new output sets on the fixture BEFORE switching — capture old, assert new equal); alias case `using .Sib: f as g` — references of `f` include the g-call sites (target-join); rename of a module-level function edits all files incl. the `as`-alias statement, macro rename keeps `@`; highlights unchanged (current-file); references of a file-local variable unchanged; two-root deved-package fixture: references found from both roots; invalidation: pulling references is NOT a derived query (grep no new `@derived` with ItemRef keys).
- [ ] **Step 2:** RED → implement → GREEN. test_references.jl (9) green; change-list for deltas.
- [ ] **Step 3:** real-workspace sanity: references of a well-known JuliaWorkspaces function (e.g. `derived_text_file_content`… pick one with known call sites) — count vs old path, triage deltas.
- [ ] **Step 4:** commit `feat: aggregate references over per-file outbound tables`.

---

### Task 8: Document + workspace symbols

**Files:** Modify `src/layer_symbols.jl:224,245`; test `test/test_symbols.jl`.

Semantics (normative):
1. `_get_document_symbols(runtime, uri)`: per-file meta from the best root (`derived_file_analysis`); the `bindingof`/`scopeof` collection walk is unchanged (top-level bindings of THIS file only — already per-file semantics).
2. `_get_workspace_symbols(runtime, query)`: re-express **over inventories directly** (spec "Aggregations"): for each text file, `derived_file_inventory(rt, uri).items` filtered by `query` (case-insensitive substring, matching the old filter semantics — read `_collect_toplevel_bindings_w_loc` first and mirror its matching + `SymbolKind` mapping from item `kind`), positions via `derived_item_positions`. No `derived_file_analysis` needed at all — this kills the old behavior of running the WHOLE root pass per file (the many-envs sweep pain point).
- [ ] **Step 1 (TDD):** failing tests: document symbols for a fixture file identical old-vs-new (capture-then-compare); workspace symbols for a query return the same (name, uri, range) triples as old on the fixture; a `@`-macro item is findable by query "mymac" AND "@mymac" (match old behavior — probe first).
- [ ] **Step 2:** RED → implement → GREEN. test_symbols.jl (3) green.
- [ ] **Step 3:** perf note in report: workspace-symbols wall time on the real workspace old vs new.
- [ ] **Step 4:** commit `feat: serve symbols from per-file analyses and inventories`.

---

### Task 9: Code actions, inlay hints, `get_static_lint_data`

**Files:** Modify `src/layer_actions.jl:810,847`, `src/layer_misc.jl:190`, `src/public.jl:745-762`; test `test/test_actions.jl`, `test/test_misc.jl`.

Semantics (normative):
1. Actions + inlay hints read `derived_file_analysis(rt, best_root, uri).meta` (both are current-file: predicates/handlers at a cursor, binding-type hints on this file's assignments). Action handlers that inspect refs must tolerate `TreeRef` (audit `_JW_ACTIONS` predicates/handlers for `.val`/`refof` dispatch on the old union — same crash-audit discipline as M3 Task 4; list each in the report).
2. `get_static_lint_data(jw, uri)`: ZERO consumers exist anywhere in the julia-vscode tree (verified). Re-point it to return `(meta_dict = derived_file_analysis(best_root, uri).meta, env, workspace_packages = Dict{String,Any}(), root)` with a docstring note that meta is per-file since the inventories refactor and `workspace_packages` is vestigial (deletion candidate for M5); keep the signature.
- [ ] **Step 1 (TDD):** failing tests: one representative action predicate + handler works on per-file meta (pick the unused-binding action); inlay hints for a fixture identical old-vs-new (capture-then-compare); `get_static_lint_data` returns per-file meta with the right root.
- [ ] **Step 2:** RED → implement → GREEN. test_actions.jl (8) + test_misc.jl (7) green.
- [ ] **Step 3:** commit `feat: move actions, inlay hints, and lint-data API to per-file analyses`.

---

### Task 10: Opener cleanups (perf + deferred tests)

**Files:** Modify `src/layer_module_tree.jl` (kind index), `src/layer_visibility.jl` (cross-root memoization); test `test/test_module_tree.jl`, `test/test_inventory.jl` (append).

1. **O(n²) `_declared_item_kind`** (layer_module_tree.jl:575 vicinity): `derived_module_names` scans a file's items per declared name. Build a per-file `(id, name) → kind` Dict once per inventory inside the query (or a thin `derived_inventory_kind_index(rt, uri)` selector if the profile warrants) — probe the real-workspace cost first; if the warm rebuild is already <1 ms total, do the local-Dict version and note it.
2. **Cross-root visibility memoization**: `_visible_names_impl` recursion bypasses the Salsa cache for referenced packages (every consumer module recomputes the package's names per revision; weight raised by the wave's new cross-root paths). Route the ACYCLIC entry (empty visited set, package top-module) through `derived_module_visible_names` itself; keep the visited-threaded plain function for cycle-bearing continuations. TraceLogging test: two modules using the same package ⇒ package visibility computed once.
3. **Operator/`var""` macro spelling tests**: inventory assertions pinning `macro +(a,b)` ⇒ item `"@+"` and `var"@weird"` handling (probe the CST shape first; if `var""` macros are genuinely exotic on this lineage, pin `"@+"` only and note).
- [ ] **Step 1:** probes (cost of #1 on the real workspace; trace counts for #2) → **Step 2:** RED tests for #2/#3 → implement → GREEN; module-tree + visibility + inventory filters green. **Step 3:** commit `perf: index declared-item kinds and memoize cross-root visibility`.

---

### Task 11: Milestone acceptance — real-workspace smoke + consumer differential + latency

**Files:** none (report-only; fixes under TDD only if bugs surface). Port `benchmark/interactive_latency.jl` from the parked `sp/perf` branch (`git show` the file; commit the port if used).

- [ ] **Step 1 — consumer smoke on /home/pfitzseb/git/JuliaWorkspaces.jl:** for the main root: completions at 5 positions (leaf file, hub file, dot-completion, `:import` mode, inside nested module), hover at 3, definitions at 3 (incl. one qualified `Sib.f`-class), references of 2 module-level names, signature help at 2, document symbols for 3 files, workspace symbols for 2 queries, inlay hints for 1 file. Zero exceptions; results sane (spot-check targets by hand).
- [ ] **Step 2 — differential:** old-vs-new output sets for completions (label sets), definitions (location sets), references (location sets), document symbols — on fixture workspaces AND 3 real-workspace probes per feature (the old path still exists until M5 — call both). Triage every delta: bug (fix under TDD) / sanctioned (cite) / old-not-gold (cite ledger). The triage list is the deliverable. Explicitly check the unused-binding lint class (spec "Aggregations" names it as a per-root aggregate): determine whether the old pass emits any module-level unused-binding hints on these roots; if yes and per-file mode diverges, that is a bucket-A gap needing a per-root aggregate over outbound tables (design in the report, fix under TDD); if the old pass emits none, record that the spec bullet is vacuous on this lineage.
- [ ] **Step 3 — latency acceptance (spec Testing strategy #4):** post-body-edit completion latency on the repro workspace, leaf AND hub file: target ≤ 50 ms both (vs 0.2–0.6 s old). Post-edit `get_diagnostics(jw)` full-sweep cost: bounded by one file's analysis + aggregation re-verification. Record numbers.
- [ ] **Step 4:** canonical full suite (baseline 5197 + M4 additions, 0 fail); finalize the M4 change-list section in the task report; commit any fixes; report.

---

## Self-review notes (already applied)

- Migration order matches the spec's step-4 order; Task 1 is the ledgered M4-opener that everything qualified depends on; references (the only fundamentally cross-file consumer, per the consumer inventory) sits after definitions so `derived_item_positions` plumbing is proven first.
- `get_static_lint_data` verified consumer-free across the whole julia-vscode tree — re-pointed, not contract-broken.
- The old pass keeps compiling until M5; each task removes callers only. layer_static_lint.jl is never edited (user-dirty file).
- Every aggregation is request-time (plain functions); no new derived value carries ItemRef-keyed dicts, ModuleStores, or contexts.
- Old-not-gold classes are named in Global Constraints so per-task change-lists don't chase known-false parity.
- test_setup_bindings parity is explicitly a no-op TODAY (verified off-by-one) — documented, deferred, differential-gated.
