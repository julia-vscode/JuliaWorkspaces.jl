@testitem "Documents add text file" begin
    using JuliaWorkspaces.URIs2
    jw = JuliaWorkspace()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    text_file = get_text_file(jw, uri)

    @test text_file.uri == uri
    @test text_file.content.content == content
    @test text_file.content.language_id == "julia"

    a = get_julia_syntax_tree(jw, uri)

    @test a !== nothing
end

@testitem "Documents add duplicate file" begin
    using JuliaWorkspaces.URIs2
    jw = JuliaWorkspace()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    @test_throws JuliaWorkspaces.JWDuplicateFile add_text_file(jw, TextFile(uri, SourceText(content, "julia")))
end

