@testsnippet TestItemAnalysisWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    const SL = JuliaWorkspaces.StaticLint
    const CST = JuliaWorkspaces.CSTParser

    const PKG = URI("file:///pkg")
    const PROJ = URI("file:///pkg/Project.toml")
    const MANIF = URI("file:///pkg/Manifest.toml")
    const ENTRY = URI("file:///pkg/src/MyPkg.jl")
    const TESTF = URI("file:///pkg/test/mytests.jl")

    const PROJECT_TOML = """
    name = "MyPkg"
    uuid = "12345678-1234-1234-1234-123456789012"
    version = "0.1.0"
    """
    const MANIFEST_TOML = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "0"
    """

    # A minimal workspace shaped like a real package: Project+Manifest so the
    # test-file root gets a project, an entry file so MyPkg is a workspace
    # package, and one test file whose analysis we assert on.
    function pkg_ws(; entry::String, testfile::String, extra::Dict{URI,String}=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(PROJ, SourceText(PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(MANIF, SourceText(MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(ENTRY, SourceText(entry, "julia")))
        add_file!(jw, TextFile(TESTF, SourceText(testfile, "julia")))
        for (u, s) in extra
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    const DEFAULT_ENTRY = """
    module MyPkg
    export efn
    efn() = 1
    ifn() = 2
    end
    """

    # The test file is its own analysis root (it is not included by anything).
    testf_diags(jw) = JuliaWorkspaces.derived_file_analysis(jw.runtime, TESTF, TESTF).diagnostics
    diag_messages(jw) = [d.message for d in testf_diags(jw)]
end

@testitem "missing refs are reported inside @testitem bodies" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        undefined_name_abc
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: undefined_name_abc" in msgs
end

@testitem "missing refs are reported inside @testset bodies" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testset "s" begin
        undefined_in_testset
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: undefined_in_testset" in msgs
end

@testitem "testitem kwargs and name args stay unsuppressed-free" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" tags=[:a] default_imports=true begin
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: tags", msgs)
    @test !any(m -> m == "Missing reference: default_imports", msgs)
end

@testitem "unknown macros still suppress missing refs in their args" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @some_unknown_macro begin
        xyz_inside_unknown
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: xyz_inside_unknown", msgs)
end

@testitem "an enclosing unknown macro suppresses even a nested @testset body" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @some_unknown_macro begin
        @testset "inner" begin
            nested_undefined_name
        end
    end
    """)
    msgs = diag_messages(jw)
    @test !any(m -> m == "Missing reference: nested_undefined_name", msgs)
end

@testitem "test macro names are not missing references" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
    end
    @testmodule TM begin
    end
    @testsnippet TS begin
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: @testitem" in msgs)
    @test !("Missing reference: @testmodule" in msgs)
    @test !("Missing reference: @testsnippet" in msgs)
end

@testitem "@testmodule bodies do not leak bindings into the file scope" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        leaked_name = 1
    end
    leaked_name
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: leaked_name" in msgs
end

@testitem "context_exported_names reads a workspace package's export list" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])
    @test SL.context_exported_names(ctx) == ["efn"]
end

@testitem "strip_module_contexts! removes contexts under any key" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])
    wrapped = SL.ExportFilteredContext(ctx, Set(["efn"]))

    fake = CST.parse("x = 1")
    md = Dict{UInt64,SL.Meta}()
    SL.setscope!(fake, SL.Scope(fake), md)
    sc = SL.scopeof(fake, md)
    sc.modules = Dict{Symbol,Any}(:__tree__ => ctx, :MyPkg => wrapped, :NotACtx => 1)

    SL.strip_module_contexts!(md)
    @test !haskey(sc.modules, :__tree__)
    @test !haskey(sc.modules, :MyPkg)
    @test haskey(sc.modules, :NotACtx)
end

@testitem "default_imports injects the package under test into @testitem scopes" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        efn()
        ifn()
        MyPkg.ifn()
    end
    """)
    msgs = diag_messages(jw)
    # exported name resolves bare
    @test !("Missing reference: efn" in msgs)
    # the package name itself resolves
    @test !("Missing reference: MyPkg" in msgs)
    # the internal name is flagged exactly once: the bare use. The qualified
    # use resolves through the tree.
    @test count(==("Missing reference: ifn"), msgs) == 1
end

@testitem "default_imports=false suppresses the package injection" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false begin
        efn()
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: efn" in msgs
end

@testitem "using the package inside a @testitem brings in its exports" setup=[TestItemAnalysisWS] begin
    # default_imports=false so this passes only if the explicit `using` works
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false begin
        using MyPkg
        efn()
        ifn()
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: efn" in msgs)
    @test "Missing reference: ifn" in msgs
end

@testitem "derived_test_setups indexes testmodules and testsnippets as plain data" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        tmf() = 1
        const TC = 2
        struct TS_t end
    end
    @testsnippet TS begin
        sx = 1
        sy, sz = 2, 3
    end
    """)
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test Set(keys(setups)) == Set([:TM, :TS])
    @test setups[:TM].kind == :module
    @test setups[:TM].file == TESTF
    @test setups[:TM].bound_names == ["TC", "TS_t", "tmf"]
    @test setups[:TS].kind == :snippet
    @test setups[:TS].bound_names == ["sx", "sy", "sz"]
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :TM) == setups[:TM]
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :Nope) === nothing
end

