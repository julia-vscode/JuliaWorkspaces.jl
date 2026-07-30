# Spec: macro annotations in the inventory, resolved at the consumer

Status: proposed. Supersedes the alternative of making `func_nargs`
unconditionally permissive for macro-wrapped definitions whenever it has no
resolution state — that removes the divergence in §1 but at the cost of the
false negatives measured there, so it was reverted rather than shipped.

§7 (the doc-wrapper defect) is independent of the rest and ships first, on its
own. File/line anchors are as of `f710e98`.

## 1. Problem

`func_nargs` (`checks.jl:205`) treats a macro-wrapped definition as
signature-opaque and returns the permissive arity `(0, typemax(Int), Symbol[],
true)` — unless it can prove the macro is one of `SIGNATURE_PRESERVING_MACROS`
(`checks.jl:194`), which needs `env` + `meta_dict` to resolve the macro name.

`layer_inventory.jl:691,759,787` call `func_nargs`/`struct_nargs` with neither.
Before the parked change, the guard covered the whole condition, so those calls
skipped the macro branch entirely and recorded a **literal** count. That count
is authoritative in per-file mode: `check_call`'s gate 1 (`checks.jl:387-431`)
consults `tree_arities` for a tree-visible workspace callee and then **returns**
at `:428` — `sig_match_any` never runs.

Measured (all four run against this tree):

| definition (sibling file) | call | per-file, before parked change | per-file, with parked change | whole-closure |
|---|---|---|---|---|
| `macro wrap end; @wrap f(x) = x` | `f(1, 2)` | **flagged (false positive)** | not flagged | not flagged |
| `@inline h(x) = x` | `h(1, 2)` | flagged (correct) | **not flagged (false negative)** | flagged (correct) |
| `"docs"` + `f(x) = x` | `f(1, 2)` | flagged (correct) | **not flagged (false negative)** | **not flagged (pre-existing bug)** |
| `f(x) = x` | `f(1, 2)` | flagged | flagged | flagged |

Two defects, not one:

- **D1 (the reported divergence).** The same definition is judged differently
  depending on which path reaches it. The inventory asserts an arity it cannot
  know; `check_call`'s own path declines to.
- **D2 (found while specifying this; pre-existing and independent).** `@doc` is
  a macrocall, so **every docstring'd definition** is treated as
  signature-opaque. In whole-closure/project mode a documented function has had
  **no arity checking at all**. The parked change extends that hole to per-file
  mode. This is far broader than the `@inline` class — docstrings are
  ubiquitous — and it should ship as its own fix regardless of whether the rest
  of this spec is built (§7).

## 2. Constraints (why this must span two layers)

1. **Layer 2 must not depend on the env.** `layer_module_tree.jl:10-14`:
   "CRITICAL: values in this layer must NEVER depend on `derived_environment`".
   `derived_module_tree` consumes `derived_file_inventory` (`:275`, `:536`), so
   an env-dependent inventory violates it transitively.
2. **Keying.** `derived_file_inventory(rt, uri)` is keyed on the file alone, so
   one file's inventory is shared by every root containing it. `env` is a
   project property; consuming it re-keys per project.
3. **`env` is not the missing ingredient.** `_points_to_Base_macro`
   (`macros.jl:192-199`) ends in `refof(x, meta_dict) !== nothing && …`.
   `meta_dict` is `semantic_pass` output, and resolution consults the tree, so
   the direction is inventory → tree → `meta_dict`. Depending on `meta_dict`
   from the inventory is a **cycle**. Handing the inventory `env` alone yields
   `false` for every macro, i.e. the parked change's behaviour.
4. **Plain data.** `layer_inventory.jl:1-7` — inventory values may hold only
   Symbols/Strings/Ints/collections thereof, so body edits produce `isequal`
   inventories and Salsa early-exits.

