# Macro-Declared Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and resolve the names a modelled macro declares but never spells — `Salsa.@declare_input`'s `foo`/`set_foo!`/`delete_foo!` and `Base.@deprecate`'s deprecated name — so uses of them stop being missing-reference diagnostics and gain hover, completion, go-to-definition and find-references.

**Architecture:** The inventory records one inert `:macro_declared` item per derived name, keyed to the macrocall's first argument. A per-root query confirms the macro's identity — via the environment store for a registry owner, via the owner package's own module tree for a workspace owner — and visibility unions the confirmed names in beside `declared`. The module tree never sees these rows, which keeps it environment-free and keeps the resolution cycle open.

**Tech Stack:** Julia, CSTParser, a Salsa incremental query engine, TestItemRunner.

**Spec:** `docs/superpowers/specs/2026-07-31-macro-declared-names-design.md`. Read it before starting; it explains *why* each of these choices is the way it is.

## Global Constraints

- **Never spawn `julia` from a shell and never run `Pkg.test`.** Use the julia-mcp tool with `env_path=/home/pfitzseb/git/julia-vscode/scripts/environments/development`.
- **Run tests** with `TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("macro-declared", ti.name), verbose=true)`. Every new test name in this plan starts with `macro-declared:` so one filter runs them all.
- **After editing any struct definition, call `julia_restart` for that env first.** Revise cannot apply struct redefinitions; you will otherwise get `@world(...)`-flavoured MethodErrors. Task 2 changes a struct.
- **Use a generous `timeout`** (≥600 s for anything that lints). A `timeout` expiry kills the session and loses all state.
- **`@testitem` bodies need explicit imports** — `using JuliaWorkspaces: ...`. The package's default imports do not apply inside them.
- **`return` does not skip a `@testitem` body** (it is evaluated at module scope). Gate with `if`/`else`.
- **A project-less root publishes no diagnostics.** Assert lint behaviour through `StaticLint.collect_hints` or `derived_file_analysis`, never through `get_diagnostic`.
- **Edit files directly** with your editor tool. Do not write bulk-rewrite scripts against repo files.
- **Run git inside `scripts/packages/JuliaWorkspaces`**, not the julia-vscode root. Branch: `sp/module-inventory-design`.
- **Commit message trailer** on every commit: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

## File Structure

| File | Responsibility for this change |
| --- | --- |
| `src/layer_inventory.jl` | The rule table, name derivation, the `:macro_declared` row and its `declared_by` field. Layer 1: env-free, per-file, no identity judgement. |
| `src/layer_module_tree.jl` | One additive change: a kind filter on the splice walk so the new query can walk `:macro_declared` rows. Stays env-free. |
| `src/layer_visibility.jl` | Confirmation, the index and its per-module projection, and the union into visible names. This is the only file that judges identity. |
| `src/layer_completions.jl`, `src/layer_hover.jl`, `src/layer_symbols.jl`, `src/layer_references.jl` | One consumer arm each. |
| `test/test_inventory.jl` | Tasks 1–2: derivation and row emission. |
| `test/test_macro_declared_names.jl` (new) | Tasks 3–10: confirmation, queries, visibility, end-to-end, consumers, invariants. |

---

### Task 1: Rule table and name derivation

Pure functions over a CST, no queries, no environment. This is the whole of the "which names does this macro declare" knowledge.

**Files:**
- Modify: `src/layer_inventory.jl` (add near `_symbol_name`, around line 480)
- Test: `test/test_inventory.jl`

**Interfaces:**
- Consumes: `_symbol_name(x)` and `CSTParser.get_name(x)`, both already in this file.
- Produces:
  - `const MacroSpelling = @NamedTuple{qualifier::Vector{String}, name::String}`
  - `struct MacroDeclarationRule; owner::Vector{String}; macro_name::String; derive::Function; end`
  - `const MACRO_DECLARATION_RULES::Vector{MacroDeclarationRule}`
  - `_macro_declaration_rule(macro_name::AbstractString) -> Union{Nothing,MacroDeclarationRule}`
  - `_declare_input_names(arg1::CSTParser.EXPR) -> Vector{String}`
  - `_deprecate_names(arg1::CSTParser.EXPR) -> Vector{String}`

- [ ] **Step 1: Write the failing test**

Append to `test/test_inventory.jl`:

```julia
@testitem "macro-declared: name derivation for the modelled macros" begin
    using JuliaWorkspaces: CSTParser, _declare_input_names, _deprecate_names,
        _macro_declaration_rule, MACRO_DECLARATION_RULES

    # The first argument of the macrocall, which is `args[3]`.
    arg1(src) = CSTParser.parse(src, true).args[1].args[3]

    @test _declare_input_names(arg1("@declare_input foo(rt, x::Int)::V")) ==
        ["foo", "set_foo!", "delete_foo!"]
    @test _declare_input_names(arg1("Salsa.@declare_input bar(rt)::Int")) ==
        ["bar", "set_bar!", "delete_bar!"]
    # No `::` return type: Salsa itself rejects this, so we derive nothing.
    @test _declare_input_names(arg1("@declare_input baz(rt)")) == String[]
    # A `::` whose left side is not a call declares nothing either.
    @test _declare_input_names(arg1("@declare_input foo::Int")) == String[]

    @test _deprecate_names(arg1("@deprecate f(x::Int) g(x)")) == ["f"]
    @test _deprecate_names(arg1("@deprecate old new")) == ["old"]
    @test _deprecate_names(arg1("@deprecate f(x::T) where T g(x)")) == ["f"]
    @test _deprecate_names(arg1("Base.@deprecate (+)(a, b) plus(a, b)")) == ["+"]

    r = _macro_declaration_rule("@declare_input")
    @test r !== nothing && r.owner == ["Salsa"]
    @test _macro_declaration_rule("@deprecate").owner == ["Base"]
    @test _macro_declaration_rule("@nope") === nothing
    @test length(MACRO_DECLARATION_RULES) == 2
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run via julia-mcp:

```julia
using TestItemRunner
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("macro-declared", ti.name), verbose=true)
```

Expected: FAIL with `UndefVarError: _declare_input_names not defined`.

- [ ] **Step 3: Implement**

Add to `src/layer_inventory.jl`, after `_symbol_name` (line 480):

```julia
# --- Modelled macros that declare names their argument never spells ---------
#
# A macrocall is transparent to the walker, so a macro that mints extra names
# leaves no trace of them anywhere. Each rule maps a macro to the names its
# FIRST argument implies. `derive` returns an empty vector when the argument is
# not the shape the macro requires — the only error path at this layer.
#
# `owner` is where the macro must come from. Nothing here checks that; it is the
# input to the confirmation step in layer_visibility.jl. Keeping both halves in
# one table is deliberate: the walker needs the names, confirmation needs the
# paths, and two tables would drift.
const MacroSpelling = @NamedTuple{qualifier::Vector{String}, name::String}

