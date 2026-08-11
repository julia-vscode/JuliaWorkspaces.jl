# Per-module extended-method contributions, cached by store `objectid`. A
# store's contents are immutable once loaded, so its contributions never
# change. Stdlib stores are const, but PACKAGE stores are re-created on
# re-index — so the cache holds only a `WeakRef` to each store (keyed by
# `objectid`, a value that does not pin the store): once a re-created/dropped
# store is otherwise unreferenced, its entry — and the whole symbol table it
# would have pinned — can be collected. The `=== m` guard rejects a stale
# entry should an `objectid` be reused after collection. Dead entries are
# swept opportunistically so the map can't grow without bound across
# re-indexes.
const _EXTENDS_CACHE = Dict{UInt,Tuple{WeakRef,Vector{Pair{SymbolServer.VarRef,SymbolServer.VarRef}}}}()
const _EXTENDS_CACHE_LOCK = ReentrantLock()
const _EXTENDS_CACHE_SWEEP_AT = 512

function _module_extends_contributions(m::SymbolServer.ModuleStore)
    oid = objectid(m)
    @lock _EXTENDS_CACHE_LOCK begin
        hit = get(_EXTENDS_CACHE, oid, nothing)
        hit !== nothing && hit[1].value === m && return hit[2]
    end
    tmp = Dict{SymbolServer.VarRef,Vector{SymbolServer.VarRef}}()
    SymbolServer.collect_extended_methods(m, tmp, m.name)
    # collect_extended_methods seeds each vector with `extends.parent`; keep
    # only the per-module contributions so they can be merged per environment
    contribs = Pair{SymbolServer.VarRef,SymbolServer.VarRef}[]
    for (ext, vec) in tmp
        for mn in @view vec[2:end]
            push!(contribs, ext => mn)
        end
    end
    @lock _EXTENDS_CACHE_LOCK begin
        if length(_EXTENDS_CACHE) >= _EXTENDS_CACHE_SWEEP_AT
            filter!(kv -> kv.second[1].value !== nothing, _EXTENDS_CACHE)
        end
        _EXTENDS_CACHE[oid] = (WeakRef(m), contribs)
    end
    return contribs
end

# Equivalent to `SymbolServer.collect_extended_methods(store)`, but assembled
# from the per-module cache so shared module stores are only ever walked once.
function _collect_extended_methods_shared(store)
    extendeds = Dict{SymbolServer.VarRef,Vector{SymbolServer.VarRef}}()
    for (_, m) in store
        for (ext, mn) in _module_extends_contributions(m)
            push!(get!(() -> SymbolServer.VarRef[ext.parent], extendeds, ext), mn)
        end
    end
    return extendeds
end

function _stdlib_only_env()
    # Shallow copy: the entries alias the immutable baked stdlib stores.
    # Nothing mutates store contents after construction (scopes and other
    # environments already alias these instances).
    new_store = copy(SymbolServer.stdlibs)
    return StaticLint.ExternalEnv(new_store, _collect_extended_methods_shared(new_store), collect(keys(new_store)))
end

# ─── Per-key readiness wrappers ──────────────────────────────────────────────
#
# These memoized derived functions expose the per-key readiness state held in
# the `input_ready_*` collection inputs. Reading the collection directly from a
# gate would make *every* readiness query depend on the single collection
# input, so any update would invalidate all of them. By funnelling each key
# through its own derived function, Salsa's early-cutoff means a collection
# update only invalidates downstream queries whose specific key's result
# actually changed — restoring fine-grained invalidation.

"""
    derived_project_environment_ready(rt, project_uri, content_hash) -> Bool

Whether the environment for `project_uri` (at `content_hash`) has been indexed.
"""
Salsa.@derived function derived_project_environment_ready(rt, project_uri, content_hash::UInt64)
    key = WatchEnvironmentKey(uri2filepath(project_uri), content_hash)
    return key in input_ready_project_environments(rt)
end

"""
    derived_project_requires_indexing(rt, project_uri, content_hash) -> Bool

Whether a dynamic process is scheduled to index `project_uri` (at
`content_hash`). A project no work item covers — e.g. one without a manifest —
can never become "ready", so readiness gates must not wait for it.

Its own derived function so per-file gates depend on this per-project `Bool`
instead of on the workspace-wide required set: when an unrelated workspace
change recomputes the set, this key's answer usually does not change and
Salsa's early cutoff stops the invalidation here.
"""
Salsa.@derived function derived_project_requires_indexing(rt, project_uri, content_hash::UInt64)
    key = WatchEnvironmentKey(uri2filepath(project_uri), content_hash)
    return key in derived_required_dynamic_projects(rt)
