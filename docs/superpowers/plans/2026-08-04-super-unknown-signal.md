# `_super` unknown-signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `_super`'s "I have no information" answer distinguishable from "this type's supertype is `Any`", so the subtyping check stops reporting a truncated walk as a proven mismatch.

**Architecture:** `_super` returns `nothing` where it has no information. `_issubtype` and `_has_type_intersection` become three-valued (`true` / `false` / `nothing`) with Kleene propagation, and `false` is returned only when every step of the walk was definite. All eight call sites are then given the direction that is safe for the question they ask: the rule-out sites (`match_method`, the message renderer) act only on a definite `false`, and the "is this a Number" sites act only on a definite `true`.

**Tech Stack:** Julia. `src/StaticLint/` (a vendored StaticLint inside JuliaWorkspaces), CSTParser, SymbolServer store types, TestItemRunner for tests.

Spec: `docs/superpowers/specs/2026-08-04-super-unknown-signal-design.md`.

## Global Constraints

- Branch: `sp/super-unknown-signal`, already created off `main` (`9ab7c24`). **Run every git command inside `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces`** — it is a git submodule; running git from the julia-vscode root operates on the wrong repository.
- Run Julia **only** through the julia-mcp tool (`mcp__julia__julia_eval`) with env `/home/pfitzseb/git/julia-vscode/scripts/environments/development`. Never spawn `julia` and never run `Pkg.test`.
- Give every `julia_eval` a timeout of **600000 ms or more**. A timeout expiry kills the session and loses all state. The first test run that lints compiles for ~45 s.
- Tests are `@testitem`s. **`@testitem` bodies need explicit imports** (`using JuliaWorkspaces: …`); the package's default `using`s do not apply inside them. `return` does not skip a `@testitem` body — gate with `if`/`else` if you ever need to.
- Code comments in this repo are terse and **never reference plan or spec documents**. Do not add "see the spec" comments.
- Editing a `struct` definition requires `julia_restart` before the next test run. This plan changes no structs, so no restart is needed.
- The three-valued values are the Julia values `true`, `false` and `nothing`. Compare with `=== true` / `=== false` / `=== nothing`. Never put a three-valued result directly in a boolean position (`if x`, `x && …`, `!x`) — that throws `TypeError` on `nothing`, which is the whole point of choosing this representation.
- `_MAX_SUPER_DEPTH = 32`.

---

### Task 1: The three-valued contract and all eight call sites

The contract change is atomic: once `_issubtype` can return `nothing`, every caller that puts it in a boolean position throws. Core and call sites therefore land together.

**Files:**
- Modify: `src/StaticLint/subtypes.jl:1-14` (`_issubtype`, `_has_type_intersection`), `:64` (the `_super` catch-all), `:66-74` (`_super(b::Binding, …)`)
- Modify: `src/StaticLint/methodmatching.jl:285,288,295` (`match_method(…::SymbolServer.MethodStore…)`), `:408,411,430` (`match_method(…::EXPR…)`)
- Modify: `src/StaticLint/linting/checks.jl:785` (`describe_call_mismatch`), `:884` (`check_incorrect_iter_spec`)
- Modify: `src/StaticLint/type_inf.jl:590` (`_is_scalar_index`), `:637` (`_is_number`)
- Test: `test/staticlint/test_staticlint.jl` (append after the `_super resolves declared supertype (#446)` testitem, which currently ends around line 599), `test/test_file_analysis.jl` (append at end of file)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `StaticLint._super(a, store, meta_dict)` → a type operand, or `nothing` meaning "no information".
  - `StaticLint._issubtype(a, b, store, meta_dict, depth=0)::Union{Bool,Nothing}`.
  - `StaticLint._has_type_intersection(a, b, store, meta_dict)::Union{Bool,Nothing}`.
  - `StaticLint._MAX_SUPER_DEPTH::Int` — the recursion cap, `32`.

- [ ] **Step 1: Write the end-to-end test for the false positive being removed**

This is the behavioural claim of the whole task, and it must be seen failing before anything is changed. `Own` is declared in the calling file, its abstract supertype `MyAbs` one file over, and the parameter is the store type `Integer` that `MyAbs` descends from — so the walk has to cross from the workspace into the store, which is exactly where it truncates today.

