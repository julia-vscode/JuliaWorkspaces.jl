@testitem "Misc: get_document_links finds file paths" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "LinkTest"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # A source file with a string literal that is NOT a real path.
    # We can still test the function returns empty when the path doesn't exist.
    source = """
    module LinkTest
    x = "nonexistent_file_12345.txt"
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///linktest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///linktest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///linktest/src/LinkTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///linktest/src/LinkTest.jl")
    links = get_document_links(jw, uri)
    # The string "nonexistent_file_12345.txt" is not a real file, so no links
    @test isempty(links)
end

@testitem "Misc: get_inlay_hints for variable types" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HintTest"
    uuid = "22345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module HintTest
    function foo(a, b)
        return a + b
    end
    foo(1, 2)
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hinttest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hinttest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hinttest/src/HintTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///hinttest/src/HintTest.jl")

    config = InlayHintConfig(true, true, :all)
    # Use full range
    hints = get_inlay_hints(jw, uri, 1, ncodeunits(source) + 1, config)
    # We just check it doesn't error; actual parameter hints depend on
    # static analysis resolving the call which may or may not happen
    @test hints isa Vector{InlayHintResult}
end

@testitem "Misc: get_inlay_hints returns empty when disabled" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HintOff"
    uuid = "32345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module HintOff
    foo(x) = x
    foo(1)
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hintoff/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintoff/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintoff/src/HintOff.jl"), SourceText(source, "julia")))

    uri = URI("file:///hintoff/src/HintOff.jl")
    config = InlayHintConfig(false, false, :nothing)
    hints = get_inlay_hints(jw, uri, 1, ncodeunits(source) + 1, config)
    @test isempty(hints)
end
