export JuliaWorkspace,
    DynamicMode, DynamicOff, DynamicIndexingOnly, DynamicPersistent,
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
    get_hover_text,
    get_doc_from_word,
    get_completions,
    CompletionResult,
    CompletionResultItem,
    CompletionEdit,
    CompletionKinds,
    InsertFormats,
    is_completion_match,
    get_expr1,
    get_typed_definition,
    completion_type,
    get_definitions,
    get_references,
    get_rename_edits,
    get_highlights,
    can_rename,
    DefinitionResult,
    ReferenceResult,
    RenameEdit,
    HighlightResult,
    get_signature_help,
    SignatureResult,
    SignatureInfo,
    ParameterInfo,
    get_document_symbols,
    get_workspace_symbols,
    DocumentSymbolResult,
    WorkspaceSymbolResult,
    get_selection_ranges,
    get_current_block_range,
    get_module_at,
    SelectionRangeResult,
    BlockRangeResult,
    get_document_links,
    get_inlay_hints,
    DocumentLinkResult,
    InlayHintResult,
    InlayHintConfig,
    get_code_actions,
    execute_code_action,
    CodeActionInfo,
    TextEditResult,
    WorkspaceFileEdit,
    TextFile,
    SourceText,
    Diagnostic


# Files

"""
    add_file!(jw::JuliaWorkspace, file::TextFile)

Add a file to the workspace. If the file already exists, it will throw an error.
"""
function add_file!(jw::JuliaWorkspace, file::TextFile)
    @debug "add_file!" uri=file.uri

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
    @debug "update_file!" uri=file.uri

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
    @debug "get_text_files"

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
    @debug "get_julia_files"

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
    @debug "get_files"

    process_from_dynamic(jw)

    return input_files(jw.runtime)
end

"""
    has_file(jw, uri)

Check if a file exists in the workspace.
"""
function has_file(jw, uri)
    @debug "has_file" uri=uri

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
    @debug "get_text_file" uri=uri

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
    @debug "remove_file!" uri=uri

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
    @debug "remove_all_children!" uri=uri

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
    @debug "get_packages"

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
    @debug "get_projects"

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
    @debug "get_julia_syntax_tree" uri=uri

    process_from_dynamic(jw)

    return derived_julia_syntax_tree(jw.runtime, uri)
end

"""
    get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)

Get the syntax tree of a TOML file from the workspace.
"""
function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
    @debug "get_toml_syntax_tree" uri=uri

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
    @debug "get_diagnostic" uri=uri

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
    @debug "get_diagnostics"

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
    @debug "get_diagnostics_blocking"

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
    @debug "get_test_items" uri=uri

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
    @debug "get_test_items (all)"

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
    @debug "get_test_env" uri=uri

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
    @debug "is_ready"

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
    @debug "wait_until_ready"

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
    @debug "get_legacy_cst" uri=uri

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
    @debug "get_roots_for_uri" uri=uri

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
    @debug "get_best_root_for_uri" uri=uri

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
    @debug "get_static_lint_data" uri=uri

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
    @debug "get_environment" uri=uri

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
    @debug "get_expr_location"

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

# Hover

