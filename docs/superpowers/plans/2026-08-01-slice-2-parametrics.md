# Slice 2 — parametrics and `where` bounds: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the cross-file type check judge parameters whose recorded type is a parametric (`x::Vector{Int}`, `x::Union{Int,Nothing}`) or a `where`-bound type variable (`x::T where T<:Real`) — 11.1% of annotated parameters, plus every `where`-parametrised signature.

**Architecture:** A resolver change only. Slice 1.5 already records types **as written**, so `Vector{Int}` is on the record as `path=["Vector"], args=[ParamType(["Int"])]`; nothing is missing from the data. `_recorded_type_path` simply declines anything with arguments. Replace it with a resolver that mirrors what the *local* path already does.

## The precedent to mirror — read it first

`StaticLint._resolve_type_expr` (`src/StaticLint/methodmatching.jl`) is the local path's answer to the same question, and has been in production for both the `isa` check and local method matching:

```julia
if _is_union_curly(t)
    return _fake_union([_resolve_type_expr(t.args[i], ...) for i in 2:length(t.args)])
end
if iscurly(t) && length(t.args) >= 1
    t = t.args[1]        # any other parametric: resolve the HEAD, drop the arguments
end
```

Two cases, and the second is deliberately lossy: `Vector{Int}` and `Vector{String}` both resolve to `Vector`. That is not a shortcut to improve on here — matching it is what keeps the cross-file and local paths from disagreeing about the same code. Comparing type *arguments* is a separate question and is **out of scope**.

## Global Constraints

- **This slice widens.** Unlike 1 and 1.5, new diagnostics are the point. The gate is not "nothing moved" but **"every moved diagnostic is a true positive"** — each one investigated and named in the report. A *removed* diagnostic is a finding, since resolving more types should never rule out less.
- **`FakeUnion` belongs on the parameter side only.** `_type_compare` has a right-side union method (`a::DataTypeStore, b::FakeUnion`) and no left-side one, so a union as the *parameter* operand works and a union as the *argument* operand does not. This slice only ever builds unions for parameters. Do not add a left-side `_issubtype(a::FakeUnion, …)` method: real subtyping needs *all* members while intersection needs *any*, and `_issubtype` is shared with the `isa` check, which the any-member reading would silently corrupt.
- **Unknown stays permissive.** Anything unresolvable is `CoreTypes.Any`, which can only remove a diagnostic.
- **Do not touch judgeability.** `_sig_is_judgeable` decides whether a record's parameter list *aligns* with a call's arguments; that is orthogonal to how well any one type resolves. The struct kind gate and the `:vararg` rule stay exactly as they are.
- Plain data only in cached values; this slice changes no record shape, only the resolver.
- Comments terse; no references to design docs, section numbers or this plan.
- Tests via `TestItemRunner.run_tests(pkgdir; filter)` in the dev-env session; never spawn `julia` or `Pkg.test`.

## File Structure

| File | Responsibility |
|---|---|
| `src/layer_file_analysis.jl` | `_recorded_type_path` → a value-returning resolver; the `Union` and head-of-curly cases; `where`-bound substitution. |
| `test/test_file_analysis.jl` | Resolution and end-to-end lint behaviour. |
| `docs/perf/typesweep.jl` | The gate; its instrumented copy of `_tree_types_match` must stay behaviour-identical. |

---

### Task 1: Parametrics

**Files:** `src/layer_file_analysis.jl`; test `test/test_file_analysis.jl`

`_recorded_type_path(t, tvars)` currently returns `nothing` whenever `!isempty(t.args)`. Replace the path-returning shape with one that resolves a `ParamType` to a comparison operand directly, handling:

1. **`Union{…}`** — resolve each argument and fold into a `FakeUnion` (`StaticLint._fake_union`). A union whose members are all unknown must collapse to `CoreTypes.Any`, not to a union of `Any`s; check what `_has_type_intersection` does with the latter before deciding, and pin whichever you choose.
2. **Any other parametric** — resolve the head path, ignore the arguments.
3. **A value node** (`path` empty, `value` non-empty) — `Any`. `Val{:String}` must not resolve `String`; the record already guards this, so confirm rather than re-implement.
4. **A type variable** — still `Any` in this task; Task 2 substitutes the bound.

Note the head of a parametric may itself be dotted (`Base.Vector{Int}`), so route it through the existing qualified-store lookup rather than assuming a bare name.

