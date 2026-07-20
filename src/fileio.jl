function our_isvalid(s)
    return isvalid(s) && !occursin('\0', s)
end

function is_path_project_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="project.toml" || basename_lower_case=="juliaproject.toml"
end

function is_path_manifest_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    # Manifest.toml, Manifest-v1.11.toml, JuliaManifest.toml, etc.
    return occursin(r"^(julia)?manifest(\-v\d+(\.\d+)*)?\.toml$", basename_lower_case)
end

function is_path_lintconfig_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == "julialint.toml"
end

function is_path_formatconfig_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == "juliaformat.toml"
end

function is_path_julia_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".jl"
end

function is_path_markdown_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".md"
end

function is_path_juliamarkdown_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".jmd"
end

is_walkdir_error(_) = false
is_walkdir_error(::Base.IOError) = true
is_walkdir_error(::Base.SystemError) = true
is_walkdir_error(err::Base.TaskFailedException) = is_walkdir_error(err.task.exception)

function read_text_file_from_uri(uri::URI; return_nothing_on_io_error=false)
    if uri.scheme !== "file"
        if return_nothing_on_io_error
            return nothing
        else
            error("Trying to read non-file content from $uri.")
        end
    end
    path = uri2filepath(uri)

    language_id = if is_path_julia_file(path)
        "julia"
    elseif is_path_project_file(path)
        "toml"
    elseif is_path_manifest_file(path)
        "toml"
    elseif is_path_lintconfig_file(path)
        "toml"
    elseif is_path_formatconfig_file(path)
        "toml"
    elseif is_path_markdown_file(path)
        "markdown"
    elseif is_path_juliamarkdown_file(path)
        "juliamarkdown"
    else
        if return_nothing_on_io_error
            return nothing
        else
            throw(JWUnknownFileType("Unknown file type for $uri"))
        end
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

"""
    read_path_into_textdocuments(uri; ignore_io_errors=false, file_limit=nothing)
        -> Union{Vector{TextFile}, Nothing}

Read every workspace-relevant file (Julia sources, Project/Manifest, lint/format
configs, Markdown) under the folder `uri` into `TextFile`s.

When `file_limit` is set and the tree contains more than that many Julia files,
returns `nothing` (the tree is deemed too large to load) — the count is checked
before any content is read. Otherwise returns the collected `Vector{TextFile}`
(possibly empty). Callers that pass a `file_limit` must handle the `nothing`
return.

With `ignore_io_errors`, a non-`file` URI yields an empty vector and unreadable
files are skipped; otherwise both throw.
"""
function read_path_into_textdocuments(uri::URI; ignore_io_errors=false, file_limit::Union{Nothing,Int}=nothing)
    result = TextFile[]

    if uri.scheme !== "file"
        if ignore_io_errors
            return result
        else
            error("Trying to read non-file content from $uri.")
        end
    end

    path = uri2filepath(uri)

    # Collect paths first so an over-limit tree aborts before any content is
    # read; contents are read afterwards with per-file yields.
    candidate_paths = String[]
    julia_file_count = 0
    for (root, _, files) in walkdir(path, onerror=x -> x)
        yield()
        for file in files
            filepath = joinpath(root, file)
            if is_path_julia_file(filepath)
                julia_file_count += 1
                if file_limit !== nothing && julia_file_count > file_limit
                    return nothing
                end
                push!(candidate_paths, filepath)
            elseif is_path_project_file(filepath) ||
                        is_path_manifest_file(filepath) ||
                        is_path_lintconfig_file(filepath) ||
                        is_path_formatconfig_file(filepath) ||
                        is_path_markdown_file(filepath) ||
                        is_path_juliamarkdown_file(filepath)
                push!(candidate_paths, filepath)
            end
        end
    end

    for filepath in candidate_paths
        text_file = read_text_file_from_uri(filepath2uri(filepath), return_nothing_on_io_error=ignore_io_errors)
        text_file === nothing && continue
        push!(result, text_file)
        yield()
    end

    return result
end

"""
    add_file_from_disc!(jw::JuliaWorkspace, path)

Read the file at the local `path` from disc and add it to the workspace `jw` as
a new file (see [`add_file!`](@ref)). The file content is read eagerly and the
file's language is inferred from its extension.

Throws if a file with the same URI is already part of the workspace.
"""
function add_file_from_disc!(jw::JuliaWorkspace, path)
    @debug "add_file_from_disc!" path=path

    process_from_dynamic(jw)

    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    add_file!(jw, text_file)
end

"""
    update_file_from_disc!(jw::JuliaWorkspace, path)

Re-read the file at the local `path` from disc and update its content in the
workspace `jw` (see [`update_file!`](@ref)). Use this to refresh a file whose
on-disc content changed outside of the workspace.

Throws if no file with the corresponding URI is part of the workspace.
"""
function update_file_from_disc!(jw::JuliaWorkspace, path)
    @debug "update_file_from_disc!" path=path

    process_from_dynamic(jw)

    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    update_file!(jw, text_file)
end

"""
    add_folder_from_disc!(jw::JuliaWorkspace, path; ignore_io_errors=false)

Recursively read all relevant files under the local folder `path` from disc and
add them to the workspace `jw`. Julia sources, `Project.toml`/`Manifest.toml`,
and configuration files are picked up. The whole batch is added before a single
reconciliation step runs, so this is more efficient than calling
[`add_file!`](@ref) per file.

If `ignore_io_errors` is `true`, files that cannot be read are skipped instead
of raising an error.
"""
function add_folder_from_disc!(jw::JuliaWorkspace, path; ignore_io_errors=false)
    @debug "add_folder_from_disc!" path=path

    process_from_dynamic(jw)

    path_uri = filepath2uri(path)

    files = read_path_into_textdocuments(path_uri, ignore_io_errors=ignore_io_errors)

    for i in files
        _add_file!(jw, i)
    end

    # Reconcile once after the whole batch rather than after every file.
    _reconcile!(jw)
end

"""
    workspace_from_folders(workspace_folders::Vector{String}; dynamic=DynamicOff, symbolcache_download=false, symbolcache_upstream=DEFAULT_SYMBOLCACHE_UPSTREAM)

Create a new [`JuliaWorkspace`](@ref) and populate it by recursively reading
every folder in `workspace_folders` from disc. This is the most convenient entry
point for analysing a project that lives on the local file system.

# Keyword arguments
- `dynamic::DynamicMode`: Whether and how to run the out-of-process dynamic
  feature. See [`DynamicMode`](@ref). Defaults to `DynamicOff`.
- `symbolcache_download::Bool`: If `true`, allow downloading precomputed package
  symbol caches from `symbolcache_upstream` instead of indexing locally.
- `symbolcache_upstream::String`: Upstream URL for symbol-cache downloads.
  Defaults to [`DEFAULT_SYMBOLCACHE_UPSTREAM`](@ref).

# Returns
- A [`JuliaWorkspace`](@ref) containing all files found under the given folders.
"""
function workspace_from_folders(workspace_folders::Vector{String}; dynamic::DynamicMode=DynamicOff, symbolcache_download::Bool=false, symbolcache_upstream::String=DEFAULT_SYMBOLCACHE_UPSTREAM)
    @debug "workspace_from_folders" folders=workspace_folders dynamic=dynamic symbolcache_download=symbolcache_download

    jw = JuliaWorkspace(;dynamic=dynamic, symbolcache_download=symbolcache_download, symbolcache_upstream=symbolcache_upstream)

    for folder in workspace_folders
        add_folder_from_disc!(jw, folder)
    end
    return jw
end
