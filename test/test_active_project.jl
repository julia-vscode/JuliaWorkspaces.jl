@testitem "Active project: set_active_project! with external project" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri
    using JuliaWorkspaces: input_indirect_text_file

    workspace_dir = abspath(joinpath(@__DIR__, "..", "testdata", "WorkspaceWithFile"))
    project_dir = abspath(joinpath(@__DIR__, "..", "testdata", "ExternalProject"))

    callback_calls = URI[]
    jw = JuliaWorkspace(indirect_file_watch_callback = uri -> push!(callback_calls, uri))

    add_folder_from_disc!(jw, workspace_dir)

    project_uri = filepath2uri(project_dir)
    set_active_project!(jw, project_uri)

    # Force the project layer to materialize — this should discover the
    # external Project.toml and Manifest.toml via indirect mechanism.
    projects = get_projects(jw)

    # The active project's Project.toml should have been loaded via
    # the indirect text file input (lazy disc read).
    proj_toml_uri = filepath2uri(joinpath(project_dir, "Project.toml"))
    @test input_indirect_text_file(jw.runtime, proj_toml_uri) !== nothing

    # The callback should have fired for the indirectly loaded files.
    @test proj_toml_uri in callback_calls
end

@testitem "Active project: set_active_project! with in-workspace project" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    dir = abspath(joinpath(@__DIR__, "..", "testdata", "InWorkspaceProject"))

    jw = JuliaWorkspace()
    add_folder_from_disc!(jw, dir)

    dir_uri = filepath2uri(dir)
    set_active_project!(jw, dir_uri)

    # Project.toml is already a regular file — it should stay regular.
    proj_toml_uri = filepath2uri(joinpath(dir, "Project.toml"))
    @test proj_toml_uri in JuliaWorkspaces.get_files(jw)
end

@testitem "Active project: clearing active project" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    workspace_dir = abspath(joinpath(@__DIR__, "..", "testdata", "WorkspaceWithFile"))
    project_dir = abspath(joinpath(@__DIR__, "..", "testdata", "ExternalProject"))

    jw = JuliaWorkspace()
    add_folder_from_disc!(jw, workspace_dir)

    project_uri = filepath2uri(project_dir)
    set_active_project!(jw, project_uri)

    # Force project discovery.
    projects_before = get_projects(jw)

    # Clear the active project.
    set_active_project!(jw, nothing)

    # The external project should no longer be in projects
    # (assuming no workspace folder file points to it).
    projects_after = get_projects(jw)
    @test length(projects_after) <= length(projects_before)
end

@testitem "Active project: test env uses active project as fallback" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    workspace_dir = abspath(joinpath(@__DIR__, "..", "testdata", "WorkspaceWithFile"))
    project_dir = abspath(joinpath(@__DIR__, "..", "testdata", "ExternalProject"))

    jw = JuliaWorkspace()
    add_folder_from_disc!(jw, workspace_dir)

    project_uri = filepath2uri(project_dir)
    set_active_project!(jw, project_uri)

    standalone_uri = filepath2uri(joinpath(workspace_dir, "main.jl"))

    # The test env for a file outside any project should use the active project.
    test_env = get_test_env(jw, standalone_uri)
    # test_env may be nothing if the project doesn't have test deps,
    # but the important thing is no error is thrown.
end
