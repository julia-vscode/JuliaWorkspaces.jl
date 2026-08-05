# Cross-File Type Parity — Plan 2: Vocabulary Rows, Mixed-Mode Union, Constructors

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the seven items Plan 1 deferred: the remaining parity vocabulary rows (parametric, `Union`, `where`, `Vararg`, optional, keywords, dispatch-only `::T`), the mixed-mode union that replaces the `tree_extended` decline, the EXPR path's cross-file ancestry hop, `FunctionHasNoMethods` on definite emptiness, constructor-call argument typing, datatype callees with full inner-constructor records, and the property-test record arm — ending with the corpus sweep.

**Architecture:** Everything builds on Plan 1's landed machinery (branch `sp/cross-file-type-parity` at `5227cc8`): plain-data signature records (`src/layer_signature_records.jl`), the per-root signature index (`derived_method_signatures_index`, `src/layer_module_tree.jl:930`), the shared alignment engine (`SigDescriptor`/`match_descriptor`, `src/StaticLint/methodmatching.jl:296`), leaf resolution (`_tree_type_resolver`, `src/layer_file_analysis.jl:732`), and the tree gate in `check_call` (`src/StaticLint/linting/checks.jl:452`). The binding design is `docs/design/2026-08-04-cross-file-type-parity-spec.md`; its goals doc's shape table is the acceptance surface. Two structural decisions are already made (Sebastian, 2026-08-05): the tree closures bundle into a `TreeContext` struct (Task 1), and inner constructors get full records carried as a `ctor_sigs::Vector{MethodSignature}` field on the datatype's own inventory item — no per-constructor rows (Task 12).

**Tech Stack:** Julia; Salsa-derived incremental layers; CSTParser syntax trees; vendored SymbolServer store; TestItemRunner via the julia-mcp dev session.

## Global Constraints

These bind every task. They are copied from the Plan 1 ledger (`.superpowers/sdd/2026-08-04-cross-file-type-parity-1-records-and-name-shapes/global-constraints.md`) and the spec; the ledger file has the full wording.

- **Never spawn `julia` or `Pkg.test` from the shell.** Run code and tests only through julia-mcp: `mcp__julia__julia_eval` with `env_path="/home/pfitzseb/git/julia-vscode/scripts/environments/development"`. A `run_tests` helper is defined in `Main`; if a restart lost it, re-define it verbatim from the ledger file. Usage: `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity", ti.name))`. Revise picks up ordinary edits — restart (`mcp__julia__julia_restart`, same env_path) ONLY after changing a struct definition, then re-define `run_tests`. Pass `timeout=600` (seconds) for full-file runs.
- **`@testitem` bodies run at module scope**: explicit `using JuliaWorkspaces: ...` imports; `return` does not skip a body (gate with `if/else`); assigning an outer name inside a `for` needs a function wrapper.
- **Inventory values are a firewall**: plain data only — no EXPR, no positions, no store values, no URIs. New record structs use `@auto_hash_equals`.
- **Unknown never flags.** Only a definite `false` from `_has_type_intersection` rules a method out; `nothing` and `CoreTypes.Any` leave the candidate alive.
- **Per-name Salsa reads go through projection nodes over one per-root node.**
- **Observed red phases**: every parity fixture is seen failing — or seen not reaching the comparison, via `MatchRecorder` — before the change that makes it pass. A fixture that passes on arrival gets a recorder assertion proving non-vacuity.
- **Decision and message must use the same operands**: any change to argument typing must flow through code shared by `check_call` and `describe_call_mismatch` (both use `call_arg_types` + `tree_arg_operands`), never through a decision-only branch.
- **Code comments**: terse, present-tense, constraints the code can't show; never reference specs/plans/tasks. **Commit messages** describe the change, no test counts, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Whole-closure mode is not regressed but per-file is the asserted surface.** Whole-closure has no tree closures; every new capability must degrade to today's behavior when the `TreeContext` field is `nothing`.
- Baselines before this plan (from the Plan 1 close-out): `test/staticlint` 784 pass / 5 fail / 1 error, all pre-existing; `test/test_file_analysis.jl` 312 pass + 3 broken of 315. Full-suite runs additionally show 132 known errors — testitem-import harness artifacts, all `UndefVarError`, 0 failures. Compare against these baselines, not against zero.

## File Structure

No new files. Every change lands in an existing unit:

| File | Role in this plan |
|---|---|
| `src/StaticLint/linting/checks.jl` | `TreeContext` definition; `check_all`/`check_call` rewiring (Tasks 1, 8–10, 12) |
| `src/StaticLint/treetypes.jl` | `ResolvedUnion` operand (Task 3); `tree_arg_operands` constructor-call route (Task 11) |
| `src/StaticLint/methodmatching.jl` | resolver threading through the EXPR lowering (Task 7); `arg_type` constructor-call branch (Task 11) |
| `src/StaticLint/subtypes.jl` | resolver-aware `_issubtype`/`_super` hop (Task 7); `ResolvedUnion` comparison methods (Task 3) |
| `src/StaticLint/signature_reader.jl` | `_erase_slot_types` for constructor records (Task 12) |
| `src/layer_inventory.jl` | `InventoryItem.ctor_sigs`; inner-constructor reading; macro-wrap guard (Task 12) |
| `src/layer_module_tree.jl` | signature-index constructor rules (Task 12) |
| `src/layer_file_analysis.jl` | `TreeContext` construction; `reaches_outside` + `ext_records` closures (Tasks 1, 8, 9) |
| `test/test_file_analysis.jl` | parity rows, all placements (most tasks) |
| `test/staticlint/test_staticlint.jl` | engine-level placement (d) rows; property-test record arm (Tasks 2–6, 13) |
| `test/test_inventory.jl` | constructor-record inventory tests (Task 12) |
| `test/test_module_tree.jl` | index + backdating tests for constructor records (Task 12) |

Fixture conventions (reuse, do not reinvent): `test/test_file_analysis.jl` has `@testsnippet FileAnalysisWS` providing `ws_with(Dict{URI,String})`, `ROOT`/`A`/`B` URIs, and `SL`; the placement pattern is `test/test_file_analysis.jl:2429–2735` (bare-identifier and qualified rows). `test/staticlint/` uses `setup=[shared_static_lint]` with `parse_and_pass`. The flagged-diagnostic filter used everywhere:

```julia
flagged = filter(d -> occursin("method call error", d.message) ||
                      occursin("No method matching", d.message), fa.diagnostics)
```

---

### Task 1: Bundle the tree closures into `TreeContext`

Pure refactor; no behavior change; the whole existing suite is the test.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`check_all` at :124, `check_call` at :452)
- Modify: `src/layer_file_analysis.jl:910–957` (closure construction + `check_all` call)

**Interfaces:**
- Produces: `StaticLint.TreeContext` — kwdef struct, all fields `Union{Nothing,Function}` defaulting to `nothing`: `visible` (`(name::String, x::EXPR) -> Bool`), `extended` (`(func_ref, x) -> Bool`), `arities` (`(name, x) -> Vector{MethodArity}`), `in_scope` (`x -> Union{Nothing,Vector}`), `signatures` (`(name, x) -> NameMethods`), `resolve` (`(TypeRef, defined_in::Vector{String}) -> operand`), `callsite_type` (`(TypeExpr, x) -> operand`). Tasks 8/9 add fields `reaches_outside` and `ext_records`.
- Produces: `check_all(x, opts, env, meta_dict, tree::TreeContext=TreeContext())` and the same trailing parameter on `check_call`. Every later task consumes `tree.<field>` instead of a positional.

- [ ] **Step 1: Define the struct and rewrite the signatures**

In `checks.jl`, above `check_all`:

```julia
"""
    TreeContext

Per-file mode's tree-side capabilities, bundled. Every field is `nothing` in
whole-closure mode; a check that needs one degrades to its pre-tree behavior
when it is absent.
"""
Base.@kwdef struct TreeContext
    visible::Union{Nothing,Function} = nothing
    extended::Union{Nothing,Function} = nothing
    arities::Union{Nothing,Function} = nothing
    in_scope::Union{Nothing,Function} = nothing
    signatures::Union{Nothing,Function} = nothing
    resolve::Union{Nothing,Function} = nothing
    callsite_type::Union{Nothing,Function} = nothing
end
```

