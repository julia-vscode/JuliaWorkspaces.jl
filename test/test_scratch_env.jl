# The dynamic analysis process must never write into the folder it is analysing.
# `scratch_env.jl` is what keeps that promise: it lives in the child project
# rather than in `JuliaWorkspaces` itself, so these items load it directly.
#
# The end-to-end path (a real resolve through TestEnv) is covered by the
# `:integration` item at the bottom, which is opt-in because it needs a registry.
#
# Shared helpers live in `test_scratch_env_helpers.jl`.

@testitem "scratch env: a manifest-less package is mirrored, never written to" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    uuid = "aaaaaaaa-1111-2222-3333-444444444444"
    dir = _write_package(mktempdir(), "Bare", uuid)
    before = _snapshot(dir)

    env_dir = materialize_scratch_env(dir, "Bare")

    @test env_dir != dir
    # Nothing to preserve, so no manifest is fabricated here either — TestEnv's
    # own `Pkg.instantiate` resolves one into the scratch dir later.
    @test !isfile(joinpath(env_dir, "Manifest.toml"))

    project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

    # Nameless is the whole point: it stops Pkg deriving the package's source
    # location from `dirname(env.project_file)`, which would be the scratch dir.
    @test project.name === nothing
    @test project.uuid === nothing
    @test project.version === nothing

    @test project.deps["Bare"] == Base.UUID(uuid)
    @test haskey(project.deps, "Dates")
    @test isempty(project.extras)
    @test isempty(project.targets)

    @static if VERSION >= v"1.11"
        # `EnvCache` realpaths the project file, so the recorded path is the
        # resolved form — `/private/var/...` on macOS, the long profile name on
        # Windows — never the raw `mktempdir()` string.
        @test isabspath(project.sources["Bare"]["path"])
        @test realpath(project.sources["Bare"]["path"]) == realpath(dir)
    end

    @test _snapshot(dir) == before
end

@testitem "scratch env: an existing manifest is carried over with absolute paths" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    uuid = "aaaaaaaa-5555-6666-7777-888888888888"
    # Manifest format 2.0 records the root package as `path = "."`, which has to
    # end up pointing back at the real package folder.
    manifest = """
    manifest_format = "2.0"

    [[deps.Dates]]
    uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

    [[deps.Pinned]]
    deps = ["Dates"]
    path = "."
    uuid = "$uuid"
    version = "0.1.0"
    """
    dir = _write_package(mktempdir(), "Pinned", uuid; manifest)
    before = _snapshot(dir)

    env_dir = materialize_scratch_env(dir, "Pinned")

    written = Pkg.Types.read_manifest(joinpath(env_dir, "Manifest.toml"))
    entry = written[Base.UUID(uuid)]
    @test isabspath(entry.path)
    @test realpath(entry.path) == realpath(dir)
    @test entry.version == v"0.1.0"
    # The rest of the pinned graph survives, so the test env resolves against
    # exactly the versions the user has.
    @test haskey(written, Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"))

    @test _snapshot(dir) == before
end

@testitem "scratch env: a deved package resolves to its real source" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # `_test_environment_key` routes a deved package's test env to the project
    # that devs it, so the package under test is a dependency, not the project.
    root = mktempdir()
    child_uuid = "aaaaaaaa-9999-0000-1111-222222222222"
    child = _write_package(joinpath(root, "Child"), "Child", child_uuid)

    parent = mkpath(joinpath(root, "Parent"))
    write(
        joinpath(parent, "Project.toml"), """
        [deps]
        Child = "$child_uuid"
        """
    )
    write(
        joinpath(parent, "Manifest.toml"), """
        manifest_format = "2.0"

        [[deps.Child]]
        path = "../Child"
        uuid = "$child_uuid"
        version = "0.1.0"
        """
    )
    before_parent, before_child = _snapshot(parent), _snapshot(child)

    env_dir = materialize_scratch_env(parent, "Child")

    entry = Pkg.Types.read_manifest(joinpath(env_dir, "Manifest.toml"))[Base.UUID(child_uuid)]
    @test isabspath(entry.path)
    @test realpath(entry.path) == realpath(child)

    @static if VERSION >= v"1.11"
        sources = Pkg.Types.read_project(joinpath(env_dir, "Project.toml")).sources
        @test realpath(sources["Child"]["path"]) == realpath(child)
    end

    @test _snapshot(parent) == before_parent
    @test _snapshot(child) == before_child
end

@testitem "scratch env: TestEnv activates against the scratch env" tags = [:integration] begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # The failure this guards against only appears once TestEnv runs: if the
    # scratch env were a plain copy of the package's Project.toml, `get_test_dir`
    # would look for `<scratch>/test` and find nothing.
    dir = _write_package(mktempdir(), "Activated", "aaaaaaaa-3333-4444-5555-666666666666")
    before = _snapshot(dir)

    original_project = Base.active_project()
    try
        Pkg.activate(materialize_scratch_env(dir, "Activated"))
        activate_test_env("Activated")

        # A test-only dep resolving proves the merged env is real, not empty.
        @test Base.identify_package("Test") !== nothing
        @test Base.identify_package("Activated") !== nothing
    finally
        Pkg.activate(original_project)
    end

    @test _snapshot(dir) == before
end