end

"""
    derived_test_environment_pending(rt, key::WatchTestEnvironmentKey) -> Bool

Whether the test-environment work item `key` is scheduled and can still produce
a result. False when none is scheduled and false once the item failed
terminally — waiting for either would gate forever.
"""
Salsa.@derived function derived_test_environment_pending(rt, key::WatchTestEnvironmentKey)
    key in input_failed_dynamic_keys(rt) && return false
    return key in derived_required_dynamic_projects(rt)
end

"""
    derived_ready_test_environment(rt, key::WatchTestEnvironmentKey) -> Union{Nothing,URI}

The ready test-project URI recorded for the test-environment work item `key`, or
`nothing` if that environment has not been indexed yet.
"""
Salsa.@derived function derived_ready_test_environment(rt, key::WatchTestEnvironmentKey)
    return get(input_ready_test_environments(rt), key, nothing)
end

"""
    derived_ready_standalone_project(rt, package_folder_uri, content_hash) -> Union{Nothing,URI}

The created standalone-project URI for `package_folder_uri`, or `nothing` if it
has not been created yet.
"""
Salsa.@derived function derived_ready_standalone_project(rt, package_folder_uri, content_hash::UInt64)
    key = CreateStandaloneProjectKey(uri2filepath(package_folder_uri), content_hash)
    return get(input_standalone_projects(rt), key, nothing)
end

"""
    derived_ready_resolved_environment(rt, env_folder_uri, content_hash) -> Union{Nothing,URI}

The resolved scratch-project URI for the manifest-less non-package environment
at `env_folder_uri`, or `nothing` if it has not been resolved yet.
"""
Salsa.@derived function derived_ready_resolved_environment(rt, env_folder_uri, content_hash::UInt64)
    key = ResolveEnvironmentKey(uri2filepath(env_folder_uri), content_hash)
    return get(input_resolved_environments(rt), key, nothing)
end

"""
    derived_resolve_environment_pending(rt, key::ResolveEnvironmentKey) -> Bool

Whether the environment-resolution work item `key` is scheduled and can still
produce a result. False when none is scheduled and false once the item failed
terminally — waiting for either would gate forever.
"""
Salsa.@derived function derived_resolve_environment_pending(rt, key::ResolveEnvironmentKey)
    key in input_failed_dynamic_keys(rt) && return false
    return key in derived_required_dynamic_projects(rt)
end

# Salsa-memoized stdlib-only env. Sharing a single env instance is required
# because `SymbolServer` stores compare by identity: refs resolved against this
# env during the semantic pass must point at the same instance that later
# read-only queries (hover, completions, tests) retrieve.
Salsa.@derived function derived_stdlib_only_env(rt)
    @debug "derived_stdlib_only_env"
    return _stdlib_only_env()
end

Salsa.@derived function derived_environment(rt, uri)
    @debug "derived_environment" uri=uri

    project = derived_project(rt, uri)

    if project === nothing
        # Reuse the memoized instance instead of building a fresh env per key.
        return derived_stdlib_only_env(rt)
    end

    metadata_packages = SymbolServer.Package[]
    for (k,v) in project.regular_packages
        x = input_package_metadata(rt, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1)
        if x!==nothing
            push!(metadata_packages, x)
        end
    end

    for (k,v) in project.stdlib_packages
        v.version === nothing && continue
        x = input_package_metadata(rt, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), nothing)
        if x!==nothing
            push!(metadata_packages, x)
        end
    end

    # Shallow copy: stdlib entries alias the shared baked stores, package
    # entries alias the memoized metadata inputs (which were always shared
    # across environments). Only the top-level Dict is per-project.
    new_store = copy(SymbolServer.stdlibs)

    for i in metadata_packages
        new_store[Symbol(i.name)] = i.val
    end

    project_deps = collect(keys(new_store))

    # Add in-workspace deved packages to project_deps so import resolution considers them valid
    for (k,v) in project.deved_packages
        entry_uri = filepath2uri(joinpath(uri2filepath(v.uri), "src", "$(v.name).jl"))
        if derived_has_file(rt, entry_uri)
            push!(project_deps, Symbol(v.name))
        end
    end

    return StaticLint.ExternalEnv(new_store, _collect_extended_methods_shared(new_store), project_deps)
end