struct MacroDeclarationRule
    owner::Vector{String}
    macro_name::String
    derive::Function
end

# `@declare_input foo(rt, x::Int)::V` declares `foo`, `set_foo!`, `delete_foo!`
# (Salsa's declare_input_macro.jl builds the latter two by string interpolation).
function _declare_input_names(arg1::CSTParser.EXPR)
    CSTParser.isdeclaration(arg1) || return String[]
    (arg1.args !== nothing && length(arg1.args) >= 1) || return String[]
    # The left side must be a CALL: `@declare_input x::Int` declares nothing,
    # because Salsa requires the call form.
    CSTParser.iscall(arg1.args[1]) || return String[]
    n = _symbol_name(CSTParser.get_name(arg1.args[1]))
    return n === nothing ? String[] : [n, "set_$(n)!", "delete_$(n)!"]
end

# `@deprecate f(x::Int) g(x)` and `@deprecate old new` both declare the first
# argument's name. `get_name` unwraps a `where` and a getfield; `_symbol_name`
# additionally covers operator names.
function _deprecate_names(arg1::CSTParser.EXPR)
    n = _symbol_name(CSTParser.get_name(arg1))
    return n === nothing ? String[] : [n]
end

const MACRO_DECLARATION_RULES = MacroDeclarationRule[
    MacroDeclarationRule(["Salsa"], "@declare_input", _declare_input_names),
    MacroDeclarationRule(["Base"], "@deprecate", _deprecate_names),
]

function _macro_declaration_rule(macro_name::AbstractString)
    for r in MACRO_DECLARATION_RULES
        r.macro_name == macro_name && return r
    end
    return nothing
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Same command as Step 2. Expected: PASS.

If `_deprecate_names(arg1("Base.@deprecate (+)(a, b) plus(a, b)"))` fails, inspect what `CSTParser.get_name` returns for that node in the REPL and adjust `_deprecate_names` — do not weaken the test.

- [ ] **Step 5: Commit**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat: derive the names a modelled macro declares

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Emit `:macro_declared` rows from the inventory

**Files:**
- Modify: `src/layer_inventory.jl` (`InventoryItem` around line 49, its back-compat constructor at 63, `_classify_item!` at 739)
- Test: `test/test_inventory.jl`

