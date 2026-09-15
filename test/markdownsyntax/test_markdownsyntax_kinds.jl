@testitem "markdownsyntax kinds: registration and predicates" setup=[MdTS] begin
    JS = MD.JuliaSyntax
    @test parentmodule(MD.K"md_document") === MD
    @test parentmodule(MD.K"MdFenceDelim") === MD
    @test string(MD.K"md_code_fence") == "md_code_fence"

    @test MD.is_md_trivia(MD.K"MdText")
    @test !MD.is_md_trivia(MD.K"MdCode")
    @test MD.is_md_nonterminal(MD.K"md_document")
    @test MD.is_md_nonterminal(MD.K"md_front_matter")
    @test !MD.is_md_nonterminal(MD.K"MdHeading")

    # Re-registering the same list is a no-op, as the standalone package's
    # `__init__` relies on.
    @test MD._register_markdown_kinds() === nothing
end
