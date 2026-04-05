@testitem "Symbols: document symbols basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SymTest"
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
    module SymTest
    a = 1
    b = 2
    function func() end
    struct T
        field1
        field2
    end
    module Inner end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///symtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///symtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///symtest/src/SymTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///symtest/src/SymTest.jl")

    symbols = get_document_symbols(jw, uri)
    @test !isempty(symbols)

    # The top-level module should contain the bindings
    names = [s.name for s in symbols]
    # Check we have typical symbols — the module itself should be one
    all_names = String[]
    function collect_names(syms)
        for s in syms
            push!(all_names, s.name)
            collect_names(s.children)
        end
    end
    collect_names(symbols)
    @test "func" in all_names
    @test "T" in all_names
    @test "Inner" in all_names
end

@testitem "Symbols: workspace symbols search" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "WsSymTest"
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
    module WsSymTest
    my_global_func(x) = x + 1
    another_func(y) = y * 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wssymtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wssymtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wssymtest/src/WsSymTest.jl"), SourceText(source, "julia")))

    # Search for "my_" — should find my_global_func
    results = get_workspace_symbols(jw, "my_")
    @test !isempty(results)
    @test any(r -> r.name == "my_global_func", results)

    # Search for "another" — should find another_func
    results2 = get_workspace_symbols(jw, "another")
    @test !isempty(results2)
    @test any(r -> r.name == "another_func", results2)

    # Search for "nonexistent" — should be empty
    results3 = get_workspace_symbols(jw, "nonexistent")
    @test isempty(results3)
end
