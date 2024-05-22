function add_text_file(jw::JuliaWorkspace, file::TextFile)
    files = input_files(jw.runtime)

    file.uri in files && error("Duplicate file $(file.uri)")

    push!(files, file.uri)

    set_input_files!(jw.runtime, files)

    set_input_text_file!(jw.runtime, file.uri, file)
end

function update_text_file!(jw::JuliaWorkspace, uri::URI, changes::Vector{TextChange})
    file = input_text_file(jw.runtime, uri)

    new_file = with_changes(file, changes)

    set_input_text_file!(jw.runtime, new_file.uri, new_file)
end

Salsa.@derived function derived_text_files(rt)
    files = input_files(rt)

    # TODO Actually filter this properly
    return [file for file in files]
end

function get_text_files(jw::JuliaWorkspace)
    return derived_text_files(jw.runtime)
end

function get_files(jw::JuliaWorkspace)
    return input_files(jw.runtime)
end

function get_text_file(jw::JuliaWorkspace, uri::URI)
    files = input_files(jw.runtime)

    uri in files = input_files(jw.runtime) || error("Unknown file")

    return input_text_file(jw.runtime, uri)
end

function remove_file!(jw::JuliaWorkspace, uri::URI)
    files = input_files(jw.runtime)

    uri in files || error("Trying to remove non-existing file")

    pop!(files, uri)

    set_input_files!(jw.runtime, files)

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
