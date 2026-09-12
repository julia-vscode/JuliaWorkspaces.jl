# End-to-end feature coverage for markdown documents (.md/.jmd): diagnostics,
# navigation and test items served from the Julia view (layer_markdown.jl),
# in both the v1 (CSTParser/StaticLint) and v2 pipelines.

@testsnippet MdFeatures begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText,
        get_diagnostic, get_hover_text, get_definitions, get_references, get_test_items,
        get_document_symbols, set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const JMD = """
    ---
    title: Test document
    ---

    # Intro

    Prose that is not Julia &&& ].

    ```julia
    foo(x) = x + 1
    ```

    More prose.

    ```@example demo
    y = foo(3
    ```
    """

    function md_workspace(text, lid; v2=false)
        uri = URI("file:///mdfeat/doc." * (lid == "juliamarkdown" ? "jmd" : "md"))
        jw = JuliaWorkspace()
        v2 && set_v2_enabled!(jw, true)
        add_file!(jw, TextFile(uri, SourceText(text, lid)))
        return jw, uri
    end

    # A package fixture, so test items in its docs are inside a package.
    function pkg_workspace(md_text; v2=false)
        jw = JuliaWorkspace()
        v2 && set_v2_enabled!(jw, true)
        add_file!(jw, TextFile(URI("file:///pkg/Project.toml"),
            SourceText("name = \"TestPkg\"\nuuid = \"6a1f1d0e-6b46-4b3d-a2c3-8a9f4c1e2d3f\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///pkg/src/TestPkg.jl"),
            SourceText("module TestPkg\nend\n", "julia")))
        md_uri = URI("file:///pkg/docs/src/index.md")
        add_file!(jw, TextFile(md_uri, SourceText(md_text, "markdown")))
        return jw, md_uri
    end
end

@testitem "Markdown features: chunk diagnostics at document offsets" setup=[MdFeatures] begin
    for v2 in (false, true), lid in ("markdown", "juliamarkdown")
        jw, uri = md_workspace(JMD, lid; v2)
        diags = get_diagnostic(jw, uri)

        # Exactly the syntax error in the second chunk; the `&&& ]` prose and
        # the front matter produce nothing.
        syntax = [d for d in diags if d.source == "JuliaSyntax.jl"]
        @test length(syntax) == 1
        d = syntax[1]
        # The range points into the second fence, at real document offsets.
        chunk2 = findfirst("y = foo(3", JMD)
        @test first(d.range) >= first(chunk2)
    end
end

@testitem "Markdown features: navigation across chunks" setup=[MdFeatures] begin
    for v2 in (false, true)
        jw, uri = md_workspace(JMD, "juliamarkdown"; v2)

        # Hover and definition of `foo` used in chunk 2, defined in chunk 1.
        idx = first(findfirst("foo(3", JMD))
        hover = get_hover_text(jw, uri, idx)
        @test hover !== nothing
        @test occursin("foo", hover)

        defs = get_definitions(jw, uri, idx)
        @test length(defs) == 1
        @test defs[1].uri == uri

        # The same requests at a prose position answer empty.
        pidx = first(findfirst("More prose", JMD))
        @test get_hover_text(jw, uri, pidx) === nothing
        @test isempty(get_definitions(jw, uri, pidx))
    end
end

@testitem "Markdown features: document symbols come from the chunks" setup=[MdFeatures] begin
    jw, uri = md_workspace(JMD, "markdown")
    symbols = get_document_symbols(jw, uri)
    @test any(s -> s.name == "foo", symbols)
end

@testitem "Markdown features: prose edits leave the Julia view unchanged" setup=[MdFeatures] begin
    jw, uri = md_workspace(JMD, "markdown")
    before = JuliaWorkspaces.derived_julia_source_view(jw.runtime, uri)

    # Same byte length: a length-changing prose edit would shift the chunk
    # offsets and legitimately change the view.
    edited = replace(JMD, "More prose." => "Xtra prose,")
    @test sizeof(edited) == sizeof(JMD)
    update_file!(jw, TextFile(uri, SourceText(edited, "markdown")))
    after = JuliaWorkspaces.derived_julia_source_view(jw.runtime, uri)

    # Equal values: Salsa's early cutoff shields every Julia analysis from
    # the prose keystroke.
    @test before == after

    # A chunk edit does reach the view.
    edited2 = replace(JMD, "foo(x) = x + 1" => "foo(x) = x + 2")
    update_file!(jw, TextFile(uri, SourceText(edited2, "markdown")))
    @test JuliaWorkspaces.derived_julia_source_view(jw.runtime, uri) != after
end

@testitem "Markdown features: test items in fences are detected" setup=[MdFeatures] begin
    md = """
    # Docs with tests

    ```julia
    @testitem "md hosted" begin
        @test 1 + 1 == 2
    end
    ```
    """
    for v2 in (false, true)
        jw, md_uri = pkg_workspace(md; v2)
        tis = get_test_items(jw, md_uri)
        @test isempty(tis.testerrors)
        @test length(tis.testitems) == 1
        ti = tis.testitems[1]
        @test ti.name == "md hosted"
        # Package-scoped id, exactly like a .jl-hosted item.
        @test ti.id == "TestPkg@6a1f1d0e/docs/src/index.md::md hosted"
        # The code slice is the item body, at real document offsets.
        @test occursin("@test 1 + 1 == 2", ti.code)
        @test occursin("@test 1 + 1 == 2", md[ti.code_range])
    end
end

@testitem "Markdown features: an unterminated test item never leaks prose" setup=[MdFeatures] begin
    # The `begin` opens in one fence and the `end` sits in the next: the parse
    # of the Julia view spans the prose between them, so the code slice must
    # come from the view (blanked) — never from the raw document.
    md = """
    ```julia
    @testitem "spans" begin
        @test true
    ```

    SECRET prose between the fences.

    ```julia
    end
    ```
    """
    for v2 in (false, true)
        jw, md_uri = pkg_workspace(md; v2)
        tis = get_test_items(jw, md_uri)
        for ti in tis.testitems
            @test !occursin("SECRET", ti.code)
        end
        for ts in tis.testsetups
            @test !occursin("SECRET", ts.code)
        end
    end
end

@testitem "Markdown features: chunk-less markdown analyzes as an empty file" setup=[MdFeatures] begin
    for v2 in (false, true)
        jw, uri = md_workspace("# Just a title\n\nProse ]]] &&& .\n", "markdown"; v2)
        @test isempty(get_diagnostic(jw, uri))
        @test isempty(get_document_symbols(jw, uri))
        @test isempty(get_test_items(jw, uri).testitems)
    end
end