Replace the seven trailing positionals of `check_all` and `check_call` with `tree::TreeContext=TreeContext()`; inside both bodies replace `tree_visible` → `tree.visible`, `tree_extended` → `tree.extended`, `tree_arities` → `tree.arities`, `tree_in_scope` → `tree.in_scope`, `tree_signatures` → `tree.signatures`, `tree_resolve` → `tree.resolve`, `tree_callsite_type` → `tree.callsite_type` (the recursion at `checks.jl:147` passes `tree` through). `sig_match_any` keeps its `tree_in_scope` parameter — pass `tree.in_scope` at the call site (`checks.jl:577`). `describe_call_mismatch` keeps its kwargs; untouched.

- [ ] **Step 2: Rewrite the per-file caller**

In `layer_file_analysis.jl:955`, replace the positional tail with:

```julia
    StaticLint.check_all(cst, _lint_options_from_config(lint_config), env, meta_dict,
        StaticLint.TreeContext(;
            visible = tree_visible, extended = tree_extended, arities = tree_arities,
            in_scope = tree_in_scope, signatures = tree_signatures,
            resolve = tree_signature_resolver, callsite_type = tree_callsite_type))
```

The local closure names stay as they are. `layer_static_lint.jl:159` and `test/staticlint/test_staticlint.jl:2316` call the 4-arg form and need no change.

- [ ] **Step 3: Run the affected suites, expecting the existing baselines exactly**

Run: `run_tests("test/test_file_analysis.jl")` and `run_tests("test/staticlint")` (`timeout=600`).
Expected: identical pass/fail/broken counts to the pre-task baseline (file-analysis 312+3 broken; staticlint per its baseline). Any delta means the refactor changed behavior — fix before proceeding.

- [ ] **Step 4: Commit**

```bash
git add src/StaticLint/linting/checks.jl src/layer_file_analysis.jl
git commit -m "refactor(staticlint): bundle the tree closures into a TreeContext"
```

---

### Task 2: Parity rows — parametric head, inner `where`, dispatch-only `::T`

Three shape rows whose reader lowering already exists (`lower_type_expr` strips `where`/curly to the head; `_slot_type` reads a nameless `::T` declaration). The deliverable is the fixtures proving the verdicts at placements (a) closure, (b) same-file, (c) sibling-file, (d) store, plus the one-file-root variant — and fixing whatever the red phase exposes. Placement (e) for all rows arrives in Task 8.

**Files:**
- Test: `test/test_file_analysis.jl` (append after the qualified rows, :2735)
- Test: `test/staticlint/test_staticlint.jl` (placement (d) engine-level rows)
- Modify: only if a red phase exposes a defect (most likely `signature_reader.jl` or `treetypes.jl`)

**Interfaces:**
- Consumes: `ws_with`, `ROOT`/`A`/`B`, `SL.MatchRecorder`, `SL._match_recorder` (`methodmatching.jl:324–330`), `JuliaWorkspaces.derived_file_analysis`.
- Produces: nothing structural; later tasks assume these rows exist and stay green.

- [ ] **Step 1: Write the sibling-file (c) fixtures with recorder assertions**

```julia
@testitem "parity/parametric: head-only comparison, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Vector{Int}) = 1\n",
        B => """
        good(v::Vector{String}) = target(v)   # heads equal; type args are a non-goal
        bad(w::Other) = target(w)
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("target(::Other)", only(flagged).message)
    @test rec.comparisons >= 2 && rec.rule_outs == 1
end

@testitem "parity/inner-where: `Vector{T} where T` annotation is its head" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Vector{T} where T) = 1\n",
        B => "good(v::Vector{Int}) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/dispatch-only: a nameless `::T` slot still types" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\ntarget(::MyAbs, y::Int) = 1\n",
        B => "good(v::Own) = target(v, 1)\nbad(w::Other) = target(w, 1)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end
```

- [ ] **Step 2: Run and record the red/green state**

Run: `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity/", ti.name))`.
These rows may pass on arrival (the reader already lowers all three shapes). If a fixture passes, the recorder assertion in the parametric row is the non-vacuity proof; extend the same recorder pattern to any fixture that never fails. If a fixture fails, the defect is real — diagnose in `lower_type_expr`/`_slot_type`/`resolve_record_type` before touching the fixture.

- [ ] **Step 3: Add the same-file (b), closure (a), and one-file-root variants**

Clone the sibling fixture's source into single-file layouts exactly as `test/test_file_analysis.jl:2460–2544` does for the bare-identifier row: (a) definitions inside a `function caller(...)` body in one file; (b) module-level definitions and calls in one file under `ROOT`; one-file-root = same source via `ws_with(Dict(B => src))` + `derived_file_analysis(jw.runtime, B, B)`. One testitem per placement, three shapes each, `@test length(flagged) == 1`. For the closure placement, types stay in the same file (the cross-file hop is Task 7).

- [ ] **Step 4: Add placement (d) — store callee — at the engine level**

Real Base names with a fully-resolvable method set are scarce per shape, and the spec sanctions a synthetic store for placement (d). Pin the `MethodStore` lowering directly (`test/staticlint/test_staticlint.jl`), using the constructor shape from `test/test_symbolserver.jl:139`:

```julia
@testitem "parity/parametric placement d: MethodStore parametric head rules out" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint
    SS = JuliaWorkspaces.SymbolServer
    cst, meta_dict, jw = parse_and_pass("struct Other end\nf(w::Other) = w\n")
    syms = get_env(jw).symbols
    vec = syms[:Base][:Vector]          # DataTypeStore behind the constructor
    vecdt = SL.get_eventual_datatype(vec, get_env(jw))
    other = SL.bindingof(cst.args[1], meta_dict)
    m = SS.MethodStore(:target, :Fake, "fake.jl", Int32(1),
        Pair{Any,Any}[:x => SS.FakeTypeName(Vector{Int})], Symbol[], nothing)
    # good: a Vector argument matches the Vector{Int} slot through the head
    @test SL.match_method(Any[vecdt], Any[], m, syms, meta_dict) === true
    # bad: a workspace struct with supertype Any is definitely ruled out
    @test SL.match_method(Any[other], Any[], m, syms, meta_dict) === false
end
```

Mirror for the dispatch-only row (a `MethodStore` whose slot pair is `Symbol("") => FakeTypeName(...)`— check how the store spells nameless slots by inspecting one real method, e.g. `syms[:Base][:iseven]`, before writing the pair). The inner-`where` shape has no distinct store spelling (the store pre-resolves it) — no (d) row needed; note that in a comment.

- [ ] **Step 5: Run all new testitems, verify green, run the two suite files for no regressions**

Run: `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity/", ti.name))`, then `run_tests("test/staticlint/test_staticlint.jl"; filter=ti -> occursin("placement d", ti.name))`, then both full files.

- [ ] **Step 6: Commit**

```bash
git add test/test_file_analysis.jl test/staticlint/test_staticlint.jl
git commit -m "test(staticlint): parametric, inner-where and dispatch-only parity rows"
```

(If Step 2 exposed a source defect, commit its fix separately first with a `fix(staticlint):` message describing the defect.)

---

### Task 3: Parity row — `Union{…}`, with workspace members

The known red: `resolve_record_type` (`treetypes.jl:32–40`) drops any union containing a tree member to `CoreTypes.Any` ("a mixed union carries no opinion") because `FakeUnion` comparison only understands store operands. This task gives unions their operand.

**Files:**
- Modify: `src/StaticLint/treetypes.jl` (new `ResolvedUnion`; `resolve_record_type` union branch)
- Modify: `src/StaticLint/subtypes.jl` (comparison methods)
- Test: `test/test_file_analysis.jl`, `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Produces: `ResolvedUnion(members::Vector{Any})` in `StaticLint` — a comparison operand whose members are already-resolved operands (store values, `TreeDataType`s, or a mix).
- Consumes: `_has_type_intersection`/`_issubtype` tri-state contract (`subtypes.jl:13–34`).

- [ ] **Step 1: Write the failing cross-file fixture**

```julia
@testitem "parity/union: workspace members rule out member-wise, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct P end\nstruct Q end\nstruct Other end\ntarget(x::Union{P,Q}) = 1\n",
        B => "good(v::P) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity/union", ti.name))`.
Expected: FAIL — `flagged` is empty, because the mixed union resolved to `Any` and `bad` was never ruled out.

- [ ] **Step 3: Implement `ResolvedUnion`**

In `treetypes.jl`, next to `TreeDataType`:

```julia
"""
    ResolvedUnion

A `Union{…}` annotation with every member already resolved to a comparison
operand (store value or `TreeDataType`). Member-wise tri-state: intersecting
any member is `true`; ruled out only when EVERY member is definitely ruled out.
"""
struct ResolvedUnion
    members::Vector{Any}
