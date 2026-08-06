# Configuration

```@meta
CurrentModule = JuliaWorkspaces
```

This page is the **authoritative specification** for the three TOML files that
configure the Julia tooling stack:

| File | Configures | Consumed by |
| --- | --- | --- |
| `JuliaLint.toml` | Which diagnostics are reported, and at what severity | The language server, `julialint` |
| `JuliaFormat.toml` | Formatting style and options | The language server, `juliaformat` |
| `JuliaTestItems.toml` | Which files are searched for test items | The language server, the test runners |

The three files deliberately share one grammar: the same discovery rule, the
same `include`/`exclude` globs, the same `[[override]]` mechanism. Learn it once
and it applies everywhere. The shared machinery lives in
[`src/config_common.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/config_common.jl).

## Shared mechanism

### Discovery: the nearest file governs, wholesale

To resolve configuration for a file, JuliaWorkspaces walks up from that file's
directory and uses the **first** config file of the relevant kind it finds. That
file then applies **as a whole**:

- Keys it does not set take their **built-in defaults**.
- They never take a value from a config file further up the tree.
- If no config file is found anywhere above the file, pure defaults apply.

**There is no merging across files.** This is the single most important thing to
understand about the format, and it is a deliberate departure from the earlier
per-key hierarchical merge. Given

```
myproject/
  JuliaLint.toml        # preset = "strict", exclude = ["gen/**"]
  src/
    JuliaLint.toml      # [rules] unused_binding = "off"
    a.jl
```

`src/a.jl` is governed **only** by `src/JuliaLint.toml`. It gets the `default`
preset (not `strict`), no exclusions, and `unused_binding` off. The root file is
irrelevant to it.

The rationale is predictability: to know how a directory is configured you read
exactly one file, rather than reconstructing a merge across an arbitrary number
of them. The cost is that a nested config must restate anything it wants to
keep — copy the parent file and edit it.

Because of that cost, **a nested config file is a last resort, not a normal way
to vary settings by directory**. The normal setup is a single config file of
each kind at the repository root; when a subtree needs different settings, use
an [`[[override]]` block](#path-scoped-overrides) in that one file — it changes
only the keys it names, while a nested file silently resets everything it does
not restate back to the defaults. Reach for a nested file only when a subtree is
genuinely independent of the enclosing project and should not follow its
configuration at all — a vendored repository with its own conventions, say.

Config file names are matched **case-insensitively on the basename**, so
`JuliaLint.toml` and `julialint.toml` both work. A leading dot does **not**:
`.JuliaLint.toml` is not recognised.

### Precedence within a file

```
built-in defaults  <  preset / style  <  top-level keys  <  last matching [[override]]
```

### File selection: `include` and `exclude`

Every config file accepts two top-level glob lists, relative to the directory
holding the config file:

```toml
include = ["src/**", "test/**"]
exclude = ["**/generated_*.jl"]
```

- An empty or absent `include` selects everything.
- `exclude` always wins over `include`.
- An excluded file is not linted / formatted / searched for test items at all.

A config file always validates itself even when its own globs exclude the
directory it lives in — otherwise a mistake in `exclude` could hide the very
diagnostic that would explain it.

### Glob syntax

Gitignore-style, implemented by
[`GlobPattern`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/config_common.jl):

| Pattern | Matches |
| --- | --- |
| `*` | Any run of characters **within** one path segment |
| `**` | Any number of path segments |
| `?` | A single character, not a separator |
| `[abc]`, `[!abc]` | A character class, optionally negated |
| `foo/` (trailing slash) | Everything below the `foo` directory |
| `/foo.jl` (leading slash) | Anchored to the config file's directory |
| `foo.jl` (no separator) | Matches at **any** depth, like gitignore |

Paths are normalised to `/` before matching, so `test\**` and `test/**` behave
identically. Matching is case-insensitive on Windows.

### Path-scoped overrides

Overrides are **the** mechanism for giving part of a tree different settings.
Any config file may carry repeated `[[override]]` blocks. Each takes a required
`paths` glob list and re-scopes a subset of the file's own keys to the files
those globs match. **Later blocks win over earlier ones.**

```toml
[rules]
unused_binding = "error"

[[override]]
paths = ["test/**"]

[override.rules]
unused_binding = "off"
```

This covers the common "different settings for tests" case — and anything else
that would tempt one to add a second config file. Prefer an override whenever
the subtree is still part of the same project: it varies exactly the keys it
names, where a nested config file would have to restate everything else it
wants to keep.

### `config-version`

Every file accepts an optional `config-version` integer. The current format is
version `1`, and an absent key means `1`.

It is reserved from the first release rather than added when first needed: a
released tool that does not know the key can only report it as an unknown key
when it meets a file written for a later format, and that cannot be fixed
retroactively in copies already installed. A file declaring a version this tool
does not understand is told to upgrade the tooling.

### Superseded configuration

Because the nearest config governs wholesale, a config file in a subdirectory
does not extend the one above it — it *replaces* it, and since nested config
files are discouraged (use [`[[override]]`](#path-scoped-overrides) instead),
that replacement is more often an accident than a decision. It is also silent by
nature, so a config file with another of the same kind in an enclosing directory
reports a `shadowed_config` diagnostic (`info` by default) naming the file it
takes over from.

This is the price of choosing nearest-wins over cascading. The alternative is
that a config dropped into a subdirectory — a vendored repository, a copied
example, a half-finished subpackage extraction — quietly voids the project's own
configuration for that subtree. It is an ordinary rule, so a project that
genuinely wants independent subtrees sets `shadowed_config = "off"`.

### Validation

Unknown keys and invalid values are reported as diagnostics **on the config file
itself**, under the `config_errors` rule. Keys from the previous flat schema are
recognised specially and reported with the name of their replacement rather than
a bare "invalid key", so an existing config tells its owner what to write
instead.

## `JuliaLint.toml`

```toml
preset = "default"
include = ["**/*.jl"]
exclude = ["gen/**"]

[rules]
unused_binding = "warning"
nothing_comparison = "error"
index_from_length = "off"
missing_reference = { severity = "warning", scope = "symbols" }

[[override]]
paths = ["test/**"]

[override.rules]
unused_binding = "off"
```

### Rule ids

A **rule** is the unit a user enables, disables, or re-prioritises. Rule ids are
the stable public contract of the linter: they appear in this file, on
[`Diagnostic`](@ref)`.code`, as the LSP diagnostic `code`, and as the SARIF
`ruleId` in `julialint --format sarif` (which is what makes per-rule suppression
in GitHub Code Scanning work).

A rule usually groups several internal `StaticLint.LintCodes` members that a user
would want to configure together — `nothing_comparison` covers both
`NothingEquality` and `NothingNotEq`. The mapping is declared once in
[`src/lint_rules.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/lint_rules.jl)
as `LINT_RULES`; `LINTCODE_TO_RULE` inverts it.

