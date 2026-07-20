# Inventories Milestone 1: `derived_file_inventory` + item ids + position maps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The firewall layer of the inventory architecture: a per-file, position-free, plain-data summary of top-level items (`derived_file_inventory`), with stable item-ids and a volatile position-map query (`derived_item_positions`) — plus the invalidation-property tests proving body edits backdate.

**Architecture:** New `src/layer_inventory.jl` with one shared top-level walker used by both the inventory extractor and the position map (so ids always agree), inventory value types under `@auto_hash_equals`, and two Salsa queries following the fused-analysis + thin-selector conventions of `layer_includes.jl`. Nothing consumes these queries yet — Milestone 2 (module tree) is the first consumer.

**Tech Stack:** Julia; JuliaWorkspaces (vendored, `scripts/packages/JuliaWorkspaces`, branch `sp/inventories`), CSTParser (external dep), AutoHashEquals (already a dep), Salsa + TraceLogging (vendored), TestItemRunner tests.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-16-inventory-architecture-design.md` (same repo/branch). Read it first; this plan implements its "Layer 1" and "Position reattachment" sections.
- Repo: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces`, branch `sp/inventories`. Commit there; do NOT push. Two pre-existing uncommitted changes (`src/types.jl` log-level tweak, `src/layer_static_lint.jl` blank lines) are the user's — never include them in commits.
- Run Julia ONLY via `mcp__julia__julia_eval` with `env_path=/home/pfitzseb/git/julia-vscode/scripts/environments/development`. `import Revise, TestItemRunner` FIRST in a fresh session, before anything loads JuliaWorkspaces. Method/function edits: `Revise.revise()` suffices. New structs / changed struct definitions / new `include`s in packagedef.jl: use `mcp__julia__julia_restart` with the same env_path (~30 s) and re-import Revise/TestItemRunner.
- Run tests with `TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("<substr>", ti.name))`.
- Before Task 1, establish the full-suite baseline once: `cd` into the package dir, `include("test/runtests.jl")`. Expect ≈4689 passes / 7 broken (6 `test_uris2.jl`, 1 `test_staticlint.jl`) / 1 pre-existing error ("Format: runic matches Runic.format_string directly", local env issue). Record the exact numbers in your report; every later full run must match baseline + your new tests.
- Equality convention: every new value type uses `@auto_hash_equals` (`using AutoHashEquals` is already in `src/JuliaWorkspaces.jl:10`). Plain default `==` on immutable structs with `String`/`Vector` fields is identity-based and would silently break Salsa's early cutoff — the whole point of this milestone.
- **Inventory values must be plain data**: no `CSTParser.EXPR` references, no `objectid`s, no byte offsets, no docstrings anywhere in `FileInventory`. The position map is the only place EXPRs/offsets appear, and nothing may depend on it except request-handler last-mile code (nothing in this milestone).
- Parity rule: where extraction mirrors existing StaticLint behavior, the cited existing code is authoritative — verify your transcription against it (file:line given per task); when they disagree, follow the existing code and note it in your report.
- Commit messages: conventional commits, no issue references, backtick macro names (e.g. `` `@enum` ``).

---

### Task 1: Inventory value types

**Files:**
- Create: `src/layer_inventory.jl` (types only in this task)
- Modify: `src/packagedef.jl` (add `include("layer_inventory.jl")` directly after `include("layer_includes.jl")`, line 27)
- Test: `test/test_inventory.jl` (new file)

**Interfaces:**
- Produces the value types every later task and Milestone 2 consume:
  - `InventoryItem(id::Int, name::String, kind::Symbol, signature::Union{Nothing,String}, field_names::Vector{String}, parent_module::Vector{String})`
  - `InventoryImport(id::Int, kind::Symbol #= :using | :import =#, path::Vector{String} #= "." entries encode relative levels =#, symbols::Vector{String}, alias::Union{Nothing,String}, parent_module::Vector{String})`
  - `InventoryExport(id::Int, kind::Symbol #= :export | :public =#, names::Vector{String}, parent_module::Vector{String})`
  - `InventoryInclude(id::Int, target::Union{Nothing,URI}, parent_module::Vector{String})`
  - `InventoryModule(id::Int, name::String, bare::Bool, parent_module::Vector{String})`
  - `FileInventory(items::Vector{InventoryItem}, imports::Vector{InventoryImport}, exports::Vector{InventoryExport}, includes::Vector{InventoryInclude}, modules::Vector{InventoryModule})`
