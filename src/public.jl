export JuliaWorkspace,
    add_file!,
    remove_file!,
    remove_all_children!,
    TextFile, SourceText,
    workspace_from_folders,
    add_folder_from_disc!,
    add_file_from_disc!,
    update_file_from_disc!,
    get_text_files,
    get_julia_files,
    has_file,
    get_text_file,
    get_julia_syntax_tree,
    get_toml_syntax_tree,
    get_diagnostic,
    get_diagnostics,
    get_diagnostics_blocking,
    get_packages,
    get_projects,
    get_test_items,
    get_test_env,
    position_at,
    is_ready,
    wait_until_ready,
    get_update_channel,
    get_legacy_cst,
    get_roots_for_uri,
    get_best_root_for_uri,
    get_static_lint_data,
    get_environment,
    get_expr_location,
    TextFile,
    SourceText,
    Diagnostic


# Files

"""
    add_file!(jw::JuliaWorkspace, file::TextFile)

Add a file to the workspace. If the file already exists, it will throw an error.
"""
function add_file!(jw::JuliaWorkspace, file::TextFile)
    process_from_dynamic(jw)

    files = input_files(jw.runtime)

    file.uri in files && throw(JWDuplicateFile("Duplicate file $(file.uri)"))

    new_files = Set{URI}([files...;file.uri])

    set_input_files!(jw.runtime, new_files)

    set_input_text_file!(jw.runtime, file.uri, file)
end

"""
    update_file!(jw::JuliaWorkspace, file::TextFile)

Update a file in the workspace. If the file does not exist, it will throw an error.
"""
function update_file!(jw::JuliaWorkspace, file::TextFile)
    process_from_dynamic(jw)

    has_file(jw, file.uri) || throw(JWUnknownFile("Cannot update unknown file $(file.uri)."))

    set_input_text_file!(jw.runtime, file.uri, file)
end

