@testitem "markdownsyntax api: chunk classification" setup=[MdTS] begin
    mk(info) = "```" * info * "\ncode\n```\n"

    # The decided fence set: plain julia, brace-delimited chunk headers, and
    # Documenter's plain-Julia block types.
    @test chunk_rows(mk("julia"))[1][1] == :julia
    @test chunk_rows(mk(" julia "))[1][1] == :julia
    @test chunk_rows(mk("{julia}"))[1][1] == :julia_attrs
    @test chunk_rows(mk("{julia; echo=false}"))[1][1] == :julia_attrs
    @test chunk_rows(mk("{julia, results=\"hidden\"}"))[1][1] == :julia_attrs
    @test chunk_rows(mk("@example"))[1] == (:example, "", "code\n")
    @test chunk_rows(mk("@example demo"))[1] == (:example, "demo", "code\n")
    @test chunk_rows(mk("@setup name"))[1] == (:setup, "name", "code\n")
    @test chunk_rows(mk("@repl sess"))[1] == (:repl, "sess", "code\n")
    @test chunk_rows(mk("@eval"))[1] == (:eval, "", "code\n")

    # Not Julia: plain fences, other languages, REPL-transcript formats,
    # and near-miss info strings.
    for info in ("", "python", "julia-repl", "jldoctest", "jldoctest mylabel",
                 "{r}", "{juliette}", "juliascript", "@meta", "@docs")
        @test isempty(MD.julia_chunks(mk(info)))
    end
end

@testitem "markdownsyntax api: shadow source" setup=[MdTS] begin
    src = "# Héading with ünïcode\n\n```julia\nf(x) = x + 1\n```\n\nprose &&& ]\n"
    shadow = MD.julia_shadow_source(src)

    # Byte-for-byte length and line structure.
    @test sizeof(shadow) == sizeof(src)
    @test findall(==(UInt8('\n')), codeunits(shadow)) == findall(==(UInt8('\n')), codeunits(src))

    # Chunk bytes verbatim, everything else spaces.
    c = MD.julia_chunks(src)[1]
    @test slice(shadow, c.code_range) == "f(x) = x + 1\n"
    outside = setdiff(1:sizeof(src), c.code_range)
    @test all(codeunits(shadow)[i] in (UInt8(' '), UInt8('\n')) for i in outside)

    # The shadow parses as Julia and the definition lands at the real offset.
    parsed = Meta.parse(shadow, first(c.code_range))
    @test parsed[1].head == :(=)

    # CRLF survives blanking.
    src = "prose\r\n```julia\r\nx\r\n```\r\n"
    shadow = MD.julia_shadow_source(src)
    @test sizeof(shadow) == sizeof(src)
    @test occursin("\r\n", shadow)
    @test slice(shadow, MD.julia_chunks(src)[1].code_range) == "x\r\n"

    # No chunks at all: everything is blanked.
    shadow = MD.julia_shadow_source("just prose\n")
    @test shadow == "          \n"
end

@testitem "markdownsyntax api: tree accessors" setup=[MdTS] begin
    JS = MD.JuliaSyntax
    src = "```julia\nx\n```\n"
    tree = MD.parsemd(src; filename="doc.md")
    @test JS.kind(tree) == MD.K"md_document"
    @test JS.filename(tree) == "doc.md"
    fence = JS.children(tree)[1]
    @test JS.kind(fence) == MD.K"md_code_fence"
    cs = JS.children(fence)
    @test [JS.kind(c) for c in cs] == [MD.K"MdFenceDelim", MD.K"MdCode", MD.K"MdFenceDelim"]
    @test cs[1].val == "julia"
    @test cs[3].val == ""
    @test JS.byte_range(fence) == 1:sizeof(src)

    # The whole input is covered: an empty document too.
    @test JS.byte_range(MD.parsemd("")) == 1:0
end
