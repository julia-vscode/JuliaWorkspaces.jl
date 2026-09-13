# Functions

```@meta
CurrentModule = JuliaWorkspaces
```

The exported functions form a [command/query split](architecture.md#the-public-api-a-commandquery-split)
over a [`JuliaWorkspace`](@ref): mutation functions change the workspace inputs,
while query functions read derived results.

## Constructing a workspace from disc

```@docs
workspace_from_folders
add_folder_from_disc!
add_file_from_disc!
update_file_from_disc!
collect_workspace_paths
```

## Path selection

The directory walk above and the per-file config attribution both answer to
these predicates on a [`PathFilter`](@ref).

```@docs
path_selected
dir_selected
```

## Mutating a workspace

```@docs
add_file!
remove_file!
remove_all_children!
set_active_project!
set_v2_enabled!
set_macro_expansion!
set_indirect_file_content!
clear_indirect_file!
```

## Files and source text

```@docs
get_text_files
get_julia_files
has_file
get_text_file
get_indirect_files
is_indirect_file
position_at
```

## Syntax trees

```@docs
get_julia_syntax_tree
get_toml_syntax_tree
parse_files_blocking
```

## Diagnostics

```@docs
get_diagnostic
get_diagnostics
get_diagnostics_blocking
```

## Projects, packages and tests

```@docs
get_packages
get_projects
get_test_items
get_test_env
```

## The dynamic feature

```@docs
is_ready
wait_until_ready
get_update_channel
set_dynamic_mode!
get_dynamic_mode
retry_failed_dynamic_projects!
set_max_alive_djps!
set_max_concurrent_djps!
set_resolve_workspace_environments!
set_symbolcache!
set_max_failure_attempts!
set_djp_request_timeout!
```

## Language features

```@docs
get_hover_text
get_doc_from_word
get_completions
is_completion_match
get_expr1
completion_type
get_typed_definition
get_definitions
get_references
get_rename_edits
get_highlights
can_rename
get_signature_help
get_document_symbols
get_workspace_symbols
get_selection_ranges
get_current_block_range
get_module_at
get_document_links
get_inlay_hints
get_code_actions
execute_code_action
get_format_edits
is_format_excluded
```

## StaticLint and environment accessors

```@docs
get_legacy_cst
get_roots_for_uri
get_best_root_for_uri
get_static_lint_data
get_environment
get_expr_location
```

## Private functions

```@docs
get_files
update_file!
```

# URI helper functions (submodule URIs2)

```@docs
URIs2.unescapeuri
URIs2.escapeuri
URIs2._bytes
URIs2.escapepath
```