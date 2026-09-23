@testitem "DJP runtime: children never precompile, preparation always may" begin
    using JuliaWorkspaces: _djp_process_env

    child = _djp_process_env(disable_precompile_auto=true)
    warmup = _djp_process_env(disable_precompile_auto=false)

    # The point of the whole change: an indexing child imports packages to read
    # their metadata, so it must not drag a full environment precompile (and
    # its one-worker-per-core fan-out) along with every `Pkg.instantiate`.
    @test child["JULIA_PKG_PRECOMPILE_AUTO"] == "0"
    # The preparation process is the one caller that must be allowed to build
    # caches; inheriting a 0 from the host would silently defeat it.
    @test !haskey(warmup, "JULIA_PKG_PRECOMPILE_AUTO")

    for env in (child, warmup)
        # Depot auto-gc races other processes rewriting the usage TOML files.
        @test env["JULIA_PKG_GC_AUTO"] == "false"
        # An inherited load path/project would stop the child resolving @.
        @test !haskey(env, "JULIA_LOAD_PATH")
        @test !haskey(env, "JULIA_PROJECT")
        @test !haskey(env, "JULIA_DEPOT_PATH")
    end

    # Preparation must warm the same depot the children read, so the rest of
    # the environment has to be identical.
    @test setdiff(keys(child), keys(warmup)) == Set(["JULIA_PKG_PRECOMPILE_AUTO"])
end

@testitem "DJP runtime: cache-free launch flags are opt-in" begin
    using JuliaWorkspaces: DjpRuntime, _djp_launch_flags

    @test _djp_launch_flags(DjpRuntime("julia", v"1.12.0", "p", true)) ==
        ["--compiled-modules=existing"]
    # An unprepared runtime must launch children the old way, so a child whose
    # own environment has no caches can still build them instead of re-loading
    # Revise and friends from source on every single launch.
    @test _djp_launch_flags(DjpRuntime("julia", v"1.12.0", "p", false)) == String[]
end

@testitem "DJP runtime: the child command carries the cache-free contract" begin
    using JuliaWorkspaces: DjpRuntime, _djp_child_cmd

    script = joinpath("app", "main.jl")
    pipe = "pipe-name"

    prepared = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", true), script, pipe)
    args = collect(prepared.exec)
    @test args[1] == "jlx"
    @test "--compiled-modules=existing" in args
    # Order matters: julia stops parsing options at the script path.
    @test findfirst(==("--compiled-modules=existing"), args) < findfirst(==(script), args)
    @test args[end] == pipe
    # Whatever else changes, a child must never precompile an environment.
    @test "JULIA_PKG_PRECOMPILE_AUTO=0" in prepared.env

    # An unprepared runtime still launches, just without cache-free loading.
    plain = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", false), script, pipe)
    @test !("--compiled-modules=existing" in collect(plain.exec))
    @test "JULIA_PKG_PRECOMPILE_AUTO=0" in plain.env

    # Trailing child arguments (error handler, crash pipe) keep their order
    # after the pipe name.
    with_extra = _djp_child_cmd(DjpRuntime("jlx", v"1.12.0", "p", true), script, pipe,
        String["handler.jl", "crashpipe"])
    @test collect(with_extra.exec)[end-2:end] == [pipe, "handler.jl", "crashpipe"]
end

@testitem "DJP runtime: the check selects the environment the child script selects" begin
    using JuliaWorkspaces: _check_djp_julia, default_djp_julia_exe, _djp_environments_dir, _djp_main_script

    # The check has to prepare the environment the child will actually run in,
    # so its selection must match `julia_dynamic_analysis_process_main.jl`.
    # Guard the child script side against drifting away from that shape.
    main_script = read(_djp_main_script(), String)
    @test occursin("\"v\$(VERSION.major).\$(VERSION.minor)\", \"Project.toml\"", main_script)
    @test occursin("\"fallback\"", main_script)

    checked = _check_djp_julia(default_djp_julia_exe())
    if VERSION < v"1.11"
        # This Julia rejects --compiled-modules=existing, which the check
        # launches with, so it must report that it cannot run cache-free.
        @test checked === nothing
    else
        @test checked !== nothing
        version, project, precompiled = checked
        # Reported by the child Julia, not assumed from the host.
        @test version == VERSION
        @test precompiled isa Bool
        env_dir = _djp_environments_dir()
        versioned = joinpath(env_dir, "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
        expected = isfile(versioned) ? versioned : joinpath(env_dir, "fallback")
        @test normpath(project) == normpath(expected)
    end
end

@testitem "DJP runtime: an executable that cannot answer is not guessed at" begin
    using JuliaWorkspaces: _check_djp_julia, djp_runtime, _reset_djp_runtime_cache!

    missing_exe = joinpath("nonexistent", "julia-does-not-exist")
    @test _check_djp_julia(missing_exe) === nothing

    # Such a runtime still launches children, just the way they always were.
    _reset_djp_runtime_cache!()
    try
        runtime = djp_runtime(missing_exe)
        @test !runtime.use_existing_caches
        @test runtime.version === nothing
        @test runtime.project === nothing
    finally
        _reset_djp_runtime_cache!()
    end
end

@testitem "DJP runtime: resolution runs once per process and only reports real preparation" begin
    using JuliaWorkspaces: djp_runtime, default_djp_julia_exe, _reset_djp_runtime_cache!, _DJP_RUNTIME_CACHE

    exe = default_djp_julia_exe()
    reports = Tuple{String,Int}[]
    progress = (message, percentage) -> push!(reports, (message, percentage))

    _reset_djp_runtime_cache!()
    try
        first_result = djp_runtime(exe; progress)
        @test first_result.exe == exe
        @test haskey(_DJP_RUNTIME_CACHE, exe)
        if VERSION >= v"1.11"
            @test first_result.version == VERSION
            @test first_result.project !== nothing
            # The child environment precompiles cleanly on every supported
            # version (see test_dynamic_process_precompile.jl), so preparing it
            # has to succeed and children have to end up cache-free.
            @test first_result.use_existing_caches
        else
            @test !first_result.use_existing_caches
        end

        # Progress appears only when the environment actually had to be
        # prepared, and a bar that was started is always ended.
        @test isempty(reports) || (first(reports)[2] == 0 && last(reports)[2] == 100)

        # Memoized: a second call launches nothing and reports nothing.
        count_before = length(reports)
        @test djp_runtime(exe; progress) == first_result
        @test length(reports) == count_before
    finally
        _reset_djp_runtime_cache!()
    end
end

@testitem "DJP runtime: reactor start resolves ahead only when it will launch real children" begin
    using JuliaWorkspaces: DynamicFeature, DynamicIndexingOnly, DynamicPersistent, DynamicOff,
        _should_prewarm_djp_runtime

    @test _should_prewarm_djp_runtime(DynamicFeature(DynamicIndexingOnly, mktempdir()))
    @test _should_prewarm_djp_runtime(DynamicFeature(DynamicPersistent, mktempdir()))
    # A download-only workspace never launches a child.
    @test !_should_prewarm_djp_runtime(DynamicFeature(DynamicOff, mktempdir()))
    # Reactor tests inject a launcher and must never spawn a Julia process.
    @test !_should_prewarm_djp_runtime(
        DynamicFeature(DynamicIndexingOnly, mktempdir(); launcher=(df, djp) -> nothing))
end
