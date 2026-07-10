@testitem "Misc: get_document_links finds file paths" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_document_links
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
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_inlay_hints, InlayHintConfig, InlayHintResult
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

@testitem "Misc: parameter name inlay hints use method matching" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_inlay_hints, InlayHintConfig, InlayHintResult
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HintNames"
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

    source = """
    module HintNames

    g(x::Int, aaa, bbb) = 1
    g(x::String, ddd, eee) = 2
    g(1, 2, 3)
    g("s", 2, 3)

    w(alpha, beta, gamma = 1) = 1
    w(4, 5)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hintnames/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintnames/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintnames/src/HintNames.jl"), SourceText(source, "julia")))

    uri = URI("file:///hintnames/src/HintNames.jl")

    config = InlayHintConfig(true, false, :all)
    hints = get_inlay_hints(jw, uri, 1, ncodeunits(source) + 1, config)
    labels = [h.label for h in hints if h.kind === :parameter]

    # `g(1, 2, 3)` matches the ::Int method, `g("s", 2, 3)` the ::String one;
    # `w(4, 5)` matches via the optional third argument. `x` is skipped as a
    # too-short label.
    @test labels == ["aaa=", "bbb=", "ddd=", "eee=", "alpha=", "beta="]
end

@testitem "Misc: parameter name inlay hints positional index" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_inlay_hints, InlayHintConfig, InlayHintResult
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HintPositions"
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
    module HintPositions

    k(alpha, beta, gamma; opt = 1) = 1
    k(1, 2, 3; opt = 5)

    m(maa, mbb, mcc = 1; opt = 0) = 1
    m(1, opt = 2, 3)

    s(aaa, bbb, ccc, sxs...) = 1
    tup = (3, 4)
    s(1, tup..., 9)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hintpositions/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintpositions/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hintpositions/src/HintPositions.jl"), SourceText(source, "julia")))

    uri = URI("file:///hintpositions/src/HintPositions.jl")

    config = InlayHintConfig(true, false, :all)
    hints = get_inlay_hints(jw, uri, 1, ncodeunits(source) + 1, config)
    labels = [h.label for h in hints if h.kind === :parameter]

    # The `;`-parameters block and inline kwargs don't shift the positional
    # index, kwargs themselves get no hint, and positions at/after a splat
    # are unknowable.
    @test labels == ["alpha=", "beta=", "gamma=", "maa=", "mbb=", "aaa="]
end

@testitem "Misc: get_inlay_hints returns empty when disabled" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_inlay_hints, InlayHintConfig, InlayHintResult
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
