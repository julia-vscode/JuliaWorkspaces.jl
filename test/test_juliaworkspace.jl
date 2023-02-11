@testitem "Julia workspace" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace(Set([pkg_root_uri]))

    @test length(jw._workspace_folders) == 1
    @test pkg_root_uri in jw._workspace_folders

    @test length(jw._text_documents) == 3
    @test haskey(jw._text_documents, project_file_uri)
    @test haskey(jw._text_documents, jl_package_file_uri)
    @test haskey(jw._text_documents, jl_file_with_error_file_uri)

    @test length(jw._julia_syntax_trees) == 2
    @test haskey(jw._julia_syntax_trees, jl_package_file_uri)
    @test haskey(jw._julia_syntax_trees, jl_file_with_error_file_uri)

    @test length(jw._toml_syntax_trees) == 1
    @test haskey(jw._toml_syntax_trees, project_file_uri)

    @test length(jw._diagnostics) == 2
    @test length(jw._diagnostics[jl_package_file_uri]) == 0
    @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    @test length(jw._packages) == 1
    @test haskey(jw._packages, project_uri)

    @test length(jw._projects) == 0
end

@testitem "add_workspace_folder" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_workspace_folder

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
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
    jw = add_workspace_folder(jw, pkg_root_uri)

    @test length(jw._workspace_folders) == 1
    @test pkg_root_uri in jw._workspace_folders

    @test length(jw._text_documents) == 3
    @test haskey(jw._text_documents, project_file_uri)
    @test haskey(jw._text_documents, jl_package_file_uri)
    @test haskey(jw._text_documents, jl_file_with_error_file_uri)

    @test length(jw._julia_syntax_trees) == 2
    @test haskey(jw._julia_syntax_trees, jl_package_file_uri)
    @test haskey(jw._julia_syntax_trees, jl_file_with_error_file_uri)

    @test length(jw._toml_syntax_trees) == 1
    @test haskey(jw._toml_syntax_trees, project_file_uri)

    @test length(jw._diagnostics) == 2
    @test length(jw._diagnostics[jl_package_file_uri]) == 0
    @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    @test length(jw._packages) == 1
    @test haskey(jw._packages, project_uri)

    @test length(jw._projects) == 0
end

@testitem "add_workspace_folder 2" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_workspace_folder

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
    pkg_root_uri = filepath2uri(pkg_root)
    project_file_path = joinpath(pkg_root, "Project.toml")
    project_path = dirname(project_file_path)
    project_file_uri = filepath2uri(project_file_path)
    project_uri = filepath2uri(project_path)
    jl_package_file_path =  joinpath(pkg_root, "src", "TestPackage1.jl")
    jl_package_file_uri = filepath2uri(jl_package_file_path)
    jl_file_with_error_file_path = joinpath(pkg_root, "src", "file_with_error.jl")
    jl_file_with_error_file_uri = filepath2uri(jl_file_with_error_file_path)

    jw = JuliaWorkspace(Set{JuliaWorkspaces.URI}([]))
    jw = add_workspace_folder(jw, pkg_root_uri)

    @test length(jw._workspace_folders) == 1
    @test pkg_root_uri in jw._workspace_folders

    @test length(jw._text_documents) == 3
    @test haskey(jw._text_documents, project_file_uri)
    @test haskey(jw._text_documents, jl_package_file_uri)
    @test haskey(jw._text_documents, jl_file_with_error_file_uri)

    @test length(jw._julia_syntax_trees) == 2
    @test haskey(jw._julia_syntax_trees, jl_package_file_uri)
    @test haskey(jw._julia_syntax_trees, jl_file_with_error_file_uri)

    @test length(jw._toml_syntax_trees) == 1
    @test haskey(jw._toml_syntax_trees, project_file_uri)

    @test length(jw._diagnostics) == 2
    @test length(jw._diagnostics[jl_package_file_uri]) == 0
    @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    @test length(jw._packages) == 1
    @test haskey(jw._packages, project_uri)

    @test length(jw._projects) == 0
end

@testitem "add_workspace_folder and remove_workspace_folder" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_workspace_folder, remove_workspace_folder

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
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
    jw = add_workspace_folder(jw, pkg_root_uri)
    jw = add_workspace_folder(jw, filepath2uri(joinpath(@__DIR__, "data", "TestPackage1", "src")))
    jw = remove_workspace_folder(jw, pkg_root_uri)

    @test length(jw._workspace_folders) == 1
    @test filepath2uri(joinpath(@__DIR__, "data", "TestPackage1", "src")) in jw._workspace_folders

    @test length(jw._text_documents) == 2
    @test haskey(jw._text_documents, jl_package_file_uri)
    @test haskey(jw._text_documents, jl_file_with_error_file_uri)

    @test length(jw._julia_syntax_trees) == 2
    @test haskey(jw._julia_syntax_trees, jl_package_file_uri)
    @test haskey(jw._julia_syntax_trees, jl_file_with_error_file_uri)

    @test length(jw._toml_syntax_trees) == 0

    @test length(jw._diagnostics) == 2
    @test length(jw._diagnostics[jl_package_file_uri]) == 0
    @test length(jw._diagnostics[jl_file_with_error_file_uri]) == 5

    @test length(jw._packages) == 0

    @test length(jw._projects) == 0
end

@testitem "add_file" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_file

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
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
    jw = add_file(jw, project_file_uri)

    @test length(jw._workspace_folders) == 0
    
    @test length(jw._text_documents) == 1
    @test haskey(jw._text_documents, project_file_uri)

    @test length(jw._julia_syntax_trees) == 0

    @test length(jw._toml_syntax_trees) == 1
    @test haskey(jw._toml_syntax_trees, project_file_uri)

    @test length(jw._diagnostics) == 0

    @test length(jw._packages) == 1
    @test haskey(jw._packages, project_uri)

    @test length(jw._projects) == 0
end

@testitem "update_file" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_file, update_file

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
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
    jw = add_file(jw, project_file_uri)
    jw = update_file(jw, project_file_uri)

    @test length(jw._workspace_folders) == 0
    
    @test length(jw._text_documents) == 1
    @test haskey(jw._text_documents, project_file_uri)

    @test length(jw._julia_syntax_trees) == 0

    @test length(jw._toml_syntax_trees) == 1
    @test haskey(jw._toml_syntax_trees, project_file_uri)

    @test length(jw._diagnostics) == 0

    @test length(jw._packages) == 1
    @test haskey(jw._packages, project_uri)

    @test length(jw._projects) == 0
end

@testitem "delete_file" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace, add_file, delete_file

    pkg_root = abspath(joinpath(@__DIR__, "data", "TestPackage1"))
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
    jw = add_file(jw, project_file_uri)
    jw = delete_file(jw, project_file_uri)
    
    @test length(jw._workspace_folders) == 0
    
    @test length(jw._text_documents) == 0

    @test length(jw._julia_syntax_trees) == 0

    @test length(jw._toml_syntax_trees) == 0

    @test length(jw._diagnostics) == 0

    @test length(jw._packages) == 0

    @test length(jw._projects) == 0
end
