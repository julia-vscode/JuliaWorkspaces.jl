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