end
```

In `resolve_record_type`, replace the store-only guard (lines 36–40) with:

```julia
        members = [resolve_record_type(m, sig, defined_in, resolver, fuel - 1) for m in t.members]
        any(m -> m === CoreTypes.Any || m === nothing, members) && return CoreTypes.Any
        all(m -> m isa SymbolServer.DataTypeStore || m isa SymbolServer.FakeTypeName, members) &&
            return _fake_union(members)      # store-only unions keep the store shape
        return ResolvedUnion(members)
```

In `treetypes.jl` (included after `subtypes.jl`, same placement as `TreeDataType`'s `_type_compare` methods), add the member-wise legs (keep the tri-state discipline — an indeterminate member blocks a `false`, never a `true` from another member):

```julia
function _has_type_intersection(a, b::ResolvedUnion, store, meta_dict)
    saw_unknown = false
    for m in b.members
        r = _has_type_intersection(a, m, store, meta_dict)
        r === true && return true
        r === nothing && (saw_unknown = true)
    end
    return saw_unknown ? nothing : false
end
_has_type_intersection(a::ResolvedUnion, b, store, meta_dict) =
    _has_type_intersection(b, a, store, meta_dict)
```

Guard the double-union case (`a isa ResolvedUnion && b isa ResolvedUnion` dispatch ambiguity) with an explicit method that iterates one side. Check the generic `_has_type_intersection(a, b, ...)` at `subtypes.jl:24` still applies for non-union operands — these are more-specific methods, no restructure needed. `ResolvedUnion` needs no `_super`/`_type_compare` methods; the fallback `_super(_,_,_) = nothing` keeps a union out of the nominal walk, which the member-wise methods make unreachable anyway. (Task 7 later adds a trailing `resolver` parameter to `_has_type_intersection`; when it lands, these methods gain and forward the same parameter.)

- [ ] **Step 4: Run to verify the fixture passes; add the remaining placements**

Placements (a)/(b)/one-file-root as in Task 2 Step 3 (same source, single-file layouts — these exercise the EXPR path's `_is_union_curly`/`_fake_union` route for local members, which already works; the fixture pins it). Placement (d): store-side `FakeUnion` handling is pre-existing — pin at engine level with a `MethodStore` whose slot is `FakeUnion` (construct via `SS.FakeUnion(FakeTypeName(Int), FakeTypeName(String))`), good arm `Int`, bad arm the parsed `Other` binding.

- [ ] **Step 5: Whitebox mixed-union test**

```julia
@testitem "resolve_record_type: a mixed union keeps member opinions" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, TypeUnionExpr, MethodSignature, SigSlot, TypeExpr
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\nend\n",
        A => "struct P end\nstruct Other end\n",
    ))
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, ROOT)
    sig = MethodSignature([SigSlot(TypeUnionExpr(TypeExpr[TypeRef(["P"]), TypeRef(["Int"])]), false)],
        nothing, Dict{String,TypeExpr}(), Symbol[], false)
    u = SL.resolve_record_type(sig.slots[1].type, sig, ["MainPkg"], resolve)
    @test u isa SL.ResolvedUnion && length(u.members) == 2
    other = resolve(TypeRef(["Other"]), ["MainPkg"])
    @test SL._has_type_intersection(other, u, nothing, nothing) === false
    p = resolve(TypeRef(["P"]), ["MainPkg"])
    @test SL._has_type_intersection(p, u, nothing, nothing) === true
end
```

- [ ] **Step 6: Run both suite files for no regressions, commit**

```bash
git add src/StaticLint/treetypes.jl src/StaticLint/subtypes.jl test/test_file_analysis.jl test/staticlint/test_staticlint.jl
git commit -m "feat(staticlint): member-wise comparison for unions with workspace members"
```

---

### Task 4: Parity row — `where`-bound type variable

The record side resolves `TypeVarRef` through the signature's own `typevars` (`resolve_record_type`, `treetypes.jl:29–31`); the EXPR side resolves a typevar's upper bound through `where_upper_bound_expr` (`methodmatching.jl:21–34`). Both exist; the row proves the verdicts and their agreement.

**Files:**
- Test: `test/test_file_analysis.jl`, `test/staticlint/test_staticlint.jl`

**Interfaces:** consumes Task 2's fixture pattern; produces nothing structural.

- [ ] **Step 1: Write the placement fixtures**

Shape source, materialized at (a)/(b)/(c)/one-file-root exactly as before:

```julia
A => "struct Other end\ntarget(x::T) where {T <: Real} = 1\n",
B => "good(v::Float64) = target(v)\nbad(w::Other) = target(w)\n",
```

Also the licensing-nothing arms, one testitem, sibling placement only (they are reader facts, not placement facts):

```julia
# a lower bound licenses nothing: no flag either way
A => "struct Other end\ntarget(x::T) where {T >: Int} = 1\n",
B => "callit(w::Other) = target(w)\n",   # expect flagged == 0
# an unbounded typevar licenses nothing
A => "struct Other end\ntarget(x::T) where T = 1\n",
B => "callit(w::Other) = target(w)\n",   # expect flagged == 0
```

Placement (d): store methods carry `FakeTypeVar` with `.ub` — `_super(::FakeTypeVar)` handles it (`subtypes.jl:75`). Engine-level pin: `MethodStore` slot `:x => SS.FakeTypeVar(:T, FakeTypeName(Union{}), FakeTypeName(Real))` (check `FakeTypeVar`'s constructor arity in `src/SymbolServer/faketypes.jl` first — it may be `(name, lb, ub)` or keyword), good arm `Float64` store type, bad arm parsed `Other` binding.

- [ ] **Step 2: Run, observe red or prove non-vacuity via recorder, fix any exposed defect**

The most likely red: placement (c)'s `good` arm needs `TypeVarRef → upper bound → store type` chained through `resolve_record_type`'s `fuel` recursion — if it fails, instrument `resolve_record_type` with the fixture's record before touching fixtures.

- [ ] **Step 3: Run both files, commit**

```bash
git add test/test_file_analysis.jl test/staticlint/test_staticlint.jl
git commit -m "test(staticlint): where-bound typevar parity row"
```

---

### Task 5: Parity rows — `Vararg` spellings, optional/defaulted completion

Alignment is already unified (`_align_args`, fixed in Plan 1's H1 round; the cross-file/closure fixtures live at `test/test_file_analysis.jl:2662–2687`). This task completes the acceptance surface: every `Vararg` spelling as its own arm, and the missing placements for optional/defaulted.

**Files:**
- Test: `test/test_file_analysis.jl`

**Interfaces:** consumes the existing `callflags` helper pattern (`test_file_analysis.jl:2665`).

- [ ] **Step 1: Write the spellings testitem**

One testitem, sibling placement, one good/bad pair per spelling — `x...`, `::Vararg`, `::Vararg{T}`, `::Vararg{T,N}`, `::Base.Vararg{T}`:

```julia
@testitem "parity/vararg: every spelling aligns and rules out identically" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # dotted: typed pad rules out a definite mismatch
    @test isempty(callflags("f(a::Int, xs::Float64...) = 1", "c() = f(1, 2.0, 3.0)"))
    @test length(callflags("struct O end\nf(a::Int, xs::Float64...) = 1", "c(o::O) = f(1, o)")) == 1
    # anonymous ::Vararg: untyped pad accepts anything, count still open-ended
    @test isempty(callflags("f(a::Int, xs::Vararg) = 1", "c() = f(1, \"s\", 's')"))
    # ::Vararg{T}
    @test length(callflags("struct O end\nf(a::Int, xs::Vararg{Float64}) = 1", "c(o::O) = f(1, o)")) == 1
    # ::Vararg{T,N}: exact count, typed pad
    @test isempty(callflags("f(a::Int, xs::Vararg{Float64,2}) = 1", "c() = f(1, 1.0, 2.0)"))
    @test length(callflags("f(a::Int, xs::Vararg{Float64,2}) = 1", "c() = f(1, 1.0)")) == 1   # count, via records
    # ::Base.Vararg{T}
    @test length(callflags("struct O end\nf(a::Int, xs::Base.Vararg{Float64}) = 1", "c(o::O) = f(1, o)")) == 1
