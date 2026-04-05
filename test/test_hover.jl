@testitem "Hover: basic identifiers and nothing cases" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverTest"
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
    module HoverTest

    1234
    Base
    +
    vari = 1234
    \"\"\"
        Text
    \"\"\"
    function func(arg) end
    func() = nothing
    module M end
    struct T end
    mutable struct T2 end
    for i = 1:1 end
    while true end
    begin end
    sin()

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hovertest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovertest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovertest/src/HoverTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///hovertest/src/HoverTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1  # +1 for newline
        end
        return idx + col
    end

    # Hovering over a bare integer literal should return nothing
    @test get_hover_text(jw, uri, index_of(source, 3, 2)) === nothing

    # Hovering over `Base` should produce hover text (it's a known module)
    result = get_hover_text(jw, uri, index_of(source, 4, 1))
    @test result !== nothing

    # Hovering over `+` operator should produce text
    result = get_hover_text(jw, uri, index_of(source, 5, 1))
    @test result !== nothing

    # Hovering over `vari` identifier should produce text
    result = get_hover_text(jw, uri, index_of(source, 6, 1))
    @test result !== nothing

    # Hovering over `func` in function definition should produce text
    result = get_hover_text(jw, uri, index_of(source, 10, 10))
    @test result !== nothing

    # Hovering over `func` in second method should produce text
    result = get_hover_text(jw, uri, index_of(source, 11, 1))
    @test result !== nothing
end

@testitem "Hover: closer keywords" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverCloser"
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
    module HoverCloser

    function foo(x)
        x + 1
    end

    for i = 1:10
        i
    end

    while true
        break
    end

    module Inner
    end

    struct MyStruct
        a
    end

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hovercloser/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovercloser/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovercloser/src/HoverCloser.jl"), SourceText(source, "julia")))

    uri = URI("file:///hovercloser/src/HoverCloser.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hover on `end` of function definition (line 5)
    result = get_hover_text(jw, uri, index_of(source, 5, 1))
    @test result !== nothing
    @test occursin("foo", result)

    # Hover on `end` of for loop (line 9)
    result = get_hover_text(jw, uri, index_of(source, 9, 1))
    @test result !== nothing
    @test occursin("for", result)

    # Hover on `end` of while loop (line 13)
    result = get_hover_text(jw, uri, index_of(source, 13, 1))
    @test result !== nothing
    @test occursin("while", result)

    # Hover on `end` of module Inner (line 16)
    result = get_hover_text(jw, uri, index_of(source, 16, 1))
    @test result !== nothing
    @test occursin("Inner", result)
end

@testitem "Hover: docstrings" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverDocs"
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
    module HoverDocs

    "I have a docstring"
    Base.@kwdef struct SomeStruct
        a
    end

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverdocs/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverdocs/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverdocs/src/HoverDocs.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverdocs/src/HoverDocs.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over SomeStruct should include the docstring
    result = get_hover_text(jw, uri, index_of(source, 4, 22))
    @test result !== nothing
    @test occursin("I have a docstring", result)
end

@testitem "Hover: struct field position" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverFields"
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
    module HoverFields

    struct S
        a
        b
        c
        d
        e
        f
        g
    end
    S(1,2,3,4,5,6,7)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverfields/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverfields/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverfields/src/HoverFields.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverfields/src/HoverFields.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over argument in S(1,...) constructor call — the `1` is arg 1 which corresponds to field `a`
    result = get_hover_text(jw, uri, index_of(source, 12, 3))
    @test result !== nothing
    @test occursin("a", result) || occursin("Argument 1", result)
end

@testitem "Hover: qualified function argument position" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverQual"
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
    module HoverQual

    module M
        f(a,b,c,d,e) = 1
    end
    M.f(1,2,3,4,5)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverqual/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverqual/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverqual/src/HoverQual.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverqual/src/HoverQual.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over the first argument `1` in `M.f(1,2,3,4,5)` line 6
    result = get_hover_text(jw, uri, index_of(source, 6, 5))
    @test result !== nothing
    @test occursin("Argument 1", result) && occursin("M.f", result)
end
