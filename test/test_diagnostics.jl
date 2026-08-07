@testitem "Basic synta error" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo() end begin"
    uri = URI("file:/bar.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 1
    @test diags[1].range == 19:25
    @test diags[1].severity == :error
    @test diags[1].message == "extra tokens after end of expression"
    @test diags[1].source == "JuliaSyntax.jl"
end

@testitem "Syntax diagnostic ranges cover the offending bytes" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    # Our ranges are 1-based with an exclusive end (as `StaticLint`'s
    # `offset+1:offset+span+1`), JuliaSyntax reports both endpoints inclusive:
    # only the end gets bumped, the start is already right.
    function syntax_diags(source)
        uri = URI("file:/range.jl")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.source == "JuliaSyntax.jl", get_diagnostic(jw, uri))
    end
    covered(source, d) = source[first(d.range):last(d.range)-1]

    # Error on a token with no preceding whitespace: shifting the start would
    # underline `x` instead of `0x`.
    ds = syntax_diags("x = 0x")
    @test length(ds) == 1
    @test ds[1].range == 5:7
    @test covered("x = 0x", ds[1]) == "0x"

    ds = syntax_diags("\"\\q\"")
    @test length(ds) == 1
    @test covered("\"\\q\"", ds[1]) == "\\q"

    # JuliaSyntax includes the whitespace before the extra token
    ds = syntax_diags("a b")
    @test length(ds) == 1
    @test ds[1].range == 2:4
    @test covered("a b", ds[1]) == " b"

    # A single-byte error must not come out zero-width
    ds = syntax_diags("@ foo")
    @test length(ds) == 1
    @test covered("@ foo", ds[1]) == " "

    # Errors at EOF are zero-width markers one past the last byte: the start is
    # `sizeof+1` and the end must not point past it (the consumer converts
    # `last-1` to a position and throws for offsets beyond the content).
    source = "f(x"
    ds = syntax_diags(source)
    @test length(ds) == 1
    @test ds[1].range == 4:4
    @test first(ds[1].range) == sizeof(source) + 1
    @test covered(source, ds[1]) == ""
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
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/test/JuliaLint.toml"), SourceText("[rules]
syntax_errors = \"off\"", "toml")))

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

@testitem "Config validation: invalid top-level key" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("nonexistent_key = true", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid lint configuration key `nonexistent_key`"), diags)
    @test all(d -> d.code === :config_errors, diags)
end

@testitem "Config validation: unknown rule" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("[rules]\nno_such_rule = \"off\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Unknown lint rule `no_such_rule`"), diags)
end

@testitem "Config validation: invalid severity" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("[rules]\nunused_binding = \"loud\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid severity `loud` for rule `unused_binding`") &&
                   contains(d.message, "off, hint, info, warning, error"), diags)
end

@testitem "Config validation: invalid preset" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("preset = \"pedantic\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid `preset`") && contains(d.message, "minimal, default, strict"), diags)
end

@testitem "Config validation: missing_reference scope invalid value" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText(
        "[rules]\nmissing_reference = { severity = \"warning\", scope = \"invalid\" }", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid `scope` for rule `missing_reference`") &&
                   contains(d.message, "none, symbols, all"), diags)
end