end
```

- [ ] **Step 2: Optional/defaulted — add the same-file and one-file-root placements**

The cross-file and closure placements exist (:2675–2682). Add one testitem covering: same-file module-level (`f9` source in one file), one-file root, and a defaulted slot whose ANNOTATION mismatches definitively when filled (`f(a::Int, b::String="x")` called `f(1, 2.0)` → 1 flag; called `f(1)` → 0 flags).

- [ ] **Step 3: Run red/green, fix fallout, run both files, commit**

Watch one specific trap: the `::Vararg{T,N}` COUNT mismatch arrives through the records' `_align_args` returning `nothing` → all candidates `false` → `IncorrectCallArgs`; confirm the message channel renders it (`describe_call_mismatch` with `cand_arities`) rather than erroring.

```bash
git add test/test_file_analysis.jl
git commit -m "test(staticlint): vararg-spelling and optional-slot parity rows"
```

---

### Task 6: Parity row — keywords, presence only

Pins the engine's keyword gate (`_match_descriptor` line 363: a call passing keywords is ruled out only by a candidate with no declared keywords and no `; kwargs...`) identically across placements. Keyword NAMES are recorded but deliberately not matched (goals non-goal: presence and splat only) — the row pins that too, so nobody "improves" one path later.

**Files:**
- Test: `test/test_file_analysis.jl`

- [ ] **Step 1: Write the testitem**

```julia
@testitem "parity/keywords: presence-only gating, all placements agree" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # a keyword passed to a method that declares none: every candidate ruled out
    @test length(callflags("struct T end\nf(x::T) = 1", "c(v::T) = f(v; k=1)")) == 1
    # declared keyword: accepted
    @test isempty(callflags("struct T end\nf(x::T; k=1) = 1", "c(v::T) = f(v; k=2)"))
    # WRONG keyword name: presence-only means NOT flagged — pinned on purpose
    @test isempty(callflags("struct T end\nf(x::T; k=1) = 1", "c(v::T) = f(v; other=2)"))
    # kwsplat accepts anything (already pinned at :2565; re-pin beside its row)
    @test isempty(callflags("struct T end\nf(x::T; kws...) = 1", "c(v::T) = f(v; whatever=1)"))
end
```

Then the same four arms as a closure placement (one file, definitions inside `function caller() ... end`) and a one-file-root variant of the first arm.

- [ ] **Step 2: Run red/green; run the file; commit**

```bash
git add test/test_file_analysis.jl
git commit -m "test(staticlint): keyword presence parity row"
```

---

### Task 7: The EXPR path's cross-file ancestry hop

Today a closure whose annotation (or whose argument's declared type's supertype) lives in a sibling file is permanently permissive: the EXPR lowering types it `Any`/`nothing`, and `_super(::Binding)` dead-ends on a `TreeRef` (`subtypes.jl:97` → fallback `nothing`). The fix threads the leaf resolver (already in `TreeContext.resolve`) down the EXPR comparison path so a `TreeRef` becomes a `TreeDataType` and the walk continues.

**Files:**
- Modify: `src/StaticLint/subtypes.jl` (`_issubtype`, `_has_type_intersection`, `_super(::Binding)` — trailing `resolver=nothing`)
- Modify: `src/StaticLint/methodmatching.jl` (`match_descriptor`/`_match_descriptor`, `match_method(::EXPR)`, `_resolve_type_expr`, `method_arg_types`, `arg_type` method-side — thread `resolver`)
- Modify: `src/StaticLint/linting/checks.jl` (`sig_match_any` passes `tree.resolve`-derived resolver)
- Modify: `src/StaticLint/linting/checks.jl` `describe_call_mismatch` EXPR arm (same threading, so message and decision agree)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces: `resolver` convention — a function `(t::TypeRef, defined_in::Vector{String}) -> operand`, `nothing` in whole-closure mode. `_treeref_operand(r::TreeRef, resolver)` helper in `treetypes.jl`: `r.kind in _TREE_DATATYPE_KINDS ? resolver(TypeRef([r.name]), r.origin_module) : nothing`.
- Consumes: `TreeContext.resolve` (Task 1), `TreeDataType` (self-carrying continuation), `_TREE_DATATYPE_KINDS`.

- [ ] **Step 1: Write the failing fixture — closure callee, sibling types**

The existing closure row (:2460) keeps its types same-file by design; this fixture is the one its comment defers:

```julia
@testitem "parity: closure callee resolves sibling-file types through the records" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\n",
        B => """
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
```

And the mid-walk variant — the argument's type is same-file but its declared supertype is sibling:

```julia
    A => "abstract type MyAbs end\nstruct Other end\n",
    B => """
    struct Own <: MyAbs end
    function caller(v::Own, w::Other)
        target(x::MyAbs) = 1
        target(v)          # Own's supertype EXPR refs a sibling TreeRef
        target(w)
    end
    """,
    # expect: 1 flag
```

- [ ] **Step 2: Run to verify both fail** (0 flags — everything indeterminate).

- [ ] **Step 3: Thread the resolver**

The one resolver threaded everywhere is `tree.resolve` — the raw two-argument leaf resolver `(t::TypeRef, defined_in::Vector{String}) -> operand`. It suffices because every cross-file hop starts from a `TreeRef`, and a `TreeRef` carries its own resolution module (`origin_module`); nothing needs the call-site path. All new parameters default to `nothing` so whole-closure callers compile unchanged.

1. `treetypes.jl` — the one conversion helper, so a `TreeRef` can never be resolved two ways:
   ```julia
   # A TreeRef as a comparison operand: its datatype, resolved in the module
   # that binds it. `nothing` for non-datatype kinds and failed resolution.
   _treeref_operand(r::TreeRef, resolver) =
       r.kind in _TREE_DATATYPE_KINDS ? resolver(TypeRef([r.name]), r.origin_module) : nothing
   ```
2. `subtypes.jl`: `_issubtype(a, b, store, meta_dict, depth=0, resolver=nothing)`; `_has_type_intersection(a, b, store, meta_dict, resolver=nothing)`; inside `_issubtype`, after `sup_a = _super(a, store, meta_dict)`:
   ```julia
   if sup_a isa TreeRef && resolver !== nothing
       sup_a = _treeref_operand(sup_a, resolver)
       sup_a === nothing && return nothing
   end
   ```
   This catches the mid-walk case: `_super(b::Binding, ...)` already returns `refof(sup)`, which IS the sibling `TreeRef` — `_super` itself does not change.
3. `methodmatching.jl`: `match_descriptor(args, kws, d, store, meta_dict, resolver=nothing)` (and `_match_descriptor`), passing `resolver` into the `_has_type_intersection` loop. `match_method(::EXPR)` gains `resolver=nothing` and forwards it to `match_descriptor`, `method_arg_types`, and `_resolve_type_expr`. `_resolve_type_expr(t, store, meta_dict, resolver=nothing)` gains a `TreeRef` branch after the existing `Binding` legs:
   ```julia
   elseif r isa TreeRef && resolver !== nothing
       dt = _treeref_operand(r, resolver)
       return dt === nothing ? CoreTypes.Any : dt
   ```
   `method_arg_types(sig, meta_dict, store, resolver=nothing)` forwards to `arg_type(arg, true, meta_dict, store, resolver)`. In `arg_type`'s METHOD side, after the existing binding path fails to produce a type, resolve a declaration's annotation through its own ref (unwrap `where`/curly to the head first, as `_names_workspace_datatype` does):
   ```julia
   if resolver !== nothing && isdeclaration(arg) && length(arg.args) >= 2
       t = arg.args[2]
       # ... unwrap iswhere/iscurly to the head ...
       r = is_getfield_w_quotenode(t) ? refof_maybe_getfield(t, meta_dict) :
           (isidentifier(t) ? refof(t, meta_dict) : nothing)
       if r isa TreeRef
           dt = _treeref_operand(r, resolver)
           dt === nothing || return dt
       end
   end
   ```
4. `checks.jl`: `sig_match_any(func::EXPR, ...)` and `sig_match_any(func_ref::Binding, ...)` gain the trailing `resolver=nothing` and forward to `match_method`; `check_call`'s call at :577 passes `tree.resolve`.
5. `describe_call_mismatch`'s EXPR arm builds candidate descriptions through the same `match_method`/`arg_type` calls — add a `tree_resolve` kwarg beside its existing `tree_callsite_type` kwarg, wire it from `layer_file_analysis.jl:612` (`tree_resolve=tree_signature_resolver`), and pass it down the same way, so message and decision use identical operands.

- [ ] **Step 4: Run to verify both fixtures pass; whole-closure unchanged**

Run the parity filter, then `run_tests("test/staticlint")` in full — the whole-closure suite must be byte-identical to baseline (its resolver is `nothing` everywhere).

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/subtypes.jl src/StaticLint/methodmatching.jl src/StaticLint/treetypes.jl src/StaticLint/linting/checks.jl src/layer_file_analysis.jl test/test_file_analysis.jl
git commit -m "feat(staticlint): resolve sibling-file types on the EXPR comparison path"
```

---

### Task 8: Mixed-mode union, site 1 — store-backed binding callee

Today (`checks.jl:493–527`) a callee bound to a store function (`import Base: length` then `length(::D) = …`) gets arity checks against records∪store but the TYPE phase declines whenever `store !== nothing`, and `tree_signatures` re-wraps any outside-reaching name as `has_unknown_shapes` (`layer_file_analysis.jl:938–948`). This task makes the type phase run over the union — workspace records ∪ in-scope store methods — and moves the outside-reach question into the gate where it can be weighed against store backing.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (tree gate restructure; `TreeContext` gains `reaches_outside`)
- Modify: `src/layer_file_analysis.jl` (`tree_signatures` stops re-wrapping; new `reaches_outside` closure)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces: `TreeContext.reaches_outside::Union{Nothing,Function} = nothing` — `(name, x) -> Bool`, wrapping `_name_reaches_from_outside(rt, root, p, name)` with the call-site path `p`.
- Produces: the gate's union verdict, which Tasks 9/10/12 extend. Completeness rule: `complete = !nm.has_unknown_shapes && (store !== nothing || !outside)`.
- Consumes: `iterate_over_ss_methods`, `match_method(args, kws, m::MethodStore, store, meta_dict)`, `retrieve_toplevel_scope`.

- [ ] **Step 1: Write the failing placement (e) fixture**

```julia
@testitem "parity: store callee with a workspace overload — union of both method sets" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "import Base: iseven\nstruct D end\niseven(d::D) = true\nstruct Other end\n",
        B => """
        import Base: iseven
        good1(d::D) = iseven(d)        # served by the workspace overload
        good2(x::Int) = iseven(x)      # served by the store's own methods
        bad(w::Other) = iseven(w)      # served by neither: flag
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end
```

- [ ] **Step 2: Run to verify it fails** (0 flags — the store-backed callee's type phase declines today).

- [ ] **Step 3: Restructure the gate's tree arm**

Add `reaches_outside` to `TreeContext`. In `layer_file_analysis.jl`: `tree_signatures` returns `derived_method_signatures(rt, root, p, name)` raw (delete the `_name_reaches_from_outside` re-wrap, :941–946); add

```julia
    tree_reaches_outside = (name, x) -> begin
        p = vcat(path, _in_file_module_names(x, meta_dict))
        _name_reaches_from_outside(rt, root, p, name)
    end