Two things about the fixture are load-bearing and neither is obvious:

- **The callee is a closure.** A module-level callee is tree-visible, and `check_call` answers those from the cross-file arity index without ever reaching `match_method`.
- **The argument is a typed parameter (`v::Own`), not a constructor call (`Own()`).** `arg_type`'s non-method branch resolves a reference through `refof(...).type` but falls through to `CoreTypes.Any` for a call — and `Any` on either side makes `_has_type_intersection` answer `true` immediately, so a `h(Own())` fixture never reaches the walk at all and passes even unfixed.

Append to `test/test_file_analysis.jl`:

```julia
@testitem "file analysis: a chain that leaves this file rules nothing out" setup=[FileAnalysisWS] begin
    # `Own <: MyAbs <: Integer` with `MyAbs` in a sibling: a real subtype whose
    # supertype walk dead-ends at a `TreeRef`. Ruling the call out would be a
    # false positive on correct code. The callee is a closure on purpose — a
    # module-level one is answered by the cross-file arity check instead — and
    # the argument is a typed parameter, since a constructor call's type is `Any`.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs <: Integer end\n",
        B => """
        struct Own <: MyAbs end
        function caller(v::Own)
            h(x::Integer) = 1
            return h(v)
        end
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) ||
                    occursin("method call error", d.message), fa.diagnostics)
end
```

- [ ] **Step 2: Run it and confirm it fails**

```
mcp__julia__julia_eval, env=/home/pfitzseb/git/julia-vscode/scripts/environments/development, timeout 600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("rules nothing out", ti.name), verbose = true)
```

Expected: FAIL — one `Test Failed` on the `@test !any(...)` line, because the truncated chain currently produces a "Possible method call error" / "No method matching" diagnostic.

**If it PASSES instead**, the comparison is not being reached and the test would prove nothing either way. Do not delete it and do not proceed on faith: add this operand-level assertion *alongside* the diagnostic one, in the same testitem, and report which of the two carried the red phase. It reaches the primitive directly, so it fails today whatever `check_call` decides.

```julia
    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)
    syms = SL.getsymbols(JuliaWorkspaces.derived_stdlib_only_env(jw.runtime))
    # `find_identifiers` finds every occurrence — the declaration and the use —
    # so take the declaring one rather than asserting there is only one.
    ownref = SL.refof(first(find_identifiers(cst, "Own")), meta_dict)
    @test ownref isa SL.Binding
    @test SL._has_type_intersection(ownref, syms[:Core][:Integer], syms, meta_dict) !== false
```

- [ ] **Step 3: Write the unit tests for the new `_super` contract**

Append to `test/staticlint/test_staticlint.jl`, after the existing `_super resolves declared supertype (#446)` testitem:

```julia
@testitem "_super answers nothing when it has no information" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    cst, meta_dict, jw = parse_and_pass("struct S <: NoSuchSupertype end\n")
    env = get_env(jw)
    syms = env.symbols

    # An operand the walk has no method for: ignorance, not the top of the lattice.
    @test SL._super("not a type at all", syms, meta_dict) === nothing
    @test SL._super(nothing, syms, meta_dict) === nothing

    # A binding whose supertype expression carries no ref is equally unknown.
    b = SL.refof(only(find_identifiers(cst, "S")), meta_dict)
    @test b isa SL.Binding
    @test SL._super(b, syms, meta_dict) === nothing

    # A genuine lattice step is unchanged.
    @test !isnothing(SL._super(syms[:Core][:Int64], syms, meta_dict))
end

@testitem "_issubtype separates a truncated walk from a finished one" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    _, meta_dict, jw = parse_and_pass("x = 1\n")
    syms = get_env(jw).symbols
    int, str, real = syms[:Core][:Int64], syms[:Core][:String], syms[:Core][:Real]

    # Definite yes, and definite no: the walk reached `Any` with every step known.
    @test SL._issubtype(int, real, syms, meta_dict) === true
    @test SL._issubtype(int, str, syms, meta_dict) === false

    # An operand with no supertype information: no verdict either way.
    @test SL._issubtype("not a type at all", int, syms, meta_dict) === nothing

    # `Any` on the right is always satisfied, whatever the left operand is.
    @test SL._issubtype("not a type at all", syms[:Core][:Any], syms, meta_dict) === true
end

@testitem "_has_type_intersection propagates unknown" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    _, meta_dict, jw = parse_and_pass("x = 1\n")
    syms = get_env(jw).symbols
    int, str, real = syms[:Core][:Int64], syms[:Core][:String], syms[:Core][:Real]
    unknown = "not a type at all"

    # Either direction definitely holding is a definite yes.
    @test SL._has_type_intersection(int, real, syms, meta_dict) === true
    @test SL._has_type_intersection(real, int, syms, meta_dict) === true
    # Both directions definitely failing is a definite no.
    @test SL._has_type_intersection(int, str, syms, meta_dict) === false
    # One unknown direction and no definite yes is unknown, in both orders.
    @test SL._has_type_intersection(unknown, int, syms, meta_dict) === nothing
    @test SL._has_type_intersection(int, unknown, syms, meta_dict) === nothing
    # A definite yes wins over an unknown: `Any` on either side still matches.
    @test SL._has_type_intersection(unknown, syms[:Core][:Any], syms, meta_dict) === true
end
```

