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

    # Both calls are recorded (including the resolved relative one), as
    # `(offset, span, target, guarded, testitem_ctx)`.
    @test length(analysis.records) == 2
    @test all(r -> length(r) == 5, analysis.records)
    @test analysis.records[1][3] == a_uri
    @test analysis.records[2][3] == rel_uri
    @test all(r -> r[4] === false && r[5] === nothing, analysis.records)

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

@testitem "reverse include map: child maps to all including parents" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///revmap/src/Pkg.jl")
    a_uri = URI("file:///revmap/src/a.jl")
    b_uri = URI("file:///revmap/src/b.jl")
    shared_uri = URI("file:///revmap/src/shared.jl")
    other_root_uri = URI("file:///revmap/src/other.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\ninclude(\"shared.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("g() = 2", "julia")))
    add_file!(jw, TextFile(shared_uri, SourceText("s() = 1", "julia")))
    add_file!(jw, TextFile(other_root_uri, SourceText("include(\"shared.jl\")", "julia")))

    rt = jw.runtime
    revmap = JuliaWorkspaces.derived_reverse_include_map(rt)

    @test revmap[a_uri] == Set([root_uri])
    @test revmap[b_uri] == Set([a_uri])
    @test revmap[shared_uri] == Set([root_uri, other_root_uri])
    # Files that nothing includes are not keys.
    @test !haskey(revmap, root_uri)
    @test !haskey(revmap, other_root_uri)
end

@testitem "reverse include map: missing include targets keep their parents" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///revmapmissing/src/Pkg.jl")
    missing_uri = URI("file:///revmapmissing/src/missing.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"missing.jl\")\nend", "julia")))

    rt = jw.runtime
    # The target has no content, but the edge must still be present so
    # roots_for_uri can find the root of a not-yet-created include target.
    @test JuliaWorkspaces.derived_reverse_include_map(rt)[missing_uri] == Set([root_uri])
    @test JuliaWorkspaces.derived_roots_for_uri(rt, missing_uri) == Set([root_uri])
end

@testitem "include graph: roots_for_uri terminates on include cycles" begin
    using JuliaWorkspaces.URIs2: URI

    # A cycle below a root: root -> a <-> b
    root_uri = URI("file:///revmapcycle/src/Pkg.jl")
    a_uri = URI("file:///revmapcycle/src/a.jl")
    b_uri = URI("file:///revmapcycle/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("include(\"a.jl\")", "julia")))

    rt = jw.runtime
    @test JuliaWorkspaces.derived_roots_for_uri(rt, b_uri) == Set([root_uri])
    @test JuliaWorkspaces.derived_roots_for_uri(rt, a_uri) == Set([root_uri])

    # A detached two-file cycle has no roots at all; the walk must terminate.
    c_uri = URI("file:///revmapcycle/src/c.jl")
    d_uri = URI("file:///revmapcycle/src/d.jl")
    add_file!(jw, TextFile(c_uri, SourceText("include(\"d.jl\")", "julia")))
    add_file!(jw, TextFile(d_uri, SourceText("include(\"c.jl\")", "julia")))
    @test JuliaWorkspaces.derived_roots_for_uri(rt, c_uri) == Set{URI}()
end

@testitem "include graph: roots_for_uri records O(1) dependencies" begin
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces.Salsa

    root_uri = URI("file:///revmapdeps/src/Pkg.jl")
    a_uri = URI("file:///revmapdeps/src/a.jl")
    b_uri = URI("file:///revmapdeps/src/b.jl")
    other_uri = URI("file:///revmapdeps/src/other.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\ninclude(\"a.jl\")\nend", "julia")))
    add_file!(jw, TextFile(a_uri, SourceText("include(\"b.jl\")", "julia")))
    add_file!(jw, TextFile(b_uri, SourceText("g() = 2", "julia")))
    add_file!(jw, TextFile(other_uri, SourceText("h() = 3", "julia")))

    rt = jw.runtime
    @test JuliaWorkspaces.derived_roots_for_uri(rt, b_uri) == Set([root_uri])

    # The per-file node must depend only on the shared reverse map and the roots
    # set — not on every file's include list (that made verification O(n²) over
    # the whole workspace).
    key_type = Salsa.DerivedKey{typeof(JuliaWorkspaces.derived_roots_for_uri), Tuple{typeof(b_uri)}}
    cache = rt.storage.derived_function_maps[key_type]
    @test length(cache[(b_uri,)].dependencies) <= 3
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

