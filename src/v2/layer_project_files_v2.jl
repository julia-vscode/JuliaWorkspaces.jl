# Full-fidelity parse products for Project.toml and Manifest.toml files:
# `JuliaProjectFile` / `JuliaManifestFile` plus their position-free
# `ProjectTomlProblem` records. The old model structs (`JuliaPackage`,
# `JuliaProject`, `JuliaNonPackageEnv` in layer_projects.jl) are derived views
# over these.
#
# Parsing is tolerant by contract: a malformed field degrades to
# `nothing`/empty AND appends a problem record — never a throw, never a silent
# drop. Problems carry a key path, not a byte range, so the parse products
# backdate across position-only edits; `derived_diagnostics` reattaches ranges
# through the TOML item walk.

# ───────────────────────────────────────────────────────────────────────────────
# Field extraction helpers
#
# Each returns the degraded value and pushes a problem when the raw value has
# the wrong shape. `key_path`/`at` follow the ProjectTomlProblem convention.

function _ptoml_problem!(problems, code::Symbol, key_path::Vector{String}, at::Symbol, message::String)
    push!(problems, ProjectTomlProblem(code, key_path, at, message))
    return nothing
end

function _ptoml_string(problems, code, table, key)::Union{Nothing,String}
    haskey(table, key) || return nothing
    v = table[key]
    v isa String && return v
    return _ptoml_problem!(problems, code, String[key], :value, "`$key` must be a string.")
end

function _ptoml_uuid(problems, code, table, key)::Union{Nothing,UUID}
    haskey(table, key) || return nothing
    v = table[key]
    if v isa String
        parsed = tryparse(UUID, v)
        parsed !== nothing && return parsed
    end
    return _ptoml_problem!(problems, code, String[key], :value, "`$key` is not a valid UUID.")
end

# A `[section]` of name → UUID entries ([deps], [weakdeps], [extras]).
function _ptoml_uuid_table(problems, code, table, section)::Dict{String,UUID}
    result = Dict{String,UUID}()
    haskey(table, section) || return result
    v = table[section]
    if !(v isa Dict)
        _ptoml_problem!(problems, code, String[section], :value, "`$section` must be a table of name = uuid entries.")
        return result
    end
    for (name, raw) in v
        parsed = raw isa String ? tryparse(UUID, raw) : nothing
        if parsed === nothing
            _ptoml_problem!(problems, code, String[section, name], :value, "`$name` in `[$section]` is not a valid UUID.")
        else
            result[name] = parsed
        end
    end
    return result
end

# A string or a list of strings, normalized to a list ([extensions] values).
function _ptoml_string_list(problems, code, key_path, raw)::Union{Nothing,Vector{String}}
    raw isa String && return String[raw]
    if raw isa Vector && all(x -> x isa String, raw)
        return String[x for x in raw]
    end
    return _ptoml_problem!(problems, code, key_path, :value, "`$(join(key_path, '.'))` must be a string or an array of strings.")
end

# ───────────────────────────────────────────────────────────────────────────────
# Project.toml

