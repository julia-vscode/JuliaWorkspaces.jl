# Cross-file method checks for workspace functions (2026-07-18)

Design for #9: make the method-set lints (`IncorrectCallArgs` / `FunctionHasNoMethods`)
behave the same for a call regardless of where the callee is defined — Base,
package, or the current project. Today they silently skip calls to
**module-level project functions**.

## Current behavior (verified)

```
# module-level `f(x)=x`, call `f(1, 2)`:
PER-FILE  (live LS)   errorof(f(1,2)) = nothing            # not flagged
WHOLE-FILE (old path) errorof(f(1,2)) = IncorrectCallArgs  # flagged
```

`check_call` (`StaticLint/linting/checks.jl`) has an explicit early return — the
`tree_visible` gate — for a `Binding` callee whose name is visible through the
module tree:

```julia
if tree_visible !== nothing && func_ref isa Binding
    n = valofid(get_name(x)); n !== nothing && tree_visible(n, x) && return
end
```

`FunctionHasNoMethods` is gated the same way. Store-backed callees (Base/stdlib/
package `FunctionStore`s) are NOT gated — they carry their full method set in the
env — so they are fully checked (and, since #6, so are workspace overloads of
them).

### Why the gate exists

The per-file/inventory architecture's core invariant: **`derived_file_analysis(root, file)`
does not depend on the analysis of any *other* file.** Editing file B must not
re-run file A's analysis (this is what made the LS incremental for large / many-env
workspaces). `check_call`'s local `func_ref` therefore only holds the methods
*this file* defines (`func_ref.refs`); methods of the same function in sibling
files are invisible. Checking a call against that partial set would false-flag a
call that actually matches a sibling method — so the gate declines instead.

Everything else already has cross-file parity through the inventory/tree layer
(hover, go-to-definition, references, completions materialize sibling items at
request time). The gap is specifically the method-set **lints**, because they
need each candidate method's **argument arity and types**, and types need the
sibling's *resolved* signature.

## The split: arity is cheap, types are expensive

- **Argument count** of a method (min/max positional, keyword names, splat) is a
  syntactic property extractable per-file from the CST — `func_nargs(::EXPR)`
  already computes exactly this. It is integers + symbols: **structurally
  comparable**, so a derived query over it backdates cleanly, and it needs **no
  sibling analysis** (only the inventory).

