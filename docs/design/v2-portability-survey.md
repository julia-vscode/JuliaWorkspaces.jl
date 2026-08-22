# v2 portability survey: rules and feature layers

*2026-08-20. A point-in-time classification of everything the v1 stack does,
by what a port to the v2 (JuliaLowering-backed) stack would take. Produced to
answer "what should move next" after DJP-side macro expansion landed; the
"Harvest JuliaLowering" milestone implemented the items marked ✅ below.*

v2 capabilities the classes are scored against: per-item lowering through
`rebase_layers → expand_forms_1 → expand_forms_2 → resolve_scopes` (no
`binding_analysis`/`closure_conversion`/`linear_ir`, hence **no CFG**); real
macro expansion via the DJP child (flag-gated) spliced into materialization;
position-free bindings/uses in source-preorder addresses; the v2 module tree;
since the env-seam program (§3½): own root discovery, a cross-file visibility
layer, and a NAME-level environment edge — but still **no** type information
(method tables, store docs).

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
| `pointless_boolean`, `literal_use`, `const_if_condition` | ✅ taken over (v2 M4) — one body-only shape producer (`derived_item_shape_findings`), no lowering/visibility/env; test-block bodies stay covered (no resolution needed). Ported deltas: `EqInIfConditional` not ported (`if x = 1` is a parse error in JuliaSyntax v2 — `syntax_errors` reports it); the `@static if` exemption is by NAME, not Base-identity; top-level `if` chains are invisible (the walker is transparent through them); `literal_use`'s module-name arm not ported (module rows carry no body); quoted code skipped (v1 lints quotes — the standard v2 narrowing). The `NotEqDef` half of `type_piracy` shipped in M3. **This closes the advisory semantic tier**: every remaining v1-only rule is type-blocked or measurement-parked. |

### B — modest additions (~10%)

| rule | what it needs |
| --- | --- |
| `module_name`, `relative_import` | ✅ this milestone — v2 module tree + splice prefix only. `module_name` is a mild superset of v1 (catches the cross-file splice-point parent). |
| `nothing_comparison` | ✅ taken over — body-shape walk in `derived_item_semantic_findings` (includes macrocall arguments, skips quotes); the shadow guard is self-resolving via lowering (a local named `nothing`/`==`/`!=` silences the item). Zero v2-only on the corpus differential. |
| `index_from_length` | ⏸ DEFERRED on measurement (v2 M3): v1 produces exactly ONE finding on this repo's corpus (layer_hover.jl, a `1:length` loop over an unknown-typed container). The port would need a syntactic stand-in for v1's `isarray`-typed exemption (fire/decline by initializer or annotation shape) to avoid v2-only findings on annotated arguments — machinery disproportionate to one corpus hit. Revisit if a registry sweep shows real volume. |
| `const_decl` (intra-module) | ✅ taken over — the module tree's raw ordered decl-event stream (whole-module, so CROSS-FILE redefinitions are new coverage over v1's scope-local check); conditional/under-macrocall rows and structurally-identical re-definitions exempt; local shapes stay `lowering_errors:error`. Zero v2-only on the corpus differential. |
| `incorrect_iter_spec` (literal arm) | ✅ taken over (v2 M3) — bare numeric literal / bare Base-resolving `length(...)` iterated values, over for/generator specs (multi-spec block form included) with the standard macro/quote address accounting; a locally-shadowed `length` declines the item. The strict `<:Number`-typed-variable arm stays deferred (type inference). |

### C — env-dependent (~45–55%, the user-visible majority)

- ✅ **`missing_reference`, `unresolved_import`** (the only two
  `:warning`-by-default StaticLint rules) — Milestone C, taken over.
  `missing_reference` is a post-pass join over lowering's anchor-module
  `:global` read-not-assigned bindings vs (id-free visible names ∪ implicit
  Base/Core scope), with synthetic reads suppressed by preorder-address
  interval and gate-heavy conservatism (see the file header of
  `lint_lowering_rules.jl` for the deviations, all in the silent direction:
  item-level existence guards, whole-file test-helper suppression,
  `scope="symbols"` ≡ `"all"`, members unchecked). `unresolved_import` ports
  v1's message semantics exactly (first unresolved component, declared-dep
  distinction, wildcard consequence, no-double-diagnosis with
  `relative_import`, resolves-to-a-binding silence). Corpus differential:
  zero v2-only findings.