function _parse_project_file(uri, table, content_hash)
    problems = ProjectTomlProblem[]
    err = :project_file_errors

    name = _ptoml_string(problems, err, table, "name")
    uuid = _ptoml_uuid(problems, err, table, "uuid")
    version = _ptoml_string(problems, err, table, "version")
    if version !== nothing && tryparse(VersionNumber, version) === nothing
        _ptoml_problem!(problems, err, String["version"], :value, "`version` is not a valid version number.")
        version = nothing
    end

    deps = _ptoml_uuid_table(problems, err, table, "deps")
    weakdeps = _ptoml_uuid_table(problems, err, table, "weakdeps")
    extras = _ptoml_uuid_table(problems, err, table, "extras")

    extensions = Dict{String,Vector{String}}()
    if haskey(table, "extensions")
        raw = table["extensions"]
        if raw isa Dict
            for (ext_name, triggers) in raw
                parsed = _ptoml_string_list(problems, err, String["extensions", ext_name], triggers)
                parsed === nothing || (extensions[ext_name] = parsed)
            end
        else
            _ptoml_problem!(problems, err, String["extensions"], :value, "`extensions` must be a table of extension = triggers entries.")
        end
    end

    targets = Dict{String,Vector{String}}()
    if haskey(table, "targets")
        raw = table["targets"]
        if raw isa Dict
            for (target_name, target_deps) in raw
                parsed = _ptoml_string_list(problems, err, String["targets", target_name], target_deps)
                parsed === nothing || (targets[target_name] = parsed)
            end
        else
            _ptoml_problem!(problems, err, String["targets"], :value, "`targets` must be a table of target = dependency-list entries.")
        end
    end

    sources = Dict{String,JuliaSourceEntry}()
    if haskey(table, "sources")
        raw = table["sources"]
        if raw isa Dict
            for (dep_name, entry) in raw
                if !(entry isa Dict)
                    _ptoml_problem!(problems, err, String["sources", dep_name], :value, "A `[sources]` entry must be a table with `url` or `path` (and optionally `rev`, `subdir`).")
                    continue
                end
                fields = Dict{String,Union{Nothing,String}}()
                for key in ("url", "path", "rev", "subdir")
                    v = get(entry, key, nothing)
                    if v !== nothing && !(v isa String)
                        _ptoml_problem!(problems, err, String["sources", dep_name], :value, "`$key` of the `[sources]` entry `$dep_name` must be a string.")
                        v = nothing
                    end
                    fields[key] = v
                end
                if fields["url"] === nothing && fields["path"] === nothing
                    _ptoml_problem!(problems, err, String["sources", dep_name], :value, "The `[sources]` entry `$dep_name` needs a `url` or a `path`.")
                elseif fields["url"] !== nothing && fields["path"] !== nothing
                    _ptoml_problem!(problems, err, String["sources", dep_name], :value, "The `[sources]` entry `$dep_name` has both `url` and `path`; only one is allowed.")
                end
                sources[dep_name] = JuliaSourceEntry(fields["url"], fields["path"], fields["rev"], fields["subdir"])
            end
        else
            _ptoml_problem!(problems, err, String["sources"], :value, "`sources` must be a table of dependency = source entries.")
        end
    end

    workspace_projects = nothing
    if haskey(table, "workspace")
        raw = table["workspace"]
        if raw isa Dict
            if haskey(raw, "projects")
                projects = raw["projects"]
                if projects isa Vector && all(x -> x isa String, projects)
                    workspace_projects = String[x for x in projects]
                else
                    _ptoml_problem!(problems, err, String["workspace", "projects"], :value, "`projects` of the `[workspace]` section must be an array of strings.")
                    workspace_projects = String[]
                end
            else
                _ptoml_problem!(problems, err, String["workspace"], :key, "The `[workspace]` section is missing its `projects` key.")
                workspace_projects = String[]
            end
        else
            _ptoml_problem!(problems, err, String["workspace"], :value, "`workspace` must be a table with a `projects` key.")
        end
    end

    compat = Dict{String,String}()
    if haskey(table, "compat")
        raw = table["compat"]
        if raw isa Dict
            for (dep_name, bound) in raw
                if bound isa String
                    compat[dep_name] = bound
                else
                    _ptoml_problem!(problems, err, String["compat", dep_name], :value, "The `[compat]` entry `$dep_name` must be a string.")
                end
            end
        else
            _ptoml_problem!(problems, err, String["compat"], :value, "`compat` must be a table of dependency = bound entries.")
        end
    end

    app_names = String[]
    if haskey(table, "apps")
        raw = table["apps"]
        if raw isa Dict
            append!(app_names, keys(raw))
            sort!(app_names)
        else
            _ptoml_problem!(problems, err, String["apps"], :value, "`apps` must be a table of app definitions.")
        end
    end

    sort!(problems; by=p -> (p.key_path, p.message))

    return JuliaProjectFile(
        uri, name, uuid, version,
        deps, weakdeps, extras, extensions, targets, sources,
        workspace_projects, compat, app_names, content_hash,
    ), problems
end

"""
    derived_project_file_parse(rt, uri) -> (Union{Nothing,JuliaProjectFile}, Vector{ProjectTomlProblem})

Parse the Project.toml at `uri` (a file URI, not a folder). `nothing` only
when the file does not exist; a malformed file still yields a (degraded)
`JuliaProjectFile` plus the problems. Consumers use the two projections below.
"""
Salsa.@derived function derived_project_file_parse(rt, uri)
    @debug "derived_project_file_parse" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing, ProjectTomlProblem[]

    table = derived_toml_syntax_tree(rt, uri)
    return _parse_project_file(uri, table, hash(tf.content.content))
