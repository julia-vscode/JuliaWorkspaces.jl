# Inventories Milestone 2: `derived_module_tree` — the DefMap analog

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The per-root module tree built purely from file inventories: module hierarchy, per-module declared-name tables, export/public lists, and classified `using`/`import` records — plus the milestone-mandated inventory parity fixes carried over from Milestone 1's final review.

**Architecture:** Two deterministic passes inside one Salsa query. Pass 1 walks include targets from the root file, splicing each file's inventory records into the module path active at its include site (worklist + visited set, mirroring `derived_include_closure`'s semantics). Pass 2 resolves import *paths* against the completed structure and the workspace-package map, classifying everything else as external. The tree never touches `derived_environment`: `StaticLint.ExternalEnv` is a mutable struct whose `isequal` is identity, so depending on it would permanently break the tree's backdating — import targets are only *classified* here (`:tree` / `:workspace_package` / `:external` / `:unresolved`), and actual `SymbolServer` store lookups stay in layer 3 behind the spec's env seam. Import resolution needs no fixpoint because imports cannot create modules — only declarations and includes can, and pass 1 completes those first.

**Tech Stack:** Julia; JuliaWorkspaces (branch `sp/inventories`), Salsa + TraceLogging (vendored), AutoHashEquals, TestItemRunner.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-16-inventory-architecture-design.md`, section "Layer 2". Read it first. One sanctioned deviation from its text, decided here: "resolves `using`/`import` against the env's SymbolServer stores" is implemented as *classification* only (see Architecture) — record this in commit/report language as honoring the spec's durability hook ("environment-derived data flows through a small number of dedicated query nodes").
- Repo: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces`, branch `sp/inventories`. Commit there; do NOT push. The user's two pre-existing uncommitted changes (`src/types.jl`, `src/layer_static_lint.jl`) must never appear in commits.
- Run Julia ONLY via `mcp__julia__julia_eval` with `env_path=/home/pfitzseb/git/julia-vscode/scripts/environments/development`. `import Revise, TestItemRunner` FIRST in a fresh session. Function-level edits: `Revise.revise()`. New/changed structs: `mcp__julia__julia_restart` (~30 s) + re-import.
- Filtered tests: `TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("<substr>", ti.name))`. Full-suite gates MUST use the canonical entry (`cd` into the package, `include("test/runtests.jl")`) — `run_tests(dir)` has a known fixture artifact. Canonical baseline at milestone start: **4774 pass / 0 fail / 1 pre-existing error ("Format: runic matches Runic.format_string directly", local env) / 7 pre-existing broken**.
- Module-tree values are plain data under `@auto_hash_equals` — no EXPRs, no objectids, no offsets, no docstrings, no `ModuleStore`/`ExternalEnv` references. `derived_module_tree` may depend ONLY on: file inventories, include-graph queries, and the project-structure queries named in Task 3 (whose values are `@auto_hash_equals` plain data). Depending on `derived_environment` or `derived_item_positions` from this layer is a bug.
- Name-extraction rule (recurring bug class): never `CSTParser.valof` after only an `isidentifier` check; use `str_value`/`valofid`. (Tasks here are mostly CST-free, but Task 1 touches the extractor.)
- Commit messages: conventional commits, no issue references, backtick macro names.

---

### Task 1: Inventory parity openers (mandated by Milestone 1's final review)

**Files:**
- Modify: `src/layer_inventory.jl`
- Test: `test/test_inventory.jl` (append; plus one two-character fixture rename in the existing walker-container testitem)