**Interfaces:**
- Consumes: Task 1's `_macro_declaration_rule`, `MacroSpelling`; the existing `_macro_name_string(x)` (line 542) and `_getfield_qualifier(x)` (line 490).
- Produces: `InventoryItem.declared_by::Union{Nothing,MacroSpelling}`; rows with `kind === :macro_declared`; `_emit_macro_declarations!(acc, x, order, id, parent_module)`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_inventory.jl`:

```julia
@testitem "macro-declared: inventory rows for a modelled macrocall" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, _BINDING_ITEM_KINDS, derived_module_tree,
        module_node
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///t/src/T.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    @deprecate oldf newf
    end
    """, "julia")))

    items = derived_file_inventory(jw.runtime, u).items
    md = [it for it in items if it.kind === :macro_declared]

    @test [it.name for it in md] ==
        ["foo", "set_foo!", "delete_foo!", "oldf"]

    # All three @declare_input names share the first argument's id and order.
    @test length(unique(it.id for it in md[1:3])) == 1
    @test length(unique(it.order for it in md[1:3])) == 1
    @test md[4].id != md[1].id

    # The spelling is recorded as written, qualifier included.
    @test md[1].declared_by == (qualifier=["Salsa"], name="@declare_input")
    @test md[4].declared_by == (qualifier=String[], name="@deprecate")

    # Inert: no shape, and outside the binding kinds, so nothing can treat
    # these as declarations before identity is confirmed.
    @test all(it -> it.arity === nothing && it.signature === nothing, md)
    @test :macro_declared ∉ _BINDING_ITEM_KINDS

    # The module tree must not see them.
    node = module_node(derived_module_tree(jw.runtime, u), ["T"])
    @test !haskey(node.declared, "set_foo!")
    @test !haskey(node.declared, "oldf")

    # Ordinary items still carry no spelling.
    ordinary = [it for it in items if it.kind !== :macro_declared]
    @test all(it -> it.declared_by === nothing, ordinary)
end

@testitem "macro-declared: only the first macro argument declares names" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///t/src/S.jl")
    jw = JuliaWorkspace()
    # `newf` is argument 2 and must contribute nothing; an unmodelled macro
    # contributes nothing at all.
    add_file!(jw, TextFile(u, SourceText("""
    @deprecate oldf newf
    @some_other_macro alpha beta
    """, "julia")))

    md = [it for it in derived_file_inventory(jw.runtime, u).items if it.kind === :macro_declared]
    @test [it.name for it in md] == ["oldf"]
end
```

- [ ] **Step 2: Run and confirm failure**

Command from Task 1 Step 2. Expected: FAIL — the `:macro_declared` list is empty, so the first `@test` fails on `String[] != ["foo", …]`.

- [ ] **Step 3: Add the struct field**

In `src/layer_inventory.jl`, change `InventoryItem` (line 49) to add a final field, and add a 9-argument back-compat constructor next to the existing 8-argument one (line 63):

```julia
@auto_hash_equals struct InventoryItem
    order::Int
    id::Int64
    name::String
    qualifier::Vector{String}
    kind::Symbol
    signature::Union{Nothing,String}
    field_names::Vector{String}
    parent_module::Vector{String}
    arity::Union{Nothing,MethodArity}
    # Set only on `:macro_declared` rows: the macro that declares this name, as
    # written at the call site. Identity is confirmed later, in
    # layer_visibility.jl, which needs the spelling to know what to confirm.
    declared_by::Union{Nothing,MacroSpelling}
end

# Back-compat constructors: non-callable items (assignments, consts, enums, …)
# carry no arity, and only `:macro_declared` rows carry a spelling.
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, nothing, nothing)
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, nothing)
```

`MacroSpelling` is defined further down the file than `InventoryItem`; move the `const MacroSpelling = ...` line from Task 1 to just above the `InventoryItem` definition so the type is known when the struct is defined. Leave the rest of Task 1's block where it is.

- [ ] **Step 4: Restart the Julia session**

Run `julia_restart` for the development env. Revise cannot apply a struct redefinition, and skipping this produces confusing MethodErrors.

- [ ] **Step 5: Implement the emission**

In `src/layer_inventory.jl`, add above `_classify_item!` (line 739):

```julia
# Names a modelled macro declares that its argument never spells. The walker is
# transparent through a macrocall, but CSTParser keeps parent links, so a
# statement can still tell that it is the macrocall's FIRST argument — `args[3]`,
# since `args[1]` is the macro name and `args[2]` a zero-span placeholder. Rows
# carry that argument's own id, so every name from one macrocall shares it (the
# shape `@enum` members already use).
#
# Matching is by bare macro name only: nothing here judges which module the macro
# came from, and nothing here reads the environment.
function _emit_macro_declarations!(acc, x, order, id, parent_module)
    p = CSTParser.parentof(x)
    (p isa CSTParser.EXPR && CSTParser.ismacrocall(p)) || return
    (p.args !== nothing && length(p.args) >= 3 && p.args[3] === x) || return
    mname = _macro_name_string(p.args[1])
    mname === nothing && return
    rule = _macro_declaration_rule(mname)
    rule === nothing && return

    spelling = (qualifier=_getfield_qualifier(p.args[1]), name=mname)
    for n in rule.derive(x)
        push!(acc.items, InventoryItem(order, id, n, String[], :macro_declared,
            nothing, String[], parent_module, nothing, spelling))
    end
    return
end
```

Then make it the first line of `_classify_item!`, so the statement's own classification is unaffected:

```julia
function _classify_item!(acc, x, order, id, parent_module, offset, include_targets_by_offset, include_records)
    _emit_macro_declarations!(acc, x, order, id, parent_module)
    if CSTParser.defines_module(x)
```

- [ ] **Step 6: Run the tests and confirm they pass**

Command from Task 1 Step 2. Expected: PASS, all four `macro-declared:` items.

- [ ] **Step 7: Run the two suites this touches, to catch fallout**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("inventory", ti.name) || occursin("module tree", ti.name), verbose=true)
```

Expected: PASS. A failure here means an existing test constructs `InventoryItem` positionally with 9 arguments and now needs the 10th, or an items consumer is surprised by the new kind — fix the consumer, not the test's intent.

- [ ] **Step 8: Commit**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat: record macro-declared names as inert inventory rows

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Confirm the macro's owner

**Files:**
- Modify: `src/layer_visibility.jl` (add near the other internal helpers, above `_visible_names_pass1`)
- Create: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: `derived_module_imports(rt, root, path)`, `derived_module_declared(rt, root, path)`, `derived_workspace_package_roots(rt)`, `derived_module_names(rt, root, path)`, `derived_project_uri_for_root(rt, uri)`, `derived_environment(rt, project_uri)`, `derived_stdlib_only_env(rt)`, and Task 1's `_macro_declaration_rule`.
- Produces: `_macro_owner_confirmed(rt, root::URI, path::Vector{String}, spelling::MacroSpelling) -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `test/test_macro_declared_names.jl`:

```julia
@testsnippet MacroDeclWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_module_visible_names, derived_module_macro_declared_names,
        derived_macro_declared_names_index, _macro_owner_confirmed
    using JuliaWorkspaces.URIs2: URI

    # A workspace with `root_src` as the root file, plus any extra files, plus
    # (optionally) a sibling workspace package that declares `@declare_input`.
    function macro_ws(root_src::String; root_uri=URI("file:///t/src/T.jl"),
                      extra=Dict{URI,String}(), with_salsa_package::Bool=false)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(root_uri, SourceText(root_src, "julia")))
        for (u, s) in extra
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        if with_salsa_package
            add_file!(jw, TextFile(URI("file:///ws/Salsa/Project.toml"), SourceText("""
            name = "Salsa"
            uuid = "1fbf2c77-44e2-4d5d-8131-0fa618a5c278"
            version = "2.5.1"
            """, "toml")))
            add_file!(jw, TextFile(URI("file:///ws/Salsa/src/Salsa.jl"), SourceText("""
            module Salsa
            macro declare_input(ex) end
            export @declare_input
            end
            """, "julia")))
        end
        return jw, root_uri
    end
end

@testitem "macro-declared: owner confirmation via a workspace package" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation fails without the import" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a same-named submodule does not confirm" setup=[MacroDeclWS] begin
    # `Salsa` here is a submodule of this very root, so the import target is
    # `:tree`, not the owner package.
    jw, root = macro_ws("""
    module T
    module Salsa
    macro declare_input(ex) end
    end
    using .Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a local macro shadows the bare spelling only" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    macro declare_input(ex) end
    @declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    # Bare: the local macro wins, so this is confirmed FOREIGN.
    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
    # Qualified: a local macro cannot shadow `Salsa.@declare_input`.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation via the environment store" setup=[MacroDeclWS] begin
    # Base is always in the baked stdlib stores, so this exercises the store
    # branch with no workspace package involved.
    jw, root = macro_ws("""
    module T
    @deprecate oldf newf
    end
    """)

    # `Base` needs no import to be in scope, so the spelling check accepts a
    # bare or `Base.`-qualified use without an import record.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@deprecate"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Base"], name="@deprecate"))
end
```

- [ ] **Step 2: Run and confirm failure**

Command from Task 1 Step 2. Expected: FAIL with `UndefVarError: _macro_owner_confirmed not defined` (the `@testsnippet` import line fails first, which is the same signal).

- [ ] **Step 3: Implement**

Add to `src/layer_visibility.jl`, above `_visible_names_pass1`:

```julia
# --- Macro identity confirmation --------------------------------------------
#
# A `:macro_declared` inventory row is a claim conditional on the wrapping macro
# really being the one we model. Confirming it is two checks: does the spelling
# point at the owner (structural, from classified imports), and does the owner
# actually provide that macro (the environment store for a registry owner, the
# owner package's own tree for a workspace one).
#
# This lives here, not in the module tree, because it reads `env`: the tree must
# stay env-free. Reading the TREE from here is fine — no tree consumes this — but
# reading VISIBILITY from here would close the resolution cycle. Do not.

# `Base` and `Core` are in scope in every module without an import.
const _IMPLICIT_MACRO_OWNERS = (["Base"], ["Core"])

# The import of `path`'s own module that could bring `spelling` in, or `nothing`.
# Only this module's imports count: Julia does not inherit an enclosing module's
# `using`, and `_visible_names_pass1` reads `path`'s imports alone for the same
# reason.
function _macro_owner_import(rt, root::URI, path::Vector{String},
                             spelling::MacroSpelling, owner::Vector{String})
    for ri in derived_module_imports(rt, root, path)
        ri.target.path == owner || continue
        if isempty(spelling.qualifier)
            # A bare `@declare_input` needs the name brought in: a wildcard
            # `using Salsa`, or a colon-list naming the macro.
            if isempty(ri.symbols)
                ri.kind === :using && return ri
            else
                any(s -> s.name == spelling.name, ri.symbols) && return ri
            end
        else
            # A qualified `Salsa.@declare_input` needs the QUALIFIER bound to the
            # owner module — by `using`/`import Salsa`, or under an `as` alias.
            bound = ri.alias !== nothing ? ri.alias :
                (isempty(ri.target.path) ? nothing : last(ri.target.path))
            bound == spelling.qualifier[1] && return ri
        end
    end
    return nothing
end

