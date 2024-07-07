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
