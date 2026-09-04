# Environment routing for the shapes the Pkg.jl work made expressible:
# nested packages deved by a workspace root, deeper env folders under test/,
# scripts with no environment of their own (the fallback project + @stdlib),
# and terminally failed environments as analysis boundaries.

@testsnippet EnvFallbackWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_diagnostic,
        derived_project_uri_for_root, derived_package, derived_nonpackage_env,
        WatchTestEnvironmentKey, ResolveEnvironmentKey, DJPKey,
        set_input_ready_test_environments!, set_input_resolved_environments!,
        set_input_failed_dynamic_keys!, set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI, uri2filepath

    const EF_PROJECT = "name = \"EfPkg\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9b1\"\nversion = \"1.0.0\"\n"
    const EF_MANIFEST = "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n"

    function ef_workspace(; config=nothing)
        jw = JuliaWorkspace()
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///ef/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(URI("file:///ef/Project.toml"), SourceText(EF_PROJECT, "toml")))
        add_file!(jw, TextFile(URI("file:///ef/Manifest.toml"), SourceText(EF_MANIFEST, "toml")))
        add_file!(jw, TextFile(URI("file:///ef/src/EfPkg.jl"), SourceText("module EfPkg\nend\n", "julia")))
        JW.set_v2_enabled!(jw, true)
        return jw
    end
    ef_ui(jw, uri) = [d.message for d in get_diagnostic(jw, uri) if d.code === :unresolved_import]
end

@testitem "env routing: a package deved by a workspace root tests in that root" setup=[EnvFallbackWS] begin
    root_project = "name = \"Root\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1\"\nversion = \"1.0.0\"\n"
    root_manifest = """
    julia_version = "1.12.0"
    manifest_format = "2.0"
    project_hash = "x"

    [[deps.Root]]
    path = "."
    uuid = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1"
    version = "1.0.0"

    [[deps.Sub]]
    path = "lib/Sub"
    uuid = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2"
    version = "0.1.0"
    """
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mono/Project.toml"), SourceText(root_project, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/Manifest.toml"), SourceText(root_manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/src/Root.jl"), SourceText("module Root end\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Sub/Project.toml"), SourceText(
        "name = \"Sub\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Sub/src/Sub.jl"), SourceText("module Sub end\n", "julia")))
    test_file = URI("file:///mono/lib/Sub/test/runtests.jl")
    add_file!(jw, TextFile(test_file, SourceText("using Test, SafeTestsets\n", "julia")))

    sub = URI("file:///mono/lib/Sub")
    pkg = derived_package(jw.runtime, sub)
    root_hash = JW.derived_project(jw.runtime, URI("file:///mono")).content_hash
    # The test environment is materialized in the deving project (the root),
    # not in a non-existent active project.
    key = JW._test_environment_key(jw.runtime, sub, pkg)
    @test key == WatchTestEnvironmentKey(uri2filepath(URI("file:///mono")), "Sub", root_hash)
    # Once its result arrives the test file routes there.
    scratch = URI("file:///scratch/test-env-Sub")
    set_input_ready_test_environments!(jw.runtime, Dict(key => scratch))
    @test derived_project_uri_for_root(jw.runtime, test_file) == scratch
end