Salsa.@derived function derived_workspace_deved_packages(rt, project_uri)
    @debug "derived_workspace_deved_packages" project_uri=project_uri

    project = derived_project(rt, project_uri)
    project === nothing && return Dict{String, URI}()

    result = Dict{String, URI}()
    for (k, v) in project.deved_packages
        entry_uri = filepath2uri(joinpath(uri2filepath(v.uri), "src", "$(v.name).jl"))
        if derived_has_file(rt, entry_uri)
            result[v.name] = entry_uri
        end
    end
    return result
end

"""
    _deepest_nonpackage_env_for_file(rt, uri) -> Union{Nothing,URI}

The non-package, manifest-less env folder enclosing `uri`, but only when it is
strictly deeper than both the enclosing project folder and the enclosing
package folder — i.e. when it would win the deepest-folder-wins selection.
Strict `>` is exact because the three folder classes are disjoint. Shared by
`derived_project_uri_for_root` and the readiness gate in
`derived_file_env_ready` so they agree on which files an env resolution is for.
"""
Salsa.@derived function _deepest_nonpackage_env_for_file(rt, uri)
    env_folder_uri = derived_nonpackage_env_for_file(rt, uri)
    env_folder_uri === nothing && return nothing

    env_len = length(uri2filepath(env_folder_uri))

    project_folder_uri = derived_project_for_file(rt, uri)
    project_folder_uri === nothing || env_len > length(uri2filepath(project_folder_uri)) || return nothing

    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing || env_len > length(uri2filepath(package_folder_uri)) || return nothing

    return env_folder_uri
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)
    @debug "derived_project_uri_for_root" uri=uri

    active_project = input_active_project(rt)

    package_folder_uri = derived_package_for_file(rt, uri)

    # Files that belong to a package's test suite prefer the merged test
    # environment: it holds the package's own deps, the `[extras]`/test-target
    # deps (or test/Project.toml when present), and the package itself — which
    # a resolved copy of a bare test/Project.toml need not contain.
    if package_folder_uri !== nothing
        pkg = derived_package(rt, package_folder_uri)
        if pkg !== nothing && _file_needs_test_env(rt, uri2filepath(package_folder_uri), uri)
            test_env_key = _test_environment_key(rt, package_folder_uri, pkg)
            if test_env_key !== nothing
                test_project_uri = derived_ready_test_environment(rt, test_env_key)
                test_project_uri !== nothing && return test_project_uri
            end
        end
    end

    # A non-package env folder (Project.toml, no manifest, no name/uuid) that is
    # deeper than any enclosing project/package folder owns its files once its
    # resolved scratch copy is ready. While resolution is still pending, fall
    # through to the enclosing package/project logic — `derived_file_env_ready`
    # suppresses env-dependent diagnostics for these files in the meantime.
    env_folder_uri = _deepest_nonpackage_env_for_file(rt, uri)
    if env_folder_uri !== nothing
        env = derived_nonpackage_env(rt, env_folder_uri)
        if env !== nothing
            resolved = derived_ready_resolved_environment(rt, env_folder_uri, env.content_hash)
            resolved !== nothing && return resolved
        end
    end

    # Check if the file is inside a project folder (has both Project.toml and Manifest.toml).
    # If this project folder is more specific (deeper) than the enclosing package folder,
    # use it directly. This handles cases like benchmark/ sub-projects that aren't packages
    # but define their own environment.
    project_folder_uri = derived_project_for_file(rt, uri)

    if project_folder_uri !== nothing
        project_is_more_specific = package_folder_uri === nothing ||
            length(uri2filepath(project_folder_uri)) > length(uri2filepath(package_folder_uri))
        if project_is_more_specific
            return project_folder_uri
        end
    end

    if package_folder_uri!==nothing
        pkg = derived_package(rt, package_folder_uri)
        pkg_content_hash = pkg === nothing ? UInt64(0) : pkg.content_hash

        # If the file belongs to a workspace package, use the package's own project
        if package_folder_uri in derived_project_folders(rt)
            return package_folder_uri
        end

        # If the package is not a project (no manifest) and not dev'd into any workspace project,
        # trigger creation of a standalone project for it
        deving_project = derived_deving_project(rt, package_folder_uri)
        if deving_project === nothing
            standalone_uri = derived_ready_standalone_project(rt, package_folder_uri, pkg_content_hash)
            if standalone_uri !== nothing
                return standalone_uri
            end
        else
            # Package IS deved in a workspace project (possibly the standalone project
            # that was created for it) — use that project
            return deving_project
        end
    end

    # TODO This needs to handle multi env
    return active_project
