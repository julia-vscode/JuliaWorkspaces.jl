@testitem "Test project detection" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace
    import UUIDs
    using UUIDs: UUID

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))

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

@testitem "Manifest details" begin
    using UUIDs, Pkg

    mktempdir() do root_path
        cp(joinpath(@__DIR__, "data", "project_detection"), joinpath(root_path, "project_detection"))

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
end
