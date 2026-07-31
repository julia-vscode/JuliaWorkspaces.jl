# Type-Aware Cross-File Method Matching — Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the cross-file method-call lint check argument *types*, not just argument counts, for calls whose callee is a workspace function defined in sibling files.

**Architecture:** Record a *syntactic* per-parameter type on `InventoryItem` (plain data, so it backdates), aggregate it into a per-root index with a per-`(path, name)` projection — exactly the shape `derived_method_arities_index`/`derived_method_arities` already use. Resolve those recorded names on demand in `layer_file_analysis.jl`, where the Salsa queries live, and pass the *already-resolved* store values into `check_call` through a new closure alongside `tree_arities`. `check_call` then reuses the existing `_has_type_intersection` comparison unchanged.

**Tech Stack:** Julia, Salsa.jl (incremental query engine), CSTParser (syntax), SymbolServer (`DataTypeStore`/`FakeUnion` type values), TestItemRunner.

## Global Constraints

- **Inventory values are plain data only.** No `EXPR`, no `objectid`, no byte offset, no store value in anything reachable from `derived_file_inventory` (`layer_inventory.jl:1-7`). Store values compare by identity and would never backdate.
- **Never recover types from syntax at the consumer.** Resolution reads recorded data, not `derived_item_positions`.
- **Permissive is the default at every step.** A truncated or unknown type must yield "no opinion", never a flag. A false *positive* is the one outcome a linter must not produce.
- **Resolution reads the defining module's WHOLE name map.** Use `derived_module_visible_names_idfree(rt, root, defmod)`. Per-name resolution must **not** become its own Salsa query — measured, that turns 0 new dependency edges into 66 for the worst file (`docs/perf/2026-07-31-type-resolution-budget.md`).
- **Assert lint behaviour through the per-file pass** — `derived_file_analysis(rt, root, file)` — never `derived_static_lint_meta_for_root`, which is the old per-root path and does not see anything wired into visibility.
- Comments: terse; do not reference design docs, section numbers, or this plan.
- Run tests via TestItemRunner in the dev-env Julia session (`scripts/environments/development`), never by spawning `julia` or `Pkg.test`.

## The slice-1 comparison restriction (read before Task 4)

**Only compare when the parameter's recorded type resolves to a store `DataTypeStore` (Base/Core).** That is 53.8% of all recorded names, and `_issubtype`'s `_super` chain is complete for them.

A parameter whose type is a **workspace-declared** type (45.3%) resolves to `CoreTypes.Any` in this slice, i.e. no opinion. Proving a mismatch against a workspace type requires climbing *workspace* ancestry, which `_super` cannot do — and a truncated supertype chain produces a false positive. That is deferred, deliberately.

This restriction is what makes slice 1 shippable on its own: it catches `f(x::Int)` called with a `String` across files, and stays silent everywhere it cannot prove a mismatch.

## File Structure

| File | Responsibility |
|---|---|
| `src/layer_inventory.jl` | Add `param_types` to `InventoryItem`; extract it at the two real-method construction sites. |
| `src/layer_module_tree.jl` | `derived_method_param_types_index` (per-root) + `derived_method_param_types` (per-`(path, name)` projection), carrying the *defining* module per record. |
| `src/layer_file_analysis.jl` | The `tree_param_types` closure: resolve recorded names → store values, pass to `check_all`. |
| `src/StaticLint/linting/checks.jl` | Thread `tree_param_types` through `check_all`/`check_call`; the type check after the arity match. |
| `test/test_inventory.jl` | Recording tests (Task 1). |
| `test/test_module_tree.jl` | Index/projection + backdating tests (Task 2). |
| `test/test_file_analysis.jl` | Resolution (Task 3) and end-to-end lint behaviour (Task 4). |

---

### Task 1: Record syntactic parameter types in the inventory

**Files:**
- Modify: `src/layer_inventory.jl` (struct at `:51-72`; construction sites at `:747` and `:842`)
- Test: `test/test_inventory.jl`

**Interfaces:**
- Consumes: nothing.
- Produces: `InventoryItem.param_types::Union{Nothing,Vector{Vector{String}}}`. `nothing` = no usable record (not a real method, or a signature whose positional alignment is unknowable). Otherwise one entry per positional parameter in source order; an inner `String[]` means *that* parameter's type is unknown. A non-empty inner vector is a dotted name path as written: `["Int"]`, `["CSTParser","EXPR"]`.
- Also produces: `_param_type_names(x::CSTParser.EXPR)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_inventory.jl`:

```julia
@testitem "inventory: records bare and qualified parameter types" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///pt/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    f(x::Int, y::CSTParser.EXPR) = 1
    g(a, b::String) = 2
    h(v::Vector{Int}) = 3
    k(x::T) where T<:Real = 4
    kk(x::T, y::Real) where T<:Real = 4
    m(x::Int, ys...) = 5
    n(p::NamedTuple{(:w,),Tuple{String}}) = 6
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)

    # bare + qualified, positionally aligned
    @test items["f"].param_types == [["Int"], ["CSTParser", "EXPR"]]
    # unannotated parameter records as unknown, not as absent
    @test items["g"].param_types == [String[], ["String"]]
    # parametric: unknown in this slice (the head is NOT recorded alone)
    @test items["h"].param_types == [String[]]
    # a where-bound type variable is method-local, never a resolvable name
    @test items["k"].param_types == [String[]]
    # ...but the BOUND's name is not a type variable: a sibling parameter
    # annotated with it must still be recorded (Task 1 review, Finding 1)
    @test items["kk"].param_types == [String[], ["Real"]]
    # a positional splat makes alignment unknowable -> no record at all
    @test items["m"].param_types === nothing
    # value positions must not be harvested as type names
    @test items["n"].param_types == [String[]]
end

@testitem "inventory: param_types is nothing for non-methods and backdates on body edits" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText, update_file!
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///pt2/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("module P\nconst C = 1\nf(x::Int) = 1\nend\n", "julia")))
    inv1 = derived_file_inventory(jw.runtime, u)
    @test Dict(it.name => it for it in inv1.items)["C"].param_types === nothing

    # a body-only edit must leave the inventory `isequal` so Salsa backdates
    update_file!(jw, TextFile(u, SourceText("module P\nconst C = 1\nf(x::Int) = 99\nend\n", "julia")))
    inv2 = derived_file_inventory(jw.runtime, u)
    @test isequal(inv1, inv2)
end
```

- [ ] **Step 2: Run the tests to verify they fail**

In the dev-env session:
```julia
run_tests("test/test_inventory.jl"; filter=ti -> occursin("param", ti.name) || occursin("parameter type", ti.name))
```
Expected: FAIL — `type InventoryItem has no field param_types`.

- [ ] **Step 3: Add the field and the extraction**

In `src/layer_inventory.jl`, add to the struct after `declared_by` (`:64`):

```julia
    # One entry per positional parameter, in source order, for a real method;
    # `nothing` when alignment is unknowable (a positional splat) or the item is
    # not a method. An empty inner vector means that parameter's type is unknown.
    # Names are as written (`["CSTParser","EXPR"]`) and resolved by the consumer
    # against the module the method's TEXT sits in.
    param_types::Union{Nothing,Vector{Vector{String}}}
```

Extend the back-compat constructors (`:69-72`) — every existing 8/9/10-argument call site must keep working:

```julia
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, nothing, nothing, nothing)
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, nothing, nothing)
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, declared_by) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, declared_by, nothing)
```

Add the extractor near the arity helpers:

```julia
# The `where`-bound type variable names of a signature. Method-local: they name
# nothing in the defining module, so a parameter annotated with one is unknown.
#
# CORRECTED after Task 1's review. Collect ONLY the variable, never the bound:
# an earlier version swept in the bound's name too, so `where T<:Real` put both
# `T` and `Real` into the set and a sibling `y::Real` was silently discarded as
# if it were a type variable. Shapes to handle: `where T`, `where T<:B` /
# `where T>:B` (variable is the left operand), `where Lo<:T<:Hi` (variable is
# the middle operand), and `where {T, S<:X}`. Anything unclassifiable
# contributes nothing — over-collecting loses real records, while
# under-collecting only yields a name that fails to resolve, which the consumer
# already treats permissively. Determine the exact CST layouts empirically
# rather than assuming them.

# A dotted access chain as a name path (`Base.Iterators.Zip` →
# ["Base","Iterators","Zip"]), or `nothing` for any other shape.
function _dotted_name_path(x::CSTParser.EXPR)
    if CSTParser.isidentifier(x)
        return [CSTParser.str_value(x)]
    elseif CSTParser.is_getfield_w_quotenode(x)
        lhs = _dotted_name_path(x.args[1])
        lhs === nothing && return nothing
        q = x.args[2]
        (q isa CSTParser.EXPR && q.args !== nothing && length(q.args) >= 1 &&
            CSTParser.isidentifier(q.args[1])) || return nothing
        return vcat(lhs, CSTParser.str_value(q.args[1]))
    end
    return nothing
end

# One recorded type per positional parameter of a method-defining EXPR, or
# `nothing` when the positional alignment is unknowable. Only bare and qualified
# names are recorded; every other shape (parametric, `where`-bound, a literal)
# records as unknown, which the consumer treats permissively.
function _param_type_names(x::CSTParser.EXPR)
    sig = CSTParser.get_sig(x)
    sig isa CSTParser.EXPR || return nothing
    tvars = _where_var_names(sig)
    sig = CSTParser.rem_wheres_decls(sig)
    (sig isa CSTParser.EXPR && sig.args !== nothing) || return nothing

    out = Vector{Vector{String}}()
    for i in 2:length(sig.args)
        arg = sig.args[i]
        arg isa CSTParser.EXPR || return nothing
        # keywords live in `:parameters` and are not positional
        CSTParser.headof(arg) === :parameters && continue
        # a positional splat/Vararg makes the alignment unknowable
        CSTParser.issplat(arg) && return nothing
        decl = CSTParser.iskwarg(arg) && arg.args !== nothing && length(arg.args) >= 1 &&
                   arg.args[1] isa CSTParser.EXPR ? arg.args[1] : arg
        CSTParser.issplat(decl) && return nothing
        if CSTParser.isdeclaration(decl) && length(decl.args) >= 2
            t = decl.args[2]
            if isidentifier_vararg(t)
                return nothing
            end
            p = _dotted_name_path(t)
            push!(out, p === nothing || (length(p) == 1 && p[1] in tvars) ? String[] : p)
        else
            push!(out, String[])
        end
    end
    return out
end

# `x::Vararg` / `x::Vararg{T,N}` in positional position — same alignment problem
# as a splat.
function isidentifier_vararg(t)
    t isa CSTParser.EXPR || return false
    CSTParser.isidentifier(t) && CSTParser.valof(t) == "Vararg" && return true
    return CSTParser.iscurly(t) && t.args !== nothing && length(t.args) >= 1 &&
        CSTParser.isidentifier(t.args[1]) && CSTParser.valof(t.args[1]) == "Vararg"
end
```

Then at **both** real-method construction sites, pass the record. At `:747` (in `_classify_assignment!`):

```julia
            is_method = StaticLint._is_real_method(x)
            push!(acc.items, InventoryItem(order, id, name, qualifier, something(kind_override, :function),
                _render_sig(x), String[], parent_module,
                (is_method ? MethodArity(StaticLint.func_nargs(x)...) : nothing), nothing,
                (is_method ? _param_type_names(x) : nothing)))
```

At `:842` (the `function`/`macro` keyword form), make the identical change.

Leave the struct site (`:879`) recording `nothing`: an implicit constructor's parameter types come from field annotations, which is not this slice.

- [ ] **Step 4: Run the tests to verify they pass**

```julia
run_tests("test/test_inventory.jl"; filter=ti -> occursin("param", ti.name) || occursin("parameter type", ti.name))
```
Expected: PASS. Then run the whole file to catch construction-site regressions:
```julia
run_tests("test/test_inventory.jl")
```
Expected: PASS (restart the session first — the struct changed).

- [ ] **Step 5: Commit**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "feat(inventory): record syntactic parameter types on InventoryItem"
```

---

### Task 2: Per-root index and per-name projection

**Files:**
- Modify: `src/layer_module_tree.jl` (add after `derived_method_arities_index`, which ends at `:879`)
- Test: `test/test_module_tree.jl`

**Interfaces:**
- Consumes: `InventoryItem.param_types` (Task 1).
- Produces:
  - `MethodParamTypes` — `@auto_hash_equals struct` with `defmod::Vector{String}`, `arity::MethodArity`, `param_types::Vector{Vector{String}}`.
  - `derived_method_param_types_index(rt, root) -> Dict{Tuple{Vector{String},String},Vector{MethodParamTypes}}`
  - `derived_method_param_types(rt, root, path, name) -> Vector{MethodParamTypes}`

`defmod` is the module the method's **text** sits in (the walk's `loc`), which differs from the key path for a qualified extension: in `Base.foo(x::MyType)` written in module `M`, `MyType` resolves against `M`, not `Base`. Getting this wrong resolves every qualified extension's types in the wrong module.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_module_tree.jl`:

```julia
@testitem "derived_method_param_types: aggregates across files with the defining module" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_method_param_types, TextFile, SourceText, MethodArity
    using JuliaWorkspaces.URIs2: URI

    root = URI("file:///mp/src/M.jl")
    a = URI("file:///mp/src/a.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root, SourceText("module M\ninclude(\"a.jl\")\nf(x::Int) = 1\nend\n", "julia")))
    add_file!(jw, TextFile(a, SourceText("f(x::String, y::Bool) = 2\nBase.sin(x::Int, y::Int) = 3\n", "julia")))

    recs = derived_method_param_types(jw.runtime, root, ["M"], "f")
    @test length(recs) == 2
    @test Set(r.param_types for r in recs) == Set([[["Int"]], [["String"], ["Bool"]]])
    @test all(r -> r.defmod == ["M"], recs)
    @test Set(r.arity.minargs for r in recs) == Set([1, 2])

    # a `Base.` extension keys under Base but its types resolve in M
    braw = derived_method_param_types(jw.runtime, root, ["Base"], "sin")
    @test isempty(braw)   # Base is not a module of this tree
end

@testitem "derived_method_param_types: qualified extension records the defining module" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_method_param_types, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    root = URI("file:///mp2/src/M.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root, SourceText("""
    module M
    struct T end
    module Inner
    M.g(x::Int) = 1
    end
    g(x::T) = 2
    end
    """, "julia")))

    recs = derived_method_param_types(jw.runtime, root, ["M"], "g")
    @test length(recs) == 2
    inner = only(filter(r -> r.param_types == [["Int"]], recs))
    @test inner.defmod == ["M", "Inner"]      # where the TEXT is, not where the name lands
    outer = only(filter(r -> r.param_types == [["T"]], recs))
    @test outer.defmod == ["M"]
end

@testitem "derived_method_param_types_index: body-only edit backdates" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_method_param_types_index, TextFile, SourceText, update_file!
    using JuliaWorkspaces.URIs2: URI

    root = URI("file:///mp3/src/M.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root, SourceText("module M\nf(x::Int) = 1\nend\n", "julia")))
    i1 = derived_method_param_types_index(jw.runtime, root)
    update_file!(jw, TextFile(root, SourceText("module M\nf(x::Int) = 12345\nend\n", "julia")))
    i2 = derived_method_param_types_index(jw.runtime, root)
    @test isequal(i1, i2)

    # a signature change must NOT backdate
    update_file!(jw, TextFile(root, SourceText("module M\nf(x::String) = 1\nend\n", "julia")))
    @test !isequal(i1, derived_method_param_types_index(jw.runtime, root))
end
```

- [ ] **Step 2: Run to verify failure**

```julia
run_tests("test/test_module_tree.jl"; filter=ti -> occursin("param_types", ti.name))
```
Expected: FAIL — `derived_method_param_types not defined`.

- [ ] **Step 3: Implement the index and projection**

In `src/layer_module_tree.jl`, after `derived_method_arities_index` ends (`:879`):