- `parent_module` is the module path *within this file* (outermost→innermost, `String[]` = file top level, i.e. whatever module the file is spliced into). Item kinds: `:function`, `:macro`, `:struct`, `:mutable_struct`, `:abstract`, `:primitive`, `:const`, `:global`, `:assignment`, `:enum`, `:enum_member`, `:opaque_macrocall`.

- [ ] **Step 1: Write the failing test.** Create `test/test_inventory.jl`:

```julia
@testitem "inventory types: structural equality across separately built instances" begin
    using JuliaWorkspaces: FileInventory, InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule
    using JuliaWorkspaces.URIs2: URI

    make() = FileInventory(
        [InventoryItem(1, "f", :function, "f(x)", String[], String[]),
         InventoryItem(2, "S", :struct, nothing, ["a", "b"], ["M"])],
        [InventoryImport(3, :using, [".", "Sibling"], String[], nothing, ["M"])],
        [InventoryExport(4, :export, ["f"], String[])],
        [InventoryInclude(5, URI("file:///pkg/src/a.jl"), String[])],
        [InventoryModule(6, "M", false, String[])],
    )

    a = make()
    b = make()
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)

    c = FileInventory(
        [InventoryItem(1, "g", :function, "g(x)", String[], String[])],
        a.imports, a.exports, a.includes, a.modules)
    @test !isequal(a, c)
end
```

- [ ] **Step 2: Run it, expect failure** (`UndefVarError: FileInventory`):

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventory types", ti.name))
```

- [ ] **Step 3: Implement.** Create `src/layer_inventory.jl`:

```julia
# Layer 1 of the inventory architecture (see
# docs/superpowers/specs/2026-07-16-inventory-architecture-design.md):
# a per-file, position-free, plain-data summary of top-level items. Values in
# this file are the firewall: they must contain only plain data (Symbols,
# Strings, Ints, vectors/structs of those) — never an EXPR reference, an
# objectid, a byte offset, or a docstring — so that body edits produce
# `isequal` inventories and Salsa's early-exit stops invalidation here.
# Position/EXPR reattachment lives exclusively in `derived_item_positions`.

"""
    InventoryItem

One top-level (module-level) item of a file. `parent_module` is the module
path within this file, outermost→innermost; `String[]` means the file's own
top level (whatever module the file is spliced into by its includer).
`signature` is a normalized (re-printed) signature string for functions and
macros, `nothing` otherwise. `field_names` is populated for structs.
"""
@auto_hash_equals struct InventoryItem
    id::Int
    name::String
    kind::Symbol
    signature::Union{Nothing,String}
    field_names::Vector{String}
    parent_module::Vector{String}
end

"""
    InventoryImport

A `using`/`import` statement. `path` is the module path with leading "."
entries encoding relative levels (`using ..Sibling` → `[".", ".", "Sibling"]`);
`symbols` is the explicit symbol list of `using X: a, b` (empty for whole-module
imports); `alias` is the `as` name if present.
"""
@auto_hash_equals struct InventoryImport
    id::Int
    kind::Symbol
    path::Vector{String}
    symbols::Vector{String}
    alias::Union{Nothing,String}
    parent_module::Vector{String}
end

"An `export` or `public` statement and the names it lists."
@auto_hash_equals struct InventoryExport
    id::Int
    kind::Symbol
    names::Vector{String}
    parent_module::Vector{String}
end

"An `include(...)` call with its resolved target (or `nothing` if unresolvable)."
@auto_hash_equals struct InventoryInclude
    id::Int
    target::Union{Nothing,URI}
    parent_module::Vector{String}
end

"A `module`/`baremodule` declared in this file."
@auto_hash_equals struct InventoryModule
    id::Int
    name::String
    bare::Bool
    parent_module::Vector{String}
end

"""
    FileInventory

The complete top-level API summary of one file. Structural equality (via
`@auto_hash_equals`) is the early-cutoff contract: two inventories are equal
iff the file's top-level API is identical, regardless of body edits,
whitespace, comments, or docstrings.
"""
@auto_hash_equals struct FileInventory
    items::Vector{InventoryItem}
    imports::Vector{InventoryImport}
    exports::Vector{InventoryExport}
    includes::Vector{InventoryInclude}
    modules::Vector{InventoryModule}
end

const EMPTY_FILE_INVENTORY = FileInventory(
    InventoryItem[], InventoryImport[], InventoryExport[], InventoryInclude[], InventoryModule[])
