# Specific "possible method call error" diagnostics (2026-07-18)

Plan for #8: make the method-call lint say *why* it flagged, instead of the bare
`"Possible method call error."`. Target: report the inferred call vs the
available signatures — arg-count mismatch, a specific positional type mismatch,
or an unknown/missing keyword — the way Julia's own `MethodError` does.

## Current state (grounding)

- `check_call` (`src/StaticLint/linting/checks.jl`) resolves the callee, then
  `sig_match_any(func_ref, x, call_counts, tls, env, meta_dict)`; on no match it
  `seterror!(x, IncorrectCallArgs, meta_dict)`. `IncorrectCallArgs` is a bare
  `LintCode`; `Meta.error::Any` just stores that code.
- `sig_match_any` → `match_method(args, kws, method, store, meta_dict)` per
  candidate method (`methodmatching.jl`), returning a **Bool**. It already
  computes everything a reason needs but discards it:
  - `!isempty(kws) && isempty(method.kws) && return false` — the kwarg case.
  - `length(args) == nsig || return false` (and the `Vararg` arity math) — the
    arity case.
  - `_has_type_intersection(args[i], t, …) || return false` — the positional
    type case (arg index `i`, inferred `args[i]`, expected `t`).
  - candidate arg types are also enumerated for the store path via
    `iterate_over_ss_methods` and for the EXPR path via the `method::EXPR`
    overload.
- `call_arg_types(x, false, meta_dict, getsymbols(env))` yields the inferred
  positional arg types + kw names for the call site (already used by
  `sig_match_any`).
- The LSP message is produced in `_file_analysis_diagnostics`
  (`src/layer_file_analysis.jl`): for a `LintCodes` error it looks up
  `LintCodeDescriptions[code]` — a static string. **Precedent for a dynamic
  message already exists there**: the `UnresolvedImport` arm builds a custom
  `"$cause $consequence"` string at render time instead of using the table.

## Approach

Render-time detail, mirroring the `UnresolvedImport` precedent — no new plumbing
through `semantic_pass`/`check_all`/`check_call`:

1. In `_file_analysis_diagnostics`, special-case `code === IncorrectCallArgs`
   before the generic `LintCodeDescriptions` lookup and build the message from
   `describe_call_mismatch(err[2], env, meta_dict)` (new helper in StaticLint,
   next to `check_call`). Fall back to the current static string when the helper
   can't produce anything specific (keeps parity for odd shapes).

2. `describe_call_mismatch(call, env, meta_dict) -> Union{Nothing,String}`
   re-derives, for the flagged `:call`:
   - `func_ref = refof_call_func(call, meta_dict)` and the callee name (for the
     `f(...)` rendering).
   - `args, kws = call_arg_types(call, false, meta_dict, getsymbols(env))`.
   - the candidate signatures, via the same enumeration `sig_match_any` uses
     (`iterate_over_ss_methods` for a store callee; the `func_ref.refs` /
     `func_ref.val` method EXPRs for a Binding callee — factor the shared walk
     out of `sig_match_any` so reason-collection and matching stay in lockstep).

   It classifies the failure with this precedence (first that holds for ALL
   candidates):
   - **keyword**: `!isempty(kws)` and no candidate accepts a passed keyword →
     `"unsupported keyword argument \`k\`"` (name the first offending kw).
   - **arity**: no candidate's arity range admits `length(args)` →
     `"expected N argument(s), got M"` (collapse the candidates' arities to a set
     / range for the "N" part).
   - **positional type**: some candidate matches on arity but a positional slot
     rejects the inferred type → name the argument index, inferred type, and
     expected type of the closest candidate (fewest mismatched slots).

3. Message format (familiar, Julia-`MethodError`-like):
   - Header always: ``No method matching `f(::T1, ::T2; kw)`.`` using the
     inferred arg types (unknown → `Any`).
   - Then the specific clause from the classification, e.g.
     `` Closest candidate: `f(::AbstractString, ::AbstractString)` (argument 2:
     got `PkgData`, expected `AbstractString`).`` or `` Expected 2 arguments, got
     3.`` or `` Unsupported keyword `foo`.``
   - Keep it one line (diagnostics render inline).

## Type formatting

Reuse the store type rendering already used by hover's `_get_hover(::FunctionStore)`
(`sig[2]` prints as `Core.String` etc.). Factor a small `_format_type(t)` helper
so the inferred args (`call_arg_types` → SymbolServer types) and the candidate
`sig[i][2]` print consistently. For a workspace-`Binding` datatype arg, print its
declared name; unknown/`Any` → `Any`.

## Edge cases / cautions

- **Splatted calls** (`call_has_splat`): arity is unknowable, so `sig_match_any`
  only arity-checks leniently — `describe_call_mismatch` should say
  `"argument count can't be determined (splat)"`-style nothing, i.e. return
  `nothing` and keep the generic message rather than assert a wrong arity.
- **Partial method sets / per-file gates**: `check_call` already declines
  (returns without flagging) for tree-visible Bindings and workspace-extended
  store callees (the #6 gate). Those never reach `IncorrectCallArgs`, so the
  detail helper doesn't need to reconsider them — but it MUST use the same callee
  enumeration so it never contradicts the match decision (e.g. don't ignore the
  workspace extensions the matcher counted).
- **Unknown inferred types**: when an arg type is unknown, do NOT claim a type
  mismatch on it (Julia can't either) — the classification's positional-type arm
  must skip `Any`/unknown slots, matching `_has_type_intersection`'s leniency, so
  the reason is only asserted where the matcher actually rejected a *known* type.
- Message must stay stable/testable — avoid nondeterministic candidate ordering
  (sort candidates deterministically before picking the "closest").

## Testing

`test/test_diagnostics.jl` / `test/staticlint/` — assert the message text, not
just that a diagnostic fires:
- arity: `f(x) = x; f(1, 2)` → mentions "expected 1", "got 2".
- positional type: `f(x::Int) = x; f("s")` → mentions argument 1, got `String`,
  expected `Int`.
- keyword: `f(x; a=1) = x; f(1; b=2)` → mentions keyword `b`.
- splat: `f(x::Int)=x; f(xs...)` → still flagged? (it isn't, per the splat
  leniency) — assert no over-claim.
- regression: a correct call still produces no diagnostic; the generic fallback
  still applies where no specific reason is derivable.

## Scope / not now

- This is a message-quality improvement; it does not change WHICH calls flag
  (that stays `sig_match_any`'s decision). Keep the two in lockstep by sharing
  the candidate-enumeration + per-method comparison so the reason can never
  disagree with the flag.
- Optional later: expose the structured reason (code + data) through the
  diagnostic `code`/related-information instead of only prose, for richer client
  rendering.
