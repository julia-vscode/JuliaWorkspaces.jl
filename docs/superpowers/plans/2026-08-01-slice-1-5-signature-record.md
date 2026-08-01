# Slice 1.5 — one signature record: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `InventoryItem.arity` and `InventoryItem.param_types` with one structured `signature` carrying each parameter's name, type-as-written and role — computed by one traversal, aggregated by one splice walk, with `MethodArity` derived rather than stored.

**Architecture:** One record, one per-root index, **two** projections. The arity projection reproduces today's `MethodArity` exactly so a type-only edit still backdates the count opinion. Withholding blanks the types *inside* a record instead of dropping it, so the count opinion survives every mechanism that currently spares it.

**Tech Stack:** Julia, Salsa, CSTParser, SymbolServer, TestItemRunner.

Design rationale, and why the obvious simplifications are wrong:
`docs/design/2026-08-01-slice-1-5-signature-record.md`. Read it first.

## Global Constraints

- **Pure consolidation.** Tasks 1–4 must not change a single diagnostic anywhere. The gate is the both-direction sweep (`docs/perf/typesweep.jl`) over all 74 roots of the julia-vscode repo: **identical per-file messages, not merely identical counts.** Any movement in either direction is a finding.
- **Plain data only** in anything reachable from `derived_file_inventory` — no `EXPR`, no `objectid`, no byte offset, no store value. Store values compare by identity and would never backdate.
- **Two projections, not one.** `derived_method_arities(root, path, name)` keeps its current name, signature and return type, now derived. Collapsing it into the full-signature projection means a type-only edit (`f(x::Int)` → `f(x::String)`) stops backdating the count opinion, which it backdates today.
- **Withholding blanks types inside a record; it never drops a record.** Every current mechanism (the `:opaque_definitions` marker, the external-import gate) deliberately spares the count opinion, and the arity index has never withheld anything. Preserve that exactly — including its pre-existing exposure to `eval`-created methods, which is a separate bug and must not be silently fixed here.
- `InventoryItem.signature::Union{Nothing,String}` **stays** for now. Deriving it is a follow-up, so a rendering regression cannot be confused with a matching regression while the gate is running.
- Comments terse; no references to design docs, section numbers or this plan.
- Tests via `run_tests(path; filter)` in the dev-env session (`scripts/environments/development`); never spawn `julia` or `Pkg.test`. Restart the session after any struct change — Revise cannot patch those.

## The record

Sketch — settle exact field names in Task 1 and keep them consistent thereafter:

```julia
@auto_hash_equals struct SigParam
    name::String        # "" for a dispatch-only `::T`
    type::ParamType     # as WRITTEN; see below
    role::Symbol        # :positional | :optional | :keyword | :vararg
end

@auto_hash_equals struct SigTypeVar   # NOT `TypeVar` — collides with Core.TypeVar
    name::String
    upper::ParamType    # unknown when there is no usable upper bound
end

@auto_hash_equals struct MethodSignature
    params::Vector{SigParam}     # positional/optional/vararg, source order
    kwargs::Vector{SigParam}
    kwsplat::Bool
    where_vars::Vector{SigTypeVar}
    shape_unknown::Bool          # macro-wrapped: arity must answer permissively
end
```

`ParamType` records the type **as written** — a dotted name path, a name path with
arguments, or an explicit unknown — not a resolvability verdict. Slice 1 collapsed
every non-bare shape to unknown at record time; that is what makes slice 2 a schema
change instead of a resolver change.

**`where_vars` is a correctness requirement, not metadata.** With a faithful record,
`x::T` records the name path `["T"]`; if the resolver cannot tell that `T` is
method-local it will look `T` up in the defining module and may genuinely find a
type of that name. Slice 1 avoided this by filtering at record time. Upper bounds:
`where T` → unknown; `T<:B` → `B`; `Lo<:T<:Hi` → `Hi`; **`T>:B` → unknown**, because
`B` is a *lower* bound and licenses nothing; `where {T, S<:X}` → both independently.

## File Structure

