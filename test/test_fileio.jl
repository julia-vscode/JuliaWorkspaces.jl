@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri, get_text_files

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))

    jw = workspace_from_folders([pkg_root])

    @test length(get_text_files(jw)) > 0
end