end

"The parsed Project.toml at file `uri`, or `nothing` when the file does not exist."
Salsa.@derived derived_project_file(rt, uri) = derived_project_file_parse(rt, uri)[1]

"The position-free problem records of the Project.toml at file `uri`."
Salsa.@derived derived_project_file_problems(rt, uri) = derived_project_file_parse(rt, uri)[2]

# ───────────────────────────────────────────────────────────────────────────────
# Manifest.toml

# The key path a manifest entry's diagnostics point at: `[[deps.Foo]]` in
# format 2, `[[Foo]]` in format 1.
_manifest_entry_key_path(format_major, name) =
    format_major == 1 ? String[name] : String["deps", name]

function _parse_manifest_entry(problems, format_major, name, entry)
    err = :manifest_errors
    key_path = _manifest_entry_key_path(format_major, name)

    # Problems inside an entry all point at the entry's own key path — the
    # generic helpers would mislocate them at a same-named top-level key.
    function entry_string(key)
        haskey(entry, key) || return nothing
        v = entry[key]
        v isa String && return v
        _ptoml_problem!(problems, err, key_path, :key, "`$key` of the manifest entry for `$name` must be a string.")
        return nothing
    end

    uuid = nothing
    if haskey(entry, "uuid")
        raw_uuid = entry["uuid"]
        uuid = raw_uuid isa String ? tryparse(UUID, raw_uuid) : nothing
        uuid === nothing && _ptoml_problem!(problems, err, key_path, :key, "`uuid` of the manifest entry for `$name` is not a valid UUID.")
    else
        _ptoml_problem!(problems, err, key_path, :key, "The manifest entry for `$name` has no `uuid`; the package cannot be resolved.")
    end
    version = entry_string("version")
    path = entry_string("path")
    git_tree_sha1 = entry_string("git-tree-sha1")
    repo_url = entry_string("repo-url")

    function dep_list(key)
        haskey(entry, key) || return nothing
        raw = entry[key]
        if raw isa Vector && all(x -> x isa String, raw)
            return String[x for x in raw]
        elseif raw isa Dict
            result = Dict{String,UUID}()
            for (dep_name, dep_uuid) in raw
                parsed = dep_uuid isa String ? tryparse(UUID, dep_uuid) : nothing
                if parsed === nothing
                    _ptoml_problem!(problems, err, key_path, :key, "`$key` of the manifest entry for `$name` has an invalid UUID for `$dep_name`.")
                else
                    result[dep_name] = parsed
                end
            end
            return result
        end
        _ptoml_problem!(problems, err, key_path, :key, "`$key` of the manifest entry for `$name` must be an array of names or a table of name = uuid entries.")
        return nothing
    end

    deps = dep_list("deps")
    weakdeps = dep_list("weakdeps")

    extensions = Dict{String,Vector{String}}()
    if haskey(entry, "extensions")
        raw = entry["extensions"]
        if raw isa Dict
            for (ext_name, triggers) in raw
                parsed = _ptoml_string_list(problems, err, key_path, triggers)
                parsed === nothing || (extensions[ext_name] = parsed)
            end
        else
            _ptoml_problem!(problems, err, key_path, :key, "`extensions` of the manifest entry for `$name` must be a table.")
        end
    end

    return JuliaManifestEntry(name, uuid, version, path, git_tree_sha1, repo_url, deps, weakdeps, extensions)
end

