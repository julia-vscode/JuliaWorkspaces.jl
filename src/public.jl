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
    get_packages,
    get_projects,
    get_test_items,
    get_test_env,
    position_at,
    TextFile,
    SourceText,
    Diagnostic


# Files

"""
    add_file!(jw::JuliaWorkspace, file::TextFile)

Add a file to the workspace. If the file already exists, it will throw an error.
"""
function add_file!(jw::JuliaWorkspace, file::TextFile)
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
    return derived_text_files(jw.runtime)
end

"""
    get_julia_files(jw::JuliaWorkspace)

Get all Julia files from the workspace.

# Returns

- A set of URIs.
"""
function get_julia_files(jw::JuliaWorkspace)
    return derived_julia_files(jw.runtime)
end

"""
    get_files(jw::JuliaWorkspace)

Get all files from the workspace.

# Returns
- A set of URIs.
"""
function get_files(jw::JuliaWorkspace)
    return input_files(jw.runtime)
end

"""
    has_file(jw, uri)

Check if a file exists in the workspace.
"""
function has_file(jw, uri)
    return derived_has_file(jw.runtime, uri)
end

"""
    get_text_file(jw::JuliaWorkspace, uri::URI)

Get a text file from the workspace. If the file does not exist, it will throw an error.

# Returns

- A `TextFile` struct.
"""
function get_text_file(jw::JuliaWorkspace, uri::URI)
    files = input_files(jw.runtime)

    uri in files || throw(JWUnknownFile("Unknown file $uri"))

    return input_text_file(jw.runtime, uri)
end

"""
    remove_file!(jw::JuliaWorkspace, uri::URI)

Remove a file from the workspace. If the file does not exist, it will throw an error.
"""
function remove_file!(jw::JuliaWorkspace, uri::URI)
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
    return derived_package_folders(jw.runtime)
end

"""
    get_projects(jw::JuliaWorkspace)

Get all projects from the workspace.

# Returns

- A set of URIs.
"""
function get_projects(jw::JuliaWorkspace)
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
    return derived_julia_syntax_tree(jw.runtime, uri)
end

"""
    get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)

Get the syntax tree of a TOML file from the workspace.
"""
function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
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
    return derived_diagnostics(jw.runtime, uri)
end

"""
    get_diagnostics(jw::JuliaWorkspace)

Get all diagnostics from the workspace.

# Returns
- A vector of `Diagnostic` structs.
"""
function get_diagnostics(jw::JuliaWorkspace)
    return derived_all_diagnostics(jw.runtime)
end

"""
    mark_current_diagnostics(jw::JuliaWorkspace)

Mark the current diagnostics in the workspace.
"""
function mark_current_diagnostics(jw::JuliaWorkspace)
    files = derived_text_files(jw.runtime)

    results = Dict{URI,Vector{Diagnostic}}()

    for f in files
        results[f] = derived_diagnostics(jw.runtime, f)
    end
    set_input_marked_diagnostics!(jw.runtime, DiagnosticsMark(uuid4(), results))
end

"""
    get_files_with_updated_diagnostics(jw::JuliaWorkspace)

Returns

- a tuple of the updated and the deleted files since calling `mark_current_diagnostics()`
"""
function get_files_with_updated_diagnostics(jw::JuliaWorkspace)
    return derived_diagnostic_updated_since_mark(jw.runtime)
end

# Test items

"""
    get_test_items(jw::JuliaWorkspace, uri::URI)

Get the test items that belong to a given `uri` of a workspace.

Returns

- the struct `TestDetails`
"""
function get_test_items(jw::JuliaWorkspace, uri::URI)
    derived_testitems(jw.runtime, uri)
end

"""
    get_test_items(jw::JuliaWorkspace)

Get all test items of the workspace `jw`.

Returns

- an instance of the struct `TestDetails`
"""
function get_test_items(jw::JuliaWorkspace)
    derived_all_testitems(jw.runtime)
end

"""
    get_test_env(jw::JuliaWorkspace, uri::URI)

Get the test environment that belongs to the given `uri` of the workspace `jw`.

Returns

- a instance of the struct `JuliaTestEnv`
"""
function get_test_env(jw::JuliaWorkspace, uri::URI)
    derived_testenv(jw.runtime, uri)
end

"""
    mark_current_testitems(jw::JuliaWorkspace)

Mark all current test items of the workspace `jw`.
"""
function mark_current_testitems(jw::JuliaWorkspace)
    files = derived_julia_files(jw.runtime)

    results = Dict{URI,TestDetails}()

    for f in files
        results[f] = derived_testitems(jw.runtime, f)
    end

    set_input_marked_testitems!(jw.runtime, TestitemsMark(uuid4(), results))
end

"""
    get_files_with_updated_testitems(jw::JuliaWorkspace)

Get all files with test items that were updated since marked of the workspace `jw`.

Returns

- the tuple (updated_files, deleted_files)
"""
function get_files_with_updated_testitems(jw::JuliaWorkspace)
    # @info "get_files_with_updated_testitems" string.(input_files(jw.runtime))
    # graph = Salsa.Inspect.build_graph(jw.runtime)
    # println(stderr, graph)
    return derived_testitems_updated_since_mark(jw.runtime)
end