```

Add `include("layer_inventory.jl")` to `src/packagedef.jl` directly after `include("layer_includes.jl")` (line 27). Restart the Julia session (new structs + new include are not revisable).

- [ ] **Step 4: Run the test, expect PASS.** Same command as Step 2.

- [ ] **Step 5: Commit:**

```bash
git add src/layer_inventory.jl src/packagedef.jl test/test_inventory.jl
git commit -m "feat: add inventory value types for the per-file API summary"
```

---

### Task 2: The shared top-level walker

**Files:**
- Modify: `src/layer_inventory.jl` (append)
- Test: `test/test_inventory.jl` (append)

**Interfaces:**
- Consumes: `CSTParser` (`defines_module`, `ismacrocall`, `headof`, EXPR `.args`, `.fullspan`), doc-wrapper facts below.
- Produces: `_foreach_toplevel_item(f, cst::CSTParser.EXPR)` — calls
  `f(x::CSTParser.EXPR, id::Int, parent_module::Vector{String}, offset::Int)` for every
  top-level item-like node in tree order, where:
  - iteration starts at the `:file` node's `.args` and recurses ONLY into module blocks
    (a `module`/`baremodule` EXPR's body block, `x.args[3].args`), tracking
    `parent_module` (module name pushed for the block's children) — never into
    function/struct/let/… bodies;
  - ids are assigned sequentially (1-based) in visit order; the module EXPR itself gets an
    id, then its children get subsequent ids (pre-order);
  - doc-wrapped items are unwrapped: a 4-arg `:macrocall` whose `args[1]` satisfies
    the doc-macro check is visited AS its wrapped item `x.args[4]`, with `offset`
    adjusted past `args[1..3]` (`fullspan` sum) — the docstring itself is never visited;
  - `offset` is the 0-based byte offset of the (unwrapped) node, accumulated from
    `.fullspan` during the walk.

Authoritative references (verify against, mirror exactly):
- Doc-wrapper detection: `headof(x.args[1]) === :globalrefdoc` on a 4-arg `:macrocall` (`src/StaticLint/macros.jl:5`, `src/StaticLint/linting/checks.jl:479`); the generalized `@doc`/`Mod.@doc` matcher is `_is_doc_macro_name` in `src/layer_hover.jl:229-240` — reuse that function (it is already defined in the package) rather than re-implementing.
- Offset adjustment through a doc wrapper: `src/layer_navigation.jl:105-109` (adds `args[1..3]` fullspans, then treats `args[4]` as the node).
- Module EXPR shape `[keyword-flag, name, block]`: name at `x.args[2]`, `bare` iff `headof(x.args[1]) === :FALSE` (`src/StaticLint/scope.jl:172-181`); name extraction as in `src/layer_navigation.jl:149-155` (`CSTParser.isidentifier(x.args[2])`, `valofid`).

- [ ] **Step 1: Write the failing test.** Append to `test/test_inventory.jl`:

```julia
@testitem "inventory walker: visit order, ids, module nesting, doc unwrap, offsets" begin
    using JuliaWorkspaces: _foreach_toplevel_item
    using JuliaWorkspaces: CSTParser

    src = """
    f() = 1
    \"\"\"
    docs for g
    \"\"\"
    g(x) = x
    module M
    h() = 2
    module Inner
    k() = 3
    end
    end
    w() = 4
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        push!(visited, (id=id, parent=copy(parent_module), offset=offset,
                        ismod=CSTParser.defines_module(x)))
    end

    # 7 item-like nodes: f, g (unwrapped), M, h, Inner, k, w — pre-order ids
    @test [v.id for v in visited] == collect(1:7)
    @test visited[1].parent == String[]          # f
    @test visited[2].parent == String[]          # g (doc-unwrapped)
    @test visited[3].ismod                       # M itself, at top level
    @test visited[3].parent == String[]
    @test visited[4].parent == ["M"]             # h
    @test visited[5].ismod                       # Inner
    @test visited[5].parent == ["M"]
    @test visited[6].parent == ["M", "Inner"]    # k
    @test visited[7].parent == String[]          # w

    # Offsets point at the actual item, not the doc wrapper: the byte at g's
    # offset begins the text "g(x)".
    g_off = visited[2].offset
    @test src[g_off + 1] == 'g'
    # And f's offset is 0.
    @test visited[1].offset == 0
end
```

- [ ] **Step 2: Run it, expect failure** (`UndefVarError: _foreach_toplevel_item`):

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventory walker", ti.name))
```

- [ ] **Step 3: Implement.** Append to `src/layer_inventory.jl`:

```julia
# Detect a doc-macro wrapper: a 4-arg :macrocall whose first arg is the
# implicit `globalrefdoc` or an explicit `@doc` / `Mod.@doc`. The wrapped item
# sits at args[4]. Mirrors layer_hover.jl's `_is_doc_expr` shape and
# layer_navigation.jl:105-109's offset handling.
function _doc_wrapped_item(x::CSTParser.EXPR)
    CSTParser.ismacrocall(x) || return nothing
    x.args !== nothing && length(x.args) == 4 || return nothing
    _is_doc_macro_name(x.args[1]) || return nothing
    return x.args[4]
end

"""
    _foreach_toplevel_item(f, cst)