- ✅ **`incorrect_call_args` (arity arm) + `function_has_no_methods`**
  (v2 M3) — the class-C keystone, resolved at ARITY level: v1's own per-file
  `tree_visible` path already checks cross-file callees from `MethodArity`
  plain data with no types, so the arity-only port reproduces the shipped
  cross-file semantics. Callee → visibility face → workspace arity funnel
  (`derived_v2_method_arities_index`) or seam arities
  (`derived_v2_external_method_arities`, the `func_nargs(::MethodStore)`
  port with permissive extension-package scope); the `compare_f_call` port;
  arity-sentence messages. Deliberately NOT ported: the positional-TYPE
  message arm ("At argument i: expected T"). Gate-heavy declines (do-blocks,
  def sigs, splats, shadowed/aliased/partial-view names, blind modules, test
  blocks, unmodelled macro arguments); zero v2-only on the differential.
- ✅ **`type_piracy`** (v2 M3) — NotEqDef as pure shape; the
  import-then-extend rule by name provenance (workspace-owned or where-bound
  argument types exempt; unresolvable names decline the definition).
- ✅ **`invalid_type_declaration`** (v2 M3) — signature `x::T` declarations
  where `T` is a literal, a workspace function/macro, or an external
  `:value` member; the seam's `:datatype` member kind (VarRef forwards and
  constructor-`extends` resolved) is the arbiter. Alias chains decline.
- ✅ **`kw_default_mismatch`** (v2 M3) — literal keyword defaults vs
  Core-builtin annotations; the EST's TYPED literal values collapse v1's
  head/digit-count table into `typeof(value)` checks, width for width.
- Still type-blocked: the positional-type arm of `incorrect_call_args`, the
  strict `<:Number` arm of `incorrect_iter_spec`, `index_from_length` (see
  class B — deferred on measurement), and store-doc-hungry
  hover/completions content.

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
- ✅ **`soft_scope_ambiguity`** (`is_ambiguous_local`): Julia's soft-scope
  ambiguity warning, statically. The flag requires the conflicting global to
  EXIST in the lowered-into module — always false against the empty anchor —
  so the rule runs a SEPARATE second lowering (`_lower_item_soft_scope`) into
  an anchor seeded with the module's plain-global names (`:assignment`/
  `:global` kinds; consts/functions/datatypes never soft-scope-warn), keeping
  `derived_item_lowering` body-only pure. Candidate-gated to items containing
  top-level `for`/`while`/`try` (the neutral-scope shapes). Corpus FP-sweep
  empty. Default `:information`, strict `:warning`.
- `is_captured`: closure-capture rules.

## 3. Feature layers, classified

Decisive axis: **local vs global**. Local (within one item) is portable today
and MORE correct than v1 — `resolve_scopes` is real scope resolution where
StaticLint's `loose_refs`/`Scope` walks are heuristics. Cross-file/module is
uniformly blocked on a v2 visibility layer ("A3"); Base/stdlib/package content
on the env seam.

✅ **A1 shipped** (M1, `src/layer_features_v2.jl`): `V2ItemView` +
`v2_item_row_at` + `v2_identifier_addr_at` — plain volatile-map consumers
reproducing `get_expr1`'s identifier right-edge tie-break in range terms.