- [ ] **Step 4: Run the three unit testitems and confirm they fail**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("_super answers nothing", ti.name) ||
                   occursin("_issubtype separates", ti.name) ||
                   occursin("_has_type_intersection propagates", ti.name), verbose = true)
```

Expected: FAIL. Today `_super` returns `CoreTypes.Any` for the unknown operands (so `=== nothing` fails), and `_issubtype` returns `false` rather than `nothing`.

- [ ] **Step 5: Make the `_super` legs answer `nothing`**

In `src/StaticLint/subtypes.jl`, replace the catch-all:

```julia
# No method for this operand — a `TreeRef`, a bare `EXPR`, a store lookup that
# missed. `nothing` means "no information", which is NOT the same answer as
# `Any`: reaching `Any` ends a walk with a verdict, running out of information
# ends it with none.
_super(_, _, _) = nothing
```

and both ignorance legs of the `Binding` method:

```julia
function _super(b::Binding, store, meta_dict)
    StaticLint.CoreTypes.isdatatype(b.type) || return nothing
    b.val isa Binding && return _super(b.val, store, meta_dict)
    sup = _super(b.val, store, meta_dict)
    if sup isa EXPR && StaticLint.hasref(sup, meta_dict)
        StaticLint.refof(sup, meta_dict)
    else
        nothing
    end
end
```

Leave `FakeTypeVar`, `FakeUnionAll`, `FakeUnion`, `FakeTypeofVararg`, `FakeTypeofBottom` and the `DataTypeStore`/`FakeTypeName`/`EXPR` methods exactly as they are: the first two are structural steps, the next three genuinely reach `Any`, and the last three already answer `nothing` on a miss and were only being coerced by the catch-all.

- [ ] **Step 6: Make the two predicates three-valued**

Replace the top of `src/StaticLint/subtypes.jl`:

```julia
# The walk's recursion cap. `_super(::Binding)` can hand back another `Binding`,
# so a mid-edit `struct A <: B` / `struct B <: A` would otherwise recurse until
# the stack goes. Raise it if a real hierarchy ever runs deeper; Base's deepest
# chains are single digits.
const _MAX_SUPER_DEPTH = 32

# `true`/`false`/`nothing`, where `nothing` means the walk ran out of
# information. `false` is returned only when every step was definite, so a
# caller may act on it; `nothing` licenses nothing.
function _issubtype(a, b, store, meta_dict, depth=0)
    _isany(b) && return true
    _type_compare(a, b) && return true
    depth >= _MAX_SUPER_DEPTH && return nothing
    sup_a = _super(a, store, meta_dict)
    sup_a === nothing && return nothing
    _type_compare(sup_a, b) && return true
    _isany(sup_a) && return false
    return _issubtype(sup_a, b, store, meta_dict, depth + 1)
end

