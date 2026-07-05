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

@testitem "collect_include_analysis produces edges, include_dict and records in one pass" begin
    using JuliaWorkspaces: StaticLint, CSTParser
    using JuliaWorkspaces.URIs2: filepath2uri

    source = """
    include("/abs/a.jl")
    include("missing_relative.jl")
    """
    cst = CSTParser.parse(source, true)

    analysis = StaticLint.collect_include_analysis(cst, "/abs/entry.jl")

    a_uri = filepath2uri("/abs/a.jl")
    rel_uri = filepath2uri("/abs/missing_relative.jl")

    # Both calls are recorded (including the resolved relative one).
    @test length(analysis.records) == 2
    @test analysis.records[1][3] == a_uri
    @test analysis.records[2][3] == rel_uri

    # Edges only contain resolved targets.
    @test analysis.edges == Set([a_uri, rel_uri])

    # include_dict keys are objectids of the actual include-call EXPRs and map to
    # their targets.
    @test length(analysis.include_dict) == 2
    @test Set(values(analysis.include_dict)) == Set([a_uri, rel_uri])
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

@testitem "include graph: edges are stable across include-preserving edits" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclstable/src/Pkg.jl")
    a_uri = URI("file:///inclstable/src/a.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("f() = 1", "julia")))

    rt = jw.runtime
    roots_before = JuliaWorkspaces.derived_roots(rt)
    includes_before = JuliaWorkspaces.derived_includes(rt, root_uri)

    # An edit that reparses but does not change the include structure. The graph
    # selectors must compare equal so Salsa's early-exit can spare downstream
    # consumers even though the fused node's include_dict churns.
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

@testitem "include graph: include_dict objectids match the memoised CST" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///incldict/src/Pkg.jl")
    a_uri = URI("file:///incldict/src/a.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("f() = 1", "julia")))

    rt = jw.runtime
    include_dict = JuliaWorkspaces.derived_include_dict(rt, root_uri)

    # The include-call objectid resolves to the included file. (That these keys
    # line up with the memoised CST the semantic pass traverses is exercised
    # end-to-end by the cross-file lint test below.)
    @test length(include_dict) == 1
    @test only(values(include_dict)) == a_uri
end

@testitem "include graph: cross-file lint resolves includes after edits" begin
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

@testitem "include graph: diagnostics terminate on include cycles" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclcycle/src/a.jl")
    a_uri = URI("file:///inclcycle/src/a.jl")
    b_uri = URI("file:///inclcycle/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("include(\"a.jl\")", "julia")))

    # The include-diagnostics walk must terminate on the a <-> b cycle rather
    # than looping forever.
    diags_a = get_diagnostic(jw, a_uri)
    diags_b = get_diagnostic(jw, b_uri)
    @test diags_a isa Vector
    @test diags_b isa Vector

    all_diags = get_diagnostics(jw)
    @test all_diags isa AbstractDict
end

@testitem "include graph: self-include terminates" begin
    using JuliaWorkspaces.URIs2: URI

    self_uri = URI("file:///inclself/src/selfinc.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(self_uri, SourceText("include(\"selfinc.jl\")", "julia")))

    rt = jw.runtime
    @test JuliaWorkspaces.derived_includes(rt, self_uri) == Set([self_uri])
    @test get_diagnostic(jw, self_uri) isa Vector
end

@testitem "include closure: transitive members and out-of-closure exclusion" begin
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
    # The closure spans the transitive include tree, and excludes unrelated files.
    @test JuliaWorkspaces.derived_include_closure(rt, root_uri) == Set([root_uri, a_uri, b_uri])
    @test !(other_uri in JuliaWorkspaces.derived_include_closure(rt, root_uri))
    @test JuliaWorkspaces.derived_include_closure(rt, other_uri) == Set([other_uri])

    # A self-include must terminate.
    self_uri = URI("file:///inclclosure/src/selfinc.jl")
    add_file!(jw, TextFile(self_uri, SourceText("include(\"selfinc.jl\")", "julia")))
    @test JuliaWorkspaces.derived_include_closure(rt, self_uri) == Set([self_uri])
end

@testitem "diagnostics: include cycle inside a project terminates and is reported" begin
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

    root_uri = URI("file:///inclcycleproj/src/InclCycle.jl")
    a_uri = URI("file:///inclcycleproj/src/a.jl")
    b_uri = URI("file:///inclcycleproj/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///inclcycleproj/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///inclcycleproj/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("module InclCycle\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("include(\"a.jl\")", "julia")))

    # With the old global diagnostics walk (no visited set) this looped forever
    # for a project root. It must terminate and report the recursive include.
    diags = get_diagnostic(jw, root_uri)
    @test diags isa Vector

    all_diags = get_diagnostics(jw)
    @test all_diags isa AbstractDict
    @test any(d -> contains(d.message, "Circular"), [d for (_, ds) in all_diags for d in ds])
end

@testitem "diagnostics: shared included file is deduplicated across roots" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "InclShared"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee99"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    a_uri = URI("file:///inclshared/src/a.jl")
    b_uri = URI("file:///inclshared/src/b.jl")
    shared_uri = URI("file:///inclshared/src/shared.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///inclshared/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///inclshared/Manifest.toml"), SourceText(manifest_toml, "toml")))
    # Two independent roots both include the same file.
    add_file!(jw, TextFile(a_uri, SourceText("include(\"shared.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("include(\"shared.jl\")", "julia")))
    add_file!(jw, TextFile(shared_uri, SourceText("foo() = undefined_symbol", "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    rt = jw.runtime
    # shared.jl is reached from both roots.
    @test JuliaWorkspaces.derived_roots_for_uri(rt, shared_uri) == Set([a_uri, b_uri])

    # The missing-reference diagnostic must appear exactly once despite two roots.
    diags = get_diagnostic(jw, shared_uri)
    @test count(d -> contains(d.message, "Missing reference: undefined_symbol"), diags) == 1
end

@testitem "include closure: content-stable presence predicate" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///inclpresence/src/Pkg.jl")
    a_uri = URI("file:///inclpresence/src/a.jl")
    missing_uri = URI("file:///inclpresence/src/missing.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\ninclude(\"missing.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("f() = 1", "julia")))

    rt = jw.runtime

    # Present target reports content; unresolved/absent target does not.
    @test JuliaWorkspaces.derived_has_content(rt, a_uri) == true
    @test JuliaWorkspaces.derived_has_content(rt, missing_uri) == false

    # The closure includes the present target and excludes the missing one.
    closure_before = JuliaWorkspaces.derived_include_closure(rt, root_uri)
    @test closure_before == Set([root_uri, a_uri])
    @test !(missing_uri in closure_before)

    # A content-only edit to an in-closure file leaves the closure value and the
    # presence predicate unchanged (Salsa back-dates them, sparing consumers).
    JuliaWorkspaces.update_file!(jw, TextFile(a_uri, SourceText("f() = 1\n# edited", "julia")))
    @test JuliaWorkspaces.derived_has_content(rt, a_uri) == true
    @test isequal(JuliaWorkspaces.derived_include_closure(rt, root_uri), closure_before)
end