| File | Responsibility |
|---|---|
| `src/layer_inventory.jl` | `SigParam`/`SigTypeVar`/`MethodSignature`/`ParamType`; extraction for methods (Task 1) and structs (Task 2); the `signature` field. |
| `src/layer_module_tree.jl` | The merged per-root index; the full-signature projection and the derived arity projection (Task 3). |
| `src/layer_file_analysis.jl` | Resolution reads the new record (Task 4). |
| `src/StaticLint/linting/checks.jl` | Consumers cut over; the `length(recs) == length(arities)` guard is deleted (Task 4). |
| `test/test_inventory.jl`, `test/test_module_tree.jl`, `test/test_file_analysis.jl` | Per-layer tests. |

---

### Task 1: The record, and faithful extraction for methods

**Files:** `src/layer_inventory.jl`; test `test/test_inventory.jl`

**Interfaces produced (Task 1, SHIPPED — use these names):** the four types above, the field `InventoryItem.method_sig::Union{Nothing,MethodSignature}`, plus `_method_signature(x::CSTParser.EXPR) -> Union{Nothing,MethodSignature}`, and `_arity_of(sig::MethodSignature) -> MethodArity`.

`arity` and `param_types` stay on `InventoryItem` for now — this task adds `signature` alongside them so the two can be compared. They are removed in Task 4.

- [ ] **Step 1: Write the equivalence test — this is the task's real gate**

Rather than asserting a handful of shapes by hand, assert that `_arity_of(_method_signature(x))` equals `MethodArity(StaticLint.func_nargs(x)...)` **for every callable item in this package's own source**. Walk the tree files, compare per item, and report every mismatch with its source text.

That is the only test that can give confidence the derived arity is a faithful replacement, and it is cheap — the inventory and item positions are already available (see `docs/perf/typebudget.jl` for the walk idiom).

Add hand-written assertions only for shapes the package may not contain: `f(::Int)`, `f(x, ys...)`, `f(x::Vararg{Int,3})`, `f(x::Int=1; k::String="a", kw...)`, `f(x::T, y::Real) where T<:Real`, `f(x::T) where T>:Int`, `f(x::Vector{T}) where T`, an operator definition, and a macro-wrapped definition.

