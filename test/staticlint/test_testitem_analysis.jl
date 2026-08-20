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

@testitem "derived_test_setups analyzes setup bodies with the normal passes" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        tmf() = 1
        const TC = 2
        struct TS_t end
        begin
            inblock = 3
        end
        @enum Color Red Green
        import MyPkg
        export tmf
    end
    @testsnippet TS begin
        sx = 1
        sy, sz = 2, 3
        using MyPkg
        using NoSuchPkg_xyz
    end
    """)
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test Set(keys(setups)) == Set([:TM, :TS])

    tm = setups[:TM]
    @test tm.kind == :module
    @test tm.file == TESTF
    # normal-pass bindings: block interiors, @enum members, and `import X`
    # (which binds X itself, as in any file) included
    @test issubset(["Color", "Green", "MyPkg", "Red", "TC", "TS_t", "inblock", "tmf"], tm.bound_names)
    @test tm.exported_names == ["tmf"]
    @test tm.wildcard_packages == String[]
    @test !tm.has_unresolved_wildcard

    ts = setups[:TS]
    @test ts.kind == :snippet
    @test issubset(["sx", "sy", "sz"], ts.bound_names)
    # resolved wildcard recorded by name; unresolved one sets the flag
    @test ts.wildcard_packages == ["MyPkg"]
    @test ts.has_unresolved_wildcard

    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :TM) == tm
    @test JuliaWorkspaces.derived_test_setup(jw.runtime, PKG, :Nope) === nothing
end

@testitem "qualified setup declarations are indexed like bare ones" setup=[TestItemAnalysisWS] begin
    # TestItems.@testmodule gets the same prebuilt-scope handling as the bare
    # form, so the index scan must recognize it too
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[QTM, QTS] begin
            qtmf()
            qsx
            undefined_next_to_qualified
        end
        """,
        extra=Dict(setups_file => """
        TestItems.@testmodule QTM begin
            export qtmf
            qtmf() = 1
        end
        TestItems.@testsnippet QTS begin
            qsx = 1
        end
        """))
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test Set(keys(setups)) == Set([:QTM, :QTS])
    msgs = diag_messages(jw)
    @test !("Missing reference: qtmf" in msgs)
    @test !("Missing reference: qsx" in msgs)
    @test "Missing reference: undefined_next_to_qualified" in msgs
end

@testitem "the setup index keys files by their containing package" setup=[TestItemAnalysisWS] begin
    # /pkgb is a distinct package whose path string-prefix-collides with
    # /pkg; containment must use the same file→package mapping the consumer
    # keys with (derived_package_for_file), not a path prefix
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
    end
    """)
    add_file!(jw, TextFile(URI("file:///pkgb/Project.toml"), SourceText("""
    name = "OtherPkg"
    uuid = "22345678-1234-1234-1234-123456789012"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///pkgb/Manifest.toml"), SourceText(MANIFEST_TOML, "toml")))
    add_file!(jw, TextFile(URI("file:///pkgb/src/OtherPkg.jl"), SourceText("module OtherPkg end", "julia")))
    add_file!(jw, TextFile(URI("file:///pkgb/test/setups.jl"), SourceText("""
    @testmodule OtherTM begin
    end
    """, "julia")))
    setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
    @test !haskey(setups, :OtherTM)

    if !Sys.iswindows()
        # /pkg and /PKG are distinct only where file URIs compare
        # case-sensitively (URIs2 folds case on Windows); a case-folded
        # prefix match would wrongly claim /PKG's setups for /pkg
        add_file!(jw, TextFile(URI("file:///PKG/Project.toml"), SourceText("""
        name = "CasePkg"
        uuid = "32345678-1234-1234-1234-123456789012"
        version = "0.1.0"
        """, "toml")))
        add_file!(jw, TextFile(URI("file:///PKG/Manifest.toml"), SourceText(MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(URI("file:///PKG/src/CasePkg.jl"), SourceText("module CasePkg end", "julia")))
        add_file!(jw, TextFile(URI("file:///PKG/test/setups.jl"), SourceText("""
        @testmodule CaseTM begin
        end
        """, "julia")))
        setups = JuliaWorkspaces.derived_test_setups(jw.runtime, PKG)
        @test !haskey(setups, :CaseTM)
    end
end

@testitem "setup-member refs stay out of the outbound table" setup=[TestItemAnalysisWS] begin
    # TM.tmf inside a testitem resolves against the synthetic setup module,
    # not a workspace module named TM; an outbound ("tmf", ["TM"]) row would
    # collide with a real module TM in cross-file reference aggregation
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM] begin
            TM.tmf()
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            export tmf
            tmf() = 1
        end
        """))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, TESTF, TESTF)
    @test !any(o -> o.name == "tmf" && o.origin_module == ["TM"], fa.outbound)
end

@testitem "@testsnippet honors default_imports=false" setup=[TestItemAnalysisWS] begin
    # snippets accept the same kwargs as @testitem; without default imports
    # the package under test is not visible in the body (Test's store is
    # absent in this harness env, so efn is the observable default import)
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testsnippet Bare default_imports=false begin
        efn()
        undefined_in_bare
    end
    @testsnippet Defaulted begin
        efn()
    end
    """)
    msgs = diag_messages(jw)
    # only the Bare snippet flags efn; skipping the injection must not
    # suppress checking either
    @test count(==("Missing reference: efn"), msgs) == 1
    @test "Missing reference: undefined_in_bare" in msgs
