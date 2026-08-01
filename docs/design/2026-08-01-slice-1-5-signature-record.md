# Slice 1.5 — one signature record

*2026-08-01 — a spec, not a task plan. Supersedes the sketch in the trailing
section of `docs/superpowers/plans/2026-07-31-type-aware-matching-slice-1.md`,
which assumed a narrower merge.*

## What this replaces

`InventoryItem` currently carries three overlapping descriptions of a callable's
shape, each added for one consumer:

| field | added for | content |
|---|---|---|
| `arity::Union{Nothing,MethodArity}` | the cross-file argument-count check | `minargs`, `maxargs`, `kws::Vector{Symbol}`, `kwsplat` |
| `param_types::Union{Nothing,Vector{Vector{String}}}` | the cross-file type check | one dotted name path per positional parameter, empty = unknown |
| `signature::Union{Nothing,String}` | hover on an external extension | the whole signature re-printed via `to_codeobject` |

They are three projections of one thing, computed by three separate traversals of
the same EXPR (`func_nargs`, `_param_type_names`, `_render_sig`), aggregated by two
separate per-root splice walks. Replace them with one structured record.

`signature::String` has exactly two consumers — `ExternalExtension`
(`layer_module_tree.jl:1078`) and `layer_hover.jl:711` — so it is in scope for the
merge rather than a separate concern.

## The record

Plain data throughout, per the layer-1 firewall. Sketch, not final:

```julia
@auto_hash_equals struct SigParam
    name::String                 # "" for a dispatch-only `::T`
    type::ParamType              # see below
    role::Symbol                 # :positional | :optional | :keyword | :vararg
end

@auto_hash_equals struct TypeVar
    name::String
    upper::ParamType             # unknown when there is no usable upper bound
end

@auto_hash_equals struct MethodSignature
    params::Vector{SigParam}     # positional and optional, in source order
    kwargs::Vector{SigParam}
    kwsplat::Bool
    where_vars::Vector{TypeVar}  # method-local; see the open-questions entry
    shape_unknown::Bool          # macro-wrapped: arity must answer permissively
end
```

**Record the type as written, not as a resolvability verdict.** Slice 1 collapses
every non-bare shape to "unknown" *at record time* — a parametric, a `where`-bound
variable and a literal all become `String[]`. That is a premature judgement, and it
is what makes slice 2 a schema change rather than a resolution change. A faithful
`ParamType` — a name path, or a name path with arguments, or an explicit unknown —
lets resolution decide what it can handle, and moves parametrics from "new field" to
"new case in the resolver".

It also has to be faithful enough to re-render, or the string signature cannot be
subsumed (below).

## What falls out

**Count shape is derived, not stored.** `minargs` is the count of `:positional`,
`maxargs` is that plus `:optional` (or `typemax` if any `:vararg`), `kws` is the
keyword names, `kwsplat` stays. `MethodArity` becomes a function of the record
rather than a field — which is the actual sense in which type matching subsumes
arity matching, and the reason the answer to "can we just drop the arity index"
was *no* while the two were separate structures.

**Argument names buy three things** beyond rendering: keyword matching by name
(today `MethodArity.kws` carries them separately), `textDocument/signatureHelp`
having a structured source, and the dispatch-only `::T` case staying representable
(`name == ""`) now that slice 1 records its type.

## The trap: merging the storage must not merge the granularity

The naive merge — one index, one projection — **loses early cutoff**. Today a
type-only edit (`f(x::Int)` → `f(x::String)`) leaves `derived_method_arities_index`
equal, so it backdates and no arity consumer re-runs. Collapse the two projections
into one and that edit invalidates the count opinion too.

So: **one index, two projections.**

- `derived_method_signatures(root, path, name)` — the full records.
- `derived_method_arities(root, path, name)` — unchanged signature and unchanged
  return type, now *derived* from the merged records.

A type-only change leaves the arity projection's value equal, so it still backdates
exactly as today. The merge is then purely a saving: one splice walk instead of two,
worth the 1.3–3.1 ms the index costs on a declaration-changing edit — a cost
currently paid twice, which the budget doc never accounted for.

## The other trap: withhold the type opinion, never the count opinion

