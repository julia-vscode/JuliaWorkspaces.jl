@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))

    jw = workspace_from_folders([pkg_root])
end
