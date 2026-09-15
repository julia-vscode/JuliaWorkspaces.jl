# Loading a package the active environment's MANIFEST locates but its
# PROJECT does not name in `[deps]`: a `[workspace]` member (or a package the
# root manifest devs for another member) seen from the root project. Only
# `Base` is needed here, so the file can be loaded on its own in tests.

# The bare package name of a `using Pkg` / `import Pkg` statement, else `nothing`.
function _bare_import_name(stmt::AbstractString)
    m = match(r"^\s*(?:using|import)\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", stmt)
    return m === nothing ? nothing : String(m.captures[1])
end

# The `PkgId` the active project's manifest records for `name`, or `nothing`
# (no manifest, no such entry, or an ambiguous one).
function _manifest_pkgid(name::AbstractString)
    project = Base.active_project()
    project === nothing && return nothing
    manifest = Base.project_file_manifest_path(project)
    manifest === nothing && return nothing
    parsed = try
        Base.parsed_toml(manifest)
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
    deps = get(parsed, "deps", nothing)
    deps isa AbstractDict || return nothing
    entries = get(deps, String(name), nothing)
    (entries isa AbstractVector && length(entries) == 1) || return nothing
    u = get(entries[1], "uuid", nothing)
    u isa AbstractString || return nothing
    return Base.PkgId(Base.UUID(u), String(name))
end

# `using Member` fails from a workspace root ("Package Member not found in
# current path": `identify_package` consults the project's `[deps]` only),
# although `locate_package` finds it through the manifest. Load it by
# identity; `nothing` when the manifest does not know it either.
function _require_from_manifest(name::AbstractString)
    id = _manifest_pkgid(name)
    id === nothing && return nothing
    return Base.require(id)
end
