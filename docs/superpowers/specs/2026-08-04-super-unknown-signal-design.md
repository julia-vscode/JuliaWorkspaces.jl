# `_super` must distinguish the top of the lattice from ignorance

*2026-08-04. Branch `sp/super-unknown-signal`, off `main` (`9ab7c24`).*

## The defect

`src/StaticLint/subtypes.jl` ends with `_super(_, _, _) = CoreTypes.Any`. An operand
the walk has no method for — a `TreeRef`, a bare `EXPR`, a store lookup that missed —
therefore reports its supertype **as `Any`**, and `_issubtype` treats reaching `Any`
as "the walk finished, and `b` was never found":

```julia
sup_a = _super(a, store, meta_dict)
_type_compare(sup_a, b) && return true
!_isany(sup_a) && return _issubtype(sup_a, b, store, meta_dict)
return false                      # ← also the answer for "no idea"
```

So "I ran out of information" and "there is no common ancestor" are one value, and
both callers of the pair predicate read that value as a definite verdict:
`_has_type_intersection` returns `false`, and `sig_match_any`/`match_method` rule the
method out. **The failure direction is a false positive on correct code**, which is
the one outcome a linter must not produce.

Three legs feed the hole without being the catch-all, and each is a real truncation
rather than a real answer:

- `_super(a::DataTypeStore, …)` returns `SymbolServer._lookup(a.super.name, store)`,
  which is `nothing` on a partial or missing store entry.
- `_super(a::FakeTypeName, …)` funnels such a miss straight into the catch-all.
- `_super(x::EXPR, …)` is already declared `::Union{EXPR,Nothing}` and answers
  `nothing` for a shape that declares no supertype.

All three are coerced to `Any` one frame later, so the distinction the type system
already carries is thrown away at the boundary.

## What it costs today, on this `main`

`main` (`9ab7c24`) has the local-path method matching and slice 1.4's type join, but
**not** the §17 signature records — there is no cross-file parameter-type operand yet.
The immediate cost is therefore local: a workspace type whose supertype chain leaves
resolvable territory is judged as having no common ancestor. `_super(b::Binding, …)`
ends at `refof(sup)`, which for a supertype declared in a sibling file is a `TreeRef`,
hence the catch-all — so `struct Own <: MyAbs` here, `abstract type MyAbs <: Integer`
next door, passed to `f(::MyAbs)`, is a genuine subtype the check rules out.

The larger reason to do it first: every consumer of a workspace type's ancestry has to
be guarded against this hole rather than being allowed to use it. That is why the
cross-file work is blocked, and why it is blocked on a contract, not on data.

## The design

### 1. `nothing` means "out of information"

`_super` answers `nothing` where it has no information, and a type only where it has
one. Two edits:

- `_super(_, _, _) = nothing` — the catch-all.
- `_super(b::Binding, …)` — both `store[:Core][:Any]` returns become `nothing`: the
  leg where `b.type` is not known to be a datatype, and the leg where the supertype
  expression carries no ref.

The three legs above need no edit; they stop being coerced.

Unchanged, because they are lattice steps rather than ignorance:

| leg | answer | why |
|---|---|---|
| `FakeTypeVar` | `.ub` | a variable's bound is its supertype |
| `FakeUnionAll` | `.body` | unwrapping, not climbing |
| `FakeUnion` | `Any` | a union's supertype genuinely is `Any` |
| `FakeTypeofVararg` | `Any` | as before |
| `FakeTypeofBottom` | `Any` | **wrong, and left alone** — see residuals |

### 2. Kleene propagation

`_issubtype` returns `Union{Bool,Nothing}`. The load-bearing invariant: **`false` is
returned only when every step of the walk was definite.**

```julia
function _issubtype(a, b, store, meta_dict, depth=0)
    _isany(b) && return true
    _type_compare(a, b) && return true
    depth >= _MAX_SUPER_DEPTH && return nothing
    sup_a = _super(a, store, meta_dict)
    sup_a === nothing && return nothing        # out of information
    _type_compare(sup_a, b) && return true
    _isany(sup_a) && return false              # reached the top: definite
    return _issubtype(sup_a, b, store, meta_dict, depth + 1)
end
```

`_has_type_intersection` propagates the same way: the bare-`Union` short-circuit still
answers `true`; `true` if either direction is `true`; `nothing` if either is `nothing`;
`false` only when both directions are definitely `false`.

### 3. A depth cap

`_super(b::Binding, …)` can hand back another `Binding`, so a mid-edit
`struct A <: B` / `struct B <: A` recurses without bound — a stack overflow in the
language-server process. This predates the change (unknown-stopping makes it strictly
rarer, not commoner), but the recursion is being rewritten here, so it gets a guard:
`_MAX_SUPER_DEPTH = 32`, matching `_ancestry`'s existing cap, exceeded ⇒ `nothing`.
A named const so raising it to 128 is one line if a real hierarchy ever needs it;
Base's deepest chains run to single digits.

### 4. The call sites

Eight, all inside this package; nothing outside JuliaWorkspaces calls these.

