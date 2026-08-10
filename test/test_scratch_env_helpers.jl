# Helpers for `test_scratch_env.jl`. Included from inside each `@testitem`,
# since test items run in isolated modules and cannot see each other's globals.
# Deliberately holds no `@testitem`, so it contributes no tests of its own.

# `scratch_env.jl` lives in the child project, which is not a dependency of the
# test environment, so it has to be loaded at runtime into a throwaway module.
# It only needs `Pkg`.
const _SCRATCH_ENV_MODULE = Ref{Module}()

function _scratch_env_module()
    isassigned(_SCRATCH_ENV_MODULE) && return _SCRATCH_ENV_MODULE[]
    path = normpath(
        joinpath(
            @__DIR__, "..", "juliadynamicanalysisprocess",
            "JuliaDynamicAnalysisProcess", "src", "scratch_env.jl"
        )
    )
    mod = Module(:ScratchEnvUnderTest)
    Core.eval(mod, :(import Pkg))
    Base.include(mod, path)
    return _SCRATCH_ENV_MODULE[] = mod
end

# A test item body is a single top-level scope, so anything defined by the
# runtime `include` above lands in a newer world age than the code calling it.
# Hence `invokelatest` on every crossing.
materialize_scratch_env(project_path, package_name) =
    Base.invokelatest(_scratch_env_module().materialize_scratch_env, project_path, package_name)

materialize_stdlib_test_env(project_path, package_name) =
    Base.invokelatest(_scratch_env_module().materialize_stdlib_test_env, project_path, package_name)

needs_stdlib_test_env(project_path, package_name) =
    Base.invokelatest(_scratch_env_module().needs_stdlib_test_env, project_path, package_name)

write_resolved_env_project(env_path, project_dir) =
    Base.invokelatest(_scratch_env_module().write_resolved_env_project, env_path, project_dir)

# Same story for the vendored TestEnv.
function activate_test_env(package_name)
    mod = Module(:TestEnvUnderTest)
    Base.include(mod, normpath(joinpath(@__DIR__, "..", "packages", "TestEnv", "src", "TestEnv.jl")))
    return Base.invokelatest(mod.TestEnv.activate, package_name)
end

# Every file under `dir`, keyed by relative path, for before/after comparison.
_snapshot(dir) = Dict(
    relpath(joinpath(root, f), dir) => read(joinpath(root, f))
    for (root, _, files) in walkdir(dir) for f in files
)

function _write_package(dir, name, uuid; manifest = nothing)
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    write(
        joinpath(dir, "Project.toml"), """
        name = "$name"
        uuid = "$uuid"
        version = "0.1.0"

        [deps]
        Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """
    )
    write(joinpath(dir, "src", "$name.jl"), "module $name\nusing Dates\nend\n")
    write(joinpath(dir, "test", "runtests.jl"), "using $name, Test\n@test true\n")
    manifest === nothing || write(joinpath(dir, "Manifest.toml"), manifest)
    return dir
end
