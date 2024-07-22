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

function is_path_lintconfig_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == ".julialint.toml"
end

function is_path_julia_file(path)
    _, ext = splitext(lowercase(path))

    return ext == ".jl"
end

function is_path_markdown_file(path)
    _, ext = splitext(lowercase(path))

    return ext == ".md"
end

function is_path_juliamarkdown_file(path)
    _, ext = splitext(lowercase(path))

    return ext == ".jmd"
end

is_walkdir_error(_) = false
is_walkdir_error(::Base.IOError) = true
is_walkdir_error(::Base.SystemError) = true
is_walkdir_error(err::Base.TaskFailedException) = is_walkdir_error(err.task.exception)

function read_text_file_from_uri(uri::URI; return_nothing_on_io_error=false)
    path = uri2filepath(uri)

    language_id = if is_path_julia_file(path)
        "julia"
    elseif is_path_project_file(path)
        "toml"
    elseif is_path_manifest_file(path)
        "toml"
    elseif is_path_lintconfig_file(path)
        "toml"
    elseif is_path_markdown_file(path)
        "markdown"
    elseif is_path_juliamarkdown_file(path)
        "juliamarkdown"
    else
        throw(JWUnknownFileType("Unknown file type for $uri"))
    end

    content = try
        read(path, String)
    catch err
        if return_nothing_on_io_error && is_walkdir_error(err)
            return nothing
        else
            rethrow(err)
        end
    end

    if !our_isvalid(content)
        if return_nothing_on_io_error
            return nothing
        else
            throw(JWInvalidFileContent("Invalid content in file $uri."))
        end
    end

    return TextFile(uri, SourceText(content, language_id))
end

function read_path_into_textdocuments(uri::URI; ignore_io_errors=false)
    path = uri2filepath(uri)

    result = TextFile[]

    for (root, _, files) in walkdir(path, onerror=x -> x)
        for file in files
            filepath = joinpath(root, file)
            if is_path_julia_file(filepath) ||
                        is_path_project_file(filepath) ||
                        is_path_manifest_file(filepath) ||
                        is_path_lintconfig_file(filepath) ||
                        is_path_markdown_file(filepath) ||
                        is_path_juliamarkdown_file(filepath)

                uri = filepath2uri(filepath)
                text_file = read_text_file_from_uri(uri, return_nothing_on_io_error=ignore_io_errors)
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

    add_file!(jw, text_file)
end

function update_file_from_disc!(jw::JuliaWorkspace, path)
    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    update_file!(jw, text_file)
end

function add_folder_from_disc!(jw::JuliaWorkspace, path; ignore_io_errors=false)
    path_uri = filepath2uri(path)

    files = read_path_into_textdocuments(path_uri, ignore_io_errors=ignore_io_errors)

    for i in files
        add_file!(jw, i)
    end
end

function workspace_from_folders(workspace_folders::Vector{String})
    jw = JuliaWorkspace()

    for folder in workspace_folders
        add_folder_from_disc!(jw, folder)
    end

    return jw
end
