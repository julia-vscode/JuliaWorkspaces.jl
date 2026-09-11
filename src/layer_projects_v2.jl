# The v2 project model, behind `input_v2_enabled`: the twins of
# `derived_package`, `derived_project` and `derived_nonpackage_env`
# (layer_projects.jl gates to them). Built on the typed Project/Manifest
# parse (layer_project_files_v2.jl) and workspace discovery
# (layer_workspaces_v2.jl): `[sources]` paths surface as deved packages, a
# manifest-less `[workspace]` member is a synthesized project against the
# root's manifest, and a root's content hash folds its members' project
# files. Everything downstream (`derived_environment`, the folder classes,
# the DJP work items) reads the model through the gated v1 names.

Salsa.@derived function derived_package_v2(rt, uri)
    @debug "derived_package_v2" uri=uri

    # Try the known project folders first (workspace files + active project),
    # then fall back to lazy probing for DJP-created projects.
    project_folders = derived_potential_project_folders(rt)
    toml_files = get(project_folders, uri, nothing)
    if toml_files === nothing
        toml_files = derived_project_toml_files(rt, uri)
    end

    project_file = toml_files.project_file
    project_file === nothing && return nothing

    pf = derived_project_file(rt, project_file)
    pf === nothing && return nothing

    # A package needs the full identity triple; a malformed field degraded to
    # `nothing` at parse time (and was recorded as a problem there).
    (pf.name === nothing || pf.uuid === nothing || pf.version === nothing) && return nothing

    return JuliaPackage(project_file, pf.name, pf.uuid, pf.content_hash)
end

Salsa.@derived function derived_project_v2(rt, uri)
    @debug "derived_project_v2" uri=uri

    # `nothing` means no project (e.g. no active project and the file is not
    # inside any package or project folder)
    uri === nothing && return nothing

    # Try the known project folders first (workspace files + active project),
    # then fall back to lazy probing for DJP-created projects.
    project_folders = derived_potential_project_folders(rt)
    toml_files = get(project_folders, uri, nothing)
    if toml_files === nothing
        toml_files = derived_project_toml_files(rt, uri)
    end

    project_file = toml_files.project_file
    manifest_file = toml_files.manifest_file

    # A folder without a Project file is not a project, even if it has a
    # Manifest.toml (e.g. a DJP-created temp project directory whose
    # Project.toml is missing or was deleted).
    project_file === nothing && return nothing

    # A folder without a manifest of its own may still be a project: a
    # `[workspace]` member resolves against the outermost root's manifest.
    if manifest_file === nothing || manifest_file.scheme != "file"
        return _workspace_member_project(rt, uri, project_file)
    end

    mf = derived_manifest_file(rt, manifest_file)
    # `nothing` when the manifest is missing or its format is one this tooling
    # cannot interpret (the parse recorded a `:manifest_errors` problem).
    mf === nothing && return nothing

    deved_packages = Dict{String,JuliaProjectEntryDevedPackage}()
    regular_packages = Dict{String,JuliaProjectEntryRegularPackage}()
    stdlib_packages = Dict{String,JuliaProjectEntryStdlibPackage}()

    for (k_entry, entry_list) in mf.entries
        _classify_manifest_entry!(deved_packages, regular_packages, stdlib_packages,
            manifest_file, k_entry, entry_list)
    end

    manifest_text_content = derived_text_file_content(rt, manifest_file)
    project_text_content = derived_text_file_content(rt, project_file)
    (manifest_text_content === nothing || project_text_content === nothing) && return nothing
    project_content_hash = hash(project_text_content.content.content, hash(manifest_text_content.content.content))

    pf = derived_project_file(rt, project_file)
    _apply_path_sources!(deved_packages, regular_packages, stdlib_packages, pf, project_file)

    # A workspace root's environment covers its members: fold every member's
    # Project.toml text into the hash so a member dep change re-keys the root's
    # watch item (the shared manifest and index must be refreshed for it).
    # `derived_workspace_members` is sorted, so the fold is deterministic.
    if pf !== nothing && pf.workspace_projects !== nothing
        for member_uri in derived_workspace_members(rt, uri)
            member_project_file = _folder_toml_files(rt, member_uri).project_file
            member_project_file === nothing && continue
            member_text = derived_text_file_content(rt, member_project_file)
            member_text === nothing && continue
            project_content_hash = hash(member_text.content.content, project_content_hash)
        end
    end

    JuliaProject(project_file, manifest_file, mf.julia_version, project_content_hash, deved_packages, regular_packages, stdlib_packages)
