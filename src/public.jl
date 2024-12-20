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

function add_file!(jw::JuliaWorkspace, file::TextFile)
    files = input_files(jw.runtime)

    file.uri in files && throw(JWDuplicateFile("Duplicate file $(file.uri)"))

    new_files = Set{URI}([files...;file.uri])

    set_input_files!(jw.runtime, new_files)

    set_input_text_file!(jw.runtime, file.uri, file)
end

function update_file!(jw::JuliaWorkspace, file::TextFile)
    has_file(jw, file.uri) || throw(JWUnknownFile("Cannot update unknown file $(file.uri)."))

    set_input_text_file!(jw.runtime, file.uri, file)
end

function get_text_files(jw::JuliaWorkspace)
    return derived_text_files(jw.runtime)
end

function get_julia_files(jw::JuliaWorkspace)
    return derived_julia_files(jw.runtime)
end

function get_files(jw::JuliaWorkspace)
    return input_files(jw.runtime)
end

function has_file(jw, uri)
    return derived_has_file(jw.runtime, uri)
end

function get_text_file(jw::JuliaWorkspace, uri::URI)
    files = input_files(jw.runtime)

    uri in files || throw(JWUnknownFile("Unknown file $uri"))

    return input_text_file(jw.runtime, uri)
end

function remove_file!(jw::JuliaWorkspace, uri::URI)
    files = input_files(jw.runtime)

    uri in files || throw(JWUnknownFile("Trying to remove non-existing file $uri"))

    new_files = filter(i->i!=uri, files)

    set_input_files!(jw.runtime, new_files)

    delete_input_text_file!(jw.runtime, uri)
end

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

function get_packages(jw::JuliaWorkspace)
    return derived_package_folders(jw.runtime)
end

function get_projects(jw::JuliaWorkspace)
    return derived_project_folders(jw.runtime)
end

# Syntax trees

function get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_julia_syntax_tree(jw.runtime, uri)
end

function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_toml_syntax_tree(jw.runtime, uri)
end

# Diagnostics

function get_diagnostic(jw::JuliaWorkspace, uri::URI)
    return derived_diagnostics(jw.runtime, uri)
end

function get_diagnostics(jw::JuliaWorkspace)
    return derived_all_diagnostics(jw.runtime)
end

function mark_current_diagnostics(jw::JuliaWorkspace)
    files = derived_text_files(jw.runtime)

    results = Dict{URI,Vector{Diagnostic}}()

    for f in files
        results[f] = derived_diagnostics(jw.runtime, f)
    end
    set_input_marked_diagnostics!(jw.runtime, DiagnosticsMark(uuid4(), results))
end

function get_files_with_updated_diagnostics(jw::JuliaWorkspace)
    return derived_diagnostic_updated_since_mark(jw.runtime)
end

# Test items

function get_test_items(jw::JuliaWorkspace, uri::URI)
    derived_testitems(jw.runtime, uri)
end

function get_test_items(jw::JuliaWorkspace)
    derived_all_testitems(jw.runtime)
end

function get_test_env(jw::JuliaWorkspace, uri::URI)
    derived_testenv(jw.runtime, uri)
end

function mark_current_testitems(jw::JuliaWorkspace)
    files = derived_julia_files(jw.runtime)

    results = Dict{URI,TestDetails}()

    for f in files
        results[f] = derived_testitems(jw.runtime, f)
    end

    set_input_marked_testitems!(jw.runtime, TestitemsMark(uuid4(), results))
end

function get_files_with_updated_testitems(jw::JuliaWorkspace)
    # @info "get_files_with_updated_testitems" string.(input_files(jw.runtime))
    # graph = Salsa.Inspect.build_graph(jw.runtime)
    # println(stderr, graph)
    return derived_testitems_updated_since_mark(jw.runtime)
end

function get_formatted_content(jw::JuliaWorkspace, uri::URI)
    config = derived_formatter_configuration(jw.runtime, uri)

    if config===nothing
        return nothing
    end


end