```julia
"""
    MethodParamTypes

One method's recorded parameter types, with the module its text sits in.
`defmod` is where the recorded names resolve — for `Base.foo(x::MyType)` written
in `M` that is `M`, not `Base`. Plain data, so it backdates.
"""
@auto_hash_equals struct MethodParamTypes
    defmod::Vector{String}
    arity::MethodArity
    param_types::Vector{Vector{String}}
end

"""
    derived_method_param_types(rt, root, path::Vector{String}, name::String) -> Vector{MethodParamTypes}

The recorded parameter types of every method of `name` at module `path` — the
same selection as [`derived_method_arities`](@ref), minus methods with no usable
record. A `get` into the per-root index, so it backdates for an untouched name
when the index changes elsewhere.
"""
Salsa.@derived function derived_method_param_types(rt, root, path, name)
    @debug "derived_method_param_types" root=root path=path name=name

    return get(derived_method_param_types_index(rt, root), (path, name), _NO_PARAM_TYPES)
end

const _NO_PARAM_TYPES = MethodParamTypes[]

"""
    derived_method_param_types_index(rt, root) -> Dict{Tuple{Vector{String},String},Vector{MethodParamTypes}}

Every `(module path, name) => records` entry of `root`'s tree in one node, by a
single splice walk — the same fan-in rationale as
[`derived_method_arities_index`](@ref): per-name nodes would each depend on every
file in the root.
"""
Salsa.@derived function derived_method_param_types_index(rt, root)
    @debug "derived_method_param_types_index" root=root

    tree = derived_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    result = Dict{Tuple{Vector{String},String},Vector{MethodParamTypes}}()

    _walk_spliced_binding_items!(rt, root, String[], nothing, Set{URI}([root])) do F, item, loc
        (item.arity === nothing || item.param_types === nothing) && return
        resolved = isempty(item.qualifier) ? loc :
            _resolve_extension_qualifier(modpaths, loc, item.qualifier)
        (resolved === nothing || resolved ∉ modpaths) && return
        push!(get!(() -> MethodParamTypes[], result, (resolved, item.name)),
              MethodParamTypes(loc, item.arity, item.param_types))
    end
    return result
end
```

Export `MethodParamTypes` wherever `MethodArity` is exported/imported into StaticLint if the wire step needs it — check with `grep -n "MethodArity" src/JuliaWorkspaces.jl src/StaticLint/StaticLint.jl` and mirror exactly.

- [ ] **Step 4: Run to verify pass**

```julia
run_tests("test/test_module_tree.jl"; filter=ti -> occursin("param_types", ti.name))
run_tests("test/test_module_tree.jl")
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_module_tree.jl test/test_module_tree.jl
git commit -m "feat(module-tree): per-root parameter-type index and per-name projection"
```

---

### Task 3: Resolve recorded types to store values

**Files:**
- Modify: `src/layer_file_analysis.jl` (the closure block at `:751-774`)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Consumes: `derived_method_param_types` (Task 2).
- Produces: `_resolve_param_types(rt, root, env, recs) -> Vector{@NamedTuple{arity::MethodArity, types::Vector{Any}}}`, where each `types[i]` is a value `StaticLint._has_type_intersection` accepts: a `SymbolServer.DataTypeStore`, or `StaticLint.CoreTypes.Any` for "unknown / no opinion".

Resolution order per recorded name, first hit wins:
1. Empty record (`String[]`) → `CoreTypes.Any`.
2. Present in `derived_module_visible_names_idfree(rt, root, defmod)` → a workspace-declared type → **`CoreTypes.Any` in this slice** (see the restriction section).
3. Otherwise the env store, via the head of the name path → `maybe_lookup` (follow a `VarRef`) → `get_eventual_datatype` (follow a constructor `FunctionStore.extends`). A `DataTypeStore` result is the operand; anything else → `CoreTypes.Any`.

Step 3's hops are not optional: `x::String` resolves to a constructor `FunctionStore` and `x::AbstractString` to a `VarRef`. Testing for `DataTypeStore` directly concludes that `String` is not a type.

- [ ] **Step 1: Write the failing test**

Add to `test/test_file_analysis.jl`:

```julia
@testitem "file analysis: recorded parameter types resolve to store datatypes" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: derived_method_param_types, derived_stdlib_only_env

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\nend\n",
        A => "struct Own end\nf(x::Int, y::AbstractString, z::Own, w) = 1\n",
    ))
    rt = jw.runtime
    env = derived_stdlib_only_env(rt)
    recs = derived_method_param_types(rt, ROOT, ["MainPkg"], "f")
    @test length(recs) == 1

    res = JuliaWorkspaces._resolve_param_types(rt, ROOT, env, recs)
    types = only(res).types
    @test length(types) == 4
    # NOTE: `CoreTypes.Any` is ITSELF a DataTypeStore, so `isa DataTypeStore` would
    # pass even on a total resolution failure. Assert the identity, not the type.
    # `Int` is a constructor FunctionStore in the store — reaching Core.Int64 proves
    # the `FunctionStore.extends` hop ran.
    @test string(types[1].name) == "Core.Int64"
    # `AbstractString` is a VarRef in the store — this proves `maybe_lookup` ran.
    @test string(types[2].name) == "Core.AbstractString"
    @test !SL._isany(types[1]) && !SL._isany(types[2])
    # a workspace-declared type is deliberately no-opinion in this slice
    @test SL._isany(types[3])
    # an unannotated parameter is no-opinion
    @test SL._isany(types[4])
end
```

