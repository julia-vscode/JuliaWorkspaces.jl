@testitem "The dynamic analysis process environment precompiles cleanly" begin
    # `JuliaDynamicAnalysisProcess` assembles the vendored packages by hand, inlining each
    # one's `packagedef.jl` as a submodule. Those files are swept along with upstream by
    # `scripts/update_vendored_packages.jl`, so a release that adds a dependency adds it to
    # *our* package — and if it is missing from our Project.toml the whole thing stops
    # precompiling, on every supported Julia version at once.
    #
    # Nothing else in this suite notices. The child process swallows the failure on its own
    # stderr, which the parent forwards only to `@debug`; what reaches the user is a
    # `DynamicProcessCrashException` per work item and a dead dynamic feature. That is how
    # Revise 3.9's `using CRC32c: crc32c` went unnoticed for three weeks. Assert the cache
    # is actually built instead.
    env_dir = normpath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess", "environments"))
    versioned = joinpath(env_dir, "v$(VERSION.major).$(VERSION.minor)")
    project = isdir(versioned) ? versioned : joinpath(env_dir, "fallback")

    # `Base.compilecache` rather than `Pkg.precompile`: it rebuilds unconditionally, so a
    # cache some other process already wrote cannot short-circuit the check, and it reports
    # a failure as a `Core.PrecompilableError` return value — `Pkg.precompile` reports one
    # as a `?` in its progress list and still exits 0.
    code = """
        result = Base.compilecache(Base.identify_package("JuliaDynamicAnalysisProcess"))
        result isa Tuple || exit(1)
        """
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia --startup-file=no --history-file=no --project=$project -e $code`

    io = IOBuffer()
    process = run(pipeline(ignorestatus(cmd), stdout=io, stderr=io))
    output = String(take!(io))

    if !success(process)
        println("── precompiling JuliaDynamicAnalysisProcess in $project ──")
        println(output)
    end

    @test success(process)
end