"""
    get_text_files(jw::JuliaWorkspace)

Get all text files from the workspace.

# Returns

- A set of URIs.
"""
function get_text_files(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    return derived_text_files(jw.runtime)
end

"""
    get_julia_files(jw::JuliaWorkspace)

Get all Julia files from the workspace.

# Returns

- A set of URIs.
"""
function get_julia_files(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    return derived_julia_files(jw.runtime)
end

"""
    get_files(jw::JuliaWorkspace)

Get all files from the workspace.

# Returns
- A set of URIs.
"""
function get_files(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    return input_files(jw.runtime)
end

"""
    has_file(jw, uri)

Check if a file exists in the workspace.
"""
function has_file(jw, uri)
    process_from_dynamic(jw)

    return derived_has_file(jw.runtime, uri)
end

"""
    get_text_file(jw::JuliaWorkspace, uri::URI)

Get a text file from the workspace. If the file does not exist, it will throw an error.

# Returns

- A [`TextFile`](@ref) struct.
"""
function get_text_file(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    files = input_files(jw.runtime)

    uri in files || throw(JWUnknownFile("Unknown file $uri"))

    return input_text_file(jw.runtime, uri)
end

"""
    remove_file!(jw::JuliaWorkspace, uri::URI)

Remove a file from the workspace. If the file does not exist, it will throw an error.
"""
function remove_file!(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    files = input_files(jw.runtime)

    uri in files || throw(JWUnknownFile("Trying to remove non-existing file $uri"))

    new_files = filter(i->i!=uri, files)

    set_input_files!(jw.runtime, new_files)

    delete_input_text_file!(jw.runtime, uri)
end

"""
    remove_all_children!(jw::JuliaWorkspace, uri::URI)

Remove all children of a folder from the workspace.
"""
function remove_all_children!(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    files = get_files(jw)

    uri_as_string = string(uri)

    for file in files
        file_as_string = string(file)

        if startswith(file_as_string, uri_as_string)
            remove_file!(jw, file)
        end
    end
end

# Projects

"""
    get_packages(jw::JuliaWorkspace)

Get all packages from the workspace.

# Returns

- A set of URIs.
"""
function get_packages(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    return derived_package_folders(jw.runtime)
end

"""
    get_projects(jw::JuliaWorkspace)

Get all projects from the workspace.

# Returns

- A set of URIs.
"""
function get_projects(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    return derived_project_folders(jw.runtime)
end

# Syntax trees

"""
    get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)

Get the syntax tree of a Julia file from the workspace.

# Returns

- The tuple `(tree, diagnostics)`, where `tree` is the syntax tree 
  and `diagnostics` is a vector of `Diagnostic` structs.   
"""
function get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_julia_syntax_tree(jw.runtime, uri)
end

"""
    get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)

Get the syntax tree of a TOML file from the workspace.
"""
function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_toml_syntax_tree(jw.runtime, uri)
end

# Diagnostics

"""
    get_diagnostic(jw::JuliaWorkspace, uri::URI)

Get the diagnostics of a file from the workspace.

# Returns

- A vector of `Diagnostic` structs.
"""
function get_diagnostic(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_diagnostics(jw.runtime, uri)
end

"""
    get_diagnostics(jw::JuliaWorkspace)

Get all diagnostics from the workspace.

# Returns
- A vector of `Diagnostic` structs.
"""
function get_diagnostics(jw::JuliaWorkspace)
    process_from_dynamic(jw)
    
    return derived_all_diagnostics(jw.runtime)
end

"""
    get_diagnostics_blocking(jw::JuliaWorkspace; cancel_token::Union{CancellationTokens.CancellationToken,Nothing}=nothing)

Wait for the dynamic environment to finish loading, then return all diagnostics.
This is useful for CLI tools that want the full, accurate set of diagnostics.
If `cancel_token` is provided, throws `CancellationTokens.OperationCanceledException`
when the token is cancelled.
"""
function get_diagnostics_blocking(jw::JuliaWorkspace; cancel_token::Union{CancellationTokens.CancellationToken,Nothing}=nothing)
    # First call triggers lazy inputs that start background processes
    get_diagnostics(jw)
    # Wait for all background processes to complete
    wait_until_ready(jw; cancel_token=cancel_token)
    # Second call picks up the results and returns final diagnostics
    return get_diagnostics(jw)
end

# Test items

"""
    get_test_items(jw::JuliaWorkspace, uri::URI)

Get the test items that belong to a given [`URI`](@ref) of a workspace.

Returns

- an instance of the struct [`TestDetails`](@ref)
"""
function get_test_items(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    derived_testitems(jw.runtime, uri)
end

"""
    get_test_items(jw::JuliaWorkspace)

Get all test items of the workspace `jw`.

Returns

- an instance of the struct [`TestDetails`](@ref)
"""
function get_test_items(jw::JuliaWorkspace)
    process_from_dynamic(jw)

    derived_all_testitems(jw.runtime)
end

"""
    get_test_env(jw::JuliaWorkspace, uri::URI)

Get the test environment that belongs to the given `uri` of the workspace `jw`.

Returns

- an instance of the struct [`JuliaTestEnv`](@ref)
"""
function get_test_env(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    derived_testenv(jw.runtime, uri)
end

# Readiness

"""
    is_ready(jw::JuliaWorkspace)

Check whether the workspace's dynamic environment loading has completed.
Returns `true` if no dynamic feature is configured, or if the environment
has finished loading and no tasks are pending.
"""
function is_ready(jw::JuliaWorkspace)
    jw.dynamic_feature === nothing && return true
    return input_env_ready(jw.runtime) && jw.dynamic_feature.pending_count[] == 0
end

"""
    wait_until_ready(jw::JuliaWorkspace; cancel_token::Union{CancellationTokens.CancellationToken,Nothing}=nothing)

Block until the workspace's dynamic environment loading has completed.
If `cancel_token` is provided, throws `CancellationTokens.OperationCanceledException`
when the token is cancelled.
"""
function wait_until_ready(jw::JuliaWorkspace; cancel_token::Union{CancellationTokens.CancellationToken,Nothing}=nothing)
    while !is_ready(jw)
        if cancel_token !== nothing
            wait(jw.dynamic_feature.update_channel, cancel_token)
        else
            wait(jw.dynamic_feature.update_channel)
        end
        # Drain the update_channel and process any dynamic results
        while isready(jw.dynamic_feature.update_channel)
            take!(jw.dynamic_feature.update_channel)
        end
        process_from_dynamic(jw)
    end
end

"""
    get_update_channel(jw::JuliaWorkspace)

Return the `Channel{Symbol}` that receives notifications when dynamic data
becomes available.  Returns `nothing` if no dynamic feature is configured.
Consumers can `take!` or `wait` on this channel to be notified of updates.
"""
function get_update_channel(jw::JuliaWorkspace)
    jw.dynamic_feature === nothing && return nothing
    return jw.dynamic_feature.update_channel
end

# Static Lint data

"""
    get_legacy_cst(jw::JuliaWorkspace, uri::URI)

Get the CSTParser legacy syntax tree for a Julia file.

# Returns
- An `EXPR` (CSTParser expression tree).
"""
function get_legacy_cst(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_julia_legacy_syntax_tree(jw.runtime, uri)
end

"""
    get_roots_for_uri(jw::JuliaWorkspace, uri::URI)

Get all root files whose include tree contains the given URI.

# Returns
- A `Set{URI}` of root file URIs.
"""
function get_roots_for_uri(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_roots_for_uri(jw.runtime, uri)
end

"""
    get_best_root_for_uri(jw::JuliaWorkspace, uri::URI)

Get the single best root file for a given URI.
Prefers package `src/` roots over test roots when a file is reachable from
multiple roots. Returns `nothing` if the URI is not part of any root's
include tree.

# Returns
- A `URI` or `nothing`.
"""
function get_best_root_for_uri(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    return derived_best_root_for_uri(jw.runtime, uri)
end

"""
    get_static_lint_data(jw::JuliaWorkspace, uri::URI)

Get the static lint analysis data for the best root containing `uri`.
This includes the metadata dictionary, environment, and workspace packages
needed by LS request handlers.

# Returns
- A named tuple `(meta_dict, env, workspace_packages, root)` or `nothing` if no root
  contains the URI.
  - `meta_dict::Dict{UInt64, StaticLint.Meta}` — maps EXPR object_id → metadata
  - `env::StaticLint.ExternalEnv` — resolved environment (symbols, methods, deps)
  - `workspace_packages::Dict{String,Any}` — deved packages available for import
  - `root::URI` — the root file that was used
"""
function get_static_lint_data(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    root = derived_best_root_for_uri(jw.runtime, uri)
    root === nothing && return nothing

    lint_result = derived_static_lint_meta_for_root(jw.runtime, root)
    project_uri = derived_project_uri_for_root(jw.runtime, root)
    env = derived_environment(jw.runtime, project_uri)

    return (
        meta_dict=lint_result.meta_dict,
        env=env,
        workspace_packages=lint_result.workspace_packages,
        root=root
    )
end

"""
    get_environment(jw::JuliaWorkspace, uri::URI)

Get the resolved environment for the best root containing `uri`.

# Returns
- A `StaticLint.ExternalEnv` or `nothing`.
"""
function get_environment(jw::JuliaWorkspace, uri::URI)
    process_from_dynamic(jw)

    root = derived_best_root_for_uri(jw.runtime, uri)
    root === nothing && return nothing

    project_uri = derived_project_uri_for_root(jw.runtime, root)
    return derived_environment(jw.runtime, project_uri)
end

"""
    get_expr_location(jw::JuliaWorkspace, x::CSTParser.EXPR)

Given an EXPR node from a CST obtained via `get_legacy_cst`, return the URI and
byte offset of `x` within its owning file.

Walks `x.parent` pointers up to the file-root EXPR, computes the byte offset
by descending through the tree, then looks up the root's `objectid` in a
Salsa-memoized expr→URI mapping.

# Returns
- `(uri::URI, offset::Int)` if the owning file is found
- `nothing` if the EXPR cannot be mapped to a file
"""
function get_expr_location(jw::JuliaWorkspace, x::CSTParser.EXPR)
    # Walk to root
    root = x
    while CSTParser.parentof(root) !== nothing
        root = CSTParser.parentof(root)
    end

    # Must be a :file node to have a URI mapping
    CSTParser.headof(root) === :file || return nothing

    # Look up which file owns this root
    expr_uri_map = derived_expr_uri_map(jw.runtime)
    uri = get(expr_uri_map, objectid(root), nothing)
    uri === nothing && return nothing

    # Compute byte offset of x within the file
    _, offset = _descend(root, x)

    return (uri=uri, offset=offset)
end

"""
    _descend(root::CSTParser.EXPR, target::CSTParser.EXPR, offset=0)

Walk the CST from `root` to find `target`, accumulating the byte offset.
Returns `(found::Bool, offset::Int)`.
"""
function _descend(x::CSTParser.EXPR, target::CSTParser.EXPR, offset=0)
    x === target && return (true, offset)
    for c in x
        c === target && return (true, offset)
        found, o = _descend(c, target, offset)
        found && return (true, o)
        offset += c.fullspan
    end
    return (false, offset)
end