end

@testitem "exported macros resolve through the tree-context injections" setup=[TestItemAnalysisWS] begin
    # the ExportFilteredContext paths (default-imports package injection and
    # snippet wildcard re-attachment) must resolve exported MACROS bare, not
    # just function/const exports
    macro_entry = """
    module MyPkg
    export @mymac, efn
    macro mymac(x)
        esc(x)
    end
    efn() = 1
    end
    """
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=macro_entry,
        testfile="""
        @testitem "defaults" begin
            @mymac 1
        end
        @testitem "via snippet" default_imports=false setup=[WS] begin
            @mymac 2
            undefined_ctrl
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet WS begin
            using MyPkg
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: @mymac" in msgs)
    @test "Missing reference: undefined_ctrl" in msgs
end

@testitem "testmodule wildcards do not suppress item-side missing refs" setup=[TestItemAnalysisWS] begin
    # A wildcard `using` inside a @testmodule stays contained in the module
    # at runtime: the item sees only TM's explicit exports, so item-side
    # checking must stay fully enabled even when the wildcard is unresolvable.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TM] begin
            tmf()
            TM.anything_goes()
            undefined_in_item
        end
        """,
        extra=Dict(setups_file => """
        @testmodule TM begin
            using NoSuchPkg_xyz
            export tmf
            tmf() = 1
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: tmf" in msgs)
    @test !("Missing reference: anything_goes" in msgs)
    @test "Missing reference: undefined_in_item" in msgs
end

@testitem "known binding macros in setups enumerate instead of suppressing" setup=[TestItemAnalysisWS] begin
    # @enum used to make the whole setup unenumerable; the normal passes
    # bind its members, so the item resolves them and keeps full checking.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            x = Red
            undefined_after_enum
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            @enum Color Red Green
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: Red" in msgs)
    @test "Missing reference: undefined_after_enum" in msgs
end

@testitem "block-nested setup bindings reach referencing items" setup=[TestItemAnalysisWS] begin
    # the old top-level-only scan silently dropped these
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            inblock
            inbranch
            undefined_next_to_blocks
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            begin
                inblock = 1
            end
            if true
                inbranch = 2
            end
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: inblock" in msgs)
    @test !("Missing reference: inbranch" in msgs)
    @test "Missing reference: undefined_next_to_blocks" in msgs
end

@testitem "same-file setup references do not cycle" setup=[TestItemAnalysisWS] begin
    # a @testitem next to its @testmodule is the common layout; the setup
    # index must come from the raw CST, never from this file's own analysis
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        export tmf
        tmf() = 1
    end
    @testitem "t" default_imports=false setup=[TM] begin
        tmf()
        undefined_same_file
    end
    """)
    msgs = diag_messages(jw)
    @test !("Missing reference: tmf" in msgs)
    @test "Missing reference: undefined_same_file" in msgs
end