@testitem "computed include: ComputedInclude diagnostic is emitted at the include site" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///computedincl/src/CompIncl.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///computedincl/Project.toml"), SourceText("""
    name = "CompIncl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef01"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///computedincl/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("""
    module CompIncl
    for f in readdir(@__DIR__)
        include(f)
    end
    end
    """, "julia")))

    diags = get_diagnostic(jw, root_uri)
    @test count(d -> contains(d.message, "could not be determined statically"), diags) == 1
end

@testitem "computed include: custom include method definitions are not flagged" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///customincl/src/CustIncl.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///customincl/Project.toml"), SourceText("""
    name = "CustIncl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef02"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///customincl/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    # FilePathsBase-style: method definitions ON `include` are signatures,
    # not calls — never flagged. The runtime CALL inside `load`'s body IS a
    # dynamic include (splices into an unknown module at call time), so it
    # gets exactly one ComputedInclude.
    add_file!(jw, TextFile(root_uri, SourceText("""
    module CustIncl
    struct MyPath end
    include(path::MyPath) = 1
    function include(mapexpr::Function, path::MyPath); 2; end
    load(p) = include(p)
    end
    """, "julia")))

    diags = get_diagnostic(jw, root_uri)
    @test count(d -> contains(d.message, "could not be determined statically"), diags) == 1
end

