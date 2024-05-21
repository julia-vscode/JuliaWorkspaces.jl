@testitem "Documents constructor" begin
    d = Documents()

    @test isempty(d._sourcetexts)
    @test isempty(d._text_files)
    @test isempty(d._notebook_files)
end

@testitem "Documents add text file" begin
    using JuliaWorkspaces.URIs2
    d_original = Documents()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    d1 = with_changes(d_original, AbstractDocumentChange[DocumentChangeAddTextFile(uri, SourceText(content, "julia"))])
    @test uri in d1._text_files
    @test d1._sourcetexts[uri].content == content
    @test d1._sourcetexts[uri].language_id == "julia"    
end

@testitem "Documents add duplicate file" begin
    using JuliaWorkspaces.URIs2
    d_original = Documents()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    d1 = with_changes(d_original, AbstractDocumentChange[DocumentChangeAddTextFile(uri, SourceText(content, "julia"))])

    @test_throws ErrorException with_changes(d_original, AbstractDocumentChange[DocumentChangeAddTextFile(uri, SourceText(content, "julia"))])
end