A `Vector{String}` of macro names satisfies (1)-(4): it is read from the CST
alone, needs no resolution, and is plain data. This is the same escape valve
`_is_enum_macro` (`layer_inventory.jl:558`) already uses, and its comment says
so explicitly.

## 3. Design

The inventory records **what it can see** (the literal arity, plus the names of
the macros wrapping the definition). The consumer, which has `env`, `meta_dict`
and the tree, decides **what that means**.

## 4. Data model

`layer_inventory.jl`:

```julia
@auto_hash_equals struct MethodArity
    minargs::Int
    maxargs::Int
    kws::Vector{Symbol}
    kwsplat::Bool
    macro_annotations::Vector{String}   # NEW: innermost→outermost, `@`-prefixed
end

# back-compat: store methods and unwrapped defs carry no annotations
MethodArity(minargs, maxargs, kws, kwsplat) =
    MethodArity(minargs, maxargs, kws, kwsplat, String[])
```

The 4-arg constructor keeps every `MethodArity(func_nargs(x)...)` splat working
(`layer_inventory.jl:691,759,787`; `checks.jl:641,643`).
`compare_f_call(ref::MethodArity, act)` (`checks.jl:343`) projects fields by
name, so it is unaffected.

Annotations live on `MethodArity`, not on `InventoryItem`, because
`derived_method_arities_index` (`layer_module_tree.jl:855-871`) copies
`item.arity` verbatim into its result — so they reach the consumer with **zero
layer-2 changes**. Cost: `MethodArity` widens from "argument-count shape" to
"the recorded constraint plus the caveat needed to interpret it"; its docstring
(`layer_inventory.jl:9-20`) must say so.

*Rejected alternative:* a separate `MethodArityRecord(arity, annotations)`
wrapper. Keeps `MethodArity` pure but changes the layer-2 API and every
`derived_method_arities` assertion in `test_module_tree.jl` for no behavioural
gain.

## 5. Collection (layer 1)

New helper in `layer_inventory.jl`, next to `_macro_name_string` (`:541`):

```julia
# The macro names directly wrapping a definition, innermost→outermost. Doc
# wrappers are transparent (they cannot rewrite a signature). Only a direct
# chain of macrocall parents counts: `@static if … end` puts an `if`/`block`
# between the macrocall and the definition, and such a definition is not
# macro-wrapped for arity purposes.
function _macro_annotations(x::CSTParser.EXPR)
    names = String[]
    p = CSTParser.parentof(x)
    while p isa CSTParser.EXPR && CSTParser.ismacrocall(p)
        if _doc_wrapped_item(p) === nothing        # layer_inventory.jl:137
            nm = _macro_name_string(p.args[1])
            nm === nothing || push!(names, nm)
        end
        p = CSTParser.parentof(p)
    end
    return names
end
```

Notes:

- `_macro_name_string` (`:541`) already normalizes the qualified `Base.@inline`
  spelling to `"@inline"`, matching how macros are named `@`-prefixed
  throughout the inventory layers (`:751-755`).
- The while-loop is a widening over today's single-parent check
  (`checks.jl:208`), which sees only the innermost wrapper. `@inline
  @propagate_inbounds f(x) = 1` records both; today it inspects only
  `@propagate_inbounds`.
- Unresolvable names (`@($m) f(x) = 1`) yield `nothing` from
  `_macro_name_string` and are skipped, so the annotation list can be *shorter*
  than the wrapper chain. §6's rule must therefore not infer "no annotations ⇒
  unwrapped" — carry a separate `has_unnamed_wrapper::Bool` if that case must
  be distinguished, or (preferred, simpler) push the sentinel `"?"`, which no
  real macro name can equal and which never matches the preserving set.
  **Decision needed — see §10.**

`func_nargs` grows a keyword so one implementation serves both callers:

```julia
function func_nargs(x::EXPR, env=nothing, meta_dict=nothing; macro_permissive=true)
```