Call `f(x, id, parent_module, offset)` for every top-level item-like node of a
`:file` CST in pre-order: the file's direct children, plus — for
`module`/`baremodule` declarations — the module node itself and then the
children of its body block (never the bodies of functions, structs, etc.).
Ids are sequential in visit order; doc-macro wrappers are transparent (the
wrapped item is visited, with `offset` pointing at it, not the docstring).
This walker is the single source of truth for item ids: the inventory
extractor and the position map both use it, so ids always agree.
"""
function _foreach_toplevel_item(f, cst::CSTParser.EXPR)
    next_id = Ref(0)
    _walk_toplevel!(f, cst.args, String[], 0, next_id)
    return nothing
end

function _walk_toplevel!(f, args, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    args === nothing && return offset
    for a in args
        item = a
        item_offset = offset
        wrapped = _doc_wrapped_item(a)
        if wrapped !== nothing
            for j in 1:3
                item_offset += a.args[j].fullspan
            end
            item = wrapped
        end

        next_id[] += 1
        f(item, next_id[], parent_module, item_offset)

        if CSTParser.defines_module(item) && item.args !== nothing && length(item.args) >= 3
            mod_name = CSTParser.isidentifier(item.args[2]) ? StaticLint.valofid(item.args[2]) : nothing
            if mod_name !== nothing
                inner_parent = vcat(parent_module, [mod_name])
                # Offset of the module block's first child: the module node's
                # offset plus the fullspans of the keyword flag and the name.
                block_offset = item_offset + item.args[1].fullspan + item.args[2].fullspan
                _walk_toplevel!(f, item.args[3].args, inner_parent, block_offset, next_id)
            end
        end

        offset += a.fullspan
    end
    return offset
end
```

Note: `_is_doc_macro_name` and `StaticLint.valofid` already exist (`layer_hover.jl:229-240`, StaticLint utils). If `layer_inventory.jl` is included before `layer_hover.jl` in `packagedef.jl`, the reference resolves at call time (Julia functions resolve late) — no include-order change needed. `StaticLint` is included at `packagedef.jl:29`, i.e. AFTER this file — same late-binding argument applies; verify by running the test.

- [ ] **Step 4: Run the test, expect PASS** (restart first: new functions in an already-loaded file are revisable, but you restarted in Task 1 anyway — `Revise.revise()` should suffice here).

- [ ] **Step 5: Commit:**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat: add the shared top-level item walker with stable ids"
```

---

### Task 3: `derived_file_inventory` — the extractor

**Files:**
- Modify: `src/layer_inventory.jl` (append)
- Test: `test/test_inventory.jl` (append)

**Interfaces:**
- Consumes: `_foreach_toplevel_item` (Task 2), `derived_julia_legacy_syntax_tree(rt, uri)`, `derived_file_include_records(rt, uri)` (`layer_includes.jl:210-212`, gives `(offset, span, target)` per include call — match include calls by offset), `derived_has_content(rt, uri)`, CSTParser predicates, `string(CSTParser.to_codeobject(...))` for rendering.
- Produces: `Salsa.@derived derived_file_inventory(rt, uri) -> FileInventory` (EMPTY_FILE_INVENTORY when no content / not a Julia file).
- Classification parity — the authoritative arms (verify each against the source):
  - assignments / function-call-form assignments / typealias: `src/StaticLint/bindings.jl:57-66`
  - `:function` / `:macro`: `bindings.jl:83-89`; signature via `CSTParser.rem_wheres_decls(CSTParser.get_sig(x))` rendered with `string(CSTParser.to_codeobject(...))` (the idiom of `layer_signatures.jl:194`); render inside `try`, `signature = nothing` on error.
  - modules: `bindings.jl:90-92` (name `args[2]`), bare-ness per `scope.jl:172-181`.
  - datatypes: `bindings.jl:96-115` — kinds `:struct`/`:mutable_struct` (via `CSTParser.defines_struct` + mutability), `:abstract`, `:primitive`; struct `field_names` mirroring `bindings.jl:107-113` (skip `defines_function` members, unwrap `:const`, unwrap kwdef-style assignments unconditionally — recording a defaulted field's name is correct regardless of `@kwdef`, and the inventory must not depend on macro resolution state).
  - `:const` / `:global` wrappers: unwrap to the inner assignment, kind `:const`/`:global`.
  - `` `@enum` ``: mirror `macros.jl:55-67` + `mark_enum_member_binding!` (`macros.jl:147-153`) — emit one `:enum` item for the type name and `:enum_member` items for members (assignment forms unwrapped).
  - `export`/`public` statements: children are identifiers (`references.jl:215,254` context) — collect names into `InventoryExport`.
  - `using`/`import`: parse module paths / symbol lists / `as` aliases from the CST; the authoritative traversal of these forms is `resolve_import` in `src/StaticLint/imports.jl` — mirror its structure walking, but emit plain strings. Relative levels: leading `.` tokens become "." entries in `path`.
  - any other `:macrocall` (not doc, not `@enum`, not testitem-family — leave testitem macros as `:opaque_macrocall` in this milestone; their inventory treatment is Milestone 3+ work per the spec): emit `:opaque_macrocall` with the macro's name and no bindings — exactly as blind as `mark_bindings!`.
  - anything else (bare calls, literals, `if` blocks, …): no item emitted.

- [ ] **Step 1: Write the failing tests.** Append to `test/test_inventory.jl`:

```julia
@testsnippet InventoryWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function inventory_of(src::String; uri=URI("file:///inv/src/F.jl"), extra_files=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        for (u, s) in extra_files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return JuliaWorkspaces.derived_file_inventory(jw.runtime, uri), jw
    end
end

@testitem "inventory extraction: kinds, names, signatures, fields" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    f(x) = x + 1
    function g(a::Int, b; kw=1)
        a + b
    end
    macro m(ex) end
    const C = 1
    global G = 2
    x = 3
    abstract type A end
    struct S
        a
        b::Int
        const c
    end
    mutable struct MS
        q
    end
    @enum Color red green
    module M
    inner() = 1
    end
    @somethingunknown foo bar
    """)

    byname(n) = only(filter(i -> i.name == n, inv.items))

    @test byname("f").kind === :function
    @test byname("f").signature == "f(x)"
    @test byname("g").kind === :function
    @test occursin("g(a::Int, b", byname("g").signature)
    @test byname("m").kind === :macro
    @test byname("C").kind === :const
    @test byname("G").kind === :global
    @test byname("x").kind === :assignment
    @test byname("A").kind === :abstract
    @test byname("S").kind === :struct
    @test byname("S").field_names == ["a", "b", "c"]
    @test byname("MS").kind === :mutable_struct
    @test byname("Color").kind === :enum
    @test byname("red").kind === :enum_member
    @test byname("green").kind === :enum_member
    @test byname("inner").parent_module == ["M"]
    @test only(filter(m -> m.name == "M", inv.modules)).bare == false
    @test any(i -> i.kind === :opaque_macrocall, inv.items)
