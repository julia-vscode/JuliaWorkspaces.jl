# Cross-file method matching and type analysis: design spec

*2026-08-04. The design for the goals fixed in
[2026-08-04-cross-file-type-parity-goals.md](2026-08-04-cross-file-type-parity-goals.md).
That document's invariants, non-goals and success criteria are binding here and
are not restated except where a design decision depends on one.*

## Decisions this spec records

1. **The reference mode is store-style record comparison.** One canonical
   plain-data signature record and one comparison engine; the same-file EXPR
   path and the cross-file tree path lower into it, and the store path already
   has its shape. A mode that cannot produce a resolved record answers unknown,
   and unknown never flags.
2. **The record vocabulary is our own, not `FakeType*`.** In the store,
   `FakeTypeName.name` means an absolute, evaluated name; in a workspace record
   a type name is relative and unresolved until the leaf. Reusing the store
   vocabulary would put two resolution semantics in one type — the conflation
   invariant 2 of the goals doc forbids. The comparator may normalize a
   *resolved* workspace type into store shape internally, but stored records
   keep an honest "unresolved name path" type.
3. **Argument-side inference: constructor-call typing only.** A call whose
   callee resolves to a datatype types as that datatype, on every path. Broader
   inference (ternaries, field access, function return types) is explicitly
   deferred; see Follow-ups.
4. **The empty candidate set splits three ways** (see Verdict semantics): a
   definitely-empty method set flags `FunctionHasNoMethods`; an empty *record*
   set that might be an artifact stays silent.

## Data model

All new types are immutable plain data with explicit structural `==` and
`hash`, each covered by a test. No positions, ranges or URIs appear in any of
them: a method moved within or between files must produce an equal record.
Consumers that need the definition site go through the content-hashed
`InventoryItem.id`.

### Type expressions (`TypeExpr`)

A closed vocabulary covering the shape table of the goals doc:

- **`TypeRef(path)`** — a name as written, one segment per qualifier:
  `AbstractString` → `["AbstractString"]`, `Base.AbstractString` →
  `["Base", "AbstractString"]`. A parametric annotation lowers to its head
  (`Vector{Int}` → `["Vector"]`; comparing type arguments is a non-goal), and
  an inner `where` (`Vector{T} where T`) is its head.
- **`TypeUnionExpr(members)`** — `Union{…}`, member-wise `TypeExpr`s.
- **`TypeVarRef(name)`** — a reference to a `where`-bound variable of the same
  signature; resolves through the signature's own typevar table, never through
  module scope. The inventory reader lowers an identifier to `TypeVarRef` iff
  the signature's own `where` clause binds it; every other identifier is a
  `TypeRef`.
- **`UnknownType()`** — anything else, including every shape the reader cannot
  classify. Unknown compares as "no opinion", never as a mismatch.

`where` clauses are read exclusively by `where_var_and_bound`; only an upper
bound is recorded (a lower bound licenses nothing and lowers the variable to
`UnknownType`).

### `MethodSignature`

Per method, from the definition as written:

- `slots` — positional parameters in order: `(type::TypeExpr, optional::Bool)`.
  Optionality is alignment information only (invariant: optional/defaulted
  parameters are not a type opinion beyond their annotation). A dispatch-only
  `::T` is a slot like any other.
- `vararg` — `nothing`, or `(eltype::TypeExpr, count::Union{Nothing,Int})` for
  the trailing slot. Every spelling — `x...`, `::Vararg`, `::Vararg{T}`,
  `::Vararg{T,N}`, `::Base.Vararg` — is classified by the existing
  `is_explicit_vararg_decl` / `arg_decl_type` helpers, which remain the single
  reader for both the count side and the record side. A bound count `N` makes
  the arity contribution exact, as in the `MethodStore` path today.
- `typevars` — name → upper-bound `TypeExpr` for the method's `where` clause.
- `kws`, `kwsplat` — keyword names and splat flag, presence only, mirroring
  `MethodArity`.
- `defined_in` — the defining module's path, attached at *index* time (a file's
  inventory only knows its file-relative `parent_module`; the spliced module
  path is known to the index walk). Usually equal to the index key's module
  path, but not for qualified extensions (`Base.foo(x::MyT) = …` written in
  `MyPkg`): the record is keyed under the extension target, while its
  annotations must resolve in the module that wrote them.

Arity bounds (`minargs`/`maxargs`) are derivable from `slots` and `vararg`.
The engine uses them only to align slots within a candidate (a candidate whose
count cannot accept the call is skipped, not flagged); the count *verdict* —
`IncorrectCallArgs` on argument count — stays on the existing `MethodArity`
channel so the two opinions invalidate independently.

