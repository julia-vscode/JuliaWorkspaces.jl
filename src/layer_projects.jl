Salsa.@derived function derived_project_files(rt)
    @debug "derived_project_files"

    files = input_files(rt)

    return [file for file in files if file.scheme=="file" && (is_path_project_file(uri2filepath(file)) || is_path_manifest_file(uri2filepath(file)))]
end

"""
    derived_project_toml_files(rt, folder_uri)

Probe for Project.toml and Manifest.toml files in `folder_uri` by
constructing candidate URIs and checking via `derived_text_file_content`.
This triggers lazy loading (and the indirect file watch callback) for
files outside the regular workspace.

Returns `(project_file=uri_or_nothing, manifest_file=uri_or_nothing)`.
"""
Salsa.@derived function derived_project_toml_files(rt, folder_uri)
    folder_path = uri2filepath(folder_uri)

    project_file = nothing
    for name in ("JuliaProject.toml", "Project.toml")
        candidate = filepath2uri(joinpath(folder_path, name))
        tf = derived_text_file_content(rt, candidate)
        if tf !== nothing
            project_file = candidate
            break
        end
    end

    manifest_file = nothing
    for name in ("JuliaManifest.toml", "Manifest.toml")
        candidate = filepath2uri(joinpath(folder_path, name))
        tf = derived_text_file_content(rt, candidate)
        if tf !== nothing
            manifest_file = candidate
            break
        end
    end

    return (project_file=project_file, manifest_file=manifest_file)
end

Salsa.@derived function derived_potential_project_folders(rt)
    project_files = derived_project_files(rt)

    pf = Dict{URI,URI}()
    mf = Dict{URI,URI}()

    for file_uri in project_files
        file_path = uri2filepath(file_uri)
        folder_path = dirname(file_path)
        folder_uri = filepath2uri(folder_path)

        if is_path_project_file(file_path)
            if !haskey(pf, folder_uri) || endswith(lowercase(file_path), "juliaproject.toml")
                pf[folder_uri] = file_uri
            end
        elseif is_path_manifest_file(file_path)
            if !haskey(mf, folder_uri) || endswith(lowercase(file_path), "juliamanifest.toml")
                mf[folder_uri] = file_uri
            end
        else
            error("Unknown file type")
        end
    end

    result = Dict{URI,@NamedTuple{project_file::Union{URI,Nothing}, manifest_file::Union{URI,Nothing}}}(
        k => (project_file=v, manifest_file=get(mf, k, nothing)) for (k, v) in pf
    )

    # Include the active project folder even if its files are not in the
    # regular file set (e.g. external environment). The files will be loaded
    # lazily via the indirect file mechanism.
    active_project = input_active_project(rt)
    if active_project !== nothing && !haskey(result, active_project)
        toml_files = derived_project_toml_files(rt, active_project)
        if toml_files.project_file !== nothing
            result[active_project] = toml_files
        end
    end

    return result
end

Salsa.@derived function derived_package(rt, uri)
    @debug "derived_package" uri=uri

    # Try the known project folders first (workspace files + active project),
    # then fall back to lazy probing for DJP-created projects.
    project_folders = derived_potential_project_folders(rt)
    toml_files = get(project_folders, uri, nothing)
    if toml_files === nothing
        toml_files = derived_project_toml_files(rt, uri)
    end

    project_file = toml_files.project_file
    project_file === nothing && return nothing

    syntax_tree = derived_toml_syntax_tree(rt, project_file)

    if haskey(syntax_tree, "name") && haskey(syntax_tree, "uuid") && haskey(syntax_tree, "version")
        parsed_uuid = tryparse(UUID, syntax_tree["uuid"])
        if parsed_uuid!==nothing
            project_text_content = derived_text_file_content(rt, project_file)
            project_text_content === nothing && return nothing
            project_content_hash = hash(project_text_content.content.content)

            return JuliaPackage(project_file, syntax_tree["name"], parsed_uuid, project_content_hash)
        end
    end

    return nothing
end

