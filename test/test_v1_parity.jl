# Flag-off parity: with `input_v2_enabled` at its default (`false`) the package
# behaves exactly as on `main`. `scripts/check_v1_parity.sh` checks the source
# structure against the base branch (v1 files byte-identical or gate lines
# only); these items pin the run-time side of the same contract.

@testitem "v1 parity: the v2 gates are exactly the allowlisted call sites" begin
    # Every read of the flag outside the v2-only files is one of the known
    # gates — a new read anywhere else is a new v1/v2 fork that the parity
    # script and this allowlist must learn about together.
    src = joinpath(pkgdir(JuliaWorkspaces), "src")
    counts = Dict{String,Int}()
    for (root, _, files) in walkdir(src), f in files
        endswith(f, ".jl") || continue
        rel = replace(relpath(joinpath(root, f), src), '\\' => '/')
        (startswith(rel, "v2/") || startswith(rel, "TomlSyntax/") || endswith(rel, "_v2.jl")) && continue
        n = count("input_v2_enabled(", read(joinpath(root, f), String))
        n == 0 || (counts[rel] = n)
    end
    @test counts == Dict(
        "inputs.jl" => 1,               # the declaration itself
        "layer_syntax_trees.jl" => 1,   # derived_toml_parse_result
        "layer_projects.jl" => 3,       # derived_package / derived_project / derived_nonpackage_env
        "layer_environment.jl" => 4,    # project_uri_for_root / _test_environment_key / file_env_ready / required_dynamic_projects
        "layer_includes.jl" => 2,       # derived_file_include_data / derived_include_diagnostics
        "layer_diagnostics.jl" => 1,    # derived_diagnostics
        "layer_file_analysis.jl" => 1,  # derived_new_static_lint_diagnostics
        "layer_testitems.jl" => 1,      # derived_testitems
        "layer_hover.jl" => 1,
        "layer_misc.jl" => 1,
        "layer_navigation.jl" => 3,
        "layer_references.jl" => 5,
        "layer_signatures.jl" => 1,
        "layer_symbols.jl" => 2,
    )
    # StaticLint, the syntax-rule engine and the emission helpers are v1 code
    # v2 never forks: no flag reads there at all.
    for dir in ("StaticLint", "lint_syntax_rules")
        for (root, _, files) in walkdir(joinpath(src, dir)), f in files
            endswith(f, ".jl") && @test !occursin("input_v2_enabled", read(joinpath(root, f), String))
        end
    end
end