end

"""
    _classify_manifest_entry!(deved, regular, stdlib, manifest_file, name, entry_list)

Sort one manifest entry into the three `JuliaProject` package classes: a
`path` entry is deved (the path absolutized against the manifest's folder), a
`git-tree-sha1` + `version` entry is regular unless the uuid is a bundled
stdlib, everything else with a uuid is a stdlib. A name recorded more than
once (distinct UUIDs sharing a name) cannot be mapped through the name-keyed
store lookups and is skipped; so is an entry whose uuid did not parse (the
manifest parse recorded a `:manifest_errors` problem for it).
"""
function _classify_manifest_entry!(deved_packages, regular_packages, stdlib_packages,
        manifest_file, k_entry, entry_list)
    length(entry_list) == 1 || return
    entry = entry_list[1]
    entry.uuid === nothing && return

    if entry.path !== nothing
        path_of_deved_package = entry.path
        if !isabspath(path_of_deved_package)
            path_of_deved_package = normpath(joinpath(dirname(uri2filepath(manifest_file)), path_of_deved_package))
            if endswith(path_of_deved_package, '\\') || endswith(path_of_deved_package, '/')
                path_of_deved_package = path_of_deved_package[1:prevind(path_of_deved_package, lastindex(path_of_deved_package))]
            end
        end

        uri_of_deved_package = filepath2uri(path_of_deved_package)

        # A deved-package manifest entry may omit `version` (it is pinned by
        # the deved path, not a registered version), e.g. Julia's own
        # `test/project`. Default to "" rather than indexing unconditionally.
        version_of_deved_package = something(entry.version, "")

        deved_packages[k_entry] = JuliaProjectEntryDevedPackage(k_entry, entry.uuid, uri_of_deved_package, version_of_deved_package)
    elseif entry.git_tree_sha1 !== nothing && entry.version !== nothing
        # A now-stdlib package recorded as registered (git-tree-sha1) is
        # resolved to the bundled stdlib by the indexer child; classify it as
        # a stdlib keyed by the bundled version to match.
        stdlib_ver = _stdlib_cache_version(entry.uuid)
        if stdlib_ver !== nothing
            stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, entry.uuid, string(stdlib_ver))
        else
            regular_packages[k_entry] = JuliaProjectEntryRegularPackage(k_entry, entry.uuid, entry.version, entry.git_tree_sha1)
        end
    else
        version_of_stdlib_package = entry.version
        # A stdlib recorded with a stale version — or with no version at
        # all, the common shape in manifests — is keyed by the bundled
        # version, matching the child's cache writer. Without this a
        # versionless stdlib entry stays `nothing` and is skipped by every
        # cache-loading site, so its symbols never resolve.
        stdlib_ver = _stdlib_cache_version(entry.uuid)
        stdlib_ver !== nothing && (version_of_stdlib_package = string(stdlib_ver))

        stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, entry.uuid, version_of_stdlib_package)
    end
    return
end

"""
    _apply_path_sources!(deved, regular, stdlib, pf, project_file)

Surface a `[sources]` `path` entry that the manifest does not resolve as a
deved package: Pkg treats a path source like a dev, so an in-workspace
path-sourced package should resolve even while the manifest is stale. Entries
the manifest already classifies are left alone (the manifest's absolutized
path wins), and an entry whose name has no UUID anywhere in the project file
is skipped (the semantic validation reports it).
"""
function _apply_path_sources!(deved_packages, regular_packages, stdlib_packages, pf, project_file)
    pf === nothing && return
    for (name, source) in pf.sources
        source.path === nothing && continue
        haskey(deved_packages, name) && continue
        haskey(regular_packages, name) && continue
        haskey(stdlib_packages, name) && continue

        uuid = get(pf.deps, name, nothing)
        uuid === nothing && (uuid = get(pf.weakdeps, name, nothing))
        uuid === nothing && (uuid = get(pf.extras, name, nothing))
        uuid === nothing && continue

        path = source.path
        isabspath(path) || (path = normpath(joinpath(dirname(uri2filepath(project_file)), path)))
        deved_packages[name] = JuliaProjectEntryDevedPackage(name, uuid, filepath2uri(_normalized_folder_path(path)), "")
    end
    return
end