- `macro_permissive=true` (default): today's behaviour — wildcard for a
  macro-wrapped def unless the macro resolves to a preserving one. Every
  existing caller keeps its semantics.
- `macro_permissive=false`: count literally, ignoring the wrapper. The inventory
  passes this, because it records the wrapper separately.

`struct_nargs` (`:179`) takes the same keyword and threads it to `func_nargs`;
its own macro-wrapped early return (`:181`) becomes conditional on it.

## 6. Resolution (the consumer)

Two call sites, both in `layer_file_analysis.jl`, both already holding `env`,
`meta_dict`, `rt`, `root` and `path`:

- `tree_arities` closure (`:765`) — feeds the flag decision at
  `checks.jl:400-426`.
- `_call_cross_file_arities` (`:512`) — feeds `describe_call_mismatch`'s
  message. Both must use the identical predicate, or the rendered reason can
  contradict the flag (`checks.jl:580-583` exists to prevent exactly that).

Shared helper:

```julia
# Interpret an inventory-recorded arity: the literal counts stand only if every
# macro wrapping the definition is known not to rewrite signatures.
function _effective_arity(rt, root, defining_path::Vector{String}, a::MethodArity)
    isempty(a.macro_annotations) && return a
    all(_is_signature_preserving(rt, root, defining_path, nm)
        for nm in a.macro_annotations) && return a
    return MethodArity(0, typemax(Int), Symbol[], true)
end

_is_signature_preserving(rt, root, defining_path, nm) =
    Symbol(nm) in StaticLint.SIGNATURE_PRESERVING_MACROS &&
    !haskey(derived_module_visible_names_idfree(rt, root, defining_path), nm)
```

The second clause is the shadow check and is what makes this **more** precise
than the pre-parked behaviour, which trusted the name blindly. Macros are keyed
`@`-prefixed in the visibility index (`layer_inventory.jl:751-755`), so a
workspace `macro inline(ex)` or `using MyPkg: @inline` in the defining module
appears as `"@inline"` and correctly forces the wildcard.
`derived_module_visible_names_idfree` is already fetched by the same gate two
lines earlier (`:525`), so this is not a new dependency.

`defining_path` is the `p` that `derived_method_arities(rt, root, p, name)` is
keyed by — i.e. the module path the definition resolved into, which is what we
want for the shadow question.

**Ceiling, stated plainly.** In per-file mode the defining file's `meta_dict`
does not exist by construction, so full resolution (`_points_to_Base_macro`) is
unavailable; name + tree-shadow is the best sound answer. When the definition is
in the *same* file as the call, `meta_dict` can resolve it outright — an
optional refinement, not required for v1. Whole-closure mode needs no change: it
passes no gates and resolves properly already.

## 7. D2: doc wrappers (independent, ship first)

`func_nargs`'s macro-wrapped test must treat a doc wrapper as transparent.
`StaticLint.isdocumented(x)` (`checks.jl:806`) is exactly the predicate for the
implicit `globalrefdoc` form:

```julia
if parentof(x) isa EXPR && CSTParser.ismacrocall(parentof(x)) && !isdocumented(x)
```

`isdocumented` covers only `globalrefdoc`; the explicit `@doc f(x) = 1` /
`Mod.@doc` spellings need `layer_hover.jl:270`'s `_is_doc_macro_name` shape (or
`_doc_wrapped_item`'s length-4 check). Whether to cover the explicit form in the
same commit is a small scope call; the implicit form is what real code produces.

This is a standalone fix with its own red test (§8, T0) and restores arity
checking for documented functions in both modes. It does **not** depend on §4-§6.

## 8. Test plan (TDD order)

Each test is written first and must be observed failing for the stated reason.

- **T0 — D2, whole-closure.** `"docs"` + `f(x) = 1` + `f(1, 2)` in one file →
  expect `IncorrectCallArgs`. Fails today (measured: no diagnostic). Harness:
  `derived_static_lint_meta_for_root` + `collect_hints`, per
  `test/staticlint/test_staticlint.jl`'s `has_error`. Note `get_hints`/
  `get_diagnostic` is vacuously empty for a project-less root — assert via
  `collect_hints`.
