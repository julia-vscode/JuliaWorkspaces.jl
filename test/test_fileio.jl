@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri, get_text_files

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))

    if Sys.islinux()
        invalid_file = joinpath(pkg_root, "\x9999.invalid.jl")
        touch(invalid_file)
        try
            jw = workspace_from_folders([pkg_root])

            @test length(get_text_files(jw)) == 5
        finally
            rm(invalid_file; force=true)
        end
    end
end
