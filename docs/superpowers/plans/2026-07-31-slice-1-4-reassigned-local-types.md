# Slice 1.4 — infer a reassigned local's type from all its assignments

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a local is assigned differing types, give it `Any` instead of whichever assignment the traversal happened to reach last — fixing the one false positive slice 1 shipped with, and every other consumer of `Binding.type` along the way.

**Architecture:** Collect, during `semantic_pass`, every binding created for a name that gets rebound in the same scope. At the end of each traversal phase, if the collected bindings carry more than one distinct *known* type, write `CoreTypes.Any` to all of them. Because `check_all` runs as a separate traversal after `semantic_pass` completes, every consumer — the call check, `isa`, hover — reads the settled type with no consumer-side change.

**Tech Stack:** Julia, StaticLint (binding/scope/traversal), SymbolServer type values, Salsa, TestItemRunner.

## Why this shape

Recorded so it is not re-litigated (full background: `docs/design/2026-07-31-module-inventory-and-resolution.md` §17b):

- **A forward-only fold is not enough on its own.** It computes the correct unified value at the *final* binding, but earlier binding objects keep the type they were inferred with, and `refof` at a use site points at whichever binding was live at that point. In the motivating case the informative assignment comes *after* the use, so the use still reads the stale type. Back-filling the whole group is what makes `refof`-based consumers correct, and it is what earns this slice its place ahead of the record merge — it fixes `isa` and hover, not just one lint.
- **No `prev` chain and no consumer change.** Grouping the bindings during the pass gives the same reach for less machinery, and once the group is back-filled there is nothing for a consumer to do differently.
- **`Any`, not a union.** `_type_compare` is one-directional with only a *right*-side union method (`subtypes.jl:37`, and `_super(::FakeUnion)` is `Any`), so a `FakeUnion` binding type makes `_has_type_intersection(Union{Nothing,Int}, Integer)` return **false** — a new false-positive class covering every union member that is a proper subtype of an abstract parameter. If a union is ever wanted, the any-member rule must live in `_has_type_intersection`, **never** as an `_issubtype(a::FakeUnion, …)` method: real subtyping needs *all* members and `_issubtype` is shared with the `isa` check, which the any-member reading would silently corrupt.

## Global Constraints

- **Only ever downgrade a known type to `Any`.** Never touch a binding whose `.type` is already `nothing` — that means "not inferred", and some consumers fall back to by-use inference when they see it. Forcing `Any` there would suppress that fallback. Unify only when the group holds **two or more distinct known types**.
- **Plain assignments only.** The `defines_function` path deliberately rebinds a name as methods accumulate, and `add_binding` has explicit arms for it ("do nothing, name of `x` will resolve to the root method"). Method definitions are not type disagreements and must not be collected.
- **Nothing new in a Salsa-cached value.** The collection is pass-local traversal state, discarded when `semantic_pass` returns. `Binding` gains no field. (`Binding` is a plain `mutable struct` and compares by identity, so mutating `.type` in place is equality-neutral.)
- **Assert lint behaviour through the per-file pass** — `derived_file_analysis(rt, root, file)` — never `derived_static_lint_meta_for_root`.
- Comments terse; no references to design docs, section numbers or this plan.
- Run tests via TestItemRunner in the dev-env Julia session (`scripts/environments/development`), never by spawning `julia` or `Pkg.test`.

## The structural fact that drives the design

`semantic_pass` (`src/StaticLint/StaticLint.jl:385`) runs in **two phases**:

1. `process_EXPR(cst, state)` with a `Toplevel` state — top-level and module-level code;
2. a delayed phase (`:392-408`) that traverses each deferred expression — **function bodies** — with a **fresh `Delayed` state per item**.

Locals therefore get bound in phase 2, in a per-item state. So the collection must exist on both state types and be flushed in both places. `Delayed` already carries exactly this shape of pass-local collection — `deferred_unused::Vector{Tuple{Binding,Scope}}` (`:301`), flushed at `:405-407` — so follow that precedent rather than inventing a new mechanism.

Grouping by `(scope, name)` keeps a closure's own local separate from an outer one of the same name, since they live in different `Scope` objects.

## File Structure

| File | Responsibility |
|---|---|
| `src/StaticLint/StaticLint.jl` | The collection field on `Toplevel` and `Delayed`; the flush at the end of each phase. |
| `src/StaticLint/bindings.jl` | Record the displaced and incoming binding at the plain-assignment rebinding branch. |
| `src/StaticLint/type_inf.jl` | The unification helper (type agreement + write-back). |
| `test/staticlint/test_inference.jl` | Binding-level unification tests (Tasks 1–2). |
| `test/test_file_analysis.jl` | End-to-end lint behaviour, incl. the `find_from_hash` shape (Task 3). |