### Severities

Every rule takes one of:

`"off"` · `"hint"` · `"info"` · `"warning"` · `"error"`

Severity is a single mechanism doing three jobs: `"off"` disables a rule, the
middle values control how an editor renders it, and `"error"` makes `julialint`
exit non-zero. There is no separate enable/disable list.

The configured severity **replaces** the built-in one. Diagnostic *tags* do not
follow it: an unused binding stays tagged `unnecessary` (so editors grey it out)
whether you report it as a hint or an error, because the tag describes the
finding, not its importance.

### Rules with options

A rule that takes parameters is written as a table instead of a bare string,
with the severity under the reserved `severity` key:

```toml
[rules]
missing_reference = { severity = "warning", scope = "symbols" }

# or, equivalently
[rules.missing_reference]
severity = "warning"
scope = "symbols"
```

Omitting `severity` keeps the preset's value while still setting options. No
rule option may be named `severity`; this is enforced by the validator.

### Presets

A preset is a **named severity baseline**, nothing more — `[rules]` entries are
deltas applied on top of it.

| Preset | Intent |
| --- | --- |
| `minimal` | Only outright breakage: syntax, test item, TOML and config errors, include-graph problems, and invalid `const` declarations. Everything else off. |
| `default` | The out-of-the-box behaviour. |
| `strict` | Every rule on, with hints and informational findings promoted to warnings. |

