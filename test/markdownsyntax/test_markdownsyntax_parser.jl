@testitem "markdownsyntax parser: fences" setup=[MdTS] begin
    # A plain fence, tilde fences, and info strings.
    src = "a\n```julia\nx = 1\n```\nb\n~~~julia\ny\n~~~\n"
    @test blocks(src) == [
        ("md_code_fence", "```julia\nx = 1\n```\n"),
        ("md_code_fence", "~~~julia\ny\n~~~\n"),
    ]

    # The closing fence must be at least as long as the opener and of the
    # same character; longer runs close, shorter runs are content.
    src = "````julia\n```\nx\n````\n"
    @test chunk_rows(src) == [(:julia, "", "```\nx\n")]
    src = "```julia\nx\n~~~\n```\n"
    @test chunk_rows(src) == [(:julia, "", "x\n~~~\n")]

    # An unclosed fence runs to the end of the input (CommonMark), and an
    # empty fence has a zero-width code range.
    src = "```julia\nx = 1\n"
    @test chunk_rows(src) == [(:julia, "", "x = 1\n")]
    src = "```julia\n```\n"
    chunks = MD.julia_chunks(src)
    @test length(chunks) == 1 && isempty(chunks[1].code_range)

    # Up to three columns of indentation open a fence; four do not.
    @test chunk_rows("   ```julia\n   x\n   ```\n") == [(:julia, "", "   x\n")]
    @test isempty(MD.julia_chunks("    ```julia\n    x\n    ```\n"))

    # A backtick fence's info string must not contain a backtick; tilde
    # fences have no such restriction.
    @test isempty(MD.julia_chunks("``` julia `x` \ncode\n```\n"))
    @test length(MD.julia_chunks("~~~ julia\ncode\n~~~\n")) == 1
end

@testitem "markdownsyntax parser: indented code protects fence lookalikes" setup=[MdTS] begin
    # A fence marker inside an indented code block is text.
    src = "para\n\n    ```julia\n    not_code()\n\nafter\n"
    @test isempty(MD.julia_chunks(src))
    @test any(b -> b[1] == "MdIndentedCode", blocks(src))

    # Indented code cannot interrupt a paragraph: the indented line is a
    # lazy continuation, so a fence after it still opens.
    src = "para\n    still para\n```julia\nx\n```\n"
    @test chunk_rows(src) == [(:julia, "", "x\n")]

    # Trailing blank lines are not part of the indented block.
    src = "\n    code\n\n\n```julia\nx\n```\n"
    @test chunk_rows(src) == [(:julia, "", "x\n")]
end

@testitem "markdownsyntax parser: front matter and headings" setup=[MdTS] begin
    # Front matter delimiters are not prose, not headings, not fences.
    src = "---\ntitle: x\n---\n\n```julia\nx\n```\n"
    bs = blocks(src)
    @test bs[1] == ("md_front_matter", "---\ntitle: x\n---\n")
    @test chunk_rows(src) == [(:julia, "", "x\n")]

    # `...` closes front matter too; an unclosed opener is prose.
    @test blocks("---\ntitle: x\n...\n")[1][1] == "md_front_matter"
    @test all(b -> b[1] != "md_front_matter", blocks("---\ntitle: x\n"))
    # Only at the very start of the document.
    @test all(b -> b[1] != "md_front_matter", blocks("a\n---\nx\n---\n"))

    # ATX headings carry level and title; a hash run without a space is prose.
    tree = MD.parsemd("## Two words ##\n")
    JS = MD.JuliaSyntax
    h = JS.children(tree)[1]
    @test JS.kind(h) == MD.K"MdHeading"
    @test h.val == (level=2, title="Two words")
    @test isempty(blocks("#nospace\n"))
    @test isempty(blocks("####### seven\n"))
end

@testitem "markdownsyntax parser: CRLF and BOM" setup=[MdTS] begin
    # CRLF line endings: ranges are byte-exact, EOLs preserved in content.
    src = "# T\r\n\r\n```julia\r\nx = 1\r\n```\r\n"
    @test chunk_rows(src) == [(:julia, "", "x = 1\r\n")]

    # A leading BOM sits inside the sentinel; the parse is unaffected.
    src = "\ufeff```julia\nx\n```\n"
    @test chunk_rows(src) == [(:julia, "", "x\n")]
end
