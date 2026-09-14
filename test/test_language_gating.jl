# The VS Code extension's document selector for the Julia language server
# includes `markdown` and `juliamarkdown`, so the client sends documentSymbol,
# hover, completion, documentLink and friends for `.md` buffers. Those requests
# must not reach the CST layer: the legacy parser reads a whole document as
# Julia, and on prose it produces garbage — or trips CSTParser's own
# infinite-loop guard. The gate lives at the public API boundary; the parser
# itself states the contract and throws.

@testitem "Language gate: the legacy CST refuses non-Julia documents" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_julia_legacy_syntax_tree, JWNotAJuliaFile, JWUnknownFile
    using JuliaWorkspaces.URIs2: URI

    # Salsa wraps whatever a derived function throws; peel that off.
    _unwrap(e) = e isa JuliaWorkspaces.Salsa.DerivedFunctionException ? _unwrap(e.captured_exception) : e

    jw = JuliaWorkspace()

    md = URI("file:///note.md")
    add_file!(jw, TextFile(md, SourceText("# Title\n\n\\\n]\n", "markdown")))

    # Julia-markdown is Markdown with Julia chunks, so it is refused for the
    # same reason.
    jmd = URI("file:///note.jmd")
    add_file!(jw, TextFile(jmd, SourceText("# Title\n\n\\\n]\n", "juliamarkdown")))

    for uri in (md, jmd)
        err = try
            derived_julia_legacy_syntax_tree(jw.runtime, uri)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test _unwrap(err) isa JWNotAJuliaFile
    end

    missing_uri = URI("file:///nowhere.jl")
    err = try
        derived_julia_legacy_syntax_tree(jw.runtime, missing_uri)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test _unwrap(err) isa JWUnknownFile
end

@testitem "Language gate: the legacy CST parses Julia buffers whatever the URI looks like" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_julia_legacy_syntax_tree
    using JuliaWorkspaces.URIs2: URI, @uri_str

    # The gate is `_is_julia_uri`, which falls back to the recorded language id
    # whenever the URI has no usable path. `file://test.jl` parses the name as
    # the *authority* (the path is empty), and untitled/notebook-cell documents
    # have no extension at all. Gating on the path alone would silently disable
    # every CST-derived feature — linting, references, completions — for them.
    for (uri, text) in (
        (uri"file://test.jl", "primitive type 1 8 end\n"),
        (URI("file:///real.jl"), "x = 1\n"),
        (URI("untitled:Untitled-1"), "x = 1\n"),
        (URI("vscode-notebook-cell:/nb.ipynb#W0"), "x = 1\n"),
    )
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(text, "julia")))
        @test derived_julia_legacy_syntax_tree(jw.runtime, uri).fullspan > 0
    end
end

