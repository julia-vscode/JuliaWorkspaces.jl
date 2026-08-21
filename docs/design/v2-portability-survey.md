# v2 portability survey: rules and feature layers

*2026-08-20. A point-in-time classification of everything the v1 stack does,
by what a port to the v2 (JuliaLowering-backed) stack would take. Produced to
answer "what should move next" after DJP-side macro expansion landed; the
"Harvest JuliaLowering" milestone implemented the items marked ✅ below.*

v2 capabilities the classes are scored against: per-item lowering through
`rebase_layers → expand_forms_1 → expand_forms_2 → resolve_scopes` (no
`binding_analysis`/`closure_conversion`/`linear_ir`, hence **no CFG**); real
macro expansion via the DJP child (flag-gated) spliced into materialization;
position-free bindings/uses in source-preorder addresses; the v2 module tree
(env-free); **no** environment/SymbolServer seam, **no** cross-file visibility
layer, **no** type information.

## 1. Lint rules (all 35), classified

Classes: **A** portable now · **B** modest additions · **C** blocked on the
env/SymbolServer seam · **D** blocked on CFG/flow · **E** no port needed.

### A — portable now (~35–45% of semantic finding volume)

| rule | status |
| --- | --- |
| `unused_binding`, `unused_function_argument` | ✅ ported (pre-milestone). v2 needed none of v1's six false-positive suppressors — real scoping (`is_captured`, per-binding reads) replaces them. |
| `unused_type_parameter` | ✅ this milestone. A `where` param mints a `:typevar` (signature reads) + `:static_parameter` (body reads) pair at one address; unused ⇔ both unread. Struct/alias params lower as `:local` — not covered, matching v1's where-only semantics. |
| `duplicate_function_argument` | ✅ this milestone — superseded: under the flag v1's syntactic check is suppressed and the shapes report as `lowering_errors:error` (the lowering is ground truth; the v1 id keeps `:information` for flag-off users). |
| `break_continue` | ✅ this milestone — superseded like the above. More precise than v1 (labeled break; actual loop scope rather than any enclosing `for`/`while`). |
| `global_const_decl` | ✅ this milestone — superseded like the above. (`TypeDeclOnGlobalVariable` is dead on Julia ≥ 1.8.) |
| `pointless_boolean`, `literal_use`, `NotEqDef` half of `type_piracy`, most of `const_if_condition` | pure shape; portable any time (some arguably belong in the syntax tier). |

### B — modest additions (~10%)

| rule | what it needs |
| --- | --- |
| `module_name`, `relative_import` | ✅ this milestone — v2 module tree + splice prefix only. `module_name` is a mild superset of v1 (catches the cross-file splice-point parent). |
| `nothing_comparison` | shape after lowering; a shadowing local shows up as a `BindingId` use, so the shape check is self-resolving. |
| `index_from_length` (conservative) | "is `length` shadowed locally / defined in this module" via module-tree names. Loses v1's `isarray` exemption (no types). |
| `const_decl` (intra-module) | a per-name kind/const table on the module tree; lowering already reports same-scope conflicts within one item. |
| `incorrect_iter_spec` (literal arm) | shape only. |

### C — blocked on the environment/SymbolServer seam (~45–55%, the user-visible majority)

`missing_reference`, `unresolved_import` (the only two `:warning`-by-default
StaticLint rules), `incorrect_call_args` (external method table),
`invalid_type_declaration`, `kw_default_mismatch`, `type_piracy`, the strict
versions of `incorrect_iter_spec`/`index_from_length`. Unreachable until v2
gets a visibility layer + env seam; shipping them env-free would be a
false-positive machine.

### D — blocked on CFG: effectively nothing

No current rule needs it. v1 approximates flow with syntactic hacks
(`is_overwritten_in_loop` et al.) that v2's real scoping makes unnecessary. A
future use-before-definition rule IS CFG-bound: `is_used_undef` is never
computed by the passes v2 runs (it is a closure-conversion internal), and
source order alone false-positives on `while cond; x = f(x); end` shapes. A
narrow straight-line variant would be sound but requires dropping the
fallback-read union first (see §3 of the feature survey).

### E — no port needed (13 rules)

The six syntax-tier rules, `include_errors` (v2 has its own include edges),
`syntax_errors`/`syntax_warnings`/`testitem_errors` (done), and the four
TOML/config/environment rules.

## 2. New checks only JuliaLowering enables

