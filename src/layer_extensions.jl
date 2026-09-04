# Package extensions ([weakdeps] + [extensions] in Project.toml): mapping
# `ext/` files to their extension, and finding an environment that contains
# the extension's triggers.
#
# Selection is two-tiered. The borrowing fast path finds an EXISTING project
# whose manifest already resolves every trigger (the package's own env, the
# project deving it, the workspace root, the test/ member, the merged test
# env — test deps routinely include the triggers). Only when none covers them
# is a `ResolveExtensionEnvironmentKey` work item scheduled, whose child
# resolves a scratch project of package + weakdeps
# (`write_extension_env_project` on the child side). While that item is
# pending, `derived_file_env_ready` gates the ext files; after a terminal
# failure the unresolvable triggers become an analysis boundary — silent by
# default, reported via the opt-in `:analysis_boundary` rule
# (layer_diagnostics.jl).

"""
    derived_extension_for_file(rt, uri)
        -> Union{Nothing,@NamedTuple{package_folder::URI, ext_name::String, triggers::Vector{String}}}

The extension a file belongs to: the file lives under the enclosing package's
`ext/` folder and its first path segment there names a declared
`[extensions]` entry (both layouts: `ext/<ExtName>.jl` and
`ext/<ExtName>/...`). `nothing` for every other file — including `ext/`
helpers that match no declared extension, which stay ordinary package files.
"""
Salsa.@derived function derived_extension_for_file(rt, uri)
    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing && return nothing

    file_path = uri2filepath(uri)
    file_path === nothing && return nothing

    # `derived_package_for_file` established the prefix; only the segment
    # under the package folder matters. Lowercase `ext` comparison: same
    # Windows-first reasoning (and TODO) as `_file_needs_test_env`.
    parts = splitpath(file_path)
    package_depth = length(splitpath(uri2filepath(package_folder_uri)))
    length(parts) >= package_depth + 2 || return nothing
    lowercase(parts[package_depth+1]) == "ext" || return nothing

    pkg = derived_package(rt, package_folder_uri)
    pkg === nothing && return nothing
    pf = derived_project_file(rt, pkg.project_file_uri)
    (pf === nothing || isempty(pf.extensions)) && return nothing

    seg = parts[package_depth+2]
    ext_name = endswith(lowercase(seg), ".jl") ? seg[1:end-3] : seg

    triggers = get(pf.extensions, ext_name, nothing)
    triggers === nothing && return nothing

    return (package_folder=package_folder_uri, ext_name=ext_name, triggers=triggers)
end

"Whether `project`'s manifest resolves every name in `triggers`."
_project_covers_triggers(project::JuliaProject, triggers) =
    all(t -> haskey(project.deved_packages, t) || haskey(project.regular_packages, t) ||
             haskey(project.stdlib_packages, t), triggers)

"""
    _extension_candidate_projects(rt, package_folder_uri) -> Vector{URI}

The existing projects whose environment might already contain a package's
extension triggers, in preference order: the package's own project, the
project deving it, the workspace root, the `test/` workspace member, the
merged test environment (test deps routinely include the triggers).
"""
function _extension_candidate_projects(rt, package_folder_uri)
    candidates = URI[]
    package_folder_uri in derived_project_folders(rt) && push!(candidates, package_folder_uri)

    deving = derived_deving_project(rt, package_folder_uri)
    deving === nothing || push!(candidates, deving)

    root = derived_workspace_root(rt, package_folder_uri)
    root === nothing || push!(candidates, root)

    test_member = _test_member_project_folder(rt, package_folder_uri)
    test_member === nothing || push!(candidates, test_member)

    pkg = derived_package(rt, package_folder_uri)
    if pkg !== nothing
        test_env_key = _test_environment_key(rt, package_folder_uri, pkg)
        if test_env_key !== nothing
            ready = derived_ready_test_environment(rt, test_env_key)
            ready === nothing || push!(candidates, ready)
        end
    end

    return candidates
end

