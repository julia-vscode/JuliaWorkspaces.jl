@testitem "workspace root discovery and member map" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_workspace_root, derived_declaring_workspace_parent, derived_workspace_members
    using JuliaWorkspaces.URIs2: URI

    root_project = """
    name = "WorkspacePkg"
    uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
    version = "0.1.0"

    [workspace]
    projects = ["test", "docs"]
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Project.toml"), SourceText(root_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/test/Project.toml"), SourceText("[deps]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/Project.toml"), SourceText("[deps]\n", "toml")))

    pkg = URI("file:///ws/Pkg")
    @test derived_declaring_workspace_parent(jw.runtime, URI("file:///ws/Pkg/test")) == pkg
    @test derived_workspace_root(jw.runtime, URI("file:///ws/Pkg/test")) == pkg
    @test derived_workspace_root(jw.runtime, URI("file:///ws/Pkg/docs")) == pkg
    # The root itself is nobody's member; unrelated folders are not members.
    @test derived_workspace_root(jw.runtime, pkg) === nothing
    @test derived_workspace_root(jw.runtime, URI("file:///ws/Pkg/benchmark")) === nothing

    @test derived_workspace_members(jw.runtime, pkg) ==
        [URI("file:///ws/Pkg/docs"), URI("file:///ws/Pkg/test")]
end

@testitem "nested workspaces chase to the outermost root" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_workspace_root, derived_workspace_members
    using JuliaWorkspaces.URIs2: URI

    mono_project = """
    [workspace]
    projects = ["PkgA"]
    """
    pkga_project = """
    name = "PkgA"
    uuid = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    version = "0.1.0"

    [workspace]
    projects = ["test"]
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///mono/Project.toml"), SourceText(mono_project, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/PkgA/Project.toml"), SourceText(pkga_project, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/PkgA/test/Project.toml"), SourceText("[deps]\n", "toml")))

    mono = URI("file:///mono")
    @test derived_workspace_root(jw.runtime, URI("file:///mono/PkgA")) == mono
    @test derived_workspace_root(jw.runtime, URI("file:///mono/PkgA/test")) == mono
    @test derived_workspace_members(jw.runtime, mono) ==
        [URI("file:///mono/PkgA"), URI("file:///mono/PkgA/test")]
end

@testitem "a workspace member synthesizes a project against the root manifest" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_project, derived_project_folders, derived_nonpackage_env_folders,
        derived_project_uri_for_root
    using JuliaWorkspaces.URIs2: URI
    using UUIDs: UUID

    root_project = """
    name = "WorkspacePkg"
    uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
    version = "0.1.0"

    [workspace]
    projects = ["test", "docs"]
    """
    root_manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [[deps.WorkspacePkg]]
    path = "."
    uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
    version = "0.1.0"

    [[deps.Test]]
    uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [[deps.Documenter]]
    git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
    uuid = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
    version = "1.0.0"
    """
    test_project = """
    [deps]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    WorkspacePkg = "d952f820-d47c-4fa1-a74c-bfd674713299"
    """
    docs_project = """
    [deps]
    Documenter = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Project.toml"), SourceText(root_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Manifest.toml"), SourceText(root_manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/src/WorkspacePkg.jl"), SourceText("module WorkspacePkg end", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/test/Project.toml"), SourceText(test_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/test/runtests.jl"), SourceText("using Test", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/Project.toml"), SourceText(docs_project, "toml")))

    test_folder = URI("file:///ws/Pkg/test")
    docs_folder = URI("file:///ws/Pkg/docs")

    # Members are project folders now (synthesized), not non-package envs.
    @test test_folder in derived_project_folders(jw.runtime)
    @test docs_folder in derived_project_folders(jw.runtime)
    @test isempty(derived_nonpackage_env_folders(jw.runtime))

    test_project_details = derived_project(jw.runtime, test_folder)
    @test test_project_details !== nothing
    # The synthesized project resolves against the ROOT's manifest.
    @test test_project_details.manifest_file_uri == URI("file:///ws/Pkg/Manifest.toml")
    @test test_project_details.julia_version == v"1.11.0"
    # The member's dep closure: Test (stdlib) and the package itself (a path
    # entry, so deved) — but not docs' Documenter.
    @test haskey(test_project_details.stdlib_packages, "Test")
    @test haskey(test_project_details.deved_packages, "WorkspacePkg")
    @test test_project_details.deved_packages["WorkspacePkg"].uri == URI("file:///ws/Pkg")
    @test !haskey(test_project_details.regular_packages, "Documenter")

    docs_project_details = derived_project(jw.runtime, docs_folder)
    @test haskey(docs_project_details.regular_packages, "Documenter")
    @test !haskey(docs_project_details.stdlib_packages, "Test")

    # Files under a member get the member's env; test files route there too.
    @test derived_project_uri_for_root(jw.runtime, URI("file:///ws/Pkg/docs/make.jl")) == docs_folder
    @test derived_project_uri_for_root(jw.runtime, URI("file:///ws/Pkg/test/runtests.jl")) == test_folder
end

