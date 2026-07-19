@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri, get_text_files

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))

    if Sys.islinux()

        mktempdir() do temp_dir
            invalid_file = joinpath(temp_dir, "\x9999.invalid.jl")
            touch(invalid_file)

            jw = workspace_from_folders([temp_dir])
            @test length(get_text_files(jw)) == 1
        end
    end
end

@testitem "read_path_into_textdocuments honors file_limit" begin
    using JuliaWorkspaces: read_path_into_textdocuments
    using JuliaWorkspaces.URIs2: filepath2uri

    dir = mktempdir()
    for i in 1:5
        write(joinpath(dir, "f$i.jl"), "f$i() = $i\n")
    end
    write(joinpath(dir, "Project.toml"), "name = \"X\"\n")

    unlimited = read_path_into_textdocuments(filepath2uri(dir))
    @test length(unlimited) == 6

    # Only Julia files count against the limit.
    at_limit = read_path_into_textdocuments(filepath2uri(dir), file_limit=5)
    @test length(at_limit) == 6

    @test read_path_into_textdocuments(filepath2uri(dir), file_limit=4) === nothing
end