"""
    _extension_environment_key(rt, package_folder_uri, pkg) -> ResolveExtensionEnvironmentKey

The identity of the extension-environment work item for the package at
`package_folder_uri`. One per package, covering all its extensions; the hash
is the package Project.toml's text hash, so a `[weakdeps]`/`[extensions]`
edit re-keys the work. Single source of truth: the required set, the
readiness gate and the selection fallback must derive the same key.
"""
_extension_environment_key(rt, package_folder_uri, pkg) =
    ResolveExtensionEnvironmentKey(uri2filepath(package_folder_uri), pkg.content_hash)

"""
    derived_ready_extension_environment(rt, key) -> Union{Nothing,URI}

The resolved extension-environment scratch project for `key`, or `nothing`.
Per-key wrapper over the collection input (see the fan-out note in
layer_environment.jl).
"""
Salsa.@derived function derived_ready_extension_environment(rt, key::ResolveExtensionEnvironmentKey)
    return get(input_extension_environments(rt), key, nothing)
end

"""
    derived_extension_environment_pending(rt, key) -> Bool

Whether the extension-environment work item `key` is scheduled and can still
produce a result. False when none is scheduled and false once the item failed
terminally — waiting for either would gate forever.
"""
Salsa.@derived function derived_extension_environment_pending(rt, key::ResolveExtensionEnvironmentKey)
    key in input_failed_dynamic_keys(rt) && return false
    return key in derived_required_dynamic_projects(rt)
end

"""
    derived_extension_project_uri(rt, package_folder_uri, ext_name) -> Union{Nothing,URI}

The project whose environment the extension `ext_name` of the package at
`package_folder_uri` should be analyzed against: the first candidate project
covering all its triggers, else the resolved extension environment once its
work item has produced one, else `nothing` (analysis falls back to the
package's own environment, gated/degraded).
"""
Salsa.@derived function derived_extension_project_uri(rt, package_folder_uri, ext_name::String)
    pkg = derived_package(rt, package_folder_uri)
    pkg === nothing && return nothing
    pf = derived_project_file(rt, pkg.project_file_uri)
    pf === nothing && return nothing
    triggers = get(pf.extensions, ext_name, nothing)
    triggers === nothing && return nothing

    for candidate in _extension_candidate_projects(rt, package_folder_uri)
        project = derived_project(rt, candidate)
        project === nothing && continue
        _project_covers_triggers(project, triggers) && return candidate
    end

    return derived_ready_extension_environment(rt, _extension_environment_key(rt, package_folder_uri, pkg))
end

"""
    _extension_entry_exists(rt, package_path, ext_name) -> Bool

Whether the extension's entry file is present in the workspace, in either
layout. Used to avoid scheduling an extension-environment work item for a
declared extension whose sources are not actually there.
"""
_extension_entry_exists(rt, package_path, ext_name) =
    derived_has_file(rt, filepath2uri(joinpath(package_path, "ext", "$(ext_name).jl"))) ||
    derived_has_file(rt, filepath2uri(joinpath(package_path, "ext", ext_name, "$(ext_name).jl")))

"""
    derived_extension_blind_triggers(rt, uri) -> Vector{String}

For an `ext/` file whose extension has NO covering environment (none of the
candidates covers the triggers and no resolved extension environment has
arrived), the extension's trigger names — the imports analysis is blind to.
Empty for every other file. The diagnostics join uses this to convert
`:unresolved_import` findings for these names into `:analysis_boundary`
notices (silent by default).
"""
Salsa.@derived function derived_extension_blind_triggers(rt, uri)
    ext = derived_extension_for_file(rt, uri)
    ext === nothing && return String[]
    project_uri = derived_extension_project_uri(rt, ext.package_folder, ext.ext_name)
    project_uri === nothing && return sort(ext.triggers)
    # A resolved extension environment whose child could not install every
    # trigger (a resolver or download failure degrades to whatever it got) is
    # still the best environment for the file — but the triggers its manifest
    # lacks are blind, not unresolved imports.
    project = derived_project(rt, project_uri)
    project === nothing && return String[]   # no readable manifest: trust the environment
    return sort(filter(t -> !_project_covers_triggers(project, (t,)), ext.triggers))
end
