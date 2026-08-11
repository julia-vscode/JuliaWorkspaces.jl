# Environment-loading fixes from the 2026-08 lint-sweep follow-up:
#
#   * every file under a package's `test/` folder is analyzed against the
#     merged test environment — the `[extras]`+`[targets]` layout only exists
#     there, and helper files routinely become their own roots via computed
#     `include` paths in runtests.jl;
#   * a `<pkg>/test` folder with its own Project.toml is covered by the
#     test-env work item alone (the resolve item is only a fallback after the
#     test env failed terminally);
#   * infra failures (request timeouts, dead children) are retried once and
#     never surface as environment_errors diagnostics.

@testitem "env routing: all files under test/ get the merged test environment" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_package, derived_file_env_ready,
        derived_required_dynamic_projects, derived_project_uri_for_root,
        _test_environment_key, TestEnvironmentReadyResult
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = [
        joinpath(dir, "Project.toml") => ("""
        name = "ExtrasRouting"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee48"
        version = "0.1.0"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """, "toml"),
        joinpath(dir, "src", "ExtrasRouting.jl") => ("module ExtrasRouting\nend\n", "julia"),
        joinpath(dir, "test", "runtests.jl") => ("for t in [\"helper.jl\"]; include(t); end\n", "julia"),
        # No @testitem, not statically reachable from runtests.jl: this is the
        # shape that used to fall back to the package's own environment.
        joinpath(dir, "test", "helper.jl") => ("using Test\n", "julia"),
    ]

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    package_uri = filepath2uri(dir)
    key = _test_environment_key(jw.runtime, package_uri, derived_package(jw.runtime, package_uri))
    @test key in derived_required_dynamic_projects(jw.runtime)

    helper_uri = filepath2uri(joinpath(dir, "test", "helper.jl"))
    src_uri = filepath2uri(joinpath(dir, "src", "ExtrasRouting.jl"))

    # The helper file needs the pending test env, so it must gate.
    @test !derived_file_env_ready(jw.runtime, helper_uri)

    merged_uri = filepath2uri(joinpath(mktempdir(), "merged"))
    put!(jw.dynamic_feature.out_channel, TestEnvironmentReadyResult(
        filepath2uri(key.project_path), key.package_name, merged_uri, key.content_hash))
    process_from_dynamic(jw)

    @test derived_file_env_ready(jw.runtime, helper_uri)
    @test derived_project_uri_for_root(jw.runtime, helper_uri) == merged_uri
    # src/ files must NOT be routed to the test environment.
    @test derived_project_uri_for_root(jw.runtime, src_uri) != merged_uri
end

@testitem "env scheduling: a test/Project.toml folder is covered by the test-env item" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_package, derived_nonpackage_env,
        derived_required_dynamic_projects, derived_project_uri_for_root,
        _test_environment_key, ResolveEnvironmentKey, TestEnvironmentReadyResult,
        ResolvedEnvironmentReadyResult, FailedResult, DJPKey
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = [
        joinpath(dir, "Project.toml") => ("""
        name = "CoveredTestEnv"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee49"
        version = "0.1.0"
        """, "toml"),
        joinpath(dir, "src", "CoveredTestEnv.jl") => ("module CoveredTestEnv\nend\n", "julia"),
        joinpath(dir, "test", "Project.toml") => ("""
        [deps]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """, "toml"),
        joinpath(dir, "test", "runtests.jl") => ("using Test\n", "julia"),
    ]

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    package_uri = filepath2uri(dir)
    test_dir = joinpath(dir, "test")
    env_uri = filepath2uri(test_dir)
    env = derived_nonpackage_env(jw.runtime, env_uri)
    @test env !== nothing
    resolve_key = ResolveEnvironmentKey(test_dir, env.content_hash)

    test_key = _test_environment_key(jw.runtime, package_uri, derived_package(jw.runtime, package_uri))

    # The test-env item covers the folder; no duplicate resolve item.
    required = derived_required_dynamic_projects(jw.runtime)
    @test test_key in required
    @test !(resolve_key in required)

    # Preference: with both a resolved copy and the merged test env ready,
    # files under test/ use the merged test env (it also devs the package).
    resolved_uri = filepath2uri(joinpath(mktempdir(), "resolved"))
    merged_uri = filepath2uri(joinpath(mktempdir(), "merged"))
    put!(jw.dynamic_feature.out_channel, ResolvedEnvironmentReadyResult(env_uri, resolved_uri, env.content_hash))
    put!(jw.dynamic_feature.out_channel, TestEnvironmentReadyResult(
        filepath2uri(test_key.project_path), test_key.package_name, merged_uri, test_key.content_hash))
    process_from_dynamic(jw)

    runtests_uri = filepath2uri(joinpath(test_dir, "runtests.jl"))
    @test derived_project_uri_for_root(jw.runtime, runtests_uri) == merged_uri
