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

    # With env_ready = true and default missing-refs ("symbols"), missing refs should appear
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