```

and pass it as `reaches_outside`. In `check_call`, replace the body of the `if !isempty(arities) || store !== nothing` block (:496–538) with count phase then union type phase:

```julia
    cc = call_nargs(x)
    count_ok = any(a -> compare_f_call(a, cc), arities)
    if !count_ok && store !== nothing
        tls = retrieve_toplevel_scope(x, meta_dict)
        count_ok = tls isa Scope && iterate_over_ss_methods(store, tls, env,
            m -> compare_f_call(func_nargs(m), cc);
            in_scope = tree.in_scope === nothing ? nothing : tree.in_scope(x))
    end
    if !count_ok
        seterror!(x, IncorrectCallArgs, meta_dict)
    elseif tree.signatures !== nothing && tree.resolve !== nothing && !_is_datatype_callee(func_ref)
        nm = tree.signatures(n, x)
        outside = tree.reaches_outside !== nothing && tree.reaches_outside(n, x)
        complete = !nm.has_unknown_shapes && (store !== nothing || !outside)
        if complete && (!isempty(nm.signatures) || store !== nothing)
            args, kws = call_arg_types(x, false, meta_dict, getsymbols(env))
            tree.callsite_type === nothing ||
                (args = tree_arg_operands(x, args, meta_dict, tree.callsite_type))
            match = any(ls -> match_method(args, kws, ls, tree.resolve, getsymbols(env), meta_dict),
                        nm.signatures)
            if !match && store !== nothing
                tls = retrieve_toplevel_scope(x, meta_dict)
                match = !(tls isa Scope) || iterate_over_ss_methods(store, tls, env,
                    m -> match_method(args, kws, m, getsymbols(env), meta_dict);
                    in_scope = tree.in_scope === nothing ? nothing : tree.in_scope(x))
            end
            match || seterror!(x, IncorrectCallArgs, meta_dict)
        end
    end