end

@testitem "inventory extraction: imports, exports, includes" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/a.jl")
    inv, _ = inventory_of("""
    using Base64
    using ..Sibling: helper, other
    import Foo.Bar as FB
    export f, S
    public g
    include("a.jl")
    f() = 1
    """; extra_files=Dict(a_uri => "z() = 1\n"))

    us = inv.imports
    @test any(i -> i.kind === :using && i.path == ["Base64"], us)
    sib = only(filter(i -> "Sibling" in i.path, us))
    @test sib.path == [".", ".", "Sibling"]
    @test sort(sib.symbols) == ["helper", "other"]
    fb = only(filter(i -> i.alias !== nothing, us))
    @test fb.kind === :import
    @test fb.path == ["Foo", "Bar"]
    @test fb.alias == "FB"

    @test only(filter(e -> e.kind === :export, inv.exports)).names == ["f", "S"]
    @test only(filter(e -> e.kind === :public, inv.exports)).names == ["g"]

    @test only(inv.includes).target == a_uri
end

@testitem "inventory firewall: body, comment, and docstring edits compare equal" setup=[InventoryWS] begin
    base(body) = """
    \"\"\"
    docs
    \"\"\"
    function f(x)
        $body
    end
    struct S
        a::Int
    end
    export f
    """

    inv1, _ = inventory_of(base("x + 1"))
    inv2, _ = inventory_of(base("x * 2\n    # a comment"))
    @test isequal(inv1, inv2)
    @test hash(inv1) == hash(inv2)

    # Docstring text is not part of the inventory.
    inv3, _ = inventory_of(replace(base("x + 1"), "docs" => "totally different docs"))
    @test isequal(inv1, inv3)

    # But an API change is.
    inv4, _ = inventory_of(replace(base("x + 1"), "f(x)" => "f(x, y)"))
    @test !isequal(inv1, inv4)
