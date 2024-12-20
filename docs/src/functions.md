# Functions

```@meta
CurrentModule = JuliaWorkspaces
```

## Exported functions
```@docs
    add_file!
    remove_file!
    remove_all_children!
    get_text_files
    get_julia_files
    has_file
    get_text_file
    get_julia_syntax_tree
    get_toml_syntax_tree
    get_diagnostic
    get_packages
    get_projects
    get_test_items
    get_test_env
```

## Private functions
```@docs
get_files
get_diagnostics
get_files_with_updated_testitems
update_file!
mark_current_testitems
get_files_with_updated_diagnostics
mark_current_diagnostics
```

# URI helper functions (submodule URIs2)
```@docs
URIs2.unescapeuri
URIs2.escapeuri
URIs2._bytes
URIs2.escapepath
```