end

@testitem "env scheduling: the resolve item is the fallback after a failed test env" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_package, derived_nonpackage_env,
        derived_required_dynamic_projects, _test_environment_key,
        ResolveEnvironmentKey, FailedResult
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = [
        joinpath(dir, "Project.toml") => ("""
        name = "FallbackResolve"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee50"
        version = "0.1.0"
        """, "toml"),
        joinpath(dir, "src", "FallbackResolve.jl") => ("module FallbackResolve\nend\n", "julia"),
        joinpath(dir, "test", "Project.toml") => ("""
        [deps]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """, "toml"),
        joinpath(dir, "test", "runtests.jl") => ("using Test\n", "julia"),
    ]

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    package_uri = filepath2uri(dir)
    test_dir = joinpath(dir, "test")
    env = derived_nonpackage_env(jw.runtime, filepath2uri(test_dir))
    resolve_key = ResolveEnvironmentKey(test_dir, env.content_hash)
    test_key = _test_environment_key(jw.runtime, package_uri, derived_package(jw.runtime, package_uri))

    @test !(resolve_key in derived_required_dynamic_projects(jw.runtime))

    put!(jw.dynamic_feature.out_channel, FailedResult(test_key))
    process_from_dynamic(jw)

    @test resolve_key in derived_required_dynamic_projects(jw.runtime)
end

@testitem "Dynamic failures: a timeout is retried once and never becomes a diagnostic" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, DJPKey, DJPRequestTimeoutException, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=2, launcher=(df, djp) -> push!(launches, djp.key))

    k = WatchTestEnvironmentKey("/ws/R", "R", UInt64(1))
    timeout = DJPRequestTimeoutException(k, "indexProject", 300)

    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    @test length(launches) == 1

    # First timeout: retried in place — no result surfaces, item stays inflight.
    handle!(df, ProcessIndexFailedMsg(k, timeout))
    @test length(launches) == 2
    @test !isready(df.out_channel)
    @test k in df.inflight
    @test !(k in df.failed_projects)

    # Second timeout: terminal, but as an infra failure — the FailedResult
    # settles readiness with NO user-facing message (no environment_errors
    # diagnostic), and the replay message is empty too.
    handle!(df, ProcessIndexFailedMsg(k, timeout))
    @test length(launches) == 2
    @test isready(df.out_channel)
    result = take!(df.out_channel)
    @test result isa FailedResult
    @test result.key == k
    @test isempty(result.message)
    @test k in df.failed_projects
    @test df.pending_count[] == 0
    @test isempty(df.inflight)

    # The exhausted-skip replay must not resurrect a message either.
    k2 = WatchTestEnvironmentKey("/ws/R", "R", UInt64(2))
    handle!(df, ReconcileMsg(Set{DJPKey}([k2])))
    @test length(launches) == 2
    result2 = take!(df.out_channel)
    @test result2 isa FailedResult
    @test isempty(result2.message)
end

@testitem "Dynamic failures: a Pkg error still becomes a diagnostic message" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexFailedMsg,
        WatchTestEnvironmentKey, DJPKey, FailedResult, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_failure_attempts=2, launcher=(df, djp) -> push!(launches, djp.key))

    k = WatchTestEnvironmentKey("/ws/R", "R", UInt64(1))
    handle!(df, ReconcileMsg(Set{DJPKey}([k])))
    handle!(df, ProcessIndexFailedMsg(k, ErrorException("Unsatisfiable requirements detected for package JET")))

    # A genuine package problem is terminal on the first failure and carries
    # its message into the environment_errors diagnostic.
    @test length(launches) == 1
    result = take!(df.out_channel)
    @test result isa FailedResult
    @test occursin("Unsatisfiable requirements", result.message)
end