# Does the environment's store for `owner` provide `macro_name`?
function _env_provides_macro(rt, root::URI, owner::Vector{String}, macro_name::String)
    project_uri = derived_project_uri_for_root(rt, root)
    env = project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
    store = get(env.symbols, Symbol(owner[1]), nothing)
    store isa SymbolServer.ModuleStore || return false
    for seg in owner[2:end]
        store = get(store.vals, Symbol(seg), nothing)
        store isa SymbolServer.ModuleStore || return false
    end
    return haskey(store.vals, Symbol(macro_name))
end

# Does the workspace package `owner` declare `macro_name` in its own tree?
# `derived_module_names` rather than `derived_module_declared`: it is id-free, so
# an item-id shift in the owner package does not invalidate us, and it carries
# kinds, so we can require an actual macro.
function _workspace_package_provides_macro(rt, owner::Vector{String}, macro_name::String)
    roots = derived_workspace_package_roots(rt)
    entry = get(roots, owner[1], nothing)
    entry === nothing && return false
    return get(derived_module_names(rt, entry, owner), macro_name, nothing) === :macro
end

function _macro_owner_confirmed(rt, root::URI, path::Vector{String}, spelling::MacroSpelling)
    rule = _macro_declaration_rule(spelling.name)
    rule === nothing && return false
    owner = rule.owner

    # A local macro of the same name shadows a BARE use — but not a qualified
    # one, which names its module explicitly.
    if isempty(spelling.qualifier) &&
            haskey(derived_module_declared(rt, root, path), spelling.name)
        return false
    end

    if owner in _IMPLICIT_MACRO_OWNERS
        # No import needed; a qualifier, if written, must still be the owner.
        isempty(spelling.qualifier) || spelling.qualifier == owner || return false
        return _env_provides_macro(rt, root, owner, spelling.name)
    end

    ri = _macro_owner_import(rt, root, path, spelling, owner)
    ri === nothing && return false

    if ri.target.sort === :workspace_package
        return _workspace_package_provides_macro(rt, owner, spelling.name)
    elseif ri.target.sort === :external
        return _env_provides_macro(rt, root, owner, spelling.name)
    else
        # `:tree` is a same-named submodule of THIS root, `:unresolved` is a
        # target we could not place. Neither is the owner.
        return false
    end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Command from Task 1 Step 2. Expected: PASS for all five confirmation items (the earlier inventory items keep passing too).

- [ ] **Step 5: Commit**

```bash
git add src/layer_visibility.jl test/test_macro_declared_names.jl
git commit -m "feat: confirm a modelled macro's owner before trusting its names

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The index and its per-module projection

**Files:**
- Modify: `src/layer_module_tree.jl` (`_walk_spliced_binding_items!` at 755-783)
- Modify: `src/layer_visibility.jl` (the two new queries, below `_macro_owner_confirmed`)
- Test: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: Task 3's `_macro_owner_confirmed`; `_walk_spliced_binding_items!`.
- Produces:
  - `derived_macro_declared_names_index(rt, root) -> Dict{Tuple{Vector{String},String},ItemRef}`
  - `derived_module_macro_declared_names(rt, root, path) -> Dict{String,ItemRef}`
  - `_walk_spliced_binding_items!(emit, rt, F, P, name, visited; kinds=_BINDING_ITEM_KINDS)`

- [ ] **Step 1: Write the failing test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: the index records confirmed names only" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    idx = derived_macro_declared_names_index(jw.runtime, root)
    @test sort([n for ((p, n), _) in idx if p == ["T"]]) ==
        ["delete_foo!", "foo", "set_foo!"]

    names = derived_module_macro_declared_names(jw.runtime, root, ["T"])
    @test sort(collect(keys(names))) == ["delete_foo!", "foo", "set_foo!"]
    # All three point at the one declaring statement.
    @test length(unique(values(names))) == 1
    @test names["foo"].file == root

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T", "Nope"]))
end

@testitem "macro-declared: an unconfirmed macrocall records nothing" setup=[MacroDeclWS] begin
    # No Salsa package in the workspace and no project, so the owner cannot be
    # confirmed by either branch.
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """)

    @test isempty(derived_macro_declared_names_index(jw.runtime, root))
    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
end

@testitem "macro-declared: a duplicate name resolves last-in-splice-order" setup=[MacroDeclWS] begin
    inc = URI("file:///t/src/inc.jl")
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    include("inc.jl")
    end
    """; extra=Dict(inc => """
    Salsa.@declare_input foo(rt)::Int
    """), with_salsa_package=true)

    names = derived_module_macro_declared_names(jw.runtime, root, ["T"])
    # The included file is spliced after the root's own statement, so its
    # declaration wins — the same rule `_declare!` applies.
    @test names["set_foo!"].file == inc
end

@testitem "macro-declared: names land in the module that declares them" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    module Inner
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    end
    end
    """; with_salsa_package=true)

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
    @test haskey(derived_module_macro_declared_names(jw.runtime, root, ["T", "Inner"]), "set_foo!")
end
```

- [ ] **Step 2: Run and confirm failure**

Expected: FAIL with `UndefVarError: derived_macro_declared_names_index not defined`.

- [ ] **Step 3: Add the kind filter to the splice walk**

In `src/layer_module_tree.jl`, change the signature at line 755 and the filter at 761, and thread `kinds` through the recursive call at 779:

```julia
function _walk_spliced_binding_items!(emit, rt, F::URI, P::Vector{String}, name,
                                      visited::Set{URI}; kinds=_BINDING_ITEM_KINDS)
```

```julia
        if (name === nothing || item.name == name) && item.kind in kinds
```

```julia
            _walk_spliced_binding_items!(emit, rt, inc.target, vcat(P, inc.parent_module), name, visited; kinds)
```

The default keeps every existing caller behaving exactly as before; this adds a second explicit filter set rather than loosening the existing one.

- [ ] **Step 4: Implement the queries**

Add to `src/layer_visibility.jl`, below `_macro_owner_confirmed`:

```julia
"""
    derived_macro_declared_names_index(rt, root) -> Dict{Tuple{Vector{String},String},ItemRef}

Every `(module path, name) => declaring item` a CONFIRMED modelled macro declares
anywhere in `root`'s tree. One splice walk over `:macro_declared` inventory rows,
in the same DFS order the module tree uses, so a duplicate name resolves
last-in-splice-order-wins exactly like `_declare!`.

Funnelled through one per-root node for the same reason as
[`derived_method_arities_index`](@ref): the walk reads every file in the root, so a
per-name node would depend on every file. Identity is confirmed once per distinct
`(module path, spelling)`, not once per macrocall.

Reads the module tree and the environment; never visibility, which would close the
cycle this whole layering exists to keep open.
"""
Salsa.@derived function derived_macro_declared_names_index(rt, root)
    @debug "derived_macro_declared_names_index" root=root

    result = Dict{Tuple{Vector{String},String},ItemRef}()
    confirmed = Dict{Tuple{Vector{String},MacroSpelling},Bool}()
    _walk_spliced_binding_items!(rt, root, String[], nothing, Set{URI}([root]);
                                 kinds=(:macro_declared,)) do F, item, loc
        spelling = item.declared_by
        spelling === nothing && return
        ok = get!(() -> _macro_owner_confirmed(rt, root, loc, spelling), confirmed, (loc, spelling))
        ok || return
        result[(loc, item.name)] = ItemRef(F, item.id)
    end
    return result
end

"""
    derived_module_macro_declared_names(rt, root, path) -> Dict{String,ItemRef}

The confirmed macro-declared names of one module: a thin projection of
[`derived_macro_declared_names_index`](@ref), so each module backdates
independently. Empty for a module with no confirmed modelled macrocall, which is
almost every module.
"""
Salsa.@derived function derived_module_macro_declared_names(rt, root, path)
    @debug "derived_module_macro_declared_names" root=root path=path

    result = Dict{String,ItemRef}()
    for ((p, n), ref) in derived_macro_declared_names_index(rt, root)
        p == path && (result[n] = ref)
    end
    return result
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

Expected: PASS.

- [ ] **Step 6: Run the module-tree suite, which owns the walk you changed**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("module tree", ti.name) || occursin("arities", ti.name) ||
        occursin("method items", ti.name) || occursin("extension", ti.name), verbose=true)
```

Expected: PASS. Any failure means the `kinds` default was not applied to every call site.

- [ ] **Step 7: Commit**

```bash
git add src/layer_module_tree.jl src/layer_visibility.jl test/test_macro_declared_names.jl
git commit -m "feat: index the confirmed macro-declared names per root

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Union the names into visibility

**Files:**
- Modify: `src/layer_visibility.jl` (`_visible_names_impl_body` at 629)
- Test: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: Task 4's `derived_module_macro_declared_names`.
- Produces: `derived_module_visible_names(rt, root, path)` entries with `kind = :macro_declared`, `origin = :declared`, `origin_module = path`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: confirmed names are visible in their module" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].origin === :declared
    @test vis["set_foo!"].origin_module == ["T"]
    @test vis["set_foo!"].item !== nothing
end

@testitem "macro-declared: a real declaration beats a macro-declared name" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    set_foo!(rt, x, v) = nothing
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    # The hand-written method wins: it is real text.
    @test vis["set_foo!"].kind === :function
end

@testitem "macro-declared: a macro-declared name beats a wildcard bring-in" setup=[MacroDeclWS] begin
    prov = URI("file:///ws/Prov/src/Prov.jl")
    jw, root = macro_ws("""
    module T
    using Salsa
    using .Sub
    Salsa.@declare_input foo(rt, x::Int)::V
    module Sub
    set_foo!() = 1
    export set_foo!
    end
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    # Declaration tier (3) beats a wildcard `using` bring-in (tier 1).
    @test vis["set_foo!"].kind === :macro_declared
end

@testitem "macro-declared: the union is a no-op without a modelled macrocall" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    f(x) = x
    end
    """; with_salsa_package=true)

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "f")
    @test !any(vn -> vn.kind === :macro_declared, values(vis))
end
```

- [ ] **Step 2: Run and confirm failure**

Expected: FAIL — `haskey(vis, "set_foo!")` is false.

- [ ] **Step 3: Implement**

In `src/layer_visibility.jl`, in `_visible_names_impl_body`, immediately after the pass-1 call:

```julia
    result, _ = _visible_names_pass1(rt, root, path, visited)

    # Confirmed macro-declared names (layer: `derived_module_macro_declared_names`)
    # rank as DECLARATIONS: `origin = :declared` gives them `_tier` 3, so pass 2
    # cannot displace them and a wildcard bring-in from pass 1 loses to them. A
    # name the module really declares wins, because that one is written text.
    #
    # `origin = :declared` without a matching `derived_module_declared` entry is
    # deliberate — see the spec. Consumers that branch on this origin must
    # tolerate the name being absent from that dict.
    let declared = derived_module_declared(rt, root, path)
        for (name, ref) in derived_module_macro_declared_names(rt, root, path)
            haskey(declared, name) && continue
            result[name] = VisibleName(:macro_declared, :declared, ref, path)
        end
    end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Expected: PASS.

- [ ] **Step 5: Run the visibility-adjacent suites**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("visib", ti.name) || occursin("module tree", ti.name) ||
        occursin("scope modules", ti.name), verbose=true)
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/layer_visibility.jl test/test_macro_declared_names.jl
git commit -m "feat: union confirmed macro-declared names into visibility

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The two paths that bypass visible names

`using .Sub` and `using .Sub: set_foo!` read the target module's `declared`/`names` directly, so they miss the union from Task 5.

**Files:**
- Modify: `src/layer_visibility.jl` (`_target_bring_ins` `:tree` branch at 142-166; `_member_lookup` `:tree` and `:workspace_package` branches at 246-266)
- Test: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: `derived_module_macro_declared_names`.
- Produces: no new names; existing entry points gain macro-declared coverage.

- [ ] **Step 1: Write the failing test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: an exported name comes in through `using .Sub`" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    module Sub
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    export set_foo!
    end
    using .Sub
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].item !== nothing
end

@testitem "macro-declared: a colon-list member keeps its kind and item" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    module Sub
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    end
    using .Sub: set_foo!
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    # Without the fix this binds as `:unknown` with no item, so hover and
    # go-to-definition go dead even though the name resolves.
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].item !== nothing
end
```

- [ ] **Step 2: Run and confirm failure**

Expected: FAIL — the first item has no `set_foo!` at all; the second has it with `kind === :unknown`.

- [ ] **Step 3: Fix `_target_bring_ins`**

In the `:tree` / `kind === :using` branch, add the macro-declared lookup and consult it when the exported name is not in `names`:

```julia
        if kind === :using
            names = derived_module_names(rt, root, tp)
            exports = derived_module_exports(rt, root, tp).exports
            declared = derived_module_declared(rt, root, tp)
            mdecl = derived_module_macro_declared_names(rt, root, tp)
            for name in exports
                if haskey(names, name)
                    mt = names[name] === :module ? ImportTarget(:tree, vcat(tp, [name])) : nothing
                    push!(entries, (name, VisibleName(names[name], :using_tree, declared[name], tp), mt))
                elseif haskey(mdecl, name)
                    # Exported and declared by a confirmed modelled macro: not in
                    # `names`, because those come from the tree's `declared`.
                    push!(entries, (name, VisibleName(:macro_declared, :using_tree, mdecl[name], tp), nothing))
                else
```

Leave the existing `else` body (the `:unknown` re-export case) as it is.

- [ ] **Step 4: Fix `_member_lookup`**

In the `:tree` branch, after the `names` lookup fails, try the macro-declared names before giving up:

