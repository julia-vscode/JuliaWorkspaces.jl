# The VS Code extension's document selector for the Julia language server
# includes `markdown` and `juliamarkdown`, so the client sends documentSymbol,
# hover, completion, documentLink and friends for `.md` buffers. Markdown
# documents are analyzed through their Julia view (layer_markdown.jl): fence
# contents verbatim, everything else blanked, offsets preserved. The gates
# therefore admit markdown at the file level, and the position-taking entry
# points additionally require the position to sit inside a Julia chunk — a
# prose position gets the same empty answers the old hard gate produced.
# Non-Julia payloads that have no Julia view (TOML) are still refused.

@testitem "Language gate: the legacy CST refuses TOML, parses markdown's Julia view" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_julia_legacy_syntax_tree, JWNotAJuliaFile, JWUnknownFile
    using JuliaWorkspaces.URIs2: URI

    # Salsa wraps whatever a derived function throws; peel that off.
    _unwrap(e) = e isa JuliaWorkspaces.Salsa.DerivedFunctionException ? _unwrap(e.captured_exception) : e

    jw = JuliaWorkspace()

    toml = URI("file:///gating/Project.toml")
    add_file!(jw, TextFile(toml, SourceText("name = \"Foo\"\n", "toml")))

    err = try
        derived_julia_legacy_syntax_tree(jw.runtime, toml)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test _unwrap(err) isa JWNotAJuliaFile

    # Markdown and Julia-markdown parse through the shadow view: prose (here
    # containing bytes that would derail CSTParser) is blanked, fence content
    # is real, and the tree spans the whole document.
    for (uri, lid) in ((URI("file:///note.md"), "markdown"),
                       (URI("file:///note.jmd"), "juliamarkdown"))
        text = "# Title\n\n\\n]\n\n```julia\nx = 1\n```\n"
        add_file!(jw, TextFile(uri, SourceText(text, lid)))
        cst = derived_julia_legacy_syntax_tree(jw.runtime, uri)
        @test cst.fullspan == sizeof(text)
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

@testitem "Language gate: prose positions of a Markdown document get empty answers" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, InlayHintConfig
    using JuliaWorkspaces.URIs2: URI

    # A chunk-less markdown document: every position is prose, so every
    # position-taking entry point answers exactly like the old hard gate did.
    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("# Title\n\nSome prose with `code`.\n", "markdown")))

    @test JuliaWorkspaces.get_hover_text(jw, uri, 1) === nothing
    @test JuliaWorkspaces.can_rename(jw, uri, 1) === nothing
    @test JuliaWorkspaces.get_current_block_range(jw, uri, 1) === nothing
    @test JuliaWorkspaces.get_module_at(jw, uri, 1) == "Main"

    # File-level queries run on the (all-whitespace) Julia view.
    @test JuliaWorkspaces.get_static_lint_data(jw, uri) !== nothing
    @test isempty(JuliaWorkspaces.get_document_symbols(jw, uri))
    @test isempty(JuliaWorkspaces.get_document_links(jw, uri))
    @test isempty(JuliaWorkspaces.get_inlay_hints(jw, uri, 1, 2, InlayHintConfig(true, true, :all)))

    @test isempty(JuliaWorkspaces.get_definitions(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_references(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_rename_edits(jw, uri, 1, "x"))
    @test isempty(JuliaWorkspaces.get_highlights(jw, uri, 1))
    @test isempty(JuliaWorkspaces.get_code_actions(jw, uri, 1, String[]))
    @test isempty(JuliaWorkspaces.execute_code_action(jw, "noop", uri, 1))

    completions = JuliaWorkspaces.get_completions(jw, uri, 1)
    @test isempty(completions.items)
    @test completions.is_incomplete == false

    @test isempty(JuliaWorkspaces.get_signature_help(jw, uri, 1).signatures)

    @test JuliaWorkspaces.get_selection_ranges(jw, uri, [1, 2]) == [nothing, nothing]
end

@testitem "Language gate: tree accessors serve a Markdown document's Julia view" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        get_legacy_cst, get_julia_syntax_tree, JWNotAJuliaFile
    using JuliaWorkspaces.URIs2: URI

    # Salsa wraps whatever a derived function throws; peel that off.
    _unwrap(e) = e isa JuliaWorkspaces.Salsa.DerivedFunctionException ? _unwrap(e.captured_exception) : e

    text = "# Title\n\n```julia\nf(x) = x\n```\n"
    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(text, "markdown")))

    @test get_legacy_cst(jw, uri).fullspan == sizeof(text)
    @test get_julia_syntax_tree(jw, uri) !== nothing

    # TOML documents are still refused: they have no Julia view.
    toml = URI("file:///gating/Project.toml")
    add_file!(jw, TextFile(toml, SourceText("name = \"Foo\"\n", "toml")))
    for f in (get_legacy_cst, get_julia_syntax_tree)
        err = try
            f(jw, toml)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test _unwrap(err) isa JWNotAJuliaFile
    end
end

@testitem "Language gate: `include` of a Markdown file does not link it into the include graph" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        get_diagnostics, get_julia_files, derived_include_closure
    using JuliaWorkspaces.URIs2: URI

    # `include` takes a path, not a language, so this resolves to a document we
    # hold. The markdown file is analyzed — as its own root, through its Julia
    # view — but it must not become part of the *includer's* tree, where the
    # legacy pipeline would treat it as a plain Julia child file.
    jl = URI("file:///incmd/main.jl")
    md = URI("file:///incmd/README.md")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(jl, SourceText("include(\"README.md\")\nx = 1\n", "julia")))
    add_file!(jw, TextFile(md, SourceText("# Readme\n\n\\n]\n", "markdown")))

    @test md ∈ get_julia_files(jw)      # admitted as its own markdown root ...
    @test md ∉ derived_include_closure(jw.runtime, jl)   # ... never as an include target

    # The whole-workspace pass completes rather than handing prose to CSTParser.
    @test get_diagnostics(jw) isa Dict
end

@testitem "Language gate: formatting refuses a Markdown document" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_format_edits
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///gating/note.md")
    jw = JuliaWorkspace()
    # Prose that happens to be parseable as Julia: without a gate the formatter
    # would rewrite the user's Markdown file as Julia code. The Julia view is
    # for analysis only — formatting stays strictly Julia.
    add_file!(jw, TextFile(uri, SourceText("x = 1\n", "markdown")))

    @test_throws Exception get_format_edits(jw, uri)
end