@testitem "v1 parity: project and manifest files get no v2 diagnostics, TOML parses with Pkg.TOML" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces: derived_toml_syntax_diagnostics, derived_toml_syntax_tree

    jw = JuliaWorkspace()
    project = URI("file:///parity/Project.toml")
    manifest = URI("file:///parity/Manifest.toml")
    # Every v2 project-file rule would fire on this pair: a malformed uuid, an
    # extension whose trigger is no weakdep, a `[sources]` entry with neither
    # url nor path, a dangling `[workspace]` member, an uninterpretable manifest.
    add_file!(jw, TextFile(project, SourceText("""
    name = "Parity"
    uuid = "not-a-uuid"
    version = "0.1.0"

    [deps]
    Dep = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1"

    [weakdeps]
    Trig = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2"

    [extensions]
    ParityExt = "Other"

    [sources]
    Dep = {}

    [workspace]
    projects = ["nowhere"]
    """, "toml")))
    add_file!(jw, TextFile(manifest, SourceText("""
    julia_version = "1.12.0"
    manifest_format = "9.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///parity/src/Parity.jl"), SourceText("module Parity end\n", "julia")))

    for uri in (project, manifest)
        codes = Set(d.code for d in get_diagnostic(jw, uri))
        @test isempty(intersect(codes, Set([:project_file_errors, :project_file_warnings, :manifest_errors, :analysis_boundary])))
    end

    # The TOML parser is Pkg.TOML: one diagnostic at a point, its source string.
    bad = URI("file:///parity/bad.toml")
    add_file!(jw, TextFile(bad, SourceText("a = \n", "toml")))
    diags = derived_toml_syntax_diagnostics(jw.runtime, bad)
    @test length(diags) == 1
    @test only(diags).source == "TOML.jl"
    @test derived_toml_syntax_tree(jw.runtime, bad) isa Dict{String,Any}

    # Flipping the flag on and back off leaves the flag-off answers unchanged,
    # and the flag-on answer is visibly different (the v2 rules do fire).
    key(d) = (d.range, d.severity, d.message, d.code)
    before = map(key, get_diagnostic(jw, project))
    set_v2_enabled!(jw, true)
    @test any(d -> d.code === :project_file_errors, get_diagnostic(jw, project))
    @test only(derived_toml_syntax_diagnostics(jw.runtime, bad)).source == "TomlSyntax.jl"
    set_v2_enabled!(jw, false)
    @test map(key, get_diagnostic(jw, project)) == before
    @test only(derived_toml_syntax_diagnostics(jw.runtime, bad)).source == "TOML.jl"
end

@testitem "v1 parity: environment selection and dynamic work items round-trip through the flag" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces: derived_project_uri_for_root, derived_required_dynamic_projects,
        derived_project, derived_package, derived_nonpackage_env, derived_testenv, _test_environment_key

    # A shape where every v2 environment rule differs from v1: a `[workspace]`
    # root deving a member package with `[sources]`, an `ext/` file, a `perf/`
    # script, and a manifest-less `test/` member.
    jw = JuliaWorkspace()
    root_uuid = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1"
    pkg_uuid = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2"
    add_file!(jw, TextFile(URI("file:///mono/Project.toml"), SourceText("""
    name = "Root"
    uuid = "$root_uuid"
    version = "1.0.0"

    [sources]
    Pkg = {path = "lib/Pkg"}

    [workspace]
    projects = ["lib/Pkg", "lib/Pkg/test"]
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/Manifest.toml"), SourceText("""
    julia_version = "1.12.0"
    manifest_format = "2.0"
    project_hash = "x"

    [[deps.Root]]
    path = "."
    uuid = "$root_uuid"
    version = "1.0.0"

    [[deps.Pkg]]
    path = "lib/Pkg"
    uuid = "$pkg_uuid"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/src/Root.jl"), SourceText("module Root end\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/Project.toml"), SourceText("""
    name = "Pkg"
    uuid = "$pkg_uuid"
    version = "0.1.0"

    [weakdeps]
    Trig = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c3"

    [extensions]
    PkgExt = "Trig"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/src/Pkg.jl"), SourceText("module Pkg end\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/ext/PkgExt.jl"), SourceText("module PkgExt end\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/perf/bench.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/test/Project.toml"), SourceText("[deps]\nPkg = \"$pkg_uuid\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Pkg/test/runtests.jl"), SourceText("using Pkg\n", "julia")))

    files = [URI("file:///mono/src/Root.jl"), URI("file:///mono/lib/Pkg/src/Pkg.jl"),
             URI("file:///mono/lib/Pkg/ext/PkgExt.jl"), URI("file:///mono/lib/Pkg/perf/bench.jl"),
             URI("file:///mono/lib/Pkg/test/runtests.jl")]
    folders = [URI("file:///mono"), URI("file:///mono/lib/Pkg"), URI("file:///mono/lib/Pkg/test")]
    pkg_folder = URI("file:///mono/lib/Pkg")

    snapshot() = (
        [derived_project_uri_for_root(jw.runtime, f) for f in files],
        derived_required_dynamic_projects(jw.runtime),
        [derived_project(jw.runtime, d) for d in folders],
        [derived_package(jw.runtime, d) for d in folders],
        [derived_nonpackage_env(jw.runtime, d) for d in folders],
        _test_environment_key(jw.runtime, pkg_folder, derived_package(jw.runtime, pkg_folder)),
        [derived_testenv(jw.runtime, f) for f in files],
    )

    off = snapshot()
    # v1: a manifest-less folder is not a project, and no extension-environment
    # work item exists.
    @test off[3][3] === nothing
    @test !any(k -> nameof(typeof(k)) === :ResolveExtensionEnvironmentKey, off[2])

    set_v2_enabled!(jw, true)
    on = snapshot()
    @test on[3][3] !== nothing                         # the test member is a synthesized project
    @test on != off

    set_v2_enabled!(jw, false)
    @test snapshot() == off
end