@testitem "env routing: a deeper env folder wins over the merged test env; scripts take the fallback" setup=[EnvFallbackWS] begin
    jw = ef_workspace()
    add_file!(jw, TextFile(URI("file:///ef/test/runtests.jl"), SourceText("using Test\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ef/test/qa/Project.toml"), SourceText(
        "[deps]\nJET = \"c3a54625-cd67-489e-a8e7-0a5a0ff4e31b\"\n", "toml")))
    qa = URI("file:///ef/test/qa/qa.jl")
    add_file!(jw, TextFile(qa, SourceText("using JET\n", "julia")))
    perf = URI("file:///ef/perf/bench.jl")
    add_file!(jw, TextFile(perf, SourceText("using Test\n", "julia")))
    build = URI("file:///ef/deps/build.jl")
    add_file!(jw, TextFile(build, SourceText("using Test\n", "julia")))

    pkg = derived_package(jw.runtime, URI("file:///ef"))
    test_key = JW._test_environment_key(jw.runtime, URI("file:///ef"), pkg)
    test_scratch = URI("file:///scratch/test-env-EfPkg")
    set_input_ready_test_environments!(jw.runtime, Dict(test_key => test_scratch))
    @test derived_project_uri_for_root(jw.runtime, URI("file:///ef/test/runtests.jl")) == test_scratch
    # test/qa/ has its own Project.toml: pending, the merged test env stands in…
    @test derived_project_uri_for_root(jw.runtime, qa) == test_scratch
    # …resolved, it is the environment those files are run with.
    env = derived_nonpackage_env(jw.runtime, URI("file:///ef/test/qa"))
    qa_key = ResolveEnvironmentKey(uri2filepath(URI("file:///ef/test/qa")), env.content_hash)
    qa_scratch = URI("file:///scratch/env-qa")
    set_input_resolved_environments!(jw.runtime, Dict(qa_key => qa_scratch))
    @test derived_project_uri_for_root(jw.runtime, qa) == qa_scratch

    # A script under the package (perf/) has no environment of its own: it is
    # checked against the fallback (the active project — none here), like a
    # file outside any package; deps/build.jl runs in the package project.
    @test derived_project_uri_for_root(jw.runtime, perf) === nothing
    @test derived_project_uri_for_root(jw.runtime, build) == URI("file:///ef")
    @test JW.derived_file_stdlibs_visible(jw.runtime, perf)
    @test JW.derived_file_stdlibs_visible(jw.runtime, URI("file:///ef/test/runtests.jl"))
    @test !JW.derived_file_stdlibs_visible(jw.runtime, URI("file:///ef/src/EfPkg.jl"))
    @test !JW.derived_file_stdlibs_visible(jw.runtime, build)
end

@testitem "unresolved_import: stdlibs resolve wherever @stdlib is on the load path" setup=[EnvFallbackWS] begin
    jw = ef_workspace()
    set_input_env_ready!(jw.runtime, true)
    src = URI("file:///ef/src/uses_test.jl")
    JW.update_file!(jw, TextFile(URI("file:///ef/src/EfPkg.jl"), SourceText("module EfPkg\ninclude(\"uses_test.jl\")\nend\n", "julia")))
    add_file!(jw, TextFile(src, SourceText("using Test\n", "julia")))
    perf = URI("file:///ef/perf/bench.jl")
    add_file!(jw, TextFile(perf, SourceText("using Test\nusing NoSuchPkg_xyz\n", "julia")))
    tst = URI("file:///ef/test/runtests.jl")
    add_file!(jw, TextFile(tst, SourceText("using Test\n", "julia")))

    # Package code must declare its stdlib dependency (Test is not in the manifest).
    @test any(occursin("`Test`", m) for m in ef_ui(jw, src))
    # A script and a test file always see @stdlib; a non-stdlib package in a
    # script is still checked against the fallback (none here).
    @test ef_ui(jw, perf) == ["Failed to resolve `NoSuchPkg_xyz`. Missing-reference checks are disabled in this scope and all nested scopes."]
    @test isempty(ef_ui(jw, tst))
end

@testitem "unresolved_import: a terminally failed environment is a boundary, not a defect" setup=[EnvFallbackWS] begin
    for config in (nothing, "[rules]\nanalysis_boundary = \"warning\"\n")
        jw = ef_workspace(; config)
        set_input_env_ready!(jw.runtime, true)
        add_file!(jw, TextFile(URI("file:///ef/docs/Project.toml"), SourceText(
            "[deps]\nDocumenter = \"e30172f5-a6a5-5a46-863b-614d45cd2de4\"\n", "toml")))
        make = URI("file:///ef/docs/make.jl")
        add_file!(jw, TextFile(make, SourceText("using Documenter\n", "julia")))
        env = derived_nonpackage_env(jw.runtime, URI("file:///ef/docs"))
        key = ResolveEnvironmentKey(uri2filepath(URI("file:///ef/docs")), env.content_hash)
        # Pending or unscheduled: not failed.
        @test !JW.derived_file_env_failed(jw.runtime, make)
        set_input_failed_dynamic_keys!(jw.runtime, Set{DJPKey}([key]))
        @test JW.derived_file_env_failed(jw.runtime, make)
        diags = get_diagnostic(jw, make)
        @test !any(d -> d.code === :unresolved_import, diags)
        notices = filter(d -> d.code === :analysis_boundary, diags)
        if config === nothing
            @test isempty(notices)
        else
            @test length(notices) == 1
            @test occursin("could not be resolved", only(notices).message)
        end
    end
end
