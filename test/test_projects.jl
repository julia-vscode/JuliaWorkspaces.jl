@testitem "Test project detection" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace
    import UUIDs
    using UUIDs: UUID

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))

    jw = workspace_from_folders([pkg_root])

    pf = JuliaWorkspaces.derived_potential_project_folders(jw.runtime)

    @test length(pf) == 1

    package_folders = JuliaWorkspaces.derived_package_folders(jw.runtime)

    @test length(package_folders) == 1
    @test package_folders[1] == filepath2uri(pkg_root)

    package_info = JuliaWorkspaces.derived_package(jw.runtime, package_folders[1])
    @test package_info.project_file_uri == filepath2uri(joinpath(pkg_root, "Project.toml"))
    @test package_info.name == "TestPackage1"
    @test package_info.uuid == UUID("85cc6e0e-feca-4605-a06a-0bfa59ec035b")

    projects = JuliaWorkspaces.derived_project_folders(jw.runtime)
    @test length(projects) == 0
end

@testitem "Manifest details" begin
    using UUIDs, Pkg, TOML

    old = Base.active_project()
    try
        mktempdir() do root_path
            cp(joinpath(@__DIR__, "..", "testdata", "project_detection"), joinpath(root_path, "project_detection"))

            Pkg.activate(joinpath(root_path, "project_detection"))
            Pkg.develop(PackageSpec(path=joinpath(root_path, "project_detection", "TestPackage3")))
            Pkg.instantiate()

            pkg_root = joinpath(root_path, "project_detection")

            jw = workspace_from_folders([pkg_root])

            project_uri = first(get_projects(jw))

            project_details = JuliaWorkspaces.derived_project(jw.runtime, project_uri)

            # The fixture ships no Manifest.toml, so `instantiate` resolves fresh
            # against the registry every run. Compare against what Pkg just wrote
            # rather than a pinned version — what this asserts is that our manifest
            # parsing agrees with Pkg's, not which 0.3.x the registry currently has.
            manifest = TOML.parsefile(joinpath(pkg_root, "Manifest.toml"))
            juliasyntax = only(manifest["deps"]["JuliaSyntax"])

            @test haskey(project_details.regular_packages, "JuliaSyntax") === true
            @test project_details.regular_packages["JuliaSyntax"].name == "JuliaSyntax"
            @test project_details.regular_packages["JuliaSyntax"].git_tree_sha1 == juliasyntax["git-tree-sha1"]
            @test project_details.regular_packages["JuliaSyntax"].uuid == UUID("70703baa-626e-46a2-a12c-08ffd08c73b4")
            @test project_details.regular_packages["JuliaSyntax"].version == juliasyntax["version"]

            @test haskey(project_details.stdlib_packages, "Dates") === true
            @test project_details.stdlib_packages["Dates"].name == "Dates"
            @test project_details.stdlib_packages["Dates"].uuid == UUID("ade2ca70-3891-5945-98fb-dc099432e06a")

            # we're not guaranteed that stdlib versions match the Julia version
            if v"1.11.0" <= VERSION < v"1.12-"
                @test VersionNumber(project_details.stdlib_packages["Dates"].version).major == VERSION.major
                @test VersionNumber(project_details.stdlib_packages["Dates"].version).minor == VERSION.minor
            end
            if VERSION < v"1.11-"
                @test project_details.stdlib_packages["Dates"].version === nothing
            end

            @test haskey(project_details.deved_packages, "TestPackage3") === true
            @test project_details.deved_packages["TestPackage3"].name == "TestPackage3"
            @test project_details.deved_packages["TestPackage3"].uuid == UUID("d952f820-d47c-4fa1-a74c-bfd674713277")
            @test project_details.deved_packages["TestPackage3"].version == "1.0.0"
        end
    finally
        Base.set_active_project(old)
    end
end