"""
    _manifest_dep_closure(mf::JuliaManifestFile, roots) -> Set{String}

The manifest entry names reachable from the dependency names in `roots` over
the entries' `deps` edges. Weakdeps are not followed (they are not installed).
Names recorded more than once are skipped, like classification skips them.
"""
function _manifest_dep_closure(mf::JuliaManifestFile, roots)
    reachable = Set{String}()
    queue = String[name for name in roots]
    while !isempty(queue)
        name = pop!(queue)
        name in reachable && continue
        entry_list = get(mf.entries, name, nothing)
        (entry_list === nothing || length(entry_list) != 1) && continue
        push!(reachable, name)
        deps = entry_list[1].deps
        deps === nothing && continue
        append!(queue, deps isa Vector ? deps : keys(deps))
    end
    return reachable
end

"""
    _workspace_member_project(rt, member_uri, project_file) -> Union{Nothing,JuliaProject}

The synthesized project of a manifest-less `[workspace]` member: the member's
`[deps]` closure over the outermost root's manifest, classified like any other
project's entries. The member packages themselves are `path` entries in that
manifest, so `using ParentPkg` from a `test/` member resolves as a deved
package. `nothing` when no declaring root with a manifest exists — the folder
then falls back to the package / non-package-env classes as before.

`manifest_file_uri` points into the root: `dirname(manifest) != folder` is
what marks a `JuliaProject` as a synthesized member (`_is_synthesized_member`).
"""
function _workspace_member_project(rt, member_uri, project_file)
    root_uri = derived_workspace_root(rt, member_uri)
    root_uri === nothing && return nothing

    root_manifest = _folder_toml_files(rt, root_uri).manifest_file
    (root_manifest === nothing || root_manifest.scheme != "file") && return nothing

    mf = derived_manifest_file(rt, root_manifest)
    mf === nothing && return nothing

    pf = derived_project_file(rt, project_file)
    pf === nothing && return nothing

    deved_packages = Dict{String,JuliaProjectEntryDevedPackage}()
    regular_packages = Dict{String,JuliaProjectEntryRegularPackage}()
    stdlib_packages = Dict{String,JuliaProjectEntryStdlibPackage}()

    for name in _manifest_dep_closure(mf, keys(pf.deps))
        _classify_manifest_entry!(deved_packages, regular_packages, stdlib_packages,
            root_manifest, name, mf.entries[name])
    end

    _apply_path_sources!(deved_packages, regular_packages, stdlib_packages, pf, project_file)

    manifest_text_content = derived_text_file_content(rt, root_manifest)
    project_text_content = derived_text_file_content(rt, project_file)
    (manifest_text_content === nothing || project_text_content === nothing) && return nothing
    project_content_hash = hash(project_text_content.content.content, hash(manifest_text_content.content.content))

    return JuliaProject(project_file, root_manifest, mf.julia_version, project_content_hash,
        deved_packages, regular_packages, stdlib_packages)
end

"""
    _is_synthesized_member(project::JuliaProject, folder_uri) -> Bool

Whether `project` is a synthesized workspace-member project — its manifest
lives at the workspace root, not in its own folder. Such a project has no
watch item of its own: the root's `WatchEnvironmentKey` covers it (see
`_watch_target_for_project`).
"""
function _is_synthesized_member(project::JuliaProject, folder_uri)
    return !_folder_paths_equal(
        _normalized_folder_path(dirname(uri2filepath(project.manifest_file_uri))),
        _normalized_folder_path(uri2filepath(folder_uri)),
    )
end

"""
    derived_nonpackage_env_v2(rt, uri) -> Union{Nothing,JuliaNonPackageEnv}

The non-package, manifest-less environment at folder `uri`, or `nothing`. The
three folder classes are disjoint by construction: a package has
name+uuid+version (`derived_package_v2`), a project has a manifest
(`derived_project_v2`), and a non-package env has neither.
"""
Salsa.@derived function derived_nonpackage_env_v2(rt, uri)
    @debug "derived_nonpackage_env_v2" uri=uri

    project_folders = derived_potential_project_folders(rt)
    toml_files = get(project_folders, uri, nothing)
    if toml_files === nothing
        toml_files = derived_project_toml_files(rt, uri)
    end

    project_file = toml_files.project_file
    project_file === nothing && return nothing
    toml_files.manifest_file === nothing || return nothing  # has a manifest → project
    derived_package_v2(rt, uri) === nothing || return nothing  # package → standalone-project path
    # A workspace member is a (synthesized) project against the root's
    # manifest, not an env that needs its own resolution.
    derived_project_v2(rt, uri) === nothing || return nothing

    project_text_content = derived_text_file_content(rt, project_file)
    project_text_content === nothing && return nothing

    return JuliaNonPackageEnv(project_file, hash(project_text_content.content.content))
end