end
```

- [ ] **Step 2: Run them, expect failure** (`UndefVarError: derived_file_inventory`):

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventory extraction", ti.name) || occursin("inventory firewall", ti.name))
```

- [ ] **Step 3: Implement.** Append to `src/layer_inventory.jl` a `Salsa.@derived function derived_file_inventory(rt, uri)` that:

1. Returns `EMPTY_FILE_INVENTORY` unless `derived_has_content(rt, uri)` and the file parses to a `:file` CST (`derived_julia_legacy_syntax_tree`).
2. Fetches `records = derived_file_include_records(rt, uri)` and builds `include_targets_by_offset = Dict(offset => target for (offset, _, target) in records)`.
3. Runs `_foreach_toplevel_item` over the CST with a classifier `_classify_item!(acc, x, id, parent_module, offset, include_targets_by_offset)` implementing the arm list from the Interfaces block. Skeleton (complete the arms against the authoritative citations — the classifier below shows the exact structure and the non-obvious arms in full):

```julia
Salsa.@derived function derived_file_inventory(rt, uri)
    @debug "derived_file_inventory" uri=uri

    derived_has_content(rt, uri) || return EMPTY_FILE_INVENTORY
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return EMPTY_FILE_INVENTORY

    include_targets_by_offset = Dict{Int,Union{Nothing,URI}}(
        offset => target for (offset, _, target) in derived_file_include_records(rt, uri))

    acc = (items=InventoryItem[], imports=InventoryImport[], exports=InventoryExport[],
           includes=InventoryInclude[], modules=InventoryModule[])
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        _classify_item!(acc, x, id, copy(parent_module), offset, include_targets_by_offset)
    end
    return FileInventory(acc.items, acc.imports, acc.exports, acc.includes, acc.modules)
end

_render_sig(x) = try
    sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
    sig === nothing ? nothing : string(CSTParser.to_codeobject(sig))
catch
    nothing
end

function _classify_item!(acc, x, id, parent_module, offset, include_targets_by_offset)
    if CSTParser.defines_module(x)
        # name/bare per bindings.jl:90-92 and scope.jl:172-181
        name = CSTParser.isidentifier(x.args[2]) ? StaticLint.valofid(x.args[2]) : nothing
        name === nothing && return
        push!(acc.modules, InventoryModule(id, name, CSTParser.headof(x.args[1]) === :FALSE, parent_module))
    elseif CSTParser.headof(x) === :function || CSTParser.headof(x) === :macro
        # bindings.jl:83-89
        name = _item_name(CSTParser.get_name(x))
        name === nothing && return
        kind = CSTParser.headof(x) === :function ? :function : :macro
        push!(acc.items, InventoryItem(id, name, kind, _render_sig(x), String[], parent_module))
    elseif CSTParser.defines_datatype(x)
        # bindings.jl:96-115
        ... # :struct/:mutable_struct/:abstract/:primitive + field extraction per bindings.jl:107-113
    elseif CSTParser.isassignment(x)
        # bindings.jl:57-66: function-call form → :function with signature;
        # curly lhs → :assignment (typealias); plain identifier lhs → :assignment
        ...
    elseif CSTParser.headof(x) === :const || CSTParser.headof(x) === :global
        # unwrap and recurse into the inner assignment with kind override
        ...
    elseif CSTParser.headof(x) === :export || CSTParser.headof(x) === :public
        names = String[StaticLint.valofid(a) for a in x.args if CSTParser.isidentifier(a)]
        isempty(names) || push!(acc.exports, InventoryExport(id, CSTParser.headof(x) === :export ? :export : :public, names, parent_module))
    elseif CSTParser.headof(x) === :using || CSTParser.headof(x) === :import
        # mirror imports.jl's structure walking; emit InventoryImport entries
        ...
    elseif _is_include_call(x)  # call named "include" with one argument
        push!(acc.includes, InventoryInclude(id, get(include_targets_by_offset, offset, nothing), parent_module))
    elseif CSTParser.ismacrocall(x)
        if _is_enum_macro(x)   # per macros.jl:55-67: name via _points_to_Base_macro-style check on x.args[1]
            ... # :enum + :enum_member items per macros.jl:147-153
        else
            mname = _macro_name_string(x.args[1])
            push!(acc.items, InventoryItem(id, something(mname, ""), :opaque_macrocall, nothing, String[], parent_module))
        end
    end
    return
end
```

