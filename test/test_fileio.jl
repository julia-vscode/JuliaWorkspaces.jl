@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri, get_text_files

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))

    if Sys.islinux()

        mktempdir() do temp_dir
            invalid_file = joinpath(temp_dir, "\x9999.invalid.jl")
            touch(invalid_file)

            jw = workspace_from_folders([temp_dir])
            @test length(get_text_files(jw)) == 1
        end
    end
end
