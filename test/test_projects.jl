@testitem "Test project detection" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace
    import UUIDs
    using UUIDs: UUID

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))

    jw = workspace_from_folders([pkg_root])

    pf = JuliaWorkspaces.derived_potential_project_folders(jw.runtime)

    @test length(pf) == 1

    package_folders = JuliaWorkspaces.derived_package_folders(jw.runtime)

    @test length(package_folders) == 1
    @test package_folders[1] == filepath2uri(pkg_root)

    package_info = JuliaWorkspaces.derived_package(jw.runtime, package_folders[1])
    @test package_info.project_file_uri == filepath2uri(joinpath(pkg_root, "Project.toml"))
    @test package_info.name == "TestPackage1"
    @test package_info.uuid == UUID("85cc6e0e-feca-4605-a06a-0bfa59ec035b")

    projects = JuliaWorkspaces.derived_project_folders(jw.runtime)
    @test length(projects) == 0
end

@testitem "Manifest details" tags=[:skip] begin
    using UUIDs, Pkg

    old = Base.active_project()
    try
        mktempdir() do root_path
            cp(joinpath(@__DIR__, "..", "testdata", "project_detection"), joinpath(root_path, "project_detection"))

            Pkg.activate(joinpath(root_path, "project_detection"))
            Pkg.develop(PackageSpec(path=joinpath(root_path, "project_detection", "TestPackage3")))
            Pkg.instantiate()

            pkg_root = joinpath(root_path, "project_detection")

            jw = workspace_from_folders([pkg_root])

            project_uri = first(get_projects(jw))

            project_details = JuliaWorkspaces.derived_project(jw.runtime, project_uri)

            @test haskey(project_details.regular_packages, "JuliaSyntax") === true
            @test project_details.regular_packages["JuliaSyntax"].name == "JuliaSyntax"
            @test project_details.regular_packages["JuliaSyntax"].git_tree_sha1 == "e09bf943597f83cc7a1fe3ae6c01c2c008d8cde7"
            @test project_details.regular_packages["JuliaSyntax"].uuid == UUID("70703baa-626e-46a2-a12c-08ffd08c73b4")
            @test project_details.regular_packages["JuliaSyntax"].version == "0.3.5"

            @test haskey(project_details.stdlib_packages, "Dates") === true
            @test project_details.stdlib_packages["Dates"].name == "Dates"
            @test project_details.stdlib_packages["Dates"].uuid == UUID("ade2ca70-3891-5945-98fb-dc099432e06a")

            # we're not guaranteed that stdlib versions match the Julia version
            if v"1.11.0" <= VERSION < v"1.12-"
                @test VersionNumber(project_details.stdlib_packages["Dates"].version).major == VERSION.major
                @test VersionNumber(project_details.stdlib_packages["Dates"].version).minor == VERSION.minor
            end
            if VERSION < v"1.11-"
                @test project_details.stdlib_packages["Dates"].version === nothing
            end

            @test haskey(project_details.deved_packages, "TestPackage3") === true
            @test project_details.deved_packages["TestPackage3"].name == "TestPackage3"
            @test project_details.deved_packages["TestPackage3"].uuid == UUID("d952f820-d47c-4fa1-a74c-bfd674713277")
            @test project_details.deved_packages["TestPackage3"].version == "1.0.0"
        end
    finally
        Base.set_active_project(old)
    end
end

@testitem "_stdlib_only_env contains Base symbols" begin
    import JuliaWorkspaces.StaticLint as StaticLint

    env = JuliaWorkspaces._stdlib_only_env()

    # Should be a StaticLint.ExternalEnv
    @test env isa StaticLint.ExternalEnv

    # project_deps should be non-empty and contain core stdlib modules
    @test !isempty(env.project_deps)
    @test :Base in env.project_deps
    @test :Core in env.project_deps

    # The store should contain entries for Base
    @test haskey(env.symbols, :Base)
end

@testitem "derived_static_lint_meta_for_root without project" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace

    # Use the StandaloneFile testdata — a bare .jl file with no Project.toml.
    standalone_root = abspath(joinpath(@__DIR__, "..", "testdata", "StandaloneFile"))

    jw = workspace_from_folders([standalone_root])

    standalone_uri = filepath2uri(joinpath(standalone_root, "standalone.jl"))

    # The file should be found as a root
    root = JuliaWorkspaces.derived_best_root_for_uri(jw.runtime, standalone_uri)
    @test root !== nothing

    # No project URI should be detected (no Project.toml)
    project_uri = JuliaWorkspaces.derived_project_uri_for_root(jw.runtime, root)
    @test project_uri === nothing

    # derived_static_lint_meta_for_root should still succeed (via _stdlib_only_env)
    lint_result = JuliaWorkspaces.derived_static_lint_meta_for_root(jw.runtime, root)
    @test !isempty(lint_result.meta_dict)
    @test isempty(lint_result.workspace_packages)
end

@testitem "derived_project with Manifest.toml but no Project.toml does not crash" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_diagnostics
    using JuliaWorkspaces.URIs2: URI

    # A folder that has only a Manifest.toml (no Project.toml) mimics a
    # DJP-created temp project directory (e.g. /tmp/jl_xxxxxx) whose
    # Project.toml is missing or was deleted. The lazy
    # `derived_project_toml_files` probe used for the active project can
    # then return `(project_file=nothing, manifest_file=<uri>)`.
    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    folder_uri = URI("file:///manifestonlyprojecttest")
    manifest_uri = URI("file:///manifestonlyprojecttest/Manifest.toml")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(manifest_uri, SourceText(manifest_toml, "toml")))

    JuliaWorkspaces.set_active_project!(jw, folder_uri)

    # A folder without a Project.toml is not a project, even if it has a
    # Manifest.toml.
    @test JuliaWorkspaces.derived_project(jw.runtime, folder_uri) === nothing

    # This is the crash path: get_diagnostics used to throw a `FieldError`
    # (accessing `.scheme` on `nothing`) because `derived_project` reached
    # `derived_text_file_content(rt, project_file)` with `project_file ===
    # nothing`.
    get_diagnostics(jw)
end
