@testitem "exclude-environments" begin
    using JuliaWorkspaces: workspace_from_folders, add_file_from_disc!, remove_file!, derived_potential_project_folders
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    write_file(p, c) = (mkpath(dirname(p)); write(p, c); p)

    mktempdir() do root
        root = realpath(root)
        folders(jw) = sort([replace(relpath(uri2filepath(u), root), '\\' => '/') for u in keys(derived_potential_project_folders(jw.runtime))])

        write_file(joinpath(root, "Project.toml"), "name = \"Demo\"\n")
        write_file(joinpath(root, ".scratch", "worktrees", "wt1", "Project.toml"), "name = \"Demo\"\n")
        write_file(joinpath(root, ".scratch", "worktrees", "wt1", "JuliaLint.toml"), "")
        config = write_file(joinpath(root, ".scratch", "JuliaLint.toml"), "exclude-environments = [\"**\"]\n")

        jw = workspace_from_folders([root])
        @test folders(jw) == ["."]

        late = write_file(joinpath(root, ".scratch", "worktrees", "wt2", "examples", "Project.toml"), "[deps]\n")
        add_file_from_disc!(jw, late)
        @test folders(jw) == ["."]

        remove_file!(jw, filepath2uri(config))
        @test folders(jw) == [".", ".scratch/worktrees/wt1", ".scratch/worktrees/wt2/examples"]
    end
end

@testitem "exclude-environments: validation" begin
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    function diags(content)
        jw = JuliaWorkspace()
        uri = URI("file:///ee/JuliaLint.toml")
        add_file!(jw, TextFile(uri, SourceText(content, "toml")))
        return get_diagnostic(jw, uri)
    end

    @test isempty(diags("exclude-environments = [\"examples/**\"]\n"))

    d = diags("exclude-environments = \"examples/**\"\n")
    @test any(x -> occursin("Invalid value for `exclude-environments`", x.message), d)
    @test all(x -> x.code === :config_errors, d)
end

@testitem "exclude-environments: a malformed value excludes nothing" begin
    using JuliaWorkspaces: workspace_from_folders, derived_potential_project_folders
    using JuliaWorkspaces.URIs2: uri2filepath

    mktempdir() do root
        root = realpath(root)
        mkpath(joinpath(root, "examples"))
        write(joinpath(root, "Project.toml"), "name = \"Demo\"\n")
        write(joinpath(root, "examples", "Project.toml"), "[deps]\n")
        write(joinpath(root, "JuliaLint.toml"), "exclude-environments = \"examples/**\"\n")

        jw = workspace_from_folders([root])
        folders = sort([replace(relpath(uri2filepath(u), root), '\\' => '/') for u in keys(derived_potential_project_folders(jw.runtime))])
        @test folders == [".", "examples"]
    end
end
