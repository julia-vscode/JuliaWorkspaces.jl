@testitem "Basic synta error" begin
    using JuliaWorkspaces.URIs2: URI

    source = "function foo() end begin"
    uri = URI("file:/bar.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 1
    @test diags[1].range == 19:24
    @test diags[1].severity == :error
    @test diags[1].message == "extra tokens after end of expression"
    @test diags[1].source == "JuliaSyntax.jl"
end

@testitem "Basic synta error 2" begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:/test/test.jl")

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/test/.JuliaLint.toml"), SourceText("syntax-errors = false", "toml")))

    diags = get_diagnostic(jw, uri)

    @test length(diags) == 0
end    
