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

Salsa.@derived function derived_text_files(rt)
    files = input_files(rt)

    # TODO Actually filter this properly
    return [file for file in files]
end

Salsa.@derived function derived_julia_files(rt)
    files = derived_text_files(rt)

    # TODO Actually filter this properly
    return [file for file in files if endswith(string(file), ".jl")]
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

Salsa.@derived function derived_has_file(rt, uri)
    files = input_files(rt)

    return uri in files
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
