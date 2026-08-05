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
