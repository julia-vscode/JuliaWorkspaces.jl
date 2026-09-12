@testitem "derived_extension_for_file maps both ext layouts" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_extension_for_file
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [weakdeps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    Baz = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"

    [extensions]
    FooBarExt = "Bar"
    FooBazExt = ["Bar", "Baz"]
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ext/Foo/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/src/Foo.jl"), SourceText("module Foo end", "julia")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/FooBarExt.jl"), SourceText("module FooBarExt end", "julia")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/FooBazExt/FooBazExt.jl"), SourceText("module FooBazExt end", "julia")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/FooBazExt/helper.jl"), SourceText("nothing", "julia")))

    flat = derived_extension_for_file(jw.runtime, URI("file:///ext/Foo/ext/FooBarExt.jl"))
    @test flat !== nothing
    @test flat.ext_name == "FooBarExt"
    @test flat.triggers == ["Bar"]
    @test flat.package_folder == URI("file:///ext/Foo")

    nested = derived_extension_for_file(jw.runtime, URI("file:///ext/Foo/ext/FooBazExt/FooBazExt.jl"))
    @test nested.ext_name == "FooBazExt"
    @test nested.triggers == ["Bar", "Baz"]

    # Every file under the extension's folder belongs to it.
    helper = derived_extension_for_file(jw.runtime, URI("file:///ext/Foo/ext/FooBazExt/helper.jl"))
    @test helper.ext_name == "FooBazExt"

    # src/ files and ext/ files matching no declared extension are not extensions.
    @test derived_extension_for_file(jw.runtime, URI("file:///ext/Foo/src/Foo.jl")) === nothing
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/loose.jl"), SourceText("nothing", "julia")))
    @test derived_extension_for_file(jw.runtime, URI("file:///ext/Foo/ext/loose.jl")) === nothing
end