Every withholding mechanism slice 1 added blanks the types while deliberately
leaving counts intact — the `:opaque_definitions` marker empties the parameter-type
index for a whole root, the external-import gate withholds by name, and `check_call`
declines when a name's records and arities differ in length. The arity index has
never withheld anything.

Collapse those into a single withhold-the-record decision and the marker starts
deleting arity coverage on exactly the metaprogramming-heavy roots where it fires.

**The mechanism that avoids it: withholding blanks the types inside the record
rather than dropping the record.** A withheld record keeps its parameter count,
roles and names, and its types all become explicit unknown. The count opinion then
survives structurally, and `_tree_types_match` declines on its own because every
type is unknown — no separate gate needed. Today's arity behaviour is preserved
exactly, including its pre-existing exposure to `eval`-created methods, which is a
separate bug and must not be silently "fixed" here without measuring the
true-positive loss.

Note this deletes `check_call`'s `length(recs) == length(arities)` guard, which
exists only because the two indices could disagree in *membership*. One index cannot.

## Can the string signature go?

Only if the record is faithful enough to re-render. `_render_sig` is
`string(to_codeobject(rem_wheres_decls(get_sig(x))))` — the source text minus
`where` clauses and the return-type declaration — so it currently reproduces
parametrics, defaults and unusual spellings that slice 1's record throws away.

Two honest options:

1. **Keep the string field.** Zero rendering risk, and it is only two consumers.
   The merge still eliminates one field and one walk.
2. **Derive it.** Requires `ParamType` to be faithful (which it should be anyway,
   see above) *and* defaults to be recorded, which they currently are not. The
   rendering will not be byte-identical to `to_codeobject` in every case, so the
   hover output changes in ways a test must pin.

**DECIDED: (1).** The string field stays through the merge, so a rendering
regression cannot be confused with a matching regression while the acceptance gate
is running. Deriving it is a follow-up.

## Acceptance

It is a pure consolidation, so the gate is strong and cheap: **the diagnostic set
over the julia-vscode repo must be identical before and after** — the same per-file
messages, not merely the same count — and every existing test must pass unchanged.
Use the both-direction sweep (`docs/perf/typesweep.jl`); here, unlike slice 1.4,
*any* movement in either direction is a finding.

Add one test per class in "the other trap": with a marker present, the arity
diagnostic must still fire. That is the property the whole design rests on and it is
currently verified by a single assertion added late in slice 1.

Also re-measure the index recompute, since halving it is the performance case for
doing this at all.

## Open questions

- **Structs — DECIDED: in scope.** Fields become parameters and the struct's type
  parameters become `where_vars`, but the type opinion stays *withheld* through the
  merge so no diagnostic moves; enabling it is a follow-up with its own sweep.
  `struct_nargs` has three arms the record must reproduce exactly — macro-wrapped is
  fully permissive, inner constructors collapse to the *union* of their ranges (a
  single range cannot express a gap, which errs toward acceptance), and otherwise
  the field count skipping field docstrings.
- **Where-clause bounds — RESOLVED, see the plan.** `where_vars` carries name →
  *upper bound*, not bare names, and it is a correctness requirement rather than
  metadata: with a faithful record `x::T` is the name path `["T"]`, so a resolver
  that cannot tell `T` is method-local will look it up in the defining module and
  may genuinely find a type of that name. Bounds: `where T` → unknown; `T<:B` → `B`;
  `Lo<:T<:Hi` → `Hi`; **`T>:B` → unknown**, since a lower bound licenses nothing;
  `where {T, S<:X}` → both. Substituting the upper bound over-approximates, which is
  the safe direction for a rule-out check, but it *widens coverage* and so is a
  follow-up rather than part of the merge. A struct's type parameters are the same
  thing and unify under one resolver rule.
- **`ExternalExtension`** carries the string signature through
  `derived_external_extension_names`. If the string is derived rather than stored,
  that NamedTuple changes shape too.

## Status

Planned in `docs/superpowers/plans/2026-08-01-slice-1-5-signature-record.md` —
four tasks, with the coverage widenings (struct types, `where`-bound substitution,
per-inner-constructor signatures, derived string signature) split out as follow-ups
so the merge itself keeps an identical-diagnostics gate.

## Sequencing

Slice 1.4 is orthogonal — it fixes the argument side and touches none of this. This
spec is a prerequisite for slice 2 (parametrics), which under the faithful-record
design becomes a resolver change rather than a schema change.