@testitem "_stdlib_only_env contains Base symbols" begin
    import JuliaWorkspaces.StaticLint as StaticLint

    env = JuliaWorkspaces._stdlib_only_env()

    # Should be a StaticLint.ExternalEnv
    @test env isa StaticLint.ExternalEnv

    # project_deps should be non-empty and contain core stdlib modules
    @test !isempty(env.project_deps)
    @test :Base in env.project_deps
    @test :Core in env.project_deps

    # The store should contain entries for Base
    @test haskey(env.symbols, :Base)
end

@testitem "derived_static_lint_meta_for_root without project" begin
    using JuliaWorkspaces: filepath2uri, JuliaWorkspace

    # Use the StandaloneFile testdata — a bare .jl file with no Project.toml.
    standalone_root = abspath(joinpath(@__DIR__, "..", "testdata", "StandaloneFile"))

    jw = workspace_from_folders([standalone_root])

    standalone_uri = filepath2uri(joinpath(standalone_root, "standalone.jl"))

    # The file should be found as a root
    root = JuliaWorkspaces.derived_best_root_for_uri(jw.runtime, standalone_uri)
    @test root !== nothing

    # No project URI should be detected (no Project.toml)
    project_uri = JuliaWorkspaces.derived_project_uri_for_root(jw.runtime, root)
    @test project_uri === nothing

    # derived_static_lint_meta_for_root should still succeed (via _stdlib_only_env)
    lint_result = JuliaWorkspaces.derived_static_lint_meta_for_root(jw.runtime, root)
    @test !isempty(lint_result.meta_dict)
    @test isempty(lint_result.workspace_packages)
end