- [ ] **Step 2: Run to verify failure**

```julia
run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("recorded parameter types", ti.name))
```
Expected: FAIL — `_resolve_param_types not defined`.

- [ ] **Step 3: Implement resolution and wire the closure**

Add to `src/layer_file_analysis.jl`, above `derived_file_analysis`:

```julia
# A recorded type name resolved to a value the type comparison accepts.
# `CoreTypes.Any` means "no opinion" and can only ever remove a diagnostic.
function _resolve_recorded_type(rt, root, env, defmod::Vector{String}, path::Vector{String})
    isempty(path) && return StaticLint.CoreTypes.Any
    head = path[1]
    # A workspace-declared type: known, but comparing against it needs workspace
    # ancestry, which the store's supertype walk cannot climb. No opinion.
    haskey(derived_module_visible_names_idfree(rt, root, defmod), head) &&
        return StaticLint.CoreTypes.Any
    syms = StaticLint.getsymbols(env)
    store = nothing
    if length(path) > 1
        store = _resolve_qualified_store(env, path[1:end-1], Symbol(path[end]))
    else
        for m in (:Base, :Core)
            st = get(syms, m, nothing)
            st isa SymbolServer.ModuleStore || continue
            v = get(st.vals, Symbol(head), nothing)
            v === nothing && continue
            store = StaticLint.maybe_lookup(v, env)
            break
        end
    end
    store === nothing && return StaticLint.CoreTypes.Any
    dt = StaticLint.get_eventual_datatype(store, env)
    return dt isa SymbolServer.DataTypeStore ? dt : StaticLint.CoreTypes.Any
end

# Resolve a name's cross-file method records into comparison operands.
function _resolve_param_types(rt, root, env, recs)
    out = @NamedTuple{arity::MethodArity, types::Vector{Any}}[]
    for r in recs
        types = Any[_resolve_recorded_type(rt, root, env, r.defmod, p) for p in r.param_types]
        push!(out, (arity=r.arity, types=types))
    end
    return out
end
```

`_resolve_qualified_store` already exists in this file (`:~600`) — reuse it, do not write a second one.

Then add the closure beside `tree_arities` (`:766-770`) and pass it to `check_all`:

```julia
    # Resolved cross-file parameter types, for the positional TYPE check. Plain
    # data in, store values out; unknown resolves to `Any`, which can only
    # remove a diagnostic.
    tree_param_types = (name, x) -> begin
        p = vcat(path, _in_file_module_names(x, meta_dict))
        _resolve_param_types(rt, root, env, derived_method_param_types(rt, root, p, name))
    end
    StaticLint.check_all(cst, _lint_options_from_config(lint_config), env, meta_dict, tree_visible, tree_extended, tree_arities, tree_in_scope, tree_param_types)
```

- [ ] **Step 4: Run to verify pass**

```julia
run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("recorded parameter types", ti.name))
```
Expected: PASS. (`check_all` gains a trailing optional parameter in Task 4; until then add it with a default of `nothing` in the same commit as this step so the call type-checks.)

- [ ] **Step 5: Commit**

```bash
git add src/layer_file_analysis.jl src/StaticLint/linting/checks.jl test/test_file_analysis.jl
git commit -m "feat(file-analysis): resolve recorded parameter types to store datatypes"
```

---

### Task 4: Wire the type check into `check_call`

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`check_all` at `:124`, its recursion at `:147`, `check_call` at `:389`, the arity-match branch at `:433-447`)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Consumes: the `tree_param_types` closure (Task 3).
- Produces: no new public names; `check_all`/`check_call` gain a trailing `tree_param_types=nothing` parameter.

Where it goes: inside the existing tree-visible branch, the arity check at `:435` decides `any(a -> compare_f_call(a, cc), arities)`. The type check runs **only when an arity matched** and only tightens that outcome. Every gate below must be satisfied or the check declines:

- `tree_param_types !== nothing` and returns a non-empty vector;
- the call has no splat (already true in this branch) and no keyword arguments;
- at least one record's arity matches the call count *and* has the same number of recorded positional types as the call has arguments;
- among those records, none matches on types.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_file_analysis.jl`:

```julia
@testitem "derived_file_analysis: cross-file positional TYPE check" setup=[FileAnalysisWS] begin
    mm(fa) = [d.message for d in fa.diagnostics
              if occursin("No method matching", d.message) || occursin("method call error", d.message)]
    ws(a, b) = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n", A => a, B => b))
    diags(a, b) = mm(JuliaWorkspaces.derived_file_analysis(ws(a, b).runtime, ROOT, B))

    # wrong store type, right arity -> flagged
    @test length(diags("f(x::Int) = x\n", "g() = f(\"s\")\n")) == 1
    # right type -> silent
    @test isempty(diags("f(x::Int) = x\n", "g() = f(1)\n"))
    # subtyping must be honoured: Int <: Integer is a match, not a mismatch
    @test isempty(diags("f(x::Integer) = x\n", "g() = f(1)\n"))
    # a sibling overload accepting the type -> silent
    @test isempty(diags("f(x::Int) = x\nf(x::String) = x\n", "g() = f(\"s\")\n"))
    # unannotated parameter -> no opinion
    @test isempty(diags("f(x) = x\n", "g() = f(\"s\")\n"))
    # a WORKSPACE-declared parameter type is no-opinion in this slice
    @test isempty(diags("struct Own end\nf(x::Own) = x\n", "g() = f(\"s\")\n"))
    # parametric annotation -> unknown -> no opinion
    @test isempty(diags("f(x::Vector{Int}) = x\n", "g() = f(\"s\")\n"))
    # keyword arguments -> decline
    @test isempty(diags("f(x::Int; k=1) = x\n", "g() = f(\"s\"; k=2)\n"))
    # arity mismatch keeps its existing message, and is not doubled up
    @test length(diags("f(x::Int) = x\n", "g() = f(1, 2)\n")) == 1
end

@testitem "derived_file_analysis: type check declines when the argument type is unknown" setup=[FileAnalysisWS] begin
    mm(fa) = [d.message for d in fa.diagnostics
              if occursin("No method matching", d.message) || occursin("method call error", d.message)]
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "f(x::Int) = x\n",
        B => "g(u) = f(u)\n",   # `u`'s type is unknown -> must not flag
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)))
end
```

- [ ] **Step 2: Run to verify failure**

```julia
run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("TYPE check", ti.name) || occursin("argument type is unknown", ti.name))
```
Expected: FAIL — the first assertion finds 0 diagnostics where 1 is expected.

- [ ] **Step 3: Thread the parameter and add the check**

Change the two signatures and the recursion in `src/StaticLint/linting/checks.jl`:

```julia
function check_all(x::EXPR, opts::LintOptions, env::ExternalEnv, meta_dict, tree_visible=nothing, tree_extended=nothing, tree_arities=nothing, tree_in_scope=nothing, tree_param_types=nothing)
```
```julia
    opts.call && check_call(x, env, meta_dict, tree_visible, tree_extended, tree_arities, tree_in_scope, tree_param_types)
```
```julia
            check_all(x.args[i], opts, env, meta_dict, tree_visible, tree_extended, tree_arities, tree_in_scope, tree_param_types)
```
```julia
function check_call(x, env::ExternalEnv, meta_dict, tree_visible=nothing, tree_extended=nothing, tree_arities=nothing, tree_in_scope=nothing, tree_param_types=nothing)
```

Replace the arity-matched no-op at `:435-436`:

```julia
                            if any(a -> compare_f_call(a, cc), arities)
                                # An arity match alone is not a match if the
                                # cross-file parameter types rule every
                                # candidate out.
                                if !_tree_types_match(x, n, cc, env, meta_dict, tree_param_types)
                                    seterror!(x, IncorrectCallArgs, meta_dict)
                                end