@testitem "unresolvable snippet wildcards still suppress item missing refs" setup=[TestItemAnalysisWS] begin
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            could_come_from_the_wildcard
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            using NoSuchPkg_xyz
        end
        """))
    msgs = diag_messages(jw)
    @test !("Missing reference: could_come_from_the_wildcard" in msgs)
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
# Regression coverage: setup-provided names and the unresolvable
# self-package fallback.
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

@testitem "semantic_pass strip_contexts=false keeps module contexts" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="")
    env = JuliaWorkspaces.derived_stdlib_only_env(jw.runtime)
    ctx = JuliaWorkspaces.TreeModuleContext(jw.runtime, ENTRY, ["MyPkg"])

    cst = CST.parse("x = 1", true)
    md = Dict{UInt64,SL.Meta}()
    SL.semantic_pass(TESTF, cst, env, md, jw.runtime; module_context=ctx, strip_contexts=false)
    @test haskey(SL.scopeof(cst, md).modules, :__tree__)

    cst2 = CST.parse("x = 1", true)
    md2 = Dict{UInt64,SL.Meta}()
    SL.semantic_pass(TESTF, cst2, env, md2, jw.runtime; module_context=ctx)
    @test !haskey(SL.scopeof(cst2, md2).modules, :__tree__)
end

@testitem "resolvable snippet wildcards re-attach instead of suppressing" setup=[TestItemAnalysisWS] begin
    # `using MyPkg` in the snippet resolves through the module tree, so the
    # item gets MyPkg's exports (export-filtered: internals still flagged)
    # and full missing-ref checking stays on.
    setups_file = URI("file:///pkg/test/setups.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY,
        testfile="""
        @testitem "t" default_imports=false setup=[TS] begin
            efn()
            MyPkg.ifn()
            ifn()
            undefined_beside_wildcard
        end
        """,
        extra=Dict(setups_file => """
        @testsnippet TS begin
            using MyPkg
        end
        """))
    msgs = diag_messages(jw)
    # exported name resolves bare; the package name resolves qualified
    @test !("Missing reference: efn" in msgs)
    @test !("Missing reference: MyPkg" in msgs)
    # non-exported internals and genuine unknowns are still flagged
    @test "Missing reference: ifn" in msgs
    @test "Missing reference: undefined_beside_wildcard" in msgs
end

@testitem "nested testitems inside setup bodies do not cycle" setup=[TestItemAnalysisWS] begin
    # invalid at runtime, but the analyzer must not crash: extraction
    # re-entering setup resolution used to raise a dependency-cycle error
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
        @testitem "nested" setup=[TM] begin
        end
    end
    """)
    @test diag_messages(jw) isa Vector
end

@testitem "an unclosed testmodule above setup-referencing items does not cycle" setup=[TestItemAnalysisWS] begin
    # transient editing state: parser recovery swallows the items below
    # into the unclosed block
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testmodule TM begin
    @testitem "t" setup=[TM] begin
        1 + 1
    end
    """)
    @test diag_messages(jw) isa Vector
end

# --- `include(...)` inside a testitem-family body -----------------------------
#
# A `@testitem` body is a fresh module at runtime, so an `include` there splices
# the target into THAT module. The inventory records the body as a `:testitem`
# node and the ordinary splice machinery does the rest; these tests pin the
# user-visible consequence.

@testitem "names from a file included in a @testitem body resolve" setup=[TestItemAnalysisWS] begin
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "one" begin
        include("shared.jl")
        helper
    end

    @testitem "two" begin
        include("shared.jl")
        helper
    end
    """, extra=Dict(shared => "helper(x) = x\n"))

    msgs = diag_messages(jw)
    # Both bodies, not just the first: the splice rule admits the helper once
    # per test item.
    @test !("Missing reference: helper" in msgs)
end

@testitem "an include in a @testitem body carries transitively" setup=[TestItemAnalysisWS] begin
    shared = URI("file:///pkg/test/shared.jl")
    deeper = URI("file:///pkg/test/deeper.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        include("shared.jl")
        deep_helper
    end
    """, extra=Dict(
        shared => "include(\"deeper.jl\")\n",
        deeper => "deep_helper() = 1\n"))

    @test !("Missing reference: deep_helper" in diag_messages(jw))
end

@testitem "colon imports in an included helper reach the testitem body" setup=[TestItemAnalysisWS] begin
    # The shape CSTParser's own `test/shared.jl` uses: the helper's top-level
    # `using ...: name` bring-ins must be visible too, not just its declarations.
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        include("shared.jl")
        ifn
    end
    """, extra=Dict(shared => "using MyPkg: ifn\n"))

    @test !("Missing reference: ifn" in diag_messages(jw))