Struct items contribute constructor signatures (default outer constructor from
the fields, inner constructors as written) whose slots are all `UnknownType`:
fields are not a type opinion, so constructors can only ever rule out on
arity — through the same engine, not a special case.

A definition whose signature shape cannot be read (macro-wrapped in a way the
parser does not see through, malformed) contributes no `MethodSignature`;
instead it marks the name shape-unknown (next section).

### Datatype supertypes

Struct/mutable/abstract/primitive `InventoryItem`s gain
`supertype::TypeExpr` — the declared parent as written (`TypeRef` for
`<: Base.Number`); a declaration with *no* `<:` clause records `Any`
(`TypeRef(["Core", "Any"])`), which is syntactically certain, not unknown —
treating it as unknown would make every plain struct unrulable-out.
`UnknownType` only when the declaration is unreadable. This is the fact
that lets the ancestry walk leave the current file: today 55% of annotated
parameters name a workspace-declared type and are unreachable.

### The per-name method set

The per-root signature index maps `(module path, name)` to:

- `signatures::Set{MethodSignature}` — a `Set`, deliberately: equality is
  order-insensitive, so moving a method between files (which reorders the
  splice walk) produces an `==` value and backdates. Duplicate signatures
  collapse harmlessly; verdicts are `any`/`all` over candidates.
- `has_unknown_shapes::Bool` — some definition of this name has a shape the
  inventory could not read. While true, the set is an under-approximation: its
  emptiness proves nothing and its exhaustion licenses nothing.
- `has_forward_decl::Bool` — a bare `function f end` exists.

Anything user-facing that enumerates candidates sorts at the point of
rendering; `Set` iteration order is never allowed to reach a diagnostic string.

## Pipeline: what is computed when

**Stage 1 — per-file inventory, syntactic only.** `MethodSignature`s and
datatype supertypes are read off the CST during inventory construction, exactly
as `MethodArity` is today. No name is resolved; the node depends only on the
file's own syntax. This is invariant 3 of the goals doc: resolved types in the
inventory would make every inventory depend on the environment.

**Stage 2 — per-root signature index, still syntactic.** A sibling of
`derived_method_arities_index` in `layer_module_tree.jl`: one splice walk over
all inventories, keyed `(module path, name)`, qualified extensions routed
through the existing `_resolve_extension_qualifier`. Per-name answers come from
projection nodes over the one per-root node (per-name nodes computed directly
would each depend on every file in the root — the measured trap). The arity
index is left untouched: a type-only edit changes this index while the arity
index's value stays `==` and its consumers backdate (goals invariant 4).

**Stage 3 — resolution at the leaf, at check time.** Inside the per-file lint
pass, when a call is compared against a candidate record, each `TypeRef` is
resolved *then*: through `derived_module_visible_names` of the **defining**
module (`defined_in`), falling through to the env store for names that resolve
into dependencies. Whole maps are read, never per-name keys (measured: ~0 new
dependency edges per file at p50 vs 66 for per-name keying; ~229 ns per name).
Resolution yields a store value, a workspace datatype record, or unknown.

Module-level visible names plus the record's own `typevars` are sufficient
scope: a top-level method's annotations can only reference module-level names
and its own `where` variables, and module-level `const` aliases are themselves
inventory items the visible-names map serves. The richer `refof`-based
resolution is only needed for closures, which stay on the EXPR path.

StaticLint never touches Salsa directly: resolution reaches it the same way
`tree_arities` does today, as closures built in `layer_file_analysis.jl`
(`tree_signatures(name, x)` for candidate sets, `tree_resolve(typeref, defined_in)`
for leaf resolution). Dependency edges accrue to the per-file analysis frame
that installed the closures.

## The comparison engine

### One alignment engine over a signature descriptor

The unit that gets unified is not the per-slot type test — both existing paths
already share `_has_type_intersection` — but slot *alignment*: vararg padding,
optional-parameter ranges, keyword gating, splat handling, today implemented
separately in `match_method(::EXPR)` and `match_method(::MethodStore)` and
about to grow a third copy. Instead: a single descriptor
`(slot types, vararg, kws, kwsplat, arg-count range)` and one `match_method`
over it. Sources lower into the descriptor:

- a workspace `MethodSignature` *is* the descriptor;
- a `MethodStore` lowers trivially (`.sig` is already flat; its types are
  already-resolved store values);