end

"""
    derived_deving_project(rt, package_folder_uri) -> Union{Nothing,URI}

The workspace project that `dev`s the package at `package_folder_uri`, or
`nothing` if no project does.

Memoized because the scan touches *every* project in the workspace: called
inline, each caller (one per file, via `derived_project_uri_for_root`) would
take a dependency on all of them, so the number of edges the incremental engine
walks would grow as files × projects.
"""
Salsa.@derived function derived_deving_project(rt, package_folder_uri)
    for project_folder_uri in derived_project_folders(rt)
        project = derived_project(rt, project_folder_uri)
        project === nothing && continue
        for (_, v) in project.deved_packages
            if v.uri == package_folder_uri
                return project_folder_uri
            end
        end
    end
    return nothing
end

_is_package_deved_in_workspace(rt, package_folder_uri) =
    derived_deving_project(rt, package_folder_uri) !== nothing

"""
    _test_environment_key(rt, package_folder_uri, pkg) -> Union{Nothing,WatchTestEnvironmentKey}

The identity of the test-environment work item for the package `pkg` at
`package_folder_uri`, or `nothing` if no project can provide that environment.

Single source of truth for that identity: the required set (which schedules the
item), the result recorder and every readiness query must derive the same key, or
a recorded result is looked up under a key nobody ever produced.

The environment comes from the package's own folder when the package is a project
itself, and likewise when no workspace project `dev`s it (a standalone project is
fabricated for it under that same folder). Only for a deved package does the
active project provide it.
"""
function _test_environment_key(rt, package_folder_uri, pkg)
    project_for_test = if package_folder_uri in derived_project_folders(rt) ||
            !_is_package_deved_in_workspace(rt, package_folder_uri)
        package_folder_uri
    else
        input_active_project(rt)
    end
    project_for_test === nothing && return nothing

    project = derived_project(rt, project_for_test)
    return WatchTestEnvironmentKey(
        uri2filepath(project_for_test),
        pkg.name,
        project === nothing ? UInt64(0) : project.content_hash,
    )
end

"""
    derived_file_env_ready(rt, uri)

Return true if this file's effective environment is ready for static-lint
analysis that depends on environment data (e.g. missing-reference checks).

Per-project gating: each file's *own* project must be settled — either its
environment finished indexing (or failed, which is terminal too), or no work
item is scheduled for it at all, in which case there is nothing to wait for.

Files that need a test environment (anything under the package's `test/`
folder, or files with `@testitem`) additionally require the test-env work item to have produced a
merged test project URI, unless that item is not scheduled or failed
terminally. Otherwise missing-ref diagnostics for test-only deps
(TestItemRunner, Test, @testitem, @test, …) would flash as false positives
until indexing finishes.

The global `input_env_ready` flag is honored as a manual override for tests: it
pretends every environment is ready.
"""
Salsa.@derived function derived_file_env_ready(rt, uri)
    input_env_ready(rt) && return true

    # Determine the file's effective project URI and require its env to be
    # settled.
    project_uri = derived_project_uri_for_root(rt, uri)
    if project_uri !== nothing
        project = derived_project(rt, project_uri)
        project_hash = project === nothing ? UInt64(0) : project.content_hash
        if !derived_project_environment_ready(rt, project_uri, project_hash) &&
                derived_project_requires_indexing(rt, project_uri, project_hash)
            return false
        end
    end

    # A manifest-less non-package env that would own this file once resolved:
    # gate while the resolution can still arrive, so missing-ref checks don't
    # flash false positives against the fallback (outer package / active
    # project) environment.
    env_folder_uri = _deepest_nonpackage_env_for_file(rt, uri)
    if env_folder_uri !== nothing
        env = derived_nonpackage_env(rt, env_folder_uri)
        if env !== nothing &&
                derived_ready_resolved_environment(rt, env_folder_uri, env.content_hash) === nothing
            key = ResolveEnvironmentKey(uri2filepath(env_folder_uri), env.content_hash)
            derived_resolve_environment_pending(rt, key) && return false
        end
    end

    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing && return true

    pkg = derived_package(rt, package_folder_uri)
    pkg === nothing && return true

    _file_needs_test_env(rt, uri2filepath(package_folder_uri), uri) || return true

    test_env_key = _test_environment_key(rt, package_folder_uri, pkg)
    test_env_key === nothing && return true

    derived_ready_test_environment(rt, test_env_key) === nothing || return true
    # No test project yet: only gate while one can still arrive.
    return !derived_test_environment_pending(rt, test_env_key)