end

@testitem "an include in a testitem body is not a blanket suppression" setup=[TestItemAnalysisWS] begin
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        include("shared.jl")
        helper
        genuinely_undefined
    end
    """, extra=Dict(shared => "helper() = 1\n"))

    msgs = diag_messages(jw)
    @test !("Missing reference: helper" in msgs)
    @test "Missing reference: genuinely_undefined" in msgs
end

@testitem "included names stay inside the test item that includes them" setup=[TestItemAnalysisWS] begin
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    helper

    @testitem "with" begin
        include("shared.jl")
        helper
    end

    @testitem "without" begin
        helper
    end
    """, extra=Dict(shared => "helper() = 1\n"))

    msgs = diag_messages(jw)
    # Two sites must still report: the file top level and the sibling item that
    # does not include the helper.
    @test count(==("Missing reference: helper"), msgs) == 2
end

@testitem "a helper included by a test item is analyzed, but conservatively" setup=[TestItemAnalysisWS] begin
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        include("shared.jl")
    end
    """, extra=Dict(shared => "helper() = whatever_the_testitem_provides\n"))
    rt = jw.runtime

    # It now has a module context (it did not before: included only from a body
    # the inventory refused to descend into, it was spliced nowhere).
    path = JuliaWorkspaces.derived_file_module_path(rt, TESTF, shared)
    @test path !== nothing
    @test JuliaWorkspaces.is_testitem_path(rt, TESTF, path)

    # But the test item's simulated `using Test`/`using MyPkg` are not written
    # anywhere in the tree, so bare missing-ref reporting there is suppressed
    # rather than wrong.
    msgs = [d.message for d in JuliaWorkspaces.derived_file_analysis(rt, TESTF, shared).diagnostics]
    @test !any(m -> startswith(m, "Missing reference:"), msgs)
end

@testitem "names declared in a testitem body are not workspace symbols" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        a_testitem_local_name() = 1
    end
    """)
    names = [s.name for s in JuliaWorkspaces.get_workspace_symbols(jw, "a_testitem_local_name")]
    @test isempty(names)
end

@testitem "a computed include suppresses only its own test item" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "computed" begin
        include(some_path_expression)
        anything_at_all
    end

    @testitem "plain" begin
        undefined_in_sibling
    end
    """)
    msgs = diag_messages(jw)
    # Unknown code is spliced into the first body, so it abstains...
    @test !("Missing reference: anything_at_all" in msgs)
    # ...but the sibling test item and the file top level keep reporting.
    @test "Missing reference: undefined_in_sibling" in msgs
end

@testitem "a missing include target in a testitem body does not throw" setup=[TestItemAnalysisWS] begin
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" begin
        include("no_such_file.jl")
    end
    """)
    @test diag_messages(jw) isa Vector
end

@testitem "an include in a @testmodule body reaches referencing test items" setup=[TestItemAnalysisWS] begin
    setups = URI("file:///pkg/test/setups.jl")
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testitem "t" setup=[TM] begin
        TM.helper
    end
    """, extra=Dict(
        setups => """
        @testmodule TM begin
            include("shared.jl")
        end
        """,
        shared => "helper() = 1\n"))

    @test diag_messages(jw) isa Vector
end

@testitem "an include inside a @testset stays opaque" setup=[TestItemAnalysisWS] begin
    # `@testset` introduces no module, so it is deliberately NOT descended into
    # — the include is invisible to the inventory and the name does not resolve.
    # Pinned so the known gap is a decision, not a surprise.
    shared = URI("file:///pkg/test/shared.jl")
    jw = pkg_ws(entry=DEFAULT_ENTRY, testfile="""
    @testset "s" begin
        include("shared.jl")
        helper
    end
    """, extra=Dict(shared => "helper() = 1\n"))

    @test "Missing reference: helper" in diag_messages(jw)
end