function _parse_manifest_file(uri, table, content_hash)
    problems = ProjectTomlProblem[]
    err = :manifest_errors

    manifest_format = v"1.0.0"
    if haskey(table, "manifest_format")
        raw = table["manifest_format"]
        parsed = raw isa String ? tryparse(VersionNumber, raw) : nothing
        if parsed === nothing
            _ptoml_problem!(problems, err, String["manifest_format"], :value, "`manifest_format` is not a valid version number.")
            sort!(problems; by=p -> (p.key_path, p.message))
            return nothing, problems
        end
        manifest_format = parsed
    end

    if manifest_format.major != 1 && manifest_format.major != 2
        _ptoml_problem!(problems, err, String["manifest_format"], :value, "Unsupported `manifest_format` $(manifest_format); this version of the tooling understands formats 1 and 2.")
        sort!(problems; by=p -> (p.key_path, p.message))
        return nothing, problems
    end

    julia_version = nothing
    if manifest_format.major == 2 && haskey(table, "julia_version")
        raw = table["julia_version"]
        julia_version = raw isa String ? tryparse(VersionNumber, raw) : nothing
        if julia_version === nothing
            _ptoml_problem!(problems, err, String["julia_version"], :value, "`julia_version` is not a valid version number.")
        end
    end

    project_hash = manifest_format.major == 2 ? _ptoml_string(problems, err, table, "project_hash") : nothing

    raw_entries = if manifest_format.major == 1
        table
    elseif haskey(table, "deps") && table["deps"] isa Dict
        table["deps"]
    else
        Dict{String,Any}()
    end

    entries = Dict{String,Vector{JuliaManifestEntry}}()
    for (name, raw) in raw_entries
        # A format-1 manifest may still declare `manifest_format = "1.0"`
        # explicitly; that top-level key is not a package entry. (Format 2 keeps
        # its meta keys outside `deps`, so nothing to skip there.)
        manifest_format.major == 1 && name == "manifest_format" && continue
        if !(raw isa Vector) || !all(x -> x isa Dict, raw)
            # Format 1 top-level scalars (there are none in practice) and any
            # non-entry shape: not a package entry.
            manifest_format.major == 1 && !(raw isa Vector) && continue
            _ptoml_problem!(problems, err, _manifest_entry_key_path(manifest_format.major, name), :key, "The manifest entry for `$name` has an unrecognized shape.")
            continue
        end
        entries[name] = JuliaManifestEntry[
            _parse_manifest_entry(problems, manifest_format.major, name, e) for e in raw
        ]
    end

    sort!(problems; by=p -> (p.key_path, p.message))

    return JuliaManifestFile(uri, manifest_format, julia_version, project_hash, entries, content_hash), problems
end

"""
    derived_manifest_file_parse(rt, uri) -> (Union{Nothing,JuliaManifestFile}, Vector{ProjectTomlProblem})

Parse the Manifest.toml at `uri` (a file URI). `nothing` when the file does
not exist or its `manifest_format` is missing/unsupported — the manifest
cannot be interpreted at all then; every lesser problem degrades per entry.
"""
Salsa.@derived function derived_manifest_file_parse(rt, uri)
    @debug "derived_manifest_file_parse" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing, ProjectTomlProblem[]

    table = derived_toml_syntax_tree(rt, uri)
    return _parse_manifest_file(uri, table, hash(tf.content.content))
end

"The parsed Manifest.toml at file `uri`, or `nothing`."
Salsa.@derived derived_manifest_file(rt, uri) = derived_manifest_file_parse(rt, uri)[1]

"The position-free problem records of the Manifest.toml at file `uri`."
Salsa.@derived derived_manifest_file_problems(rt, uri) = derived_manifest_file_parse(rt, uri)[2]

# ───────────────────────────────────────────────────────────────────────────────
# Cross-section and cross-file validation