@testitem "derived_package_for_file and derived_project_for_file pick the deepest folder" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_package_for_file, derived_project_for_file,
        derived_package_folders, derived_project_folders
    using JuliaWorkspaces.URIs2: URI

    outer_project = """
    name = "Outer"
    uuid = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    version = "1.0.0"
    """

    inner_project = """
    name = "Inner"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [deps]
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nesting/Project.toml"), SourceText(outer_project, "toml")))
    add_file!(jw, TextFile(URI("file:///nesting/Manifest.toml"), SourceText(manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///nesting/lib/Inner/Project.toml"), SourceText(inner_project, "toml")))
    add_file!(jw, TextFile(URI("file:///nesting/lib/Inner/Manifest.toml"), SourceText(manifest, "toml")))

    @test length(derived_package_folders(jw.runtime)) == 2
    @test length(derived_project_folders(jw.runtime)) == 2

    # A file in the nested package belongs to the nested package, not the outer one
    nested_file = URI("file:///nesting/lib/Inner/src/Inner.jl")
    @test derived_package_for_file(jw.runtime, nested_file) == URI("file:///nesting/lib/Inner")
    @test derived_project_for_file(jw.runtime, nested_file) == URI("file:///nesting/lib/Inner")

    # A file only inside the outer package belongs to the outer package
    outer_file = URI("file:///nesting/src/Outer.jl")
    @test derived_package_for_file(jw.runtime, outer_file) == URI("file:///nesting")
    @test derived_project_for_file(jw.runtime, outer_file) == URI("file:///nesting")

    # A file sitting exactly at a package root
    root_file = URI("file:///nesting/lib/Inner/Project.toml")
    @test derived_package_for_file(jw.runtime, root_file) == URI("file:///nesting/lib/Inner")
    @test derived_project_for_file(jw.runtime, root_file) == URI("file:///nesting/lib/Inner")

    # A file outside of any package or project
    outside_file = URI("file:///somewhere_else/foo.jl")
    @test derived_package_for_file(jw.runtime, outside_file) === nothing
    @test derived_project_for_file(jw.runtime, outside_file) === nothing

    # A file that has no path at all
    untitled_file = URI("untitled:Untitled-1")
    @test derived_package_for_file(jw.runtime, untitled_file) === nothing
    @test derived_project_for_file(jw.runtime, untitled_file) === nothing

    # A sibling prefix must not match: /nesting/libextra is not inside /nesting/lib
    @test derived_package_for_file(jw.runtime, URI("file:///nesting/libextra/Inner/src/Inner.jl")) == URI("file:///nesting")
end

@testitem "non-package manifest-less envs are classified disjointly and found for files" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_package_folders, derived_project_folders, derived_nonpackage_env_folders,
        derived_nonpackage_env, derived_nonpackage_env_for_file
    using JuliaWorkspaces.URIs2: URI

    package_project = """
    name = "Pkg"
    uuid = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    version = "1.0.0"
    """
    env_project = """
    [deps]
    Documenter = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
    """
    manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [deps]
    """

    jw = JuliaWorkspace()
    # /ws/Pkg: package without manifest; /ws/Pkg/docs: non-package env without
    # manifest; /ws/Pkg/benchmark: non-package env WITH manifest (a project).
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Project.toml"), SourceText(package_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/src/Pkg.jl"), SourceText("module Pkg end", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/Project.toml"), SourceText(env_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/make.jl"), SourceText("using Documenter", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/benchmark/Project.toml"), SourceText(env_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/benchmark/Manifest.toml"), SourceText(manifest, "toml")))

    # The three classes are disjoint.
    @test derived_package_folders(jw.runtime) == [URI("file:///ws/Pkg")]
    @test derived_project_folders(jw.runtime) == [URI("file:///ws/Pkg/benchmark")]
    @test derived_nonpackage_env_folders(jw.runtime) == [URI("file:///ws/Pkg/docs")]

    env = derived_nonpackage_env(jw.runtime, URI("file:///ws/Pkg/docs"))
    @test env !== nothing
    @test env.project_file_uri == URI("file:///ws/Pkg/docs/Project.toml")
    # A package folder or a project folder is never a non-package env.
    @test derived_nonpackage_env(jw.runtime, URI("file:///ws/Pkg")) === nothing
    @test derived_nonpackage_env(jw.runtime, URI("file:///ws/Pkg/benchmark")) === nothing

    # Deepest-folder lookup, and sibling prefixes must not match.
    @test derived_nonpackage_env_for_file(jw.runtime, URI("file:///ws/Pkg/docs/make.jl")) == URI("file:///ws/Pkg/docs")
    @test derived_nonpackage_env_for_file(jw.runtime, URI("file:///ws/Pkg/src/Pkg.jl")) === nothing
    @test derived_nonpackage_env_for_file(jw.runtime, URI("file:///ws/Pkg/docsx/make.jl")) === nothing
    @test derived_nonpackage_env_for_file(jw.runtime, URI("untitled:Untitled-1")) === nothing
end