`...` arms are specified fully by the authoritative citations in the Interfaces block; the enum check may match by macro name (`"@enum"` via the same name-string helper used for `:opaque_macrocall`) rather than by `_points_to_Base_macro` (which requires resolution state the inventory must not depend on) — record this deliberate deviation in your report. `_item_name` unwraps an identifier or `var"..."` name via `CSTParser.str_value`, returning `nothing` otherwise (never call `CSTParser.valof` after an `isidentifier` check — `var"..."` identifiers return `nothing` from `valof`).

4. Where an arm's transcription is ambiguous, open the cited source and mirror it.

- [ ] **Step 4: Run the tests, expect PASS.** Iterate on arm details until green (the fixtures encode the contract).

- [ ] **Step 5: Run the includes + lint suite subset, expect 0 failures** (guards against accidental interference — this task adds pure new code, so anything red is a real problem):

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("include", ti.name) || occursin("lint", ti.name))
```

- [ ] **Step 6: Commit:**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat: extract per-file inventories with `@enum` and doc-wrapper parity"
```

---

### Task 4: `derived_item_positions` — the volatile leaf

**Files:**
- Modify: `src/layer_inventory.jl` (append)
- Test: `test/test_inventory.jl` (append)

**Interfaces:**
- Consumes: `_foreach_toplevel_item`, `derived_julia_legacy_syntax_tree`.
- Produces: `Salsa.@derived derived_item_positions(rt, uri) -> Dict{Int,@NamedTuple{expr::CSTParser.EXPR, offset::Int}}` — item-id → (current EXPR, 0-based byte offset). Volatile by design (recomputes every reparse; ids keep meaning). NOTHING in layers 1–3 may ever depend on it; it exists for request-handler last-mile use in later milestones.

- [ ] **Step 1: Write the failing test.** Append:

```julia
@testitem "item positions: ids agree with the inventory and offsets track edits" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    src1 = "f() = 1\ng() = 2\n"
    uri = URI("file:///inv/src/pos.jl")
    inv1, jw = inventory_of(src1; uri=uri)
    pos1 = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)

    f_item = only(filter(i -> i.name == "f", inv1.items))
    g_item = only(filter(i -> i.name == "g", inv1.items))
    @test pos1[f_item.id].offset == 0
    @test src1[pos1[g_item.id].offset + 1] == 'g'

    # A body edit above g shifts g's offset but keeps its id (inventory equal).
    src2 = "f() = 1 + 11111\ng() = 2\n"
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText(src2, "julia")))
    inv2 = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
    @test isequal(inv1, inv2)                       # firewall holds
    pos2 = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)
    @test src2[pos2[g_item.id].offset + 1] == 'g'   # same id, new offset
    @test pos2[g_item.id].offset != pos1[g_item.id].offset
end
```

- [ ] **Step 2: Run it, expect failure** (`UndefVarError: derived_item_positions`).

- [ ] **Step 3: Implement.** Append:

```julia
"""
    derived_item_positions(rt, uri)

Map each inventory item id to its current syntax node and 0-based byte offset.
Volatile: recomputes on every reparse (EXPR identities and offsets change),
which is fine because it is a leaf — semantic layers depend on
`derived_file_inventory` (position-free) only; this query exists solely for
request handlers to reattach locations, docstrings, and defining EXPRs at the
last mile. Depending on this query from any layer-1/2/3 computation is a bug.
"""
Salsa.@derived function derived_item_positions(rt, uri)
    result = Dict{Int,@NamedTuple{expr::CSTParser.EXPR, offset::Int}}()

    derived_has_content(rt, uri) || return result
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return result

    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        result[id] = (expr=x, offset=offset)
    end
    return result
end
```

- [ ] **Step 4: Run the test, expect PASS.**