@testitem "Language gate: every URI-taking entry point tolerates a Markdown document" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, InlayHintConfig
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("# Title\n\nSome prose with `code`.\n", "markdown")))

    @test JuliaWorkspaces.get_hover_text(jw, uri, 1) === nothing
    @test JuliaWorkspaces.can_rename(jw, uri, 1) === nothing
    @test JuliaWorkspaces.get_current_block_range(jw, uri, 1) === nothing
    @test JuliaWorkspaces.get_static_lint_data(jw, uri) === nothing
    @test JuliaWorkspaces.get_module_at(jw, uri, 1) == "Main"

    @test isempty(JuliaWorkspaces.get_definitions(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_references(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_rename_edits(jw, uri, 1, "x"))
    @test isempty(JuliaWorkspaces.get_highlights(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_document_symbols(jw, uri))
    @test isempty(JuliaWorkspaces.get_document_links(jw, uri))
    @test isempty(JuliaWorkspaces.get_code_actions(jw, uri, 1, String[]))
    @test isempty(JuliaWorkspaces.execute_code_action(jw, "noop", uri, 1))
    @test isempty(JuliaWorkspaces.get_inlay_hints(jw, uri, 1, 2, InlayHintConfig(true, true, :all)))

    completions = JuliaWorkspaces.get_completions(jw, uri, 1)
    @test isempty(completions.items)
    @test completions.is_incomplete == false

    @test isempty(JuliaWorkspaces.get_signature_help(jw, uri, 1).signatures)

    @test JuliaWorkspaces.get_selection_ranges(jw, uri, [1, 2]) == [nothing, nothing]

    ti = JuliaWorkspaces.get_test_items(jw, uri)
    @test isempty(ti.testitems) && isempty(ti.testsetups) && isempty(ti.testerrors)
end

@testitem "Language gate: tree accessors throw for a Markdown document" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        get_legacy_cst, get_julia_syntax_tree, JWNotAJuliaFile
    using JuliaWorkspaces.URIs2: URI

    # Salsa wraps whatever a derived function throws; peel that off.
    _unwrap(e) = e isa JuliaWorkspaces.Salsa.DerivedFunctionException ? _unwrap(e.captured_exception) : e

    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("# Title\n", "markdown")))

    for f in (get_legacy_cst, get_julia_syntax_tree)
        err = try
            f(jw, uri)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test _unwrap(err) isa JWNotAJuliaFile
    end
end

@testitem "Language gate: `include` of a Markdown file does not admit it for analysis" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        get_diagnostics, get_julia_files, derived_include_closure
    using JuliaWorkspaces.URIs2: URI

    # `include` takes a path, not a language, so this resolves to a document we
    # hold. It must not join the set every CST-driven query iterates.
    jl = URI("file:///incmd/main.jl")
    md = URI("file:///incmd/README.md")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(jl, SourceText("include(\"README.md\")\nx = 1\n", "julia")))
    add_file!(jw, TextFile(md, SourceText("# Readme\n\n\\\n]\n", "markdown")))

    @test md ∉ get_julia_files(jw)
    @test md ∉ derived_include_closure(jw.runtime, jl)

    # The whole-workspace pass completes rather than handing prose to CSTParser.
    @test get_diagnostics(jw) isa Dict
end

@testitem "Language gate: formatting refuses a Markdown document" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_format_edits
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    # Prose that happens to be parseable as Julia: without a gate the formatter
    # would rewrite the user's Markdown file as Julia code.
    add_file!(jw, TextFile(uri, SourceText("x = 1\n", "markdown")))

    @test_throws Exception get_format_edits(jw, uri)
end

@testitem "Language gate: test items are not detected in a Markdown document" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: URI

    # A Markdown heading is a Julia comment, so a README that quotes a
    # `@testitem` parses as one. The per-file query is what the LS publishes
    # from for every changed file; it must agree with the whole-workspace
    # query, which only ever iterates Julia documents.
    body = "# Notes\n\n@testitem \"from prose\" begin\n    @test true\nend\n"
    md = URI("file:///gatepkg/NOTES.md")
    jl = URI("file:///gatepkg/src/notes.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///gatepkg/Project.toml"),
        SourceText("name = \"GatePkg\"\nuuid = \"7c1f0a4e-5b2d-4c8e-9f3a-1d2e3f4a5b6c\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(md, SourceText(body, "markdown")))
    add_file!(jw, TextFile(jl, SourceText(body, "julia")))

    ti = get_test_items(jw, md)
    @test isempty(ti.testitems) && isempty(ti.testsetups) && isempty(ti.testerrors)
    @test !haskey(get_test_items(jw), md)

    # The same body in a Julia file does report the item, so the fixture is sound.
    @test length(get_test_items(jw, jl).testitems) == 1
    @test haskey(get_test_items(jw), jl)
end

@testitem "Language gate: prose in a Markdown document never reaches the Julia parser" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    # Parsed as Julia, prose like this yields a leaf `K"if"` node from error
    # recovery, which crashed the syntax lint rules (#322). The gate keeps a
    # Markdown file out of the fused parse altogether, so this holds
    # independently of that fix.
    uri = URI("file:///gating/AGENTS.md")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("- Add or update tests for the code you change, even if nobody asked.\n- Prefer using explicit names.\n", "markdown")))

    ti = get_test_items(jw, uri)
    @test isempty(ti.testitems) && isempty(ti.testsetups) && isempty(ti.testerrors)
    @test isempty(get_diagnostic(jw, uri))
end