Salsa.@derived function derived_project(rt, uri)
    @debug "derived_project" uri=uri

    # Try the known project folders first (workspace files + active project),
    # then fall back to lazy probing for DJP-created projects.
    project_folders = derived_potential_project_folders(rt)
    toml_files = get(project_folders, uri, nothing)
    if toml_files === nothing
        toml_files = derived_project_toml_files(rt, uri)
    end

    project_file = toml_files.project_file
    manifest_file = toml_files.manifest_file

    if manifest_file===nothing
        return nothing
    end

    manifest_content = derived_toml_syntax_tree(rt, manifest_file)

    # manifest_content isa Dict || return nothing

    deved_packages = Dict{String,JuliaProjectEntryDevedPackage}()
    regular_packages = Dict{String,JuliaProjectEntryRegularPackage}()
    stdlib_packages = Dict{String,JuliaProjectEntryStdlibPackage}()

    manifest_version_str = get(manifest_content, "manifest_format", "1.0")
    manifest_version = tryparse(VersionNumber, manifest_version_str)

    if manifest_version === nothing
        return nothing
    end

    manifest_deps = if manifest_version.major == 1
        manifest_content
    elseif manifest_version.major == 2 && haskey(manifest_content, "deps") && manifest_content["deps"] isa Dict
        manifest_content["deps"]
    else
        return nothing
    end

    julia_version = if manifest_version.major == 1
        nothing
    elseif manifest_version.major == 2 && haskey(manifest_content, "julia_version")
        tryparse(VersionNumber, manifest_content["julia_version"])
    else
        nothing
    end

    for (k_entry, v_entry) in pairs(manifest_deps)
        v_entry isa Vector || continue
        length(v_entry)==1 || continue
        v_entry[1] isa Dict || continue

        if haskey(v_entry[1], "path") && haskey(v_entry[1], "uuid")
            uuid_of_deved_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_deved_package !== nothing || continue

            path_of_deved_package = v_entry[1]["path"]
            if !isabspath(path_of_deved_package)
                path_of_deved_package = normpath(joinpath(dirname(uri2filepath(manifest_file)), path_of_deved_package))
                if endswith(path_of_deved_package, '\\') || endswith(path_of_deved_package, '/')
                    path_of_deved_package = path_of_deved_package[1:prevind(path_of_deved_package, lastindex(path_of_deved_package))]
                end
            end

            uri_of_deved_package = filepath2uri(path_of_deved_package)

            version_of_deved_package = v_entry[1]["version"]

            deved_packages[k_entry] = JuliaProjectEntryDevedPackage(k_entry, uuid_of_deved_package, uri_of_deved_package, version_of_deved_package)
        elseif haskey(v_entry[1], "git-tree-sha1") && haskey(v_entry[1], "uuid") && haskey(v_entry[1], "version")
            uuid_of_regular_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_regular_package !== nothing || continue

            git_tree_sha1_of_regular_package = v_entry[1]["git-tree-sha1"]

            version_of_regular_package = v_entry[1]["version"]

            regular_packages[k_entry] = JuliaProjectEntryRegularPackage(k_entry, uuid_of_regular_package, version_of_regular_package, git_tree_sha1_of_regular_package)
        elseif haskey(v_entry[1], "uuid")
            uuid_of_stdlib_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_stdlib_package !== nothing || continue

            version_of_stdlib_package = get(v_entry[1], "version", nothing)

            stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, uuid_of_stdlib_package, version_of_stdlib_package)
        else
            error("Unknown manifest entry type $(keys(v_entry[1]))")
        end
    end

    manifest_text_content = derived_text_file_content(rt, manifest_file)
    project_text_content = derived_text_file_content(rt, project_file)
    (manifest_text_content === nothing || project_text_content === nothing) && return nothing
    project_content_hash = hash(project_text_content.content.content, hash(manifest_text_content.content.content))

    JuliaProject(project_file, manifest_file, julia_version, project_content_hash, deved_packages, regular_packages, stdlib_packages)
end

Salsa.@derived function derived_package_folders(rt)
    return URI[i for i in keys(derived_potential_project_folders(rt)) if derived_package(rt, i)!==nothing]
end

Salsa.@derived function derived_project_folders(rt)
    return URI[i for i in keys(derived_potential_project_folders(rt)) if derived_project(rt, i)!==nothing]
end

Salsa.@derived function derived_package_for_file(rt, file::URI)
    packages = derived_package_folders(rt)

    file_path = uri2filepath(file)
    package = packages |>
        x -> map(x) do i
            package_folder_path = uri2filepath(i)
            parts = splitpath(package_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return package
end

Salsa.@derived function derived_project_for_file(rt, file::URI)
    projects = derived_project_folders(rt)

    file_path = uri2filepath(file)
    project = projects |>
        x -> map(x) do i
            project_folder_path = uri2filepath(i)
            parts = splitpath(project_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return project
end
