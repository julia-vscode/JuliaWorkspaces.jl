@testitem "Signatures: basic function call" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigTest"
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

    source = """
    module SigTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigtest/src/SigTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigtest/src/SigTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Inside func() on line 3, col 6 (between the parens)
    idx = string_index(source, 3, 6)
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    @test any(s -> !isempty(s.parameters), result.signatures)
end

@testitem "Signatures: struct constructor" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigStruct"
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
    module SigStruct
    struct T
        a
        b
    end
    T()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigstruct/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigstruct/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigstruct/src/SigStruct.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigstruct/src/SigStruct.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Inside T() on line 6, col 3
    idx = string_index(source, 6, 3)
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
end

@testitem "Signatures: empty on non-call" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigEmpty"
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
    module SigEmpty
    x = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigempty/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigempty/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigempty/src/SigEmpty.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigempty/src/SigEmpty.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # On "x = 1" — not a call, should return empty
    idx = string_index(source, 2, 1)
    result = get_signature_help(jw, uri, idx)
    @test isempty(result.signatures)
end