@testitem "a workspace needs exactly one DJP and readiness gates on the root" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText,
        derived_project, derived_required_dynamic_projects, derived_file_env_ready,
        WatchEnvironmentKey, WatchTestEnvironmentKey, CreateStandaloneProjectKey,
        ResolveEnvironmentKey, set_input_ready_project_environments!
    using JuliaWorkspaces.URIs2: URI, uri2filepath, filepath2uri

    mktempdir() do temp_root
        pkg_root = joinpath(temp_root, "WorkspacePkg")
        mkpath(joinpath(pkg_root, "src"))
        mkpath(joinpath(pkg_root, "test"))
        mkpath(joinpath(pkg_root, "docs"))

        write(joinpath(pkg_root, "Project.toml"), """
        name = "WorkspacePkg"
        uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
        version = "0.1.0"

        [workspace]
        projects = ["test", "docs"]
        """)
        write(joinpath(pkg_root, "Manifest.toml"), """
        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "abc123"

        [[deps.WorkspacePkg]]
        path = "."
        uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
        version = "0.1.0"

        [[deps.Test]]
        uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """)
        write(joinpath(pkg_root, "src", "WorkspacePkg.jl"), "module WorkspacePkg end\n")
        write(joinpath(pkg_root, "test", "Project.toml"), """
        [deps]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        WorkspacePkg = "d952f820-d47c-4fa1-a74c-bfd674713299"
        """)
        write(joinpath(pkg_root, "test", "runtests.jl"), "using Test\n")
        write(joinpath(pkg_root, "docs", "Project.toml"), """
        [deps]
        """)

        jw = workspace_from_folders([pkg_root])
        set_v2_enabled!(jw, true)

        pkg_uri = filepath2uri(pkg_root)
        root_project = derived_project(jw.runtime, pkg_uri)
        @test root_project !== nothing

        # One watch item for the whole workspace: no test-env item for the
        # member `test/`, no resolve item for the member `docs/`, no
        # standalone items.
        required = derived_required_dynamic_projects(jw.runtime)
        root_key = WatchEnvironmentKey(uri2filepath(pkg_uri), root_project.content_hash)
        @test required == Set([root_key])

        # Member files gate on the ROOT's watch item...
        test_file = filepath2uri(joinpath(pkg_root, "test", "runtests.jl"))
        @test !derived_file_env_ready(jw.runtime, test_file)
        # ...and settle when it lands.
        set_input_ready_project_environments!(jw.runtime, Set([root_key]))
        @test derived_file_env_ready(jw.runtime, test_file)

        # A member dep change re-keys the root: the folded content hash covers
        # every member's Project.toml.
        update_file!(jw, TextFile(filepath2uri(joinpath(pkg_root, "docs", "Project.toml")),
            SourceText("[deps]\nDocumenter = \"e30172f5-a6a5-5a46-863b-614d45cd2de4\"\n", "toml")))
        rekeyed_project = derived_project(jw.runtime, pkg_uri)
        @test rekeyed_project.content_hash != root_project.content_hash
        @test derived_required_dynamic_projects(jw.runtime) ==
            Set([WatchEnvironmentKey(uri2filepath(pkg_uri), rekeyed_project.content_hash)])
    end
end

@testitem "derived_testenv points test files at the workspace member project" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText,
        derived_testenv
    using JuliaWorkspaces.URIs2: URI

    root_project = """
    name = "WorkspacePkg"
    uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
    version = "0.1.0"

    [workspace]
    projects = ["test"]
    """
    root_manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.WorkspacePkg]]
    path = "."
    uuid = "d952f820-d47c-4fa1-a74c-bfd674713299"
    version = "0.1.0"

    [[deps.Test]]
    uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    """
    test_project = """
    [deps]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    WorkspacePkg = "d952f820-d47c-4fa1-a74c-bfd674713299"
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Project.toml"), SourceText(root_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Manifest.toml"), SourceText(root_manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/src/WorkspacePkg.jl"), SourceText("module WorkspacePkg end", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/test/Project.toml"), SourceText(test_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/test/runtests.jl"), SourceText("using Test", "julia")))

    testenv = derived_testenv(jw.runtime, URI("file:///ws/Pkg/test/runtests.jl"))
    @test testenv.package_name == "WorkspacePkg"
    @test testenv.package_uri == URI("file:///ws/Pkg")
    # The test/ member's own (synthesized) project is the test environment.
    @test testenv.project_uri == URI("file:///ws/Pkg/test")

    # The env hash must cover the shared root manifest: a change there means
    # the pooled test process cannot be reused.
    update_file!(jw, TextFile(URI("file:///ws/Pkg/Manifest.toml"),
        SourceText(root_manifest * "\n[[deps.Example]]\nuuid = \"7876af07-990d-54b4-ab0e-23690620f79a\"\nversion = \"0.5.3\"\ngit-tree-sha1 = \"46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc\"\n", "toml")))
    testenv2 = derived_testenv(jw.runtime, URI("file:///ws/Pkg/test/runtests.jl"))
    @test testenv2.env_content_hash != testenv.env_content_hash
end
