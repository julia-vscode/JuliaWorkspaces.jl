@testitem "JuliaProjectFile round-trips every section" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_project_file, derived_project_file_problems
    using JuliaWorkspaces.URIs2: URI
    using UUIDs: UUID

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [weakdeps]
    Baz = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"

    [extensions]
    FooBazExt = "Baz"
    FooMultiExt = ["Baz", "Bar"]

    [extras]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [targets]
    test = ["Test"]

    [sources]
    Bar = {path = "../Bar"}
    Baz = {url = "https://example.com/Baz.jl", rev = "main"}

    [workspace]
    projects = ["test", "docs"]

    [compat]
    julia = "1.10"
    Bar = "2"

    [apps]
    fooapp = {submodule = "FooApp"}
    """

    uri = URI("file:///fixture/Foo/Project.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))

    pf = derived_project_file(jw.runtime, uri)
    @test pf !== nothing
    @test pf.name == "Foo"
    @test pf.uuid == UUID("5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd")
    @test pf.version == "0.1.0"
    @test pf.deps == Dict("Bar" => UUID("6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"))
    @test pf.weakdeps == Dict("Baz" => UUID("3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"))
    @test pf.extras == Dict("Test" => UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40"))
    @test pf.extensions == Dict("FooBazExt" => ["Baz"], "FooMultiExt" => ["Baz", "Bar"])
    @test pf.targets == Dict("test" => ["Test"])
    @test pf.sources["Bar"].path == "../Bar"
    @test pf.sources["Bar"].url === nothing
    @test pf.sources["Baz"].url == "https://example.com/Baz.jl"
    @test pf.sources["Baz"].rev == "main"
    @test pf.workspace_projects == ["test", "docs"]
    @test pf.compat == Dict("julia" => "1.10", "Bar" => "2")
    @test pf.app_names == ["fooapp"]

    @test isempty(derived_project_file_problems(jw.runtime, uri))

    # No [workspace] section is distinct from an empty member list.
    plain_uri = URI("file:///fixture/Plain/Project.toml")
    add_file!(jw, TextFile(plain_uri, SourceText("name = \"Plain\"\n", "toml")))
    @test derived_project_file(jw.runtime, plain_uri).workspace_projects === nothing
end

@testitem "malformed Project.toml fields degrade with problem records" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_project_file, derived_project_file_problems, derived_package
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "not-a-uuid"
    version = "also.not.a.version!"

    [deps]
    Bad = "still-not-a-uuid"

    [sources]
    Dangling = {rev = "main"}

    [workspace]
    projects = "test"
    """

    folder = URI("file:///broken/Foo")
    uri = URI("file:///broken/Foo/Project.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))

    pf = derived_project_file(jw.runtime, uri)
    @test pf.name == "Foo"
    @test pf.uuid === nothing
    @test pf.version === nothing
    @test isempty(pf.deps)
    @test pf.workspace_projects == String[]

    problems = derived_project_file_problems(jw.runtime, uri)
    @test all(p -> p.code === :project_file_errors, problems)
    @test any(p -> p.key_path == ["uuid"], problems)
    @test any(p -> p.key_path == ["version"], problems)
    @test any(p -> p.key_path == ["deps", "Bad"], problems)
    @test any(p -> p.key_path == ["sources", "Dangling"], problems)
    @test any(p -> p.key_path == ["workspace", "projects"], problems)

    # The degraded identity means the folder is not a package — same behavior
    # the raw haskey checks used to produce, but with problems recorded.
    @test derived_package(jw.runtime, folder) === nothing
end

@testitem "cross-section validation finds dangling references" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_project_semantic_problems
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [extensions]
    FooBazExt = "Baz"

    [targets]
    test = ["Test"]

    [sources]
    Unknown = {url = "https://example.com/U.jl"}

    [compat]
    Stray = "1"
    """

    uri = URI("file:///semantic/Foo/Project.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))

    problems = derived_project_semantic_problems(jw.runtime, uri)

    # `Baz` is not a declared weakdep, so the extension cannot load: an error.
    ext = only(filter(p -> p.key_path == ["extensions", "FooBazExt"], problems))
    @test ext.code === :project_file_errors

    # The rest are inconsistencies Pkg tolerates until used: warnings.
    @test only(filter(p -> p.key_path == ["targets", "test"], problems)).code === :project_file_warnings
    @test any(p -> p.key_path == ["sources", "Unknown"] && p.code === :project_file_warnings, problems)
    @test only(filter(p -> p.key_path == ["compat", "Stray"], problems)).code === :project_file_warnings

    # `julia` is always a valid compat target.
    @test !any(p -> p.key_path == ["compat", "julia"], problems)
end

@testitem "JuliaManifestFile parses entries with weakdeps and extensions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_manifest_file, derived_manifest_file_problems, derived_project
    using JuliaWorkspaces.URIs2: URI
    using UUIDs: UUID

    manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [[deps.Bar]]
    git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.1.0"
    weakdeps = ["Baz"]

        [deps.Bar.extensions]
        BarBazExt = "Baz"

    [[deps.Local]]
    path = "../Local"
    uuid = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    version = "0.1.0"

    [[deps.Mystery]]
    some-unknown-field = "?"
    """

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"
    """

    folder = URI("file:///manifests/Foo")
    project_uri = URI("file:///manifests/Foo/Project.toml")
    manifest_uri = URI("file:///manifests/Foo/Manifest.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(project_uri, SourceText(project, "toml")))
    add_file!(jw, TextFile(manifest_uri, SourceText(manifest, "toml")))

    mf = derived_manifest_file(jw.runtime, manifest_uri)
    @test mf !== nothing
    @test mf.manifest_format == v"2.0.0"
    @test mf.julia_version == v"1.11.0"
    @test mf.project_hash == "abc123"

    bar = only(mf.entries["Bar"])
    @test bar.uuid == UUID("6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22")
    @test bar.git_tree_sha1 == "0123456789abcdef0123456789abcdef01234567"
    @test bar.version == "2.1.0"
    @test bar.weakdeps == ["Baz"]
    @test bar.extensions == Dict("BarBazExt" => ["Baz"])

    local_entry = only(mf.entries["Local"])
    @test local_entry.path == "../Local"

    # The uuid-less entry used to `error()` out of `derived_project`; now it is
    # kept (degraded) with a problem record, and the project still derives.
    @test only(mf.entries["Mystery"]).uuid === nothing
    problems = derived_manifest_file_problems(jw.runtime, manifest_uri)
    @test any(p -> p.code === :manifest_errors && p.key_path == ["deps", "Mystery"], problems)

    project_details = derived_project(jw.runtime, folder)
    @test project_details !== nothing
    @test haskey(project_details.regular_packages, "Bar")
    @test haskey(project_details.deved_packages, "Local")
    @test !haskey(project_details.stdlib_packages, "Mystery")
end

@testitem "project-file problems surface as located diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "not-a-uuid"
    version = "0.1.0"
    """

    uri = URI("file:///diag/Foo/Project.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))

    diags = get_diagnostic(jw, uri)
    d = only(filter(d -> d.code === :project_file_errors, diags))
    @test d.severity === :error
    # The range points at the offending value (half-open byte range).
    @test project[first(d.range):last(d.range)-1] == "\"not-a-uuid\""
end

@testitem "manifest problems surface as located diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.Mystery]]
    some-unknown-field = "?"
    """

    uri = URI("file:///diag/Foo/Manifest.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(manifest, "toml")))

    diags = get_diagnostic(jw, uri)
    d = only(filter(d -> d.code === :manifest_errors, diags))
    @test d.severity === :information
    # Points at the `[[deps.Mystery]]` header's key.
    @test manifest[first(d.range):last(d.range)-1] == "deps.Mystery"
end
