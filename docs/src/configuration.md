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

### Settings: the nearest file governs, wholesale

To resolve the *settings* for a file — `preset`, `[rules]`, `style`,
`[options]`, `[[override]]` — JuliaWorkspaces walks up from that file's
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
not restate back to the defaults.

Config file names are matched **case-insensitively on the basename**, so
`JuliaLint.toml` and `julialint.toml` both work. A leading dot does **not**:
`.JuliaLint.toml` is not recognised.

### Scope: every enclosing file must admit the file

Scope is the one thing that does **not** follow nearest-wins. A file is searched,
linted or formatted only if **every** config file of that kind above it admits it
through its [`include`/`exclude`](#file-selection-include-and-exclude) globs,
each evaluated relative to that config file's own directory. "Above it" stops at
the root of the tree in question — a workspace folder here — so a config file
outside that tree has no say.

**A nested config may narrow scope, never widen it.** Given

```
myproject/
  JuliaTestItems.toml           # exclude = ["packages/**"]
  packages/
    Foo/                        # a vendored repository
      JuliaTestItems.toml       # include = ["**/*.jl"]
      src/Foo.jl
```

`packages/Foo/src/Foo.jl` is **not** searched for test items. The vendored
config governs the settings of its own subtree, and it may exclude more of it,
but it cannot take back the enclosing project's decision to leave `packages/`
alone.

This is how you seal a subtree you do not own: write the exclusion in the
config file at the root of the project that vendors it. It is also why an
ancestor's `exclude` is worth reaching for before a nested config file — the
parent always has the last word on what is in scope.

The rule is the same one git applies to `.gitignore` (a file cannot be
re-included once a parent directory is excluded), and the same split Ruff makes
between hierarchical rule settings and top-level file discovery. The alternative
— letting the innermost file decide scope on its own — hands vendored code a
veto over the project vendoring it.

### Precedence within a file

```
built-in defaults  <  preset / style  <  top-level keys  <  last matching [[override]]
```

### File selection: `include` and `exclude`

Every config file accepts two top-level glob lists, relative to the directory
holding **that** config file. When several config files of one kind enclose a
file, each is evaluated against its own directory and the results are
intersected — see [Scope](#scope-every-enclosing-file-must-admit-the-file):

```toml
include = ["src/**", "test/**"]
exclude = ["**/generated_*.jl"]
```

- An empty or absent `include` selects everything.
- `exclude` always wins over `include`.
- An excluded file is not linted / formatted / searched for test items at all.

A config file always validates itself even when **its own** globs exclude the
directory it lives in — otherwise a mistake in `exclude` could hide the very
diagnostic that would explain it. That exemption stops at its own file: a config
inside a subtree an **enclosing** `JuliaLint.toml` excluded reports nothing at
all, along with the rest of that subtree. Excluding a vendored repository should
not leave you reading diagnostics about its config files.

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

One asymmetry in that table is easy to trip over: a pattern **containing** a
separator anywhere is anchored to the config file's directory even without a
leading `/`. So `excluded/**` matches `excluded/a.jl` but **not**
`nested/excluded/a.jl` — write `**/excluded/**` for the latter. Only a pattern
with no separator at all, like `generated.jl`, matches at every depth. This
matters more now that a root config's patterns govern subtrees several levels
down.

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

Because the nearest config governs its settings wholesale, a config file in a
subdirectory does not extend the one above it — it *replaces* it, and since
nested config files are discouraged (use
[`[[override]]`](#path-scoped-overrides) instead), that replacement is more often
an accident than a decision. It is also silent by nature, so a config file with
another of the same kind in an enclosing directory reports a `shadowed_config`
diagnostic (`info` by default) naming the file it takes over from.

Only settings are superseded; the message says so. The outer file's
`include`/`exclude` keep applying, because
[scope composes over the whole chain](#scope-every-enclosing-file-must-admit-the-file).

`JuliaTestItems.toml` never reports this: version 1 of that file has nothing but
scope keys, so a nested one supersedes nothing at all.

It is an ordinary rule, so a project that deliberately keeps nested settings
files sets `shadowed_config = "off"`.

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

Not every rule is backed by the semantic StaticLint pass. Purely syntactic
rules run on the JuliaSyntax tree of a single file alone
(see [`src/lint_syntax_rules/`](https://github.com/julia-vscode/JuliaWorkspaces.jl/tree/main/src/lint_syntax_rules), one file per rule):

| Rule | Finds |
| --- | --- |
| `nan_comparison` | `x == NaN` / `x != NaN`, which always yield the same answer; use `isnan`. |
| `duplicate_branch_condition` | An `elseif` condition identical to an earlier condition in the same chain, making the branch unreachable. Conditions containing arbitrary function or macro calls are exempt, since each evaluation may legitimately differ. |
| `string_concat_style` | A string literal concatenated with `*`; prefer interpolation or `string(...)`. |
| `bare_using` | `using Foo` without an explicit name list; prefer `using Foo: x, y` or `import Foo`. |
| `debug_statement` | A leftover `@show`. |
| `async_task` | `@async`, which pins the task to the current thread; consider `Threads.@spawn`. |
| `detached_docstring` | A string that looks like a docstring but is not attached to anything, because a comment or a blank line sits between it and the expression it documents. The text is evaluated and discarded. |

All of these are `"off"` outside the `strict` preset, except `detached_docstring`,
which reports as a warning in every preset but `minimal`: a severed docstring
discards its text outright rather than expressing a style preference.

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
The one exception so far is `detached_docstring`, which found its way into
`default` directly because its finding is outright discarded program text — and
even that class of rule enters at `"warning"` at most, never `"error"`, so an
upgrade can never change `julialint`'s exit status.
Version-pinning syntax (`preset = "default@2"`) may be added later — bare names
will keep floating, so nothing written today changes meaning.

Every preset must classify every rule. This is enforced when `lint_rules.jl`
loads, so a rule added without a decision fails the build rather than appearing
in everyone's `default` at whatever severity a fallback happened to pick.

### Rules that are off by default

Three rules are classified `off` in `default` despite being long-standing
checks: `incorrect_call_args`, `missing_reference` and `unresolved_import`.

They share a limitation. Each needs a complete picture of something the
analysis often cannot see in full — the method set of a callee, every name a
module actually defines, the environment an import resolves against. Where that
picture is incomplete the rule reports anyway, and on a corpus sweep of the 100
most-depended-upon registered packages their sampled false-positive rates were
93%, 78% and 77% respectively, together accounting for roughly 92% of every
false positive measured. A check that is wrong more often than right should not
fire on a project that never asked for it.

All three remain on in `strict`, and any project can restore one:

```toml
[rules]
missing_reference = "warning"
```

They are worth turning on deliberately — they find real bugs, and the sweep that
measured their false positives also turned up genuine `UndefVarError`s and
`MethodError`s through them. Expect to spend time tuning around the noise.

Note that an untitled/unsaved buffer has no path, so no `JuliaLint.toml` can
govern it; such buffers always lint under `default` and cannot opt back in.

### The rules

| Rule | Default | Reports |
| --- | --- | --- |
| `syntax_errors` | `error` | Julia syntax errors |
| `syntax_warnings` | `off` | Julia syntax warnings |
| `lowering_errors` | `error` | Shapes Julia's lowering rejects (invalid assignment targets, malformed signatures, duplicate struct fields, …) — the file will not load. v2 only (`set_v2_enabled!`); when active it supersedes `duplicate_function_argument`/`break_continue`/`global_const_decl` |
| `soft_scope_ambiguity` | `information` | Julia's soft-scope ambiguity warning, statically: an un-annotated assignment in a top-level `for`/`while`/`try` to a name that is also a plain module global (Julia warns at run time and treats it as a new local). v2 only (`set_v2_enabled!`) |
| `analysis_boundary` | `off` | Opt-in: one notice per construct the linter cannot see through (a computed or function-body `include`, an interpolated `@eval`, a runtime `eval`, a `using`/`import` inside `try`/`if`, a macro whose expansion failed) naming the rules it silences in that module. v2 only (`set_v2_enabled!`); see [Analysis boundaries](@ref) |
| `testitem_errors` | `error` | Malformed `@testitem` blocks |
| `toml_syntax_errors` | `error` | TOML syntax errors in config, `Project.toml`, `Manifest.toml` |
| `project_file_errors` | `error` | Structure in a `Project.toml` that Pkg rejects (a malformed uuid, an extension trigger that is no declared weakdep, a `[sources]` entry with neither url nor path). v2 only (`set_v2_enabled!`) |
| `project_file_warnings` | `warning` | Inconsistencies Pkg tolerates until the section is used (a target dep missing from `[extras]`, a stale manifest, a dangling `[sources]`/`[workspace]` path). v2 only (`set_v2_enabled!`) |
| `manifest_errors` | `info` | A `Manifest.toml` shape the tooling cannot interpret. v2 only (`set_v2_enabled!`) |
| `config_errors` | `error` | Invalid keys/values in any of the three config files |
| `shadowed_config` | `info` | A config file that supersedes another of the same kind in an enclosing directory |
| `environment_errors` | `info` | A project/test environment that could not be resolved, reported on its `Project.toml` |
| `incorrect_call_args` | `off` | Wrong argument count/type; calls to method-less functions. Off by default; see “Rules that are off by default” below |
| `incorrect_iter_spec` | `info` | Loop iterators that will likely error |
| `index_from_length` | `info` | Indexing off `1:length(...)`/`1:size(...)` instead of `eachindex`/`axes`. Ranges that don't start at 1 (`2:length(x)`) are not flagged — they have no direct rewrite |
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
| `relative_import` | `off` | A relative import with more dots than available nesting |
| `include_errors` | `warning` | Circular, duplicate, missing, unreadable, or statically unresolvable (computed-path) `include`s. A computed include also disables missing-reference checks in the module it appears in, since the included file's contents are unknown to the analyzer |
| `missing_reference` | `off` | Unresolved references. Option `scope`: `"none"`, `"symbols"`, `"all"` (default). Off by default; see “Rules that are off by default” below |
| `unresolved_import` | `off` | Imports whose target could not be resolved. Off by default; see “Rules that are off by default” below |
| `missing_compat` | `off` | A package `[deps]`/`[extras]`/`[weakdeps]` entry (stdlibs included) or `julia` without a `[compat]` entry. Options: `check_julia`, `check_extras`, `check_weakdeps` (booleans, default `true`), `ignore` (array of names). v2 only (`set_v2_enabled!`) |
| `unused_dependency` | `off` | A package `[deps]` entry that no `using`/`import` in the package's source (or its extensions) references. Option: `ignore` (array of names). v2 only (`set_v2_enabled!`) |
| `unbound_type_parameter` | `off` | A method `where` parameter no argument type binds (undefined at run time). v2 only (`set_v2_enabled!`) |
| `undocumented_public_name` | `off` | An exported/`public` name a workspace package declares without a docstring; a submodule without a module docstring. v2 only (`set_v2_enabled!`) |

### Package-quality rules (Aqua.jl parity)

!!! note "v2 only"
    All four rules in this section are produced by the v2 analysis stack, i.e.
    a workspace with `set_v2_enabled!(jw, true)`. With the flag off (the
    default) they emit nothing, whatever their configured severity.

Four rules port the statically-checkable parts of
[Aqua.jl](https://github.com/JuliaTesting/Aqua.jl)'s package-quality test
suite into the linter, so they run continuously in the editor and in
`julialint` instead of only at test time. All four ship `"off"` outside the
`strict` preset.

| Aqua check | Rule | Notes |
| --- | --- | --- |
| `deps_compat` | `missing_compat` | Same semantics: `[compat]` entries required for `julia` and every `[deps]`/`[extras]`/`[weakdeps]` entry, standard libraries included. The `check_julia`/`check_extras`/`check_weakdeps` options mirror Aqua's keyword arguments; `ignore` exempts named dependencies. Only packages (`name` + `uuid`) are checked. |
| `stale_deps` | `unused_dependency` | The static face of the check: a `[deps]` entry that no `using`/`import` in `src/` or `ext/` references. Aqua instead loads the package and accepts dependencies that get loaded *transitively*; a static analysis cannot see loads, so a dependency needed only for side effects belongs on the rule's `ignore` list. An `include` the analyzer cannot resolve silences the whole check for that package — the unseen file could contain the import. |
| `unbound_args` | `unbound_type_parameter` | Mirrors `Test.detect_unbound_args` semantics on the method signature: bound through invariant type parameters at any depth, `Type{T}`, every branch of a `Union`, covariant upper bounds, and the `N` of `Vararg{T,N}`; never through return types, lower bounds, or a trailing vararg's element type. Keyword argument types bind (they reach the keyword-body method positionally). A parameter that is never mentioned again is `unused_type_parameter`'s finding instead. |
| `undocumented_names` | `undocumented_public_name` | Every exported/`public` name a workspace package declares needs a docstring, and every submodule needs a module docstring; the package's root module is exempt (the README is its docstring). Re-exported names are skipped — their docstrings live upstream. Works on every Julia version (Aqua's check needs ≥ 1.11 at test time). |

The remaining Aqua checks have no static counterpart here: `undefined_exports`
is already covered by `missing_reference` (an `export`/`public` of an
undefined name is an unresolved reference), `piracies` by `type_piracy`, and
`ambiguities`, `persistent_tasks` and `project_extras` are inherently
run-time checks (method-table intersection, precompilation-process behavior,
and a `test/Project.toml` comparison that only matters for packages
supporting Julia ≤ 1.1).

### Analysis boundaries

!!! note "v2 only"
    Everything in this section describes the v2 analysis stack, i.e. a
    workspace with `set_v2_enabled!(jw, true)`. With the flag off (the
    default) the behaviour is the legacy one: a computed include is an
    `include_errors` warning, no `analysis_boundary` notice exists, and an
    unresolved import is always reported as `unresolved_import`.

Some constructs put part of a program beyond static analysis: an `include`
whose path is computed or that runs inside a function body, an `@eval` with
`$` interpolation or a bare `eval(...)` call, a `using`/`import` guarded by
`try` or `if`, and a top-level macro the linter does not model whose expansion
could not be obtained (the dynamic analysis process is off, the file has no
environment, or the macro raised an error when expanded). Whatever such a
construct defines or brings into scope is invisible, so any rule that would
otherwise report false positives — `missing_reference`, `incorrect_call_args`,
`type_piracy`, `invalid_type_declaration`, `kw_default_mismatch` and
`incorrect_iter_spec` — is silently switched off in the smallest scope that
contains the construct, its module. A macro the dynamic analysis process
*did* expand successfully is not a boundary: the names its expansion defines
are analyzed like ordinary code.

The `default` and `minimal` presets say nothing about this. The linter never
reports on code merely because it cannot analyze it. To find out what is
holding analysis back, opt in:

```toml
[rules]
analysis_boundary = "warning"   # or "error" for CI
```

(`preset = "strict"` includes it at `warning`.) Each boundary construct then
gets one diagnostic naming the rules it suppresses; rewrite it — a literal
`include` path, an explicit list of definitions instead of an interpolated
`@eval`, an unconditional import — and the full diagnostic set comes back for
that module.

Environments are boundaries too. An `ext/` file whose weak-dependency
triggers resolve in no reachable environment, and any file whose owning
environment could not be resolved at all (a failed test-environment or
scratch-project resolution — see the `environment_errors` diagnostic on the
project file), has its `unresolved_import` findings reported as
`analysis_boundary` notices instead: the imports were checked against a
fallback environment, which says nothing about the code.

Which environment a file is checked against follows how Julia would load it:
package code (`src/`, `ext/`, `deps/`) against the package's own project (an
extension against a project that also holds its triggers), test files against
the test environment, a folder with its own `Project.toml` against that
project, and every other file — scripts under `perf/`, `benchmark/`,
`examples/`, a `docs/` without a project — against the active project, with
the standard libraries visible as they are on Julia's default load path.
Only package code has to declare a standard library it imports.

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

Because the file has only scope keys, the
[chain rule](#scope-every-enclosing-file-must-admit-the-file) is all there is to
its resolution: a `JuliaTestItems.toml` in a subdirectory can exclude more of
that subdirectory, and nothing else.

TestItemRunner.jl reads the same file with the same semantics, so
`@run_package_tests` and the VS Code test explorer agree on which files are
searched. Both root the chain at the tree they are given: config files above a
workspace folder do not reach the editor, and config files above the path handed
to the runner do not reach it either. Pointing the runner at a subdirectory
therefore scopes discovery to that subdirectory, exactly as opening it as a
workspace folder would.

## Implementation notes

### Query structure

Configuration resolution is split into three Salsa queries per file kind so that
parsing happens once per config file rather than once per configured file, and so
that scope and settings invalidate independently:

- `derived_parsed_lint_config(rt, config_uri)` — parses the *settings* of one
  `JuliaLint.toml` into a `ParsedLintConfig` (preset, rule table, override
  blocks).
- `derived_lint_path_filter(rt, config_uri)` — parses the `include`/`exclude`
  globs of one `JuliaLint.toml`. Deliberately separate from the above: were the
  globs part of `ParsedLintConfig`, editing `[rules]` would invalidate every
  file's scope, and editing `exclude` every file's rules.
- `derived_effective_lint_config(rt, uri)` — resolves scope over the whole
  `ancestor_configs` chain, then preset < `[rules]` < overrides from the nearest
  config alone, yielding an [`EffectiveLintConfig`](@ref).

Editing a config file invalidates only through `derived_toml_syntax_tree`;
adding or removing one invalidates through `derived_text_files`. Formatting has
the same shape via `derived_format_path_filter` and
`derived_format_configuration`, as does test-item discovery via
`derived_testitems_path_filter` and `derived_testitems_selected`.

The list of config files of one kind is sorted, not merely collected: it is a
dependency of every file's scope, and it is built from a `Set`, so an unsorted
result would change on unrelated file additions and defeat backdating.

Every value reachable from a config struct has well-defined `==` and `hash`
(`GlobPattern` compares by its written pattern, not its compiled regex) so that
Salsa can backdate correctly when a config edit turns out not to change the
effective result.

### Scope can prune the directory walk

Scope is resolved per file by the queries above, which is what a language server
needs: it must still see a file no config selected in order to answer
go-to-definition across it.

A batch tool does not. `juliati` in a repository that keeps a few hundred
thousand `.jl` files of test data under an excluded directory should never
`readdir` that directory at all — the ~64 s spent listing such a tree dwarfs the
~35 ms of listing `src/` and `test/`. So the walk itself can honour one or more
config kinds:

```julia
JuliaWorkspaces.workspace_from_folders([path]; scope=:testitems)
```

`scope` is a `Symbol` or a collection of them, drawn from `:testitems`, `:lint`
and `:format`; the default `nothing` walks everything, exactly as before.
[`collect_workspace_paths`](@ref) does the walking and documents the details.

Three properties make this safe:

- **Directory pruning is conservative.** A directory is skipped only when no
  file below it could be selected — decided by `dir_selected`, which asks
  whether an `exclude` pattern covers the whole subtree and whether any
  `include` pattern could still match beneath it. `exclude = ["src/*"]` prunes
  each directory directly inside `src`, but never `src` itself.
- **Nested configs still compose.** Because a nested config may only
  [narrow scope](#scope-every-enclosing-file-must-admit-the-file), a directory
  ruled out by an ancestor can never be reclaimed below it, so it is safe to
  stop descending there. Config files themselves are always read from a
  surviving directory, so they keep reporting their own diagnostics.
- **Several kinds compose as a union.** A caller building one workspace to serve
  lint, format and test-item queries alike passes all three kinds, and a file any
  one of them wants is read. A kind with no config file of its own selects
  everything, so asking for several kinds prunes only what all of them exclude.

A malformed config file fails open — it prunes nothing, and its `config_errors`
diagnostic is reported as usual once it is part of the workspace.

The one thing to know before excluding a subtree: **its `Project.toml` and
`Manifest.toml` are not read either.** A package that is in scope but whose test
environment reaches into the excluded subtree — through `[sources]`, or a
relative `dev` path — will have that environment resolved incompletely. Exclude
directories that hold data, not directories that hold environments an in-scope
package depends on.

### Where rules are applied

`StaticLint.LintOptions` — the 14 boolean gate that `check_all` consults — is
derived from the effective config by `lint_options_from_config`: a category is
enabled when **any** rule mapping into it is not `"off"`. Because several rules
can share one category, and several rules have no category at all, that gate is
necessarily coarse.

The precise per-rule decision therefore happens in exactly one place: every
producer emits severity-free `LintFinding`s (a range, a rule id, a message),
and `materialize` in `derived_diagnostics`
([`src/layer_diagnostics.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/layer_diagnostics.jl))
turns each finding into a `Diagnostic`: an `"off"` rule is dropped, the
configured severity is applied, and the rule's tags and documentation link are
attached. This keeps rule granularity independent of StaticLint's internal
check structure, at the cost of computing a small number of findings that are
then discarded — and it means a severity-only config edit re-runs only this
cheap materialization step, never the producers.

`_emit_hint_findings!`
([`src/lint_emission.jl`](https://github.com/julia-vscode/JuliaWorkspaces.jl/blob/main/src/lint_emission.jl))
maps StaticLint's hints onto rule ids and messages; it is shared by both
static-lint pipelines — the whole-closure pass in `layer_static_lint.jl` and
the per-file pass in `layer_file_analysis.jl` — which differ only in how a call
mismatch is described and in the container they collect into.

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