- **Argument types** need each sibling method's arg declarations *resolved* to
  types (through that file's imports/scope) — i.e. that sibling's semantic
  analysis. Pulling that into the per-file pass reintroduces file→file analysis
  dependencies: mutual references (`A` calls `f` in `B`, `B` calls `g` in `A`)
  cycle, and unrelated edits cascade — exactly what the refactor removed.

So the two halves want different treatment.

## Part A — argument-count parity, always on

Achievable now, safe, incremental, zero false positives.

1. **Inventory arity.** Extend `InventoryItem` (or a parallel per-file query)
   with the structured arity of each `:function`/`:macro`/`:struct` method:
   `(minargs, maxargs, kws::Vector{Symbol}, kwsplat::Bool)`, computed from the
   defining EXPR via `StaticLint.func_nargs` / `struct_nargs` at inventory-build
   time. No env/meta available there → macro-wrapped defs fall back to
   `(0, typemax, [], true)` (permissive), so never a false positive. Purely
   per-file, plain data.

2. **Cross-file aggregation.** A derived query
   `derived_method_arities(rt, root, path, name) -> Vector{ArityTuple}` — the
   arities of every method of `name` at module `path`, in the same splice walk as
   `derived_method_items` (tree + inventories only, **no file analyses**). Stable
   value ⇒ dependents backdate on unrelated edits.

3. **Check.** For a call whose callee is a tree-visible workspace function
   (currently declined), instead of declining: gather the cross-file arities and
   compare against the call's `call_nargs` via the existing `compare_f_call`
   arity logic. Match none ⇒ `IncorrectCallArgs`; empty (and not a bare
   `function f end` forward decl) ⇒ `FunctionHasNoMethods`. Match some ⇒ still
   decline the *type* check (Part B).

   Wiring: thread a `tree_arities = (name, x) -> Vector{ArityTuple}` closure
   (built in `derived_file_analysis`, like `tree_visible`/`tree_extended`) into
   `check_all`/`check_call`. `describe_call_mismatch` (#8) must use the same
   cross-file arities for its "Expected N, got M" clause so the message matches
   the decision.

Soundness: arity is exact and aggregated over ALL methods ⇒ a call is flagged
only when no method anywhere accepts that count. Incrementality: unchanged (no
sibling-analysis dependency introduced).

## Part B — positional-type parity, on save (the proposed approach)

**Is "arg-count always, type-check only on file save" feasible? Yes.** The LS
already has every needed piece: a `textDocument/didSave` handler
(`requests/textdocument.jl`), push diagnostics (`publishDiagnostics`), and
`workspace/diagnostic/refresh` (client re-pull), gated on the client's
`refreshSupport` capability (recorded at init).

Design:

1. **A save-gated cross-file type check.** A derived query,
   e.g. `derived_call_type_diagnostics(rt, root, file)`, that — for each call
   `check_call` declined and Part A left type-unchecked — gathers the callee's
   method items (`derived_method_items`), materializes each one's signature EXPR
   (`derived_item_positions`) and its **own** file meta
   (`derived_file_analysis(rt, qroot, item.file).meta`), and runs
   `match_method(call_args, call_kws, method_expr, store, method_meta)`. No match
   ⇒ a type-mismatch diagnostic (reusing `describe_call_mismatch`). This is the
   same materialization hover/go-to-def already do.

2. **Why this is cycle-free.** The query lives OUTSIDE `derived_file_analysis`
   (it is a top-level diagnostic query, which nothing else depends on). So
   `derived_file_analysis(A)` never depends on this query, and the query
   depending on `derived_file_analysis(B)` cannot form a cycle even under mutual
   references — `derived_diagnostics(A) → derived_file_analysis(B)` and
   `derived_diagnostics(B) → derived_file_analysis(A)` are two independent DAG
   edges, not a cycle.

3. **Why "on save" contains the cost.** A Salsa derived query is only computed
   when *requested*. If `derived_call_type_diagnostics` is requested **only from
   the `didSave` handler** (not from the live `derived_diagnostics` pull path),
   it never runs on keystrokes. On save it recomputes only if a dependency
   actually changed since the last save (materialized sibling metas backdate when
   a sibling's edit didn't change the relevant signature). Between saves the live
   diagnostics (syntax, Part-A arity, store-function checks) update normally; the
   type set is simply not refreshed.

4. **Delivery.** On `didSave`: evaluate `derived_call_type_diagnostics` for the
   saved file (and, optionally, open dependents), cache the result on the server
   keyed by URI, and either (a) `publishDiagnostics` the merged set, or (b) send
   `workspace/diagnostic/refresh` and have the pull handler
   (`textDocument_diagnostic_request`) merge the cached save-time type set with
   the live set. (b) fits the current pull model better; (a) is simpler but mixes
   push/pull. The cached type set is cleared/replaced on the next save of a file
   it depends on.

5. **UX.** Argument-count and all existing errors stay live; positional-type
   errors for project functions appear/refresh on save. This is a familiar model
   (many linters are save-triggered) and a deliberate, documented tradeoff.

### Open questions for Part B
- **Backdating inside the save query.** Materializing via `derived_file_analysis`
  gives SymbolServer types, whose equality is identity, not structural — so the
  query's *value* (if it stored types) wouldn't backdate. Mitigation: the query's
  value is the *diagnostics* (plain strings/ranges), which ARE structurally
  comparable; the type resolution happens inside and isn't part of the value. So
  backdating keys on the diagnostic set, which is fine.
- **Which files to refresh on save.** Saving B should refresh the type
  diagnostics of open files that call B's functions. Either refresh all open
  files (simple) or track a callee→caller index (precise). Start simple.
- **Dependent-file invalidation vs "on save".** If A is open and unsaved while B
  is saved, should A's type errors update? Keep it simple: refresh on the save of
  *any* file; A's cached set updates at its own next save or a global refresh.

## Alternative considered (rejected)

Route the method-set lints through the surviving whole-file pass
(`derived_static_lint_diagnostics_for_root`), which already checks cross-file
correctly. Rejected: that is the perf-heavy whole-closure path the per-file mode
replaced; using it live reintroduces the invalidation cost for every keystroke.

## Recommended phasing

1. **Part A now** — arg-count parity, always on. Small, safe, closes the most
   visible part of the gap (your `f(1, 2)` case) with the #8 detailed message.
2. **Part B next** — save-gated positional-type parity, per the design above.

## Testing
- Part A: `f(x)=x` (defined in sibling) called `f(1,2)` in another file ⇒
  flagged with "Expected 1 argument, got 2"; a call matching a sibling method's
  arity ⇒ not flagged (no false positive); `function f end` + `f(1)` ⇒
  `FunctionHasNoMethods` only when no real method exists anywhere.
- Part B: a `didSave` drives a positional-type diagnostic for a cross-file call;
  a keystroke (didChange) does NOT recompute it; correct call ⇒ none.
- Incrementality guard: editing an unrelated sibling does not re-run a file's
  Part-A analysis (assert via the tracing receiver used in `test_file_analysis.jl`).