Because a preset is just a `Dict{Symbol,Symbol}`, adding one later needs no new
mechanism.

A preset name **floats**: it tracks the tool rather than pinning a frozen rule
set, so upgrading the tooling can change what a preset reports. To keep that
from breaking projects on upgrade, a rule that did not exist before enters
existing presets as `"off"`; promoting it is a deliberate, changelogged change.
Version-pinning syntax (`preset = "default@2"`) may be added later — bare names
will keep floating, so nothing written today changes meaning.

Every preset must classify every rule. This is enforced when `lint_rules.jl`
loads, so a rule added without a decision fails the build rather than appearing
in everyone's `default` at whatever severity a fallback happened to pick.

### The rules

| Rule | Default | Reports |
| --- | --- | --- |
| `syntax_errors` | `error` | Julia syntax errors |
| `syntax_warnings` | `off` | Julia syntax warnings |
| `testitem_errors` | `error` | Malformed `@testitem` blocks |
| `toml_syntax_errors` | `error` | TOML syntax errors in config, `Project.toml`, `Manifest.toml` |
| `config_errors` | `error` | Invalid keys/values in any of the three config files |
| `shadowed_config` | `info` | A config file that supersedes another of the same kind in an enclosing directory |
| `incorrect_call_args` | `info` | Wrong argument count/type; calls to method-less functions |
| `incorrect_iter_spec` | `info` | Loop iterators that will likely error |
| `index_from_length` | `info` | Indexing off `length`/`size` instead of `eachindex`/`axes` |
| `nothing_comparison` | `info` | `== nothing` / `!= nothing` instead of `isnothing`/`===` |
| `const_if_condition` | `info` | Boolean literal or unbracketed assignment as an `if` condition |
| `pointless_boolean` | `info` | `&&`/`\|\|` whose first argument is a boolean literal |
| `invalid_type_declaration` | `info` | Non-`DataType` in a type declaration |
| `unused_type_parameter` | `hint` | Declared but unused type parameters |
| `module_name` | `info` | A module named after its parent |
| `type_piracy` | `info` | Type piracy; overloading `!=` instead of `==` |
| `unused_function_argument` | `hint` | Declared but unused function arguments |
| `duplicate_function_argument` | `info` | Repeated argument names in a signature |
| `kw_default_mismatch` | `info` | Keyword defaults not matching the argument type |
| `literal_use` | `info` | Inappropriate use of literal values |
| `break_continue` | `info` | `break`/`continue` outside a loop |
| `global_const_decl` | `info` | Type declarations on globals; `const` on locals |
| `const_decl` | `info` | Invalid `const` declarations and redefinitions |
| `unused_binding` | `hint` | Variables assigned but never used |
| `relative_import` | `info` | A relative import with more dots than available nesting |
| `include_errors` | `warning` | Circular, duplicate, missing or unreadable `include`s |
| `missing_reference` | `warning` | Unresolved references. Option `scope`: `"none"`, `"symbols"`, `"all"` (default) |
| `unresolved_import` | `warning` | Imports whose target could not be resolved |

### Rules and code actions

A quick fix is withdrawn when the rule it fixes is turned off: with no
diagnostic to act on, offering to "fix" it would contradict the user. Refactorings
and source actions (`ExpandFunction`, the raw-string rewrites, the docstring
actions) fix no rule and are never affected by lint configuration — they are
editor capabilities, not fixes.