@testitem "computed include: function-body includes flag and suppress like computed ones" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    # ColorSchemes-style: literal-looking includes inside a loader function,
    # data file is an orphan. Both the diagnostic and the orphan suppression
    # must fire even though no top-level include exists.
    root_uri = URI("file:///fnincl/src/FnIncl.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///fnincl/Project.toml"), SourceText("""
    name = "FnIncl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef06"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///fnincl/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("""
    module FnIncl
    function loadall()
        datadir = joinpath(dirname(@__DIR__), "data")
        include(joinpath(datadir, "schemes.jl"))
    end
    end
    """, "julia")))
    orphan = URI("file:///fnincl/data/schemes.jl")
    add_file!(jw, TextFile(orphan, SourceText("register(undefined_helper)\n", "julia")))

    set_input_env_ready!(jw.runtime, true)

    @test count(d -> contains(d.message, "could not be determined statically"), get_diagnostic(jw, root_uri)) == 1
    @test !any(d -> contains(d.message, "undefined_helper"), get_diagnostic(jw, orphan))
end

@testitem "computed include: missing_reference suppressed in the polluted module only" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///pollutedmod/src/PollutedMod.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pollutedmod/Project.toml"), SourceText("""
    name = "PollutedMod"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef03"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///pollutedmod/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("""
    module PollutedMod
    module Polluted
    for f in ["x.jl"]
        include(f)
    end
    p() = undefined_in_polluted
    end
    module Clean
    c() = undefined_in_clean
    end
    end
    """, "julia")))
    set_input_env_ready!(jw.runtime, true)

    msgs = [d.message for d in get_diagnostic(jw, root_uri)]
    @test !any(contains("undefined_in_polluted"), msgs)
    @test any(contains("undefined_in_clean"), msgs)
end

@testitem "computed include: orphan roots suppressed only in computed-include packages" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    # Package A: entry has a computed include; data.jl is an orphan (nothing
    # statically includes it) — it is very likely the computed include's
    # target, so its bare missing refs are suppressed.
    add_file!(jw, TextFile(URI("file:///orphA/Project.toml"), SourceText("""
    name = "OrphA"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef04"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///orphA/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///orphA/src/OrphA.jl"), SourceText("""
    module OrphA
    for f in ["data.jl"]
        include(f)
    end
    end
    """, "julia")))
    orphan_a = URI("file:///orphA/src/data.jl")
    add_file!(jw, TextFile(orphan_a, SourceText("a() = undefined_in_orpha\n", "julia")))

    # Package B: fully static; loose.jl is an orphan by accident and keeps
    # full checking.
    add_file!(jw, TextFile(URI("file:///orphB/Project.toml"), SourceText("""
    name = "OrphB"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef05"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///orphB/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///orphB/src/OrphB.jl"), SourceText("module OrphB\nend\n", "julia")))
    orphan_b = URI("file:///orphB/src/loose.jl")
    add_file!(jw, TextFile(orphan_b, SourceText("b() = undefined_in_orphb\n", "julia")))

    set_input_env_ready!(jw.runtime, true)

    @test !any(d -> contains(d.message, "undefined_in_orpha"), get_diagnostic(jw, orphan_a))
    @test any(d -> contains(d.message, "undefined_in_orphb"), get_diagnostic(jw, orphan_b))
end

@testitem "guarded includes: isfile/isdefined guards suppress MissingFile and DuplicateInclude" begin
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///guardincl/src/GuardIncl.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///guardincl/Project.toml"), SourceText("""
    name = "GuardIncl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef20"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///guardincl/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    # deps.jl doesn't exist (Pkg.build output) — guarded, so no MissingFile.
    # helper.jl is re-included under an @isdefined guard — idiomatic
    # double-inclusion PROTECTION, so no DuplicateInclude — and helper2.jl
    # exercises the reverse order: the guarded include comes first, so the
    # later canonical include is not a duplicate, but the one after it is.
    # deps2.jl is the variable-path guarded computed include (no
    # ComputedInclude), while dynpath is unguarded and still warns.
    add_file!(jw, TextFile(root_uri, SourceText("""
    module GuardIncl
    isfile(joinpath(@__DIR__, "deps.jl")) && include("deps.jl")
    include("helper.jl")
    if !isdefined(@__MODULE__, :HELPER_LOADED)
        include("helper.jl")
    end
    isdefined(@__MODULE__, :HELPER2_LOADED) || include("helper2.jl")
    include("helper2.jl")
    include("helper2.jl")
    const depsjl = joinpath(@__DIR__, "deps2.jl")
    isfile(depsjl) && include(depsjl)
    dynpath = joinpath(@__DIR__, "dyn.jl")
    include(dynpath)
    include("really_missing.jl")
    end
    """, "julia")))
    add_file!(jw, TextFile(URI("file:///guardincl/src/helper.jl"), SourceText("const HELPER_LOADED = true\n", "julia")))
    add_file!(jw, TextFile(URI("file:///guardincl/src/helper2.jl"), SourceText("const HELPER2_LOADED = true\n", "julia")))

    msgs = [d.message for d in get_diagnostic(jw, root_uri)]
    # The unguarded missing include still reports; the guarded ones don't.
    @test count(contains("can not be found"), msgs) == 1
    # Only the second unconditional helper2 include is a real duplicate.
    @test count(contains("already been included"), msgs) == 1
    # Only the unguarded computed include reports.
    @test count(contains("could not be determined statically"), msgs) == 1
end

@testitem "collect_include_analysis tags includes inside testitem-family macros" begin
    using JuliaWorkspaces: StaticLint, CSTParser

    source = """
    include("top.jl")
    @testitem "a" begin
        include("shared.jl")
    end
    TestItems.@testitem "b" begin
        include("shared.jl")
    end
    @testmodule M begin
        include("shared.jl")
    end
    @testset "ts" begin
        include("shared.jl")
    end
    """
    cst = CSTParser.parse(source, true)
    records = StaticLint.collect_include_analysis(cst, "/abs/entry.jl").records

    @test length(records) == 5
    # Top-level and `@testset` includes carry no testitem context; each
    # testitem-family body gets its own, distinct from the others.
    @test records[1][5] === nothing
    @test records[5][5] === nothing
    ctxs = [r[5] for r in records[2:4]]
    @test all(!isnothing, ctxs)
    @test length(unique(ctxs)) == 3
end

@testitem "testitem includes: sharing a helper across test items is not a duplicate" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///tiincl/Project.toml"), SourceText("""
    name = "TIIncl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef21"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///tiincl/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///tiincl/src/TIIncl.jl"), SourceText("module TIIncl\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///tiincl/shared.jl"), SourceText("const SHARED = true\n", "julia")))

    runtests_uri = URI("file:///tiincl/test/runtests.jl")
    add_file!(jw, TextFile(runtests_uri, SourceText("""
    include("test_a.jl")
    include("test_b.jl")
    """, "julia")))

    # Each test item is its own module at runtime, so both may include the same
    # helper — and so may the enclosing file at top level.
    a_uri = URI("file:///tiincl/test/test_a.jl")
    add_file!(jw, TextFile(a_uri, SourceText("""
    include("../shared.jl")
    @testitem "a1" begin
        include("../shared.jl")
    end
    @testitem "a2" begin
        include("../shared.jl")
    end
    """, "julia")))

    # The qualified form, plus the other two module-introducing testitem macros.
    b_uri = URI("file:///tiincl/test/test_b.jl")
    add_file!(jw, TextFile(b_uri, SourceText("""
    TestItems.@testitem "b1" begin
        include("../shared.jl")
    end
    @testmodule Setup begin
        include("../shared.jl")
    end
    @testsnippet Snip begin
        include("../shared.jl")
    end
    """, "julia")))

    @test isempty([d for d in get_diagnostic(jw, a_uri) if contains(d.message, "already been included")])
    @test isempty([d for d in get_diagnostic(jw, b_uri) if contains(d.message, "already been included")])
    @test isempty([d for d in get_diagnostic(jw, runtests_uri) if contains(d.message, "already been included")])
end

@testitem "testitem includes: duplicates inside one test item still report" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///tidup/Project.toml"), SourceText("""
    name = "TIDup"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef22"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///tidup/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///tidup/src/TIDup.jl"), SourceText("module TIDup\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///tidup/shared.jl"), SourceText("const SHARED = true\n", "julia")))

    # A test item's body is one module: including the same file twice there is a
    # genuine duplicate, and a missing include is still missing. An `@testset`
    # introduces no module, so its includes share the file's structure.
    test_uri = URI("file:///tidup/test/runtests.jl")
    add_file!(jw, TextFile(test_uri, SourceText("""
    @testitem "dup" begin
        include("../shared.jl")
        include("../shared.jl")
    end
    @testitem "gone" begin
        include("../nonexistent.jl")
    end
    @testset "ts" begin
        include("../shared.jl")
        include("../shared.jl")
    end
    """, "julia")))

    msgs = [d.message for d in get_diagnostic(jw, test_uri)]
    @test count(contains("already been included"), msgs) == 2
    @test count(contains("can not be found"), msgs) == 1
end