- [ ] **Step 1: Write the failing tests.** Resolution-level first: `x::Vector{Int}` resolves to the `Array`/`Vector` datatype (assert the resolved name, not `isa DataTypeStore` — `CoreTypes.Any` is itself a `DataTypeStore`, so that assertion is vacuous); `x::Union{Int,Nothing}` yields a union that intersects both `Int` and `Nothing` and not `String`; `x::Val{:String}` does **not** resolve `String`; `x::Vector{T} where T` resolves the head.

  Then end-to-end: a sibling `f(x::Vector{Int}) = 1` called as `f("s")` is flagged, called as `f([1,2])` is not; `f(x::Union{Int,Nothing})` accepts both members and rejects a `String`. Assert through `derived_file_analysis(rt, root, file)`, never `derived_static_lint_meta_for_root`.
- [ ] **Step 2: Run them; confirm they fail** — the parametric ones because everything currently resolves to `Any`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Confirm green**, then run `test/test_file_analysis.jl`, `test/test_inventory.jl`, `test/test_module_tree.jl` and `test/staticlint/test_staticlint.jl` entire.
- [ ] **Step 5: The sweep.** Run `docs/perf/typesweep.jl` over all 74 roots. **Movement is expected.** For every new diagnostic, name the callee, the parameter type and the argument type, and state why it is a true positive. For every *removed* diagnostic, stop and report — that direction should be impossible. Report the `compared` and `rejected` counts alongside, since `rejected` rising is the signal the slice is doing anything at all.
- [ ] **Step 6: Commit.**

---

### Task 2: `where`-bound substitution

**Files:** `src/layer_file_analysis.jl`; test `test/test_file_analysis.jl`

A parameter typed by a method-local type variable currently resolves to `Any`. The record carries each variable's **upper bound** (`SigTypeVar.upper`), and substituting it is sound for a rule-out check: `f(x::T) where T<:Real` can only ever be instantiated at a subtype of `Real`, so an argument that cannot intersect `Real` cannot match any instantiation.

Three things to get right:

- **`where T>:B` yields no usable upper bound** — `B` is a *lower* bound. The record already stores unknown for it; confirm, and pin it, because reading `B` as the bound would be unsound in the flagging direction.
- **Substitution applies at every depth**, not just the top: `x::Vector{T}` resolves its head to `Vector` regardless, but `x::Union{T,Nothing}` must substitute inside the union.
- **A bound that is itself a type variable** (`where {T, S<:T}`) must terminate. Resolve to `Any` rather than chasing, unless a single hop is provably enough — say which you chose.

- [ ] **Step 1: Write the failing tests.** `f(x::T) where T<:Real` called with a `String` is flagged; called with an `Int` is not. `f(x::T) where T` is never flagged. `f(x::T) where T>:Int` is never flagged. `f(x::Union{T,Nothing}) where T<:Real` rejects a `String`.
- [ ] **Step 2: Confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Confirm green** across the same four suites.
- [ ] **Step 5: The sweep**, with the same rules as Task 1 — movement expected, each new diagnostic justified, any removal a finding. Report Task 1's and Task 2's movement **separately**, so each widening's effect is attributable; that is the reason these are two tasks rather than one.
- [ ] **Step 6: Commit.**

---

## Self-Review

**Out of scope, deliberately:** comparing type *arguments* (`Vector{Int}` vs `Vector{String}` still both resolve to `Vector`, matching the local path); a left-side `FakeUnion` rule in `_issubtype`; anything touching judgeability or the record's shape.

**Risks.**
- The lossy head-of-curly rule is the one most likely to be "improved" by an implementer into argument comparison. That would diverge from `_resolve_type_expr` and make the cross-file and local paths disagree about identical code.
- A union of all-unknown members is the subtle case: it must not become a union of `Any`s that then matches nothing, or it inverts into a false-positive source.
- Two widenings in two tasks: keep the sweeps separate, or neither movement is attributable.

**Verified while writing this plan** (do not re-derive): `_recorded_type_path` declines on `!isempty(t.args)`, which is the only thing stopping parametrics today; `_resolve_type_expr` special-cases `_is_union_curly` and otherwise takes `t.args[1]`; `_fake_union` folds members with `SymbolServer.FakeUnion`; `_type_compare(a::DataTypeStore, b::FakeUnion)` exists while no left-side method does; `ParamType` carries `path`, `args` and `value`, and value nodes have an empty `path`.