function _has_type_intersection(a, b, store, meta_dict)
    # A bare `Union` datatype means "some union, members unknown" (e.g. the
    # binding type of a `x::Union{…}` declaration); it can't disprove a call.
    (_is_bare_union(a) || _is_bare_union(b)) && return true
    ab = _issubtype(a, b, store, meta_dict)
    ab === true && return true
    ba = _issubtype(b, a, store, meta_dict)
    ba === true && return true
    (ab === nothing || ba === nothing) && return nothing
    return false
end
```

- [ ] **Step 7: Give the six `match_method` sites the rule-out direction**

In `src/StaticLint/methodmatching.jl`, every one of the six
`_has_type_intersection(…) || return false` lines becomes a definite-only test.
There are three in `match_method(args, kws, method::SymbolServer.MethodStore, store, meta_dict)` and three in `match_method(args, kws, method::EXPR, store, meta_dict)`; the argument expressions differ, so make the edits one at a time and keep each line's own operands:

```julia
            _has_type_intersection(args[i], t, store, meta_dict) === false && return false
```
```julia
            _has_type_intersection(args[i], va.T, store, meta_dict) === false && return false
```
```julia
        _has_type_intersection(args[i], t, store, meta_dict) === false && return false
```
```julia
            _has_type_intersection(args[i], margs[i], store, meta_dict) === false && return false
```
```julia
            _has_type_intersection(args[i], tail, store, meta_dict) === false && return false
```
```julia
            _has_type_intersection(args[i], margs[i], store, meta_dict) === false && return false
```

Add this comment once, above the first of them in each of the two functions:

```julia
    # Only a DEFINITE mismatch rules a method out. An unknown slot leaves the
    # method a candidate — flagging on ignorance is a false positive.
```

- [ ] **Step 8: Give the message renderer and the three Number-shaped sites their directions**

`src/StaticLint/linting/checks.jl:785`, inside `describe_call_mismatch` — name a slot only when it is provably wrong:

```julia
        if _has_type_intersection(got, exp, store, meta_dict) === false
            slot = s
            break
        end
```

`src/StaticLint/linting/checks.jl:884`, inside `check_incorrect_iter_spec`:

```julia
                if type !== nothing && _issubtype(type, getsymbols(env)[:Core][:Number], env.symbols, meta_dict) === true
```

`src/StaticLint/type_inf.jl:590`, the tail of `_is_scalar_index`:

```julia
        return _issubtype(r.type, store[:Core][:Number], store, meta_dict) === true
```

`src/StaticLint/type_inf.jl:637`, the tail of `_is_number`:

```julia
    return _issubtype(t, store[:Core][:Number], store, state.meta_dict) === true
```

Leave `_ancestry` (`type_inf.jl:415-426`) alone: it already breaks on a `nothing` from `_super`, and `_join_types` widens to `Any` when chains do not meet, which is the permissive answer.

- [ ] **Step 9: Run the four testitems from Steps 1 and 3 and confirm they pass**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("rules nothing out", ti.name) ||
                   occursin("_super answers nothing", ti.name) ||
                   occursin("_issubtype separates", ti.name) ||
                   occursin("_has_type_intersection propagates", ti.name), verbose = true)
```

Expected: PASS, all four.

- [ ] **Step 10: Run every testitem that exercises method matching or inference**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 900000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("method", ti.name) || occursin("call", ti.name) ||
                   occursin("iter", ti.name) || occursin("infer", ti.name) ||
                   occursin("type", ti.name), verbose = true)
