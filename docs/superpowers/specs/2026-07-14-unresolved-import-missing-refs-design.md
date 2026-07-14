# Tolerate unresolvable modules in missing-refs linting

**Date:** 2026-07-14
**Status:** Approved

## Problem

The `missing-refs` lint level defaults to `"symbols"` even though `"all"`
(which also checks getfield references like `Foo.bar`) would be more useful.
The blocker is noise from unresolvable modules: when `using MyModule` cannot
be resolved (package not installed, not in the project, etc.), the import
args get no refs and no bindings, so *every* downstream use is flagged —
bare exported names, `MyModule` in `MyModule.foo`, and names from
`using MyModule: foo`. One missing package floods a file with warnings.

## Behavior

1. **Default level flips** from `"symbols"` to `"all"`
   (`_missingrefs_from_config` in `src/layer_diagnostics.jl`).

2. **New LintCode `UnresolvedImport`**, placed on the first unresolved
   component of an import path. The message must make the consequence
   obvious — missing-reference checks go quiet downstream:

   > Failed to resolve `MyModule`. Missing-reference checks are disabled in
   > this scope and all scopes nested inside it.

   For non-wildcard forms (`import MyModule`, `using MyModule: foo`,
   `import MyModule: foo`) there is no blanket suppression, so the second
   sentence is dropped/adjusted accordingly.

   The diagnostic is environment-dependent: it must stay hidden until the
   environment is fully loaded. Because the message embeds the module name,
   `_is_env_dependent_diagnostic` needs prefix matching (like the existing
   "Missing reference:" case), not exact set membership.

3. **Unresolved wildcard `using MyModule`** sets an
   `unresolved_wildcard_using` flag on the enclosing scope. `collect_hints`
   skips bare-identifier missing refs whose scope chain contains a flagged
   scope — any such identifier could legitimately come from the unknown
   module. Getfield checks against *resolved* modules (`Foo.bar` with known
   `Foo`) remain active; suppression only covers bare identifiers.

4. **Explicit-name forms** (`using MyModule: foo`, `import MyModule`,
   `import MyModule: foo`) create bindings with unknown value/type for the
   explicitly named symbols so downstream uses resolve normally. Qualified
   uses `MyModule.foo` are already tolerated because
   `should_mark_missing_getfield_ref` returns false when the LHS is unknown.

5. **Timing:** failure marking runs as a post-pass after `semantic_pass`
   (alongside `resolve_remaining_getfields!` in
   `derived_static_lint_meta_for_root`, `src/layer_static_lint.jl`). It
   cannot happen inside `resolve_import_block`, because an in-pass failure
   may still be retried later via `state.resolveonly` (e.g. a sibling module
   defined further down the file).

6. **No double-reporting:** for an identifier that carries the
   `UnresolvedImport` error, `collect_hints` must report that lint error
   instead of the generic "Missing reference:" warning. The bare-missing-ref
   branch currently wins for identifiers without refs; reorder so `haserror`
   takes precedence.

## Non-goals

- No synthetic "unknown module" sentinel in reference resolution: fake refs
  would leak into completion, hover, and rename.
- No file- or root-level diagnostic filtering; suppression is scope-granular.

## Testing

JuliaWorkspaces test suite additions:

- Unresolved wildcard `using`: statement flagged with `UnresolvedImport`,
  bare unresolved identifiers in the same and nested scopes are silent,
  sibling module scopes are still checked.
- `using MyModule: foo` / `import MyModule: foo`: bindings created, uses of
  `foo` resolve, statement still flagged.
- `import MyModule` + `MyModule.foo`: tolerated, statement flagged.
- Resolved-module typo `Foo.bar` still flagged at `:all`.
- New diagnostic suppressed while the environment is not ready.
- Default lint config now maps to `:all`.