```

Semantics preserved from today, verify each against the current code before deleting it: the eval/macro blind-spot comment block (:510–516) moves with the type phase; the splat skip (`tree.arities !== nothing && !call_has_splat(x)`) still wraps the whole arm; the "matches workspace arity → return" flow is now "count phase then type phase then return" — the `return` at :540 stays.

- [ ] **Step 4: Run — new fixture green, and re-run these specific guards:**

- `run_tests("test/test_file_analysis.jl"; filter=ti -> occursin("parity", ti.name))` — all rows still green; the partial-set testitem (:2546, "declines wherever the record set is partial") is the regression canary: its `import Base: length` arm must STAY silent (the store's `length` methods now participate and `length(::Vector)` matches through the store).
- `run_tests("test/test_file_analysis.jl")` and `run_tests("test/staticlint")` in full.

- [ ] **Step 5: Add placement (e) arms for every earlier row**

One testitem "parity: placement (e) — store callee with workspace overload, per shape": for each of bare (exists at :2429 family — extend), parametric, union, where, vararg, optional, keywords: an `import Base: <fn>` + workspace overload of a real Base name, a good call served by each half, a bad call served by neither. Reuse `iseven` where the shape allows; shapes needing a parametric/vararg store method can define the workspace overload to carry the shape instead (the SHAPE only needs to appear on one side of the union for the row to be honest — note which side in a comment).

- [ ] **Step 6: Commit**

```bash
git add src/StaticLint/linting/checks.jl src/layer_file_analysis.jl test/test_file_analysis.jl
git commit -m "feat(staticlint): type-check store-backed callees against the record-store union"
```

---

### Task 9: Mixed-mode union, site 2 — pure store callee extended by the workspace

Today a call whose `func_ref` IS a store function that some workspace file extends declines entirely (`tree.extended` → `return`, `checks.jl:551–553`) — counts and types both. Replace the blanket decline with the same union, sourcing the workspace half from the external-extension table (`_matching_workspace_extensions`, `layer_file_analysis.jl:668`), whose `ItemRef`s reach the items' `method_sig` records. This sources extension records at check time instead of re-keying the signature index under store paths — same semantics as the spec's "keyed under the extension target", chosen because the table already exists and already covers both the qualified (`Base.foo(x) = …`) and unqualified (`import Base: foo; foo(x) = …`) forms.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`TreeContext` gains `ext_records`; the tree_extended arm)
- Modify: `src/layer_file_analysis.jl` (new closure)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Produces: `TreeContext.ext_records::Union{Nothing,Function} = nothing` — `(func_ref, x) -> NameMethods`: the records of every workspace extension of the store function `func_ref`, `has_unknown_shapes=true` if any matching extension's item has `method_sig === nothing`, `has_forward_decl=false`.
- Consumes: `_matching_workspace_extensions`, `_inventory_item`, `derived_file_module_path`, `LocatedSignature`.

- [ ] **Step 1: Write the failing fixtures — both directions**

```julia
@testitem "parity: a store function the workspace extends is checked against the union" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct D end\nBase.iseven(d::D) = true\nstruct Other end\n",
        B => """
        good1(d::D) = iseven(d)       # served by the sibling's qualified extension
        good2(x::Int) = iseven(x)     # served by the store
        bad(w::Other) = iseven(w)     # neither: flag (today: silent decline)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end
```

Plus the safety arm in the same testitem style: an extension whose signature the inventory cannot read (`@inline Base.iseven(d::E) where {E<:SomethingUnresolvable} = …` is still readable — use a macro the walker treats as opaque instead: define the extension under `@static if true ... end`? No — `@static` is walked. Use a genuinely unreadable shape: `Base.eval(:(...))`-style is invisible, which is the accepted blind spot, not this guard. The reachable unreadable case is an extension item whose `method_sig` is `nothing` — e.g. `Base.iseven(d::E) where E = d.x` is readable; construct instead a macro-declared extension: `macro mkext() :(Base.isodd(d::D) = true) end; @mkext`). If no such fixture is constructible for a STORE-qualified name, assert the closure contract directly instead: build the workspace, call the closure with a hand-made `func_ref`, check `has_unknown_shapes`.

- [ ] **Step 2: Run to verify red** (0 flags on `bad`).

- [ ] **Step 3: Implement**

`layer_file_analysis.jl`, beside the other closures:

```julia
    tree_ext_records = (func_ref, x) -> begin
        sigs = Set{LocatedSignature}()
        unknown = false
        for e in _matching_workspace_extensions(rt, root, env, func_ref)
            item = _inventory_item(rt, e.ref)
            if item === nothing || item.method_sig === nothing
                unknown = true
                continue
            end
            fp = derived_file_module_path(rt, root, e.ref.file)
            loc = fp === nothing ? nothing : vcat(fp, item.parent_module)
            loc === nothing ? (unknown = true) :
                push!(sigs, LocatedSignature(loc, item.method_sig))
        end
        return NameMethods(sigs, unknown, false)
    end
```

`checks.jl`, replace the decline (:551–553):

```julia
        if tree.extended !== nothing && (func_ref isa SymbolServer.FunctionStore || func_ref isa SymbolServer.DataTypeStore)
            if tree.extended(func_ref, x)
                (tree.ext_records === nothing || tree.resolve === nothing ||
                    call_has_splat(x)) && return
                nm = tree.ext_records(func_ref, x)
                nm.has_unknown_shapes && return
                tls = retrieve_toplevel_scope(x, meta_dict)
                tls isa Scope || return
                args, kws = call_arg_types(x, false, meta_dict, getsymbols(env))
                tree.callsite_type === nothing ||
                    (args = tree_arg_operands(x, args, meta_dict, tree.callsite_type))
                match = any(ls -> match_method(args, kws, ls, tree.resolve, getsymbols(env), meta_dict),
                            nm.signatures) ||
                    iterate_over_ss_methods(func_ref, tls, env,
                        m -> match_method(args, kws, m, getsymbols(env), meta_dict);
                        in_scope = tree.in_scope === nothing ? nothing : tree.in_scope(x))
                match || seterror!(x, IncorrectCallArgs, meta_dict)
                return
            end
        end
```

One phase (the engine's alignment covers counts), matching how `sig_match_any` treats store callees today. Whole-closure mode: `tree.extended === nothing` → arm never entered → unchanged.

- [ ] **Step 4: Run — fixture green; the corpus-derived guard at :2634 (`Base.axes` extension pair) must still be silent; both suites full**

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/linting/checks.jl src/layer_file_analysis.jl test/test_file_analysis.jl
git commit -m "feat(staticlint): check calls to store functions the workspace extends"
```

---

### Task 10: `FunctionHasNoMethods` on definite emptiness

Verdict semantics case 2: signatures empty ∧ `has_forward_decl` ∧ ¬`has_unknown_shapes` ∧ no store backing ∧ no outside reach → `FunctionHasNoMethods`. Restores parity with whole-closure mode (which flags `function f end; f()` via `func_has_no_methods`) and makes the verdict survive moving the forward declaration to a sibling file. `NameMethods.has_forward_decl` finally gets its consumer.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (tree gate)
- Test: `test/test_file_analysis.jl`

- [ ] **Step 1: Write the failing fixtures**

```julia
@testitem "parity: a forward-declared function with no methods flags, cross-file" setup=[FileAnalysisWS] begin
    function flagsof(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return [d.message for d in fa.diagnostics]
    end
    # sibling forward declaration, no methods anywhere: flag
    @test any(m -> occursin("no methods", m), flagsof("function f end\n", "c() = f()\n"))
    # a real method anywhere unflags it — here, beside the declaration
    @test !any(m -> occursin("no methods", m), flagsof("function f end\nf(x) = x\n", "c() = f(1)\n"))
end
```

Add a third arm during the red phase pinning the unprovable case — a definition shape that sets `has_unknown_shapes` for `f`'s own key (per `derived_method_signatures_index`, that is a `:macro_declared` row for `f` or a callable `f` item with an arity but no readable signature) must stay silent. Find a source shape that produces one (check `test_macro_declared_names.jl` for macros the walker treats as name-minting); if none is constructible for a name that ALSO has a forward declaration, assert the condition at the index level instead: build the workspace, read `derived_method_signatures(rt, ROOT, ["MainPkg"], "f")`, and test the gate predicate directly.

Also the same-file placement (`B` holds both the declaration and the call) and the one-file root variant, expecting the same flag — plus whole-closure agreement is already covered by the existing `func_has_no_methods` tests in `test/staticlint`.

- [ ] **Step 2: Run to verify red** (per-file mode today: the tree gate returns silently at :540 for every tree-visible callee).

- [ ] **Step 3: Implement — one branch in the Task 8 gate**

In the restructured tree arm, before the count phase (the count phase requires arities or store; this case has neither):

```julia
    if tree.signatures !== nothing && store === nothing && !call_has_splat(x)
        nm0 = tree.signatures(n, x)
        if isempty(nm0.signatures) && nm0.has_forward_decl && !nm0.has_unknown_shapes &&
           !(tree.reaches_outside !== nothing && tree.reaches_outside(n, x))
            seterror!(x, FunctionHasNoMethods, meta_dict)
            return
        end
    end
```

Fold the `nm0` fetch with the type phase's `nm` fetch (one `tree.signatures` call per gate pass).

- [ ] **Step 4: Run green; full file-analysis suite; commit**

```bash
git add src/StaticLint/linting/checks.jl test/test_file_analysis.jl
git commit -m "feat(staticlint): flag calls to forward-declared functions with no methods"
```

---

### Task 11: Constructor-call argument typing

`arg_type`'s non-method branch answers `Any` for every call expression (`methodmatching.jl:39–68`), so `f(Own())` carries no type — the measured largest cause of argument-side unknowns. New rule on every path: a call argument whose callee resolves to a datatype types as that datatype.

**Files:**
- Modify: `src/StaticLint/methodmatching.jl` (`arg_type` non-method branch, `_resolve_type_expr` Binding leg)
- Modify: `src/StaticLint/treetypes.jl` (`_workspace_datatype_segments` call-arg route)
- Test: `test/test_file_analysis.jl`, `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Consumes: `_is_type_callee` (`methodmatching.jl:406`), `_resolve_type_expr` (:424), `_names_workspace_datatype`/`_type_name_segments` (`treetypes.jl`), `tree_arg_operands`.
- Produces: the "argument is a constructor call" parity row.

- [ ] **Step 1: Write the failing row — constructed type in each placement**

```julia
@testitem "parity/ctor-arg: a constructor-call argument carries its type" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # (c) constructed type declared in the sibling, call in B
    @test length(callflags("struct Own end\nstruct Other end\ntarget(x::Own) = 1\n",
                           "b1() = target(Other())\n")) == 1
    @test isempty(callflags("struct Own end\nstruct Other end\ntarget(x::Own) = 1\n",
                            "b2() = target(Own())\n"))
    # (b) same file
    @test length(callflags("struct Z end\n",
                           "struct Own end\nstruct Other end\ntarget(x::Own) = 1\nb3() = target(Other())\n")) == 1
    # (d) store type constructed: ArgumentError("x") vs a slot wanting a workspace type
    @test length(callflags("struct Own end\ntarget(x::Own) = 1\n",
                           "b4() = target(ArgumentError(\"x\"))\n")) == 1
    # (a) closure: whole path is local
    @test length(callflags("struct Z end\n",
                           "struct Own end\nstruct Other end\nfunction c()\n    t(x::Own) = 1\n    t(Other())\nend\n")) == 1
end
```

- [ ] **Step 2: Run to verify red** (every arm 0 flags today).

- [ ] **Step 3: Implement, two shared-path edits**

1. `arg_type` non-method branch, after the `_is_where_typevar_ref` guard:
   ```julia
        if iscall(arg) && arg.args !== nothing && !isempty(arg.args) && store !== nothing &&
                _is_type_callee(arg.args[1], store, meta_dict)
            return _resolve_type_expr(arg.args[1], store, meta_dict)
        end
   ```
2. `_resolve_type_expr` currently drops a plain workspace datatype `Binding` to `Any`; add the leg (before the final fallback):
   ```julia
        elseif r isa Binding && r.val isa EXPR && CSTParser.defines_datatype(r.val)
            return r
   ```
3. Cross-file: `_workspace_datatype_segments` (`treetypes.jl:158`) gains the call route so `tree_arg_operands` converts a `TreeRef`-callee constructor argument:
   ```julia
        if arg isa EXPR && iscall(arg) && arg.args !== nothing && !isempty(arg.args) &&
                _names_workspace_datatype(arg.args[1], meta_dict)
            return _type_name_segments(arg.args[1])
        end
   ```
   placed before the existing identifier route's `(arg isa EXPR && isidentifier(arg)) || return nothing` line.

Both `check_call` and `describe_call_mismatch` flow through `call_arg_types` + `tree_arg_operands`, so decision and message move together — no other edit.

- [ ] **Step 4: Run green; run BOTH full suites (this branch changes whole-closure behavior too — new true positives are expected there; any staticlint test that fixture-calls a constructor into a mismatching slot may legitimately start flagging and needs its expectation updated, one by one, verifying each is a true positive)**

- [ ] **Step 5: Commit**

```bash
git add src/StaticLint/methodmatching.jl src/StaticLint/treetypes.jl test/test_file_analysis.jl test/staticlint/test_staticlint.jl
git commit -m "feat(staticlint): type constructor-call arguments as the constructed datatype"
```

---

### Task 12: Datatype callees through the engine — full inner-constructor records

Struct items currently carry ONE record (`method_sig` = default field constructor, `layer_inventory.jl:899–904`), structs with inner constructors read shape-unknown, and the gate excludes every datatype callee (`!_is_datatype_callee(func_ref)`). This task: (1) `InventoryItem` gains `ctor_sigs::Vector{MethodSignature}` — default outer constructor when no inner constructors, else every inner constructor as written with slot types erased to `UnknownType` (spec: constructors rule out on alignment/keywords only); (2) a struct behind a non-doc macrocall records NO constructor signatures (the macro may add constructor methods — `@kwdef`), leaving it shape-unknown; (3) the index reads `ctor_sigs`; (4) the gate exclusion lifts.

**Files:**
- Modify: `src/layer_inventory.jl` (`InventoryItem` struct + back-compat constructors + the datatype branch)
- Modify: `src/StaticLint/signature_reader.jl` (`_erase_slot_types`)
- Modify: `src/layer_module_tree.jl` (`derived_method_signatures_index` datatype rule)
- Modify: `src/StaticLint/linting/checks.jl` (drop `!_is_datatype_callee(func_ref)` from the Task 8 type phase)
- Test: `test/test_inventory.jl`, `test/test_module_tree.jl`, `test/test_file_analysis.jl`

**Interfaces:**
- Produces: `InventoryItem.ctor_sigs::Vector{MethodSignature}` (empty vector = no constructor opinion; the existing `method_sig` field goes back to `nothing` for datatype items). `StaticLint._erase_slot_types(sig::MethodSignature) -> MethodSignature`.
- **A struct definition changes ⇒ restart the julia-mcp session after the edit and re-define `run_tests`.**

- [ ] **Step 1: Write the failing inventory tests**

In `test/test_inventory.jl`, using its `InventoryWS` snippet (`inventory_of(src)` returns `(inventory, jw)`; items are `inventory.items` — see `test_inventory.jl:121–133`):

```julia
@testitem "inventory: constructor signatures per struct" setup=[InventoryWS] begin
    using JuliaWorkspaces: UnknownType
    # plain struct: one default record, one Unknown slot per field
    # inner constructors: one record each, as written, slot types erased, kws kept
    src = """
    struct A x; y::Int end
    struct B
        x
        B(x::Int; scale=1) = new(x * scale)
        B() = new(0)
    end
    Base.@kwdef struct C
        inc::Int = 1
    end
    """
    items = inventory_of(src)[1].items
    a = only(filter(i -> i.name == "A", items))
    @test length(a.ctor_sigs) == 1 && length(a.ctor_sigs[1].slots) == 2
    @test all(s -> s.type isa JuliaWorkspaces.UnknownType, a.ctor_sigs[1].slots)
    b = only(filter(i -> i.name == "B", items))
    @test length(b.ctor_sigs) == 2
    @test any(cs -> cs.kws == [:scale], b.ctor_sigs)
    @test all(cs -> all(s -> s.type isa JuliaWorkspaces.UnknownType, cs.slots), b.ctor_sigs)
    c = only(filter(i -> i.name == "C", items))
    @test isempty(c.ctor_sigs)          # macro-wrapped: no constructor opinion
    @test c.method_sig === nothing
end
```

And the end-to-end fixtures in `test/test_file_analysis.jl`:

```julia
@testitem "parity/ctor: datatype callees rule out on keywords and alignment only" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # keyword passed to a plain struct's field constructor: no method takes keywords
    @test length(callflags("struct S x end\n", "mk() = S(x = 1)\n")) == 1
    # field types are NOT an opinion: a 'wrong' positional type stays silent
    @test isempty(callflags("struct S x::Int end\n", "mk() = S(\"str\")\n"))
    # inner constructor with a keyword: presence accepted
    @test isempty(callflags("struct T\n    x\n    T(x::Int; scale=1) = new(x*scale)\nend\n",
                            "mk() = T(1; scale=2)\n"))
    # @kwdef keyword form stays silent (shape unknown behind the macro)
    @test isempty(callflags("Base.@kwdef struct FS\n    inc::Int = 1\nend\n",
                            "mk() = FS(; inc=3)\n"))
end
```

- [ ] **Step 2: Run to verify red** (the first arm is silent today — `_is_datatype_callee` excludes constructors; the inventory test fails on the missing field).

- [ ] **Step 3: Implement**

1. `signature_reader.jl`:
   ```julia
   "Constructor records carry alignment and keywords, never types: fields and
   inner-constructor annotations are not a type opinion for dispatch on the type."
   _erase_slot_types(sig::MethodSignature) = MethodSignature(
       [SigSlot(UnknownType(), s.optional) for s in sig.slots],
       sig.vararg === nothing ? nothing : VarargSpec(UnknownType(), sig.vararg.count),
       Dict{String,TypeExpr}(), sig.kws, sig.kwsplat)
   ```
2. `layer_inventory.jl`: add `ctor_sigs::Vector{MethodSignature}` to `InventoryItem` (after `supertype`); extend the two back-compat constructors with `MethodSignature[]`. In the datatype branch (:895–906): detect a non-doc macrocall ancestor (reuse the doc-macro detector at :154; walk `parentof` until the file root — a `:macrocall` head that is not the doc form ⇒ wrapped); build:
   ```julia
   ctor_sigs = if !CSTParser.defines_struct(x) || under_nondoc_macro
       MethodSignature[]
   else
       inner = filter(a -> CSTParser.defines_function(a), x.args[3].args)
       if isempty(inner)
           [MethodSignature([SigSlot(UnknownType(), false) for _ in field_names],
                nothing, Dict{String,TypeExpr}(), Symbol[], false)]
       else
           sigs = MethodSignature[]
           ok = true
           for ic in inner
               s = StaticLint.method_signature(ic)
               s === nothing ? (ok = false) : push!(sigs, StaticLint._erase_slot_types(s))
           end
           ok ? sigs : MethodSignature[]      # any unreadable inner ctor: no opinion
       end
   end
   ```
   The item's `method_sig` becomes `nothing` for datatype items (delete the old `ctor_sig` local); pass `ctor_sigs` positionally. **Restart the session now.**
3. `layer_module_tree.jl`, `derived_method_signatures_index` walk: the datatype case —
   ```julia
        if item.method_sig !== nothing
            push!(...)                              # unchanged, function kinds
        elseif item.kind in (:struct, :mutable_struct) && !isempty(item.ctor_sigs)
            for cs in item.ctor_sigs
                push!(get!(() -> Set{LocatedSignature}(), sigs, key), LocatedSignature(loc, cs))
            end
        elseif item.kind === :macro_declared
            ...
   ```
   The existing "callable with a count but no readable signature" rule (:961) now catches `:struct` items with empty `ctor_sigs` → `unknown` — exactly the macro-wrapped and unreadable-inner-ctor cases. Verify order of the `elseif` chain preserves that.
4. `checks.jl`: delete `!_is_datatype_callee(func_ref)` from the Task 8 type phase. (`_is_datatype_callee` keeps its other callers, if any — grep first; if none remain, delete the helper.)

- [ ] **Step 4: Backdating test**

In `test/test_module_tree.jl`, alongside the existing signature-index backdating testitem (find it via `grep -n "backdate" test/test_module_tree.jl`): move a struct WITH an inner constructor from one file to a sibling; assert `derived_method_signatures(rt, root, path, "T")` compares `==` before/after (the `Set` is position-free), and that a field RENAME changes it.

- [ ] **Step 5: Run everything relevant**

`run_tests("test/test_inventory.jl")`, `run_tests("test/test_module_tree.jl")`, `run_tests("test/test_file_analysis.jl")`, `run_tests("test/staticlint")` — the kwdef guard at `test_file_analysis.jl:2577` is the canary; symbols/hover/completions suites (`test_symbols.jl`, `test_hover.jl`) guard against inventory-shape fallout.

- [ ] **Step 6: Commit**

```bash
git add src/layer_inventory.jl src/StaticLint/signature_reader.jl src/layer_module_tree.jl src/StaticLint/linting/checks.jl test/
git commit -m "feat(inventory): constructor signature records, inner constructors included"
```

---

### Task 13: Property-test record arm

The pin at `test/staticlint/test_staticlint.jl:4610` checks `_has_type_intersection` over store operands against Julia's real `<:`. The record arm: the same pairs, resolved as `TypeRef`s through `_tree_type_resolver` over a minimal workspace, must give the same tri-state verdicts — pinning tree-side resolution to store-side resolution to the language.

**Files:**
- Test: `test/test_file_analysis.jl` (needs `ws_with`; the staticlint dir has no workspace helper)

- [ ] **Step 1: Write the testitem**

```julia
@testitem "record-arm: TypeRef resolution never contradicts the store verdicts" setup=[FileAnalysisWS] begin
    # Same name table as the store-side pin (test_staticlint.jl:4610); the two
    # tables must not drift — same floors, same pairs.
    concrete = ["Int8","Int64","UInt8","Float32","Float64","Bool","Char","String",
                "Symbol","Nothing","Dict","Set","Array","UnitRange","ArgumentError",
                "BoundsError","Rational","Complex"]
    bounds = ["Real","Signed","Unsigned","Integer","AbstractFloat","Number",
              "AbstractString","AbstractChar","AbstractDict","AbstractSet",
              "AbstractArray","DenseArray","AbstractRange","Exception","Function","Tuple"]
    using JuliaWorkspaces: TypeRef
    jw = ws_with(Dict(ROOT => "module MainPkg\nend\n"))
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, ROOT)
    # project-less root: the resolver and this lookup share the stdlib-only env
    env = JuliaWorkspaces.derived_stdlib_only_env(jw.runtime)
    syms = SL.getsymbols(env)
    function lookup(n)   # the store-side operand, as the store pin builds it
        for m in (:Core, :Base)
            haskey(syms, m) && haskey(syms[m], Symbol(n)) && return syms[m][Symbol(n)]
        end
        return nothing
    end
    function tally()
        mismatches = String[]
        resolved = 0
        for c in concrete, b in bounds
            rc = resolve(TypeRef([c]), ["MainPkg"]); rb = resolve(TypeRef([b]), ["MainPkg"])
            sc = lookup(c); sb = lookup(b)
            (rc === nothing || rb === nothing || sc === nothing || sb === nothing) && continue
            resolved += 1
            SL._has_type_intersection(rc, rb, syms, Dict{UInt64,SL.Meta}()) ===
                SL._has_type_intersection(sc, sb, syms, Dict{UInt64,SL.Meta}()) ||
                push!(mismatches, "$c vs $b")
        end
        return resolved, mismatches
    end
    resolved, mismatches = tally()
    @test isempty(mismatches)
    @test resolved >= 250    # floor against silent vacuity (18×16 = 288 pairs)
end
```

The store operand a `TypeRef` resolves to may be `get_eventual_datatype`-reduced where the raw `lookup` is the constructor `FunctionStore` — if the tally shows systematic mismatches of that one shape, apply `SL.get_eventual_datatype(sc, env)` to the store side first (that is what the store path's comparisons see anyway); note it in a comment.

- [ ] **Step 2: Run — this may genuinely fail; any mismatch is a resolution defect to fix in `_tree_type_resolver`/`_store_type_value`, not in the test.**

- [ ] **Step 3: Commit**

```bash
git add test/test_file_analysis.jl
git commit -m "test(staticlint): pin record-side type resolution to the store verdicts"
```

---

### Task 14: Corpus sweep, both directions, and the full gate

**Files:**
- No source changes expected; fixes get their own commits.

- [ ] **Step 1: Re-verify the order-independence fixture exists**

`grep -n "both file orders\|order-independence" test/` — the spec requires a two-files-two-orders fixture. Plan 1's move testitems (commits `b91c65e`, `25f3b75`) may already cover it; if not, add it now (two same-name methods split across `A`/`B`, assert identical diagnostics for both include orders).

- [ ] **Step 2: Run the corpus sweep**

The corpus is `/home/pfitzseb/.cache/djp-repro/depot/packages` (read-only, 80 roots); the Plan 1 scans and the scan procedure live in `.superpowers/sdd/2026-08-04-cross-file-type-parity-1-records-and-name-shapes/sweep/` (`scan_main.txt` = main baseline, `scan_branch_round3.txt` = Plan 1 final; task-10-report.md describes the scan loop: one `walkdir` + `derived_file_analysis`-diagnostics pass per root, via julia-mcp). Produce `scan_branch_plan2.txt` in the NEW ledger dir (`.superpowers/sdd/<this plan's slug>/sweep/`), then diff against `scan_branch_round3.txt`:

- **Every added diagnostic** classified by hand: true positive (acceptable) or false positive (STOP — fix before anything else, one commit per defect, each with a reduced fixture added to the "real-corpus operand defects" testitem at `test_file_analysis.jl:2613`).
- **Every removed diagnostic** explained (expected removals: site-1/site-2 unions unflagging things? No — unions only ADD checking; removals are suspect by default).

- [ ] **Step 3: Full suite**

`run_tests("test")` (`timeout=600`; expect the known 132 harness-artifact errors, 0 failures beyond baseline broken counts — the three `@test_broken` pins from Plan 1 must still be broken, not passing).

- [ ] **Step 4: Write the sweep summary into the ledger and commit any fixture additions**

```bash
git add test/
git commit -m "test(staticlint): corpus-sweep fixtures for plan-2 defects"
```

(Nothing about the sweep itself is committed to the repo; the ledger dir is gitignored.)

---

## Task order and dependencies

1 → (2, 3, 4, 5, 6 in any order) → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14.
Tasks 2–6 depend only on Task 1. Task 8 depends on Task 1's `TreeContext` and is required by 9, 10, 12. Task 13 is independent of 7–12 but runs late so resolution fixes from earlier tasks land first. Task 14 is the gate.