"""
    derived_project_semantic_problems(rt, project_file_uri) -> Vector{ProjectTomlProblem}

Problems a single section cannot see: references between sections
(`[extensions]` triggers vs `[weakdeps]`, `[targets]` vs `[extras]`, …),
consistency with the folder's manifest, and the existence of `[sources]` /
`[workspace]` paths on disc (probed through the lazy indirect-file mechanism,
so edits to a member's Project.toml re-run this).
"""
Salsa.@derived function derived_project_semantic_problems(rt, project_file_uri)
    @debug "derived_project_semantic_problems" uri=project_file_uri

    pf = derived_project_file(rt, project_file_uri)
    pf === nothing && return ProjectTomlProblem[]

    problems = ProjectTomlProblem[]
    err = :project_file_errors
    warn = :project_file_warnings
    folder_path = dirname(uri2filepath(project_file_uri))

    # A package needs both halves of its identity.
    if pf.name !== nothing && pf.uuid === nothing && !haskey(derived_toml_syntax_tree(rt, project_file_uri), "uuid")
        _ptoml_problem!(problems, err, String["name"], :key, "The project has a `name` but no `uuid`; Pkg rejects such a project file.")
    end

    declared = union(keys(pf.deps), keys(pf.weakdeps), keys(pf.extras))

    for (ext_name, triggers) in pf.extensions
        for trigger in triggers
            if !(haskey(pf.weakdeps, trigger) || haskey(pf.deps, trigger))
                _ptoml_problem!(problems, err, String["extensions", ext_name], :value, "The extension `$ext_name` lists `$trigger` as a trigger, but `$trigger` is not in `[weakdeps]` (or `[deps]`).")
            end
        end
    end

    for (target_name, target_deps) in pf.targets
        for dep in target_deps
            if !(haskey(pf.extras, dep) || haskey(pf.deps, dep))
                _ptoml_problem!(problems, warn, String["targets", target_name], :value, "The target `$target_name` lists `$dep`, but `$dep` is not in `[extras]` (or `[deps]`).")
            end
        end
    end

    for (dep_name, source) in pf.sources
        if !(dep_name in declared)
            _ptoml_problem!(problems, warn, String["sources", dep_name], :key, "The `[sources]` entry `$dep_name` does not match any entry in `[deps]`, `[weakdeps]` or `[extras]`.")
        end
        if source.path !== nothing
            target = filepath2uri(normpath(joinpath(folder_path, source.path)))
            if derived_project_toml_files(rt, target).project_file === nothing
                _ptoml_problem!(problems, warn, String["sources", dep_name], :value, "The `path` of the `[sources]` entry `$dep_name` does not point at a folder with a Project.toml.")
            end
        end
    end

    for dep_name in keys(pf.compat)
        if !(dep_name == "julia" || dep_name in declared)
            _ptoml_problem!(problems, warn, String["compat", dep_name], :key, "The `[compat]` entry `$dep_name` does not match any entry in `[deps]`, `[weakdeps]` or `[extras]`.")
        end
    end

    if pf.workspace_projects !== nothing
        for member in pf.workspace_projects
            member_folder = filepath2uri(normpath(joinpath(folder_path, member)))
            member_files = derived_project_toml_files(rt, member_folder)
            if member_files.project_file === nothing
                _ptoml_problem!(problems, warn, String["workspace", "projects"], :value, "The workspace member `$member` does not point at a folder with a Project.toml.")
            elseif member_files.manifest_file !== nothing
                _ptoml_problem!(problems, warn, String["workspace", "projects"], :value, "The workspace member `$member` has its own Manifest.toml, which shadows the shared workspace manifest.")
            end
        end
    end

    # Consistency with the effective manifest, when there is one: every
    # `[deps]` entry should be resolved there, under the same UUID. For a
    # manifest-less `[workspace]` member the effective manifest is the
    # outermost root's.
    folder_uri = filepath2uri(folder_path)
    manifest_uri = _folder_toml_files(rt, folder_uri).manifest_file
    if manifest_uri === nothing
        root_uri = derived_workspace_root(rt, folder_uri)
        if root_uri !== nothing
            manifest_uri = _folder_toml_files(rt, root_uri).manifest_file
        end
    end
    if manifest_uri !== nothing && manifest_uri.scheme == "file"
        mf = derived_manifest_file(rt, manifest_uri)
        if mf !== nothing
            for (dep_name, dep_uuid) in pf.deps
                entries = get(mf.entries, dep_name, nothing)
                if entries === nothing
                    _ptoml_problem!(problems, warn, String["deps", dep_name], :key, "`$dep_name` is not in the manifest; the environment may need to be resolved.")
                elseif !any(e -> e.uuid == dep_uuid, entries)
                    _ptoml_problem!(problems, warn, String["deps", dep_name], :value, "`$dep_name` has a different UUID in the manifest; the environment may need to be resolved.")
                end
            end
        end
    end

    sort!(problems; by=p -> (p.key_path, p.message))
    return problems
end

# ───────────────────────────────────────────────────────────────────────────────
# Package-quality checks (ported from Aqua.jl)

