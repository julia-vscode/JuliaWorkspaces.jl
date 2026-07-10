# Hover: parameter names in call-position hints

## Problem

Hovering over an argument in a call with many (≥ 4) arguments shows
`Argument 2 of 5 in call to `foo``. The positional index alone is not very
useful — the user wants to know *which* parameter they are supplying. The two
datatype-field branches in `_get_fcall_position` (`layer_hover.jl`) already
show field names for constructor calls whose arity matches the struct's field
count; the fallback branch (normal function calls, and constructor calls that
don't match the field count) does not.

## Goal

In the fallback branch, resolve the called function's methods, pick the method
that best matches the call, and show the parameter name at the hovered
position:

```
Argument `radius` (2 of 5) in call to `Circle`
```

When no name can be resolved, the existing text is kept unchanged:

```
Argument 2 of 5 in call to `Circle`
```

The feature only ever adds information; every resolution failure degrades to
the current behavior. The `minargs < 4` gate and the two datatype-field
branches are unchanged.

## Method matching

Arity filtering alone is not enough — heavily overloaded functions have many
same-arity methods with different parameter names. Matching is therefore
two-stage:

1. **Arity:** a candidate method is kept when
   `StaticLint.compare_f_call(func_nargs(method), call_nargs(call))` holds —
   the same predicate the `IncorrectCallArgs` lint uses. This handles optional
   arguments, varargs, and keyword arguments.
2. **Types:** for each positional call argument whose type can be cheaply
   inferred, the candidate's declared parameter type at that position must
   satisfy `StaticLint._has_type_intersection`. Unknown argument types and
   undeclared parameter types are wildcards (always compatible). Vararg
   parameter positions are treated as wildcards.

Cheap argument-type inference covers:

- literals: `INTEGER` → `Int`, `FLOAT` → `Float64`, `CHAR` → `Char`,
  `STRING`/string literals → `String`, `TRUE`/`FALSE` → `Bool` (extends the
  spirit of `_infer_scalar_type` in `type_inf.jl`)
- identifiers (and `a.b` getfield chains) whose resolved binding has a known
  `.type`

Everything else is unknown (wildcard).

The first candidate that survives both stages wins. If no candidate survives
the type stage, matching falls back to the first arity-compatible candidate.
If there is no arity-compatible candidate either, the hover keeps the plain
positional text.

## Candidate collection

A new internal helper (in `layer_signatures.jl`, next to
`_collect_signatures`) collects, for a call EXPR, candidate methods as
parameter lists of `(name::String, type::Any)` pairs, where `type` is a
comparable type object (`SymbolServer.FakeTypeName` / `DataTypeStore` /
workspace `Binding`) or `nothing` when undeclared:

- **SymbolServer stores** (`FunctionStore`, `DataTypeStore`): iterate methods
  with `StaticLint.iterate_over_ss_methods`; each `MethodStore.sig` entry is
  already a `name => type` pair. Names print via `string(first(pair))`; types
  are used as-is.
- **Workspace-defined methods:** for each ref of the resolved binding with
  `StaticLint.get_method`, walk the sig EXPR like `_get_signatures` does.
  Parameter names come from `bindingof(arg).name`, declared types from
  `bindingof(arg).type` (which the binding pass resolves for `x::T`
  declarations); `nothing` when untyped. Struct definitions contribute their
  field list (only when they define no explicit inner constructor, matching
  `_get_signatures`).

Callee resolution reuses the `_collect_signatures` pattern:
plain identifier, `f{T}` curly, and `M.f` getfield-with-quotenode heads, then
`StaticLint.refof` + `_retrieve_toplevel_scope`.

`SignatureInfo`/`ParameterInfo` and the public signature-help API are
unchanged; the helper is hover-internal for now but written so signature help
and inlay hints can adopt it later.

## Hover text assembly

In `_get_fcall_position`'s fallback branch (`layer_hover.jl:538-545`):

- name resolved and non-empty, not `#unused#`, position within the matched
  method's named positional parameters →
  `Argument `NAME` (I of N) in call to `CALLNAME``
- otherwise → `Argument I of N in call to `CALLNAME`` (exact current text)

`CALLNAME` construction (including the `M.f` getfield case) is unchanged.

## Error handling

Any of: unresolvable callee name, no ref, no top-level scope, no methods, no
arity-compatible method, out-of-range position, empty/`#unused#` name — all
degrade to the current positional-only text. No exceptions escape; the helper
returns `nothing` rather than throwing.

## Testing

Extend `test/test_hover.jl` (existing in-memory-workspace pattern):

1. Workspace function, 5 untyped params, qualified call `M.f(1,2,3,4,5)` —
   existing test at line ~329 updated: now expects ``Argument `a` (1 of 5)``.
2. Two same-arity workspace methods with typed first param (`f(x::Int, …)` /
   `f(x::String, …)`, different later param names) — hovering a later argument
   of a call with an `Int` literal first arg shows the Int method's parameter
   name (type matching disambiguates).
3. Constructor call that today falls through to the fallback (arity mismatch
   with field count, e.g. struct with inner constructor) — shows the inner
   constructor's parameter name.
4. Call to an unresolvable function — text unchanged
   (`Argument 1 of 5 in call to `g``).
5. SymbolServer-backed call (e.g. a Base function with ≥ 4 args) — shows a
   parameter name from the method store, exercising the `MethodStore.sig`
   path.