---

### Task 1: Collect the bindings of a rebound name

**Files:**
- Modify: `src/StaticLint/StaticLint.jl` (`Toplevel` at `:236-256`, `Delayed` at `:294-304`)
- Modify: `src/StaticLint/bindings.jl` (the rebinding branch at `:484-491`)
- Test: `test/staticlint/test_inference.jl`

**Interfaces:**
- Produces: `TraverseState.rebound::Dict{Tuple{Scope,String},Vector{Binding}}`, holding, for each `(scope, name)` rebound at least once, every `Binding` created for it in source order. Absent names are not keys. `Scope` is a mutable struct so it hashes by identity, which is what we want.
- Both `Toplevel` and `Delayed` must carry the field — `add_binding(x, state, scope)` is generic over `TraverseState`.

- [ ] **Step 1: Write the failing test**

Add to `test/staticlint/test_inference.jl`. Follow the file's existing setup idiom for building a `meta_dict` from source — read a neighbouring testitem first and reuse it rather than inventing a harness.

Assert, for a function body containing `x = nothing`, a use, then `x = 1`:
- the `(scope, "x")` group exists and holds **3** bindings in source order (the two assignments plus… verify the real count in-situ and pin whatever it actually is — do not guess);
- a name assigned exactly once produces **no** key;
- a function with two methods (`f(x) = 1` then `f(x, y) = 2`) produces **no** key, because method accumulation is not rebinding.

- [ ] **Step 2: Run it and confirm it fails**

```julia
run_tests("test/staticlint/test_inference.jl"; filter=ti -> occursin("rebound", ti.name))
```
Expected: FAIL — no `rebound` field.

- [ ] **Step 3: Implement**

Add the field to both state structs with a `Dict{Tuple{Scope,String},Vector{Binding}}()` default in their constructors, then record at the plain-assignment rebinding branch in `add_binding` — the `elseif scopehasbinding(scope, name)` arm around `:484-491`, the one that ends in `scope.names[name] = b` after `check_const_decl`.

Record **both** the displaced binding (`scope.names[name]`, before the overwrite) and the incoming `b`, de-duplicated so a three-assignment name yields three entries rather than four. Do **not** record in the `defines_function` arms.

Note `infer_type(b, scope, state)` runs at the *end* of `add_binding` (`:505`), so `b.type` is not yet set when you record — that is fine and expected, since unification happens later.

- [ ] **Step 4: Confirm it passes**

```julia
run_tests("test/staticlint/test_inference.jl"; filter=ti -> occursin("rebound", ti.name))
run_tests("test/staticlint/test_inference.jl")
```
Restart the session first — the state structs changed.

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/StaticLint.jl src/StaticLint/bindings.jl test/staticlint/test_inference.jl
git commit -m "feat(staticlint): collect the bindings of a reassigned local"
```

---

### Task 2: Unify the collected types

**Files:**
- Modify: `src/StaticLint/type_inf.jl` (the helper)
- Modify: `src/StaticLint/StaticLint.jl` (flush after `process_EXPR` and in the delayed loop at `:392-408`)
- Test: `test/staticlint/test_inference.jl`

**Interfaces:**
- Consumes: `state.rebound` (Task 1).
- Produces: `_unify_rebound_types!(state)` — for each group whose bindings carry **two or more distinct known types**, sets `.type = CoreTypes.Any` on every binding in the group. Groups with ≤1 distinct known type are left untouched, as are bindings whose `.type` is `nothing`.

Type identity: `.type` is `Union{Binding,SymbolServer.SymStore,Nothing}`. Do **not** assume two `DataTypeStore`s for the same type are the same object — establish empirically how the inferred types for `x = 1` in two places compare, and write the comparison accordingly. `CoreTypes.Any` is itself a `DataTypeStore`, so an `isa DataTypeStore` check proves nothing.

- [ ] **Step 1: Write the failing tests**

Assert on binding types after `semantic_pass`, in a function body:
- `x = nothing` … `x = 1` → **both** bindings have type `Any` (this is the back-fill: the *earlier* binding must change, which is the whole point);
- `x = 1` … `x = 2` → neither becomes `Any`; the type stays `Int`;
- a binding whose type is `nothing` alongside a known type → the `nothing` one stays `nothing`;
- a two-method function → unaffected;
- a closure's `x` and an enclosing `x` with differing types → only the group that actually disagrees is downgraded (pins the `(scope, name)` grouping).

Assert `!_isany(...)` plus the resolved name for the negative cases; `isa DataTypeStore` is vacuous.

- [ ] **Step 2: Run and confirm failure**

Expected: the first assertion fails — the earlier binding still carries `Nothing`.

- [ ] **Step 3: Implement**

Write `_unify_rebound_types!` in `type_inf.jl`, and call it in `semantic_pass`: once after `process_EXPR(cst, state)` for the `Toplevel` state, and once per delayed item alongside the existing `ds.deferred_unused` loop at `:405-407`. Both flush points sit before `semantic_pass` returns, so everything downstream sees settled types.

- [ ] **Step 4: Confirm passing**

```julia
run_tests("test/staticlint/test_inference.jl")
run_tests("test/staticlint/test_staticlint.jl")
```

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/type_inf.jl src/StaticLint/StaticLint.jl test/staticlint/test_inference.jl
git commit -m "feat(staticlint): unify a reassigned local's type to Any when assignments disagree"
```