**Correction, confirmed in Task 1 — do not restore the original claim here.** This
plan previously said a macro-wrapped definition must set `shape_unknown` and derive
a permissive arity "matching `func_nargs`'s early return". That is wrong:
`func_nargs`'s permissive early return is gated on `env !== nothing && meta_dict
!== nothing`, and the inventory calls `func_nargs(x)` with neither, so a
macro-wrapped **method** gets *exact* counts today. Honouring the original wording
would make every top-level `@inline`/`@propagate_inbounds` method permissive at
Task 4's cutover and silently delete real diagnostics. `_method_signature` sets
`shape_unknown = false` unconditionally. `struct_nargs`'s macro arm *is* purely
syntactic, so `shape_unknown` is genuinely Task 2's lever — see Task 2.

- [ ] **Step 2: Run it; confirm it fails** (`_method_signature` undefined).

- [ ] **Step 3: Implement**

Mirror `func_nargs`'s traversal decisions exactly rather than reinventing them — it is the specification for role assignment. Reuse the slice-1 helpers where they already do the right thing (`_dotted_name_path`, `is_explicit_vararg_decl`, the quotenode guard that stops value positions being harvested as type names).

Where clauses: read them from `CSTParser.get_sig(x)` **before** `rem_wheres_decls`, which strips them.

- [ ] **Step 4: Confirm green**, including the whole-package equivalence test and the full `test/test_inventory.jl`. Restart the session first.

- [ ] **Step 5: Commit.**

---

### Task 2: Structs

**Files:** `src/layer_inventory.jl`; test `test/test_inventory.jl`

Today the struct site records `MethodArity(struct_nargs(x)...)` and `param_types === nothing`, so struct constructors are invisible to the type check. Give them a faithful signature — fields become parameters, the struct's type parameters become `where_vars` — while keeping the type opinion **withheld** so no diagnostic moves.

`struct_nargs` (`StaticLint/linting/checks.jl:179`) is the specification, and it has three arms the record must reproduce exactly:

1. **Macro-wrapped** (not behind a doc wrapper) → fully permissive `(0, typemax, [], true)`. Set `shape_unknown`.
2. **Inner constructors present** → arity is the *union* of their ranges, and the existing comment notes a single range cannot express a gap (arities 1 and 3 admit 2), erring toward acceptance. Reproduce that union. Recording the inner constructors as distinct signatures would be strictly more precise and is therefore a **diagnostic change** — defer it.
3. **No inner constructors** → the field count, skipping a field's docstring (a bare string child of the body block, which the inventory's own field-name loop also skips).

- [ ] **Step 1: Write the equivalence test.** Same shape as Task 1: over this package's source, `_arity_of` the struct signature must equal `MethodArity(struct_nargs(x)...)` for every struct item. Add hand-written cases for all three arms above, plus a parametric struct (`struct Foo{T} <: Bar; x::T; end` → `where_vars == [T]`), a documented field, and `@kwdef`.
- [ ] **Step 2: Confirm failure.**
- [ ] **Step 3: Implement**, recording field names and types faithfully while leaving the type opinion withheld.
- [ ] **Step 4: Confirm green.**
- [ ] **Step 5: Commit.**

---

### Task 3: The merged index and its two projections

**Files:** `src/layer_module_tree.jl`; test `test/test_module_tree.jl`

**Interfaces produced:**
- `derived_method_signatures_index(rt, root)` — one splice walk, replacing both `derived_method_arities_index` and `derived_method_param_types_index`.
- `derived_method_signatures(rt, root, path, name)` — full records, each carrying `defmod` (the module the method's *text* sits in — for `Base.foo(x::MyType)` written in `M` that is `M`, not `Base`).
- `derived_method_arities(rt, root, path, name)` — **unchanged name, signature and return type**, now derived from the merged records.

- [ ] **Step 1: Write the tests**
  - The arity projection returns exactly what it returns today for a spread of fixtures.
  - **Backdating, both directions and both projections:** a body-only edit leaves both `isequal`; a *type-only* edit (`f(x::Int)` → `f(x::String)`) changes the signature projection but leaves **the arity projection `isequal`** — this is the whole reason there are two projections, and the assertion that would catch a naive merge.
  - Withholding blanks types but not counts: with an `:opaque_definitions` marker present, the arity projection is unchanged and non-empty while every record's types are unknown.
  - `defmod` is `loc`, not the qualifier-resolved path, for a method written in `M.Inner` extending `M.g`.
- [ ] **Step 2: Confirm failure.**
- [ ] **Step 3: Implement.** Port the withholding from `derived_method_param_types_index` — the marker, the external-import gate via `_external_import_targets`, and the `:macro_declared` withhold — converting each from *drop the record* to *blank the record's types*.
- [ ] **Step 4: Confirm green**, plus `test/test_module_tree.jl` entire.
- [ ] **Step 5: Commit.**

---

### Task 4: Cut over the consumers and delete the old fields

**Files:** `src/layer_file_analysis.jl`, `src/StaticLint/linting/checks.jl`, `src/layer_inventory.jl`; tests `test/test_file_analysis.jl`

- [ ] **Step 0 — REQUIRED, found in Task 2's review: keep struct items out of the parameter-type side with an explicit kind gate.**

`derived_method_arities_index` already includes structs, so today a name that is
both a struct and a method reliably hits `length(recs) != length(arities)` in
`_tree_types_match` and declines outright. The moment structs enter the record set,
those lengths match, the check *engages*, and a **sibling method's** record can
drive a flag:

```julia
struct Point; x; y; end          # arity (2,2)
Point(s::String) = Point(0, 0)   # arity (1,1), type ["String"]
Point(1.0)                       # today: declined. Without the gate: FLAGGED.
```

Withholding struct field types does **not** prevent this — the struct's own record
cannot flag, but its mere presence re-arms the check for the whole name. Arm-1 and
arm-2 structs push the other way (`length(r.types) != length(args)` disarms the
name entirely), which is a diagnostic change in the removing direction. Both break
the identical-diagnostics gate. Gate on `item.kind`, and pin it with a test using
the fixture above.

- [ ] **Step 1** — point `_resolve_param_types` and the `tree_param_types` closure at `derived_method_signatures`, resolving `ParamType` and consulting `where_vars` so a parameter typed by a type variable is unknown (bound substitution is a follow-up, not this task).
- [ ] **Step 2** — delete `check_call`'s `length(recs) == length(arities)` guard. It exists only because two indices could disagree about *membership*; one index cannot. Its test must be repointed, not deleted: the shape it guarded (a splat method beside a typed one) must still decline, now because the splat method's record carries unknown types.
- [ ] **Step 3** — remove `arity` and `param_types` from `InventoryItem`, with their back-compat constructors, and delete `derived_method_param_types_index`/`derived_method_param_types`. Keep `MethodArity` itself — it is the derived projection's return type and is imported into StaticLint.
- [ ] **Step 4 — the gate.** Run the both-direction sweep across all 74 roots. **Identical per-file messages required.** Report both directions; any movement is a finding, and a *drop* is as much a finding as an addition. Then re-measure the per-root index recompute on a declaration-changing edit — halving it is the performance case for the whole slice, and it has to be shown, not assumed.
- [ ] **Step 5: Commit.**

---

## Follow-ups this plan deliberately excludes

Each is a coverage widening that produces new diagnostics, so each needs its own sweep in which new diagnostics are *expected* and every one must be validated as a true positive. They are cheap once the record exists:

1. **Enable the struct type opinion.** *Re-costed after Task 2:* not a one-line
   flip. Task 2 records struct field types as **unknown**, not faithfully, so this
   must *add* the extraction — and `_struct_field_name` unwraps the macrocall /
   `const` / default layers while discarding the unwrapped EXPR, so a literal
   one-line change would silently withhold types for `const a::Int`,
   `@atomic a::Int` and `a::Int = 1`. The honest shape is: factor the unwrap into a
   decl-returning helper, record from it, extend the tests, then sweep — and expect
   the sweep to *move* diagnostics rather than confirm they held. It also makes
   field-type edits stop backdating, which they do today.
2. **Substitute `where` upper bounds.** `f(x::T) where T<:Real` currently gives `x` no opinion; the bound is an over-approximation and therefore safe for a rule-out check. Requires substitution at every depth of the type expression (`x::Vector{T}`), which slice 1 never faced.
3. **Record inner constructors as distinct signatures** instead of the union range, removing the "cannot express a gap" imprecision.
4. **Derive the string signature** from the record and drop the field. Needs defaults recorded, and hover output will not be byte-identical to `to_codeobject`, so it needs its own pinned tests.

## Self-Review

**Risks.**
- The naive one-projection merge is the likeliest mistake and is invisible in tests that only check values — Task 3's type-only-edit backdating assertion is the one that catches it.
- Converting withholding from drop-the-record to blank-the-types is the second: get it wrong and the `eval` marker silently deletes arity coverage on metaprogramming-heavy roots, which no diagnostic count will show, because it only removes diagnostics.
- Deleting a field from `InventoryItem` touches every construction site; Tasks 1–2 keep the old fields alongside precisely so the equivalence tests can run before Task 4 removes them.

**Verified while writing this plan** (do not re-derive): `struct_nargs` is at `StaticLint/linting/checks.jl:179` with the three arms above; `func_nargs` returns early and permissively for a macro-wrapped definition that is not behind a doc wrapper; `_render_sig` is `string(to_codeobject(rem_wheres_decls(get_sig(x))))` and has exactly two consumers, `layer_module_tree.jl:1078` and `layer_hover.jl:711`; `CSTParser.get_sig` retains the `where` wrapper, so where clauses must be read before `rem_wheres_decls`.