end

"""
    _file_needs_test_env(rt, package_folder, uri)

Whether a root should be analyzed against the package's merged test
environment: any file under `<package_folder>/test/`, or a file containing
`@testitem`s. Test-only dependencies declared via `[extras]`+`[targets]` are
visible only in that environment, and helper files under `test/` routinely
become their own roots (computed `include` paths in `runtests.jl`), so the
whole folder gets the test environment — not just `test/runtests.jl`.

Must stay in agreement with the gating in `derived_file_env_ready`.
"""
function _file_needs_test_env(rt, package_folder::AbstractString, uri)
    # TODO Is this lowercase the right move? On Windows for sure, not clear about other platforms
    test_dir = lowercase(joinpath(package_folder, "test")) * Base.Filesystem.path_separator
    return startswith(lowercase(uri2filepath(uri)), test_dir) || _file_has_testitems(rt, uri)
end

"""
    _file_has_testitems(rt, uri)

Check whether a file contains `@testitem` macros by looking at the
already-computed test item detection results (which use JuliaSyntax, not CSTParser).
"""
function _file_has_testitems(rt, uri)
    try
        details = derived_testitems(rt, uri)
        return !isempty(details.testitems)
    catch
        return false
    end
end

"""
    _covering_test_env_key(rt, env_uri) -> Union{Nothing,WatchTestEnvironmentKey}

The test-environment work item that already covers the non-package env folder
at `env_uri`, i.e. the key of the enclosing package's test env when `env_uri`
is that package's `test/` folder and a `test/runtests.jl` exists. `nothing`
when no test-env item covers the folder.
"""
function _covering_test_env_key(rt, env_uri)
    env_path = uri2filepath(env_uri)
    lowercase(basename(env_path)) == "test" || return nothing

    package_path = dirname(env_path)
    package_uri = filepath2uri(package_path)
    package_uri in derived_package_folders(rt) || return nothing
    isfile(joinpath(env_path, "runtests.jl")) || return nothing

    pkg = derived_package(rt, package_uri)
    pkg === nothing && return nothing

    return _test_environment_key(rt, package_uri, pkg)
end

Salsa.@derived function derived_required_dynamic_projects(rt)
    @debug "derived_required_dynamic_projects"

    required = Set{DJPKey}()

    # Every project folder needs a :watch_environment DJP
    for project_uri in derived_project_folders(rt)
        project = derived_project(rt, project_uri)
        project === nothing && continue
        push!(required, WatchEnvironmentKey(
            uri2filepath(project_uri),
            project.content_hash,
        ))
    end

    # Standalone projects and test environments are fabricated only when
    # workspace-environment resolution is enabled.
    input_resolve_workspace_environments(rt) || return required

    # Package folders that aren't project folders and aren't deved need a standalone project DJP
    for package_uri in derived_package_folders(rt)
        package_uri in derived_project_folders(rt) && continue
        _is_package_deved_in_workspace(rt, package_uri) && continue

        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue
        push!(required, CreateStandaloneProjectKey(
            uri2filepath(package_uri),
            pkg.content_hash,
        ))
    end

    # Non-package Project.tomls without a manifest need a resolved scratch project
    for env_uri in derived_nonpackage_env_folders(rt)
        env = derived_nonpackage_env(rt, env_uri)
        env === nothing && continue

        # A `<pkg>/test` folder is already covered by the package's test-env
        # work item, which honors test/Project.toml and additionally devs the
        # package itself. Resolving it separately would duplicate the Pkg work
        # and, on failure, the environment_errors diagnostics. Schedule the
        # resolve item only as a fallback once the test-env item has failed
        # terminally.
        covering_key = _covering_test_env_key(rt, env_uri)
        if covering_key !== nothing && !(covering_key in input_failed_dynamic_keys(rt))
            continue
        end

        push!(required, ResolveEnvironmentKey(
            uri2filepath(env_uri),
            env.content_hash,
        ))
    end

    # Test environments: for each package folder with a test/runtests.jl, the test env DJP
    for package_uri in derived_package_folders(rt)
        package_folder = uri2filepath(package_uri)
        runtests_path = joinpath(package_folder, "test", "runtests.jl")
        isfile(runtests_path) || continue

        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue

        test_env_key = _test_environment_key(rt, package_uri, pkg)
        test_env_key === nothing && continue

        push!(required, test_env_key)
    end

    return required
end