```

And add the helper near `sig_match_any`:

```julia
# Does any cross-file method of `n` match the call on positional TYPES as well as
# count? True (no opinion) whenever anything needed is unavailable — a resolved
# type is only ever allowed to REMOVE a diagnostic.
function _tree_types_match(x, n, cc, env::ExternalEnv, meta_dict, tree_param_types)
    tree_param_types === nothing && return true
    recs = tree_param_types(n, x)
    isempty(recs) && return true
    args, kws = call_arg_types(x, false, meta_dict, getsymbols(env))
    isempty(kws) || return true          # keywords: not modelled in this slice
    checked = false
    for r in recs
        compare_f_call(r.arity, cc) || continue
        length(r.types) == length(args) || return true   # defaults/alignment: decline
        checked = true
        all(i -> _has_type_intersection(args[i], r.types[i], getsymbols(env), meta_dict),
            1:length(args)) && return true
    end
    return !checked
end
```

- [ ] **Step 4: Run to verify pass**

```julia
run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("TYPE check", ti.name) || occursin("argument type is unknown", ti.name))
run_tests("test/test_file_analysis.jl")
run_tests("test/staticlint/test_staticlint.jl")
```
Expected: PASS on all three. The last one is the regression gate: `check_call` is shared with the whole-closure path, where `tree_param_types` is `nothing` and behaviour must be byte-identical.

- [ ] **Step 5: Verify no new diagnostics on this repo**

The strongest false-positive check available. In the dev-env session, build a workspace over this package and diff the diagnostic count against `main`:

```julia
include("docs/perf/typebudget.jl")
jw, _ = TypeBudget.load_folder("<abs path to JuliaWorkspaces>"; project="<...>/Project.toml")
root = JuliaWorkspaces.derived_workspace_package_roots(jw.runtime)["JuliaWorkspaces"]
total = 0
for f in JuliaWorkspaces.derived_tree_files(jw.runtime, root)
    global total += length(JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f).diagnostics)
end
@show total
```
Expected: equal to the same figure on `main`. Any increase is a false positive — investigate before committing, do not rationalise it.

- [ ] **Step 6: Commit**

```bash
git add src/StaticLint/linting/checks.jl test/test_file_analysis.jl
git commit -m "feat(lint): check cross-file positional argument types past the arity gate"
```

---

## Self-Review

**Spec coverage.** Record → Task 1. Per-root index + projection with the defining module → Task 2. On-demand resolution through the whole module map, plus the store leg with its `VarRef`/`FunctionStore` hops → Task 3. Wire past the arity gate → Task 4. The three §17 rules: *unknown is permissive* (Task 3 step 3 returns `CoreTypes.Any`, Task 4's helper returns `true` on every unavailable input); *no early ancestry elaboration* (nothing resolves at record time); *degrade rather than truncate* (a workspace-declared parameter type is no-opinion instead of a partial supertype walk).

**Deliberately out of scope**, each recording as unknown and therefore permissive: parametrics (11.1% of annotated parameters — slice 2), keyword-argument types, positional splats/`Vararg`, struct implicit constructors, and comparison against workspace-declared types (needs workspace ancestry, §18-adjacent).

**Known risks.**
- `check_call` is shared with the whole-closure path; Task 4 step 4 runs `test_staticlint.jl` as the regression gate.
- Adding a field to `InventoryItem` touches every construction site; Task 1 keeps three back-compat constructors and runs the full inventory file.
- ~~`isidentifier_vararg` is a new name~~ — **resolved in Task 1**: `StaticLint.is_explicit_vararg_decl` already exists and is logically identical, so no new helper was added. It takes the *declaration*, not the type expression. (`StaticLint.bounded_vararg_N` is related but answers a different question — the bound, not the shape.)
- **`CoreTypes.Any` is itself a `SymbolServer.DataTypeStore`.** Any assertion of the form `resolved isa DataTypeStore` passes on total resolution failure and is therefore worthless. Assert `!_isany(...)` plus the resolved name (`"Core.Int64"`, `"Core.AbstractString"` — note `Int` resolves to `Core.Int64`, not `"Int"`).

**Verified against the code while writing this plan** (do not re-derive): every CSTParser and StaticLint name used above exists; `CSTParser.get_sig` retains the `where` wrapper, so `_where_var_names` must run on `get_sig(x)` *before* `rem_wheres_decls`; `_isany(CoreTypes.Any)` is `true`, making it the correct permissive operand; `_resolve_qualified_store(env, qualifier::Vector{String}, name_sym::Symbol)` already exists in `layer_file_analysis.jl`.
- Restart the Julia session after Task 1 and Task 2 — both change struct definitions, which Revise cannot patch.
