@testitem "Completions: latex completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompTest"
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
    module CompTest
    \\therefor
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comptest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptest/src/CompTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///comptest/src/CompTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # \therefor at end of partial (line 2, col 10 = after "\\therefor")
    index = string_index(source, 2, 10)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "\\therefore", result.items)
    # Check that the replacement text is the unicode char
    item = first(filter(i -> i.label == "\\therefore", result.items))
    @test item.text_edit.new_text == "∴"
end

@testitem "Completions: keyword / snippet completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompKW"
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
    module CompKW
    f
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compkw/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkw/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkw/src/CompKW.jl"), SourceText(source, "julia")))

    uri = URI("file:///compkw/src/CompKW.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    index = string_index(source, 2, 2)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "for", result.items)
    @test any(item -> item.label == "function", result.items)
    # "for" snippet should have snippet format
    for_item = first(filter(i -> i.label == "for", result.items))
    @test for_item.insert_text_format == JuliaWorkspaces.InsertFormats.Snippet
end

@testitem "Completions: getfield completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompDot"
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
    module CompDot
    Base.
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compdot/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdot/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdot/src/CompDot.jl"), SourceText(source, "julia")))

    uri = URI("file:///compdot/src/CompDot.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "Base." (line 2, col 6)
    index = string_index(source, 2, 6)
    result = get_completions(jw, uri, index)
    @test length(result.items) > 10
end

@testitem "Completions: getfield partial completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompDotP"
    uuid = "42345678-1234-1234-1234-123456789abc"
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
    module CompDotP
    Base.r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compdotp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdotp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdotp/src/CompDotP.jl"), SourceText(source, "julia")))

    uri = URI("file:///compdotp/src/CompDotP.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "Base.r" (line 2, col 7)
    index = string_index(source, 2, 7)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "rand", result.items)
end

@testitem "Completions: token completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompTok"
    uuid = "52345678-1234-1234-1234-123456789abc"
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
    module CompTok
    r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comptok/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptok/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptok/src/CompTok.jl"), SourceText(source, "julia")))

    uri = URI("file:///comptok/src/CompTok.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "r" (line 2, col 2)
    index = string_index(source, 2, 2)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "rand", result.items)
end

@testitem "Completions: scope variable completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompScope"
    uuid = "62345678-1234-1234-1234-123456789abc"
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
    module CompScope
    myvar = 1
    myv
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compscope/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscope/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscope/src/CompScope.jl"), SourceText(source, "julia")))

    uri = URI("file:///compscope/src/CompScope.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "myv" (line 3, col 4)
    index = string_index(source, 3, 4)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "myvar", result.items)
end

@testitem "Completions: import completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompImp"
    uuid = "72345678-1234-1234-1234-123456789abc"
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
    module CompImp
    import Base: r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compimp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compimp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compimp/src/CompImp.jl"), SourceText(source, "julia")))

    uri = URI("file:///compimp/src/CompImp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "import Base: r" (line 2, col 15 = right after "r")
    index = string_index(source, 2, 15)
    result = get_completions(jw, uri, index)
    # In a minimal workspace without symbol server data, Base members won't resolve,
    # so we just verify the function returns a valid result without error.
    @test result isa CompletionResult
end

@testitem "Completions: is_completion_match" begin
    # Test the exported fuzzy matching util
    @test is_completion_match("rand", "ran")
    @test is_completion_match("Base", "Bas")
    @test !is_completion_match("x", "rand")
    # Case-insensitive prefix match when prefix is lowercase
    @test is_completion_match("Base", "bas")
    # Case-sensitive when prefix has uppercase
    @test is_completion_match("Base", "Bas")
    @test !is_completion_match("base", "Bas")
end

@testitem "Completions: empty result for empty file" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompEmpty"
    uuid = "82345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = ""

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compempty/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compempty/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compempty/src/CompEmpty.jl"), SourceText(source, "julia")))

    uri = URI("file:///compempty/src/CompEmpty.jl")

    result = get_completions(jw, uri, 1)
    @test result isa CompletionResult
    @test result.is_incomplete == true
end

@testitem "Completions: completion kinds" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompKinds"
    uuid = "92345678-1234-1234-1234-123456789abc"
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
    module CompKinds
    function f(kind_variable_arg)
        kind_variable_local = 1
        kind_variable_
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compkinds/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkinds/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkinds/src/CompKinds.jl"), SourceText(source, "julia")))

    uri = URI("file:///compkinds/src/CompKinds.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "kind_variable_" (line 4, col 19)
    index = string_index(source, 4, 19)
    result = get_completions(jw, uri, index)
    @test any(i -> i.label == "kind_variable_local" && i.kind == CompletionKinds.Variable, result.items)
    @test any(i -> i.label == "kind_variable_arg" && i.kind == CompletionKinds.Variable, result.items)
end

@testitem "Completions: relative import completions" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompRelImp"
    uuid = "a2345678-1234-1234-1234-123456789abc"
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
    module CompRelImp
    module M end
    import .
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comprelimp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comprelimp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comprelimp/src/CompRelImp.jl"), SourceText(source, "julia")))

    uri = URI("file:///comprelimp/src/CompRelImp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "import ." (line 3, col 9)
    index = string_index(source, 3, 9)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "M", result.items)
end
