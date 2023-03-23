module SemanticPassTomlFiles

import UUIDs
using UUIDs: UUID

import ..URIs2
using ..URIs2: URI, uri2filepath, filepath2uri

import ...JuliaWorkspaces
using ...JuliaWorkspaces: JuliaPackage, JuliaProject, JuliaDevedPackage

function semantic_pass_toml_files(toml_syntax_trees)
    # Extract all packages & paths with a manifest
    packages = Dict{URI,JuliaPackage}()
    paths_with_manifest = Dict{String,Dict}()
    for (k,v) in pairs(toml_syntax_trees)
        # TODO Maybe also check the filename here and only do the package detection for Project.toml and JuliaProject.toml
        if haskey(v, "name") && haskey(v, "uuid") && haskey(v, "version")
            parsed_uuid = tryparse(UUID, v["uuid"])
            if parsed_uuid!==nothing
                folder_uri = k |> uri2filepath |> dirname |> filepath2uri
                packages[folder_uri] = JuliaPackage(k, v["name"], parsed_uuid)
            end
        end

        path = uri2filepath(k)
        dname = dirname(path)
        filename = basename(path)
        filename_lc = lowercase(filename)
        if filename_lc == "manifest.toml" || filename_lc == "juliamanifest.toml"
            paths_with_manifest[dname] = v
        end
    end

    # Extract all projects
    projects = Dict{URI,JuliaProject}()
    for (k,_) in pairs(toml_syntax_trees)
        path = uri2filepath(k)
        dname = dirname(path)
        filename = basename(path)
        filename_lc = lowercase(filename)

        if (filename_lc=="project.toml" || filename_lc=="juliaproject.toml" ) && haskey(paths_with_manifest, dname)
            manifest_content = paths_with_manifest[dname]
            manifest_content isa Dict || continue
            deved_packages = Dict{URI,JuliaDevedPackage}()
            manifest_version = get(manifest_content, "manifest_format", "1.0")

            manifest_deps = if manifest_version=="1.0"
                manifest_content
            elseif manifest_version=="2.0" && haskey(manifest_content, "deps") && manifest_content["deps"] isa Dict
                manifest_content["deps"]
            else
                continue
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
                    path_of_deved_package = normpath(joinpath(dname, path_of_deved_package))
                    if endswith(path_of_deved_package, '\\') || endswith(path_of_deved_package, '/')
                        path_of_deved_package = path_of_deved_package[1:end-1]
                    end
                end

                uri_of_deved_package = filepath2uri(path_of_deved_package)

                deved_packages[uri_of_deved_package] = JuliaDevedPackage(k_entry, uuid_of_deved_package)
            end

            folder_uri = k |> uri2filepath |> dirname |> filepath2uri
            projects[folder_uri] = JuliaProject(k, deved_packages)
        end
    end

    return packages, projects
end

end
