# Materializing a scratch environment
#
# `TestEnv.activate` calls `Pkg.instantiate` on whatever environment is active
# when it runs (`ctx_and_pkgspec` in the vendored TestEnv). For an environment
# with a `Project.toml` but no `Manifest.toml` that resolves and writes a
# manifest straight into that directory. Static analysis must never touch the
# user's working tree, and TestEnv is vendored from upstream so we cannot patch
# it — therefore we never make the user's environment the active one. Instead we
# build a throwaway *wrapper* environment that mirrors it and activate that.
#
# The wrapper is deliberately nameless (no `name`/`uuid`/`version`) and carries
# the package under test as an ordinary path-tracked dependency. That is not a
# stylistic choice: Pkg derives the package's source location from
# `dirname(env.project_file)` in two places —
#
#   * `Pkg.Operations.sandbox_preserve`, which injects the root entry with
#     `path = dirname(env.project_file)`, and
#   * TestEnv's `get_test_dir`, which sets `pkgspec.path = dirname(ctx.env.project_file)`
#     when the package *is* the active project.
#
# A verbatim copy of the package's own `Project.toml` would therefore point both
# of them at the scratch directory, which has no `src/` and no `test/`. Leaving
# the wrapper nameless routes both through the manifest entry instead, which we
# aim back at the real package folder.

"""
    CAN_MIRROR_ENV

Whether this Julia's `Pkg` exposes enough of its environment API for
[`materialize_scratch_env`](@ref) to work. False before Julia 1.2, where
`Pkg.Types.Project`/`Manifest` are plain `Dict`s and `Pkg.Operations.abspath!`
does not exist.

Callers must not fall back to activating the user's environment when this is
false — that is the very thing we are avoiding.
"""
const CAN_MIRROR_ENV =
    isdefined(Pkg.Types, :Project) &&
    isdefined(Pkg.Types, :Manifest) &&
    isdefined(Pkg.Operations, :abspath!)

# The absolute path of the package's source tree, as seen from `src_env`.
#
# `manifest` must already have been run through `abspath!`, so a deved entry's
# `path` is absolute by the time we read it.
function _package_source_path(src_env, manifest, package_name::String)
    # The common case: the environment *is* the package (with or without a manifest).
    if src_env.pkg !== nothing && src_env.pkg.name == package_name
        return dirname(src_env.project_file)
    end

    # Otherwise the package is deved into this environment — this is the shape
    # `_test_environment_key` produces when it routes a workspace package's test
    # env to the active project rather than to the package folder.
    uuid = get(src_env.project.deps, package_name, nothing)
    if uuid !== nothing
        entry = get(manifest, uuid, nothing)
        if entry !== nothing && entry.path !== nothing
            return entry.path
        end
    end

    error("Cannot locate the source of package $package_name in the environment at $(dirname(src_env.project_file)).")
end

# A manifest whose recorded project hash disagrees with the project makes
# `Pkg.instantiate` warn on every run. The wrapper's dep set differs from the
# source project's (it gained the package under test), so re-record it. Purely
# cosmetic, hence best-effort: `record_project_hash` is a Pkg internal.
function _record_project_hash!(env_dir::String)
    try
        env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(env_dir))
        Pkg.Operations.record_project_hash(env)
        Pkg.Types.write_manifest(env.manifest, env.manifest_file)
    catch err
        err isa InterruptException && rethrow()
        @debug "Could not record the project hash of the scratch environment" env_dir exception = (err, catch_backtrace())
    end
    return
end

