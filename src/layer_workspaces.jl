# Workspace ([workspace] in Project.toml) discovery: which folder is a member
# of which workspace, and where the outermost root — the folder whose manifest
# every member resolves against — is.
#
# Membership is declared downward (`projects = ["test", "docs"]`) but resolved
# upward, the way Pkg does it: a folder is a member iff some ancestor's
# Project.toml lists it. Ancestor probing goes through the lazy indirect-file
# mechanism (`derived_project_toml_files`), so a workspace root outside the
# opened folders is found and watched, and edits to it re-run these queries.
#
# The queries here only answer "who declares whom"; what membership *means*
# (a synthesized project against the root manifest, fewer DJPs) lives in
# layer_projects.jl / layer_environment.jl.

# Path identity for member declarations: separators and `..` normalized,
# trailing separators dropped, case-insensitive on Windows.
_normalized_folder_path(path::AbstractString) = String(rstrip(normpath(path), ('/', '\\')))
_folder_paths_equal(a::AbstractString, b::AbstractString) =
    Sys.iswindows() ? lowercase(a) == lowercase(b) : a == b

"""
    _folder_toml_files(rt, folder_uri)

The `(project_file, manifest_file)` of a folder: the workspace-file scan's
answer when the folder is known, the lazy probe otherwise. The lookup pattern
`derived_package`/`derived_project`/`derived_nonpackage_env` share.
"""
function _folder_toml_files(rt, folder_uri)
    toml_files = get(derived_potential_project_folders(rt), folder_uri, nothing)
    toml_files === nothing || return toml_files
    return derived_project_toml_files(rt, folder_uri)
end

"""
    derived_declaring_workspace_parent(rt, folder_uri) -> Union{Nothing,URI}

The nearest ancestor folder whose Project.toml declares `folder_uri` as a
`[workspace]` member, or `nothing`. Walks every ancestor up to the filesystem
root — Pkg finds workspace roots the same way, so a root far above the opened
folder still counts.
"""
Salsa.@derived function derived_declaring_workspace_parent(rt, folder_uri)
    folder_path = uri2filepath(folder_uri)
    folder_path === nothing && return nothing
    folder_path = _normalized_folder_path(folder_path)

    current = dirname(folder_path)
    while true
        parent_uri = filepath2uri(current)
        project_file = _folder_toml_files(rt, parent_uri).project_file
        if project_file !== nothing
            pf = derived_project_file(rt, project_file)
            if pf !== nothing && pf.workspace_projects !== nothing
                for member in pf.workspace_projects
                    member_path = _normalized_folder_path(joinpath(current, member))
                    if _folder_paths_equal(member_path, folder_path)
                        return parent_uri
                    end
                end
            end
        end
        next = dirname(current)
        # dirname is idempotent at the filesystem root.
        _folder_paths_equal(next, current) && return nothing
        current = next
    end
end

"""
    derived_workspace_root(rt, folder_uri) -> Union{Nothing,URI}

The outermost workspace root for `folder_uri`, or `nothing` when no ancestor
declares it. Nested workspaces chase to the outermost declaring folder — the
one Pkg puts the shared manifest at. Cycle-free by construction: a declaring
parent is always a strict ancestor.
"""
Salsa.@derived function derived_workspace_root(rt, folder_uri)
    parent = derived_declaring_workspace_parent(rt, folder_uri)
    parent === nothing && return nothing
    outer = derived_workspace_root(rt, parent)
    return outer === nothing ? parent : outer
end

"""
    derived_workspace_members(rt, root_uri) -> Vector{URI}

The transitive `[workspace]` members declared from `root_uri` downward
(members of members included), deduplicated and sorted. Purely declarative —
a listed folder is a member even when it has no Project.toml yet (the
semantic validation in layer_project_files.jl reports that).
"""
Salsa.@derived function derived_workspace_members(rt, root_uri)
    result = URI[]
    seen = Set{URI}([root_uri])
    queue = URI[root_uri]
    while !isempty(queue)
        folder_uri = popfirst!(queue)
        folder_path = uri2filepath(folder_uri)
        folder_path === nothing && continue
        project_file = _folder_toml_files(rt, folder_uri).project_file
        project_file === nothing && continue
        pf = derived_project_file(rt, project_file)
        (pf === nothing || pf.workspace_projects === nothing) && continue
        for member in pf.workspace_projects
            member_uri = filepath2uri(_normalized_folder_path(joinpath(folder_path, member)))
            member_uri in seen && continue
            push!(seen, member_uri)
            push!(result, member_uri)
            push!(queue, member_uri)
        end
    end
    sort!(result; by=string)
    return result
end
