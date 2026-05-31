# Tests for include-graph diagnostics: `DuplicateInclude`, `IncludeLoop` and
# `MissingFile`.
#
# Each scenario lives as a self-contained folder under
# `testdata/include_scenarios/`. The tests load the relevant folder into a
# `JuliaWorkspace` and inspect the diagnostics produced for individual files,
# rather than writing temporary files at test time.

@testmodule shared_include_diagnostics begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    const StaticLint = JuliaWorkspaces.StaticLint

    const SCENARIO_DIR = abspath(joinpath(@__DIR__, "..", "..", "testdata", "include_scenarios"))

    export load_scenario, has_lint_code, file_uri
    export DuplicateInclude, IncludeLoop, MissingFile

    const DuplicateInclude = StaticLint.DuplicateInclude
    const IncludeLoop = StaticLint.IncludeLoop
    const MissingFile = StaticLint.MissingFile

    # Load a scenario folder from `testdata/include_scenarios/` into a fresh
    # workspace.
    function load_scenario(scenario::AbstractString)
        jw = JuliaWorkspace()
        add_folder_from_disc!(jw, joinpath(SCENARIO_DIR, scenario))
        return jw
    end

    # URI of a file (given by path components relative to the scenario folder).
    function file_uri(scenario::AbstractString, relpath::AbstractString...)
        return filepath2uri(joinpath(SCENARIO_DIR, scenario, relpath...))
    end

    # Does any diagnostic reported for the given file correspond to `code`?
    # The static-lint layer reports `LintCodes` errors using the human readable
    # description from `LintCodeDescriptions`, so we match against that.
    function has_lint_code(jw, uri::URI, code::StaticLint.LintCodes)
        diags = get_diagnostic(jw, uri)
        desc = StaticLint.LintCodeDescriptions[code]
        return any(d -> d.message == desc, diags)
    end
end

@testitem "include: duplicate include is reported" setup=[shared_include_diagnostics] begin
    jw = load_scenario("duplicate_include")
    main = file_uri("duplicate_include", "main.jl")

    @test has_lint_code(jw, main, DuplicateInclude)
    @test !has_lint_code(jw, main, IncludeLoop)
end

@testitem "include: circular include is reported" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_include")
    main = file_uri("circular_include", "main.jl")

    @test has_lint_code(jw, main, IncludeLoop)
end

@testitem "include: circular include via ./ is reported on every file" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_include_relative")

    @test has_lint_code(jw, file_uri("circular_include_relative", "main.jl"), IncludeLoop)
    @test has_lint_code(jw, file_uri("circular_include_relative", "a.jl"), IncludeLoop)
    @test has_lint_code(jw, file_uri("circular_include_relative", "b.jl"), IncludeLoop)
end

@testitem "include: self-include is reported as a loop" setup=[shared_include_diagnostics] begin
    jw = load_scenario("self_include")
    main = file_uri("self_include", "main.jl")

    @test has_lint_code(jw, main, IncludeLoop)
end

@testitem "include: no false positives when each file included once" setup=[shared_include_diagnostics] begin
    jw = load_scenario("no_false_positive")
    main = file_uri("no_false_positive", "main.jl")

    @test !has_lint_code(jw, main, IncludeLoop)
    @test !has_lint_code(jw, main, DuplicateInclude)
end

@testitem "include: normpath with .. resolves duplicate include" setup=[shared_include_diagnostics] begin
    jw = load_scenario("normpath_dotdot")
    main = file_uri("normpath_dotdot", "src", "main.jl")

    @test has_lint_code(jw, main, DuplicateInclude)
    @test !has_lint_code(jw, main, IncludeLoop)
    @test !has_lint_code(jw, main, MissingFile)
end

@testitem "include: ./file resolves the same as file" setup=[shared_include_diagnostics] begin
    jw = load_scenario("normpath_dot")
    main = file_uri("normpath_dot", "main.jl")

    @test has_lint_code(jw, main, DuplicateInclude)
    @test !has_lint_code(jw, main, MissingFile)
end

@testitem "include: circular include via .. is detected" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_dotdot")
    main = file_uri("circular_dotdot", "main.jl")

    @test has_lint_code(jw, main, IncludeLoop)
end