- [ ] **Step 5: Commit:**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat: add the volatile item-position map"
```

---

### Task 5: Invalidation-property tests (the acceptance criteria)

**Files:**
- Test: `test/test_inventory.jl` (append)

**Interfaces:**
- Consumes: `Salsa.TraceLogging` (`AbstractTraceReceiver`, `TraceSpan`, `receive_span`, `with_tracing`) — every derived re-execution emits a span named after the function; a downstream probe derived function defined inside the testitem (the `Salsa.@derived`-in-test pattern used by Salsa's own suite) observes backdating directly.

- [ ] **Step 1: Write the tests** (these are spec acceptance criteria — expected to pass if Tasks 1–4 are correct; a failure means a bug in those tasks, not in the test):

```julia
@testitem "inventory invalidation: body edits backdate, API edits propagate" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # A downstream consumer of the inventory: recomputes only if the
    # inventory VALUE changed (Salsa early-exit on isequal).
    Salsa.@derived function probe_names(rt, uri)
        inv = JuliaWorkspaces.derived_file_inventory(rt, uri)
        return sort([i.name for i in inv.items])
    end

    uri = URI("file:///inv/src/fw.jl")
    src1 = "f(x) = x + 1\ng() = 2\n"
    _, jw = inventory_of(src1; uri=uri)
    rt = jw.runtime
    @test probe_names(rt, uri) == ["f", "g"]

    # Body edit: inventory re-executes (content changed) but its value is
    # equal, so the probe must NOT re-execute.
    recv = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("f(x) = x * 42\ng() = 2\n", "julia")))
    TL.with_tracing(() -> probe_names(rt, uri), recv)
    @test get(recv.counts, "derived_file_inventory", 0) == 1
    @test get(recv.counts, "probe_names", 0) == 0

    # API edit: both re-execute and the probe sees the new name.
    recv2 = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("f(x) = x * 42\nh() = 2\n", "julia")))
    result = TL.with_tracing(() -> probe_names(rt, uri), recv2)
    @test get(recv2.counts, "probe_names", 0) == 1
    @test result == ["f", "h"]
end
```

- [ ] **Step 2: Run it, expect PASS:**

```julia
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("inventory invalidation", ti.name))
```

If the probe re-executes on the body edit, the inventory is not comparing equal — debug which field differs (`findfirst(!isequal, ...)` over fields) before touching the test.

- [ ] **Step 3: Run the full suite** (`cd` into the package dir, `include("test/runtests.jl")`). Expect exactly the recorded baseline + this milestone's new passes; anything else is a regression to fix before committing.

- [ ] **Step 4: Commit:**

```bash
git add test/test_inventory.jl
git commit -m "test: inventory firewall invalidation properties"
```

---

### Task 6: Real-workspace smoke check (report-only)

**Files:** none (no commits; findings go in the task report)

- [ ] **Step 1:** In the dev-env Julia session, load the repro workspace and exercise the new queries at scale:

```julia
using JuliaWorkspaces
using JuliaWorkspaces.URIs2: filepath2uri
jw = workspace_from_folders(["/home/pfitzseb/git/JuliaWorkspaces.jl"])
rt = jw.runtime
files = collect(JuliaWorkspaces.derived_all_julia_files(rt))
@time invs = [JuliaWorkspaces.derived_file_inventory(rt, u) for u in files];
println("files: ", length(files),
    "  items: ", sum(length(i.items) for i in invs),
    "  imports: ", sum(length(i.imports) for i in invs),
    "  empty inventories: ", count(i -> isequal(i, JuliaWorkspaces.EMPTY_FILE_INVENTORY), invs))
# Firewall at scale: body-edit a large file, re-derive, assert isequal.
target = filepath2uri("/home/pfitzseb/git/JuliaWorkspaces.jl/src/layer_static_lint.jl")
inv_before = JuliaWorkspaces.derived_file_inventory(rt, target)
c = get_text_file(jw, target).content.content * "\n# trailing comment\n"
JuliaWorkspaces.update_file!(jw, TextFile(target, SourceText(c, "julia")))
inv_after = JuliaWorkspaces.derived_file_inventory(rt, target)
println("firewall holds on real file: ", isequal(inv_before, inv_after))
```

- [ ] **Step 2:** Report: total extraction time (expect well under a second for ~550 files), item counts, how many files produced empty inventories (spot-check 3 of them — empty is only correct for files with no top-level items), and whether the firewall held on the real file. Anomalies (crashes on any real file, absurd counts, firewall failure) are bugs — fix under TDD before closing the milestone.

---

## Self-review notes (already applied)

- Spec coverage: implements spec "Layer 1" + "Position reattachment" + the layer-1 slice of "Testing strategy" items 1/3; module tree, analyses, aggregations, differential harness, and the LS.jl gate are later milestones by design.
- Testitem-family macros are deliberately `:opaque_macrocall` in this milestone (spec risk note: their inventory treatment lands with the testsetup re-expression, including the known `args[2]` off-by-one fix).
- The Task 3 classifier shows structure + non-obvious arms; `...` arms are bound to authoritative file:line citations rather than transcribed here, per the parity rule in Global Constraints — the fixtures in Step 1 encode the observable contract for every arm.