"""
    derived_missing_compat_problems(rt, project_file_uri) -> Vector{ProjectTomlProblem}

Findings of the `missing_compat` rule (Aqua.jl's `test_deps_compat`): a
package's Project.toml should declare a `[compat]` entry for `julia` and for
every entry in `[deps]`, `[extras]` and `[weakdeps]` — stdlibs included. Only
packages (name and uuid present) are checked. Config-independent: every
potential finding is produced; the emission join filters by the rule's
`check_julia`/`check_extras`/`check_weakdeps`/`ignore` options, recognizing
the section as the key path's first segment.
"""
Salsa.@derived function derived_missing_compat_problems(rt, project_file_uri)
    @debug "derived_missing_compat_problems" uri=project_file_uri

    pf = derived_project_file(rt, project_file_uri)
    pf === nothing && return ProjectTomlProblem[]
    (pf.name === nothing || pf.uuid === nothing) && return ProjectTomlProblem[]

    problems = ProjectTomlProblem[]

    if !haskey(pf.compat, "julia")
        _ptoml_problem!(problems, :missing_compat, String["compat"], :key,
            "`[compat]` has no `julia` entry.")
    end

    for (section, entries) in (("deps", pf.deps), ("extras", pf.extras), ("weakdeps", pf.weakdeps))
        for name in keys(entries)
            haskey(pf.compat, name) && continue
            _ptoml_problem!(problems, :missing_compat, String[section, name], :key,
                "`$name` in `[$section]` has no `[compat]` entry.")
        end
    end

    sort!(problems; by=p -> (p.key_path, p.message))
    return problems
end

"""
    derived_unused_dependency_problems(rt, project_file_uri) -> Vector{ProjectTomlProblem}

Findings of the `unused_dependency` rule (the static face of Aqua.jl's
`test_stale_deps`): a `[deps]` entry of a package that no `using`/`import`
anywhere in the package's source — the `src/` tree or any extension —
references. `[weakdeps]` never count (they are extension triggers). Where
Aqua accepts a dependency that gets loaded transitively at run time, a static
check cannot see loads, so such deps go on the rule's `ignore` option (the
emission join applies it).

An include the analyzer cannot see through (a computed path, a missing file)
could contain the very import that uses a dependency, so any such include in
the scanned trees silences the whole check for the package.
"""
Salsa.@derived function derived_unused_dependency_problems(rt, project_file_uri)
    @debug "derived_unused_dependency_problems" uri=project_file_uri

    pf = derived_project_file(rt, project_file_uri)
    pf === nothing && return ProjectTomlProblem[]
    (pf.name === nothing || pf.uuid === nothing) && return ProjectTomlProblem[]
    isempty(pf.deps) && return ProjectTomlProblem[]

    folder_path = dirname(uri2filepath(project_file_uri))
    entry_uri = filepath2uri(joinpath(folder_path, "src", "$(pf.name).jl"))
    derived_has_file(rt, entry_uri) || return ProjectTomlProblem[]

    roots = URI[entry_uri]
    for ext_name in sort!(collect(keys(pf.extensions)))
        for candidate in (joinpath(folder_path, "ext", "$(ext_name).jl"),
                          joinpath(folder_path, "ext", ext_name, "$(ext_name).jl"))
            ext_uri = filepath2uri(candidate)
            if derived_has_file(rt, ext_uri)
                push!(roots, ext_uri)
                break
            end
        end
    end

    used = Set{String}()
    for root in roots
        tree = derived_module_tree(rt, root)
        for file_uri in keys(tree.file_modules)
            for (_, _, target, _, _) in derived_file_include_records(rt, file_uri)
                if target === nothing || derived_text_file_content(rt, target) === nothing
                    return ProjectTomlProblem[]
                end
            end
        end
        for node in tree.modules
            for ri in node.imports
                ri.target.sort === :tree && continue
                isempty(ri.target.path) && continue
                push!(used, ri.target.path[1])
            end
        end
    end

    problems = ProjectTomlProblem[]
    for name in keys(pf.deps)
        name in used && continue
        haskey(pf.weakdeps, name) && continue
        _ptoml_problem!(problems, :unused_dependency, String["deps", name], :key,
            "`$name` is a declared dependency, but no `using`/`import` in this package's source (or its extensions) references it. If it is only needed indirectly, add it to this rule's `ignore` list.")
    end

    sort!(problems; by=p -> (p.key_path, p.message))
    return problems
end