| layer | portable now | modest additions | blocked on visibility (A3) / env |
| --- | --- | --- | --- |
| references (763 LOC) | ✅ **local refs/rename/highlights/goto-def** shipped (M1); ✅ **same-file GLOBAL highlights** (M2) — name-keyed per module, declining on aliases/qualified cursors/qualified-extended names | `_can_rename` global arm | cross-file global refs/rename (needs the outbound-table equivalent) |
| symbols (347) | ✅ **workspace symbols** shipped (M1); ✅ **document symbols** shipped (M2) — full lexical fidelity incl. locals/fields/testset titles via range-containment nesting; declared deltas: flat local nesting, whole-statement value ranges, inference-kind degradations | — | — |
| navigation (205) | ✅ **module-at-position** (M1); ✅ **selection ranges + block range** (M2) — gap-partition windows, docstring-inclusive blocks via A2, hard declines around degraded rows (strict-equality differential) | — | — |
| misc (208) | ✅ **document links** shipped (M1), parity semantics (any file-naming string literal); docstring contents deliberately unlinked | — | **inlay parameter hints DESCOPED**: callee resolution is `find_methods` — type-discriminating, store-backed; pinned tests require overload selection by argument type → blocked on type-level env data; a tree-callee hybrid is signature-help-shaped follow-up. Inlay type hints need types |
| actions (881) | structural set + OrganizeImports + BOTH docstring actions verified WORKING under both flags (all pure CST + parent pointers; meta unused; parity-probed incl. execution equality) — no port needed. v2-driven when/handlers for v2-only findings remain the follow-up | — | FixMissingRef, ExplicitPackageVarImport |
| signatures (585) | ✅ **workspace callees shipped** (M3): labels + UTF-16 parameter ranges from SOURCE SLICES through `_assemble_signature` (one label/offset contract for both engines), inner constructors included; `derived_v2_method_items` supplies the cross-file method set; v1's cursor-independent comma-count active-parameter rule mirrored | — | Base/stdlib callees (store method rendering) |
| hover (1083) | ✅ **cross-file function + module names shipped** (M3): per-method docstring + signature-slice blocks, byte-equal to the pinned TreeRef rendering, exported/public footer included. DECLINED BY DESIGN: locals (v1 renders inferred types), datatypes (canonical Expr printing vs comment-preserving slices), same-file-declared names and definition sites (v1's same-file binding view differs from its own cross-file rendering), argument positions | — | Base/store docs (dominates hover value) |
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
- ✅ **Milestone C — the env edge + first env rules**
  (`src/layer_v2_env_seam.jl`, outside src/v2 because the store walk needs
  guard-forbidden names; stores never escape into derived values): external
  exports/member-kind/first-missing-segment/implicit-scope/project-deps as
  plain-data queries; the four visibility seam places restored (the
  `:external_names` differential ratchet class died — external faces
  converged exactly); env-ready gating extended to v2 findings in
  `derived_diagnostics` (it previously covered only the StaticLint loop);
  `missing_reference` + `unresolved_import` shipped as takeovers (see §1
  class C). Differentials caught three real bugs along the way: the
  module-tree method-extension rule, comma-list import row conflation, and
  the missing resolves-to-a-binding rule. Notable env fact: the baked
  "stdlib-only" env is `load_core()`'s Core/Base/Main only — no actual
  stdlibs — so projectless tests use `Base`/`Base.Threads` as store-present
  fixtures.
- ✅ **v2 M3 — the ARITY edge**: the seam gained
  `derived_v2_external_method_arities` (the `func_nargs(::MethodStore)` port
  over the extended-method union, extension-package scope deliberately
  permissive — over-accepting arities only removes findings) and the
  `:datatype` member kind (VarRef forwards resolved; constructor
  FunctionStores followed through `.extends`, v1's `is_never_datatype` rule
  — while `:module` determination stays lookup-free for visibility parity).
  Workspace-side, `src/v2/layer_arity_v2.jl` funnels per-item `MethodArity`
  (the `func_nargs(::EXPR)`/`struct_nargs` port in BodyTree vocabulary; the
  walker now snapshots enclosing macrocall NAMES per wrapped item so the
  signature-preserving-macro rule survives without resolution) into
  `derived_v2_method_arities_index` — an entry per method-kind declaration,
  empty-vector = `function f end`.
- The environment-seam program is COMPLETE at name+arity level. What remains
  env-side is genuinely TYPE-level store data (per-slot method signatures,
  docs, completions content) — a different program.

## 4. Recommended sequencing (as of this survey)

1. ✅ **Harvest JuliaLowering** (this milestone): lowering errors + routed
   takeover ids + `unused_type_parameter` + the module-tree pair.
2. ✅ **v2 features M1** (`src/layer_features_v2.jl`, behind
   `input_v2_enabled` / `set_v2_enabled!`, since M3 the SINGLE v2 flag):
   A1 + local references family + workspace symbols + module-at-position +
   document links, each with the try-v2-else-v1 composition and a corpus
   differential; structural actions verified working under both flags.
3. ✅ **The small rule batch**: `nothing_comparison` + intra-module
   `const_decl` taken over; `soft_scope_ambiguity` shipped as the first
   genuinely new lowering-only rule (see §2).
4. ✅ **The environment seam** (name level, §3½ Milestones A–C):
   `missing_reference` + `unresolved_import` shipped.
5. ✅ **v2 M3** (one flag + the arity edge + same-file hover/signature
   help): the two v2 flags consolidated into `input_v2_enabled` /
   `set_v2_enabled!`; the arity edge (§3½) with the
   `incorrect_call_args`/`function_has_no_methods` takeover and the
   `type_piracy` / `invalid_type_declaration` / `kw_default_mismatch` /
   `incorrect_iter_spec`-literal batch; signature slicing + hover +
   signature help on v2 (§3). `index_from_length` deferred on measurement.
   What remains env-side — store-doc hover/completions, the positional-type
   arms — needs genuinely TYPE-level store queries; plan separately.
6. ✅ **v2 M4** (the final shape-rule batch): `pointless_boolean`,
   `const_if_condition`, `literal_use` taken over (§1 class A). The advisory
   semantic tier is CLOSED — the only rules v1 still owns are
   `index_from_length` (measurement-parked) and the type-blocked arms.
