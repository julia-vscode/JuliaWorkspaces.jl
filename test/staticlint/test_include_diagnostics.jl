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

    # Does any file in the workspace report a diagnostic corresponding to `code`?
    #
    # Include diagnostics are attached to the `include(...)` statement that
    # triggers them, which lives in whichever file contains that statement (e.g.
    # a circular include is reported on the file holding the loop-closing
    # `include`, not necessarily the root). The legacy StaticLint tests likewise
    # asserted detection across the whole include tree (`any(h -> ..., hints)`),
    # so we scan every Julia file in the workspace.
    #
    # The static-lint layer reports `LintCodes` errors using the human readable
    # description from `LintCodeDescriptions`, so we match against that.
    function has_lint_code(jw, code::StaticLint.LintCodes)
        desc = StaticLint.LintCodeDescriptions[code]
        for uri in get_julia_files(jw)
            diags = get_diagnostic(jw, uri)
            if any(d -> d.message == desc, diags)
                return true
            end
        end
        return false
    end
end

@testitem "include: duplicate include is reported" setup=[shared_include_diagnostics] begin
    jw = load_scenario("duplicate_include")

    @test has_lint_code(jw, DuplicateInclude)
    @test !has_lint_code(jw, IncludeLoop)
end

@testitem "include: circular include is reported" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_include")

    @test has_lint_code(jw, IncludeLoop)
end

@testitem "include: circular include via ./ is detected" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_include_relative")

    @test has_lint_code(jw, IncludeLoop)
end

@testitem "include: self-include is reported as a loop" setup=[shared_include_diagnostics] begin
    jw = load_scenario("self_include")

    @test has_lint_code(jw, IncludeLoop)
end

@testitem "include: no false positives when each file included once" setup=[shared_include_diagnostics] begin
    jw = load_scenario("no_false_positive")

    @test !has_lint_code(jw, IncludeLoop)
    @test !has_lint_code(jw, DuplicateInclude)
end

@testitem "include: normpath with .. resolves duplicate include" setup=[shared_include_diagnostics] begin
    jw = load_scenario("normpath_dotdot")

    @test has_lint_code(jw, DuplicateInclude)
    @test !has_lint_code(jw, IncludeLoop)
    @test !has_lint_code(jw, MissingFile)
end

@testitem "include: ./file resolves the same as file" setup=[shared_include_diagnostics] begin
    jw = load_scenario("normpath_dot")

    @test has_lint_code(jw, DuplicateInclude)
    @test !has_lint_code(jw, MissingFile)
end

@testitem "include: circular include via .. is detected" setup=[shared_include_diagnostics] begin
    jw = load_scenario("circular_dotdot")

    @test has_lint_code(jw, IncludeLoop)
end

@testitem "include: joinpath with string literals resolves (#311)" setup=[shared_include_diagnostics] begin
    # `include(joinpath("subdir", "myfile.jl"))` must resolve like
    # `include("subdir/myfile.jl")`: the file is loaded, its bindings are
    # visible, and no MissingFile is reported.
    jw = load_scenario("joinpath_resolve")

    @test !has_lint_code(jw, MissingFile)
    # the included file is actually part of the workspace
    @test any(u -> endswith(string(u), "subdir/myfile.jl"), get_julia_files(jw))
    # `foo` (defined in the included file) resolves — no missing-reference diag
    main = file_uri("joinpath_resolve", "main.jl")
    @test !any(d -> startswith(d.message, "Missing reference"), get_diagnostic(jw, main))
end

@testitem "include: joinpath and string resolve to same path (#311)" setup=[shared_include_diagnostics] begin
    # Including the same file via a plain string and via joinpath must resolve to
    # the same path, detected as a DuplicateInclude.
    jw = load_scenario("joinpath_duplicate")

    @test has_lint_code(jw, DuplicateInclude)
    @test !has_lint_code(jw, MissingFile)
end
