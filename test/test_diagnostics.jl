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

@testitem "@nospecialize params no false MissingRef" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NosTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    version = "0.1.0"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # Cover: default value, no default, type annotation, and keyword parameter
    source = """
    module NosTest
    struct Unknown end
    function foo(x, @nospecialize(prev=Unknown()), @nospecialize(y), @nospecialize(z::Int); @nospecialize(kw=1))
        prev
        y
        z
        kw
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nostest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///nostest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///nostest/src/NosTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///nostest/src/NosTest.jl")
    diags = get_diagnostic(jw, uri)

    missing_ref_diags = filter(d -> startswith(d.message, "Missing reference"), diags)
    @test isempty(missing_ref_diags)
end