```

Expected: PASS. A `TypeError: non-boolean (Nothing) used in boolean context` here means a call site was missed — find it in the stack trace and give it `=== true` or `=== false` per the table in the spec, then re-run. A newly-passing-instead-of-flagging test is the intended direction, but read each one: if a test asserted a diagnostic that is now gone, confirm the diagnostic was a false positive before touching the test, and say so in the commit message.

- [ ] **Step 11: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add src/StaticLint/subtypes.jl src/StaticLint/methodmatching.jl \
        src/StaticLint/linting/checks.jl src/StaticLint/type_inf.jl \
        test/staticlint/test_staticlint.jl test/test_file_analysis.jl
git commit -F - <<'EOF'
fix(staticlint): ignorance about a supertype is not a verdict

`_super`'s catch-all reported an operand it cannot walk as having supertype
`Any`, so `_issubtype` could not tell a truncated walk from one that finished
without finding a common ancestor. Both answered `false`, and every caller read
that as proven: a workspace type whose supertype lives in a sibling file — which
`refof`s to a `TreeRef`, hence the catch-all — had its calls ruled out.

`_super` now answers `nothing` where it has no information, and the two
predicates carry that through: `false` only when every step of the walk was
definite. The rule-out sites act on a definite `false`, the Number-shaped sites
on a definite `true`, which is what they already did once `false` and unknown
were told apart.

The rewritten recursion gets a depth cap: `_super(::Binding)` can return another
`Binding`, so a mid-edit supertype cycle recursed until the stack went.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 2: Pin the false-positive direction against Julia's own `<:`

The unit tests in Task 1 cover the three-valued mechanics; this covers the property that makes the whole check sound, over a table wide enough that a regression in any one walk shows up. The type-aware branch has a version of this that resolves its operands through `_resolve_param_types`, which does not exist on `main` — this port looks the names up in the store instead.

**Files:**
- Test: `test/staticlint/test_staticlint.jl` (append at end)

**Interfaces:**
- Consumes: `StaticLint._has_type_intersection(a, b, store, meta_dict)::Union{Bool,Nothing}` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the property test**

```julia
@testitem "the rule-out check never contradicts real subtyping" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    # The check is only sound if it never rules out a pair that really is a
    # subtype. Julia's own `<:` decides which pairs those are, so the
    # expectations cannot drift from the language. Deep ancestries are in here
    # on purpose: they are what a truncated `_super` walk gets wrong.
    concrete = [(:Int8, Int8), (:Int64, Int64), (:UInt8, UInt8),
                (:Float32, Float32), (:Float64, Float64),
                (:Bool, Bool), (:Char, Char), (:String, String),
                (:Symbol, Symbol), (:Nothing, Nothing),
                (:Dict, Dict), (:Set, Set), (:Array, Array), (:UnitRange, UnitRange),
                (:ArgumentError, ArgumentError), (:BoundsError, BoundsError),
                (:Rational, Rational), (:Complex, Complex)]
    bounds = [(:Real, Real), (:Signed, Signed), (:Unsigned, Unsigned),
              (:Integer, Integer), (:AbstractFloat, AbstractFloat), (:Number, Number),
              (:AbstractString, AbstractString), (:AbstractChar, AbstractChar),
              (:AbstractDict, AbstractDict), (:AbstractSet, AbstractSet),
              (:AbstractArray, AbstractArray), (:DenseArray, DenseArray),
              (:AbstractRange, AbstractRange), (:Exception, Exception),
              (:Function, Function), (:Tuple, Tuple)]

    _, meta_dict, jw = parse_and_pass("x = 1\n")
    syms = get_env(jw).symbols
    # `Core` then `Base`, which is the order a bare name is in scope under, so a
    # row never has to hardcode which of the two defines its type (`DenseArray`
    # is `Core`'s, `AbstractRange` is `Base`'s).
    function lookup(n)
        for m in (:Core, :Base)
            haskey(syms, m) && haskey(syms[m], n) && return syms[m][n]
        end
        return nothing
    end

    cres = [(n, t, lookup(n)) for (n, t) in concrete]
    bres = [(n, t, lookup(n)) for (n, t) in bounds]
    # Nothing below is vacuous through a missing entry or through `Any`.
    @test all(p -> p[3] !== nothing && !SL._isany(p[3]), cres)
    @test all(p -> p[3] !== nothing && !SL._isany(p[3]), bres)

    # The tally lives in a function because a `@testitem` body is evaluated at
    # module scope, where assigning to an outer name from inside a `for` is an
    # ambiguous soft-scope assignment.
    function tally()
        checked = 0        # pairs where `<:` holds and the check must stay silent
        ruled_out = 0      # pairs where `<:` fails and the check rules out
        false_ruleouts = String[]
        for (cn, ct, cv) in cres, (bn, bt, bv) in bres
            verdict = SL._has_type_intersection(cv, bv, syms, meta_dict)
            if ct <: bt
                checked += 1
                verdict === false && push!(false_ruleouts, "$cn <: $bn")
            elseif verdict === false
                ruled_out += 1
            end
        end
        return checked, ruled_out, false_ruleouts
    end
    checked, ruled_out, false_ruleouts = tally()

    @test isempty(false_ruleouts)
    # Floors, so a table that silently stops producing pairs fails loudly
    # instead of passing on nothing.
    @test checked >= 25
    # ...and the negative direction, which a check that answered `nothing`
    # for everything would fail while still passing the property above.
    @test ruled_out >= 150

    # The deep ancestries, named, so a regression says which walk broke.
    pair(cn, bn) = SL._has_type_intersection(
        cres[findfirst(p -> p[1] === cn, cres)][3],
        bres[findfirst(p -> p[1] === bn, bres)][3], syms, meta_dict)
    @test pair(:Int8, :Signed) === true
    @test pair(:Int8, :Number) === true
    @test pair(:Dict, :AbstractDict) === true
    @test pair(:ArgumentError, :Exception) === true
    @test pair(:UnitRange, :AbstractRange) === true
    @test pair(:Float64, :AbstractFloat) === true