"""
    get_hover_text(jw::JuliaWorkspace, uri::URI, index::Integer)

Return a Markdown documentation string for the expression at `index` (1-based
Julia string index) in the file identified by `uri`, or `nothing` if there is
no hover information for that position.
"""
function get_hover_text(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_hover_text" uri=uri index=index

    process_from_dynamic(jw)
    return _get_hover_text(jw.runtime, uri, index)
end

"""
    get_doc_from_word(jw::JuliaWorkspace, word::AbstractString)

Search all loaded symbol stores for symbols matching `word` (fuzzy match)
and return their documentation as a single markdown string.
Returns `"No results found."` when no matches are found.
"""
function get_doc_from_word(jw::JuliaWorkspace, word::AbstractString)
    @debug "get_doc_from_word" word=word

    process_from_dynamic(jw)
    return _get_doc_from_word(jw.runtime, word)
end

# Completions

"""
    get_completions(jw::JuliaWorkspace, uri::URI, index::Integer, completion_mode::Symbol=:import)

Return a `CompletionResult` with completion items at the given `index`
(1-based Julia string index) in the file identified by `uri`.

`completion_mode` may be `:import` (default) or `:qualify` to control whether
additional `using` statements are inserted for out-of-scope symbols.
"""
function get_completions(jw::JuliaWorkspace, uri::URI, index::Integer, completion_mode::Symbol=:import)
    @debug "get_completions" uri=uri index=index mode=completion_mode

    process_from_dynamic(jw)
    offset = index - 1  # Convert 1-based string index to 0-based CSTParser offset
    return _get_completions(jw.runtime, uri, offset, completion_mode, jw)
end

# References / Definition / Rename / Highlight

"""
    get_definitions(jw::JuliaWorkspace, uri::URI, index::Integer)

Return a vector of `DefinitionResult` for the symbol at `index` (1-based
Julia string index) in the file identified by `uri`.
"""
function get_definitions(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_definitions" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_definitions(jw.runtime, uri, offset)
end

"""
    get_references(jw::JuliaWorkspace, uri::URI, index::Integer)

Return a vector of `ReferenceResult` for all references to the symbol at
`index` (1-based Julia string index) in the file identified by `uri`.
"""
function get_references(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_references" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_references(jw.runtime, uri, offset)
end

"""
    get_rename_edits(jw::JuliaWorkspace, uri::URI, index::Integer, new_name::String)

Return a vector of `RenameEdit` for renaming the symbol at `index` (1-based
Julia string index) in `uri` to `new_name`.
"""
function get_rename_edits(jw::JuliaWorkspace, uri::URI, index::Integer, new_name::String)
    @debug "get_rename_edits" uri=uri index=index new_name=new_name

    process_from_dynamic(jw)
    offset = index - 1
    return _get_rename_edits(jw.runtime, uri, offset, new_name)
end

"""
    get_highlights(jw::JuliaWorkspace, uri::URI, index::Integer)

Return a vector of `HighlightResult` for highlighted occurrences of the
symbol at `index` (1-based Julia string index) in the same file.
"""
function get_highlights(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_highlights" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_highlights(jw.runtime, uri, offset)
end

"""
    can_rename(jw::JuliaWorkspace, uri::URI, index::Integer)

Check whether the symbol at `index` (1-based Julia string index) can be
renamed. Returns a named tuple `(start_index, end_index)` with 1-based
indices, or `nothing`.
"""
function can_rename(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "can_rename" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _can_rename(jw.runtime, uri, offset)
end

# Signatures

"""
    get_signature_help(jw::JuliaWorkspace, uri::URI, index::Integer)

Return a `SignatureResult` with signature information for the function call
at `index` (1-based Julia string index) in the file identified by `uri`.
"""
function get_signature_help(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_signature_help" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_signature_help(jw.runtime, uri, offset)
end

# Document Symbols / Workspace Symbols

"""
    get_document_symbols(jw::JuliaWorkspace, uri::URI)

Return a vector of `DocumentSymbolResult` representing the document outline
for the file identified by `uri`. Each result has `start_offset` and
`end_offset` as 0-based byte offsets, plus `name`, `kind` (LSP SymbolKind
integer), and `children`.
"""
function get_document_symbols(jw::JuliaWorkspace, uri::URI)
    @debug "get_document_symbols" uri=uri

    process_from_dynamic(jw)
    return _get_document_symbols(jw.runtime, uri)
end

"""
    get_workspace_symbols(jw::JuliaWorkspace, query::String)

Search all files for top-level bindings whose name starts with `query`.
Returns a vector of `WorkspaceSymbolResult`.
"""
function get_workspace_symbols(jw::JuliaWorkspace, query::String)
    @debug "get_workspace_symbols" query=query

    process_from_dynamic(jw)
    return _get_workspace_symbols(jw.runtime, query)
end

# Navigation

"""
    get_selection_ranges(jw::JuliaWorkspace, uri::URI, indices::Vector{Int})

For each 1-based string index in `indices`, compute a nested selection range.
Returns a vector of `Union{Nothing, SelectionRangeResult}`.
"""
function get_selection_ranges(jw::JuliaWorkspace, uri::URI, indices::Vector{Int})
    @debug "get_selection_ranges" uri=uri count=length(indices)

    process_from_dynamic(jw)
    offsets = [idx - 1 for idx in indices]
    return _get_selection_ranges(jw.runtime, uri, offsets)
end

"""
    get_current_block_range(jw::JuliaWorkspace, uri::URI, index::Integer)

Find the current top-level block at `index` (1-based Julia string index).
Returns a `BlockRangeResult` with 0-based byte offsets, or `nothing`.
"""
function get_current_block_range(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_current_block_range" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_current_block_range(jw.runtime, uri, offset)
end

"""
    get_module_at(jw::JuliaWorkspace, uri::URI, index::Integer)

Return the fully qualified module name at `index` (1-based Julia string index),
or "Main" if no module scope is found.
"""
function get_module_at(jw::JuliaWorkspace, uri::URI, index::Integer)
    @debug "get_module_at" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_module_at(jw.runtime, uri, offset)
end

# ============================================================================
# Document links
# ============================================================================

"""
    get_document_links(jw::JuliaWorkspace, uri::URI) → Vector{DocumentLinkResult}

Return clickable document links (string literals that resolve to files).
Offsets in results are 0-based byte offsets for direct use with CST spans.
"""
function get_document_links(jw::JuliaWorkspace, uri::URI)
    @debug "get_document_links" uri=uri

    process_from_dynamic(jw)
    return _get_document_links(jw.runtime, uri)
end

# ============================================================================
# Inlay hints
# ============================================================================

"""
    get_inlay_hints(jw::JuliaWorkspace, uri::URI, start_index::Integer, end_index::Integer, config::InlayHintConfig) → Vector{InlayHintResult}

Return inlay hints (parameter names, variable types) for the given range.
`start_index` and `end_index` are 1-based Julia string indices.
"""
function get_inlay_hints(jw::JuliaWorkspace, uri::URI, start_index::Integer, end_index::Integer, config::InlayHintConfig)
    @debug "get_inlay_hints" uri=uri start_index=start_index end_index=end_index

    process_from_dynamic(jw)
    start_offset = start_index - 1
    end_offset = end_index - 1
    return _get_inlay_hints(jw.runtime, uri, start_offset, end_offset, config)
end

# ============================================================================
# Code actions
# ============================================================================

"""
    get_code_actions(jw::JuliaWorkspace, uri::URI, index::Integer, diagnostic_messages::Vector{String}, workspace_folders::Vector{String}=String[]) → Vector{CodeActionInfo}

Return the list of applicable code actions at `index` (1-based Julia string index).
`diagnostic_messages` should contain the text of any diagnostics overlapping the cursor.
`workspace_folders` is an optional list of workspace folder paths (used by license actions).
"""
function get_code_actions(jw::JuliaWorkspace, uri::URI, index::Integer, diagnostic_messages::Vector{String}, workspace_folders::Vector{String}=String[])
    @debug "get_code_actions" uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _get_code_actions(jw.runtime, uri, offset, diagnostic_messages, workspace_folders)
end

"""
    execute_code_action(jw::JuliaWorkspace, action_id::String, uri::URI, index::Integer, workspace_folders::Vector{String}=String[]) → Vector{WorkspaceFileEdit}

Execute the code action identified by `action_id` at `index` (1-based Julia string index).
Returns a vector of workspace file edits. Each edit contains a URI and a vector of
`TextEditResult`s with 0-based byte offsets.
"""
function execute_code_action(jw::JuliaWorkspace, action_id::String, uri::URI, index::Integer, workspace_folders::Vector{String}=String[])
    @debug "execute_code_action" action_id=action_id uri=uri index=index

    process_from_dynamic(jw)
    offset = index - 1
    return _execute_code_action(jw.runtime, action_id, uri, offset, workspace_folders)
end
