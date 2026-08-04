# Cross-file method matching and type analysis: what a fresh implementation must achieve

*2026-08-04. A goal document, not a design and not a plan: it fixes what "done"
means so the design can be argued about on its merits. Written after a first
attempt that is not being merged, and after the `_super` unknown-signal fix,
which is.*

## The goal, in one sentence

**A call is judged the same way whether the methods it might match live in this
file, in a sibling file of the same root, or in a dependency's store — and every
deviation from that is a deliberate, recorded decision rather than an accident of
which code path ran.**

## Why parity, and not "more type checking"

The first attempt aimed at coverage: teach the cross-file path to compare
parameter types, since it only compared argument counts. It worked, it was
correct, and over 74 real roots it ruled out **one** call site — which turned out
to be a false positive that a later slice removed. Its measured yield was
therefore approximately zero.

That is not an argument for abandoning the work. It is an argument that coverage
was the wrong thing to measure, because the defect users actually meet is not "a
missed error" but **instability**:

- moving a method from one file to another changes a diagnostic;
- a call flagged in single-file mode goes quiet once a root is indexed;
- the same source reports differently depending on whether the callee's file has
  been analysed yet.

Each of those is a parity break, each is reachable in ordinary editing, and each
teaches the user to distrust the whole diagnostic channel. A checker that
under-reports uniformly is usable; one that changes its mind as files move is
not. So: parity is the goal, and any coverage gained is a side effect of removing
the special cases that broke parity.

## The modes that must agree

1. **Same-file** — the callee's methods are local `Binding`s / definition `EXPR`s;
   `sig_match_any` → `match_method(…::EXPR…)`.
2. **Cross-file, same root** — the callee's method set spans sibling files and is
   known only through the module tree, as plain-data records.
3. **Store** — the callee is a dependency's function; `iterate_over_ss_methods` →
   `match_method(…::MethodStore…)`.
4. **Mixed** — a store function extended by the workspace, or a workspace name
   imported and extended. These are where the first attempt spent most of its
   special cases.

Orthogonally, **single-file mode and env mode** must agree: a file analysed with
no root and no module tree must not report differently from the same file
analysed as part of its package, except where the missing information makes a
verdict genuinely unavailable — and then the answer is silence, not a different
verdict.

## Invariants a fresh implementation may not break

1. **Unknown never flags.** A resolved type may only ever *remove* a diagnostic.
   Every unknown — an unresolved name, a truncated supertype walk, a partial
   method set, an unparsed sibling — must reach the permissive answer.
2. **A negative verdict requires that every step was definite.** This is now
   enforced at the primitive: `_super` answers `nothing` for "no information",
   and `_issubtype`/`_has_type_intersection` return `nothing` rather than `false`
   when anything was unknown. Nothing built on top may reintroduce the
   conflation.
3. **Plain data in the cache; resolution at the leaf.** The per-file inventory
   must not gain a dependency on the environment. This is a dependency-graph
   constraint, not an equality one: resolved types in the inventory would make
   every file's inventory depend on the env, so adding one dependency or
   precompiling one package would invalidate every inventory, module tree and
   index in the workspace.
4. **The count opinion and the type opinion are gated separately.** Whatever
   suppresses types must leave arities intact, and a type-only edit
   (`f(x::Int)` → `f(x::String)`) must leave the count answer equal so its
   consumers backdate.
5. **Lint behaviour is asserted through the per-file pass**
   (`derived_file_analysis(...)`), never the whole-closure per-root query, which
   does not see anything wired through visibility.

## What parity concretely requires

The unit of work is a *type-expression shape*, and each shape is done when all
four modes give the same verdict for it. This list is the acceptance surface:

| shape | notes |
|---|---|
| bare identifier | 83.1% of annotated parameters in the corpus |
| qualified name (`Base.AbstractString`) | 4.7% |
| parametric (`Vector{Int}`) | 11.1%; head only — see non-goals |
| `Union{…}` | member-wise |
| `where`-bound type variable | upper bound only; a lower bound licenses nothing |
| inner `where` in an annotation (`Vector{T} where T`) | is its head |
| every `Vararg` spelling | bound, anonymous (`::Vararg`), dotted (`::Base.Vararg`) |
| optional / defaulted parameters | alignment, not types |
| keywords | presence only — see non-goals |
| struct constructors | fields are not a type opinion |
| macro-wrapped definitions | shape unknown ⇒ permissive |
| dispatch-only `::T` | binds no name, still types a slot |

## Terrain already measured — do not re-derive

- **Resolution is cheap.** Reading the defining module's *whole* visible-names
  map adds 0 new dependency edges per file (p50 0 / max 2 over 1056 (root, file)
  pairs); keying it per name costs 66 edges for the same file. ~229 ns per name;
  the entire argument-resolution leg of a cold whole-repo build is 14.4 ms.
