@testitem "Test project detection" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))

    jw = workspace_from_folders([pkg_root])

    pf = JuliaWorkspaces.derived_potential_project_folders(jw.runtime)

    println()
    println(pf)
    println()

    @test length(pf) == 1

    asasdfasdf = JuliaWorkspaces.derived_package_folders(jw.runtime)

    println()
    println("PACKAGES:")
    for i in asasdfasdf
        println("  ", i)

        qwer = JuliaWorkspaces.derived_package(jw.runtime, i)

        println(qwer)
    end
    println()

    asasdfasdf = JuliaWorkspaces.derived_project_folders(jw.runtime)

    println()
    println("PROJECTS")
    for i in asasdfasdf
        println("  ", i)
    end
    println()

end