@testitem "a manifest-less non-package env owns its files once resolved and gates until then" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_nonpackage_env, derived_project_uri_for_root, derived_file_env_ready,
        ResolveEnvironmentKey, set_input_resolved_environments!, set_input_failed_dynamic_keys!,
        input_resolved_environments, derived_required_dynamic_projects, DJPKey
    using JuliaWorkspaces.URIs2: URI, uri2filepath

    package_project = """
    name = "Pkg"
    uuid = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    version = "1.0.0"
    """
    env_project = """
    [deps]
    Documenter = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/Pkg/Project.toml"), SourceText(package_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/src/Pkg.jl"), SourceText("module Pkg end", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/Project.toml"), SourceText(env_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Pkg/docs/make.jl"), SourceText("using Documenter", "julia")))

    docs_folder = URI("file:///ws/Pkg/docs")
    make_jl = URI("file:///ws/Pkg/docs/make.jl")
    env = derived_nonpackage_env(jw.runtime, docs_folder)
    @test env !== nothing
    # Match production key construction (uri2filepath uses `\` on Windows).
    key = ResolveEnvironmentKey(uri2filepath(docs_folder), env.content_hash)

    # The resolve work item is scheduled, so diagnostics for the file gate ...
    @test key in derived_required_dynamic_projects(jw.runtime)
    @test !derived_file_env_ready(jw.runtime, make_jl)
    # ... and selection falls through (no resolved env yet, no active project).
    @test derived_project_uri_for_root(jw.runtime, make_jl) === nothing
    # A file of the enclosing package is unaffected by the pending env.
    @test derived_file_env_ready(jw.runtime, URI("file:///ws/Pkg/src/Pkg.jl"))

    # Once the resolved scratch project is recorded, it owns the file and
    # readiness settles.
    scratch = URI("file:///scratch/env-docs-1234")
    set_input_resolved_environments!(jw.runtime, Dict(key => scratch))
    @test derived_project_uri_for_root(jw.runtime, make_jl) == scratch
    @test derived_file_env_ready(jw.runtime, make_jl)

    # A terminal failure also settles readiness (best-effort diagnostics).
    set_input_resolved_environments!(jw.runtime, Dict{ResolveEnvironmentKey,typeof(scratch)}())
    set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([key]))
    @test derived_file_env_ready(jw.runtime, make_jl)
    @test derived_project_uri_for_root(jw.runtime, make_jl) === nothing
end

@testitem "derived_project with Manifest.toml but no Project.toml does not crash" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_diagnostics
    using JuliaWorkspaces.URIs2: URI

    # A folder that has only a Manifest.toml (no Project.toml) mimics a
    # DJP-created temp project directory (e.g. /tmp/jl_xxxxxx) whose
    # Project.toml is missing or was deleted. The lazy
    # `derived_project_toml_files` probe used for the active project can
    # then return `(project_file=nothing, manifest_file=<uri>)`.
    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    folder_uri = URI("file:///manifestonlyprojecttest")
    manifest_uri = URI("file:///manifestonlyprojecttest/Manifest.toml")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(manifest_uri, SourceText(manifest_toml, "toml")))

    JuliaWorkspaces.set_active_project!(jw, folder_uri)

    # A folder without a Project.toml is not a project, even if it has a
    # Manifest.toml.
    @test JuliaWorkspaces.derived_project(jw.runtime, folder_uri) === nothing

    # This is the crash path: get_diagnostics used to throw a `FieldError`
    # (accessing `.scheme` on `nothing`) because `derived_project` reached
    # `derived_text_file_content(rt, project_file)` with `project_file ===
    # nothing`.
    get_diagnostics(jw)
end

@testitem "derived_project prefers the manifest for the running Julia version" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, derived_project
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"

    [deps]
    """

    manifest_toml(julia_version) = """
    julia_version = "$julia_version"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    versioned_name = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
    foreign_name = "Manifest-v$(VERSION.major).$(VERSION.minor + 1).toml"

    # All three manifests in one folder: Pkg would use the version-specific one,
    # and so must we — the caches we look up are keyed by the entries of the
    # manifest this Julia version resolves against.
    folder_uri = URI("file:///versionedmanifesttest")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///versionedmanifesttest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///versionedmanifesttest/Manifest.toml"), SourceText(manifest_toml("1.0.0"), "toml")))
    add_file!(jw, TextFile(URI("file:///versionedmanifesttest/$foreign_name"), SourceText(manifest_toml("1.0.0"), "toml")))
    add_file!(jw, TextFile(URI("file:///versionedmanifesttest/$versioned_name"), SourceText(manifest_toml(string(VERSION)), "toml")))

    project = derived_project(jw.runtime, folder_uri)
    @test project !== nothing
    @test endswith(string(project.manifest_file_uri), versioned_name)
    @test project.julia_version == VERSION

    # A manifest for another Julia version is not bound at all: we can only
    # index an environment resolved for the Julia version we run under, so this
    # folder counts as having no manifest rather than as a wrongly-keyed one.
    other_uri = URI("file:///foreignmanifesttest")
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///foreignmanifesttest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///foreignmanifesttest/$foreign_name"), SourceText(manifest_toml("1.0.0"), "toml")))

    @test derived_project(jw2.runtime, other_uri) === nothing
end
