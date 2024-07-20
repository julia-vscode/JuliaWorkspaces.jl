Salsa.@derived function derived_project_files(rt)
    files = input_files(rt)

    return [file for file in files if is_path_project_file(uri2filepath(file)) || is_path_manifest_file(uri2filepath(file))]
end

Salsa.@derived function derived_potential_project_folders(rt)
    project_files = derived_project_files(rt)

    pf = Dict{URI,URI}()
    mf = Dict{URI,URI}()

    for file_uri in project_files
        file_path = uri2filepath(file_uri)
        folder_path = dirname(file_path)
        fodler_uri = filepath2uri(folder_path)

        if is_path_project_file(file_path)
            if !haskey(pf, folder_path) || endswith(lowercase(file_path), "juliaproject.toml")
                pf[fodler_uri] =file_uri
            end
        elseif is_path_manifest_file(file_path)
            if !haskey(mf, folder_path) || endswith(lowercase(file_path), "juliamanifest.toml")
                mf[fodler_uri] =file_uri
            end
        else
            error("Unknown file type")
        end
    end

    return Dict(k => (project_file=v, manifest_file=get(mf,k,nothing)) for (k,v) in pf)
end

Salsa.@derived function derived_package(rt, uri)
    project_folders = derived_potential_project_folders(rt)

    project_file = project_folders[uri].project_file

    syntax_tree = derived_toml_syntax_tree(rt, project_file)

    if haskey(syntax_tree, "name") && haskey(syntax_tree, "uuid") && haskey(syntax_tree, "version")
        parsed_uuid = tryparse(UUID, syntax_tree["uuid"])
        if parsed_uuid!==nothing
            project_text_content = input_text_file(rt, project_file)
            project_content_hash = hash(project_text_content.content.content)

            return JuliaPackage(project_file, syntax_tree["name"], parsed_uuid, project_content_hash)
        end
    end

    return nothing
end

Salsa.@derived function derived_project(rt, uri)
    project_folders = derived_potential_project_folders(rt)

    project_file = project_folders[uri].project_file
    manifest_file = project_folders[uri].manifest_file

    if manifest_file===nothing
        return nothing
    end

    manifest_content = derived_toml_syntax_tree(rt, manifest_file)

    # manifest_content isa Dict || return nothing

    deved_packages = Dict{URI,JuliaDevedPackage}()
    manifest_version = get(manifest_content, "manifest_format", "1.0")

    manifest_deps = if manifest_version=="1.0"
        manifest_content
    elseif manifest_version=="2.0" && haskey(manifest_content, "deps") && manifest_content["deps"] isa Dict
        manifest_content["deps"]
    else
        error("")
    end

    for (k_entry, v_entry) in pairs(manifest_deps)
        v_entry isa Vector || continue
        length(v_entry)==1 || continue
        v_entry[1] isa Dict || continue
        haskey(v_entry[1], "path") || continue
        haskey(v_entry[1], "uuid") || continue
        uuid_of_deved_package = tryparse(UUID, v_entry[1]["uuid"])
        uuid_of_deved_package !== nothing || continue

        path_of_deved_package = v_entry[1]["path"]
        if !isabspath(path_of_deved_package)
            path_of_deved_package = normpath(joinpath(dirname(uri2filepath(manifest_file)), path_of_deved_package))
            if endswith(path_of_deved_package, '\\') || endswith(path_of_deved_package, '/')
                path_of_deved_package = path_of_deved_package[1:end-1]
            end
        end

        uri_of_deved_package = filepath2uri(path_of_deved_package)

        deved_packages[uri_of_deved_package] = JuliaDevedPackage(k_entry, uuid_of_deved_package)
    end

    manifest_text_content = input_text_file(rt, manifest_file)
    project_text_content = input_text_file(rt, project_file)
    project_content_hash = hash(project_text_content.content.content, hash(manifest_text_content.content.content))

    JuliaProject(project_file, manifest_file, project_content_hash, deved_packages)
end

Salsa.@derived function derived_package_folders(rt)
    return URI[i for i in keys(derived_potential_project_folders(rt)) if derived_package(rt, i)!==nothing]
end

Salsa.@derived function derived_project_folders(rt)
    return URI[i for i in keys(derived_potential_project_folders(rt)) if derived_project(rt, i)!==nothing]
end
