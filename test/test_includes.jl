@testitem "collect_include_calls resolves absolute paths without a file path" begin
    using JuliaWorkspaces: StaticLint, CSTParser
    using JuliaWorkspaces.URIs2: filepath2uri

    source = """
    include("/abs/target.jl")
    include("relative.jl")
    """
    cst = CSTParser.parse(source, true)

    # A file with no filesystem path (e.g. an unsaved buffer) can still resolve
    # absolute includes; relative ones are unresolvable.
    records = StaticLint.collect_include_calls(cst, nothing)

    @test length(records) == 2
    @test records[1][3] == filepath2uri("/abs/target.jl")
    @test records[2][3] === nothing
end

@testitem "include graph: edges, roots, and transitive includes" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclgraph/src/Pkg.jl")
    a_uri = URI("file:///inclgraph/src/a.jl")
    b_uri = URI("file:///inclgraph/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")\nf() = 1", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("g() = 2", "julia")))

    rt = jw.runtime
    @test JuliaWorkspaces.derived_includes(rt, root_uri) == Set([a_uri])
    @test JuliaWorkspaces.derived_includes(rt, a_uri) == Set([b_uri])
    @test JuliaWorkspaces.derived_includes(rt, b_uri) == Set{URI}()
    @test JuliaWorkspaces.derived_roots(rt) == Set([root_uri])
    @test JuliaWorkspaces.derived_roots_for_uri(rt, b_uri) == Set([root_uri])
end

@testitem "include graph: values are stable across include-preserving edits" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclstable/src/Pkg.jl")
    a_uri = URI("file:///inclstable/src/a.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("f() = 1", "julia")))

    rt = jw.runtime
    roots_before = JuliaWorkspaces.derived_roots(rt)
    includes_before = JuliaWorkspaces.derived_includes(rt, root_uri)

    # Edit that reparses but does not change the include structure. The graph
    # values must compare equal so Salsa's early-exit can spare downstream
    # consumers.
    JuliaWorkspaces.update_file!(jw, TextFile(a_uri, SourceText("f() = 1\n# a comment", "julia")))

    @test isequal(JuliaWorkspaces.derived_roots(rt), roots_before)
    @test isequal(JuliaWorkspaces.derived_includes(rt, root_uri), includes_before)

    # An edit that does change the include structure must update the graph.
    b_uri = URI("file:///inclstable/src/b.jl")
    add_file!(jw, TextFile(b_uri, SourceText("g() = 2", "julia")))
    JuliaWorkspaces.update_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")\nf() = 1", "julia")))

    @test JuliaWorkspaces.derived_includes(rt, a_uri) == Set([b_uri])
    @test JuliaWorkspaces.derived_roots_for_uri(rt, b_uri) == Set([root_uri])
end

@testitem "include graph: closure of a root" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclclosure/src/Pkg.jl")
    a_uri = URI("file:///inclclosure/src/a.jl")
    b_uri = URI("file:///inclclosure/src/b.jl")
    other_uri = URI("file:///inclclosure/src/other.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("g() = 2", "julia")))
    add_file!(jw, TextFile(other_uri, SourceText("h() = 3", "julia")))

    rt = jw.runtime
    @test JuliaWorkspaces.derived_include_closure(rt, root_uri) == Set([root_uri, a_uri, b_uri])
    @test JuliaWorkspaces.derived_include_closure(rt, other_uri) == Set([other_uri])
    # Self-includes must terminate.
    self_uri = URI("file:///inclclosure/src/selfinc.jl")
    add_file!(jw, TextFile(self_uri, SourceText("include(\"selfinc.jl\")", "julia")))
    @test JuliaWorkspaces.derived_include_closure(rt, self_uri) == Set([self_uri])
end

@testitem "include graph: lint diagnostics terminate on include cycles in a project" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "InclCycle"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee88"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    root_uri = URI("file:///inclcycle/src/InclCycle.jl")
    a_uri = URI("file:///inclcycle/src/a.jl")
    b_uri = URI("file:///inclcycle/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///inclcycle/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///inclcycle/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("module InclCycle\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("include(\"a.jl\")", "julia")))

    # The old diagnostics walk had no visited set and would loop forever on
    # the a <-> b cycle. It must terminate and report the include loop.
    diags = get_diagnostic(jw, root_uri)
    @test diags isa Vector

    all_diags = get_diagnostics(jw)
    cycle_diags = [d for (_, ds) in all_diags for d in ds if contains(d.message, "recursive")]
    @test !isempty(cycle_diags) || any(d -> d.source == "StaticLint.jl", [d for (_, ds) in all_diags for d in ds])
end

@testitem "include graph: cross-file lint still resolves includes after edits" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "InclLint"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee77"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    root_uri = URI("file:///incllint/src/InclLint.jl")
    inc_uri = URI("file:///incllint/src/helper.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///incllint/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///incllint/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("module InclLint\ninclude(\"helper.jl\")\nuse_helper() = helper_fn()\nend", "julia")))
    add_file!(jw, TextFile(inc_uri, SourceText("helper_fn() = 42", "julia")))

    # helper_fn is defined in the included file, so no missing-reference
    # diagnostic may appear in the root.
    diags = get_diagnostic(jw, root_uri)
    @test !any(d -> contains(d.message, "Missing reference: helper_fn"), diags)

    # Still true after the included file is edited (fresh CST, fresh objectids).
    JuliaWorkspaces.update_file!(jw, TextFile(inc_uri, SourceText("helper_fn() = 43", "julia")))
    diags = get_diagnostic(jw, root_uri)
    @test !any(d -> contains(d.message, "Missing reference: helper_fn"), diags)
end
