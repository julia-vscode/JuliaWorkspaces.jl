@testitem "Basic synta error" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo() end begin"
    uri = URI("file:/bar.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 1
    @test diags[1].range == 19:24
    @test diags[1].severity == :error
    @test diags[1].message == "extra tokens after end of expression"
    @test diags[1].source == "JuliaSyntax.jl"
end

@testitem "Diagnostic equality distinguishes empty ranges by position" begin
    using JuliaWorkspaces: Diagnostic

    # Empty UnitRanges compare equal regardless of position (`24:23 == 23:22`).
    # Diagnostic equality/hash must still tell an empty range at one position
    # from an empty range at another, or Salsa backdating keeps a stale range.
    a = Diagnostic(24:23, :error, "Expected `end`", nothing, Symbol[], "JuliaSyntax.jl")
    b = Diagnostic(23:22, :error, "Expected `end`", nothing, Symbol[], "JuliaSyntax.jl")

    @test a != b
    @test !isequal(a, b)
    @test hash(a) != hash(b)

    # Same position still compares equal (backdating must still work normally).
    c = Diagnostic(23:22, :error, "Expected `end`", nothing, Symbol[], "JuliaSyntax.jl")
    @test b == c
    @test isequal(b, c)
    @test hash(b) == hash(c)
end

@testitem "Syntax diagnostics: EOF range not left stale after trailing-trivia edit" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    # Unterminated blocks make JuliaSyntax report an empty EOF-marker range.
    # Deleting the trailing space shifts that empty range by one; the stale
    # range must not survive (its offset would exceed the shortened content and
    # crash the consumer's offset->position conversion), which happened while
    # editing the end of a file.
    u = URI("file:/edit.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("module M\nfunction f()\n ", "julia")))  # 23 bytes
    get_diagnostic(jw, u)  # cache diagnostics (empty range 24:23) at length 23

    update_file!(jw, TextFile(u, SourceText("module M\nfunction f()\n", "julia")))  # 22 bytes
    diags = get_diagnostic(jw, u)
    n = 22

    @test !isempty(diags)
    for d in diags
        @test first(d.range) <= n + 1   # stale 24:23 would give first=24 > 23
        @test last(d.range) <= n + 1
    end
end

@testitem "Basic synta error 2" begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:/test/test.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/test/JuliaLint.toml"), SourceText("syntax-errors = false", "toml")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 0
end

@testitem "@nospecialize params no false MissingRef" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NosTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    version = "0.1.0"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Cover: default value, no default, type annotation, and keyword parameter
    source = """
    module NosTest
    struct Unknown end
    function foo(x, @nospecialize(prev=Unknown()), @nospecialize(y), @nospecialize(z::Int); @nospecialize(kw=1))
        prev
        y
        z
        kw
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nostest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///nostest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///nostest/src/NosTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///nostest/src/NosTest.jl")
    diags = get_diagnostic(jw, uri)

    missing_ref_diags = filter(d -> startswith(d.message, "Missing reference"), diags)
    @test isempty(missing_ref_diags)
end

@testitem "Diagnostics: standalone file no crash" begin
    using JuliaWorkspaces.URIs2: URI

    # A standalone file with no Project.toml — should not crash and should
    # not emit env-dependent lint errors (only syntax errors if any).
    source = """
    module StandaloneDiag

    function foo(x)
        return x + 1
    end

    foo(42)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///standalonediag/src/StandaloneDiag.jl"), SourceText(source, "julia")))

    uri = URI("file:///standalonediag/src/StandaloneDiag.jl")

    # Should not throw (previously crashed with KeyError in derived_environment)
    diags = get_diagnostic(jw, uri)

    # No syntax errors in this well-formed file
    syntax_diags = filter(d -> d.source == "JuliaSyntax.jl", diags)
    @test isempty(syntax_diags)
end

@testitem "Diagnostics: stdlib without version in manifest no crash" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "StdlibVerTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
    version = "0.1.0"

    [deps]
    SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"
    """

    # Stdlib entries in real manifests often have no `version` field.
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [[deps.SHA]]
    uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
    """

    source = """
    module StdlibVerTest

    using SHA

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///stdlibvertest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///stdlibvertest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///stdlibvertest/src/StdlibVerTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///stdlibvertest/src/StdlibVerTest.jl")

    # Should not throw (previously crashed with a MethodError from
    # parse(VersionNumber, nothing) in derived_environment)
    diags = get_diagnostic(jw, uri)

    syntax_diags = filter(d -> d.source == "JuliaSyntax.jl", diags)
    @test isempty(syntax_diags)
end

# ──────────────────────────────────────────────────────────────────────
# Config validation tests
# ──────────────────────────────────────────────────────────────────────

@testitem "Config validation: invalid key" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("nonexistent-key = true", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid lint configuration nonexistent-key"), diags)
end

@testitem "Config validation: bool key with wrong type" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("call = \"yes\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid lint configuration value for call") && contains(d.message, "true") && contains(d.message, "false"), diags)
end

@testitem "Config validation: missing-refs wrong type" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("missing-refs = true", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid lint configuration value for missing-refs"), diags)
end

@testitem "Config validation: missing-refs invalid value" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("missing-refs = \"invalid\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid lint configuration value for missing-refs") && contains(d.message, "none, symbols, all"), diags)
end

@testitem "Config validation: valid config keys accepted" begin
    using JuliaWorkspaces.URIs2: URI

    config_content = """
    static-lint = true
    call = true
    iter = false
    nothingcomp = true
    constif = false
    lazy = true
    datadecl = false
    typeparam = true
    modname = false
    pirates = true
    useoffuncargs = false
    kwdefault = true
    literal = false
    break-continue = true
    constdecl = false
    missing-refs = "symbols"
    syntax-errors = true
    """

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText(config_content, "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test isempty(diags)
end

# ──────────────────────────────────────────────────────────────────────
# static-lint toggle tests
# ──────────────────────────────────────────────────────────────────────

@testitem "static-lint = false suppresses StaticLint diagnostics" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SLToggle"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Code with a constif check (non-env-dependent)
    source = """
    module SLToggle
    function foo()
        if true
            return 1
        end
        return 0
    end
    end
    """

    # First, verify diagnostics are present by default
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sltoggle/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sltoggle/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sltoggle/src/SLToggle.jl"), SourceText(source, "julia")))

    uri = URI("file:///sltoggle/src/SLToggle.jl")
    diags = get_diagnostic(jw, uri)
    sl_diags = filter(d -> d.source == "StaticLint.jl", diags)
    @test !isempty(sl_diags)

    # Now add static-lint = false config and verify diagnostics are suppressed
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///sltoggle2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///sltoggle2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///sltoggle2/src/SLToggle.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///sltoggle2/JuliaLint.toml"), SourceText("static-lint = false", "toml")))

    uri2 = URI("file:///sltoggle2/src/SLToggle.jl")
    diags2 = get_diagnostic(jw2, uri2)
    sl_diags2 = filter(d -> d.source == "StaticLint.jl", diags2)
    @test isempty(sl_diags2)
end

@testitem "static-lint subdirectory toggle (replaces disabledDirs)" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SubDirTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee02"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Code that triggers constif (non-env-dependent)
    source_with_lint = """
    module SubDirTest
    function bar()
        if true
            return 1
        end
        return 0
    end
    end
    """

    test_source = """
    if true
        println("test")
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///subdirtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///subdirtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///subdirtest/src/SubDirTest.jl"), SourceText(source_with_lint, "julia")))
    add_file!(jw, TextFile(URI("file:///subdirtest/test/runtests.jl"), SourceText(test_source, "julia")))
    # Disable static-lint only in test/
    add_file!(jw, TextFile(URI("file:///subdirtest/test/JuliaLint.toml"), SourceText("static-lint = false", "toml")))

    # src/ file should have StaticLint diagnostics
    src_uri = URI("file:///subdirtest/src/SubDirTest.jl")
    src_diags = get_diagnostic(jw, src_uri)
    src_sl = filter(d -> d.source == "StaticLint.jl", src_diags)
    @test !isempty(src_sl)

    # test/ file should have no StaticLint diagnostics
    test_uri = URI("file:///subdirtest/test/runtests.jl")
    test_diags = get_diagnostic(jw, test_uri)
    test_sl = filter(d -> d.source == "StaticLint.jl", test_diags)
    @test isempty(test_sl)
end

# ──────────────────────────────────────────────────────────────────────
# Individual LintOptions toggle tests
# ──────────────────────────────────────────────────────────────────────

@testitem "LintOption toggle: constif (as nothingcomp proxy)" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ConstIfToggle"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee03"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module ConstIfToggle
    function foo()
        if true
            return 1
        end
        return 0
    end
    end
    """

    # Enabled by default — both with and without config
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///cit3/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///cit3/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///cit3/src/ConstIfToggle.jl"), SourceText(source, "julia")))

    uri = URI("file:///cit3/src/ConstIfToggle.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags)

    # Disabled with config — nothingcomp = false should not affect constif
    # Here we test that individual toggle works, using constif = false
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///cit4/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///cit4/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///cit4/src/ConstIfToggle.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///cit4/JuliaLint.toml"), SourceText("constif = false", "toml")))

    uri2 = URI("file:///cit4/src/ConstIfToggle.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags2)
end

@testitem "LintOption toggle: constif" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ConstIfTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee04"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module ConstIfTest
    function foo()
        if true
            return 1
        end
        return 0
    end
    end
    """

    # Enabled (default) — diagnostic should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///cit/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///cit/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///cit/src/ConstIfTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///cit/src/ConstIfTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags)

    # Disabled
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///cit2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///cit2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///cit2/src/ConstIfTest.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///cit2/JuliaLint.toml"), SourceText("constif = false", "toml")))

    uri2 = URI("file:///cit2/src/ConstIfTest.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags2)
end

@testitem "LintOption toggle: lazy" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "LazyTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee05"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module LazyTest
    function foo(x)
        true || println("never")
        return x
    end
    end
    """

    # Enabled (default) — diagnostic should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///lt/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///lt/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///lt/src/LazyTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///lt/src/LazyTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "||"), diags)

    # Disabled
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///lt2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///lt2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///lt2/src/LazyTest.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///lt2/JuliaLint.toml"), SourceText("lazy = false", "toml")))

    uri2 = URI("file:///lt2/src/LazyTest.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "boolean literal") && contains(d.message, "||"), diags2)
end

@testitem "LintOption toggle: modname" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ModNameTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee06"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module ModNameTest
    module ModNameTest
    end
    end
    """

    # Enabled (default) — diagnostic should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mnt/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mnt/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mnt/src/ModNameTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///mnt/src/ModNameTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "matches that of its parent"), diags)

    # Disabled
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///mnt2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mnt2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mnt2/src/ModNameTest.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///mnt2/JuliaLint.toml"), SourceText("modname = false", "toml")))

    uri2 = URI("file:///mnt2/src/ModNameTest.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "matches that of its parent"), diags2)
end

@testitem "LintOption toggle: modname (as typeparam proxy)" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ModNameToggle"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee07"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module ModNameToggle
    module ModNameToggle
    end
    end
    """

    # Enabled (default) — diagnostic should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mntog/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mntog/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mntog/src/ModNameToggle.jl"), SourceText(source, "julia")))

    uri = URI("file:///mntog/src/ModNameToggle.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "matches that of its parent"), diags)

    # Disabled
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///mntog2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mntog2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mntog2/src/ModNameToggle.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///mntog2/JuliaLint.toml"), SourceText("modname = false", "toml")))

    uri2 = URI("file:///mntog2/src/ModNameToggle.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "matches that of its parent"), diags2)
end

@testitem "LintOption toggle: break-continue" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "BreakContTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee08"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module BreakContTest
    function foo()
        break
    end
    end
    """

    # Enabled (default) — diagnostic should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///bct/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///bct/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///bct/src/BreakContTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///bct/src/BreakContTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "break") && contains(d.message, "loop"), diags)

    # Disabled
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///bct2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///bct2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///bct2/src/BreakContTest.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///bct2/JuliaLint.toml"), SourceText("break-continue = false", "toml")))

    uri2 = URI("file:///bct2/src/BreakContTest.jl")
    diags2 = get_diagnostic(jw2, uri2)
    @test !any(d -> contains(d.message, "break") && contains(d.message, "loop"), diags2)
end

# ──────────────────────────────────────────────────────────────────────
# missing-refs tests
# ──────────────────────────────────────────────────────────────────────

@testitem "missing-refs: none suppresses vs default allows (with env_ready)" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces: Salsa

    project_toml = """
    name = "MissRefTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee09"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module MissRefTest
    function foo()
        return undefined_symbol
    end
    end
    """

    # With env_ready = true and default missing-refs ("all"), missing refs should appear
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mrt/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mrt/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///mrt/src/MissRefTest.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    uri = URI("file:///mrt/src/MissRefTest.jl")
    diags = get_diagnostic(jw, uri)
    missing_refs = filter(d -> startswith(d.message, "Missing reference"), diags)
    @test !isempty(missing_refs)

    # With missing-refs = "none", no missing refs should appear
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///mrt2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mrt2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///mrt2/src/MissRefTest.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///mrt2/JuliaLint.toml"), SourceText("missing-refs = \"none\"", "toml")))
    JuliaWorkspaces.set_input_env_ready!(jw2.runtime, true)

    uri2 = URI("file:///mrt2/src/MissRefTest.jl")
    diags2 = get_diagnostic(jw2, uri2)
    missing_refs2 = filter(d -> startswith(d.message, "Missing reference"), diags2)
    @test isempty(missing_refs2)
end

# ──────────────────────────────────────────────────────────────────────
# Hierarchical config override test
# ──────────────────────────────────────────────────────────────────────

@testitem "Hierarchical config: child overrides parent" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HierTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee0b"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Code that triggers constif
    source = """
    module HierTest
    function foo()
        if true
            return 1
        end
        return 0
    end
    end
    """

    # Root config disables constif
    root_config = "constif = false"
    # Subdir config re-enables constif
    sub_config = "constif = true"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hier/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/src/HierTest.jl"), SourceText(source, "julia")))
    add_file!(jw, TextFile(URI("file:///hier/JuliaLint.toml"), SourceText(root_config, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/src/JuliaLint.toml"), SourceText(sub_config, "toml")))

    # Child overrides parent — constif should be enabled for src/
    uri = URI("file:///hier/src/HierTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags)
end

# ──────────────────────────────────────────────────────────────────────
# Default behavior test
# ──────────────────────────────────────────────────────────────────────

@testitem "Default behavior: all checks enabled without config" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "DefaultTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee0c"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Code with multiple non-env-dependent lint issues: constif + modname
    source = """
    module DefaultTest
    module DefaultTest
    end
    function foo()
        if true
            return 1
        end
        return 0
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///dft/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///dft/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///dft/src/DefaultTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///dft/src/DefaultTest.jl")
    diags = get_diagnostic(jw, uri)

    # Both constif and modname diagnostics should be present
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags)
    @test any(d -> contains(d.message, "matches that of its parent"), diags)
end

# ──────────────────────────────────────────────────────────────────────
# unresolved-import tolerance tests
# ──────────────────────────────────────────────────────────────────────

@testitem "unresolved import: explicit names are bound, uses silent" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresExpl"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee21"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresExpl
    using NotARealPackage: foo, bar
    import AlsoNotReal
    function f()
        foo(bar) + AlsoNotReal.thing + genuine_typo
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresexpl/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresexpl/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresexpl/src/UnresExpl.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresexpl/src/UnresExpl.jl"))

    # Uses of the explicitly imported names resolve to synthetic bindings
    @test !any(d -> d.message == "Missing reference: foo", diags)
    @test !any(d -> d.message == "Missing reference: bar", diags)
    @test !any(d -> d.message == "Missing reference: AlsoNotReal", diags)
    # A genuine typo in the same scope is still reported
    @test any(d -> d.message == "Missing reference: genuine_typo", diags)
end

@testitem "unresolved import: self-import using M: M tolerates M.foo" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresSelf"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresSelf
    using NotARealPackage: NotARealPackage
    function f()
        NotARealPackage.foo(1)
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresself/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresself/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresself/src/UnresSelf.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresself/src/UnresSelf.jl"))

    @test !any(d -> d.message == "Missing reference: foo", diags)
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
    @test any(d -> startswith(d.message, "Failed to resolve `NotARealPackage`"), diags)
end

@testitem "unresolved import: late-resolving sibling module fills binding" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresLate"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresLate
    using .Sib: bar
    function f()
        bar()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreslate/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslate/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslate/src/UnresLate.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreslate/src/UnresLate.jl"))

    # Everything resolves after the retry: no missing refs at all
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: late-resolved module lacking the name stays silent for uses" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresLateMiss"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee24"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresLateMiss
    using .Sib: baz
    function f()
        baz()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreslatemiss/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslatemiss/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreslatemiss/src/UnresLateMiss.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreslatemiss/src/UnresLateMiss.jl"))

    # uses of baz resolve to the (never-filled) synthetic binding
    @test !any(d -> d.message == "Missing reference: baz", diags)
end

@testitem "unresolved import: statement flagged with UnresolvedImport" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresFlag"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee25"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresFlag
    using NotARealPackage
    import AlsoNotReal: thing
    using Base: not_a_real_base_name_xyz
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresflag/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflag/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflag/src/UnresFlag.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresflag/src/UnresFlag.jl"))

    wildcard = filter(d -> d.message == "Failed to resolve `NotARealPackage`. Missing-reference checks are disabled in this scope and all nested scopes.", diags)
    @test length(wildcard) == 1
    @test wildcard[1].severity == :warning

    explicit = filter(d -> d.message == "Failed to resolve `AlsoNotReal`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test length(explicit) == 1

    # module resolvable but name missing: flagged on the name, immediately
    @test any(d -> startswith(d.message, "Failed to resolve `not_a_real_base_name_xyz`"), diags)
    @test !any(d -> startswith(d.message, "Failed to resolve `Base`"), diags)

    # no generic missing refs inside the import statements
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: name missing from late-resolved module is flagged" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresFlagLate"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee26"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresFlagLate
    using .Sib: baz
    function f()
        baz()
    end
    module Sib
    bar() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresflaglate/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflaglate/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresflaglate/src/UnresFlagLate.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresflaglate/src/UnresFlagLate.jl"))

    # flagged on `baz` (the name), not on `Sib` (the module resolved)
    @test any(d -> startswith(d.message, "Failed to resolve `baz`"), diags)
    @test !any(d -> startswith(d.message, "Failed to resolve `Sib`"), diags)
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: diagnostic suppressed while env not ready" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresEnv"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee27"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresEnv
    using NotARealPackage
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresenv/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresenv/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresenv/src/UnresEnv.jl"), SourceText(source, "julia")))
    # NOTE: env deliberately NOT marked ready

    diags = get_diagnostic(jw, URI("file:///unresenv/src/UnresEnv.jl"))

    @test !any(d -> startswith(d.message, "Failed to resolve"), diags)
end

@testitem "unresolved import: as-aliased imports are flagged" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresAs"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2b"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresAs
    import NotARealPackageXYZ as NR
    using Base: not_a_real_base_name_xyz as aliasname
    function f()
        NR.foo(aliasname)
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresas/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresas/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresas/src/UnresAs.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresas/src/UnresAs.jl"))

    @test any(d -> d.message == "Failed to resolve `NotARealPackageXYZ`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test any(d -> d.message == "Failed to resolve `not_a_real_base_name_xyz`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test !any(d -> startswith(d.message, "Failed to resolve `Base`"), diags)
    # aliased names are bound; their uses stay silent
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: too-many-dots import is not double-diagnosed" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresDots"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2c"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresDots
    using ....TooDeep
    function f()
        obvious_typo_here()
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresdots/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresdots/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresdots/src/UnresDots.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresdots/src/UnresDots.jl"))

    # the dots error is the sole diagnostic for the import statement
    @test any(d -> d.message == "Relative import has more leading dots than available module nesting.", diags)
    @test !any(d -> startswith(d.message, "Failed to resolve"), diags)
    # and it must NOT flip on wildcard suppression: the genuine typo stays flagged
    @test any(d -> d.message == "Missing reference: obvious_typo_here", diags)
end

@testitem "unresolved wildcard using: bare missing refs suppressed in scope" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresWild"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee28"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresWild
    using NotARealPackage
    function f(x)
        some_unknown_export(x) + another_mystery
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreswild/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswild/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswild/src/UnresWild.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreswild/src/UnresWild.jl"))

    @test !any(d -> startswith(d.message, "Missing reference"), diags)
    @test count(d -> startswith(d.message, "Failed to resolve `NotARealPackage`"), diags) == 1
end

@testitem "unresolved wildcard using: sibling and nested modules" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresWildMod"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee29"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresWildMod
    module Inner1
    using NotARealPackage
    f() = mystery_name()
    end
    module Inner2
    g() = obvious_typo()
    end
    module Inner3
    using NotARealPackage
    module Nested
    h() = nested_typo()
    end
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unreswildmod/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswildmod/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unreswildmod/src/UnresWildMod.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unreswildmod/src/UnresWildMod.jl"))

    # Inner1: suppressed by its own unresolved wildcard using
    @test !any(d -> d.message == "Missing reference: mystery_name", diags)
    # Inner2: no unresolved using -> still checked
    @test any(d -> d.message == "Missing reference: obvious_typo", diags)
    # Nested module inside Inner3 does NOT inherit the suppression
    @test any(d -> d.message == "Missing reference: nested_typo", diags)
end

@testitem "unresolved import: macro-name imports are bound, uses silent" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresMacro"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2d"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresMacro
    using NotARealPkgQ: @mac
    import AlsoNotRealQ.@othermac
    function f()
        @mac(1)
        @othermac(2)
        genuine_typo
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresmacro/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresmacro/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresmacro/src/UnresMacro.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresmacro/src/UnresMacro.jl"))

    # Both unresolvable modules are flagged once, on the module name
    @test any(d -> d.message == "Failed to resolve `NotARealPkgQ`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test any(d -> d.message == "Failed to resolve `AlsoNotRealQ`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    # The imported macros are bound synthetically; their uses stay silent
    @test !any(d -> d.message == "Missing reference: @mac", diags)
    @test !any(d -> d.message == "Missing reference: @othermac", diags)
    # A genuine typo in the same scope is still reported
    @test any(d -> d.message == "Missing reference: genuine_typo", diags)
end

@testitem "unresolved import: file-toplevel using is flagged and binds names" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresTop"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2e"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    # No enclosing module: the import sits at the top level of the file.
    source = """
    using NotARealTopPkg: foo
    foo()
    genuine_typo_top
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unrestop/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestop/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestop/src/UnresTop.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unrestop/src/UnresTop.jl"))

    @test any(d -> d.message == "Failed to resolve `NotARealTopPkg`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    # The imported name is bound; its use stays silent
    @test !any(d -> d.message == "Missing reference: foo", diags)
    # A genuine typo at file top level is still reported
    @test any(d -> d.message == "Missing reference: genuine_typo_top", diags)
end

@testitem "unresolved import: file-toplevel late-resolving sibling fills binding" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresTopSib"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2f"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    # `using .Sib` precedes the `module Sib` definition, both at file top level
    # (no enclosing module): resolution succeeds only via the ResolveOnly retry
    # of the file-toplevel import statement itself.
    source = """
    using .Sib: bar
    function f()
        bar()
    end
    module Sib
    bar() = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unrestopsib/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestopsib/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestopsib/src/UnresTopSib.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unrestopsib/src/UnresTopSib.jl"))

    # Late resolution fills the binding: nothing is flagged
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
    @test !any(d -> startswith(d.message, "Failed to resolve"), diags)
end

@testitem "unresolved import: operator names are bound" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresOp"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee30"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module UnresOp
    import NotARealOpPkg: +, ==
    using AlsoNotOp: (*)
    function f(a, b)
        a + b == a
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresop/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresop/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresop/src/UnresOp.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresop/src/UnresOp.jl"))

    # Operator imports through unresolvable modules are flagged on the module name
    @test any(d -> d.message == "Failed to resolve `NotARealOpPkg`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    @test any(d -> d.message == "Failed to resolve `AlsoNotOp`. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    # No spurious missing-ref (or crash) from the operator names
    @test !any(d -> startswith(d.message, "Missing reference"), diags)
end

@testitem "unresolved import: imports inside a quote are not flagged" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresQuoted"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee31"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    # Imports inside quoted code are data, not executed imports, so they must not
    # be diagnosed. The unquoted `using` at module level is the positive control.
    source = """
    module UnresQuoted
    function gen()
        q1 = quote
            using NotARealQuotedPkg
            import AlsoNotRealQuoted: thing
        end
        q2 = :(using AnotherQuotedPkg)
        q1, q2
    end
    using ActuallyUnresolved
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unresquoted/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresquoted/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unresquoted/src/UnresQuoted.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unresquoted/src/UnresQuoted.jl"))

    # None of the quoted imports are flagged
    @test !any(d -> occursin("NotARealQuotedPkg", d.message), diags)
    @test !any(d -> occursin("AlsoNotRealQuoted", d.message), diags)
    @test !any(d -> occursin("AnotherQuotedPkg", d.message), diags)
    # The unquoted import at module level still is
    @test any(d -> startswith(d.message, "Failed to resolve `ActuallyUnresolved`"), diags)
end

@testitem "unresolved import: declared-but-uncacheable dep vs unknown name" begin
    using JuliaWorkspaces.URIs2: URI

    # `DeclaredButUncached` is listed in the manifest (so it's a declared
    # dependency) but no symbols are cached for it, so it never enters the env.
    # `TotallyUnknownPkg` is not declared anywhere.
    project_toml = """
    name = "UncachedDep"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee41"
    version = "0.1.0"

    [deps]
    DeclaredButUncached = "12345678-1234-1234-1234-123456789abc"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [[deps.DeclaredButUncached]]
    git-tree-sha1 = "0000000000000000000000000000000000000000"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "1.0.0"
    """
    source = """
    module UncachedDep
    import DeclaredButUncached: foo
    using TotallyUnknownPkg
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///uncacheddep/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///uncacheddep/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///uncacheddep/src/UncachedDep.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///uncacheddep/src/UncachedDep.jl"))

    # Declared dependency: message attributes the failure to indexing/caching
    @test any(d -> d.message == "`DeclaredButUncached` is a declared dependency but its symbols could not be indexed. Anything imported through this statement is assumed to exist and will not be checked.", diags)
    # Undeclared name: keeps the generic "Failed to resolve" wording
    @test any(d -> d.message == "Failed to resolve `TotallyUnknownPkg`. Missing-reference checks are disabled in this scope and all nested scopes.", diags)
end

@testitem "missing-refs: default is all (getfield refs checked)" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "MissRefAll"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee2a"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    source = """
    module MissRefAll
    using NotARealPackage
    function f()
        Base.this_name_surely_does_not_exist_xyz
    end
    end
    """

    # Default config: getfield refs into resolved modules are checked, even
    # though an unresolved wildcard using suppresses bare missing refs here
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///missrefall/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///missrefall/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///missrefall/src/MissRefAll.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///missrefall/src/MissRefAll.jl"))
    @test any(d -> d.message == "Missing reference: this_name_surely_does_not_exist_xyz", diags)

    # With missing-refs = "symbols", the getfield ref is not checked
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///missrefall2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/src/MissRefAll.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///missrefall2/JuliaLint.toml"), SourceText("missing-refs = \"symbols\"", "toml")))
    JuliaWorkspaces.set_input_env_ready!(jw2.runtime, true)

    diags2 = get_diagnostic(jw2, URI("file:///missrefall2/src/MissRefAll.jl"))
    @test !any(d -> d.message == "Missing reference: this_name_surely_does_not_exist_xyz", diags2)
end

@testitem "static-lint: a project-less root publishes no diagnostics (parity with old)" begin
    using JuliaWorkspaces.URIs2: URI

    # A loose file with NO project and no active project (the LS-startup
    # no-active-project window). The old whole-closure query bails empty in
    # this case; the migrated per-file consumer must too — otherwise every
    # real-package import flashes a "Failed to resolve …" false positive.
    script = URI("file:///loose/script.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(script, SourceText("import JSON\nf(x) = x == nothing\n", "julia")))
    rt = jw.runtime

    @test JuliaWorkspaces.derived_project_uri_for_root(rt, script) === nothing

    new = JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, script)
    old = JuliaWorkspaces.derived_static_lint_diagnostics(rt, script)
    @test isempty(old)          # old query bails empty (project_uri === nothing)
    @test new == old            # migrated query matches
    @test isempty(new)

    # ... and the per-file analysis itself still runs (stdlib fallback), so
    # the suppression lives in the consumer query, not the analysis — the
    # analysis would otherwise carry the false-positive flash
    fa = JuliaWorkspaces.derived_file_analysis(rt, script, script)
    @test any(d -> startswith(d.message, "Failed to resolve"), fa.diagnostics)

    # published diagnostics carry no static-lint flash
    diags = get_diagnostic(jw, script)
    @test !any(d -> d.source == "StaticLint.jl", diags)
    @test !any(d -> startswith(d.message, "Failed to resolve"), diags)
end

@testitem "static-lint: setting the active project restores diagnostics (new == old)" begin
    using JuliaWorkspaces.URIs2: URI

    # Same loose file, but now an active project is set: the root's project
    # URI is non-nothing, so the migrated consumer stops suppressing and
    # matches the old query exactly.
    env_dir = URI("file:///env")
    script = URI("file:///loose/script.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///env/Project.toml"), SourceText("""
    name = "Env"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0012"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///env/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(script, SourceText("import JSON\nf(x) = x == nothing\n", "julia")))
    JuliaWorkspaces.set_active_project!(jw, env_dir)
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)
    rt = jw.runtime

    @test JuliaWorkspaces.derived_project_uri_for_root(rt, script) !== nothing

    new = JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, script)
    old = JuliaWorkspaces.derived_static_lint_diagnostics(rt, script)
    @test new == old            # parity restored
    @test !isempty(new)         # diagnostics now appear
    @test any(d -> occursin("JSON", d.message), new)  # the real-package import now flags
end