- **Where parameter types point:** 55% of this package's annotated parameters
  name a workspace-declared type, 35% Base/Core, 9.6% a dependency. The
  workspace-declared majority is unreachable until a supertype is recorded and
  the ancestry walk can cross from tree into store.
- **The argument side is the binding constraint.** Of 93 220 argument slots at
  compared call sites: parameter type known 4.6%, argument type known 11.5%, both
  1.4%. Parameter-side unknowns are mostly facts about the source (no
  annotation). Argument-side unknowns are inference gaps — fixable.
- **`arg_type`'s non-method branch answers `Any` for anything that is not a
  reference, a literal, an array literal or a quoted symbol.** A constructor call
  (`f(Own())`) therefore carries no type at all. This single fall-through is the
  largest identified cause of the 11.5%.
- **Equality of store values:** the `FakeType*` family has explicit `==`
  (`shared/symbolserver/faketypes.jl`); the `…Store` types do not, but they are
  looked up from a `ModuleStore`'s `vals` rather than constructed, so identity is
  stable within an environment — which is what backdating needs. Deep equality is
  not required, and would cost ~5 ms per `ModuleStore` against ~16 µs for
  identity.
- **Index cost:** a per-root signature index recomputes in 11–16 ms on a
  declaration-changing edit and invalidates 468–1089 per-name nodes. Per-name
  nodes must project from one per-root node; computed per name, each would depend
  on every file in the root.

## Success criteria

1. **A parity matrix, as tests.** One fixture per shape in the table above,
   asserted in all four modes, requiring identical diagnostics. This is the
   deliverable that distinguishes this attempt from the last one; a shape without
   a parity test is not done.
2. **Every rule-out has both operands resolved.** Assertable directly, and it is
   the machine-checkable form of invariant 1.
3. **A real-corpus sweep, both directions.** New diagnostics are acceptable only
   if each is a true positive; disappearing diagnostics must each be explained.
   The count alone proves nothing.
4. **An incremental arm, not only cold builds.** No from-cold comparison can
   observe a backdating defect. A type-only edit, a count-changing edit and a
   body-only edit, each re-collected and compared against a from-cold rebuild of
   the same state.
5. **Moving a method between files changes no diagnostic.** The most direct
   statement of the goal, and cheap to test on a real root.

## Non-goals

- **Comparing type arguments.** `Vector{Int}` and `Vector{String}` both resolve
  to `Vector` on every path. Making one path finer would itself break parity.
- **Keyword type checking.** Presence and splat only.
- **Flow-sensitive inference.** A rebound local settles on the join of its
  assignments; a dominance test that recovers the narrow type where the rebinding
  dominates its uses is a separate, later question.
- **The inverse type→methods index.** Different cost profile, and it needs the
  ancestor chain enumerated rather than a pair predicate.
- **Coverage for its own sake.** A shape that cannot be made to agree across
  modes should answer "unknown" in all of them rather than be handled well in one.

## Traps from the first attempt

Recorded because each cost real time and none is discoverable from the code:

- **A fixture can pass before the fix and prove nothing.** `f(Own())` types as
  `Any`; the argument must be a typed parameter to reach the comparison at all.
  Every red phase must be observed, not assumed.
- **A tree-visible callee never reaches the type comparison** — the arity gate
  answers and returns. Fixtures for the local path need a closure callee.
- **Sample code in a plan is where defects hide.** Of the defects found while
  executing the last plan, all but one were in the plan's own code blocks.
- **A `@testitem` body is evaluated at module scope**, so assigning to an outer
  name inside a `for` is an ambiguous soft-scope assignment; and `return` does not
  skip a testitem body.
- **Withholding is expensive in coverage.** Blanking every type in a root because
  one file calls `eval` disabled three roots entirely and prevented four
  diagnostics, all of which were false positives with unrelated causes. Prefer a
  narrow consumer-side decline to a whole-root switch.
- **Backdating hazards are structural, not obvious:** empty ranges compare equal
  regardless of position; a record that is deliberately coarse is only safe if
  every answer derived from it is equally coarse.

## What to salvage rather than rebuild

Verify each against `main` before relying on it — some of these shipped
independently of the abandoned branch and some did not:

- the three-valued `_super` / `_issubtype` / `_has_type_intersection` contract,
  and its depth cap;
- `where_var_and_bound` as the single reader of the `where`-clause grammar, so the
  local and cross-file paths cannot disagree about what a bound is;
- the `Vararg`-spelling helpers (`is_explicit_vararg_decl`, `arg_decl_type`), and
  the rule that the count side and the record side must route through the same one;
- the sweep harness and the resolution-cost harness under `docs/perf/`;
- the property test that pins the rule-out check against Julia's own `<:`.

## The first question a design must answer

Not "how do we record types" — that is settled well enough by the last attempt —
but **which of the four modes is the reference**, and what happens to the other
three when they cannot reach it. Parity is cheap to achieve by making every mode
equally ignorant; it is worth having only if the reference mode is the most
informed one that can be made available everywhere.
