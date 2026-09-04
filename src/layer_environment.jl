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
    _watch_target_for_project(rt, project_uri) -> (uri, content_hash)

The `(project_uri, content_hash)` pair whose `WatchEnvironmentKey` covers the
environment of `project_uri`: the project's own folder normally, the workspace
root's folder and hash for a synthesized member project (a member has no watch
item of its own — the root's covers it, and its hash folds every member's
Project.toml).

Single source of truth for that identity: the required set (which schedules
the item via the root's `derived_project`), the readiness gates and every
other consumer must derive the same pair, or a recorded result is looked up
under a key nobody ever produced.
"""
function _watch_target_for_project(rt, project_uri)
    project = derived_project(rt, project_uri)
    project === nothing && return (project_uri, UInt64(0))
    if _is_synthesized_member(project, project_uri)
        root_uri = filepath2uri(dirname(uri2filepath(project.manifest_file_uri)))
        root_project = derived_project(rt, root_uri)
        root_project === nothing || return (root_uri, root_project.content_hash)
    end
    return (project_uri, project.content_hash)
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
    # An extension file gets an environment containing its weakdep triggers:
    # an existing covering project or the resolved extension environment. When
    # neither exists (yet), fall through to the package logic below —
    # `derived_file_env_ready` gates while the ext-env item can still arrive,
    # and terminally missing triggers become an analysis boundary.
    ext = derived_extension_for_file(rt, uri)
    if ext !== nothing
        ext_project_uri = derived_extension_project_uri(rt, ext.package_folder, ext.ext_name)
        ext_project_uri !== nothing && return ext_project_uri
    end

    # A non-package env folder (Project.toml, no manifest, no name/uuid) that is
    # deeper than any enclosing project/package folder owns its files once its
    # resolved scratch copy is ready — even under `test/` (`test/qa/Project.toml`
    # is the environment those files are run with, not the merged test env).
    # The package's `test/` folder itself is the exception: its merged test
    # env also devs the package, so that keeps precedence (handled below).
    # While resolution is still pending, fall through to the test-env and
    # package logic — `derived_file_env_ready` suppresses env-dependent
    # diagnostics for these files in the meantime.
    env_folder_uri = _deepest_nonpackage_env_for_file(rt, uri)
    if env_folder_uri !== nothing && _covering_test_env_key(rt, env_folder_uri) === nothing
        env = derived_nonpackage_env(rt, env_folder_uri)
        if env !== nothing
            resolved = derived_ready_resolved_environment(rt, env_folder_uri, env.content_hash)
            resolved !== nothing && return resolved
        end
    end

    if package_folder_uri !== nothing
        pkg = derived_package(rt, package_folder_uri)
        if pkg !== nothing && _file_needs_test_env(rt, uri2filepath(package_folder_uri), uri)
            # When `test/` is a workspace member its own (synthesized) project
            # IS the test environment — available immediately, no DJP result
            # to wait for. This must run before the merged-test-env branch: no
            # test-env item is scheduled for this shape, so waiting on one
            # would fall through to the package's main env and flash
            # missing-reference false positives for test-only deps.
            test_member = _test_member_project_folder(rt, package_folder_uri)
            test_member !== nothing && return test_member

            test_env_key = _test_environment_key(rt, package_folder_uri, pkg)
            if test_env_key !== nothing
                test_project_uri = derived_ready_test_environment(rt, test_env_key)
                test_project_uri !== nothing && return test_project_uri
            end
        end
    end

    # The package's own `test/` env folder (covered by the test-env item):
    # its resolved copy is the fallback once the test-env item has failed.
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

    # A file inside a package folder that is neither package code (`src/`,
    # `ext/`, `deps/`) nor a test file — `perf/`, `benchmark/`, `examples/`,
    # `docs/` without a Project.toml — is a script with no environment of its
    # own. Julia runs it with the default load path, so it is checked against
    # the active project (JW's fallback), exactly like a file outside any
    # package; stdlibs are visible to it regardless (`@stdlib` is always on
    # the default load path — see `derived_file_stdlibs_visible`).
    if package_folder_uri !== nothing && _is_package_script_file(rt, package_folder_uri, uri)
        return active_project
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
    _test_member_project_folder(rt, package_folder_uri) -> Union{Nothing,URI}

The package's `test/` folder when it is a synthesized `[workspace]` member —
the folder whose project then IS the test environment (test deps and the
package itself resolve through the root's shared manifest, no merged test-env
work item needed) — or `nothing` for every other test-folder shape.

Single source of truth for this shape: the required set (which skips the
test-env item for it), `derived_project_uri_for_root` (which routes test
files to it) and `derived_file_env_ready` must agree, or test files gate on
an item nobody schedules.
"""
function _test_member_project_folder(rt, package_folder_uri)
    test_folder_uri = filepath2uri(joinpath(uri2filepath(package_folder_uri), "test"))
    project = derived_project(rt, test_folder_uri)
    project === nothing && return nothing
    _is_synthesized_member(project, test_folder_uri) || return nothing
    return test_folder_uri
end

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
    project_for_test = if package_folder_uri in derived_project_folders(rt)
        package_folder_uri
    else
        # A package deved by a workspace project (a `lib/<Pkg>` of a monorepo
        # whose root manifest carries `path = "lib/<Pkg>"`) runs its tests in
        # that project: materialize the test environment there. The active
        # project is only the fallback for a package nothing devs.
        deving = derived_deving_project(rt, package_folder_uri)
        deving === nothing ? package_folder_uri : deving
    end
    project_for_test === nothing && return nothing

    project = derived_project(rt, project_for_test)
    return WatchTestEnvironmentKey(
        uri2filepath(project_for_test),
        pkg.name,
        project === nothing ? UInt64(0) : project.content_hash,
    )
end

# Package folders whose files are loaded as PACKAGE code (with the package's
# own environment): `src/` and `ext/` by Julia's loader, `deps/build.jl` by
# `Pkg.build` (which activates the package project).
const _PACKAGE_CODE_FOLDERS = ("src", "ext", "deps")

"""
    _is_package_script_file(rt, package_folder_uri, uri) -> Bool

Whether `uri`, which lies under the package folder, is a script rather than
package or test code: its first path segment below the package is none of
`src`/`ext`/`deps`, and it is not a test file (`_file_needs_test_env`).
"""
function _is_package_script_file(rt, package_folder_uri, uri)
    package_path = uri2filepath(package_folder_uri)
    file_path = uri2filepath(uri)
    (package_path === nothing || file_path === nothing) && return false
    parts = splitpath(file_path)
    depth = length(splitpath(package_path))
    length(parts) > depth + 1 || return false          # a file directly in the package folder
    lowercase(parts[depth + 1]) in _PACKAGE_CODE_FOLDERS && return false
    return !_file_needs_test_env(rt, package_path, uri)
end

"The names of the running Julia's standard libraries (`Pkg.Types.stdlibs()`)."
Salsa.@derived function derived_stdlib_names(rt)
    names = Set{String}()
    for (_, info) in Pkg.Types.stdlibs()
        push!(names, String(info isa Tuple ? info[1] : info.name))
    end
    return names
end

"""
    derived_file_stdlibs_visible(rt, uri) -> Bool

Whether a `using`/`import` of a standard library in this file resolves
regardless of the file's project: true for everything Julia runs with
`@stdlib` on the load path — scripts, files outside any package, and test
files (`Pkg.test` runs with `["@", "@stdlib"]`). False only for package code
(`src/`, `ext/`, `deps/`), which must declare its stdlib dependencies.
"""
Salsa.@derived function derived_file_stdlibs_visible(rt, uri)
    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing && return true
    package_path = uri2filepath(package_folder_uri)
    package_path === nothing && return true
    _file_needs_test_env(rt, package_path, uri) && return true
    return _is_package_script_file(rt, package_folder_uri, uri)
end

"""
    derived_file_env_failed(rt, uri) -> Bool

Whether the work item that would own this file's environment failed
terminally, so the environment the file is analyzed against is a fallback
(the enclosing package's, or none): the watch item of its effective project,
the extension-environment item of an `ext/` file, the resolve item of a
deeper non-package env folder, the test-environment item of a test file, or
the standalone-project item of a manifest-less package. Consumers treat
env-dependent findings in such a file as an analysis boundary rather than a
defect (the diagnostics join transforms `unresolved_import`).
"""
Salsa.@derived function derived_file_env_failed(rt, uri)
    failed = input_failed_dynamic_keys(rt)
    isempty(failed) && return false

    project_uri = derived_project_uri_for_root(rt, uri)
    if project_uri !== nothing
        watch_uri, watch_hash = _watch_target_for_project(rt, project_uri)
        watch_path = uri2filepath(watch_uri)
        watch_path !== nothing && WatchEnvironmentKey(watch_path, watch_hash) in failed && return true
    end

    ext = derived_extension_for_file(rt, uri)
    if ext !== nothing &&
            derived_extension_project_uri(rt, ext.package_folder, ext.ext_name) === nothing
        ext_pkg = derived_package(rt, ext.package_folder)
        ext_pkg !== nothing && _extension_environment_key(rt, ext.package_folder, ext_pkg) in failed &&
            return true
    end

    env_folder_uri = _deepest_nonpackage_env_for_file(rt, uri)
    if env_folder_uri !== nothing
        env = derived_nonpackage_env(rt, env_folder_uri)
        if env !== nothing &&
                derived_ready_resolved_environment(rt, env_folder_uri, env.content_hash) === nothing
            ResolveEnvironmentKey(uri2filepath(env_folder_uri), env.content_hash) in failed && return true
        end
    end

    package_folder_uri = derived_package_for_file(rt, uri)
    package_folder_uri === nothing && return false
    pkg = derived_package(rt, package_folder_uri)
    pkg === nothing && return false
    package_path = uri2filepath(package_folder_uri)
    if _file_needs_test_env(rt, package_path, uri)
        test_env_key = _test_environment_key(rt, package_folder_uri, pkg)
        test_env_key !== nothing && derived_ready_test_environment(rt, test_env_key) === nothing &&
            test_env_key in failed && return true
    end
    return CreateStandaloneProjectKey(package_path, pkg.content_hash) in failed
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
    # settled. For a synthesized workspace member the watch item lives at the
    # root — gate on that (`_watch_target_for_project` is the single source of
    # truth for the translation).
    project_uri = derived_project_uri_for_root(rt, uri)
    if project_uri !== nothing
        watch_uri, watch_hash = _watch_target_for_project(rt, project_uri)
        if !derived_project_environment_ready(rt, watch_uri, watch_hash) &&
                derived_project_requires_indexing(rt, watch_uri, watch_hash)
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

    # An extension file with no covering environment: gate while the
    # extension-environment work item can still arrive.
    ext = derived_extension_for_file(rt, uri)
    if ext !== nothing &&
            derived_extension_project_uri(rt, ext.package_folder, ext.ext_name) === nothing
        ext_pkg = derived_package(rt, ext.package_folder)
        if ext_pkg !== nothing
            ext_key = _extension_environment_key(rt, ext.package_folder, ext_pkg)
            derived_extension_environment_pending(rt, ext_key) && return false
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

    # Every project folder needs a :watch_environment DJP — except a
    # synthesized workspace member, whose environment the root's watch item
    # covers (this is where a workspace shrinks to a single DJP).
    for project_uri in derived_project_folders(rt)
        project = derived_project(rt, project_uri)
        project === nothing && continue
        _is_synthesized_member(project, project_uri) && continue
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

        # A `test/` that is a workspace member resolves against the root's
        # shared manifest — the root's watch item covers it, no merged
        # test-env item needed (`_test_member_project_folder` is the single
        # source of truth for this shape, shared with the env selection).
        _test_member_project_folder(rt, package_uri) === nothing || continue

        test_env_key = _test_environment_key(rt, package_uri, pkg)
        test_env_key === nothing && continue

        push!(required, test_env_key)
    end

    # Extension environments: a package declaring `[extensions]` whose entry
    # files are present needs one when NO existing manifest (its own, the
    # deving project's, the workspace root's, the test member's, the merged
    # test env's) resolves some extension's triggers — the borrowing fast path
    # in `derived_extension_project_uri` handles every covered shape without a
    # child.
    for package_uri in derived_package_folders(rt)
        pkg = derived_package(rt, package_uri)
        pkg === nothing && continue
        pf = derived_project_file(rt, pkg.project_file_uri)
        (pf === nothing || isempty(pf.extensions)) && continue

        package_folder = uri2filepath(package_uri)
        candidates = _extension_candidate_projects(rt, package_uri)
        needs_ext_env = any(pf.extensions) do (ext_name, triggers)
            _extension_entry_exists(rt, package_folder, ext_name) || return false
            return !any(candidates) do candidate
                project = derived_project(rt, candidate)
                project !== nothing && _project_covers_triggers(project, triggers)
            end
        end
        needs_ext_env || continue

        push!(required, _extension_environment_key(rt, package_uri, pkg))
    end

    return required
end