"""
    materialize_scratch_env(project_path, package_name) -> String

Build a scratch environment mirroring the one at `project_path` and return its
directory. The environment at `project_path` is only ever read.

The result is safe to `Pkg.activate` before calling `TestEnv.activate(package_name)`:
every write TestEnv performs then lands in the scratch directory or in TestEnv's
own temporary directory, never in the user's folder.

When the source environment has a manifest it is copied over verbatim (with
relative paths made absolute), so the test environment resolves against exactly
the versions the user has pinned. When it does not, there is nothing to preserve
and TestEnv's `Pkg.instantiate` resolves one into the scratch directory.
"""
function materialize_scratch_env(project_path::String, package_name::String)
    src_env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(project_path))

    # `abspath!` rewrites deved `path` entries relative to the *source* manifest,
    # so it has to run before anything is written elsewhere. On a manifest-less
    # environment this is a no-op over an empty dict.
    manifest = Pkg.Operations.abspath!(src_env, deepcopy(src_env.manifest))
    package_path = _package_source_path(src_env, manifest, package_name)

    env_dir = mktempdir()

    project = deepcopy(src_env.project)

    @static if VERSION >= v"1.11"
        # `[sources]` paths are project-relative, so they need the same treatment
        # as the manifest's. Then pin the package under test to its real location.
        Pkg.Operations.abspath!(src_env, project)
        project.sources[package_name] = Dict("path" => package_path)
    end

    # The source project's own package becomes an ordinary dependency of the wrapper.
    if src_env.pkg !== nothing
        project.deps[src_env.pkg.name] = src_env.pkg.uuid
    end

    project.name = nothing
    project.uuid = nothing
    project.version = nothing

    # Meaningless in a nameless environment, and `[targets]`/`[extras]` in
    # particular would only invite confusion: TestEnv reads those from the real
    # package's `Project.toml` (via `gen_target_project`), not from here.
    empty!(project.extras)
    empty!(project.targets)

    # With `[extras]` gone, a `[sources]` entry for a test-only extra would
    # reference a package Pkg can no longer see, and `Pkg.Types.validate`
    # rejects the wrapper over it ("Sources for `X` not listed in `deps` or
    # `extras` section"). Keep only sources the wrapper still declares as deps —
    # validate's allowed set is deps ∪ non-weak extras, so weakdeps must NOT be
    # admitted here (unlike the compat prune below).
    @static if VERSION >= v"1.11"
        filter!(kv -> haskey(project.deps, first(kv)), project.sources)
    end

    # With `[extras]` gone, a `[compat]` entry for a test-only extra (allowed in
    # the source project) would reference a package Pkg can no longer see, and
    # Pkg rejects the whole wrapper project over it. Keep only compat entries
    # the wrapper can still account for.
    let allowed = Set{String}(keys(project.deps))
        push!(allowed, "julia")
        hasfield(Pkg.Types.Project, :weakdeps) && union!(allowed, keys(project.weakdeps))
        filter!(kv -> first(kv) in allowed, project.compat)
    end

    # `[workspace]` members are declared relative to the project file, so copying
    # the section over would send Pkg looking for them inside the scratch dir.
    # `[apps]` is simply meaningless without a name. Both sections postdate the
    # oldest Julia the analysis process runs on, hence the field guards.
    for section in (:workspace, :apps)
        hasfield(Pkg.Types.Project, section) && empty!(getfield(project, section))
    end

    Pkg.Types.write_project(project, joinpath(env_dir, "Project.toml"))

    if isfile(src_env.manifest_file)
        # Manifest format 2.0 already lists the root package with `path = "."`,
        # which `abspath!` has resolved for us. Older formats omit it, and a
        # dependency missing from the manifest is a hard error in
        # `Pkg.instantiate`, so fill it in either way.
        if src_env.pkg !== nothing
            entry = get(manifest, src_env.pkg.uuid, nothing)
            if entry === nothing
                entry = Pkg.Types.PackageEntry()
                manifest[src_env.pkg.uuid] = entry
            end
            entry.name = src_env.pkg.name
            entry.path = package_path
            entry.version === nothing && (entry.version = src_env.pkg.version)
            isempty(entry.deps) && (entry.deps = copy(src_env.project.deps))
        end

        Pkg.Types.write_manifest(manifest, joinpath(env_dir, "Manifest.toml"))
        _record_project_hash!(env_dir)
    end

    return env_dir
end

# The UUID of `package_name` as declared by the environment at `src_env` —
# either the environment's own package or one of its direct dependencies.
function _package_uuid(src_env, package_name::String)
    if src_env.pkg !== nothing && src_env.pkg.name == package_name
        return src_env.pkg.uuid
    end
    return get(src_env.project.deps, package_name, nothing)
end

"""
    needs_stdlib_test_env(project_path, package_name) -> Bool

Whether the test environment for `package_name` must be built by
[`materialize_stdlib_test_env`](@ref) instead of TestEnv. TestEnv's
`get_test_dir` mirrors `Pkg.test` and bails out on any stdlib UUID without
setting `pkgspec.path`, which crashes downstream (`pkgspec.path::String`) — so a
dev checkout of a stdlib (the julia repo's `stdlib/` folder, a `Pkg.develop`ed
stdlib) can never go through TestEnv. The replacement path pins the checkout via
`[sources]`, hence the 1.11 floor.
"""
function needs_stdlib_test_env(project_path::String, package_name::String)
    (CAN_MIRROR_ENV && VERSION >= v"1.11") || return false
    uuid = try
        src_env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(project_path))
        _package_uuid(src_env, package_name)
    catch err
        err isa InterruptException && rethrow()
        # A broken environment should fail in the main path, with its real error.
        return false
    end
    return uuid !== nothing && Pkg.Types.is_stdlib(uuid)
end