- ✅ **`lowering_errors`** (this milestone): the LoweringError catalog —
  ~131 validation/desugaring/scope checks (invalid assignment targets,
  malformed signatures, duplicate struct fields, `new{...}` arity,
  write-only-underscore reads, bad destructuring, …) — surfaced instead of
  discarded, at `:error` in every preset (these shapes do not load; verified
  equivalent on stable Julia's flisp lowering), with four false-positive
  guards (test-block let-wrapping, items under macrocall arguments, items
  containing stripped macrocalls, files with syntax errors).
- `is_ambiguous_local`: Julia's soft-scope-ambiguity warning, statically.
  Already projected; per-item lowering rarely sees the conflicting global, so
  a useful rule needs the enclosing module's names injected into the frame.
- `is_captured`: closure-capture rules.

## 3. Feature layers, classified

Decisive axis: **local vs global**. Local (within one item) is portable today
and MORE correct than v1 — `resolve_scopes` is real scope resolution where
StaticLint's `loose_refs`/`Scope` walks are heuristics. Cross-file/module is
uniformly blocked on a v2 visibility layer ("A3"); Base/stdlib/package content
on the env seam.

**A1**, the prerequisite for eight of nine layers (~80 LOC): a
`derived_v2_item_at_offset` / address-at-offset query — the inverse of
`derived_v2_file_maps`, with the cursor-vs-identifier tie-break v1's
`get_expr1` implements.

| layer | portable now | modest additions | blocked on visibility (A3) / env |
| --- | --- | --- | --- |
| references (763 LOC) | **local refs/rename/highlights/goto-def (~220 LOC)** — slots into v1's existing `(:local, Binding)` vs `(:tree, ItemRef)` seam | same-file top-level refs | cross-file refs/rename |
| symbols (347) | **workspace symbols (~70 LOC, near-mechanical)** | document symbols w/ nesting (~200) | — |
| navigation (205) | **module-at-position (~40 LOC)** | selection ranges, block range (trivia-free range deltas) | — |
| misc (208) | **document links (~60 LOC)** | inlay parameter hints | inlay type hints (needs types) |
| actions (881) | **~6 of 13 actions (~250 LOC)** incl. the unused-fixes (v2 already emits the findings) | OrganizeImports, docstring actions (need A2 = docstring capture) | FixMissingRef, ExplicitPackageVarImport |
| signatures (585) | active-parameter index | same-file help (~300, BodyTree signature renderer); cross-file reachable WITHOUT A3 via a cheap `derived_v2_method_items` | Base/stdlib callees |
| hover (1083) | local-variable hover | same-file hover (needs A2) | cross-module; Base/store docs (dominates hover value) |
| completions (1629) | scope-local variables | same-file module names, fields | visible-names/import completions; store completions (dominates volume) |
| formatting (309) | — | — | already stack-independent; nothing to do ever |

All features sit behind flat `public.jl` functions returning plain structs, so
a v2 implementation swaps in behind them, flag-gated; every layer's existing
testitem suite doubles as a differential harness.

## 3½. Environment-seam program status

- ✅ **Milestone A — v2 root discovery** (`src/v2/layer_includes_v2.jl`):
  include graph, roots, reverse map and best-root from skeleton `V2Include`
  rows; the `joinpath(@__DIR__, …)` include idiom resolves statically; v2's
  two root consumers retargeted; the boundary guard now forbids v1's root
  queries; corpus root-differential green with an empty allowlist.
- ✅ **Milestone B — v2 visibility layer (tree-only)**
  (`src/v2/layer_visibility_v2.jl`): `derived_v2_module_visible_names` + the
  id-free face + per-name selector, the two-pass ledger algorithm with
  workspace-package cross-root recursion (cycle-guarded memoization), the
  unresolved-wildcard flag, and v2's own `derived_v2_workspace_package_roots`
  (no v1 query reachable from v2 any more). External targets follow v1's
  store-missing behavior — the four-place Milestone C seam is marked in the
  file. Corpus differential green with ratchet classes `:testitem_nodes` /
  `:macro_declared` / `:external_names`; building it caught and fixed the
  missing method-extension rule in v2's module-tree declare.
- Next: **Milestone C — the env edge** (external exports hash-keyed
  plain-data-out, Base/Core implicit names, env readiness) and the first env
  rules (`missing_reference` as a post-pass join over lowering's
  anchor-module `:global` bindings, `unresolved_import`).

## 4. Recommended sequencing (as of this survey)

1. ✅ **Harvest JuliaLowering** (this milestone): lowering errors + routed
   takeover ids + `unused_type_parameter` + the module-tree pair.
2. **v2 features M1**: A1 + local-references family + workspace symbols +
   module-at-position + document links + structural actions (~640 LOC).
3. `is_ambiguous_local` (with module-name injection), `nothing_comparison`,
   intra-module `const_decl`.
4. **The environment seam** — the remaining ~half of lint value plus full
   hover/completions. The big one; planned separately.
