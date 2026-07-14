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
   `unresolved_wildcard_import` flag on the enclosing scope. `collect_hints`
   skips bare-identifier missing refs whose scope chain contains a flagged
   scope — any such identifier could legitimately be an export of the
   unknown module. The scope walk stops at module boundaries (matching
   `resolve_ref` semantics): a `module` nested inside a flagged scope does
   *not* inherit suppression, since Julia modules don't inherit `using`s.
   Getfield checks against *resolved* modules (`Foo.bar` with known `Foo`)
   remain active; the flag only covers bare identifiers.

4. **Synthetic bindings for every name an unresolved import would bind** —
   the explicit names in `using/import M: foo, bar`, `as`-aliases, the last
   path component of `import A.B`, and the module name itself for both
   `import MyModule` and wildcard `using MyModule`. The user has asserted
   these names exist, so we bind them:

   - Created *eagerly* in `resolve_import_block`'s failure branch (the same
     spot that schedules the `state.resolveonly` retry), as
     `Binding(arg, nothing, nothing, [])` on the import arg. `val === nothing
     && type === nothing` is the discriminator for "synthetic": real import
     bindings from `_mark_import_arg` always carry a non-nothing `val`.
     Creation cannot wait for a post-pass — reference resolution, including
     the Delayed function-body passes, has already run by then.
   - The binding flows into `scope.names` through the normal `add_binding`
     traversal, so downstream uses of `bar` *resolve* (goto-definition and
     find-references link to the import statement) instead of being
     suppressed, and getfield uses (`bar.x`, `MyModule.foo`) are tolerated
     because `should_mark_missing_getfield_ref` returns false for a binding
     with unknown type.
   - **Late resolution fills the binding in place.** When the ResolveOnly
     retry re-runs `resolve_import_block`, an arg whose existing ref is a
     synthetic import binding must not short-circuit as resolved: re-run
     `_get_field`, and on success mutate `b.val`/`b.type` on the *same*
     `Binding` object (plus the usual `_mark_import_arg` side effects, e.g.
     registering a wildcard module). Downstream refs hold that object, so
     they all see the real target — behavior converges to today's
     resolved-import shape.
   - **Late resolution may still miss the name:** in `using A: bar`, `A` can
     late-resolve (e.g. a sibling module defined further down) while `bar`
     doesn't exist in it. The re-run `_get_field` fails, the binding stays
     synthetic (it must be left in place, not cleared — uses of `bar` remain
     resolved and silent), and the post-pass flags `bar` with
     `UnresolvedImport`. This is deliberately identical to the immediate
     "`A` resolved but `bar` missing" case: the root cause is reported once,
     at the import site.
   - Post-pass detection of "still unresolved": module-path components via
     `!hasref` (they never get synthetic bindings), bound-name components
     via the synthetic-binding discriminator.

   Generic bare-missing-ref reporting no longer applies to identifiers
   inside `using`/`import` statements at all; the `UnresolvedImport` marking
   pass is the sole reporter there.

   In every form, the `UnresolvedImport` diagnostic goes on the first
   unresolved component of the *module path inside the import statement* —
   never on downstream uses:

   - `import MyModule` → flag `MyModule` in the import statement;
     `MyModule.foo` elsewhere is silent.
   - `using MyModule: MyModule` → flag the `MyModule` *before* the colon
     (the module path). The `MyModule` after the colon is an explicitly
     named symbol and gets a synthetic binding like any other, so
     `MyModule.foo` elsewhere is silent — this self-import pattern must
     behave exactly like `import MyModule`.
   - `using A.B.C` where `A` resolves but `B` doesn't → flag `B`.

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

- No synthetic "unknown module" sentinel whose lookups always succeed: an
  entire fake module would leak invented names into completion, hover, and
  rename. Synthetic bindings are restricted to names the user explicitly
  wrote in an import statement.
- No file- or root-level diagnostic filtering; suppression is scope-granular.

## Testing

JuliaWorkspaces test suite additions:

- Unresolved wildcard `using`: statement flagged with `UnresolvedImport`,
  bare unresolved identifiers in the same and nested scopes are silent,
  sibling module scopes are still checked.
- `using MyModule: foo` / `import MyModule: foo`: uses of `foo` resolve to
  the synthetic binding and are silent, statement still flagged; *other*
  unresolved identifiers in the same scope are still reported.
- Late resolution, name exists: `using .A: bar` textually above
  `module A; bar() = 1; end` — no diagnostics at all, and the binding's
  `val` is filled in by the retry (uses of `bar` point at the real target).
- Late resolution, name missing: `using .A: baz` textually above a
  `module A` that defines no `baz` — `UnresolvedImport` on `baz` (not on
  `A`), uses of `baz` are silent.
- `using A: typo` with `A` immediately resolvable but lacking `typo`:
  `UnresolvedImport` on `typo`, uses of `typo` are silent.
- `import MyModule` + `MyModule.foo`: the `MyModule` component inside the
  import statement is flagged with `UnresolvedImport`; the downstream
  `MyModule.foo` use produces no diagnostic.
- `using MyModule: MyModule` + `MyModule.foo`: same behavior as
  `import MyModule` — the module path before the colon is flagged, the
  explicitly named `MyModule` binds, downstream use is silent.
- Resolved-module typo `Foo.bar` still flagged at `:all`.
- New diagnostic suppressed while the environment is not ready.
- Default lint config now maps to `:all`.