The link is declared by the `rule` field of `_ActionDef` in
[`src/layer_actions.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/layer_actions.jl);
`nothing` means "not a fix for anything".

## `JuliaFormat.toml`

```toml
style = "minimal"
include = ["**/*.jl"]
exclude = ["gen/**"]

[options]
margin = 92
always_for_in = true

[[override]]
paths = ["docs/**"]

[override.options]
margin = 80
```

`style` is the preset and `[options]` are deltas on top of it — the same shape as
`preset` and `[rules]` in the lint file.

| Key | Default | Values |
| --- | --- | --- |
| `style` | `"minimal"` | `default`, `yas`, `blue`, `sciml`, `minimal`, `runic` |
| `[options]` | — | Any field of `JuliaFormatter.Options` |

The `runic` style accepts **no** options; combining it with a non-empty
`[options]` is reported as a configuration error rather than silently ignored.

An excluded file is not a formatting failure. Callers formatting many files
should ask [`is_format_excluded`](@ref) first and skip, rather than letting
[`get_format_edits`](@ref) report it as an error.

### Relation to `.JuliaFormatter.toml`

JuliaWorkspaces **never** reads JuliaFormatter.jl's own `.JuliaFormatter.toml`.
`JuliaFormatter.format_text` is always called with an explicit option set derived
solely from `JuliaFormat.toml`. The files are deliberately distinct: one file
interpreted by two independently versioned tools would diverge silently.

## `JuliaTestItems.toml`

```toml
include = ["src/**", "test/**"]
exclude = ["test/manual/**"]
```

Version 1 is **discovery scope only** — it controls which files are searched for
`@testitem` blocks. Execution settings (worker counts, timeouts, environment
variables, tag filters, per-item defaults) are deliberately not part of it yet;
they will arrive as additional sections under the same grammar.

Note the division of labour: this file decides *where test items are found*,
while the `testitem_errors` rule in `JuliaLint.toml` decides *whether malformed
test items are reported as diagnostics*.

## Implementation notes

### Query structure

Configuration resolution is split into two Salsa queries per file kind so that
parsing happens once per config file rather than once per configured file:

- `derived_parsed_lint_config(rt, config_uri)` — parses one `JuliaLint.toml`
  into a `ParsedLintConfig` (preset, rule table, filters, override blocks).
- `derived_effective_lint_config(rt, uri)` — finds the governing config, then
  resolves preset < `[rules]` < overrides **for that one file**, yielding an
  [`EffectiveLintConfig`](@ref).

Editing a config file invalidates only through `derived_toml_syntax_tree`;
adding or removing one invalidates through `derived_text_files`. Formatting has
the same shape via `derived_format_configuration`, as does test-item discovery
via `derived_testitems_selected`.

Every value reachable from a config struct has well-defined `==` and `hash`
(`GlobPattern` compares by its written pattern, not its compiled regex) so that
Salsa can backdate correctly when a config edit turns out not to change the
effective result.

### Where rules are applied

`StaticLint.LintOptions` — the 14 boolean gate that `check_all` consults — is
derived from the effective config by `lint_options_from_config`: a category is
enabled when **any** rule mapping into it is not `"off"`. Because several rules
can share one category, and several rules have no category at all, that gate is
necessarily coarse.

The precise per-rule decision therefore happens where diagnostics are emitted,
in `_emit_hint_diagnostics!`
([`src/lint_emission.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/lint_emission.jl)):
each finding's rule id is looked up, an `"off"` rule is skipped, and the
configured severity replaces the built-in one. This keeps rule granularity
independent of StaticLint's internal check structure, at the cost of computing a
small number of findings that are then discarded.

`_emit_hint_diagnostics!` is shared by both static-lint pipelines — the
whole-closure pass in `layer_static_lint.jl` and the per-file pass in
`layer_file_analysis.jl` — which differ only in how a call mismatch is described
and in the container they collect into.

### Migrating from the old schema

The previous flat schema (`static-lint`, `nothingcomp`, `missing-refs`,
`break-continue`, …) is **not** honoured. Every old key produces a diagnostic
naming its replacement:

| Old | New |
| --- | --- |
| `static-lint = false` | `preset = "minimal"`, or individual `[rules]` entries |
| `syntax-errors = false` | `[rules] syntax_errors = "off"` |
| `nothingcomp = false` | `[rules] nothing_comparison = "off"` |
| `missing-refs = "symbols"` | `[rules] missing_reference = { scope = "symbols" }` |
| `useoffuncargs = false` | `[rules] unused_function_argument = "off"` |
| `break-continue = false` | `[rules] break_continue = "off"` |

The full table is `_LINT_CONFIG_MIGRATIONS` in
[`src/layer_diagnostics.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/layer_diagnostics.jl).
For the formatter, top-level option keys move into `[options]`.

Because old keys are inert rather than an error, a project that relied on
`static-lint = false` will start reporting lint diagnostics again after
upgrading until its config is migrated.
