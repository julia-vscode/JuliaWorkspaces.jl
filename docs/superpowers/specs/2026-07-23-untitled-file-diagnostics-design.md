# Diagnostics for untitled files

## Goal

Re-enable diagnostics for untitled (non-`file` scheme) buffers, and use the
fallback environment (the active project) as the project for every untitled
file.

## Background

Untitled buffers reach `JuliaWorkspace` as `TextFile`s with a non-`file` URI
(e.g. `untitled:Untitled-1`) and a `SourceText` carrying a `language_id`. Today
they receive no diagnostics because of two gates:

1. **`layer_diagnostics.jl` — `derived_diagnostics`**: the whole diagnostics
   body is wrapped in `if uri.scheme == "file"`, so a non-file URI returns an
   empty `Diagnostic[]`.
2. **`layer_files.jl` — `derived_julia_files`**: keeps only URIs where
   `endswith(string(file), ".jl")`. An untitled URI has no `.jl` suffix, so it
   never becomes a *root*; `derived_roots_for_uri` is empty for it and
   static-lint produces nothing even with gate #1 lifted. (Syntax and testitem
   diagnostics query the file directly and are unaffected by this gate.)

The supporting machinery already tolerates path-less URIs:
`derived_file_include_data` explicitly handles `uri2filepath(uri) === nothing`
("an unsaved buffer"), and `derived_file_module_path` is a plain module-tree
lookup.

The environment side already works: `derived_project_uri_for_root` falls
through to `input_active_project` for a file that is in no package/project
folder, and (after commit 28f54e9) an untitled file returns `nothing` from both
`derived_package_for_file` and `derived_project_for_file`. The active project
is the documented fallback environment (`public.jl`). So an untitled file
already resolves to the active project as its environment — no change is
required there.

## Design

### 1. Value-stable language query (`layer_files.jl`)

```julia
Salsa.@derived function derived_file_language_id(rt, uri)
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    return tf.content.language_id
end
```

Returns only the `language_id` string, so it backdates on ordinary content
edits: a keystroke in an untitled buffer re-executes this query but returns the
same string, shielding `derived_julia_files` (and therefore `derived_roots`)
from per-keystroke invalidation.

### 2. Julia predicate

Wherever "is this a Julia file" is decided, use:

- file scheme → `is_path_julia_file(uri2filepath(uri))` (unchanged behavior)
- non-file scheme → `derived_file_language_id(rt, uri) == "julia"`

### 3. Gate #2 fix (`derived_julia_files`, `layer_files.jl`)

Include non-file URIs whose language is `"julia"` so an untitled Julia buffer
becomes a root and static-lint runs for it:

```julia
Set{URI}(file for file in files if
    endswith(string(file), ".jl") ||
    (file.scheme != "file" && derived_file_language_id(rt, file) == "julia"))
```

File-scheme behavior is unchanged (still the cheap suffix check).

### 4. Gate #1 fix (`derived_diagnostics`, `layer_diagnostics.jl`)

Split the body:

- **Julia-content diagnostics** — syntax errors/warnings, testitem errors,
  static-lint, and include diagnostics — run under the Julia predicate for both
  file and non-file URIs.
- **Config/TOML diagnostics** — toml-syntax, lint-config, format-config — stay
  gated behind `uri.scheme == "file"` (untitled buffers are never config
  files).

### 5. Guard `derived_lint_configuration` (`layer_diagnostics.jl`)

It calls `startswith(uri2filepath(uri), config_folder_path)`, which crashes on a
`nothing` path. Early-return an empty config for non-file URIs (untitled files
have no folder-based lint config, so defaults apply).

### 6. Environment / project

No code change. `derived_project_uri_for_root` already returns the active
project for path-less files, and the project-less-root suppression in
`derived_new_static_lint_diagnostics` (`layer_file_analysis.jl`) still hides
env-dependent false positives during the LS-startup no-active-project window.

## Tests (`test/test_diagnostics.jl`)

1. Untitled Julia buffer with a syntax error reports the syntax diagnostic.
2. Untitled Julia buffer gets static-lint diagnostics (e.g. an undefined-var
   missing reference) once an active project is set.
3. Untitled markdown buffer (`language_id = "markdown"`) reports no diagnostics
   (not parsed as Julia).
4. An untitled buffer resolves its environment to the active project (fallback).

## Out of scope

- LanguageServer-side changes. The LS already forwards untitled buffers with a
  `language_id`; this work is confined to `JuliaWorkspaces`.
- Changing the file-scheme Julia detection from extension-based to
  language-based.
