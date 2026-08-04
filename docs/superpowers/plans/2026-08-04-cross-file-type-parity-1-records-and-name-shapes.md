# Cross-File Type Parity, Plan 1: Records, Engine, and Name Shapes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plain-data method-signature records, one shared matching engine, and cross-file type checking for the bare-identifier and qualified-name shapes — the infrastructure slice of `docs/design/2026-08-04-cross-file-type-parity-spec.md`.

**Architecture:** Per-file inventories gain syntactic `MethodSignature` records and datatype supertypes (never resolved at inventory time); a per-root Salsa index aggregates them into per-name `Set`s; resolution happens at check time through the defining module's visible names; `check_call`'s tree gate gains a type phase after its arity phase, running the same alignment engine the EXPR and `MethodStore` paths are refactored onto.

**Tech Stack:** Julia, CSTParser (vendored), Salsa (vendored fork), SymbolServer stores, TestItemRunner via the julia-mcp dev-env session.

## Global Constraints

- **Never spawn `julia` or `Pkg.test` from the shell.** Run code and tests only through the julia-mcp dev-env session: `run_tests("test/<file>.jl"; filter=ti -> occursin("<substring>", ti.name))`. Restart the session (`julia_restart`) after ANY struct definition changes, or you get method errors on stale types. Long timeouts kill sessions — keep filters narrow.
- **`@testitem` bodies run at module scope**: they need explicit `using JuliaWorkspaces: ...` imports (defaults don't apply), `return` does not skip a body (gate with `if/else`), and assigning an outer name inside a `for` is an ambiguous soft-scope assignment.
- **Inventory values are a firewall** (layer_inventory.jl:1-7): plain data only — no EXPR, no positions, no store values, no URIs inside records. All new record structs use `@auto_hash_equals` (field-wise `==`/`hash`, correct for `Vector`/`Set`/`Dict` fields).
- **Unknown never flags.** Only a definite `false` from `_has_type_intersection` rules a method out; `nothing` and `CoreTypes.Any` both leave the candidate alive. Never convert an unknown into a `false`.
- **Per-name Salsa reads go through projection nodes over one per-root node** — never compute per-name nodes that read every file.
- **Code comments**: terse, present-tense, state constraints the code can't show. Never reference the spec, the plan, findings, or tasks.
- **Commit messages** describe the change; no test counts, no branch bookkeeping.
- Edit files directly with Edit/Write; no bulk-rewrite scripts.

## File Structure

- Create: `src/layer_signature_records.jl` — record types (`TypeExpr` family, `MethodSignature`, `NameMethods`), no logic.
- Create: `src/StaticLint/signature_reader.jl` — syntactic lowering: EXPR → `TypeExpr` / `MethodSignature`.
- Create: `src/StaticLint/treetypes.jl` — `TreeDataType` and its `_super`/`_type_compare` methods.
- Modify: `src/packagedef.jl` (include lines), `src/StaticLint/StaticLint.jl` (imports + includes), `src/layer_inventory.jl` (two new `InventoryItem` fields), `src/layer_module_tree.jl` (index + projection), `src/StaticLint/methodmatching.jl` (engine extraction, record lowering), `src/StaticLint/subtypes.jl` (implicit-Any supertype, resolver threading), `src/StaticLint/linting/checks.jl` (type phase, resolver threading), `src/layer_file_analysis.jl` (closures).
- Test: `test/test_signature_records.jl` (new), `test/staticlint/test_staticlint.jl`, `test/test_file_analysis.jl`.

---

### Task 1: Record types

**Files:**
- Create: `src/layer_signature_records.jl`
- Modify: `src/packagedef.jl:27` (include before `layer_inventory.jl`)
- Modify: `src/StaticLint/StaticLint.jl:7` (imports)
- Test: `test/test_signature_records.jl`

**Interfaces:**
- Produces: `abstract type TypeExpr`; `TypeRef(path::Vector{String})`; `TypeUnionExpr(members::Vector{TypeExpr})`; `TypeVarRef(name::String)`; `UnknownType()`; `SigSlot(type::TypeExpr, optional::Bool)`; `VarargSpec(eltype::TypeExpr, count::Union{Nothing,Int})`; `MethodSignature(slots::Vector{SigSlot}, vararg::Union{Nothing,VarargSpec}, typevars::Dict{String,TypeExpr}, kws::Vector{Symbol}, kwsplat::Bool)`; `LocatedSignature(defined_in::Vector{String}, sig::MethodSignature)`; `NameMethods(signatures::Set{LocatedSignature}, has_unknown_shapes::Bool, has_forward_decl::Bool)`; `const TYPE_ANY = TypeRef(["Core", "Any"])`; `EMPTY_NAME_METHODS`.
- Consumes: `@auto_hash_equals` (already used in layer_inventory.jl).

- [ ] **Step 1: Write the failing test**

```julia
# test/test_signature_records.jl
@testitem "signature records: structural equality and Set semantics" begin
    using JuliaWorkspaces: TypeRef, TypeUnionExpr, TypeVarRef, UnknownType,
        SigSlot, VarargSpec, MethodSignature, LocatedSignature, NameMethods, TYPE_ANY

    # Vector-carrying records must compare by content, not identity.
    @test TypeRef(["Base", "Int"]) == TypeRef(["Base", "Int"])
    @test hash(TypeRef(["Base", "Int"])) == hash(TypeRef(["Base", "Int"]))
    @test TypeRef(["Int"]) != TypeRef(["Base", "Int"])
    @test UnknownType() == UnknownType()
    @test TypeVarRef("T") != TypeRef(["T"])
    @test TypeUnionExpr([TypeRef(["Int"]), UnknownType()]) ==
          TypeUnionExpr([TypeRef(["Int"]), UnknownType()])

    sig(t) = MethodSignature([SigSlot(t, false)], nothing,
        Dict{String,JuliaWorkspaces.TypeExpr}(), Symbol[], false)
    @test sig(TypeRef(["Own"])) == sig(TypeRef(["Own"]))
    @test sig(TypeRef(["Own"])) != sig(TypeRef(["Other"]))

    # Set collapses duplicates and equality is order-insensitive.
    a = LocatedSignature(["MainPkg"], sig(TypeRef(["Own"])))
    b = LocatedSignature(["MainPkg"], sig(TypeRef(["Other"])))
    @test Set([a, b, a]) == Set([b, a])
    @test NameMethods(Set([a, b]), false, false) == NameMethods(Set([b, a]), false, false)
    @test TYPE_ANY == TypeRef(["Core", "Any"])
end
```

- [ ] **Step 2: Run test to verify it fails**

In the julia-mcp dev-env session: `run_tests("test/test_signature_records.jl")`
Expected: FAIL — `UndefVarError` on the `using JuliaWorkspaces: TypeRef, ...` line.

- [ ] **Step 3: Write the record types**

```julia
# src/layer_signature_records.jl

# Plain-data method-signature records, per-file firewall rules of
# layer_inventory.jl: no EXPR, no positions, no store values. A record's
# type names are UNRESOLVED, relative to the module that wrote them;
# resolution happens at check time, at the leaf.

"A type annotation as written. Closed vocabulary; anything unclassifiable is
`UnknownType`, which never rules anything out."
abstract type TypeExpr end

"A (possibly qualified) type name, one segment per qualifier:
`Base.AbstractString` → `[\"Base\", \"AbstractString\"]`. A parametric
annotation lowers to its head."
@auto_hash_equals struct TypeRef <: TypeExpr
    path::Vector{String}
end

"`Union{…}`, member-wise."
@auto_hash_equals struct TypeUnionExpr <: TypeExpr
    members::Vector{TypeExpr}
end

"A reference to a `where`-bound variable of the same signature. Resolves only
through the signature's own `typevars`, never through module scope."
@auto_hash_equals struct TypeVarRef <: TypeExpr
    name::String
end

@auto_hash_equals struct UnknownType <: TypeExpr end

"`Any` is recorded explicitly where its meaning is syntactically certain
(no annotation; a datatype with no `<:` clause) — unlike `UnknownType`,
it is definite and can end a supertype walk with a verdict."
const TYPE_ANY = TypeRef(["Core", "Any"])

"One positional parameter: its annotation and whether it is defaulted.
Optionality is alignment information only."
@auto_hash_equals struct SigSlot
    type::TypeExpr
    optional::Bool
end

"The trailing vararg slot, all spellings (`x...`, `::Vararg`, `::Vararg{T}`,
`::Vararg{T,N}`, `::Base.Vararg`). `count` is `N` for the bounded form."
@auto_hash_equals struct VarargSpec
    eltype::TypeExpr
    count::Union{Nothing,Int}
end

"""
    MethodSignature

One method's signature as written: positional `slots` in order (excluding the
vararg slot), the `vararg` if any, `where`-clause upper bounds in `typevars`
(a variable with no readable upper bound maps to `UnknownType`), and keyword
presence. Arity is derivable but the count verdict stays on `MethodArity`.
"""
@auto_hash_equals struct MethodSignature
    slots::Vector{SigSlot}
    vararg::Union{Nothing,VarargSpec}
    typevars::Dict{String,TypeExpr}
    kws::Vector{Symbol}
    kwsplat::Bool
end

"A signature plus the module path that wrote it — attached at index time
(inventories only know file-relative paths). `defined_in` is where the
signature's names resolve; for qualified extensions it differs from the
index key."
@auto_hash_equals struct LocatedSignature
    defined_in::Vector{String}
    sig::MethodSignature
end

"""
    NameMethods

Everything the signature index knows about one `(module path, name)`:
the signature `Set` (order-insensitive equality, so moving a method between
files backdates), plus two completeness markers. While `has_unknown_shapes`
is true the set is an under-approximation: its emptiness proves nothing and
exhausting it licenses nothing.
"""
@auto_hash_equals struct NameMethods
    signatures::Set{LocatedSignature}
    has_unknown_shapes::Bool
    has_forward_decl::Bool
end

const EMPTY_NAME_METHODS = NameMethods(Set{LocatedSignature}(), false, false)
```

In `src/packagedef.jl`, before `include("layer_inventory.jl")`:

```julia
include("layer_signature_records.jl")
```

In `src/StaticLint/StaticLint.jl`, extend line 7:

```julia
import ..MethodArity
import ..TypeExpr, ..TypeRef, ..TypeUnionExpr, ..TypeVarRef, ..UnknownType,
    ..TYPE_ANY, ..SigSlot, ..VarargSpec, ..MethodSignature, ..LocatedSignature,
    ..NameMethods
```

- [ ] **Step 4: Restart the dev-env session, run test to verify it passes**

`julia_restart`, then `run_tests("test/test_signature_records.jl")`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_signature_records.jl src/packagedef.jl src/StaticLint/StaticLint.jl test/test_signature_records.jl
git commit -m "feat(inventory): plain-data method-signature record types"
```

---

### Task 2: `where_var_and_bound` — the single reader of `where`-clause grammar

**Files:**
- Create: `src/StaticLint/signature_reader.jl` (started here, grown in Task 3)
- Modify: `src/StaticLint/StaticLint.jl` (add `include("signature_reader.jl")` after `include("methodmatching.jl")`)
- Test: `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Produces: `where_var_and_bound(x::EXPR) -> Union{Nothing,Tuple{String,Union{Nothing,EXPR}}}` — for one entry of a `where` clause: the variable name and its upper-bound EXPR (`nothing` bound for a bare `T` or a lower-bound-only form; `nothing` overall when the entry isn't readable).
- Consumes: `CSTParser` predicates already imported in StaticLint; the grammar shapes handled by `where_upper_bound_expr` (methodmatching.jl:72-86): bare identifier, `T <: B`, `Lo <: T <: Hi` comparison.

- [ ] **Step 1: Write the failing test**

Append to `test/staticlint/test_staticlint.jl`:

```julia
@testitem "where_var_and_bound reads each where-clause entry shape" begin
    using JuliaWorkspaces: CSTParser
    const SL = JuliaWorkspaces.StaticLint

    # Parse a method def and pick where-clause entries off the sig EXPR.
    function where_entries(src)
        cst = CSTParser.parse(src)
        sig = CSTParser.get_sig(cst)
        entries = CSTParser.EXPR[]
        while CSTParser.iswhere(sig)
            append!(entries, sig.args[2:end])
            sig = sig.args[1]
        end
        entries
    end

    e = only(where_entries("f(x::T) where T = 1"))
    @test SL.where_var_and_bound(e) == ("T", nothing)

    e = only(where_entries("f(x::T) where T <: Integer = 1"))
    name, ub = SL.where_var_and_bound(e)
    @test name == "T"
    @test CSTParser.isidentifier(ub) && SL.valofid(ub) == "Integer"

    e = only(where_entries("f(x::T) where Int <: T <: Integer = 1"))
    name, ub = SL.where_var_and_bound(e)
    @test name == "T"
    @test SL.valofid(ub) == "Integer"

    # Lower bound licenses nothing.
    e = only(where_entries("f(x::T) where T >: Int = 1"))
    @test SL.where_var_and_bound(e) == ("T", nothing)
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/staticlint/test_staticlint.jl"; filter=ti -> occursin("where_var_and_bound", ti.name))`
Expected: FAIL — `where_var_and_bound` not defined.

- [ ] **Step 3: Implement**

```julia
# src/StaticLint/signature_reader.jl

"""
    where_var_and_bound(x::EXPR)

One `where`-clause entry → `(name, upper_bound_expr_or_nothing)`, or `nothing`
when the entry isn't a readable type-variable declaration. The only reader of
this grammar: a bare `T`, `T <: B`, the ascending chain `Lo <: T <: Hi`, and
the lower-bound forms (`T >: B`, descending chains), which yield no bound.
"""
function where_var_and_bound(x::EXPR)
    if isidentifier(x)
        n = valofid(x)
        return n === nothing ? nothing : (n, nothing)
    end
    if x.head isa EXPR && isoperator(x.head) && x.args !== nothing && length(x.args) == 2 &&
            isidentifier(x.args[1])
        n = valofid(x.args[1])
        n === nothing && return nothing
        valof(x.head) == "<:" && return (n, x.args[2])
        valof(x.head) == ">:" && return (n, nothing)
        return nothing
    end
    if headof(x) === :comparison && x.args !== nothing && length(x.args) == 5 &&
            headof(x.args[2]) === :OPERATOR && headof(x.args[4]) === :OPERATOR &&
            isidentifier(x.args[3])
        n = valofid(x.args[3])
        n === nothing && return nothing
        if valof(x.args[2]) == "<:" && valof(x.args[4]) == "<:"
            return (n, x.args[5])
        end
        return (n, nothing)
    end
    return nothing
end
```

Add to `src/StaticLint/StaticLint.jl`, next to the `include("methodmatching.jl")` line:

```julia
include("signature_reader.jl")
```

- [ ] **Step 4: Run tests to verify pass, and that existing staticlint tests stay green**

`run_tests("test/staticlint/test_staticlint.jl")`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/signature_reader.jl src/StaticLint/StaticLint.jl test/staticlint/test_staticlint.jl
git commit -m "feat(staticlint): single syntactic reader for where-clause entries"
```

---

### Task 3: Lowering EXPRs to records — `lower_type_expr` and `method_signature`

**Files:**
- Modify: `src/StaticLint/signature_reader.jl`
- Test: `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Produces: `lower_type_expr(t::EXPR, typevars::Set{String}) -> TypeExpr`; `method_signature(x::EXPR) -> Union{Nothing,MethodSignature}` (`nothing` = shape unknown); `declared_supertype(x::EXPR) -> TypeExpr` for datatype definitions.
- Consumes: Task 1 record types; Task 2 `where_var_and_bound`; existing `arg_decl_type`, `is_explicit_vararg_decl`, `bounded_vararg_N`, `names_vararg`, `unwrap_nospecialize`, `_is_union_curly` (methodmatching.jl), `_is_real_method` (checks.jl:505), `valofid`, `is_getfield_w_quotenode`.

- [ ] **Step 1: Write the failing test**

```julia
@testitem "method_signature lowers definitions to records" begin
    using JuliaWorkspaces: CSTParser, TypeRef, TypeVarRef, UnknownType, TYPE_ANY,
        SigSlot, VarargSpec
    const SL = JuliaWorkspaces.StaticLint

    ms(src) = SL.method_signature(CSTParser.parse(src))

    s = ms("f(a, b::Own, c::Base.AbstractString) = 1")
    @test [sl.type for sl in s.slots] ==
        [TYPE_ANY, TypeRef(["Own"]), TypeRef(["Base", "AbstractString"])]
    @test all(!sl.optional for sl in s.slots)
    @test s.vararg === nothing && isempty(s.kws) && !s.kwsplat

    # Parametric head; where-bound var; defaulted slot; kws.
    s = ms("function g(v::Vector{Int}, t::T, n=1; kw=2, rest...) where T <: Integer end")
    @test [sl.type for sl in s.slots] == [TypeRef(["Vector"]), TypeVarRef("T"), TYPE_ANY]
    @test [sl.optional for sl in s.slots] == [false, false, true]
    @test s.typevars == Dict{String,JuliaWorkspaces.TypeExpr}("T" => TypeRef(["Integer"]))
    @test s.kws == [:kw] && s.kwsplat

    # Vararg spellings.
    @test ms("h(xs::Int...) = 1").vararg == VarargSpec(TypeRef(["Int"]), nothing)
    @test ms("h(a, ::Vararg{String}) = 1").vararg == VarargSpec(TypeRef(["String"]), nothing)
    @test ms("h(x::Vararg{Int,3}) = 1").vararg == VarargSpec(TypeRef(["Int"]), 3)
    @test ms("h(xs...) = 1").vararg == VarargSpec(TYPE_ANY, nothing)
    # The vararg slot is not also a positional slot.
    @test isempty(ms("h(xs::Int...) = 1").slots)

    # Union lowers member-wise; unreadable shapes lower to UnknownType.
    s = ms("u(x::Union{Int,Own}) = 1")
    @test s.slots[1].type == JuliaWorkspaces.TypeUnionExpr(
        JuliaWorkspaces.TypeExpr[TypeRef(["Int"]), TypeRef(["Own"])])
    @test ms("w(x::typeof(sin)) = 1").slots[1].type == UnknownType()

    # Forward declaration has no signature.
    @test ms("function f end") === nothing

    # Datatype supertypes: explicit, and implicit Any.
    @test SL.declared_supertype(CSTParser.parse("struct Own <: MyAbs end")) == TypeRef(["MyAbs"])
    @test SL.declared_supertype(CSTParser.parse("struct Other end")) == TYPE_ANY
    @test SL.declared_supertype(CSTParser.parse("abstract type A <: B.C end")) == TypeRef(["B", "C"])
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/staticlint/test_staticlint.jl"; filter=ti -> occursin("method_signature lowers", ti.name))`
Expected: FAIL — `method_signature` not defined.

- [ ] **Step 3: Implement**

Append to `src/StaticLint/signature_reader.jl`:

```julia
# Name path of a (possibly getfield-qualified) type name: `Base.Vararg` →
# ["Base", "Vararg"]. `nothing` when any segment isn't a plain identifier.
function _name_path(t::EXPR)
    if isidentifier(t)
        n = valofid(t)
        return n === nothing ? nothing : [n]
    end
    if is_getfield_w_quotenode(t)
        lhs = _name_path(t.args[1])
        lhs === nothing && return nothing
        q = t.args[2]
        (q isa EXPR && q.args !== nothing && !isempty(q.args) && isidentifier(q.args[1])) || return nothing
        n = valofid(q.args[1])
        n === nothing && return nothing
        return push!(lhs, n)
    end
    return nothing
end

"""
    lower_type_expr(t, typevars) -> TypeExpr

A type annotation as written → the record vocabulary. `typevars` holds the
names bound by the enclosing signature's `where` clause; those lower to
`TypeVarRef`, everything else by name path. Parametric annotations lower to
their head; an inner `where` is its head; unclassifiable shapes are
`UnknownType`.
"""
function lower_type_expr(t::EXPR, typevars::Set{String})
    if CSTParser.isbracketed(t)
        return lower_type_expr(CSTParser.rem_invis(t), typevars)
    end
    if iswhere(t) && t.args !== nothing && !isempty(t.args)
        return lower_type_expr(t.args[1], typevars)
    end
    if _is_union_curly(t)
        return TypeUnionExpr(TypeExpr[lower_type_expr(t.args[i], typevars) for i in 2:length(t.args)])
    end
    if iscurly(t) && t.args !== nothing && length(t.args) >= 1
        return lower_type_expr(t.args[1], typevars)
    end
    path = _name_path(t)
    path === nothing && return UnknownType()
    length(path) == 1 && path[1] in typevars && return TypeVarRef(path[1])
    return TypeRef(path)
end

"""
    method_signature(x::EXPR) -> Union{Nothing,MethodSignature}

The signature record of a function/macro definition or assignment-form method,
read syntactically. `nothing` when the definition has no readable signature
(`function f end`, unreadable shapes) — the caller records shape-unknown.
"""
function method_signature(x::EXPR)
    _is_real_method(x) || return nothing
    sig = CSTParser.get_sig(x)
    sig === nothing && return nothing

    typevar_list = Tuple{String,Union{Nothing,EXPR}}[]
    while sig isa EXPR && (iswhere(sig) || isdeclaration(sig))
        if iswhere(sig)
            for i in 2:length(sig.args)
                vb = where_var_and_bound(sig.args[i])
                vb === nothing || push!(typevar_list, vb)
            end
        end
        sig = sig.args[1]
    end
    (sig isa EXPR && iscall(sig) && sig.args !== nothing) || return nothing

    tvnames = Set{String}(first(vb) for vb in typevar_list)
    typevars = Dict{String,TypeExpr}(
        name => (ub === nothing ? UnknownType() : lower_type_expr(ub, tvnames))
        for (name, ub) in typevar_list)

    slots = SigSlot[]
    vararg = nothing
    kws = Symbol[]
    kwsplat = false

    record_kw!(entry) = begin
        if entry isa EXPR && CSTParser.issplat(entry)
            kwsplat = true
        else
            name_x = _kw_name(entry)
            n = name_x isa EXPR && isidentifier(name_x) ? valofid(name_x) : nothing
            n === nothing || push!(kws, Symbol(n))
        end
    end

    # One pass, in source order: `(expr, optional)` — a defaulted positional
    # parses kwarg-shaped OUTSIDE the `:parameters` block.
    positionals = Tuple{EXPR,Bool}[]
    for i in 2:length(sig.args)
        arg = sig.args[i]
        if isparameters(arg)
            for p in arg.args
                record_kw!(p)
            end
        elseif iskwarg(arg)
            push!(positionals, (arg.args[1], true))
        else
            push!(positionals, (arg, false))
        end
    end

    for (i, (arg, optional)) in enumerate(positionals)
        arg = unwrap_nospecialize(arg)
        if i == length(positionals) && !optional
            n = bounded_vararg_N(arg)
            if n !== nothing || is_explicit_vararg_decl(arg)
                t = arg_decl_type(arg)
                el = iscurly(t) && length(t.args) >= 2 ? lower_type_expr(t.args[2], tvnames) : TYPE_ANY
                vararg = VarargSpec(el, n)
                continue
            end
            if CSTParser.issplat(arg)
                inner = arg.args !== nothing && length(arg.args) >= 1 ? arg.args[1] : nothing
                vararg = VarargSpec(inner === nothing ? TYPE_ANY : _slot_type(inner, tvnames), nothing)
                continue
            end
        end
        push!(slots, SigSlot(_slot_type(arg, tvnames), optional))
    end

    return MethodSignature(slots, vararg, typevars, kws, kwsplat)
end

# The recorded type of one positional parameter: its `::T` annotation, else
# definite `Any` (an unannotated slot accepts anything — certain, not unknown).
function _slot_type(arg, tvnames::Set{String})
    t = arg_decl_type(arg)
    t === nothing && return TYPE_ANY
    return lower_type_expr(t, tvnames)
end

"""
    declared_supertype(x::EXPR) -> TypeExpr

The declared parent of a datatype definition. No `<:` clause means `Any` —
syntactically certain, so it can end a supertype walk with a verdict.
"""
function declared_supertype(x::EXPR)
    sup = _super(x, nothing, nothing)
    sup === nothing && return TYPE_ANY
    sup isa EXPR || return UnknownType()
    return lower_type_expr(sup, Set{String}())
end
```

**Implementation notes for this step (verify against the parser, don't assume):**
- Check with a quick `CSTParser.parse` in the dev-env session how `f(a, b=1)` represents `b=1` (kwarg-shaped positional outside `:parameters`) and adjust the `iskwarg(arg)` branch if optional positionals arrive differently — the alignment (`optional=true` slots, in order) is what matters.
- `_super(x::EXPR, …)` (subtypes.jl:103) returns the `<:` clause's RHS for datatype heads and `nothing` when the declaration has none — Task 7 also touches this; here only the EXPR→clause read is reused, with `nothing` mapped to definite `Any`.

- [ ] **Step 4: Run tests to verify pass**

`run_tests("test/staticlint/test_staticlint.jl")`
Expected: the new testitem passes; no regressions. Iterate on parser-shape details until green — every assert in Step 1 is a real shape from the spec's acceptance table.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/signature_reader.jl test/staticlint/test_staticlint.jl
git commit -m "feat(staticlint): lower definition signatures to plain-data records"
```

---

### Task 4: Inventory integration

**Files:**
- Modify: `src/layer_inventory.jl` (`InventoryItem` fields + the three construction sites)
- Test: `test/test_file_analysis.jl` (inventory tests live where the workspace fixtures are)

**Interfaces:**
- Produces: `InventoryItem.method_sig::Union{Nothing,MethodSignature}` and `InventoryItem.supertype::Union{Nothing,TypeExpr}` (new trailing fields; back-compat constructors default both to `nothing`). Populated: `method_sig` for `:function`/`:macro` items (via `StaticLint.method_signature`), constructor records for `:struct`/`:mutable_struct` items, `supertype` for all datatype items (via `StaticLint.declared_supertype`).
- Consumes: Task 3 readers; existing construction sites `layer_inventory.jl:747` (assignment-form), `:842` (function/macro), `:879-880` (datatype).

- [ ] **Step 1: Write the failing test**

Append to `test/test_file_analysis.jl`:

```julia
@testitem "inventory: items carry method signatures and supertypes" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, UnknownType, TYPE_ANY, SigSlot

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        abstract type MyAbs end
        struct Own <: MyAbs
            a
            b::Int
        end
        struct Other end
        target(x::MyAbs) = 1
        function f end
        end
        """,
    ))
    inv = JuliaWorkspaces.derived_file_inventory(jw.runtime, ROOT)
    byname = Dict(i.name => i for i in inv.items)

    @test byname["MyAbs"].supertype == TYPE_ANY
    @test byname["Own"].supertype == TypeRef(["MyAbs"])
    @test byname["Other"].supertype == TYPE_ANY

    # Struct constructor: one all-Unknown slot per field (count opinion only).
    @test byname["Own"].method_sig !== nothing
    @test [sl.type for sl in byname["Own"].method_sig.slots] == [UnknownType(), UnknownType()]

    @test byname["target"].method_sig !== nothing
    @test byname["target"].method_sig.slots[1].type == TypeRef(["MyAbs"])

    # Forward declaration: no signature, no arity — shape data absent, kind present.
    @test byname["f"].method_sig === nothing && byname["f"].arity === nothing
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("carry method signatures", ti.name))`
Expected: FAIL — `InventoryItem` has no field `supertype`.

- [ ] **Step 3: Implement**

In `src/layer_inventory.jl`:

1. Add trailing fields to the struct (after `declared_by`):

```julia
    # Syntactic signature record for callables (`nothing` = shape unknown or
    # not a callable) and declared parent for datatypes. Unresolved names,
    # per this file's plain-data firewall.
    method_sig::Union{Nothing,MethodSignature}
    supertype::Union{Nothing,TypeExpr}
```

2. Extend the back-compat constructors so every existing arity-list call keeps working, defaulting the new fields to `nothing`:

```julia
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, nothing, nothing, nothing)
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, declared_by) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, declared_by, nothing, nothing)
```

(Adjust the existing two back-compat constructors to the new field count; keep positional order `…, arity, declared_by, method_sig, supertype`.)

3. At the function/macro site (`_classify_item!`, line 842) and the assignment-form site (`_classify_assignment!`, line 747), pass `method_sig = StaticLint.method_signature(x)` (and `declared_by = nothing`):

```julia
push!(acc.items, InventoryItem(order, id, name, qualifier, kind, _render_sig(x), String[], parent_module,
    (StaticLint._is_real_method(x) ? MethodArity(StaticLint.func_nargs(x)...) : nothing),
    nothing, StaticLint.method_signature(x), nothing))
```

4. At the datatype site (line 879-880): `supertype = StaticLint.declared_supertype(x)`; for structs additionally build the constructor record. If any field of the struct body defines a function (inner constructor), lower each inner constructor via `StaticLint.method_signature`; the inventory carries only ONE `method_sig` per item, so with inner constructors present record `method_sig = nothing` and let the arity channel carry the counts (the index marks the name shape-unknown for types, which is permissive — inner-constructor *type* records are out of scope for this plan). Without inner constructors:

```julia
ctor_sig = if CSTParser.defines_struct(x) && !any(CSTParser.defines_function, x.args[3].args)
    MethodSignature([SigSlot(UnknownType(), false) for _ in field_names],
        nothing, Dict{String,TypeExpr}(), Symbol[], false)
else
    nothing
end
push!(acc.items, InventoryItem(order, id, name, String[], kind, nothing, field_names, parent_module, arity,
    nothing, ctor_sig, StaticLint.declared_supertype(x)))
```

Note: `field_names` skips inner-constructor entries but the default-constructor slot count must be the FIELD count — reuse `field_names` length as above, which already excludes them.

- [ ] **Step 4: Restart the dev-env session (struct changed), run the inventory + file-analysis suites**

`julia_restart`, then `run_tests("test/test_file_analysis.jl")` and `run_tests("test/test_signature_records.jl")`
Expected: PASS, including all pre-existing inventory tests (back-compat constructors keep old call sites compiling).

- [ ] **Step 5: Commit**

```bash
git add src/layer_inventory.jl test/test_file_analysis.jl
git commit -m "feat(inventory): record method signatures and datatype supertypes"
```

---

### Task 5: The per-root signature index and per-name projection

**Files:**
- Modify: `src/layer_module_tree.jl` (next to `derived_method_arities_index`, line 889)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces: `derived_method_signatures_index(rt, root) -> Dict{Tuple{Vector{String},String},NameMethods}`; `derived_method_signatures(rt, root, path::Vector{String}, name::String) -> NameMethods` (returns `EMPTY_NAME_METHODS` on miss).
- Consumes: Task 4 item fields; `_walk_spliced_binding_items!`, `_resolve_extension_qualifier`, `derived_module_tree` (all as used at layer_module_tree.jl:889-904).

- [ ] **Step 1: Write the failing test**

```julia
@testitem "signature index: per-name sets with completeness markers" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, LocatedSignature

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::MyAbs) = 1\nabstract type MyAbs end\nfunction fwd end\n",
        B => "target(x::MyAbs, y) = 2\n",
    ))
    rt = jw.runtime

    nm = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")
    @test length(nm.signatures) == 2
    @test all(ls -> ls.defined_in == ["MainPkg"], nm.signatures)
    @test !nm.has_unknown_shapes && !nm.has_forward_decl

    fwd = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "fwd")
    @test isempty(fwd.signatures) && fwd.has_forward_decl

    # Unknown name → the empty, marker-free answer.
    miss = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "nope")
    @test miss == JuliaWorkspaces.EMPTY_NAME_METHODS

    # Moving a method between files leaves the per-name value ==.
    before = nm
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nfunction fwd end\n",
        B => "target(x::MyAbs) = 1\ntarget(x::MyAbs, y) = 2\n",
    ))
    after = JuliaWorkspaces.derived_method_signatures(jw2.runtime, ROOT, ["MainPkg"], "target")
    @test before == after
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("signature index", ti.name))`
Expected: FAIL — `derived_method_signatures` not defined.

- [ ] **Step 3: Implement**

In `src/layer_module_tree.jl`, mirroring the arity pair at lines 856-904:

```julia
"""
    derived_method_signatures(rt, root, path, name) -> NameMethods

The signature records of every method of `name` at module `path`, plus the
completeness markers. Projection of one per-root node — a single lookup.
"""
Salsa.@derived function derived_method_signatures(rt, root, path, name)
    @debug "derived_method_signatures" root=root path=path name=name

    return get(derived_method_signatures_index(rt, root), (path, name), EMPTY_NAME_METHODS)
end

# Callable kinds whose items participate in the signature set. `:macro_declared`
# rows are names minted by a macro — shape unknown by construction.
_is_callable_kind(kind::Symbol) =
    kind in (:function, :macro, :struct, :mutable_struct, :const, :global, :assignment)

"""
    derived_method_signatures_index(rt, root) -> Dict{Tuple{Vector{String},String},NameMethods}

Sibling of [`derived_method_arities_index`](@ref): same walk, same keying,
carrying type records instead of counts. Kept as a separate node so a
type-only edit invalidates this index while the arity index backdates.
"""
Salsa.@derived function derived_method_signatures_index(rt, root)
    @debug "derived_method_signatures_index" root=root

    tree = derived_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    sigs = Dict{Tuple{Vector{String},String},Set{LocatedSignature}}()
    unknown = Set{Tuple{Vector{String},String}}()
    fwd = Set{Tuple{Vector{String},String}}()

    _walk_spliced_binding_items!(rt, root, String[], nothing, Set{URI}([root])) do F, item, loc
        resolved = isempty(item.qualifier) ? loc :
            _resolve_extension_qualifier(modpaths, loc, item.qualifier)
        (resolved === nothing || resolved ∉ modpaths) && return
        key = (resolved, item.name)
        if item.method_sig !== nothing
            push!(get!(() -> Set{LocatedSignature}(), sigs, key),
                LocatedSignature(loc, item.method_sig))
        elseif item.kind === :macro_declared
            push!(unknown, key)
        elseif item.kind in (:function, :macro) && item.arity === nothing
            push!(fwd, key)
        elseif _is_callable_kind(item.kind) && item.arity !== nothing
            # A callable with a count but no readable signature.
            push!(unknown, key)
        end
    end

    result = Dict{Tuple{Vector{String},String},NameMethods}()
    for key in union(keys(sigs), unknown, fwd)
        result[key] = NameMethods(get(() -> Set{LocatedSignature}(), sigs, key),
            key in unknown, key in fwd)
    end
    return result
end
```

- [ ] **Step 4: Run tests**

`run_tests("test/test_file_analysis.jl")`
Expected: new testitem passes, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/layer_module_tree.jl test/test_file_analysis.jl
git commit -m "feat(tree): per-root signature index with per-name projections"
```

---

### Task 6: Extract the shared alignment engine (behavior-preserving)

**Files:**
- Modify: `src/StaticLint/methodmatching.jl` (both `match_method` bodies)
- Test: existing suites only — this task changes no behavior.

**Interfaces:**
- Produces: `SigDescriptor(fixed::Vector{Any}, opts::Vector{Any}, has_vararg::Bool, vararg_pad::Any, vararg_N::Union{Nothing,Int}, kws::Vector{Any})` (plain mutable-free struct, internal to StaticLint); `match_descriptor(args::Vector{Any}, kws::Vector{Any}, d::SigDescriptor, store, meta_dict) -> Bool`; `lower_descriptor(method::SymbolServer.MethodStore) -> SigDescriptor`.
- Consumes: current `match_method` bodies (methodmatching.jl:270-300 and :352-439).

**Semantics that must be preserved exactly** (`fixed` INCLUDES the vararg slot's own type as its last element when `has_vararg && vararg_N === nothing`; this reproduces both current bodies with one formula):

- kw gate: `!isempty(kws) && isempty(d.kws) && return false`.
- Bounded vararg (`vararg_N !== nothing`): `nfixed = length(d.fixed) - 1` is wrong for the store path — instead the store lowering *appends* `va.T` to `fixed`, so `nfixed = length(d.fixed) - 1` holds for both. Require `length(args) == nfixed + d.vararg_N`; compare slots `1:nfixed` against `d.fixed`, slots `nfixed+1:end` against `d.vararg_pad`.
- Unbounded vararg: pad `opts` first, then pad with `d.vararg_pad`; accept `length(args) == length(fixed′)` or `length(args) == length(fixed′) - 1` (vararg consumes zero).
- No vararg: `opts` padding then exact length.
- Every slot comparison: `_has_type_intersection(args[i], t, store, meta_dict) === false && return false` — only definite `false` rules out.

- [ ] **Step 1: Capture the current behavior baseline**

`run_tests("test/staticlint/test_staticlint.jl")` and `run_tests("test/test_file_analysis.jl")` — both must be green before touching anything. Record the result.

- [ ] **Step 2: Implement the descriptor and engine; rewrite both `match_method` bodies as lowerings**

```julia
struct SigDescriptor
    fixed::Vector{Any}      # required slot types; includes the vararg slot's own
                            # type as last element for the unbounded-vararg form
    opts::Vector{Any}       # defaulted slot types, in order
    has_vararg::Bool
    vararg_pad::Any         # type for args beyond the vararg slot
    vararg_N::Union{Nothing,Int}
    kws::Vector{Any}
end

function match_descriptor(args::Vector{Any}, kws::Vector{Any}, d::SigDescriptor, store, meta_dict)
    !isempty(kws) && isempty(d.kws) && return false

    # Only a DEFINITE mismatch rules a method out. An unknown slot leaves the
    # method a candidate — flagging on ignorance is a false positive.
    if d.vararg_N !== nothing
        nfixed = length(d.fixed) - 1
        length(args) == nfixed + d.vararg_N || return false
        for i in 1:nfixed
            _has_type_intersection(args[i], d.fixed[i], store, meta_dict) === false && return false
        end
        for i in (nfixed + 1):length(args)
            _has_type_intersection(args[i], d.vararg_pad, store, meta_dict) === false && return false
        end
        return true
    end

    margs = copy(d.fixed)
    if length(margs) < length(args)
        for i in 1:min(length(d.opts), length(args) - length(margs))
            push!(margs, d.opts[i])
        end
        if d.has_vararg
            for _ in 1:(length(args) - length(margs))
                push!(margs, d.vararg_pad)
            end
        end
    end
    if length(args) == length(margs) || (d.has_vararg && length(args) == length(margs) - 1)
        for i in 1:length(args)
            _has_type_intersection(args[i], margs[i], store, meta_dict) === false && return false
        end
        return true
    end
    return false
end

function lower_descriptor(method::SymbolServer.MethodStore)
    fixed = Any[last(p) for p in method.sig]
    has_vararg = false
    pad = CoreTypes.Any
    N = nothing
    if !isempty(fixed) && last(fixed) isa SymbolServer.FakeTypeofVararg
        va = last(fixed)
        has_vararg = true
        pad = va.T
        if isdefined(va, :N) && va.N isa Integer
            N = va.N
            fixed[end] = va.T   # bounded: the appended slot participates as pad only
        else
            fixed[end] = va.T   # unbounded: vararg slot's own type, engine formula
        end
    end
    return SigDescriptor(fixed, Any[], has_vararg, pad, N, Vector{Any}(method.kws))
end

match_method(args::Vector{Any}, kws::Vector{Any}, method::SymbolServer.MethodStore, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(method), store, meta_dict)
```

**Careful bounded-store check before committing:** the current store body (methodmatching.jl:278-282) computes `n_no_vararg = nsig - 1` and requires `length(args) == n_no_vararg + va.N`. With `fixed = [t₁…tₙ₋₁, va.T]`, `nfixed = length(fixed) - 1 = n_no_vararg` — identical. Fixed-slot loop runs `1:n_no_vararg` over `t₁…tₙ₋₁` — identical. Extras compare against `pad = va.T` — identical. For the unbounded store form, the engine's accept condition (`== length(margs)` after padding, or `== length(margs) - 1`) must reproduce `length(args) >= n_no_vararg`: padding extends `margs` to `length(args)` whenever `length(args) >= length(fixed)`, and the `- 1` arm covers `length(args) == n_no_vararg`; counts below that fail both — identical.

The EXPR body keeps its struct branch and its sig extraction (lines 356-399) but replaces lines 401-438 with building `SigDescriptor(margs_without_change, mopts, vararg, pad, vararg_N, mkws)` and calling `match_descriptor`. `margs` already includes the vararg slot's own type as its last element in the splat/explicit-Vararg forms (arg_type reads through the splat) — which is exactly the `fixed` convention. For the bounded form the current EXPR code compares `1:nfixed` against `margs` and tail against `vararg_T`-or-Any: with `pad = vararg_T === nothing ? CoreTypes.Any : vararg_T`, identical.

- [ ] **Step 3: Run the full baseline again**

`run_tests("test/staticlint/test_staticlint.jl")` and `run_tests("test/test_file_analysis.jl")`
Expected: identical results to Step 1 — zero behavior change. Any new failure means the descriptor formula diverged; fix the lowering, not the test.

- [ ] **Step 4: Commit**

```bash
git add src/StaticLint/methodmatching.jl
git commit -m "refactor(staticlint): one alignment engine under both match_method paths"
```

---

### Task 7: Implicit-`Any` supertype on the EXPR path

**Files:**
- Modify: `src/StaticLint/subtypes.jl` (`_super(::EXPR)`, line 103)
- Test: `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Produces: `_super(x::EXPR, store, meta_dict)` returns `CoreTypes.Any` (not `nothing`) for a datatype definition with no `<:` clause. Return type widens from `Union{EXPR,Nothing}` to `Union{EXPR,Nothing,typeof(CoreTypes.Any)}` — `_super(b::Binding, …)` (line 89-101) must pass the non-EXPR value through instead of dropping it.
- Consumes: existing `_super` cascade.

A plain `struct Other end` has supertype `Any` by language semantics — syntactically certain. Today the walk answers `nothing` (unknown), so a definite mismatch against a plain struct is silently permissive on every path. This is the single change in this plan that adds rule-out power to the *existing* EXPR path.

- [ ] **Step 1: Write the failing test**

```julia
@testitem "a datatype with no <: clause has supertype Any, definitely" begin
    using JuliaWorkspaces: CSTParser
    const SL = JuliaWorkspaces.StaticLint

    x = CSTParser.parse("struct Other end")
    @test SL._super(x, nothing, nothing) == SL.CoreTypes.Any
    x = CSTParser.parse("abstract type A end")
    @test SL._super(x, nothing, nothing) == SL.CoreTypes.Any
    # An explicit clause still returns the clause EXPR.
    x = CSTParser.parse("struct Own <: MyAbs end")
    @test SL._super(x, nothing, nothing) isa CSTParser.EXPR
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/staticlint/test_staticlint.jl"; filter=ti -> occursin("no <: clause", ti.name))`
Expected: FAIL — returns `nothing`.

- [ ] **Step 3: Implement**

In `_super(x::EXPR, store, meta_dict)` (drop the `::Union{EXPR,Nothing}` return annotation): for the `:struct`/`:abstract`/`:primitive` heads, when the recursive read yields `nothing` because the head's name position carries no `<:` declaration, return `CoreTypes.Any`. Concretely: the datatype heads recurse into the name/signature slot; when that slot is a bare identifier (or curly), the current cascade falls through to `nothing`. Restructure:

```julia
function _super(x::EXPR, store, meta_dict)
    if x.head === :struct || x.head === :abstract || x.head === :primitive
        slot = x.head === :struct ? x.args[2] : x.args[1]
        sup = _super_decl_slot(slot)
        # No `<:` clause: the parent is `Any` by language semantics — a
        # definite answer that can end a walk with a verdict.
        return sup === nothing ? CoreTypes.Any : sup
    elseif CSTParser.issubtypedecl(x)
        return x.args[2]
    elseif CSTParser.isbracketed(x)
        return _super(x.args[1], store, meta_dict)
    end
    return nothing
end

# The `<:` RHS inside a datatype head's name slot, `nothing` when absent.
function _super_decl_slot(x)
    x isa EXPR || return nothing
    CSTParser.issubtypedecl(x) && return x.args[2]
    CSTParser.isbracketed(x) && return _super_decl_slot(x.args[1])
    return nothing
end
```

And in `_super(b::Binding, …)` line 95-100: `sup` may now be `CoreTypes.Any` rather than an EXPR — return it directly:

```julia
    sup = _super(b.val, store, meta_dict)
    sup isa EXPR || return sup === nothing ? nothing : sup
    StaticLint.hasref(sup, meta_dict) ? StaticLint.refof(sup, meta_dict) : nothing
```

- [ ] **Step 4: Run staticlint + file-analysis suites; inspect any newly-flagging tests**

`run_tests("test/staticlint/test_staticlint.jl")`, `run_tests("test/test_file_analysis.jl")`
Expected: the new testitem passes. Existing `_super` negative-case tests (test_staticlint.jl:602-626) pin datatype-without-clause shapes — if one asserted `nothing` for a bare struct, that assertion is *about the old defect*: update it to expect `CoreTypes.Any` and say so in the commit message. Any *lint fixture* newly flagging must be a genuine mismatch on a plain struct (verify by hand before touching it).

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/subtypes.jl test/staticlint/test_staticlint.jl
git commit -m "fix(staticlint): a datatype without a <: clause supertypes Any, definitely"
```

---

### Task 8: `TreeDataType` and resolver threading

**Files:**
- Create: `src/StaticLint/treetypes.jl`
- Modify: `src/StaticLint/StaticLint.jl` (include after subtypes.jl), `src/StaticLint/subtypes.jl` (threading), `src/StaticLint/methodmatching.jl` (record lowering)
- Test: `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Produces:
  - `struct TreeDataType; key::Tuple{Vector{String},String}; sup::Union{Nothing,TypeExpr}; resolve::Function; end` — a workspace datatype resolved from a record; `resolve(t::TypeExpr, defined_in::Vector{String})` returns `TreeDataType` | store value | `nothing`.
  - `_type_compare(a::TreeDataType, b::TreeDataType) = a.key == b.key`; cross-kind compares (`TreeDataType` vs store types) are `false` — nominally distinct, and that is definite.
  - `_super(a::TreeDataType, store, meta_dict)` — resolves `a.sup` through `a.resolve` (defining module = `a.key[1]`); `nothing` sup → `nothing` (unreadable), `TYPE_ANY` sup → `CoreTypes.Any`.
  - `resolve_record_type(t::TypeExpr, sig::MethodSignature, defined_in, resolver) -> Any` — `TypeVarRef` through `sig.typevars` (fuel 4), `UnknownType` → `CoreTypes.Any`, `TypeUnionExpr` → `_fake_union` of resolved members, `TypeRef` → `resolver(t, defined_in)` with `nothing` mapped to `CoreTypes.Any`.
  - `lower_descriptor(ls::LocatedSignature, resolver) -> SigDescriptor`.
  - `match_method(args, kws, ls::LocatedSignature, resolver, store, meta_dict) -> Bool`.
- Consumes: Task 6 engine; Task 1 records; `_fake_union` (methodmatching.jl:308).

- [ ] **Step 1: Write the failing test (stub resolver — no Salsa involved)**

```julia
@testitem "record matching: resolution at the leaf with a stub resolver" begin
    using JuliaWorkspaces: TypeRef, TypeVarRef, UnknownType, TYPE_ANY, SigSlot,
        MethodSignature, LocatedSignature
    const SL = JuliaWorkspaces.StaticLint
    const SS = JuliaWorkspaces.SymbolServer

    # A tiny workspace universe: Own <: MyAbs <: Any, Other <: Any.
    types = Dict(
        "MyAbs" => (sup = TYPE_ANY,),
        "Own"   => (sup = TypeRef(["MyAbs"]),),
        "Other" => (sup = TYPE_ANY,),
    )
    function resolver(t::TypeRef, defined_in)
        length(t.path) == 1 || return nothing
        t.path == ["Core", "Any"] && return SL.CoreTypes.Any
        haskey(types, t.path[1]) || return nothing
        SL.TreeDataType((["MainPkg"], t.path[1]), types[t.path[1]].sup, resolver)
    end

    own   = resolver(TypeRef(["Own"]), ["MainPkg"])
    myabs = resolver(TypeRef(["MyAbs"]), ["MainPkg"])
    other = resolver(TypeRef(["Other"]), ["MainPkg"])

    @test SL._issubtype(own, myabs, nothing, nothing) === true
    @test SL._issubtype(other, myabs, nothing, nothing) === false
    @test SL._has_type_intersection(other, myabs, nothing, nothing) === false
    # Unreadable supertype: unknown, not a verdict.
    dangling = SL.TreeDataType((["MainPkg"], "X"), nothing, resolver)
    @test SL._has_type_intersection(dangling, myabs, nothing, nothing) === nothing

    sig = MethodSignature([SigSlot(TypeRef(["MyAbs"]), false)], nothing,
        Dict{String,JuliaWorkspaces.TypeExpr}(), Symbol[], false)
    ls = LocatedSignature(["MainPkg"], sig)
    @test SL.match_method(Any[own], Any[], ls, resolver, nothing, nothing) === true
    @test SL.match_method(Any[other], Any[], ls, resolver, nothing, nothing) === false
    # An UnknownType slot never rules out.
    usig = MethodSignature([SigSlot(UnknownType(), false)], nothing,
        Dict{String,JuliaWorkspaces.TypeExpr}(), Symbol[], false)
    @test SL.match_method(Any[other], Any[], LocatedSignature(["MainPkg"], usig),
        resolver, nothing, nothing) === true
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/staticlint/test_staticlint.jl"; filter=ti -> occursin("stub resolver", ti.name))`
Expected: FAIL — `TreeDataType` not defined.

- [ ] **Step 3: Implement**

```julia
# src/StaticLint/treetypes.jl

"""
    TreeDataType

A workspace-declared datatype as a comparison operand: its index key, its
declared supertype record, and the resolver that can continue the walk.
Nominal identity is the key; a tree type never equals a store type.
"""
struct TreeDataType
    key::Tuple{Vector{String},String}
    sup::Union{Nothing,TypeExpr}
    resolve::Function
end

_type_compare(a::TreeDataType, b::TreeDataType) = a.key == b.key
_type_compare(a::TreeDataType, b::_NominalType) = false
_type_compare(a::_NominalType, b::TreeDataType) = false

function _super(a::TreeDataType, store, meta_dict)
    a.sup === nothing && return nothing
    a.sup == TYPE_ANY && return CoreTypes.Any
    a.sup isa TypeRef || return nothing
    return a.resolve(a.sup, a.key[1])
end

# `TypeVarRef` hops through the signature's own typevar table; `fuel` bounds
# pathological self-referential bounds.
function resolve_record_type(t::TypeExpr, sig::MethodSignature, defined_in, resolver, fuel=4)
    fuel <= 0 && return CoreTypes.Any
    if t isa TypeVarRef
        ub = get(sig.typevars, t.name, UnknownType())
        return resolve_record_type(ub, sig, defined_in, resolver, fuel - 1)
    elseif t isa TypeUnionExpr
        isempty(t.members) && return CoreTypes.Any
        members = [resolve_record_type(m, sig, defined_in, resolver, fuel - 1) for m in t.members]
        # `FakeUnion` member comparison only understands store operands; a
        # tree member inside one would rule out falsely. Until unions get
        # their own parity row, a mixed union carries no opinion.
        all(m -> m isa SymbolServer.DataTypeStore || m isa SymbolServer.FakeTypeName, members) ||
            return CoreTypes.Any
        return _fake_union(members)
    elseif t isa TypeRef
        r = resolver(t, defined_in)
        return r === nothing ? CoreTypes.Any : r
    end
    return CoreTypes.Any   # UnknownType and anything future: no opinion
end

function lower_descriptor(ls::LocatedSignature, resolver)
    sig = ls.sig
    res(t) = resolve_record_type(t, sig, ls.defined_in, resolver)
    fixed = Any[res(sl.type) for sl in sig.slots if !sl.optional]
    opts = Any[res(sl.type) for sl in sig.slots if sl.optional]
    has_vararg = sig.vararg !== nothing
    pad = has_vararg ? res(sig.vararg.eltype) : CoreTypes.Any
    N = has_vararg ? sig.vararg.count : nothing
    if has_vararg
        push!(fixed, pad)   # engine convention: vararg slot rides last in `fixed`
    end
    return SigDescriptor(fixed, opts, has_vararg, pad, N, Vector{Any}(sig.kws))
end

match_method(args::Vector{Any}, kws::Vector{Any}, ls::LocatedSignature, resolver, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(ls, resolver), store, meta_dict)
```

Include from `src/StaticLint/StaticLint.jl` after `include("subtypes.jl")`. Note `_super(::TreeDataType)` must be defined *after* the generic `_super(_, _, _) = nothing` fallback loads — same file-ordering rule Julia handles by specificity, so plain inclusion order is fine.

**Bounded-vararg convention check:** `lower_descriptor(::LocatedSignature)` pushes the pad onto `fixed` for BOTH bounded and unbounded varargs, matching Task 6's store lowering (`fixed[end] = va.T` in both arms) — `nfixed = length(fixed) - 1` stays uniform.

- [ ] **Step 4: Run tests**

`run_tests("test/staticlint/test_staticlint.jl")`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/treetypes.jl src/StaticLint/StaticLint.jl test/staticlint/test_staticlint.jl
git commit -m "feat(staticlint): workspace datatypes as comparison operands with leaf resolution"
```

---

### Task 9: The resolver over the real tree — closures in `layer_file_analysis.jl`

**Files:**
- Modify: `src/layer_file_analysis.jl` (closure block at lines 777-801)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces: two closures handed to `check_all` (Task 10 wires them through):
  - `tree_signatures(name::String, x::EXPR) -> NameMethods` — per-name records at the call site's module path (same path computation as `tree_arities`, line 792-795).
  - `tree_resolve(t::TypeRef, defined_in::Vector{String}) -> Union{Nothing,TreeDataType,Any-store-value}`.
- Consumes: `derived_method_signatures` (Task 5); `derived_module_visible_names(rt, root, path) -> Dict{String,VisibleName}` (layer_visibility.jl:1030; `VisibleName` has `kind`, `origin`, `item::Union{Nothing,ItemRef}`, `origin_module`); `derived_file_inventory` for item-by-id lookup; the env store via the `env` already in scope.

- [ ] **Step 1: Write the failing test**

The resolver is exercised end-to-end in Task 10's fixtures; this task's test targets resolution directly:

```julia
@testitem "tree_resolve: workspace names, store names, unknowns" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, TYPE_ANY

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\n",
        B => "caller() = 1\n",
    ))
    rt = jw.runtime
    resolve = JuliaWorkspaces._tree_type_resolver(rt, ROOT)
    # `SL` comes from the FileAnalysisWS snippet.

    own = resolve(TypeRef(["Own"]), ["MainPkg"])
    @test own isa SL.TreeDataType && own.key == (["MainPkg"], "Own")
    @test own.sup == TypeRef(["MyAbs"])

    # Store name (Base is visible everywhere) → a store value the subtype
    # walk understands.
    int = resolve(TypeRef(["Int"]), ["MainPkg"])
    @test int !== nothing && !(int isa SL.TreeDataType)
    # Qualified store name.
    @test resolve(TypeRef(["Base", "AbstractString"]), ["MainPkg"]) !== nothing
    # Unknown → nothing, silently.
    @test resolve(TypeRef(["NoSuchName"]), ["MainPkg"]) === nothing
    # The walk crosses tree → store: Own <: MyAbs <: Any ends definitely.
    myabs = resolve(TypeRef(["MyAbs"]), ["MainPkg"])
    @test SL._issubtype(own, myabs, nothing, nothing) === true
end
```

- [ ] **Step 2: Run test to verify it fails**

`run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("tree_resolve", ti.name))`
Expected: FAIL — `_tree_type_resolver` not defined.

- [ ] **Step 3: Implement**

In `src/layer_file_analysis.jl` (near the closure block):

```julia
# Item lookup for a resolved name: scan the declaring file's inventory for the
# ItemRef's id. Inventories are small; the read is a dependency the analysis
# frame already takes for visible names of the same module.
function _inventory_item(rt, ref::ItemRef)
    for item in derived_file_inventory(rt, ref.file).items
        item.id == ref.id && return item
    end
    return nothing
end

# Store lookup for an external name: nested VarRef from the origin module path
# plus the name, resolved against the env's symbol table (`getsymbols(env)`).
function _store_value(symbols, module_path::Vector{String}, name::String)
    vr = nothing
    for seg in module_path
        vr = SymbolServer.VarRef(vr, Symbol(seg))
    end
    return SymbolServer._lookup(SymbolServer.VarRef(vr, Symbol(name)), symbols)
end

"""
    _tree_type_resolver(rt, root) -> Function

The leaf resolver for record slot types: a `TypeRef` plus its defining module
path → a `TreeDataType` (workspace datatype), a store value (external name),
or `nothing` (unknown). Reads whole visible-names maps, never per-name keys.
"""
function _tree_type_resolver(rt, root)
    env_of = let project_uri = derived_project_uri_for_root(rt, root)
        project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
    end
    symbols = StaticLint.getsymbols(env_of)
    resolve = function (t, defined_in)
        t isa StaticLint.TypeRef || return nothing
        isempty(t.path) && return nothing
        head, rest = t.path[1], t.path[2:end]
        vis = derived_module_visible_names(rt, root, defined_in)
        vn = get(vis, head, nothing)
        if vn === nothing
            # Not visible in the tree: a fully-qualified external path
            # (`Base.AbstractString`) or nothing at all.
            return _store_value(symbols, t.path[1:end-1], t.path[end])
        end
        if isempty(rest)
            if vn.item !== nothing
                item = _inventory_item(rt, vn.item)
                item === nothing && return nothing
                item.supertype === nothing && return nothing   # not a datatype
                return StaticLint.TreeDataType((vn.origin_module, item.name), item.supertype, resolve)
            end
            return _store_value(symbols, vn.origin_module, head)
        end
        # Qualified path whose head is visible: a workspace module or an
        # external module alias. Workspace module → recurse with the deeper
        # module path; external → store lookup under its origin.
        if vn.kind === :module && vn.item !== nothing
            return resolve(StaticLint.TypeRef(rest), vcat(vn.origin_module, head))
        end
        return length(rest) == 1 ? _store_value(symbols, vcat(vn.origin_module, head), rest[1]) : nothing
    end
    return resolve
end
```

**Implementation notes (verify, don't assume):** the exact `VisibleName.kind`/`origin` values for workspace items vs external symbols vs modules are pinned in layer_visibility.jl:40-45 and its tests — read them first and adjust the three branches. Multi-segment external paths under an aliased module (`import Base.Iterators as It; It.Zip`) may need `rest` joined segment-wise rather than `rest[end]` — handle the two-segment case correctly and return `nothing` for deeper shapes (unknown never flags).

Then in the closure block (after `tree_in_scope`, line 800):

```julia
    tree_signature_resolver = _tree_type_resolver(rt, root)
    tree_signatures = (name, x) -> begin
        p = vcat(path, _in_file_module_names(x, meta_dict))
        derived_method_signatures(rt, root, p, name)
    end
```

and pass both to `check_all` (signature extended in Task 10).

- [ ] **Step 4: Run tests**

`run_tests("test/test_file_analysis.jl")`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/layer_file_analysis.jl test/test_file_analysis.jl
git commit -m "feat(analysis): leaf resolution of record type names over tree and store"
```

---

### Task 10: The type phase in `check_call`, plus the match recorder

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`check_all` + `check_call` signatures and the tree gate), `src/StaticLint/methodmatching.jl` (recorder hooks), `src/layer_file_analysis.jl:801` and `src/layer_static_lint.jl:159` (call sites)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces:
  - `check_call(x, env, meta_dict, tree_visible=nothing, tree_extended=nothing, tree_arities=nothing, tree_in_scope=nothing, tree_signatures=nothing, tree_resolve=nothing)` (and the same two trailing parameters on `check_all`, threaded through like the existing four; `layer_static_lint.jl:159` passes nothing extra — whole-closure mode is unchanged).
  - `MatchRecorder` (mutable, fields `comparisons::Int`, `rule_outs::Int`) with `const _match_recorder = Ref{Union{Nothing,MatchRecorder}}(nothing)`; `match_descriptor` bumps `comparisons` once per candidate it examines and `rule_outs` once per `false` it returns. Test-only; production default `nothing` costs one Ref load.
- Consumes: Tasks 5-9.

**Verdict semantics of the new phase** (spec "Verdict semantics"; case 2 — `FunctionHasNoMethods` — is deliberately NOT in this plan; empty stays silent):

After the arity phase finds a match (the `# matches a workspace overload's arity` branch, checks.jl:433, and the store-fallback success path), instead of falling to the `return`:

```julia
if tree_signatures !== nothing && tree_resolve !== nothing
    nm = tree_signatures(n, x)
    # Only a complete record set can exhaust candidates; partial sets and
    # store-backed names keep their permissive answer.
    if !isempty(nm.signatures) && !nm.has_unknown_shapes && store === nothing
        args, kwargs = call_arg_types(x, false, meta_dict, getsymbols(env))
        matched = any(ls -> match_method(args, kwargs, ls,
                                         tree_resolve, getsymbols(env), meta_dict),
                      nm.signatures)
        matched || seterror!(x, IncorrectCallArgs, meta_dict)
    end
end
```

**Placement details that matter:**
- The phase runs only when the arity phase did NOT flag (an arity flag is already the answer; the two opinions stay separately gated).
- `call_has_splat(x)` has already returned before this point (line 418) — splats never reach the type phase.
- `getsymbols(env)` is the store handle every `match_method` call receives (verified: `sig_match_any` at checks.jl:528-529 passes `getsymbols(env)` for both `call_arg_types` and `match_method`) — this block mirrors it. `call_arg_types` returns untyped `[]` vectors, which are already `Vector{Any}`.
- The `store !== nothing` exclusion keeps mixed mode (store function + workspace overloads) on its current permissive path — the union is Plan 2.

- [ ] **Step 1: Write the failing end-to-end test (bare identifier, sibling file — the headline case)**

```julia
@testitem "parity: bare identifier, sibling-file callee flags a definite mismatch" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        """,
        B => """
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    msgs = [d.message for d in fa.diagnostics]
    flagged = filter(m -> occursin("method call error", m) || occursin("No method matching", m), msgs)
    @test length(flagged) == 1   # `bad` flags, `good` does not
end
```

- [ ] **Step 2: Run test to verify it fails (red phase, observed)**

`run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("sibling-file callee flags", ti.name))`
Expected: FAIL — zero diagnostics (today the arity gate accepts and returns).

- [ ] **Step 3: Implement** — thread the two parameters through `check_all`/`check_call` (default `nothing` at every existing call site), insert the phase as above, add the recorder:

```julia
# methodmatching.jl
"Test-only observation hook: counts candidate examinations and definite
rule-outs, so a fixture can assert the comparison actually ran."
mutable struct MatchRecorder
    comparisons::Int
    rule_outs::Int
end
const _match_recorder = Ref{Union{Nothing,MatchRecorder}}(nothing)
```

In `match_descriptor`, first line: `r = _match_recorder[]; r === nothing || (r.comparisons += 1)`; wrap each `return false` exit as `return _record_ruleout(false)` — simpler: a small wrapper

```julia
function match_descriptor(args, kws, d, store, meta_dict)
    res = _match_descriptor(args, kws, d, store, meta_dict)
    r = _match_recorder[]
    if r !== nothing
        r.comparisons += 1
        res || (r.rule_outs += 1)
    end
    return res
end
```

(rename the Task 6 body to `_match_descriptor`).

In `src/layer_file_analysis.jl:801`, pass the two new closures:

```julia
    StaticLint.check_all(cst, _lint_options_from_config(lint_config), env, meta_dict,
        tree_visible, tree_extended, tree_arities, tree_in_scope,
        tree_signatures, tree_signature_resolver)
```

- [ ] **Step 4: Run the new test and the full file-analysis + staticlint suites**

`run_tests("test/test_file_analysis.jl")`, `run_tests("test/staticlint/test_staticlint.jl")`
Expected: new test passes; the pre-existing cross-file tests (e.g. "a chain that leaves this file rules nothing out", test_file_analysis.jl:2196 — correct code) stay green. Any pre-existing fixture that now flags is a candidate false positive: STOP and diagnose before adjusting anything (systematic-debugging skill).

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/linting/checks.jl src/StaticLint/methodmatching.jl src/layer_file_analysis.jl src/layer_static_lint.jl test/test_file_analysis.jl
git commit -m "feat(staticlint): type-check tree-visible callees against signature records"
```

---

### Task 11: The bare-identifier parity row

**Files:**
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Consumes: everything above; `JuliaWorkspaces.StaticLint._match_recorder`, `MatchRecorder`.

One fixture per placement, each with the matching call (`good`) and the definitively-mismatching call (`bad`), each asserting exactly one flag AND (for the record path) that the comparison ran. The type universe in every placement: `MyAbs <: Any`, `Own <: MyAbs`, `Other <: Any`; callee `target(x::MyAbs)`; arguments are typed parameters (a constructor call types as `Any` and would make the fixture vacuous).

- [ ] **Step 1: Write the four placement testitems (each observed red or already-green — record which)**

```julia
@testitem "parity/bare-id (a): closure callee" setup=[FileAnalysisWS] begin
    # Types live in the SAME file as the closure: the EXPR path resolves
    # annotations through local bindings only — its cross-file hop
    # (TreeRef → record) is deferred to Plan 2 and is NOT asserted here.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        function caller(v::Own, w::Other)
            target(x::MyAbs) = 1
            target(v)
            target(w)
        end
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/bare-id (b): same-file module-level callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

# (c) sibling-file is Task 10's testitem.

@testitem "parity/bare-id (d): store callee" setup=[FileAnalysisWS] begin
    # `sin` has a `sin(x::Real)` method (an ABSTRACT store param — the good
    # arm must match through ancestry, not by luck), and no method a plain
    # struct can reach, so the bad arm is a definite rule-out on every
    # candidate. VERIFY at red phase that `good` matches and `bad` is ruled
    # out via the store's actual method set; if Base's `sin` methods make
    # either arm unknown-not-definite, pick another Base function with a
    # single abstract-typed method rather than weakening the assertion.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        struct Other end
        struct MyReal <: Real end
        good(v::MyReal) = sin(v)
        bad(w::Other) = sin(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/bare-id: a bare one-file root reports like placement (b)" setup=[FileAnalysisWS] begin
    # The same source analysed as a project-less one-file root: the file IS
    # its whole tree, so the record path must reach the same verdict. (True
    # "no root" cannot be expressed through derived_file_analysis — a file
    # outside every root produces no analysis at all, which is the silent
    # end of the degradation map by construction.)
    jw = ws_with(Dict(
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, B, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    # Same verdict as placement (b) — a one-file root has its whole tree.
    @test length(flagged) == 1
end

@testitem "parity/bare-id: the record comparison actually runs" setup=[FileAnalysisWS] begin
    # `SL` comes from the FileAnalysisWS snippet.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\ntarget(x::MyAbs) = 1\n",
        B => "good(v::Own) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    rec = SL.MatchRecorder(0, 0)
    SL._match_recorder[] = rec
    try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    @test rec.comparisons >= 2   # both call sites reached the engine
    @test rec.rule_outs >= 1     # `bad` was ruled out, not skipped
end
```

**Note on (b) and the no-root axis:** in per-file mode a same-file module-level callee is tree-visible, so both run the record path — their agreement with (c) is the parity claim. The recorder testitem must run with a *fresh* workspace (Salsa caches per runtime — a reused runtime would have the analysis cached and the recorder would see zero comparisons).

- [ ] **Step 2: Run each; record red/green as observed**

`run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity/bare-id", ti.name))`
Expected after Task 10: (b), (c), one-file-root, recorder PASS. (a) and (d) become green at Task 7 (both hinge on the implicit-`Any` supertype making a plain struct rulable-out) — if either was still red before this task, that observation IS their red phase; record it. Diagnose any remaining failure before adjusting a fixture; a fixture that cannot be made to flag identically in all placements is a spec deviation and must be recorded, not papered over.

- [ ] **Step 3: Fix what red placements reveal** — likely candidates: `_super(::Binding)` line 96-100 dropping non-EXPR sup values (Task 7 touched it; verify), resolution of `MyAbs` from `B`'s module path, `call_arg_types` argument vector types. Keep fixes minimal and in the layer they belong to.

- [ ] **Step 4: Run the full suite**

`run_tests("test/test_file_analysis.jl")`, `run_tests("test/staticlint/test_staticlint.jl")`, `run_tests("test/test_signature_records.jl")`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add test/test_file_analysis.jl
git commit -m "test(staticlint): bare-identifier parity row across placements"
```

---

### Task 12: The qualified-name parity row

**Files:**
- Test: `test/test_file_analysis.jl`; fixes in `src/layer_file_analysis.jl` (`_tree_type_resolver`) as revealed.

**Interfaces:**
- Consumes: Task 9's resolver (multi-segment `TypeRef` branches).

- [ ] **Step 1: Write the testitems**

```julia
@testitem "parity/qualified: Base-qualified annotation, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Base.AbstractString) = 1\n",
        B => "good(v::String) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/qualified: workspace-module-qualified annotation" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        module Inner
        abstract type MyAbs end
        end
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "struct Own <: Inner.MyAbs end\nstruct Other end\ntarget(x::Inner.MyAbs) = 1\n",
        B => "good(v::Own) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end
```

- [ ] **Step 2: Run to observe red** — the workspace-module-qualified case exercises the resolver's `vn.kind === :module` branch and `Own`'s supertype record `TypeRef(["Inner", "MyAbs"])`; expect at least one red. `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity/qualified", ti.name))`

- [ ] **Step 3: Fix the resolver branches the red run identifies** (module descent; `_super(::TreeDataType)` resolving a multi-segment sup). Re-run until green.

- [ ] **Step 4: Full suites again**

`run_tests("test/test_file_analysis.jl")`, `run_tests("test/staticlint/test_staticlint.jl")`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add test/test_file_analysis.jl src/layer_file_analysis.jl
git commit -m "test(staticlint): qualified-name parity row; resolver module descent"
```

---

### Task 13: Backdating and incremental assertions

**Files:**
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Consumes: `update_file!(jw, TextFile(uri, SourceText(text, "julia")))` (the same mutation API the existing incremental tests use — find one with `grep -n "update_file!" test/` and copy its exact call shape; do NOT build text via `string(::SourceText)`, which returns the repr).

- [ ] **Step 1: Write the testitems**

```julia
@testitem "backdating: a type-only edit leaves arity answers equal" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::Int) = 1\n",
        B => "caller(y) = target(y)\n",
    ))
    rt = jw.runtime
    arities_before = JuliaWorkspaces.derived_method_arities(rt, ROOT, ["MainPkg"], "target")
    sigs_before = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")

    update_file!(jw, TextFile(A, SourceText("target(x::String) = 1\n", "julia")))

    @test JuliaWorkspaces.derived_method_arities(rt, ROOT, ["MainPkg"], "target") == arities_before
    @test JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target") != sigs_before
end

@testitem "backdating: moving a method between files leaves the signature set equal" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::Int) = 1\ntarget(x::String) = 2\n",
        B => "\n",
    ))
    rt = jw.runtime
    before = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")

    update_file!(jw, TextFile(A, SourceText("target(x::Int) = 1\n", "julia")))
    update_file!(jw, TextFile(B, SourceText("target(x::String) = 2\n", "julia")))

    after = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")
    @test after == before

    # And the diagnostic set of an unrelated caller is unchanged: recompute
    # from cold on an identical second workspace and compare.
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::Int) = 1\n",
        B => "target(x::String) = 2\n",
    ))
    fa_inc = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    fa_cold = JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, B)
    @test [d.message for d in fa_inc.diagnostics] == [d.message for d in fa_cold.diagnostics]
end
```

Adjust the `update_file!`/`TextFile`/`SourceText` imports to the snippet's conventions (add `using JuliaWorkspaces: update_file!, TextFile, SourceText` inside the testitems if the snippet doesn't provide them).

- [ ] **Step 2: Run to verify current state** — first testitem's arity assertion should pass immediately (arity index already backdates on `main`); the signature assertions are the new claims. `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("backdating", ti.name))`

- [ ] **Step 3: Fix any equality break the move test reveals** — a failure here means a record smuggled position-dependent data; find the field, remove it (the records must stay position-free), never "fix" by loosening the assertion.

- [ ] **Step 4: Full suite, one last time, all three files**

`run_tests("test/test_signature_records.jl")`, `run_tests("test/staticlint/test_staticlint.jl")`, `run_tests("test/test_file_analysis.jl")`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add test/test_file_analysis.jl
git commit -m "test(tree): signature records backdate under type-preserving edits and moves"
```

---

### Task 14: Corpus sweep (verification gate, not code)

**Files:**
- Read: `docs/perf/lsbench/README.md` (the harness and its five reading traps)

- [ ] **Step 1:** Run the sweep harness over the real-root corpus against `main` and this branch, per its README. Work on a copied depot/registry (never the real `~/.julia`).
- [ ] **Step 2:** Diff diagnostics both directions. Every NEW diagnostic: classify by hand; each must be a true positive (a real definite mismatch). Every DISAPPEARED diagnostic: explain (expected: none from this plan). Counts alone gate nothing.
- [ ] **Step 3:** Record the classification table in the PR description. If any new diagnostic is a false positive: STOP, diagnose with the systematic-debugging skill, fix before proceeding — a false positive here is an invariant-1 breach (an unknown reached `false` somewhere).

---

## Deferred to Plan 2 (do not start here)

Parametric/`Union`/`where`/`Vararg`/optional/keyword parity rows as fixtures (the *reader* already lowers them; the rows prove the verdicts); placement (e) mixed-mode union replacing the `tree_extended` decline; `FunctionHasNoMethods` on definite emptiness; constructor-call argument typing; the EXPR path's cross-file ancestry hop (`_super(::Binding)` resolving a `TreeRef` supertype through the records — until then a closure whose annotation types live in a sibling file stays permissive); the property-test record arm; inner-constructor records.
