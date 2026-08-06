# Test-setup bodies analyzed as virtual files

## Problem

`layer_test_setups.jl` extracts the names a `@testmodule`/`@testsnippet`
binds with a hand-rolled CST scan. The scan is a weaker duplicate of the
normal StaticLint passes and is wrong in both directions:

- **Over-suppression:** any wildcard `using X` or any macrocall at a setup's
  top level makes the setup "not fully enumerable", which turns off bare
  missing-ref checks in every referencing `@testitem` — even when `X` is a
  perfectly resolvable indexed package whose exports could be enumerated,
  and even for `@enum`, which the normal passes handle.
- **Silent drops:** bindings inside top-level `begin`/`if` blocks are
  neither collected nor flagged as unenumerable, producing false missing-ref
  diagnostics in referencing testitems.

## Semantics (agreed)

A setup body is a file:

- `@testmodule TM begin … end` behaves like a file containing
  `module TM … end` — a bare module, no default imports beyond Base/Core.
- `@testsnippet TS begin … end` behaves like a file top level running with
  the testitem default imports (`using Test`, `using <PackageUnderTest>`),
  because TestItemRunner `include_string`s it into the referencing item's
  module.

Run the normal passes over the body and extract plain data from the result.
Full file parity, including macros: known macros (`@enum`, …) bind names via
the existing handlers; an unknown binding-generating macro produces the same
false missing-refs it would in a regular file. No setup-specific
conservatism remains.

## Data model

`TestSetupData` (layer_test_setups.jl) and its StaticLint mirror
`TestSetupInfo` (StaticLint.jl) drop `fully_enumerable` and become:

```julia
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol                       # :module / :snippet
    file::URI
    bound_names::Vector{String}        # sorted keys of the analyzed body scope
    exported_names::Vector{String}     # sorted; exact top-level export scan
    wildcard_packages::Vector{String}  # sorted; resolved wildcard `using` targets
    has_unresolved_wildcard::Bool      # body scope's unresolved_wildcard_import
end
```

## Per-setup analysis query

`derived_test_setups_in_file(rt, uri)` keeps its signature and its
macrocall-detection loop. For each setup body (`:block` subtree) it runs the
normal passes instead of the hand scan, mirroring `derived_file_analysis`'s
frame:

- root via `derived_best_root_for_uri(rt, uri)`; env via the root's project
  (`derived_environment`, with the `derived_stdlib_only_env` fallback);
- a `TreeModuleContext` for tree/workspace-package resolution;
- a fresh local `meta_dict`; the `mark_unresolved_imports!` tail step runs
  so the wildcard flag is final;
- scope seeding matches the runtime semantics the inline handlers
  (`_handle_testmodule`/`_handle_testsnippet`) already implement:
  module-like scope with Base/Core for `:module`, default-imports injection
  for `:snippet`.

Flattening:

- `bound_names` = keys of the body scope's `names`;
- `wildcard_packages` = keys of the body scope's `modules` minus the seeded
  entries (Base, Core, Test, the package under test);
- `has_unresolved_wildcard` = the body scope's `unresolved_wildcard_import`;
- `exported_names` keeps the existing exact top-level export scan
  (`_setup_toplevel_export_names`): export statements are literal identifier
  lists and the pass records exports nowhere reusable.

Every other `_setup_*` helper is deleted.

Salsa constraints:

- **Purity:** scopes/EXPRs/meta stay local; only the flattened struct
  escapes.
- **No cycle:** the query never touches `derived_file_analysis` or
  `test_setup_info`, so a testitem referencing a setup in the same file is
  safe (that was the cycle that ruled out reading setups off the declaring
  file's `FileAnalysis`).
- The query gains env and tree-context dependencies — coarser re-execution
  than the pure-CST scan — but `@auto_hash_equals` output equality still
  backdates consumers. `derived_test_setups` / `derived_test_setup` faces
  are unchanged.
- Setup bodies are analyzed twice (inline in the declaring file for its own
  diagnostics, once here). Accepted; bodies are small.

## Injection flow (`_handle_testitem`, macros.jl)

`:snippet`:

- inject `bound_names` as today;
- for each `wildcard_packages` entry, re-attach the way
  `_inject_testitem_default_imports!` attaches the package under test: env
  store into `item_scope.modules` plus public names, else
  `workspace_package_context` → tree-ref binding + `ExportFilteredContext`;
- if re-attachment fails item-side (rare; same package, same env) or
  `has_unresolved_wildcard` is set → `item_scope.unresolved_wildcard_import
  = true`.

`:module`: unchanged mechanics — `TestSetupModuleRef` with `bound_names` as
members (now complete), exports injected bare. A testmodule's wildcard flag
never suppresses item-side checks: its `using` stays contained in the module
at runtime, exports are literal, and `TestSetupModuleRef` member misses are
already never flagged.

## Behavior changes

1. Resolvable wildcard `using` in a snippet brings real names/stores into
   referencing items instead of suppressing missing-ref checks; only
   genuinely unresolvable wildcards suppress.
2. Testmodule wildcards never suppress item-side checks.
3. Full macro parity (`@enum` binds; unknown macros behave as in any file).
4. `begin`/`if`-block bindings in setup bodies are found.
5. `import X` binds `X` itself, as in a file.

## Testing

End-to-end via `derived_file_analysis`, in the existing branch's test style:

- snippet with indexed wildcard (`using LinearAlgebra` → `norm` resolves;
  an unrelated undefined name is still flagged);
- snippet with unresolvable wildcard → suppression;
- snippet wildcard on a deved workspace package → tree channel;
- testmodule with wildcard → item refs not suppressed;
- `@enum` in a setup body → names enumerated;
- `begin`-block bindings in a setup body → found;
- same-file testitem + setup → no cycle;
- existing `fully_enumerable` assertions updated.