---

### Task 3: End-to-end, hover, and the sweep

**Files:**
- Test: `test/test_file_analysis.jl`, plus hover tests wherever the repo keeps them
- Measurement: `docs/perf/typesweep.jl`

- [ ] **Step 1: Write the end-to-end tests**

The named regression pin, reproducing the shipped false positive's shape (`Revise`'s `find_from_hash` — the informative assignment comes **after** the guarded use, which is what defeats a forward-only fold):

```julia
# a.jl
find_from_hash(name::String, h::Base.SHA1) = 1
# b.jl
function manifest_paths!()
    h = nothing
    for line in 1:3
        if h !== nothing
            find_from_hash("x", h)     # must NOT be flagged
        elseif line == 2
            h = Base.SHA1("abc")
        end
    end
end
```

Also pin that real mismatches still flag — `f(x::Int)` called with a genuinely `String`-typed local must still be caught, or this slice has simply disabled the feature.

- [ ] **Step 2: Confirm the first fails and the second passes**

- [ ] **Step 3: Pin the hover change**

Hover on a reassigned local now reports `Any` rather than the first assignment's type. That is intended — flow-insensitively the variable really can hold either — but it is user-visible, so pin it with a test rather than letting it land as a side effect.

- [ ] **Step 4: The gate — a both-direction 74-root sweep**

```julia
include("docs/perf/typesweep.jl")
```

Unlike slice 1, **a diagnostic drop here can be legitimate** — that is the point of the change. So both directions need explaining, not just one:

- every diagnostic **gone** should be attributable to a reassigned local (spot-check a sample, and confirm the `find_from_hash` one is among them);
- every diagnostic **new** is a finding — unification can create one by widening a type to `Any` where a by-use inference previously produced something sharper. Investigate each; do not wave any through.

Report both counts against `main`, and confirm the accepted §17b false positive is gone.

- [ ] **Step 5: Commit, and update the record**

Mark §17b resolved in `docs/design/2026-07-31-module-inventory-and-resolution.md`, keeping the description of what the bug *was* — it explains why the machinery exists. Note the sweep's before/after numbers in `docs/perf/`.

---

## Self-Review

**Coverage.** §17b's fix in full: all assignments considered (Task 1), agree-or-`Any` (Task 2), the motivating case pinned and measured (Task 3). No consumer change, because back-filling makes `refof` correct for everyone.

**Out of scope.** A `FakeUnion` binding type (see "Why this shape"); flow-sensitivity of any kind — a guard like `if x !== nothing` is still not read, we merely stop claiming a type we cannot justify; and `func_nargs`'s failure to recognise an anonymous `::Vararg{T}`, which is a separate pre-existing arity-side bug worth its own change.

**Risks.**
- The two-phase traversal is the thing most likely to be got wrong: flushing only after `process_EXPR` would silently miss every local, since function bodies are traversed in the delayed phase. Task 2's first assertion is inside a function body specifically to catch that.
- Widening types to `Any` can *remove* true positives elsewhere; the sweep's "gone" direction is what surfaces that, so it must be explained rather than celebrated.
- Restart the Julia session after Task 1 — `Toplevel` and `Delayed` are struct definitions and Revise cannot patch them.

**Verified against the code while writing this plan** (do not re-derive): `semantic_pass` is two-phase with a fresh `Delayed` per deferred item (`StaticLint.jl:385-408`); `Delayed.deferred_unused` is the precedent for a pass-local collection flushed at `:405-407`; `add_binding`'s plain-assignment rebinding arm is `:484-491` and overwrites `scope.names[name]` with no link to the displaced binding; `infer_type` runs at `:505`, *after* the scope assignment; `Binding` is a plain `mutable struct` with no `@auto_hash_equals`, so it compares by identity; `check_all` runs after `semantic_pass` (`layer_file_analysis.jl:719` then `:774`), which is what makes an end-of-pass flush sufficient.
