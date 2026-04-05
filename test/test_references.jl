@testitem "References: find references basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "RefTest"
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
    module RefTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///reftest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///reftest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///reftest/src/RefTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///reftest/src/RefTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 col 1 — should find both the definition and the call
    idx = string_index(source, 3, 1)
    refs = get_references(jw, uri, idx)
    @test length(refs) == 2
    @test all(r -> r.uri == uri, refs)
end

@testitem "References: definitions basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "DefTest"
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
    module DefTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///deftest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///deftest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///deftest/src/DefTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///deftest/src/DefTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 (the call site) — should go to the definition
    idx = string_index(source, 3, 1)
    defs = get_definitions(jw, uri, idx)
    @test !isempty(defs)
    @test all(d -> d.uri == uri, defs)
end

@testitem "References: rename basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "RenTest"
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
    module RenTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///rentest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rentest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rentest/src/RenTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///rentest/src/RenTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 col 1 (the call site) — rename to "myfunc"
    idx = string_index(source, 3, 1)
    edits = get_rename_edits(jw, uri, idx, "myfunc")
    @test length(edits) == 2
    @test all(e -> e.new_text == "myfunc", edits)
    @test all(e -> e.uri == uri, edits)
end

@testitem "References: highlight basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HLTest"
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
    module HLTest
    x = 1
    y = x + 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hltest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hltest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hltest/src/HLTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///hltest/src/HLTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "x" on line 3 (the usage) — should highlight the definition on line 2 (:write) and usage on line 3 (:read)
    idx = string_index(source, 3, 5)
    highlights = get_highlights(jw, uri, idx)
    @test length(highlights) >= 2
    @test any(h -> h.kind == :write, highlights)
    @test any(h -> h.kind == :read, highlights)
end

@testitem "References: can_rename basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CanRenTest"
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
    module CanRenTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///canrentest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///canrentest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///canrentest/src/CanRenTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///canrentest/src/CanRenTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 — should be renamable
    idx = string_index(source, 3, 1)
    result = can_rename(jw, uri, idx)
    @test result !== nothing
    @test result.start_index > 0
    @test result.end_index > result.start_index
end

@testitem "References: empty results on whitespace" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "EmptyRef"
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
    module EmptyRef
    x = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///emptyref/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///emptyref/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///emptyref/src/EmptyRef.jl"), SourceText(source, "julia")))

    uri = URI("file:///emptyref/src/EmptyRef.jl")

    # Beginning of file — should return empty results
    refs = get_references(jw, uri, 1)
    @test isempty(refs)

    defs = get_definitions(jw, uri, 1)
    @test isempty(defs)

    highlights = get_highlights(jw, uri, 1)
    @test isempty(highlights)
end