**Interfaces:**
- Consumes: the existing extractor internals (`_classify_assignment!`, `_item_name`, `_symbol_name`, `_walk_toplevel!`'s container arm) and `derived_item_positions`.
- Produces (all additive, no shape changes):
  1. Operator-named function definitions emit items: `+(a, b) = 1` → `InventoryItem(name="+", qualifier=String[], kind=:function, …)`; `Base.:+(a, b) = 1` and `function Base.:+(a, b) end` → `name="+", qualifier=["Base"]`. Route the function-call-form name through the operator-accepting name helper (`_symbol_name`-style), and handle the quoted-operator getfield form (`Base.:+` — the name EXPR is a getfield whose rhs is a quotenode-wrapped operator; explore the CST shape before writing).
  2. Tuple-destructuring assignments emit one `:assignment` item per identifier: `a, b = 1, 2` → items "a" and "b" (same id? NO — the walker assigns one id to the statement; emit multiple items sharing that id is NOT allowed since ids key the position map. Emit one item per name with the SAME id and document that the position map resolves the shared id to the whole statement — this matches how a future goto-def would target the statement. Add a comment stating this deliberately.) Cover `const x, y = 1, 2` too.
  3. Ternary guard: the walker's `:if` container arm must not descend into ternaries (`cond ? a : b` parses with head `:if` but has no `:block` body). Guard on the container having a block-shaped body (explore: `headof(node.trivia[1]) === :IF` vs. block-arg check — pick the one that distinguishes ternaries in the real CST and say why in a comment). Test: a top-level ternary produces no junk ids — assert `derived_item_positions` has exactly the ids the inventory has.
  4. Rename `elseif_f`/`else_f` in the existing container testitem to distinct-first-letter names (e.g. `bravo_f`) so its byte-offset assertions can't pass with swapped offsets.
  5. Parity-audit testitem: a single fixture exercising every non-scoping construct StaticLint binds at module level (`if`/`elseif`/`else`/`begin` nesting incl. a function inside `if` inside `begin`, `const`/`global` wraps, operator def, tuple destructuring, `@enum`, doc-wrapped struct, module) asserting every expected name appears in the inventory — with a comment block naming the DELIBERATE exceptions (scoped constructs per `introduces_scope` — `for`/`while`/`let`/`try`/functions; opaque macrocalls; testitem-family macros deferred per spec).

- [ ] **Step 1: Write the failing tests** for 1–3 and 5 (4 is a mechanical edit to an existing testitem, no RED needed). Concrete testitem skeletons — names/kinds exact, adjust only CST-exploration-dependent details:

```julia
@testitem "inventory parity: operator-named function definitions" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    +(a, b) = 1
    Base.:+(a, b) = 2
    function Base.:*(a, b) end
    """)
    plus_local = only(filter(i -> i.name == "+" && isempty(i.qualifier), inv.items))
    @test plus_local.kind === :function
    plus_base = only(filter(i -> i.name == "+" && i.qualifier == ["Base"], inv.items))
    @test plus_base.kind === :function
    star = only(filter(i -> i.name == "*", inv.items))
    @test star.qualifier == ["Base"]
end

@testitem "inventory parity: tuple-destructuring assignments" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    a, b = 1, 2
    const x, y = 3, 4
    """)
    for (n, k) in [("a", :assignment), ("b", :assignment), ("x", :const), ("y", :const)]
        item = only(filter(i -> i.name == n, inv.items))
        @test item.kind === k
    end
    # Destructured names share their statement's walker id (position map
    # resolves the shared id to the whole statement).
    @test only(filter(i -> i.name == "a", inv.items)).id ==
          only(filter(i -> i.name == "b", inv.items)).id
end

@testitem "inventory parity: ternaries produce no junk position ids" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI
    uri = URI("file:///inv/src/tern.jl")
    inv, jw = inventory_of("f() = 1\ncond = true\nresult = cond ? 1 : 2\ng() = 2\n"; uri=uri)
    pos = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)
    inv_ids = Set(vcat([i.id for i in inv.items], [m.id for m in inv.modules],
                       [i.id for i in inv.imports], [e.id for e in inv.exports],
                       [i.id for i in inv.includes]))
    # Every position-map id corresponds to a walked statement; none may come
    # from descending into ternary call arguments.
    @test Set(keys(pos)) ⊇ inv_ids
    @test length(pos) <= 4 + 1   # f, cond, result, g (+1 slack for the ternary statement itself)
end

@testitem "inventory parity audit: module-level bindables are never invisible" setup=[InventoryWS] begin
    # Deliberate exceptions (documented, not extracted): names bound inside
    # scoped constructs (for/while/let/try/function bodies — introduces_scope),
    # opaque macrocalls, and testitem-family macros (deferred per spec).
    inv, _ = inventory_of("""
    if VERSION > v"1.0"
        cond_f(x) = x
        begin
            nested_g() = 1
        end
    elseif false
        alt_f() = 2
    else
        other_f() = 3
    end
    const C = 1
    global G = 2
    +(a, b) = 1
    p, q = 1, 2
    @enum Fruit apple banana
    \"\"\"doc\"\"\"
    struct DocS end
    module M
    m_f() = 1
    end
    """)
    names = Set(i.name for i in inv.items)
    for expected in ["cond_f", "nested_g", "alt_f", "other_f", "C", "G", "+",
                     "p", "q", "Fruit", "apple", "banana", "DocS", "m_f"]
        @test expected in names
    end
end
```

- [ ] **Step 2: Run them, expect failures** (operator/tuple/audit items missing; ternary id-count too high):

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventory parity", ti.name))
```

- [ ] **Step 3: Implement** all four fixes in `src/layer_inventory.jl` (explore CST shapes first for the quoted-operator getfield and the ternary discriminator). Also apply item 4's fixture rename.

- [ ] **Step 4: Run the parity filter + the full inventory filter, expect PASS:**

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventor", ti.name) || occursin("item positions", ti.name))
```

- [ ] **Step 5: Commit:**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "fix: close inventory parity gaps for operator definitions, destructuring, and ternaries"
```

---

### Task 2: Module-tree value types

**Files:**
- Create: `src/layer_module_tree.jl` (types only)
- Modify: `src/packagedef.jl` (add `include("layer_module_tree.jl")` directly after `include("layer_inventory.jl")`)
- Test: `test/test_module_tree.jl` (new)

**Interfaces (produces — consumed by Tasks 3–7 and Milestone 3):**

```julia
const ItemRef = @NamedTuple{file::URI, id::Int}

@auto_hash_equals struct ImportTarget
    sort::Symbol            # :tree | :workspace_package | :external | :unresolved
    path::Vector{String}    # :tree → ABSOLUTE module path within this root;
                            # :workspace_package → [package_name];
                            # :external/:unresolved → the original path segments as written
end

@auto_hash_equals struct ResolvedImport
    kind::Symbol                       # :using | :import
    target::ImportTarget
    symbols::Vector{ImportSymbol}      # per-symbol (name, alias); empty = whole-module
    alias::Union{Nothing,String}       # statement-level `as` alias
    from::ItemRef                      # the InventoryImport this came from
end

@auto_hash_equals struct ModuleNode
    path::Vector{String}               # absolute path in this root; String[] = the root file's own top level
    bare::Bool                         # baremodule (false for the synthetic root node)
    declared_at::Union{Nothing,ItemRef}   # nothing for the synthetic root node
    files::Vector{URI}                 # files whose top level splices here, in include order
    declared::Dict{String,ItemRef}     # module-level name → defining item (later declaration wins)
    exports::Vector{String}
    publics::Vector{String}
    imports::Vector{ResolvedImport}
end

@auto_hash_equals struct ModuleTree
    root::URI
    modules::Vector{ModuleNode}            # sorted by path for deterministic equality
    file_modules::Dict{URI,Vector{String}} # file → absolute path its top level splices into
end

const EMPTY_MODULE_TREE(root) — function, not const value: ModuleTree(root, [ModuleNode(String[], false, nothing, URI[], Dict{String,ItemRef}(), String[], String[], ResolvedImport[])], Dict{URI,Vector{String}}())
```

Plus a lookup helper `module_node(tree::ModuleTree, path::Vector{String})::Union{Nothing,ModuleNode}` (linear scan is fine — trees have few modules).

- [ ] **Step 1: Write the failing test** (`test/test_module_tree.jl`):

```julia
@testitem "module tree types: structural equality across separately built instances" begin
    using JuliaWorkspaces: ModuleTree, ModuleNode, ResolvedImport, ImportTarget, ItemRef, module_node
    using JuliaWorkspaces.URIs2: URI

    f = URI("file:///t/src/T.jl")
    make() = ModuleTree(f,
        [ModuleNode(String[], false, nothing, [f],
            Dict("g" => (file=f, id=2)), ["g"], String[],
            [ResolvedImport(:using, ImportTarget(:external, ["Base64"]),
                            JuliaWorkspaces.ImportSymbol[], nothing, (file=f, id=1))]),
         ModuleNode(["M"], false, (file=f, id=3), [f], Dict{String,ItemRef}(), String[], String[], ResolvedImport[])],
        Dict(f => String[]))

    a = make(); b = make()
    @test a == b && isequal(a, b) && hash(a) == hash(b)
    @test module_node(a, ["M"]) !== nothing
    @test module_node(a, ["Nope"]) === nothing
end
```

- [ ] **Step 2: Run it, expect `UndefVarError: ModuleTree`:**

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("module tree types", ti.name))
```

- [ ] **Step 3: Implement** the types above verbatim in `src/layer_module_tree.jl` with a header comment mirroring `layer_inventory.jl`'s firewall rationale (plain data; the env-independence rule from Global Constraints stated explicitly). Add the packagedef include. Restart the session (new structs + include).

- [ ] **Step 4: Run the test, expect PASS. Step 5: Commit:**

```bash
git add src/layer_module_tree.jl src/packagedef.jl test/test_module_tree.jl
git commit -m "feat: add module-tree value types"
```

---

### Task 3: `derived_workspace_package_roots`

**Files:**
- Modify: `src/layer_module_tree.jl` (append)
- Test: `test/test_module_tree.jl` (append)

**Interfaces:**
- Consumes: `derived_package_folders(rt)` (layer_projects.jl:227-229), `derived_package(rt, folder)` → `JuliaPackage` (`@auto_hash_equals`, has `.name`), the entry-file idiom `filepath2uri(joinpath(uri2filepath(folder), "src", "$(name).jl"))` gated on `derived_has_file` (mirror layer_environment.jl:101-115), `derived_has_file(rt, uri)`.
- Produces: `Salsa.@derived derived_workspace_package_roots(rt) -> Dict{String,URI}` — workspace package name → its entry-file URI (only packages whose entry file exists). Plain data; deterministic (if two folders claim the same package name, the lexicographically smaller folder URI wins — document).

- [ ] **Step 1: Failing test** (fixture: a workspace with two packages built via `add_file!` — Project.toml with name/uuid/version + `src/Name.jl` each — plus one package folder whose entry file is missing, asserting it is absent from the map). Use the `InventoryWS`-style in-memory pattern; Project.toml fixtures exist in `test/test_fast_path.jl`-era tests on other branches — write fresh ones here (name/uuid/version + manifest not required for `derived_package`).

- [ ] **Step 2: RED** (`UndefVarError`), **Step 3: implement**, **Step 4: GREEN**, **Step 5: commit:**

```bash
git add src/layer_module_tree.jl test/test_module_tree.jl
git commit -m "feat: map workspace package names to entry files"
```

---

### Task 4: Pass 1 — tree structure from inventories

**Files:**
- Modify: `src/layer_module_tree.jl` (append)
- Test: `test/test_module_tree.jl` (append)

**Interfaces:**
- Consumes: `derived_file_inventory(rt, uri)`, `derived_has_content(rt, uri)`.
- Produces: internal `_build_tree_structure(rt, root) -> (modules_by_path::Dict{Vector{String},<mutable node builder>}, file_modules)` plus the public `Salsa.@derived derived_module_tree(rt, root)` running pass 1 (+ pass 2 stub returning imports with `sort=:unresolved` until Task 5 replaces it — or land Task 4 with imports simply collected unresolved and Task 5 upgrading; either way each task ends green).

**Splicing semantics (normative):**
1. Worklist starts at `(root_file, path=String[])`. A visited `Set{URI}` guards cycles and duplicate includes — first include wins, later includes of the same file are skipped (matches `derived_include_closure`).
2. For a file F spliced at absolute path P: every inventory record with file-relative `parent_module` RP lives at absolute path `vcat(P, RP)`.
3. `InventoryModule` at RP named N creates/extends node `vcat(P, RP, [N])` (records `bare`, `declared_at=ItemRef(F, id)`); the module NAME also enters the parent module's `declared`.
4. `InventoryInclude` at RP with target T (skip `nothing` targets and content-less targets) enqueues `(T, vcat(P, RP))`; T is appended to that node's `files`.
5. Items with empty `qualifier` and binding kinds (`:function`, `:macro`, `:struct`, `:mutable_struct`, `:abstract`, `:primitive`, `:const`, `:global`, `:assignment`, `:enum`, `:enum_member`) enter `declared` at their absolute path — later declarations overwrite (include order). Items with non-empty `qualifier` (method extensions) do NOT enter `declared`.
6. `InventoryExport` names append to the node's `exports`/`publics`.
7. Every visited file F records `file_modules[F] = P`.
8. Nodes are created on demand (a module path mentioned only via nesting still gets a node); the synthetic root node (path `String[]`) always exists.

- [ ] **Step 1: Failing tests.** Fixtures (in-memory workspaces, `InventoryWS`-style snippet local to this file):
  - package shape: root `module Pkg; include("a.jl"); include("b.jl"); end` with a.jl declaring `afunc`/`Common` module and b.jl extending — assert `module_node(tree, ["Pkg"]).declared` has `afunc`, `Common`; `file_modules[a_uri] == ["Pkg"]`.
  - module split across files: root declares `module Pkg` and includes `inner.jl` INSIDE a nested `module Sub ... include("inner.jl") ... end` — assert inner.jl's items land at `["Pkg","Sub"]` and `file_modules[inner_uri] == ["Pkg","Sub"]`.
  - later-declaration-wins: same name in a.jl and b.jl → `declared` points at b.jl's item.
  - duplicate include skipped; include cycle terminates; missing include target ignored.
  - script shape (no module): root with bare functions → declared at `String[]`.

- [ ] **Step 2: RED. Step 3: implement** pass 1 exactly per the normative semantics (mutable builder structs internally, frozen into the plain-data `ModuleNode`s sorted by path at the end). **Step 4: GREEN. Step 5: commit:**

```bash
git add src/layer_module_tree.jl test/test_module_tree.jl
git commit -m "feat: build per-root module trees from file inventories"
```

---

### Task 5: Pass 2 — import classification

**Files:**
- Modify: `src/layer_module_tree.jl`
- Test: `test/test_module_tree.jl` (append)

**Interfaces:**
- Consumes: pass-1 structure, `derived_workspace_package_roots(rt)`.
- Produces: `ResolvedImport` records on each node, classified per these rules (normative), applied to each `InventoryImport` at its absolute module path AP:
  1. Leading `"."` segments: one `.` = current module AP, each additional `.` pops one level (`using ..X` from `["Pkg","Sub"]` → resolve `X` starting at `["Pkg"]`). If pops exceed depth → `:unresolved`.
  2. After relative anchoring (or for absolute paths, anchoring at the innermost enclosing module that DECLARES the first segment, walking outward to `String[]` — Julia's module lookup), the remaining segments must each name an existing tree module (child path exists in `modules_by_path`) → `sort=:tree, path=<absolute resolved path>`. Segments naming a *declared non-module item* → `:unresolved`.
  3. Absolute first segment not found in the tree: if it names a workspace package (`derived_workspace_package_roots`) → `sort=:workspace_package, path=[name]`. (A package importing ITSELF by name from within — anchor rule 2 already catches the declared module first.)
  4. Otherwise → `sort=:external, path=<segments as written>` (Base, stdlib, registry packages — layer 3 checks the env).
  5. `symbols`/`alias`/`kind` copy through from the inventory record; `from=ItemRef(file, id)`.

- [ ] **Step 1: Failing tests:** `using .Child` / `using ..Sibling` (from nested), `using ..TooFar` beyond root → `:unresolved`, absolute `using Pkg.Sub` from anywhere in the tree → `:tree ["Pkg","Sub"]`, `import Base: +, map` → `:external` with both symbols, `using DevedPkg` (fixture with a second workspace package) → `:workspace_package`, `using SomeRegistryPkg` → `:external`, `import Foo.Bar as FB` alias carried, colon-symbol `as` aliases carried.
- [ ] **Step 2: RED. Step 3: implement. Step 4: GREEN + run the whole module-tree filter. Step 5: commit:**

```bash
git add src/layer_module_tree.jl test/test_module_tree.jl
git commit -m "feat: classify module-tree imports against tree, workspace packages, and external world"
```

---

### Task 6: Invalidation acceptance tests

**Files:**
- Test: `test/test_module_tree.jl` (append)

Same TraceLogging + probe pattern as Milestone 1's Task 5 (CountReceiver + a `Salsa.@derived` probe defined in the testitem consuming `derived_module_tree`). Assertions (spec acceptance criteria — failures indicate bugs in Tasks 2–5; fix under TDD, never weaken):
1. Body edit in a spliced file → `derived_file_inventory` re-executes once, `derived_module_tree` re-executes zero times (inventory backdated), probe zero.
2. API edit that doesn't change the tree's tables (e.g. adding a function whose name was already declared later-wins-shadowed — pick a fixture where the resulting `declared` map is genuinely unchanged; if none is natural, use: reordering two unrelated function bodies — inventory CHANGES (ids shift), tree re-executes but its VALUE compares equal → probe zero. This is the tree's own backdating layer.)
3. Adding an export → tree re-executes AND probe re-executes, sees the new export.
4. Adding an `include` of a new file → tree re-executes; `file_modules` gains the new file; probe sees it.

- [ ] **Step 1: Write tests. Step 2: Run, expect PASS** (investigate + fix any failure). **Step 3: canonical full suite** — baseline 4774 + all new tests from Tasks 1–6, 0 fail. **Step 4: commit:**

```bash
git add test/test_module_tree.jl
git commit -m "test: module-tree invalidation properties"
```

---

### Task 7: Real-workspace smoke check (report-only)

**Files:** none (findings in the report; fixes under TDD only if bugs surface)

- [ ] **Step 1:** Fresh session; build trees for every root of `/home/pfitzseb/git/JuliaWorkspaces.jl`:

```julia
using JuliaWorkspaces
jw = workspace_from_folders(["/home/pfitzseb/git/JuliaWorkspaces.jl"]); rt = jw.runtime
roots = collect(JuliaWorkspaces.derived_roots(rt))
@time trees = [JuliaWorkspaces.derived_module_tree(rt, r) for r in roots];
println("roots: ", length(roots),
    "  modules: ", sum(length(t.modules) for t in trees),
    "  declared names: ", sum(sum(length(n.declared) for n in t.modules) for t in trees),
    "  imports by sort: ", let c = Dict{Symbol,Int}()
        for t in trees, n in t.modules, i in n.imports
            c[i.target.sort] = get(c, i.target.sort, 0) + 1
        end; c end)
```

- [ ] **Step 2:** Spot-check 3 trees against reality (the main `src/JuliaWorkspaces.jl` root: `file_modules` for a couple of layer files must be `["JuliaWorkspaces"]`; a `packages/JSON` root: `Parser`'s `using ..Common`-style imports classified `:tree`; one `:workspace_package` classification if any root devs another). Report `:unresolved` counts with 3 sampled examples each — high unresolved counts indicate a rule gap (fix under TDD). Report timing (expect the whole-workspace tree build well under a second warm) and a firewall check: body-edit a spliced file, assert the tree value `isequal` before/after.

---

## Self-review notes (already applied)

- Env independence (the `ExternalEnv`-identity trap) is promoted to a Global Constraint and stated in Task 2's header comment — it is this milestone's load-bearing rule, the analog of M1's plain-data rule.
- Import classification vs. resolution is a sanctioned spec deviation, documented in Global Constraints, honoring the spec's own durability hook.
- Shared-id semantics for destructured names (Task 1.2) is a deliberate documented choice, not an accident — position-map consumers resolve the statement.
- M1 ledger carry-overs all land in Task 1; the parity-audit test operationalizes the "no blinder than `mark_bindings!`" rule fixture-wise rather than by `introduces_scope` introspection (simpler, equally binding).