```julia
        names = derived_module_names(rt, root, tp)
        if !haskey(names, member_name)
            ref = get(derived_module_macro_declared_names(rt, root, tp), member_name, nothing)
            ref === nothing && return (:unknown, nothing, tp, nothing)
            return (:macro_declared, ref, tp, nothing)
        end
        mt = names[member_name] === :module ? ImportTarget(:tree, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_module_declared(rt, root, tp)[member_name], tp, mt)
```

Apply the same shape in the `:workspace_package` branch, using `entry` as the root:

```julia
        names = derived_module_names(rt, entry, tp)
        if !haskey(names, member_name)
            ref = get(derived_module_macro_declared_names(rt, entry, tp), member_name, nothing)
            ref === nothing && return (:unknown, nothing, tp, nothing)
            return (:macro_declared, ref, tp, nothing)
        end
        mt = names[member_name] === :module ? ImportTarget(:workspace_package, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_module_declared(rt, entry, tp)[member_name], tp, mt)
```

- [ ] **Step 5: Run the tests and confirm they pass**

Expected: PASS.

- [ ] **Step 6: Run the visibility suites again**

Command from Task 5 Step 5. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/layer_visibility.jl test/test_macro_declared_names.jl
git commit -m "feat: bring macro-declared names in through using and colon-lists

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: End-to-end — the diagnostics go away, and none appear

This is the point of the whole change. It also pins the one regression the change could introduce: the declaration site's own identifier goes from unresolved-and-exempt to resolved, and must not start being reported as a bad call.

**Drive the PER-FILE pass, not the whole-closure one.** These tests take their
meta from `derived_file_analysis(rt, root, uri)`, never from
`derived_static_lint_meta_for_root`. Only the per-file pass
(`semantic_pass(...; module_context=...)`) resolves through the visibility layer,
so only it sees the union this feature adds — and it is also the live path:
`derived_diagnostics` → `derived_new_static_lint_diagnostics` →
`derived_file_analysis(...).diagnostics` (`layer_file_analysis.jl:834`). The
whole-closure query is reached only by the old per-root diagnostics
(`layer_static_lint.jl:192`) and will report the generated names as missing no
matter how correct the feature is.

**Files:**
- Test only: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: nothing.

- [ ] **Step 1: Write the test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: uses of the generated names are not missing refs" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, CSTParser, derived_static_lint_meta_for_root,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        foo(rt, 1)
        set_foo!(rt, 1, 2)
        delete_foo!(rt, 1)
    end
    end
    """; with_salsa_package=true)

    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    res = derived_static_lint_meta_for_root(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, res.workspace_packages, res.meta_dict, :all)
    flagged = [CSTParser.valof(x) for (_, x) in hints]

    @test "set_foo!" ∉ flagged
    @test "delete_foo!" ∉ flagged
    @test "foo" ∉ flagged
    # And nothing new: `Salsa` itself is a workspace package here, so it resolves.
    @test isempty(flagged)
end

@testitem "macro-declared: the declaration site is not reported as a bad call" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, derived_static_lint_meta_for_root,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    res = derived_static_lint_meta_for_root(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, res.workspace_packages, res.meta_dict, :all)

    # `foo` at the declaration now RESOLVES (it did not before), and it is not a
    # definition signature, so it reads as a call. It must not be flagged.
    errs = [StaticLint.errorof(x, res.meta_dict) for (_, x) in hints]
    @test !any(e -> e === StaticLint.IncorrectCallArgs, errs)
end

@testitem "macro-declared: an unconfirmed macro still flags its names" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, CSTParser, derived_static_lint_meta_for_root,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    # A LOCAL `@declare_input` (bare spelling) is confirmed foreign, so the
    # generated names do not exist and their uses must be reported.
    jw, root = macro_ws("""
    module T
    macro declare_input(ex) end
    @declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """)

    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    res = derived_static_lint_meta_for_root(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, res.workspace_packages, res.meta_dict, :all)
    @test "set_foo!" in [CSTParser.valof(x) for (_, x) in hints]
end
```

- [ ] **Step 2: Run the tests**

Expected: PASS. If the first item reports `Salsa` as flagged, the workspace-package fixture is not being picked up — check `derived_workspace_package_roots(jw.runtime)` in the REPL before changing the test.

If the second item FAILS, that is a real regression and the fix belongs in `StaticLint`: the declaration site must not be arity-checked. Add the guard, then re-run.

- [ ] **Step 3: Commit**

```bash
git add test/test_macro_declared_names.jl
git commit -m "test: pin the end-to-end diagnostic behaviour for macro-declared names

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Consumer arms — completions, hover, symbols

**Files:**
- Modify: `src/layer_completions.jl` (`_completion_kind_for_visible`, ~line 976)
- Modify: `src/layer_hover.jl` (the visible-name kind dispatch, ~line 528)
- Modify: `src/layer_symbols.jl` (the items loop, ~line 299)
- Test: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: `VisibleName.kind === :macro_declared`; `InventoryItem.kind === :macro_declared`.
- Produces: no new API.

- [ ] **Step 1: Write the failing test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: completion kind is a method, not a variable" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: _completion_kind_for_visible, CompletionKinds

    @test _completion_kind_for_visible(:macro_declared) == CompletionKinds.Method
end

```

(The workspace-symbols test also already exists, added in Task 2's fix round
alongside the skip. Do not duplicate it here.)

- [ ] **Step 2: Run and confirm failure**

Expected: FAIL — `:macro_declared` falls into `_completion_kind_for_visible`'s `else` and returns `CompletionKinds.Variable`.

- [ ] **Step 3: Add the completion arm**

In `src/layer_completions.jl`, in `_completion_kind_for_visible`:

```julia
    elseif kind in (:function, :macro, :macro_declared)
        return CompletionKinds.Method
```

- [x] **Step 4: Add the symbols skip — ALREADY DONE IN TASK 2**

This landed in Task 2's fix round: leaving it until now let unconfirmed rows
surface as phantom workspace symbols, which Task 2's own inert-rows invariant
forbids. `src/layer_symbols.jl` already skips `:macro_declared` beside
`:opaque_macrocall`, with a test. Verify it is present and move on; do not
re-implement it.

- [ ] **Step 5: Add the hover arm**

In `src/layer_hover.jl`, the `TreeRef` kind dispatch is a chain starting `if tr.kind === :module` (~line 520) whose second arm is `elseif tr.kind in (:function, :macro, :struct, ...)` (~528). Add a new arm **before** that one, so the store-backed rendering never sees this kind:

```julia
    elseif tr.kind === :macro_declared
        # A name a modelled macro declares. There is no expansion to re-print and
        # no recorded signature, and the defining EXPR is the DECLARING statement
        # (`foo(rt, x::Int)::V`) — printing that as this name's signature would be
        # a fabrication for `set_foo!`. Name, declaring macro, docstring; no
        # signature.
        documentation = string(documentation, "```julia\n", tr.name, "\n```\n")
        spelling = _macro_declared_spelling(rt, tr.item)
        spelling === nothing ||
            (documentation = string(documentation, "declared by `", spelling, "`\n\n"))
        return _tree_item_fallback_hover(tr.item, documentation, rt)
```

and add the helper next to `_tree_item_fallback_hover` (line 600):

```julia
# The macro that declares `item`'s name, as written at the call site
# (`Salsa.@declare_input`), or `nothing` when `item` is not a macro-declared row.
function _macro_declared_spelling(rt, item::Union{Nothing,ItemRef})
    item === nothing && return nothing
    for it in derived_file_inventory(rt, item.file).items
        it.id == item.id && it.kind === :macro_declared || continue
        s = it.declared_by
        s === nothing && continue
        return isempty(s.qualifier) ? s.name : string(join(s.qualifier, "."), ".", s.name)
    end
    return nothing
end
```

- [ ] **Step 6: Write the hover test**

```julia
@testitem "macro-declared: hover names the declaring macro and no signature" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_hover_text, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """; with_salsa_package=true)

    src = String(get_text_file(jw, root).content)
    off = first(findfirst("set_foo!(rt, 1, 2)", src)) - 1
    h = get_hover_text(jw, root, off)
    @test h !== nothing
    @test occursin("set_foo!", h)
    @test occursin("@declare_input", h)
    # The input's own signature must not be presented as this name's signature.
    @test !occursin("foo(rt, x::Int)", h)