"""
    materialize_stdlib_test_env(project_path, package_name) -> String

Build a scratch test environment for a stdlib package checked out at (or deved
into) `project_path`, and return its directory. Replaces `TestEnv.activate` for
stdlib UUIDs (see [`needs_stdlib_test_env`](@ref)): the package itself is
path-pinned through `[sources]`, and its test dependencies come from
`test/Project.toml` when present, otherwise from the package's
`[extras]`/`[targets] test`. The caller is expected to `Pkg.activate` the result
and `Pkg.instantiate` it; nothing is ever written to the user's folder.
"""
function materialize_stdlib_test_env(project_path::String, package_name::String)
    src_env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(project_path))
    manifest = Pkg.Operations.abspath!(src_env, deepcopy(src_env.manifest))
    package_path = _package_source_path(src_env, manifest, package_name)
    package_uuid = _package_uuid(src_env, package_name)
    package_uuid === nothing &&
        error("Cannot determine the UUID of package $package_name in the environment at $(dirname(src_env.project_file)).")

    pkg_env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(package_path))
    pkg_project = deepcopy(pkg_env.project)
    # `[sources]` paths in the package's Project.toml are relative to the
    # package folder; rebase them before any entries are copied elsewhere.
    Pkg.Operations.abspath!(pkg_env, pkg_project)

    project = Pkg.Types.Project()
    project.deps[package_name] = package_uuid

    test_project_file = joinpath(package_path, "test", "Project.toml")
    if isfile(test_project_file)
        test_env = Pkg.Types.EnvCache(test_project_file)
        test_project = deepcopy(test_env.project)
        # `[sources]` paths in test/Project.toml are relative to the test folder.
        Pkg.Operations.abspath!(test_env, test_project)
        merge!(project.deps, test_project.deps)
        for (name, source) in test_project.sources
            name == package_name && continue
            project.sources[name] = source
        end
        for (name, compat) in test_project.compat
            haskey(project.deps, name) && (project.compat[name] = compat)
        end
    else
        for target in get(pkg_project.targets, "test", String[])
            uuid = get(pkg_project.extras, target, nothing)
            uuid === nothing && (uuid = get(pkg_project.deps, target, nothing))
            uuid === nothing && continue
            project.deps[target] = uuid
        end
        # A promoted test dep may be path-pinned through the package's own
        # `[sources]`; without carrying the (rebased) entry over, Pkg would go
        # looking for it in a registry.
        for (name, source) in pkg_project.sources
            name == package_name && continue
            haskey(project.deps, name) && (project.sources[name] = source)
        end
        for (name, compat) in pkg_project.compat
            name != "julia" && haskey(project.deps, name) && (project.compat[name] = compat)
        end
    end

    project.sources[package_name] = Dict("path" => package_path)

    env_dir = mktempdir()
    Pkg.Types.write_project(project, joinpath(env_dir, "Project.toml"))
    return env_dir
end

"""
    write_resolved_env_project(env_path, project_dir) -> Nothing

Copy the `Project.toml` of the manifest-less non-package environment at
`env_path` into `project_dir`, with relative `[sources]` paths rebased to
absolute and env-location-relative sections (`[workspace]`, `[apps]`) dropped.
The caller is expected to `Pkg.activate` the result and `Pkg.instantiate` it,
which resolves a manifest into `project_dir`; the environment at `env_path` is
only ever read.

Note: an environment that is a `[workspace]` member normally resolves against
the workspace root's manifest; the copy resolves standalone instead, which may
pick different versions. That is acceptable for symbol indexing.
"""
function write_resolved_env_project(env_path::String, project_dir::String)
    mkpath(project_dir)

    if !CAN_MIRROR_ENV
        # Pre-1.2 Pkg has no Project type; `[sources]`/`[workspace]`/`[apps]`
        # all postdate it, so a verbatim copy is exact. `projectfile_path` is
        # only assumed to exist behind CAN_MIRROR_ENV, so find the file by hand
        # (same JuliaProject-over-Project preference).
        for name in ("JuliaProject.toml", "Project.toml")
            candidate = joinpath(env_path, name)
            if isfile(candidate)
                cp(candidate, joinpath(project_dir, "Project.toml"); force=true)
                return
            end
        end
        error("No project file found in the environment at $env_path.")
    end

    src_env = Pkg.Types.EnvCache(Pkg.Types.projectfile_path(env_path))
    project = deepcopy(src_env.project)

    @static if VERSION >= v"1.11"
        # `[sources]` paths are relative to the environment's own folder.
        Pkg.Operations.abspath!(src_env, project)
    end

    # `[workspace]` members are declared relative to the project file, and
    # `[apps]` is meaningless in the scratch copy. Same treatment (and the same
    # field guards) as in `materialize_scratch_env`.
    for section in (:workspace, :apps)
        hasfield(Pkg.Types.Project, section) && empty!(getfield(project, section))
    end

    Pkg.Types.write_project(project, joinpath(project_dir, "Project.toml"))
    return
end