- **T1 — D2, cross-file.** Docstring'd `f(x) = x` in `a.jl`, `f(1, 2)` in
  `b.jl` → flagged. `FileAnalysisWS` + `derived_file_analysis`.
- **T2 — collection.** `derived_file_inventory` records
  `arity.macro_annotations == ["@inline"]` for `@inline f(x) = 1`, `["@inline"]`
  for `Base.@inline f(x) = 1`, `["@propagate_inbounds", "@inline"]` for the
  nested form, `String[]` for a plain and for a docstring'd def, and the literal
  `(1, 1)` arity in every one of those cases.
- **T3 — D1, false positive gone.** `macro wrap end; @wrap f(x) = x` in `a.jl`,
  `f(1, 2)` in `b.jl` → not flagged.
- **T4 — D1, precision kept.** `@inline h(x) = x` in `a.jl`, `h(1, 2)` in
  `b.jl` → flagged. This is the assertion the parked change cannot satisfy.
- **T5 — shadowing.** `a.jl` defines `macro inline(ex) … end` and
  `@inline h(x) = x`; `h(1, 2)` in `b.jl` → not flagged. Fails both today and
  under the parked change (today: flagged; parked: passes for the wrong reason —
  pair it with T4 so a blanket wildcard cannot satisfy both).
- **T6 — message parity.** The flagged T4 call's rendered message names the
  arity mismatch, proving `_call_cross_file_arities` took the same path.
- **T7 — struct parity.** `@kwdef struct S; a; b; end` cross-file → still
  permissive (annotation recorded, `@kwdef` not in the preserving set).
- **Rewrite.** The parked `test_module_tree.jl` item ("a macro-wrapped
  definition is recorded as permissive") inverts: the inventory now records the
  literal arity **plus** `["@wrap"]`, and permissiveness is asserted at the
  consumer (T3). Delete it in favour of T2 + T3.
- **Regression.** Full suite. Baseline on this branch: 5646 passed, 0 failed,
  1 errored (`Runic not found`, dev-env), 7 broken (pre-existing
  `@test_broken`).

## 9. Salsa / invalidation

- No new dependency edges. Layer 1 gains a CST-derived field; layer 2 is
  untouched; only the layer-3 consumer resolves.
- Backdating is preserved: `String[]` compares `isequal`, and `@auto_hash_equals`
  covers the new field, so unchanged files still produce equal inventories.
- `FileInventory` has no serialized form (constructed only at
  `layer_inventory.jl:453`, never written), so there is no cache format to
  version — unlike the symbol store.
- `InventoryItem`/`MethodArity` are Salsa-cached structs: development needs
  `julia_restart` after the struct edit (Revise cannot redefine them).

## 10. Open decisions

1. **Unnamed wrappers** (§5): sentinel `"?"` vs a separate boolean. Sentinel is
   simpler and fails safe (never matches the preserving set); the boolean is
   more explicit. Recommend the sentinel with a comment.
2. **Explicit `@doc` form** in §7: same commit or follow-up. Recommend same
   commit — it is one extra predicate.
3. **Same-file full resolution** (§6 ceiling): build in v1 or leave as a
   refinement. Recommend leaving it out; the tree-shadow check already covers
   the case that matters.

## 11. Out of scope (unlocked follow-ups)

- **`@kwdef` real arity.** `struct_nargs` (`:181`) currently goes permissive for
  *all* macro-wrapped structs. With the annotation recorded, `@kwdef` could get
  its true shape — positional fields plus one keyword per field — instead of
  accepting anything.
- **Positional type checking cross-file** remains deferred
  (`layer_file_analysis.jl:764`); this spec touches argument counts only.
- **Hover/signature help** could render recorded annotations; no consumer asked
  for it.