@testitem "an ext file borrows an environment whose manifest covers its triggers" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_extension_project_uri, derived_project_uri_for_root,
        derived_extension_blind_triggers, derived_required_dynamic_projects,
        ResolveExtensionEnvironmentKey
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [weakdeps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [extensions]
    FooBarExt = "Bar"
    """
    manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.Bar]]
    git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ext/Foo/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/Manifest.toml"), SourceText(manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/src/Foo.jl"), SourceText("module Foo end", "julia")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/FooBarExt.jl"), SourceText("module FooBarExt end", "julia")))

    pkg_folder = URI("file:///ext/Foo")
    ext_file = URI("file:///ext/Foo/ext/FooBarExt.jl")

    # The package's own manifest resolves Bar, so the package env covers the
    # extension: no work item, no blindness.
    @test derived_extension_project_uri(jw.runtime, pkg_folder, "FooBarExt") == pkg_folder
    @test derived_project_uri_for_root(jw.runtime, ext_file) == pkg_folder
    @test isempty(derived_extension_blind_triggers(jw.runtime, ext_file))
    @test !any(k -> k isa ResolveExtensionEnvironmentKey, derived_required_dynamic_projects(jw.runtime))
end

@testitem "uncovered triggers schedule an ext-env DJP, gate, and go blind on failure" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_extension_project_uri, derived_project_uri_for_root, derived_file_env_ready,
        derived_extension_blind_triggers, derived_required_dynamic_projects, derived_package,
        ResolveExtensionEnvironmentKey, DJPKey,
        set_input_extension_environments!, set_input_failed_dynamic_keys!
    using JuliaWorkspaces.URIs2: URI, uri2filepath

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [weakdeps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [extensions]
    FooBarExt = "Bar"
    """

    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///ext/Foo/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/src/Foo.jl"), SourceText("module Foo end", "julia")))
    add_file!(jw, TextFile(URI("file:///ext/Foo/ext/FooBarExt.jl"), SourceText("module FooBarExt end", "julia")))

    pkg_folder = URI("file:///ext/Foo")
    ext_file = URI("file:///ext/Foo/ext/FooBarExt.jl")

    pkg = derived_package(jw.runtime, pkg_folder)
    key = ResolveExtensionEnvironmentKey(uri2filepath(pkg_folder), pkg.content_hash)

    # No manifest anywhere resolves Bar: the ext-env item is scheduled, the
    # ext file has no covering env yet, and diagnostics gate on the pending item.
    @test key in derived_required_dynamic_projects(jw.runtime)
    @test derived_extension_project_uri(jw.runtime, pkg_folder, "FooBarExt") === nothing
    @test !derived_file_env_ready(jw.runtime, ext_file)
    # The triggers are already reported blind (the env-ready gate suppresses
    # env-dependent findings while the item is pending, so the transform only
    # becomes visible once the item settles).
    @test derived_extension_blind_triggers(jw.runtime, ext_file) == ["Bar"]

    # The resolved extension environment arrives: it owns the ext file and
    # readiness settles.
    scratch = URI("file:///scratch/ext-env-Foo-1234")
    set_input_extension_environments!(jw.runtime, Dict(key => scratch))
    @test derived_extension_project_uri(jw.runtime, pkg_folder, "FooBarExt") == scratch
    @test derived_project_uri_for_root(jw.runtime, ext_file) == scratch
    @test derived_file_env_ready(jw.runtime, ext_file)
    @test isempty(derived_extension_blind_triggers(jw.runtime, ext_file))

    # A terminal failure settles readiness too — and the triggers become an
    # analysis boundary (silent by default).
    set_input_extension_environments!(jw.runtime, Dict{ResolveExtensionEnvironmentKey,typeof(scratch)}())
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([key]))
    @test derived_file_env_ready(jw.runtime, ext_file)
    @test derived_extension_blind_triggers(jw.runtime, ext_file) == ["Bar"]

    # A resolved extension environment whose manifest lacks a trigger (the
    # child could not install it) still owns the file, but that trigger is
    # blind; one that carries it is not.
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}())
    degraded = URI("file:///scratch/ext-env-Foo-degraded")
    add_file!(jw, TextFile(URI("file:///scratch/ext-env-Foo-degraded/Project.toml"), SourceText("[deps]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///scratch/ext-env-Foo-degraded/Manifest.toml"), SourceText(
        "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n", "toml")))
    set_input_extension_environments!(jw.runtime, Dict(key => degraded))
    @test derived_project_uri_for_root(jw.runtime, ext_file) == degraded
    @test derived_extension_blind_triggers(jw.runtime, ext_file) == ["Bar"]
    covered = URI("file:///scratch/ext-env-Foo-covered")
    add_file!(jw, TextFile(URI("file:///scratch/ext-env-Foo-covered/Project.toml"), SourceText("[deps]\nBar = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///scratch/ext-env-Foo-covered/Manifest.toml"), SourceText(
        "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[[deps.Bar]]\ngit-tree-sha1 = \"0123456789abcdef0123456789abcdef01234567\"\nuuid = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\nversion = \"1.0.0\"\n", "toml")))
    set_input_extension_environments!(jw.runtime, Dict(key => covered))
    @test isempty(derived_extension_blind_triggers(jw.runtime, ext_file))
    # Covered, yet the trigger's store is not indexed: the trigger is a
    # declared dependency of the extension (a `[weakdeps]` entry), so
    # `using Bar` is a boundary, never an unresolved import.
    JuliaWorkspaces.set_v2_enabled!(jw, true)
    @test !any(d -> d.code === :unresolved_import, JuliaWorkspaces.get_diagnostic(jw, ext_file))

    # A project file with NO manifest: the child's `instantiate` failed after
    # writing the project — nothing installed, every trigger blind.
    bare = URI("file:///scratch/ext-env-Foo-bare")
    add_file!(jw, TextFile(URI("file:///scratch/ext-env-Foo-bare/Project.toml"), SourceText("[deps]\nBar = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\n", "toml")))
    set_input_extension_environments!(jw.runtime, Dict(key => bare))
    @test derived_extension_blind_triggers(jw.runtime, ext_file) == ["Bar"]
end