end
```

If `get_text_file` is not the accessor for a file's text, use whatever `test/test_hover.jl` uses to build offsets and keep the four assertions.

- [ ] **Step 7: Run all `macro-declared` tests**

Expected: PASS.

- [ ] **Step 8: Run the consumer suites**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("completion", ti.name) || occursin("hover", ti.name) ||
        occursin("symbol", ti.name), verbose=true)
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/layer_completions.jl src/layer_hover.jl src/layer_symbols.jl test/test_macro_declared_names.jl
git commit -m "feat: teach completions, hover and symbols the macro-declared kind

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Go-to-definition works; rename refuses

Go-to-definition needs no code change — `:macro_declared` falls out of `_DEF_METHOD_ITEM_KINDS` into the item-definition path. Test it, then add the rename refusal, which does need code.

**Files:**
- Modify: `src/layer_references.jl` (`_can_rename`, ~line 683)
- Test: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: `_reference_target(runtime, root, uri, x, meta_dict)`; `derived_file_inventory`.
- Produces: `_can_rename` returns `nothing` for a `:macro_declared` target.

- [ ] **Step 1: Write the failing test**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: go-to-definition lands on the declaring macrocall" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_definitions, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """; with_salsa_package=true)

    src = String(get_text_file(jw, root).content)
    off = first(findfirst("set_foo!(rt, 1, 2)", src)) - 1
    defs = get_definitions(jw, root, off)
    @test length(defs) == 1
    @test defs[1].uri == root
    # It lands on the declaring statement `foo(rt, x::Int)::V`, which starts at
    # the same offset the `Salsa.@declare_input ` prefix ends at.
    @test defs[1].range.start.line == 2
end

@testitem "macro-declared: find-references matches on name, not just id" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_references, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
        set_foo!(rt, 3, 4)
        delete_foo!(rt, 1)
    end
    end
    """; with_salsa_package=true)

    src = String(get_text_file(jw, root).content)
    off = first(findfirst("set_foo!(rt, 1, 2)", src)) - 1
    refs = get_references(jw, root, off)
    # All three names share one id, so an id-only join would return the
    # `delete_foo!` site too. Only the two `set_foo!` uses may come back.
    @test length(refs) == 2
end

@testitem "macro-declared: rename is refused" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: can_rename, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    g(x) = x
    end
    """; with_salsa_package=true)

    src = String(get_text_file(jw, root).content)
    # A generated name: refused, because the declaration site has no such token.
    off = first(findfirst("set_foo!(rt, 1, 2)", src)) - 1
    @test can_rename(jw, root, off) === nothing

    # An ordinary declaration is still renameable.
    off_g = first(findfirst("g(x) = x", src)) - 1
    @test can_rename(jw, root, off_g) !== nothing
end
```

If `defs[1].range` is shaped differently, keep the `uri` and count assertions and drop the line assertion rather than weakening the rest.

- [ ] **Step 2: Run and confirm failure**

Expected: the definitions item PASSES already (that is the point — it needs no code); the rename item FAILS because `_can_rename` returns a range unconditionally.

If the definitions item fails, stop and investigate before touching rename: something upstream is not producing the `ItemRef`.

- [ ] **Step 3: Implement the refusal**

In `src/layer_references.jl`, `_can_rename` currently returns the token's range without resolving anything. Resolve the target and refuse a macro-declared one:

```julia
function _can_rename(runtime, uri::URI, offset::Int)
    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return nothing

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x isa CSTParser.EXPR || return nothing

    # A name a modelled macro declares cannot be renamed: the declaring
    # statement contains no token spelling it, so there is nothing to rewrite
    # there and the rename would leave the code broken. Renaming the whole
    # family is a separate change.
    _is_macro_declared_target(runtime, root, uri, x) && return nothing

    loc = _get_file_loc(x, runtime)
    loc === nothing && return nothing
    _, x_start = loc

    return (start=_offset_to_position(runtime, uri, x_start), stop=_offset_to_position(runtime, uri, x_start + x.span))
end

# True when `x` resolves to a name a modelled macro declares.
function _is_macro_declared_target(runtime, root::URI, uri::URI, x::CSTParser.EXPR)
    # Same accessor every other request handler in this file uses (see `:551`,
    # `:599`, `:633`, `:714`) — the per-file analysis, not the whole-root meta.
    meta_dict = derived_file_analysis(runtime, root, uri).meta
    tgt = _reference_target(runtime, root, uri, x, meta_dict)
    (tgt === nothing || tgt[1] !== :tree) && return false
    ref = tgt[2]
    for it in derived_file_inventory(runtime, ref.file).items
        it.id == ref.id && it.kind === :macro_declared && it.name == CSTParser.valof(x) && return true
    end
    return false
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Expected: PASS.

- [ ] **Step 5: Run the references suite**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter=ti->occursin("reference", ti.name) || occursin("rename", ti.name) ||
        occursin("navigation", ti.name), verbose=true)
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/layer_references.jl test/test_macro_declared_names.jl
git commit -m "feat: refuse rename on a macro-declared name

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Invariants and stability regressions

Three properties that are easy to break later and hard to notice: the index must never read visibility, the recorded ids must be stable under insertion, and the id-free visibility projection must still backdate.

**Files:**
- Test only: `test/test_macro_declared_names.jl`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Write the tests**

Append to `test/test_macro_declared_names.jl`:

```julia
@testitem "macro-declared: the index does not read visibility" setup=[MacroDeclWS] begin
    # If `derived_macro_declared_names_index` ever consulted visibility, this
    # computation would re-enter an in-progress query. Salsa raises
    # DependencyCycleException for that — but only under debug mode, so assert
    # debug mode is on, or the failure mode becomes unbounded recursion instead
    # (see layer_visibility.jl's note on the same hazard).
    using JuliaWorkspaces: Salsa
    @test Salsa.Debug.debug_enabled()

    jw, root = macro_ws("""
    module T
    using Salsa
    using .Sub
    Salsa.@declare_input foo(rt, x::Int)::V
    module Sub
    bar() = 1
    export bar
    end
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test haskey(vis, "bar")
end

@testitem "macro-declared: ids survive an insertion above the declarations" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: derived_file_inventory

    ids_for(src) = begin
        jw, root = macro_ws(src; with_salsa_package=true)
        Dict(it.name => it.id
             for it in derived_file_inventory(jw.runtime, root).items
             if it.kind === :macro_declared)
    end

    before = ids_for("""
    module T
    using Salsa
    Salsa.@declare_input a(rt)::Int
    Salsa.@declare_input b(rt)::Int
    end
    """)
    after = ids_for("""
    module T
    using Salsa
    Salsa.@declare_input z(rt)::Int
    Salsa.@declare_input a(rt)::Int
    Salsa.@declare_input b(rt)::Int
    end
    """)

    # The id key includes the input's own name, so inserting one above the
    # others leaves theirs untouched. Every derived value carrying these
    # ItemRefs depends on this.
    for n in ("a", "set_a!", "delete_a!", "b", "set_b!", "delete_b!")
        @test before[n] == after[n]
    end
end

@testitem "macro-declared: cross-root qualified access resolves" setup=[MacroDeclWS] begin
    # `Pkg.set_foo!` from a consumer root — the shape the language server itself
    # uses, and the one that goes through `qualified_module_target` →
    # `_get_field(::TreeModuleContext)` → the ID-FREE visibility projection.
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis

    consumer = URI("file:///ws/App/src/App.jl")
    jw, _ = macro_ws("""
    module Prov
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    export set_foo!
    end
    """; root_uri=URI("file:///ws/Prov/src/Prov.jl"), with_salsa_package=true)
    add_file!(jw, TextFile(URI("file:///ws/Prov/Project.toml"), SourceText("""
    name = "Prov"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0009"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/App/Project.toml"), SourceText("""
    name = "App"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee000a"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(consumer, SourceText("""
    module App
    using Prov
    f(rt) = Prov.set_foo!(rt, 1, 2)
    end
    """, "julia")))

    fa = derived_file_analysis(jw.runtime, consumer, consumer)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, consumer)
    ids = CSTParser.EXPR[]
    walk(x) = (CSTParser.headof(x) === :IDENTIFIER && push!(ids, x);
               x.args === nothing || foreach(walk, x.args))
    walk(cst)
    target = only(filter(i -> CSTParser.valof(i) == "set_foo!", ids))
    @test StaticLint.hasref(target, fa.meta)
end

@testitem "macro-declared: origin :declared consumers tolerate the missing declared entry" setup=[MacroDeclWS] begin
    # These entries claim `origin = :declared` without a matching
    # `derived_module_declared` entry, which is deliberate but load-bearing: any
    # consumer that assumes the dict has the name would throw a KeyError.
    using JuliaWorkspaces: derived_module_declared, derived_module_visible_names_idfree,
        _in_scope_module_syms

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !haskey(derived_module_declared(jw.runtime, root, ["T"]), "set_foo!")
    @test haskey(derived_module_visible_names(jw.runtime, root, ["T"]), "set_foo!")
    # Exercise the two origin-filtering consumers; neither may throw, and a
    # macro-declared entry must not be mistaken for a loaded module.
    @test derived_module_visible_names_idfree(jw.runtime, root, ["T"]) isa Dict
    @test :set_foo! ∉ _in_scope_module_syms(jw.runtime, root, ["T"])
end

@testitem "macro-declared: the id-free projection backdates across an id shift" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: derived_module_visible_names_idfree

    # Two `@deprecate` in one module share an id key, so inserting one shifts the
    # other's id — but the ID-FREE projection must be unchanged, which is the
    # whole point of that seam.
    idfree(src) = begin
        jw, root = macro_ws(src)
        derived_module_visible_names_idfree(jw.runtime, root, ["T"])
    end

    a = idfree("""
    module T
    @deprecate oldb newb
    end
    """)
    b = idfree("""
    module T
    @deprecate olda newa
    @deprecate oldb newb
    end
    """)

    @test haskey(a, "oldb") && haskey(b, "oldb")
    @test isequal(a["oldb"], b["oldb"])
end
```

- [ ] **Step 2: Run the tests**

Expected: PASS. If the id-free item fails, the projection is carrying something id-bearing — that is a real defect in Task 5's union, not a test problem.

- [ ] **Step 3: Run the full suite**

```julia
run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; verbose=true)
```

Expected: PASS, except two known-benign failures — a Runic dev-env formatting error and a trailing "FooSetup is not defined" complaint. Anything else is yours.

- [ ] **Step 4: Commit**

```bash
git add test/test_macro_declared_names.jl
git commit -m "test: pin the cycle, id-stability and backdating invariants

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Acceptance gates

The three gates the spec commits to. These are verification, not code; record the results in the final commit message or a comment on the branch.

**Files:** none.

- [ ] **Step 1: Real-repo language server check**

Open the julia-vscode repository in VS Code with this branch's JuliaWorkspaces active. Confirm:

- `scripts/packages/JuliaWorkspaces/src/inputs.jl` has no diagnostics.
- A file using the inputs cross-file — e.g. `src/layer_files.jl`, which calls `input_text_file` and `set_input_text_file!` — has no missing-reference diagnostics for those names.
- Hover on `set_input_files!` shows the name and `@declare_input`, with no signature.
- Go-to-definition on `set_input_files!` lands in `src/inputs.jl`.
- No new diagnostics anywhere else in the workspace.

All twelve uses in `inputs.jl` are *qualified* (`Salsa.@declare_input`), so this gate exercises only that path — the bare path is covered by the Task 3 fixtures.

- [ ] **Step 2: Visibility differential**

Already covered by Task 5's no-op test. Confirm that test is present and passing.

- [ ] **Step 3: Perf**

Run lsbench against the 2026-07-24 baseline and confirm no measurable change in module-tree or visibility recompute time. Expected: none — the new work is one extra splice walk over rows that almost no module has, plus one lookup per distinct macro spelling.

- [ ] **Step 4: Final commit**

```bash
git commit --allow-empty -m "chore: record acceptance gate results for macro-declared names

<paste the three gate outcomes here>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```
