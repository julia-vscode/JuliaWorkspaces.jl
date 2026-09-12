# The v2 environment selection, behind `input_v2_enabled`: the twins of
# `derived_project_uri_for_root`, `_test_environment_key`,
# `derived_file_env_ready` and `derived_required_dynamic_projects`
# (layer_environment.jl gates to them), plus the helpers only they and the
# v2 stack use. Over the v1 selection: extension files resolve to an
# environment holding their weakdep triggers (layer_extensions_v2.jl), a
# deeper non-package env folder wins over the merged test env, a `test/`
# that is a workspace member is its own test environment, package scripts
# (`perf/`, `benchmark/`, `examples/`) run against the active project, a
# deved package's tests materialize in the deving project, synthesized
# workspace members gate on the root's watch item, and extension-environment
# work items are scheduled. `derived_file_env_failed`,
# `derived_stdlib_names` and `derived_file_stdlibs_visible` feed the v2
# diagnostics join and lint producers only.

Salsa.@derived function derived_project_uri_for_root_v2(rt, uri)
    @debug "derived_project_uri_for_root_v2" uri=uri

    active_project = input_active_project(rt)

    package_folder_uri = derived_package_for_file(rt, uri)

    # Files that belong to a package's test suite prefer the merged test
    # environment: it holds the package's own deps, the `[extras]`/test-target
    # deps (or test/Project.toml when present), and the package itself — which
    # a resolved copy of a bare test/Project.toml need not contain.
    # An extension file gets an environment containing its weakdep triggers:
    # an existing covering project or the resolved extension environment. When
    # neither exists (yet), fall through to the package logic below —
    # `derived_file_env_ready_v2` gates while the ext-env item can still arrive,
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
    # package logic — `derived_file_env_ready_v2` suppresses env-dependent
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

            test_env_key = _test_environment_key_v2(rt, package_folder_uri, pkg)
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
    _test_member_project_folder(rt, package_folder_uri) -> Union{Nothing,URI}

The package's `test/` folder when it is a synthesized `[workspace]` member —
the folder whose project then IS the test environment (test deps and the
package itself resolve through the root's shared manifest, no merged test-env
work item needed) — or `nothing` for every other test-folder shape.

Single source of truth for this shape: the required set (which skips the
test-env item for it), `derived_project_uri_for_root_v2` (which routes test
files to it) and `derived_file_env_ready_v2` must agree, or test files gate on
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
    _test_environment_key_v2(rt, package_folder_uri, pkg) -> Union{Nothing,WatchTestEnvironmentKey}

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
function _test_environment_key_v2(rt, package_folder_uri, pkg)
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

Salsa.@derived function derived_stdlib_names(rt)
    # `readdir(Sys.STDLIB)` rather than `Pkg.Types.stdlibs()`: the same
    # names, without JIT-compiling Pkg's registry machinery inside the lint
    # process.
    names = Set{String}()
    try
        for entry in readdir(Sys.STDLIB)
            isdir(joinpath(Sys.STDLIB, entry)) && push!(names, entry)
        end
    catch err
        err isa InterruptException && rethrow()
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

    project_uri = derived_project_uri_for_root_v2(rt, uri)
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
        test_env_key = _test_environment_key_v2(rt, package_folder_uri, pkg)
        test_env_key !== nothing && derived_ready_test_environment(rt, test_env_key) === nothing &&
            test_env_key in failed && return true
    end
    return CreateStandaloneProjectKey(package_path, pkg.content_hash) in failed
end

"""
    derived_file_env_ready_v2(rt, uri)

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
Salsa.@derived function derived_file_env_ready_v2(rt, uri)
    input_env_ready(rt) && return true

    # Determine the file's effective project URI and require its env to be
    # settled. For a synthesized workspace member the watch item lives at the
    # root — gate on that (`_watch_target_for_project` is the single source of
    # truth for the translation).
    project_uri = derived_project_uri_for_root_v2(rt, uri)
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

    test_env_key = _test_environment_key_v2(rt, package_folder_uri, pkg)
    test_env_key === nothing && return true

    derived_ready_test_environment(rt, test_env_key) === nothing || return true
    # No test project yet: only gate while one can still arrive.
    return !derived_test_environment_pending(rt, test_env_key)
end

Salsa.@derived function derived_required_dynamic_projects_v2(rt)
    @debug "derived_required_dynamic_projects_v2"

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

        test_env_key = _test_environment_key_v2(rt, package_uri, pkg)
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
