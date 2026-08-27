@testitem "Markdown: admonitions render as blockquotes" begin
    using JuliaWorkspaces: _sanitize_docstring

    # Julia's `!!!` admonition body is four-space indented, so a plain markdown
    # renderer shows the `!!!` line literally and turns the body into a code
    # block. It becomes a blockquote instead.
    titled = """
    Intro.

    !!! compat "Julia 1.9"
        The one-argument form requires Julia 1.9

    After.
    """
    @test _sanitize_docstring(titled) == """
    Intro.

    > **Compat: Julia 1.9**
    >
    > The one-argument form requires Julia 1.9

    After.
    """

    # No title: the admonition type is the header. Body paragraphs keep their
    # separation, and the first line that is neither blank nor indented ends
    # the block.
    untitled = """
    !!! warning
        Line one.

        Line two.


    Tail.
    """
    @test _sanitize_docstring(untitled) == """
    > **Warning**
    >
    > Line one.
    >
    > Line two.

    Tail.
    """

    # A tab-indented body is an admonition body too.
    @test _sanitize_docstring("!!! note\n\tTabbed.\n") == "> **Note**\n>\n> Tabbed.\n"

    # An admonition is the last thing in the docstring.
    @test _sanitize_docstring("Text.\n\n!!! tip\n    Do it.\n") ==
        "Text.\n\n> **Tip**\n>\n> Do it.\n"
end

@testitem "Markdown: an indented admonition is converted in place" begin
    using JuliaWorkspaces: _sanitize_docstring

    # Nested in a list item: the body is indented relative to the header, and
    # the blockquote has to keep the header's indent to stay in the item.
    nested = """
    - item one

      !!! note
          Nested body.

    - item two
    """
    @test _sanitize_docstring(nested) == """
    - item one

      > **Note**
      >
      > Nested body.

    - item two
    """

    # Only the header's own indent plus one level is stripped; deeper indent
    # inside the body (a code block, say) is body content and stays.
    @test _sanitize_docstring("  !!! warning\n      Body.\n          code()\n") ==
        "  > **Warning**\n  >\n  > Body.\n  >     code()\n"
end

@testitem "Markdown: sanitizing leaves code blocks and existing rules alone" begin
    using JuliaWorkspaces: _sanitize_docstring

    # `!!!` inside a fenced example is example text, not an admonition.
    fenced = """
    ```julia
    !!! warning
        not an admonition
    ```
    """
    @test _sanitize_docstring(fenced) == fenced

    # A docstring with no admonition is untouched apart from the pre-existing
    # rules: jldoctest blocks render as Julia, headings are demoted.
    @test _sanitize_docstring("```jldoctest\njulia> 1\n```\n") == "```julia\njulia> 1\n```\n"
    @test _sanitize_docstring("Text\n# Examples\n") == "Text\n### Examples\n"
end

@testitem "Markdown: hover renders a docstring admonition as a blockquote" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    source = """
    \"\"\"
        f(x)

    Does a thing.

    !!! warning "Careful"
        This is sharp.
    \"\"\"
    f(x) = x

    g() = f(1)
    """
    uri = URI("file:///mdadmon/test.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    result = get_hover_text(jw, uri, first(findfirst("f(1)", source)))
    @test result !== nothing
    @test occursin("> **Warning: Careful**\n>\n> This is sharp.", result)
    @test !occursin("!!!", result)
end

@testitem "Markdown: word documentation search is sanitized" begin
    using JuliaWorkspaces: JuliaWorkspace, get_doc_from_word

    # `atexit`'s docstring carries a `!!! compat` admonition, and this search
    # path composed hover text without sanitizing it.
    result = get_doc_from_word(JuliaWorkspace(), "atexit")
    if occursin("The one-argument form requires Julia", result)
        @test !occursin("!!!", result)
        @test occursin("> **Compat", result)
    else
        # No store to search in this environment — nothing to assert.
        @test result isa String
    end
end
