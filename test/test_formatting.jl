# Tests for the native formatting functionality (get_format_edits) and the
# JuliaFormat.toml configuration model.

@testitem "Format: default (minimal) formatting reformats messy code" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function  foo(x )\nreturn x+1\nend\n"
    uri = URI("file:///fmt/messy.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test edit isa JuliaWorkspaces.WorkspaceFileEdit
    @test edit.uri == uri
    @test length(edit.edits) == 1

    te = edit.edits[1]
    # Full-document replacement starts at the very beginning.
    @test te.start == JuliaWorkspaces.Position(1, 1)
    # MinimalStyle (the default) collapses redundant whitespace and reindents,
    # but does not add spaces around binary operators such as `+`.
    @test occursin("function foo(x)", te.new_text)
    @test occursin("    return x+1", te.new_text)
end

@testitem "Format: already-formatted file produces no edits" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo(x)\n    return x + 1\nend\n"
    uri = URI("file:///fmt/clean.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test edit isa JuliaWorkspaces.WorkspaceFileEdit
    @test isempty(edit.edits)
end

@testitem "Format: full-document edit end position covers whole file" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\nbar(c,d)\n"
    uri = URI("file:///fmt/end.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    te = edit.edits[1]
    @test te.start == JuliaWorkspaces.Position(1, 1)
    # Source has two lines plus a trailing newline, so the end position is the
    # start of the (empty) third line.
    @test te.stop == JuliaWorkspaces.Position(3, 1)
    @test occursin("foo(a, b)", te.new_text)
    @test occursin("bar(c, d)", te.new_text)
end

@testitem "Format: explicit default style via JuliaFormat.toml" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\n"
    uri = URI("file:///fmt/d/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/d/JuliaFormat.toml"), SourceText("style = \"default\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test occursin("foo(a, b)", edit.edits[1].new_text)
end

@testitem "Format: blue style is applied" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\n"
    uri = URI("file:///fmt/blue/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/blue/JuliaFormat.toml"), SourceText("style = \"blue\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test occursin("foo(a, b)", edit.edits[1].new_text)
end

@testitem "Format: yas style is applied" begin
    using JuliaWorkspaces.URIs2: URI

    source = "x = [1,2,3]\n"
    uri = URI("file:///fmt/yas/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/yas/JuliaFormat.toml"), SourceText("style = \"yas\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test occursin("[1, 2, 3]", edit.edits[1].new_text)
end

@testitem "Format: sciml style is applied" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\n"
    uri = URI("file:///fmt/sciml/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/sciml/JuliaFormat.toml"), SourceText("style = \"sciml\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test occursin("foo(a, b)", edit.edits[1].new_text)
end

@testitem "Format: runic style routes through Runic" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo(x)\nx+1\nend\n"
    uri = URI("file:///fmt/runic/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/runic/JuliaFormat.toml"), SourceText("style = \"runic\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test !isempty(edit.edits)
    formatted = edit.edits[1].new_text
    # Runic indents with 4 spaces and adds spaces around binary operators.
    @test occursin("    return x + 1", formatted)
end

@testitem "Format: runic matches Runic.format_string directly" begin
    using JuliaWorkspaces.URIs2: URI
    import Runic

    source = "x=1\ny=  2\n"
    uri = URI("file:///fmt/runic2/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/runic2/JuliaFormat.toml"), SourceText("style = \"runic\"\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    @test edit.edits[1].new_text == Runic.format_string(source)
end

@testitem "Format: additional JuliaFormatter option (margin) is honored" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo(averylongargument, anotherlongargument, yetanotherlongargument)\n    return 1\nend\n"
    uri = URI("file:///fmt/margin/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/margin/JuliaFormat.toml"), SourceText("style = \"default\"\n[options]\nmargin = 20\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    # With a tiny margin the call signature must be split over several lines.
    @test !isempty(edit.edits)
    @test count(==('\n'), edit.edits[1].new_text) > 3
end

@testitem "Format: nested JuliaFormat.toml overrides parent" begin
    using JuliaWorkspaces.URIs2: URI

    # A function call that fits comfortably within a margin of 92.
    source = "function foo(averylongargument, anotherlongargument)\n    return 1\nend\n"
    uri = URI("file:///fmt/nest/inner/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    # Parent forces a tiny margin (would split the signature)...
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/nest/JuliaFormat.toml"), SourceText("style = \"default\"\n[options]\nmargin = 1\n", "toml")))
    # ...but the nested config overrides the margin back to the default 92.
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/nest/inner/JuliaFormat.toml"), SourceText("style = \"default\"\n[options]\nmargin = 92\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    # With the nested margin of 92 the signature fits on one line, so there is
    # nothing to change. Had the parent margin of 1 been used, the signature
    # would have been split across several lines.
    @test isempty(edit.edits)
end

@testitem "Format: JuliaFormatter config files are never read" begin
    using JuliaWorkspaces.URIs2: URI

    # A signature that fits within the default margin of 92.
    source = "function foo(averylongargument, anotherlongargument)\n    return 1\nend\n"
    uri = URI("file:///fmt/ignore/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    # A stray .JuliaFormatter.toml forcing a tiny margin must be ignored; only
    # JuliaFormat.toml controls behavior. Note JuliaWorkspaces does not even
    # track .JuliaFormatter.toml files, but adding it as raw text proves it has
    # no effect on formatting.
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/ignore/.JuliaFormatter.toml"), SourceText("margin = 1\n", "toml")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri)

    # Default style with the default margin keeps the signature on one line -> no
    # edit. If the stray JuliaFormatter config had been read, margin = 1 would
    # have split the signature across several lines.
    @test isempty(edit.edits)
end

@testitem "Format: syntax error surfaces as an error" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo( end\n"
    uri = URI("file:///fmt/err/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    @test_throws Exception JuliaWorkspaces.get_format_edits(jw, uri)
end

@testitem "Format range: formats only the requested lines" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\nbar(c,d)\nbaz(e,f)\n"
    uri = URI("file:///fmt/range/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # Only format line 2.
    edit = JuliaWorkspaces.get_format_edits(jw, uri, 2, 2)

    @test edit isa JuliaWorkspaces.WorkspaceFileEdit
    @test length(edit.edits) == 1

    te = edit.edits[1]
    @test te.start == JuliaWorkspaces.Position(2, 1)
    @test te.stop == JuliaWorkspaces.Position(3, 1)
    @test occursin("bar(c, d)", te.new_text)
    @test !occursin("foo", te.new_text)
    @test !occursin("baz", te.new_text)
end

@testitem "Format range: already-formatted range produces no edits" begin
    using JuliaWorkspaces.URIs2: URI

    source = "x = 1\ny = 2\nz = 3\n"
    uri = URI("file:///fmt/range2/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    edit = JuliaWorkspaces.get_format_edits(jw, uri, 2, 2)

    @test isempty(edit.edits)
end

@testitem "Format config: invalid style produces a diagnostic" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/badstyle/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/badstyle/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("style = \"bogus\"\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test length(diags) == 1
    @test diags[1].severity == :error
    @test diags[1].source == "JuliaWorkspaces.jl"
    @test occursin("style", diags[1].message)
end

@testitem "Format config: unknown field produces a diagnostic" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/badfield/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/badfield/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("not_a_real_option = true\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test length(diags) == 1
    @test diags[1].severity == :error
    @test diags[1].source == "JuliaWorkspaces.jl"
    @test occursin("not_a_real_option", diags[1].message)
end

@testitem "Format config: valid config produces no diagnostics" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/goodcfg/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/goodcfg/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("style = \"blue\"\n[options]\nmargin = 80\nalways_use_return = true\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test isempty(diags)
end

@testitem "Format config: runic is a valid style for the config validator" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/runiccfg/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/runiccfg/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("style = \"runic\"\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test isempty(diags)
end

@testitem "Format config: runic with options is an error, not a silent ignore" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/runicopts/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/runicopts/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("style = \"runic\"\n[options]\nmargin = 80\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test any(d -> occursin("does not support any `[options]`", d.message), diags)
end

@testitem "Format config: top-level option key reports the migration" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///fmt/flatopt/JuliaFormat.toml")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/flatopt/code.jl"), SourceText("x = 1\n", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(config_uri, SourceText("margin = 80\n", "toml")))

    diags = get_diagnostic(jw, config_uri)

    @test any(d -> occursin("`margin` is no longer supported", d.message) &&
                   occursin("[options]", d.message), diags)
end

@testitem "Format: exclude suppresses formatting" begin
    using JuliaWorkspaces.URIs2: URI

    source = "foo(a,b)\n"
    uri = URI("file:///fmt/excl/gen/code.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/excl/JuliaFormat.toml"),
        SourceText("style = \"default\"\nexclude = [\"gen/**\"]\n", "toml")))

    @test_throws Exception JuliaWorkspaces.get_format_edits(jw, uri)

    # A sibling outside the excluded tree still formats.
    other = URI("file:///fmt/excl/src/code.jl")
    JuliaWorkspaces.add_file!(jw, TextFile(other, SourceText(source, "julia")))
    @test occursin("foo(a, b)", JuliaWorkspaces.get_format_edits(jw, other).edits[1].new_text)
end

@testitem "Format: override block re-scopes options by path" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo(averylongargument, anotherlongargument)\n    return 1\nend\n"
    config = """
    style = "default"

    [options]
    margin = 92

    [[override]]
    paths = ["docs/**"]

    [override.options]
    margin = 1
    """

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:///fmt/ovr/JuliaFormat.toml"), SourceText(config, "toml")))

    # Outside the override the wide margin keeps the signature on one line.
    plain = URI("file:///fmt/ovr/src/code.jl")
    JuliaWorkspaces.add_file!(jw, TextFile(plain, SourceText(source, "julia")))
    @test isempty(JuliaWorkspaces.get_format_edits(jw, plain).edits)

    # Inside it the tiny margin splits the signature.
    docs = URI("file:///fmt/ovr/docs/code.jl")
    JuliaWorkspaces.add_file!(jw, TextFile(docs, SourceText(source, "julia")))
    @test !isempty(JuliaWorkspaces.get_format_edits(jw, docs).edits)
end