| site | change | behaviour |
|---|---|---|
| `methodmatching.jl:285,288,295` (`match_method(…::MethodStore…)`) | `… === false && return false` | **changes**: unknown no longer rules a store method out |
| `methodmatching.jl:408,411,430` (`match_method(…::EXPR…)`) | as above | **changes**: same, for a workspace signature |
| `checks.jl:785` (`describe_call_mismatch`) | name a slot only on `=== false` | **changes**: header-only rather than naming an unprovable slot |
| `checks.jl:884` (`check_incorrect_iter_spec`) | `=== true` | identical: it only ever acted on `true` |
| `type_inf.jl:590,637` (scalar-index, number tests) | `=== true` | identical: same reason |
| `type_inf.jl:420` (`_ancestry`) | none | already breaks on `nothing`; the join widens to `Any` |

The three-valued return is deliberately not hidden behind a Bool wrapper: an
unhandled site throws `TypeError` on `nothing` in a boolean context, which is loud,
whereas silent coercion is precisely the defect being fixed.

## Testing

Unit tests only, by decision (2026-08-04). New testitems beside the existing `_super`
one in `test/staticlint/test_staticlint.jl`, and the end-to-end in
`test/test_file_analysis.jl`:

1. **`_super` answers `nothing`** for an operand it has no method for, and for a
   `Binding` whose supertype expression carries no ref — the two edited legs.
2. **`_issubtype` is three-valued**: `nothing` on a chain that truncates, `false` on
   one that genuinely reaches `Any`, `true` where it already held.
3. **`_has_type_intersection`**: the 3×3 Kleene table, including that one unknown
   direction plus one `true` direction is `true`.
4. **A ported property test.** The type-aware branch pins the rule-out check against
   Julia's own `<:` over a table of concrete types × abstract bounds; that version
   resolves its operands through `_resolve_param_types`, which does not exist here, so
   the port looks the names up in the store directly. For every pair where `<:` holds
   the result must not be `false`, with floors under both the subtype-pair count and
   the rule-out count so a table that stops producing pairs fails loudly instead of
   passing on nothing.
5. **The false positive this removes**, end to end: `struct Own <: MyAbs` in the
   calling file, `abstract type MyAbs <: Integer` in a sibling, passed to `f(::MyAbs)`.
   Asserted through `derived_file_analysis(…).meta` — never
   `derived_static_lint_meta_for_root`, which is the old per-root path and does not see
   anything wired through visibility.
6. **A regression floor**: a definite mismatch (`f(x::Int)` called with a `String`)
   still flags, so the fix cannot pass by switching the check off.

### The gate, and what it does not cover

Accepted residual: unlike the `Vararg` arity fix, this change **can** move real
diagnostics — it removes rule-outs on the local method-matching path — and unit tests
show the classes predicted above without showing that nothing else moved. The
74-root both-direction sweep (`docs/perf/typesweep.jl`) that would show it lives on
the type-aware branch and is not being ported. The property test in (4) is the
substitute: it is the false-positive direction, decided by the language rather than by
an expectation that can drift.

## Residuals, recorded rather than fixed

- **`FakeTypeofBottom` still reports `Any`.** `Union{}` is a subtype of everything, so
  the honest answer is neither `Any` nor `nothing`. Pre-existing, unrelated to the
  contract change, and it would need a `_issubtype` special case rather than a `_super`
  one.
- **The cross-file operand itself.** This spec makes ignorance visible; it does not
  make a sibling file's supertype *known*. That needs the supertype recorded on
  `InventoryItem` as a parameters-dropped head, a per-`(module, name)` projection, and
  a tree-backed operand reaching `subtypes.jl` as a closure — the next slice, now
  unblocked.
- **The `Lo<:T<:Hi` local-path miss** (no binding for the middle identifier of a
  `:comparison`) is upstream of everything here and unaffected.

## Rejected alternatives

- **Bool-only, tri-state kept internal** — `_issubtype` meaning "provably a subtype"
  plus a new `_definitely_disjoint`. Smallest diff, no `TypeError` risk, and the
  conflation it keeps is the safe one. Rejected because it hides the distinction from
  the next caller, and the next caller is the cross-file ancestry work whose whole
  problem is that distinction.
- **An explicit trilean enum.** Self-documenting, but a new vocabulary type in a file
  that otherwise traffics only in store values, for no gain over `nothing` once every
  site handles it explicitly.

## What shipped

`_super` answers `nothing` on its catch-all and on both ignorance legs of the
`Binding` method; `_issubtype` and `_has_type_intersection` are three-valued with
a depth cap of 32; the six `match_method` sites and the message renderer act on a
definite `false`, and the two Number-shaped sites on a definite `true`.

Evidence: the false positive in the spec's opening is removed end to end
(`test/test_file_analysis.jl`), the three-valued mechanics are pinned by unit
tests, and the property test crosses 18 concrete types with 16 abstract bounds
— 34 subtype pairs, none ruled out, 254 correct rule-outs.

Full suite: 5990 passed, 0 failed, 7 broken (pre-existing `@test_broken`
assertions, unrelated to this change), 1 errored — the dev environment's Runic
formatting check, which cannot load the `Runic` package outside `Pkg.test`. The
run also ends with a non-zero exit from `TestItemRunner`'s trailing "Test setup
FooSetup is not defined" complaint, raised by a testdata fixture that
deliberately declares a setup with no matching `@testsetup`; both are known-benign
and neither is a regression. No diagnostic sweep was run, by decision; the
coverage that buys and the coverage it forgoes are stated under "The gate".
