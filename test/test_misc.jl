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

@testitem "Misc: get_inlay_hints picks the type-matching method" begin
    using JuliaWorkspaces.URIs2: URI

    # `join([1,2,3], '\n')` must resolve to `join(iterator, delim)`, not the
    # `join(io::IO, iterator)` overload. The delimiter `'\n'` must be labeled
    # `delim=`, not `iterator=`.
    source = """
    module HintPick
    x = join([1,2,3], '\\n')
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hintpick/src/HintPick.jl"), SourceText(source, "julia")))

    uri = URI("file:///hintpick/src/HintPick.jl")
    config = InlayHintConfig(true, false, :all)
    hints = get_inlay_hints(jw, uri, 1, ncodeunits(source) + 1, config)

    # Ordered by position: the array is `iterator`, the char is `delim`.
    @test [h.label for h in hints] == ["iterator=", "delim="]
end

@testitem "Misc: get_inlay_hints parameter names across argument shapes" begin
    using JuliaWorkspaces.URIs2: URI

    function labels(body)
        src = "module M\n$body\nend\n"
        uri = URI("file:///inlayshapes/src/M.jl")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        cfg = InlayHintConfig(true, false, :all)
        return [h.label for h in get_inlay_hints(jw, uri, 1, ncodeunits(src) + 1, cfg)]
    end

    # Positional args of a single-method function.
    @test labels("foo(alpha, beta) = alpha\nx = foo(1, 2)") == ["alpha=", "beta="]
    # Keyword args (with or without `;`) must not suppress the positional hints.
    @test labels("foo(alpha, beta; c=1) = alpha\nx = foo(1, 2; c=3)") == ["alpha=", "beta="]
    @test labels("foo(alpha, beta; c=1) = alpha\nx = foo(1, 2, c=3)") == ["alpha=", "beta="]
    # Nested calls are hinted at both levels.
    @test labels("foo(alpha, beta) = alpha\nx = foo(foo(1,2), 3)") == ["alpha=", "alpha=", "beta=", "beta="]
    # A hint whose label matches the argument text is suppressed.
    @test labels("foo(alpha, beta) = alpha\nalpha = 1\nx = foo(alpha, 2)") == ["beta="]
    # Parameter names of two chars or fewer are suppressed.
    @test labels("foo(a, b) = a\nx = foo(1, 2)") == String[]
    # A single positional argument gets no hint.
    @test labels("foo(alpha) = alpha\nx = foo(1)") == String[]
    # A matrix literal resolves the type-matching `join` overload.
    @test labels("x = join([1 2; 3 4], '\\n')") == ["iterator=", "delim="]
end
