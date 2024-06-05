

function our_isvalid(s)
    return isvalid(s) && !occursin('\0', s)
end

function is_path_project_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="project.toml" || basename_lower_case=="juliaproject.toml"
end

function is_path_manifest_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="manifest.toml" || basename_lower_case=="juliamanifest.toml"
end

function is_path_julia_file(path)
    _, ext = splitext(lowercase(path))

    return ext == ".jl"
end

function read_text_file_from_uri(uri::URI)
    path = uri2filepath(uri)

    language_id = if is_path_julia_file(path)
        "julia"
    elseif is_path_project_file(path)
        "toml"
    elseif is_path_manifest_file(path)
        "toml"
    else
        error("Unknown file")
    end

    content = try
        s = read(path, String)
        our_isvalid(s) || return nothing
        s
    catch err
        # TODO Reenable this
        # is_walkdir_error(err) || rethrow()
        # return nothing
        rethrow()
    end

    return TextFile(uri, SourceText(content, language_id))
end

function read_path_into_textdocuments(uri::URI)
    path = uri2filepath(uri)

    result = TextFile[]

    for (root, _, files) in walkdir(path, onerror=x -> x)
        for file in files            
            filepath = joinpath(root, file)
            if is_path_julia_file(filepath) || is_path_project_file(filepath) || is_path_manifest_file(filepath)
                uri = filepath2uri(filepath)
                text_file = read_text_file_from_uri(uri)
                text_file === nothing && continue
                push!(result, text_file)
            end
        end
    end

    return result
end

function add_file_from_disc!(jw::JuliaWorkspace, path)
    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    add_text_file(jw, text_file)
end

function update_file_from_disc!(jw::JuliaWorkspace, path)
    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    old_content = get_text_file(jw, uri)

    update_text_file!(jw, uri, [TextChange(1:lastindex(old_content.content.content), text_file.content.content)], old_content.content.language_id)
end

function add_folder_from_disc!(jw::JuliaWorkspace, path)
    path_uri = filepath2uri(path)

    files = read_path_into_textdocuments(path_uri)

    for i in files
        add_text_file(jw, i)
    end
end

function workspace_from_folders(workspace_folders::Vector{String})
    jw = JuliaWorkspace()

    for folder in workspace_folders
        add_folder_from_disc!(jw, folder)
    end

    return jw
end