@testitem "Config validation: unknown rule option" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText(
        "[rules]\nunused_binding = { severity = \"warning\", scope = \"all\" }", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Unknown option `scope` for rule `unused_binding`"), diags)
end

@testitem "Config validation: old schema keys report their replacement" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText(
        "static-lint = true\nnothingcomp = false\nmissing-refs = \"symbols\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "`static-lint` is no longer supported") && contains(d.message, "preset"), diags)
    @test any(d -> contains(d.message, "`nothingcomp` is no longer supported") && contains(d.message, "nothing_comparison"), diags)
    @test any(d -> contains(d.message, "`missing-refs` is no longer supported") && contains(d.message, "missing_reference"), diags)
end

@testitem "Config validation: valid config accepted" begin
    using JuliaWorkspaces.URIs2: URI

    config_content = """
    preset = "default"
    include = ["**/*.jl"]
    exclude = ["gen/**"]

    [rules]
    unused_binding = "warning"
    nothing_comparison = "error"
    index_from_length = "off"
    missing_reference = { severity = "warning", scope = "symbols" }
    syntax_errors = "error"

    [[override]]
    paths = ["test/**"]

    [override.rules]
    unused_binding = "off"
    """

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText(config_content, "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test isempty(diags)
end

@testitem "Config validation: override block requires paths" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:/proj/JuliaLint.toml")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("[[override]]\n[override.rules]\nunused_binding = \"off\"", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "missing the required `paths` key"), diags)
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
    add_file!(jw2, TextFile(URI("file:///sltoggle2/JuliaLint.toml"), SourceText("preset = \"minimal\"", "toml")))

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
    add_file!(jw, TextFile(URI("file:///subdirtest/test/JuliaLint.toml"), SourceText("preset = \"minimal\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///cit4/JuliaLint.toml"), SourceText("[rules]
const_if_condition = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///cit2/JuliaLint.toml"), SourceText("[rules]
const_if_condition = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///lt2/JuliaLint.toml"), SourceText("[rules]
pointless_boolean = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///mnt2/JuliaLint.toml"), SourceText("[rules]
module_name = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///mntog2/JuliaLint.toml"), SourceText("[rules]
module_name = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///bct2/JuliaLint.toml"), SourceText("[rules]
break_continue = \"off\"", "toml")))

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
    add_file!(jw2, TextFile(URI("file:///mrt2/JuliaLint.toml"), SourceText("[rules]
missing_reference = \"off\"", "toml")))
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

    # The root config turns the rule off AND sets an unrelated rule. The
    # nearest config governs wholesale, so neither key reaches src/.
    root_config = """
    [rules]
    const_if_condition = "off"
    unused_binding = "off"
    """
    sub_config = """
    [rules]
    const_if_condition = "info"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hier/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/src/HierTest.jl"), SourceText(source, "julia")))
    add_file!(jw, TextFile(URI("file:///hier/JuliaLint.toml"), SourceText(root_config, "toml")))
    add_file!(jw, TextFile(URI("file:///hier/src/JuliaLint.toml"), SourceText(sub_config, "toml")))

    # The nearest config re-enables the rule for src/.
    uri = URI("file:///hier/src/HierTest.jl")
    diags = get_diagnostic(jw, uri)
    @test any(d -> contains(d.message, "boolean literal") && contains(d.message, "if"), diags)

    # No merging: `unused_binding = "off"` is set only in the root config, so it
    # does not carry into src/, whose config never mentions the rule.
    cfg = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, uri)
    @test JuliaWorkspaces.rule_enabled(cfg, :unused_binding)
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

@testitem "unresolved-import: false suppresses only the import diagnostic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "UnresTog"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee44"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    # Explicit import (not wildcard) so missing-ref checks stay on in the scope:
    # the genuine typo must still be reported to prove the toggle is surgical.
    source = """
    module UnresTog
    using NotARealPackage: NotARealPackage
    function f()
        return genuine_typo()
    end
    end
    """

    # Enabled (default) — both the import warning and the genuine typo appear.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///unrestog/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestog/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///unrestog/src/UnresTog.jl"), SourceText(source, "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, URI("file:///unrestog/src/UnresTog.jl"))
    @test any(d -> startswith(d.message, "Failed to resolve `NotARealPackage`"), diags)
    @test any(d -> d.message == "Missing reference: genuine_typo", diags)

    # Disabled — the import warning is gone, but the rest of static-lint still runs.
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///unrestog2/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///unrestog2/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw2, TextFile(URI("file:///unrestog2/src/UnresTog.jl"), SourceText(source, "julia")))
    add_file!(jw2, TextFile(URI("file:///unrestog2/JuliaLint.toml"), SourceText("[rules]
unresolved_import = \"off\"", "toml")))
    JuliaWorkspaces.set_input_env_ready!(jw2.runtime, true)

    diags2 = get_diagnostic(jw2, URI("file:///unrestog2/src/UnresTog.jl"))
    # The UnresolvedImport diagnostic (both "Failed to resolve" and "could not be
    # indexed" phrasings) is suppressed...
    @test !any(d -> contains(d.message, "Failed to resolve `") || contains(d.message, "could not be indexed"), diags2)
    # ...and it did not fall through to the generic LintCode "Failed to resolve import." message.
    @test !any(d -> d.message == "Failed to resolve import.", diags2)
    # ...while an unrelated static-lint check (missing reference) stays active.
    @test any(d -> d.message == "Missing reference: genuine_typo", diags2)
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

@testitem "unresolved import: colon import `using Foo.Bar: x` through a workspace package's re-exported indexed module is not flagged" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, FunctionStore, MethodStore

    # The `using Revise.CodeTracking: MethodInfoKey` shape: `Outer` is a WORKSPACE
    # (deved) package whose source brings in an indexed dependency `Inner` via
    # `using Inner`. Resolving `Outer.Inner` runs through Outer's tree context,
    # where `Inner` surfaces as an `:external_symbol` stand-in. The whole-module
    # form (`using Outer.Inner`) binds it and stays silent; the COLON form's
    # module-path component used to be flagged as an unresolved import even though
    # `Inner` is indexed and resolvable.
    inner_uuid = Base.UUID("22222222-2222-2222-2222-222222222222")
    inner_tree = "2222222222222222222222222222222222222222"
    inner_ms = ModuleStore(VarRef(nothing, :Inner), Dict{Symbol,Any}(), "", true, [:bar], Symbol[])
    inner_ms.vals[:bar] = FunctionStore(VarRef(VarRef(nothing, :Inner), :bar), MethodStore[], "", VarRef(VarRef(nothing, :Inner), :bar), true)
    inner_pkg = Package("Inner", inner_ms, inner_uuid, nothing)

    outer_project = """
    name = "Outer"
    uuid = "11111111-1111-1111-1111-111111111111"
    version = "0.1.0"
    [deps]
    Inner = "22222222-2222-2222-2222-222222222222"
    """
    outer_manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    [[deps.Inner]]
    uuid = "22222222-2222-2222-2222-222222222222"
    git-tree-sha1 = "$inner_tree"
    version = "1.0.0"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/Outer/Project.toml"), SourceText(outer_project, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Outer/Manifest.toml"), SourceText(outer_manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/Outer/src/Outer.jl"), SourceText("module Outer\nusing Inner\nend\n", "julia")))
    fileuri = URI("file:///ws/Outer/test/runtests.jl")
    add_file!(jw, TextFile(fileuri, SourceText("using Outer.Inner: bar\n", "julia")))
    JuliaWorkspaces.set_input_env_ready!(jw.runtime, true)
    JuliaWorkspaces.set_input_package_metadata!(jw.runtime, :Inner, inner_uuid, v"1.0.0", inner_tree, inner_pkg)

    diags = get_diagnostic(jw, fileuri)

    # `Inner` is indexed and reachable through Outer, so its colon import resolves.
    @test !any(d -> occursin("Failed to resolve `Inner`", d.message), diags)
    @test !any(d -> occursin("could not be indexed", d.message) && occursin("Inner", d.message), diags)
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
    add_file!(jw2, TextFile(URI("file:///missrefall2/JuliaLint.toml"), SourceText("[rules]
missing_reference = { scope = \"symbols\" }", "toml")))
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

@testitem "derived_julia_files admits untitled Julia buffers, not markdown" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    jl = URI("untitled:Untitled-1")
    md = URI("untitled:Untitled-2")
    add_file!(jw, TextFile(jl, SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(md, SourceText("# hi\n", "markdown")))

    julia_files = JuliaWorkspaces.derived_julia_files(jw.runtime)

    @test jl in julia_files
    @test !(md in julia_files)

    # value-stable language query
    @test JuliaWorkspaces.derived_file_language_id(jw.runtime, jl) == "julia"
    @test JuliaWorkspaces.derived_file_language_id(jw.runtime, md) == "markdown"
end

@testitem "derived_julia_files: one predicate for roots and the diagnostics gate" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    upper = URI("file:///Foo.JL")             # uppercase ext -> julia (case-insensitive)
    untitled_jl_md = URI("untitled:Buf-1.jl")  # .jl-suffixed but tagged markdown -> not julia
    untitled_julia = URI("untitled:Buf-2")     # no suffix, tagged julia -> julia
    add_file!(jw, TextFile(upper, SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(untitled_jl_md, SourceText("# hi\n", "markdown")))
    add_file!(jw, TextFile(untitled_julia, SourceText("y = 2\n", "julia")))

    julia_files = JuliaWorkspaces.derived_julia_files(jw.runtime)

    # Root admission agrees with `_is_julia_uri` (the diagnostics gate): the raw
    # `.jl`-suffix no longer decides it.
    @test upper in julia_files
    @test !(untitled_jl_md in julia_files)
    @test untitled_julia in julia_files
    @test JuliaWorkspaces._is_julia_uri(jw.runtime, upper)
    @test !JuliaWorkspaces._is_julia_uri(jw.runtime, untitled_jl_md)
    @test JuliaWorkspaces._is_julia_uri(jw.runtime, untitled_julia)
end

@testitem "Untitled Julia buffer reports syntax diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    uri = URI("untitled:Untitled-1")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "julia")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 1
    @test diags[1].severity == :error
    @test diags[1].source == "JuliaSyntax.jl"
end

@testitem "Untitled markdown buffer reports no diagnostics" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    uri = URI("untitled:Untitled-2")
    jw = JuliaWorkspace()
    # Content that is a Julia syntax error but the buffer is markdown: it must
    # not be parsed as Julia, so no diagnostics.
    add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "markdown")))

    diags = get_diagnostic(jw, uri)

    @test isempty(diags)
end

@testitem "Untitled buffer uses active project as fallback environment" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, get_diagnostic, TextFile, SourceText,
        set_active_project!, set_input_env_ready!, derived_project_uri_for_root
    using JuliaWorkspaces.URIs2: URI

    env_dir = URI("file:///env")
    uri = URI("untitled:Untitled-1")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///env/Project.toml"), SourceText("""
    name = "Env"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0013"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///env/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(uri, SourceText("import JSON\n", "julia")))
    set_active_project!(jw, env_dir)
    set_input_env_ready!(jw.runtime, true)

    # The untitled buffer's project is the active project (fallback env).
    @test derived_project_uri_for_root(jw.runtime, uri) == env_dir

    # With the env ready, the unresolvable package import now flags.
    diags = get_diagnostic(jw, uri)
    @test any(d -> d.source == "StaticLint.jl", diags)
    @test any(d -> occursin("JSON", d.message), diags)
end

# ──────────────────────────────────────────────────────────────────────
# Per-project environment gating
# ──────────────────────────────────────────────────────────────────────

# `_add_file!` instead of `add_file!` in these tests: it skips the reconcile, so
# the dynamic reactor stays idle and the only results are the injected ones.

@testitem "env gating: a ready environment only unblocks its own project" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, get_diagnostic, process_from_dynamic, derived_project,
        EnvironmentReadyResult, input_env_ready, set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI, uri2filepath

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (name, n) in (("EnvGateA", "41"), ("EnvGateB", "42"))
        _add_file!(jw, TextFile(URI("file:///ws/$name/Project.toml"), SourceText("""
        name = "$name"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee$n"
        version = "0.1.0"
        """, "toml")))
        _add_file!(jw, TextFile(URI("file:///ws/$name/Manifest.toml"), SourceText(manifest_toml, "toml")))
        _add_file!(jw, TextFile(URI("file:///ws/$name/src/$name.jl"), SourceText("""
        module $name
        f() = undefined_symbol
        end
        """, "julia")))
    end

    uri_a = URI("file:///ws/EnvGateA/src/EnvGateA.jl")
    uri_b = URI("file:///ws/EnvGateB/src/EnvGateB.jl")
    folder_b = URI("file:///ws/EnvGateB")

    missing_refs(uri) = filter(d -> startswith(d.message, "Missing reference"), get_diagnostic(jw, uri))

    # Nothing is ready yet: both projects gate their env-dependent diagnostics.
    @test isempty(missing_refs(uri_a))
    @test isempty(missing_refs(uri_b))

    # Only B's environment finishes indexing.
    put!(jw.dynamic_feature.out_channel, EnvironmentReadyResult(
        uri2filepath(folder_b), derived_project(jw.runtime, folder_b).content_hash))
    process_from_dynamic(jw)

    @test !isempty(missing_refs(uri_b))
    @test isempty(missing_refs(uri_a))     # A's own environment is still pending
    @test !input_env_ready(jw.runtime)     # production never sets the manual override

    # The manual override still unblocks every project.
    set_input_env_ready!(jw.runtime, true)
    @test !isempty(missing_refs(uri_a))
end

@testitem "env gating: a failed environment DJP unblocks its own project" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, get_diagnostic, process_from_dynamic, derived_project,
        FailedResult, WatchEnvironmentKey
    using JuliaWorkspaces.URIs2: URI, uri2filepath

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    _add_file!(jw, TextFile(URI("file:///ws/EnvFail/Project.toml"), SourceText("""
    name = "EnvFail"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee43"
    version = "0.1.0"
    """, "toml")))
    _add_file!(jw, TextFile(URI("file:///ws/EnvFail/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    fileuri = URI("file:///ws/EnvFail/src/EnvFail.jl")
    _add_file!(jw, TextFile(fileuri, SourceText("module EnvFail\nf() = undefined_symbol\nend\n", "julia")))

    folder = URI("file:///ws/EnvFail")
    missing_refs() = filter(d -> startswith(d.message, "Missing reference"), get_diagnostic(jw, fileuri))

    @test isempty(missing_refs())

    # A failure is terminal: gating must not wait for an environment that will
    # never arrive, so the (best-effort) diagnostics are published.
    put!(jw.dynamic_feature.out_channel, FailedResult(WatchEnvironmentKey(
        uri2filepath(folder), derived_project(jw.runtime, folder).content_hash)))
    process_from_dynamic(jw)

    @test !isempty(missing_refs())
end

@testitem "env gating: a project no DJP is scheduled for does not gate forever" begin
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_diagnostic,
        set_active_project!, derived_project, derived_project_uri_for_root
    using JuliaWorkspaces.URIs2: URI

    # Project.toml but no Manifest.toml: no environment is ever indexed for this
    # project, so its files must not wait for a readiness signal that can never
    # arrive.
    env_dir = URI("file:///noman")
    fileuri = URI("file:///noman/foo.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///noman/Project.toml"), SourceText("""
    name = "NoMan"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee44"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(fileuri, SourceText("import JSON\n", "julia")))
    set_active_project!(jw, env_dir)

    @test derived_project(jw.runtime, env_dir) === nothing
    @test derived_project_uri_for_root(jw.runtime, fileuri) == env_dir

    diags = get_diagnostic(jw, fileuri)
    @test any(d -> d.source == "StaticLint.jl" && occursin("JSON", d.message), diags)
end

@testitem "env gating: a failed test-environment DJP unblocks the package's test files" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_project, derived_file_env_ready,
        derived_required_dynamic_projects, EnvironmentReadyResult, FailedResult,
        WatchTestEnvironmentKey
    using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath

    # The test-env work item is only scheduled for a package with a real
    # `test/runtests.jl` on disc, so this fixture is written to disc.
    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = Dict(
        joinpath(dir, "Project.toml") => ("""
        name = "TestEnvGate"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee45"
        version = "0.1.0"
        """, "toml"),
        joinpath(dir, "Manifest.toml") => ("""
        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "abc123"

        [deps]
        """, "toml"),
        joinpath(dir, "src", "TestEnvGate.jl") => ("module TestEnvGate\nend\n", "julia"),
        joinpath(dir, "test", "runtests.jl") => ("f() = undefined_symbol\n", "julia"),
    )

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    proj_uri = filepath2uri(dir)
    proj_hash = derived_project(jw.runtime, proj_uri).content_hash
    test_key = WatchTestEnvironmentKey(dir, "TestEnvGate", proj_hash)
    @test test_key in derived_required_dynamic_projects(jw.runtime)

    put!(jw.dynamic_feature.out_channel, EnvironmentReadyResult(dir, proj_hash))
    process_from_dynamic(jw)

    runtests_uri = filepath2uri(joinpath(dir, "test", "runtests.jl"))
    # The project env is ready, but the test env this file needs is still pending.
    @test !derived_file_env_ready(jw.runtime, runtests_uri)

    put!(jw.dynamic_feature.out_channel, FailedResult(test_key))
    process_from_dynamic(jw)

    @test derived_file_env_ready(jw.runtime, runtests_uri)
end

@testitem "env gating: a manifest-less package's test files wait for their test environment" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_package, derived_file_env_ready,
        derived_required_dynamic_projects, derived_ready_test_environment,
        derived_test_environment_pending, _test_environment_key,
        TestEnvironmentReadyResult, WatchTestEnvironmentKey
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    # A package without a manifest is not a project folder, so its test-env work
    # item is keyed on the package folder itself with a zero content hash.
    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = [
        joinpath(dir, "Project.toml") => ("""
        name = "BareGate"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee46"
        version = "0.1.0"
        """, "toml"),
        joinpath(dir, "src", "BareGate.jl") => ("module BareGate\nend\n", "julia"),
        joinpath(dir, "test", "runtests.jl") => ("using Test\n", "julia"),
        joinpath(dir, "test", "test_gate.jl") => ("""
        @testitem "t" begin
            @test true
        end
        """, "julia"),
    ]

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    package_uri = filepath2uri(dir)
    key = _test_environment_key(jw.runtime, package_uri, derived_package(jw.runtime, package_uri))
    @test key == WatchTestEnvironmentKey(dir, "BareGate", UInt64(0))
    @test key in derived_required_dynamic_projects(jw.runtime)

    runtests_uri = filepath2uri(joinpath(dir, "test", "runtests.jl"))
    testitem_uri = filepath2uri(joinpath(dir, "test", "test_gate.jl"))

    # The work item is scheduled and unresolved, so both test files must wait.
    @test derived_test_environment_pending(jw.runtime, key)
    @test derived_ready_test_environment(jw.runtime, key) === nothing
    @test !derived_file_env_ready(jw.runtime, runtests_uri)
    @test !derived_file_env_ready(jw.runtime, testitem_uri)

    merged_uri = filepath2uri(joinpath(mktempdir(), "merged"))
    put!(jw.dynamic_feature.out_channel, TestEnvironmentReadyResult(
        filepath2uri(key.project_path), key.package_name, merged_uri, key.content_hash))
    process_from_dynamic(jw)

    # Ready because the result was found, not because nothing is scheduled.
    @test derived_ready_test_environment(jw.runtime, key) == merged_uri
    @test derived_test_environment_pending(jw.runtime, key)
    @test derived_file_env_ready(jw.runtime, runtests_uri)
    @test derived_file_env_ready(jw.runtime, testitem_uri)
end

@testitem "env gating: a failed test-environment DJP unblocks a manifest-less package" begin
    using JuliaWorkspaces: JuliaWorkspace, DynamicIndexingOnly, TextFile, SourceText,
        _add_file!, process_from_dynamic, derived_package, derived_file_env_ready,
        derived_required_dynamic_projects, derived_test_environment_pending,
        _test_environment_key, FailedResult
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    dir = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    files = [
        joinpath(dir, "Project.toml") => ("""
        name = "BareGateFail"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee47"
        version = "0.1.0"
        """, "toml"),
        joinpath(dir, "src", "BareGateFail.jl") => ("module BareGateFail\nend\n", "julia"),
        joinpath(dir, "test", "runtests.jl") => ("using Test\n", "julia"),
    ]

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=mktempdir())
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end

    package_uri = filepath2uri(dir)
    key = _test_environment_key(jw.runtime, package_uri, derived_package(jw.runtime, package_uri))
    @test key in derived_required_dynamic_projects(jw.runtime)

    runtests_uri = filepath2uri(joinpath(dir, "test", "runtests.jl"))
    @test !derived_file_env_ready(jw.runtime, runtests_uri)

    put!(jw.dynamic_feature.out_channel, FailedResult(key))
    process_from_dynamic(jw)

    @test !derived_test_environment_pending(jw.runtime, key)
    @test derived_file_env_ready(jw.runtime, runtests_uri)
end

@testitem "env gating: test-environment keys agree between producer and consumers" begin
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, _add_file!,
        _set_active_project!, derived_package, derived_required_dynamic_projects,
        _test_environment_key, WatchTestEnvironmentKey, derived_project
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    # Three shapes of package folder, all with a `test/runtests.jl` on disc (the
    # required set only fabricates a test-env item for those): the package is its
    # own project, the package has no manifest and no project devs it, and the
    # package is deved by an enclosing project.
    root = uri2filepath(filepath2uri(mktempdir()))  # round-trip: drive-letter casing must match production-derived keys on Windows
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    function write_package(dir, name, uuid; manifest=nothing)
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "test"))
        out = [
            joinpath(dir, "Project.toml") => ("""
            name = "$name"
            uuid = "$uuid"
            version = "0.1.0"
            """, "toml"),
            joinpath(dir, "src", "$name.jl") => ("module $name\nend\n", "julia"),
            joinpath(dir, "test", "runtests.jl") => ("using Test\n", "julia"),
        ]
        manifest === nothing || push!(out, joinpath(dir, "Manifest.toml") => (manifest, "toml"))
        return out
    end

    own_dir = joinpath(root, "Own")
    bare_dir = joinpath(root, "Bare")
    outer_dir = joinpath(root, "Outer")
    deved_dir = joinpath(outer_dir, "Deved")

    files = [
        write_package(own_dir, "Own", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee48"; manifest=manifest_toml);
        write_package(bare_dir, "Bare", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee49");
        write_package(deved_dir, "Deved", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee4a");
        [
            joinpath(outer_dir, "Project.toml") => ("""
            [deps]
            Deved = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee4a"
            """, "toml"),
            joinpath(outer_dir, "Manifest.toml") => ("""
            julia_version = "1.11.0"
            manifest_format = "2.0"
            project_hash = "abc123"

            [[deps.Deved]]
            deps = []
            path = "Deved"
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee4a"
            version = "0.1.0"
            """, "toml"),
        ]
    ]

    jw = JuliaWorkspace()
    for (path, (content, lang)) in files
        write(path, content)
        _add_file!(jw, TextFile(filepath2uri(path), SourceText(content, lang)))
    end
    outer_uri = filepath2uri(outer_dir)
    _set_active_project!(jw, outer_uri)

    required = derived_required_dynamic_projects(jw.runtime)
    key_of(dir) = _test_environment_key(jw.runtime, filepath2uri(dir),
        derived_package(jw.runtime, filepath2uri(dir)))

    outer_hash = derived_project(jw.runtime, outer_uri).content_hash

    # A package that is its own project provides its own test env.
    @test key_of(own_dir) == WatchTestEnvironmentKey(own_dir, "Own",
        derived_project(jw.runtime, filepath2uri(own_dir)).content_hash)
    # No manifest and nothing devs it: keyed on the package folder, hash 0.
    @test key_of(bare_dir) == WatchTestEnvironmentKey(bare_dir, "Bare", UInt64(0))
    # Deved: the active project provides the test env.
    @test key_of(deved_dir) == WatchTestEnvironmentKey(outer_dir, "Deved", outer_hash)

    for dir in (own_dir, bare_dir, deved_dir)
        @test key_of(dir) in required
    end
    # ...and every test-env item in the required set is one of those keys.
    @test Set(k for k in required if k isa WatchTestEnvironmentKey) ==
        Set(key_of(dir) for dir in (own_dir, bare_dir, deved_dir))
end
