@testitem "Julia workspace" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = workspace_from_folders([pkg_root])

    text_files = get_text_files(jw)
    @test length(text_files) == 4
    @test project_file_uri in text_files
    @test jl_package_file_uri in text_files
    @test jl_file_with_error_file_uri in text_files

    # @test length(jw._julia_syntax_trees) == 2
    @test get_julia_syntax_tree(jw, jl_package_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode
    @test get_julia_syntax_tree(jw, jl_file_with_error_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode

    # @test length(jw._toml_syntax_trees) == 1
    @test get_toml_syntax_tree(jw, project_file_uri) isa Dict

    # @test length(jw._diagnostics) == 2
    # @test length(jw._diagnostics[jl_package_file_uri]) == 0
    # @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    packages = get_packages(jw)
    @test length(packages) == 1
    @test project_uri in packages

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "add_workspace_folder" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace()
    add_folder_from_disc!(jw, pkg_root)

    text_files = get_text_files(jw)
    @test length(text_files) == 4
    @test project_file_uri in text_files
    @test jl_package_file_uri in text_files
    @test jl_file_with_error_file_uri in text_files

    # @test length(jw._julia_syntax_trees) == 2
    @test get_julia_syntax_tree(jw, jl_package_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode
    @test get_julia_syntax_tree(jw, jl_file_with_error_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode

    # @test length(jw._toml_syntax_trees) == 1
    @test get_toml_syntax_tree(jw, project_file_uri) isa Dict

    # @test length(jw._diagnostics) == 2
    # @test length(jw._diagnostics[jl_package_file_uri]) == 0
    # @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    packages = get_packages(jw)
    @test length(packages) == 1
    @test project_uri in packages

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "add_workspace_folder and remove_workspace_folder" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    second_folder = joinpath(@__DIR__, "..", "testdata", "project_detection", "TestPackage2", "src")

    jw = JuliaWorkspace()
    add_folder_from_disc!(jw, pkg_root)
    add_folder_from_disc!(jw, second_folder)
    remove_all_children!(jw, filepath2uri(second_folder))

    text_files = get_text_files(jw)
    @test length(text_files) == 4
    @test project_file_uri in text_files
    @test jl_package_file_uri in text_files
    @test jl_file_with_error_file_uri in text_files

    # @test length(jw._julia_syntax_trees) == 2
    @test get_julia_syntax_tree(jw, jl_package_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode
    @test get_julia_syntax_tree(jw, jl_file_with_error_file_uri) isa JuliaWorkspaces.JuliaSyntax.SyntaxNode

    # @test length(jw._toml_syntax_trees) == 1
    @test get_toml_syntax_tree(jw, project_file_uri) isa Dict

    # @test length(jw._diagnostics) == 2
    # @test length(jw._diagnostics[jl_package_file_uri]) == 0
    # @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    packages = get_packages(jw)
    @test length(packages) == 1
    @test project_uri in packages

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "add_file" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace()
    add_file_from_disc!(jw, project_file_path)

    text_files = get_text_files(jw)
    @test length(text_files) == 1
    @test project_file_uri in text_files

    @test get_toml_syntax_tree(jw, project_file_uri) isa Dict

    # @test length(jw._diagnostics) == 2
    # @test length(jw._diagnostics[jl_package_file_uri]) == 0
    # @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    packages = get_packages(jw)
    @test length(packages) == 1
    @test project_uri in packages

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "update_file" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace()
    add_file_from_disc!(jw, project_file_path)
    update_file_from_disc!(jw, project_file_path)

    text_files = get_text_files(jw)
    @test length(text_files) == 1
    @test project_file_uri in text_files

    @test get_toml_syntax_tree(jw, project_file_uri) isa Dict

    # @test length(jw._diagnostics) == 2
    # @test length(jw._diagnostics[jl_package_file_uri]) == 0
    # @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    packages = get_packages(jw)
    @test length(packages) == 1
    @test project_uri in packages

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "delete_file" begin
    using JuliaWorkspaces: filepath2uri

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace()
    add_file_from_disc!(jw, project_file_path)
    remove_file!(jw, project_file_uri)
    
    text_files = get_text_files(jw)
    @test length(text_files) == 0

    packages = get_packages(jw)
    @test length(packages) == 0

    projects = get_projects(jw)
    @test length(projects) == 0
end

@testitem "is_ready after a failed dynamic process" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, FailedResult,
        WatchEnvironmentKey, CreateStandaloneProjectKey, process_from_dynamic, is_ready

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    df = jw.dynamic_feature

    # Nothing pending, but no environment round has completed yet.
    @test !is_ready(jw)

    # A failed work item must still flip readiness (best-effort), so consumers
    # of `wait_until_ready`/`is_ready` don't block forever on a broken project.
    put!(df.out_channel, FailedResult(WatchEnvironmentKey("/some/project", UInt64(1))))
    process_from_dynamic(jw)
    @test is_ready(jw)

    # Work kinds without a produced project (test envs, standalone projects)
    # also unblock readiness when they fail.
    jw2 = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    @test !is_ready(jw2)
    put!(jw2.dynamic_feature.out_channel, FailedResult(CreateStandaloneProjectKey("/some/package", UInt64(1))))
    process_from_dynamic(jw2)
    @test is_ready(jw2)
end
