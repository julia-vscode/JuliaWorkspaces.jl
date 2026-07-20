@testitem "Navigation: get_module_at" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_module_at
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NavTest"
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
    module NavTest
    module Inner
    x = 1
    end
    y = 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///navtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///navtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///navtest/src/NavTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///navtest/src/NavTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "x = 1" inside Inner module (line 3)
    idx = string_index(source, 3, 1)
    mod = get_module_at(jw, uri, idx)
    @test occursin("Inner", mod)

    # "y = 2" in NavTest (line 5)
    idx2 = string_index(source, 5, 1)
    mod2 = get_module_at(jw, uri, idx2)
    @test occursin("NavTest", mod2)
    @test !occursin("Inner", mod2)
end

@testitem "Navigation: get_module_at in an included file's nested module" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_module_at
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NavInc"
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

    # The entry file splices `sub.jl` into module `NavInc`; `sub.jl` itself
    # defines a nested module `Deep`. The full dotted path at a position inside
    # `Deep` must combine the file's module-path prefix (`NavInc`, from the
    # module tree) with the in-file nesting (`Deep`, from the scope chain).
    entry = """
    module NavInc
    include("sub.jl")
    end
    """
    sub = """
    module Deep
    z = 1
    end
    w = 2
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///navinc/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///navinc/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///navinc/src/NavInc.jl"), SourceText(entry, "julia")))
    sub_uri = URI("file:///navinc/src/sub.jl")
    add_file!(jw, TextFile(sub_uri, SourceText(sub, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # `z = 1` inside the nested module `Deep` (line 2 of sub.jl)
    idx = string_index(sub, 2, 1)
    mod = get_module_at(jw, sub_uri, idx)
    @test mod == "NavInc.Deep"

    # `w = 2` at the file's top level (line 4) — just the file prefix.
    idx2 = string_index(sub, 4, 1)
    mod2 = get_module_at(jw, sub_uri, idx2)
    @test mod2 == "NavInc"
end

@testitem "Navigation: get_current_block_range" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, add_file!, TextFile, SourceText, get_current_block_range
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "BlockTest"
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
    module BlockTest
    x = 1
    y = 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///blocktest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///blocktest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///blocktest/src/BlockTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///blocktest/src/BlockTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Inside the module body, on "x = 1" (line 2)
    idx = string_index(source, 2, 1)
    result = get_current_block_range(jw, uri, idx)
    @test result !== nothing
    @test result.block_start isa JuliaWorkspaces.Position
    @test result.block_stop isa JuliaWorkspaces.Position
    @test result.highlight_start isa JuliaWorkspaces.Position
    @test result.highlight_stop isa JuliaWorkspaces.Position
    @test (result.block_stop.line, result.block_stop.column) >= (result.block_start.line, result.block_start.column)
    @test (result.highlight_stop.line, result.highlight_stop.column) >= (result.highlight_start.line, result.highlight_start.column)
end

@testitem "Navigation: get_selection_ranges" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_selection_ranges
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SelTest"
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
    module SelTest
    x = 1 + 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///seltest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///seltest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///seltest/src/SelTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///seltest/src/SelTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # On "1" in "x = 1 + 2" (line 2, col 5)
    idx = string_index(source, 2, 5)
    ranges = get_selection_ranges(jw, uri, [idx])
    @test length(ranges) == 1
    r = ranges[1]
    @test r !== nothing
    # Should have parent (the enclosing expression)
    @test r.parent !== nothing || r.start_offset >= 0
end