end
```

- [ ] **Step 2: Run it**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("never contradicts real subtyping", ti.name), verbose = true)
```

Expected: PASS. It is a property of the code Task 1 shipped, so it has no red phase of its own.

Two failures are informative rather than a reason to weaken the test:
- **A `false_ruleouts` entry** is a real bug in the walk for that pair — report it, do not delete the pair.
- **A floor not met** means the store lookups came back thinner than expected. The `@test all(p -> p[3] !== nothing …)` assertions above name which entry is missing; drop that row from the table, print the resulting `checked` and `ruled_out`, and set each floor to the printed value (a floor is a tripwire against a table that stopped producing pairs, so it tracks the real count rather than being padded). Record both numbers in the commit message.

- [ ] **Step 3: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add test/staticlint/test_staticlint.jl
git commit -F - <<'EOF'
test(staticlint): pin the rule-out check against real subtyping

The check is sound only if it never rules out a pair that really is a subtype.
Julia's own `<:` decides which pairs those are over a table of concrete types
crossed with abstract bounds, so the expectations cannot drift from the
language, and floors under both the subtype-pair and rule-out counts keep a
table that stops producing pairs from passing on nothing.

The deep ancestries are asserted by name as well, so a regression reports which
walk broke rather than only that one did.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 3: Pin the conservative directions and the definite-mismatch floor

Task 1's change must not have bought its silence by switching checks off. Three assertions: a definite mismatch still flags, and the two Number-shaped consumers still behave as they did.

**Files:**
- Test: `test/staticlint/test_staticlint.jl` (append at end)

**Interfaces:**
- Consumes: `StaticLint._issubtype`, `StaticLint._has_type_intersection` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the tests**

```julia
@testitem "a definite mismatch still rules a call out" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    # Both operands fully resolved and provably disjoint: the check must still
    # flag, or the unknown-signal work would have bought its silence by
    # switching the type comparison off.
    cst, meta_dict, _ = parse_and_pass("""
    function outer()
        h(x::Int) = x
        return h("a string")
    end
    """)
    call = find_first(cst, x -> SL.iscall(x) && SL.valofid(SL.CSTParser.get_name(x)) == "h" &&
                                length(x.args) == 2)
    @test call !== nothing
    @test SL.errorof(call, meta_dict) === SL.IncorrectCallArgs
end

@testitem "iterating over a resolved type still reads its type" setup=[shared_static_lint] begin
    SL = JuliaWorkspaces.StaticLint

    # `check_incorrect_iter_spec` flags iterating over a Number, and reaches
    # `_issubtype` only through the last branch: a bound name whose type
    # resolved. Both directions must survive the three-valued return — a proven
    # Number still flags, a proven non-Number still does not. The error is set
    # on the RANGE SPEC (`i in x`), not on the `:for`.
    spec_error(src) = begin
        cst, meta_dict, _ = parse_and_pass(src)
        forx = find_first(cst, x -> SL.headof(x) === :for)
        @assert forx !== nothing && forx.args !== nothing
        SL.errorof(forx.args[1], meta_dict)
    end

    @test spec_error("x = 1\nfor i in x\nend\n") === SL.IncorrectIterSpec
    @test spec_error("x = \"s\"\nfor i in x\nend\n") === nothing
end
```