@testitem "setup testmodules and testsnippets inject into @testitem scopes cross-file" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM, TS] begin
            TM.tmf()
            TM.not_a_member()
            sx
            totally_undefined
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            tmf() = 1
        end
        @testsnippet TS begin
            sx = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: TM" in msgs)
    @test !("Missing reference: tmf" in msgs)
    # member sets are not enumerable in general (macros, usings inside the
    # setup) — unknown members must NOT be flagged
    @test !("Missing reference: not_a_member" in msgs)
    @test !("Missing reference: sx" in msgs)
    # ordinary missing refs in the same body still fire
    @test "Missing reference: totally_undefined" in msgs
end

@testitem "unknown setup names inject nothing" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" default_imports=false setup=[NoSuchSetup] begin
        whatever_name
    end
    """)
    msgs = diag_messages(jw)
    @test "Missing reference: whatever_name" in msgs
end

@testitem "end to end: default imports, explicit using, setups, and real missing refs" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "full" setup=[TM, TS] begin
            using MyPkg: ifn
            efn()
            ifn()
            MyPkg.ifn()
            TM.tmf()
            sx
            oops_undefined
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            tmf() = 1
        end
        @testsnippet TS begin
            sx = 1
        end
        """))
    msgs = diag_messages(jw)
    missing_refs = filter(m -> startswith(m, "Missing reference:"), msgs)
    @test missing_refs == ["Missing reference: oops_undefined"]
end

# ───────────────────────────────────────────────────────────────────
# Regression coverage for the final-review fix wave (see
# docs/superpowers/plans/2026-08-05-testitem-per-file-support.md):
# CRITICAL #1 (setup-provided names), IMPORTANT #2 (unresolvable
# self-package fallback).
# ───────────────────────────────────────────────────────────────────

@testitem "testmodule exports inject into @testitem scopes bare" setup=[TestItemAnalysisWS] begin
    # `using ..Setups.TM` brings TM's EXPORTS into the testitem scope, not
    # just the name TM — a bare use of an exported name must not be flagged,
    # while a genuinely undefined name in the same body still is.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM] begin
            tmf()
            TM.tmf()
            totally_undefined_xyz
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
        export tmf
        tmf() = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: tmf" in msgs)
    @test "Missing reference: totally_undefined_xyz" in msgs
end

@testitem "snippet using-leaves inject into @testitem scopes" setup=[TestItemAnalysisWS] begin
    # A name a snippet gains via an explicit `using X: a` at its top level
    # must exist in the referencing testitem too (TestItemRunner splices the
    # snippet's code into the testitem module), alongside the snippet's own
    # declarations. A genuinely undefined name still fires.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            ifn()
            helper()
            totally_undefined_xyz2
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
        using MyPkg: ifn
        helper() = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: ifn" in msgs)
    @test !("Missing reference: helper" in msgs)
    @test "Missing reference: totally_undefined_xyz2" in msgs
end

@testitem "testsnippet declaration bodies get default imports" setup=[TestItemAnalysisWS] begin
    # A @testsnippet body itself is include_string'd into a testitem module
    # at runtime, so it sees the same default imports (Test, the package
    # under test) a testitem body does — MyPkg is a resolvable workspace
    # package in this fixture.
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testsnippet TS2 begin
        v = efn()
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: efn" in msgs)
end

@testitem "unresolvable self-package suppresses missing refs instead of flooding" setup=[TestItemAnalysisWS] begin
    # No src/MyPkg.jl entry file at all: the package is a real Project.toml
    # package (self_package_name resolves), but its module doesn't exist
    # anywhere in the workspace tree, so the `using MyPkg` default-imports
    # injection cannot enumerate it. The fallback must suppress bare
    # missing-ref checks in the body rather than flood it.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(PROJ, SourceText(PROJECT_TOML, "toml")))
    add_file!(jw, TextFile(MANIF, SourceText(MANIFEST_TOML, "toml")))
    add_file!(jw, TextFile(TESTF, SourceText("""
    @testitem "t" begin
        totally_undefined_no_pkg
    end
    """, "julia")))
    msgs = diag_messages(jw)
    @test !("Missing reference: totally_undefined_no_pkg" in msgs)
end