- an EXPR lowers at comparison time (closures; whole-closure mode), resolving
  annotations through `refof` as today.

The existing `match_method` bodies dissolve into lowering plus the shared
engine, so the paths cannot disagree about what a vararg or an optional
parameter means. Whole-closure mode keeps its EXPR route but runs the same
engine; per-file remains the asserted surface (goals invariant 5).

### Per-slot comparison

`_has_type_intersection` / `_issubtype` / `_super` keep their tri-state
contract and depth cap, and gain methods for the new operands:

- `TypeRef` — resolved at the leaf (Stage 3), then compared as whatever it
  resolved to. Unresolved → `nothing`.
- workspace datatype record — `_super` answers its `supertype` `TypeExpr`,
  resolved the same way. The ancestry walk can now alternate tree→tree across
  files and cross tree→store (a workspace `struct MyS <: Number` continues into
  the store's `Number` chain); store→tree remains impossible and is not needed.
- `TypeVarRef` — its signature's recorded upper bound, or `nothing`.
- `TypeUnionExpr` — member-wise, as `FakeUnion` is handled today.
- `UnknownType` — `nothing`, always.

A `false` (the only verdict that can rule a method out) remains producible only
from `_type_compare` over two fully resolved operands. Constructor
`FunctionStore`s resolve through the existing
`resolves_to_datatype`/`get_eventual_datatype` before comparison.

### Verdict semantics

For a call with resolvable callee name and no splat, with candidate set =
workspace records for the name ∪ store methods where the callee has store
backing (same in-scope extension filter as today):

1. **Candidate set non-empty:** the call is fine if *any* candidate matches
   count and is not ruled out on types; `IncorrectCallArgs` only if *every*
   candidate was definitively ruled out. Any unknown — an unresolved operand,
   an unreadable shape, a truncated walk — keeps its candidate alive.
2. **Candidate set empty and definitely complete** (`signatures` empty,
   `has_forward_decl`, not `has_unknown_shapes`, no store backing):
   `FunctionHasNoMethods`. This restores parity with whole-closure mode, which
   already flags `function f end; f()`, and makes the verdict stable under
   moving the forward declaration to a sibling file.
3. **Candidate set empty otherwise** (shape-unknown definitions present, no
   root, name not enumerable): silence.

The count opinion is decided before and independently of the type opinion:
the arity phase of the gate consults `MethodArity` exactly as on `main`, and
everything that suppresses types (splat, macro-wrapped, no root) leaves it
untouched.

### `check_call` rewiring

The tree gate (`checks.jl:405`) keeps its entry condition, splat skip, and
arity phase. What changes:

- where the gate today `return`s unconditionally after an arity match, it
  proceeds to the type phase over `tree_signatures` candidates;
- the store-fallback arm (unqualified `import Base: show` bindings) becomes the
  general union: workspace records ∪ `iterate_over_ss_methods`, one engine;
- the blanket `tree_extended` decline (`checks.jl:457`) is replaced by matching
  against the same union — the partial-set problem it guarded against is gone
  once both halves of the set are available. The residual risk (extensions
  outside the root and outside every in-scope store) is exactly the risk the
  store path already accepts today: parity means the same risk everywhere.
- `_is_local_callee_binding` callees (closures, parameters) continue to the
  EXPR path, which now lowers into the shared engine.

## Constructor-call argument typing

`arg_type`'s non-method branch answers `Any` for every call expression, so
`f(Own())` carries no type and short-circuits every comparison — the largest
measured cause of argument-side unknowns. New rule, applied uniformly: a call
argument whose callee resolves to a datatype types as that datatype —

- same file / local: `refof` → `Binding` whose val defines a datatype, or a
  store `DataTypeStore`/`FunctionStore` via `get_eventual_datatype`;
- cross-file: a `TreeRef`/tree-visible name resolved through the same leaf
  resolution as parameter types (this also discharges the standing rule that
  every `refof`→type consumer must handle `TreeRef` rather than crash or guess);
- unresolvable callee: `Any`, as today.

This is one added branch in one place, but it has its own parity dimension —
the fixture matrix covers "argument is a constructor call" as a shape row, with
the constructed type living in each of the five placements.

## Backdating and equality rules

1. **No positions in records** (see Data model). Method moves are equality
   facts.
2. **Explicit `==`/`hash` per record type**, tested. The default `==` falls
   back to field-wise `===` and any `Vector` field silently breaks backdating
   without failing anything.
3. **Two indices, two channels.** Body-only edit → both backdate, nothing
   downstream runs. Type-only edit → signature index changes, arity answers
   backdate. Count-changing edit → both re-run. Budget: the arity index's
   measured 11–16 ms recompute and 468–1089 touched per-name nodes; the
   signature index must stay in that class.
4. **Order-independence by construction.** Per-name values are `Set`s;
   deterministic ordering is imposed only where text is rendered.

## Degradation map

- **No root / project-less:** no visible-names map → every `TypeRef` resolves
  unknown → type phase silent; arity phase silent (no index); store-callee
  checks work as today. Unchanged: project-less roots publish no static-lint
  diagnostics at all.
- **File that is its own root:** full pipeline over a one-file index. Its
  module-level callees now get type checks (today: arity only), same-file and
  cross-file verdicts identical by construction.
- **Splatted calls, macro-wrapped definitions, `eval` in scope:** exactly the
  per-shape permissive answers above; never a per-root or per-file switch
  (withholding at root granularity measured as pure cost in the first attempt).

## Testing

### The parity matrix

One fixture per shape row (the goals table plus a "constructor-call argument"
row), each with a matching call and a definitively-mismatching call, each
materialized in five placements:

| placement | path exercised |
|---|---|
| (a) closure callee | EXPR lowering |
| (b) same-file module-level callee | records, own file |
| (c) sibling-file callee | records, cross-file |
| (d) store callee | `MethodStore` lowering (synthetic store; pinned Base names where needed) |
| (e) store callee + workspace overload | union / mixed mode |

Assertions run through `derived_file_analysis`; each fixture also runs with no
root, expecting silence-or-same. A shape is done when all five placements
report identically; a shape without its row is not done.

### Anti-vacuity

Every parity fixture must be provably non-vacuous — the first attempt's
fixtures passed without reaching the comparison:

- a **test-mode recorder** installable in the engine counts comparisons and
  records, per rule-out, that both operands were resolved. Fixtures assert
  verdicts *and* that the comparison ran; a global test asserts no `false` was
  ever produced from an unresolved operand (success criterion 2, machine-checked).
  Production default is a no-op.
- **observed red phases**: each fixture is seen failing (or seen not reaching
  the comparison, via the recorder) before the slice that makes it pass. This
  is an execution-discipline requirement the implementation plan must carry.

### Property test

The existing pin of `_issubtype` against Julia's real `<:` gains a record arm:
the same generated type pairs, expressed as workspace records resolved through
a synthetic module, must produce the same tri-state verdicts as their store
expression. Tree-side and store-side resolution are thereby pinned to each
other, not only each to Julia.

### Corpus sweep and incremental arm

- The sweep harness under `docs/perf/` runs the real-root corpus on `main` and
  on the branch. Every new diagnostic is classified (true positives only are
  acceptable); every disappeared diagnostic is explained. Counts do not gate.
- On a real root: a type-only edit, a count-changing edit, and a body-only
  edit, each re-collected incrementally and compared against a from-cold
  rebuild of the same state. Direct backdating assertions: after the type-only
  edit the per-name arity value is `==`; after a between-files method move the
  per-name signature `Set` is `==` and the diagnostic set unchanged (success
  criterion 5, tested directly).
- A fixture with two same-name methods split across files in both file orders
  guards verdict order-independence against future short-circuiting.

## Implementation staging

Vertical slices by shape, not layers: each slice extends the records, index,
engine and gate just enough to turn one parity row green end-to-end, red phase
observed first. Suggested order: bare identifier → qualified name → parametric
head → `Union` → `where` bounds → `Vararg` spellings → optional/defaulted →
keywords → struct constructors → macro-wrapped (permissive row) → dispatch-only
`::T` → constructor-call argument typing → `FunctionHasNoMethods`
completeness. The first slice carries the infrastructure (record types, index,
projections, closures, engine skeleton, recorder); every later slice should be
mostly vocabulary and fixtures.

## Follow-ups deliberately out of scope

- **Broader argument-side inference** (ternaries, field access, function return
  types, flow-sensitive narrowing): measured as the binding constraint on
  yield (argument type known in only 11.5% of compared slots), but each is its
  own parity surface and none is needed to prove the machinery. Revisit after
  the corpus sweep quantifies what constructor-call typing alone recovers.
- **Type-argument comparison, keyword type checking, the inverse type→methods
  index** — non-goals per the goals doc.
- **Store→tree ancestry** (a store type whose supertype is a workspace type)
  cannot occur in valid Julia environments and is not modeled.