- [ ] **Step 2: Run them**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces";
    filter = ti -> occursin("definite mismatch still rules", ti.name) ||
                   occursin("unresolved iteration operand", ti.name), verbose = true)
```

Expected: PASS both.

`find_first(root::EXPR, f::Function)` is exported by the `shared_static_lint` testmodule — note the argument order, tree first. Do not hand-roll another tree walker.

- [ ] **Step 3: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add test/staticlint/test_staticlint.jl
git commit -F - <<'EOF'
test(staticlint): a definite mismatch still flags, an unknown one still does not

Floors under the two directions the unknown signal moves between: a call whose
operands are both resolved and disjoint is still ruled out, and an iteration
operand that resolves to no type is still not reported as a number.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 4: Full suite, and record what shipped

**Files:**
- Modify: `docs/superpowers/specs/2026-08-04-super-unknown-signal-design.md` (append a short "What shipped" section)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Run the whole suite in the background**

```
mcp__julia__julia_eval, env=…/environments/development, timeout 3600000:

using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; verbose = true)
```

Expected: PASS, except two known-benign complaints — a Runic formatting error from the dev environment, and a trailing "FooSetup is not defined". Anything else is a regression from this work.

- [ ] **Step 2: Record what shipped**

Append to the spec, filling in the real numbers from the runs (no placeholders — if a number is unknown, go get it):

```markdown
## What shipped

`_super` answers `nothing` on its catch-all and on both ignorance legs of the
`Binding` method; `_issubtype` and `_has_type_intersection` are three-valued with
a depth cap of 32; the six `match_method` sites and the message renderer act on a
definite `false`, and the two Number-shaped sites on a definite `true`.

Evidence: the false positive in the spec's opening is removed end to end
(`test/test_file_analysis.jl`), the three-valued mechanics are pinned by unit
tests, and the property test crosses <N> concrete types with <M> abstract bounds
— <checked> subtype pairs, none ruled out, <ruled_out> correct rule-outs.

Full suite: <result>. No diagnostic sweep was run, by decision; the coverage that
buys and the coverage it forgoes are stated under "The gate".
```

- [ ] **Step 3: Commit**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git add docs/superpowers/specs/2026-08-04-super-unknown-signal-design.md
git commit -F - <<'EOF'
docs: record what the unknown-supertype signal shipped as

The legs that changed, the depth cap, the direction each call site was given,
and the evidence: the end-to-end false positive, the three-valued unit tests and
the property test's counts.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

## Self-review

**Spec coverage.** Every section maps to a task: §Design/1 (`_super` legs) → Task 1 Step 5; §Design/2 (Kleene) → Task 1 Step 6; §Design/3 (depth cap) → Task 1 Step 6's `_MAX_SUPER_DEPTH`; §Design/4 (eight call sites) → Task 1 Steps 7–8; §Testing items 1–3 → Task 1 Step 3; item 4 (property test) → Task 2; item 5 (end-to-end) → Task 1 Step 1; item 6 (regression floor) → Task 3. §Residuals needs no task by construction — `FakeTypeofBottom` and the `Lo<:T<:Hi` miss are explicitly left alone, and Task 1 Step 5 names the legs not to touch.

**Placeholders.** The only angle-bracketed values are in Task 4 Step 2, where the instruction is to fill them from the runs and the step says so; no step defers a decision or omits code.

**Type consistency.** `_issubtype(a, b, store, meta_dict, depth=0)` is defined in Task 1 Step 6 and called with four arguments everywhere else, which the default covers. `_has_type_intersection` keeps its four-argument signature throughout. `_MAX_SUPER_DEPTH` is defined once and read once. The tests use `syms = env.symbols` / `get_env(jw).symbols` and `SL.getsymbols(env)` — both appear in the existing suite, and each test uses one consistently.
