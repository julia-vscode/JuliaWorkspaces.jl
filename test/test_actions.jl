@testitem "Actions: get_code_actions finds ExpandFunction" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ActTest"
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
    module ActTest
    f(x) = x + 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///acttest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///acttest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///acttest/src/ActTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///acttest/src/ActTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # On "x" in "f(x) = x + 1" (line 2, col 3 — clearly inside the function)
    idx = string_index(source, 2, 3)
    actions = get_code_actions(jw, uri, idx, String[])
    ids = [a.id for a in actions]
    @test "ExpandFunction" in ids
end

@testitem "Actions: execute ExpandFunction" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "ExpandTest"
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
    module ExpandTest
    f(x) = x + 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///expandtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///expandtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///expandtest/src/ExpandTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///expandtest/src/ExpandTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    idx = string_index(source, 2, 3)
    edits = execute_code_action(jw, "ExpandFunction", uri, idx)
    @test !isempty(edits)
    @test edits[1] isa WorkspaceFileEdit
    # The edit should contain "function" keyword
    @test any(occursin("function", e.new_text) for e in edits[1].edits)
end

@testitem "Actions: RewriteAsRawString on string literal" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "RawTest"
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
    module RawTest
    x = "hello\\nworld"
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///rawtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rawtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rawtest/src/RawTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///rawtest/src/RawTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # On the string literal (line 2, col 6 — inside the quoted string)
    idx = string_index(source, 2, 6)
    actions = get_code_actions(jw, uri, idx, String[])
    ids = [a.id for a in actions]
    @test "RewriteAsRawString" in ids
end

@testitem "Actions: no actions on whitespace" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NoActTest"
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
    module NoActTest

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///noacttest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///noacttest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///noacttest/src/NoActTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///noacttest/src/NoActTest.jl")

    # On the empty line (line 2, col 1 — just whitespace)
    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    idx = string_index(source, 2, 1)
    actions = get_code_actions(jw, uri, idx, String[])
    # Should have no function-related actions
    @test !any(a.id == "ExpandFunction" for a in actions)
end

@testitem "Actions: AddLicenseIdentifier appears on first line" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        # Create a minimal project with a LICENSE file
        write(joinpath(dir, "Project.toml"), """
        name = "LicTest"
        uuid = "52345678-1234-1234-1234-123456789abc"
        version = "0.1.0"
        """)
        write(joinpath(dir, "Manifest.toml"), """
        # This file is machine-generated - editing it directly is not advised

        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "abc123"

        [deps]
        """)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "LicTest.jl"), "module LicTest\nend\n")
        write(joinpath(dir, "LICENSE"), "MIT License\n\nCopyright (c) 2024\n")

        source = read(joinpath(dir, "src", "LicTest.jl"), String)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Project.toml")), SourceText(read(joinpath(dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Manifest.toml")), SourceText(read(joinpath(dir, "Manifest.toml"), String), "toml")))
        src_uri = filepath2uri(joinpath(dir, "src", "LicTest.jl"))
        add_file!(jw, TextFile(src_uri, SourceText(source, "julia")))

        workspace_folders = [dir]

        # On first line, col 2 (the 'o' in 'module') -> should offer AddLicenseIdentifier
        actions = get_code_actions(jw, src_uri, 2, String[], workspace_folders)
        ids = [a.id for a in actions]
        @test "AddLicenseIdentifier" in ids
    end
end

@testitem "Actions: AddLicenseIdentifier not offered without workspace_folders" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "NoWsTest"
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

    source = "module NoWsTest\nend\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nowstest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///nowstest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    uri = URI("file:///nowstest/src/NoWsTest.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # No workspace_folders → should not offer AddLicenseIdentifier
    actions = get_code_actions(jw, uri, 2, String[])
    ids = [a.id for a in actions]
    @test !("AddLicenseIdentifier" in ids)
end

@testitem "Actions: AddLicenseIdentifier not offered on non-first line" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), """
        name = "Line2Test"
        uuid = "72345678-1234-1234-1234-123456789abc"
        version = "0.1.0"
        """)
        write(joinpath(dir, "Manifest.toml"), """
        # This file is machine-generated - editing it directly is not advised

        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "abc123"

        [deps]
        """)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "Line2Test.jl"), "module Line2Test\nend\n")
        write(joinpath(dir, "LICENSE"), "MIT License\n\nCopyright (c) 2024\n")

        source = read(joinpath(dir, "src", "Line2Test.jl"), String)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Project.toml")), SourceText(read(joinpath(dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Manifest.toml")), SourceText(read(joinpath(dir, "Manifest.toml"), String), "toml")))
        src_uri = filepath2uri(joinpath(dir, "src", "Line2Test.jl"))
        add_file!(jw, TextFile(src_uri, SourceText(source, "julia")))

        workspace_folders = [dir]

        # On second line (the "end") -> should NOT offer AddLicenseIdentifier
        function string_index(src, line, col)
            lines = split(src, '\n')
            off = 0
            for l in 1:(line - 1)
                off += ncodeunits(lines[l]) + 1
            end
            return off + col
        end

        idx = string_index(source, 2, 1)
        actions = get_code_actions(jw, src_uri, idx, String[], workspace_folders)
        ids = [a.id for a in actions]
        @test !("AddLicenseIdentifier" in ids)
    end
end

@testitem "Actions: execute AddLicenseIdentifier inserts SPDX header" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), """
        name = "ExecLicTest"
        uuid = "82345678-1234-1234-1234-123456789abc"
        version = "0.1.0"
        """)
        write(joinpath(dir, "Manifest.toml"), """
        # This file is machine-generated - editing it directly is not advised

        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "abc123"

        [deps]
        """)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "ExecLicTest.jl"), "module ExecLicTest\nend\n")
        write(joinpath(dir, "LICENSE"), "MIT License\n\nCopyright (c) 2024\n")

        source = read(joinpath(dir, "src", "ExecLicTest.jl"), String)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Project.toml")), SourceText(read(joinpath(dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(dir, "Manifest.toml")), SourceText(read(joinpath(dir, "Manifest.toml"), String), "toml")))
        src_uri = filepath2uri(joinpath(dir, "src", "ExecLicTest.jl"))
        add_file!(jw, TextFile(src_uri, SourceText(source, "julia")))

        workspace_folders = [dir]

        edits = execute_code_action(jw, "AddLicenseIdentifier", src_uri, 2, workspace_folders)
        @test !isempty(edits)
        @test edits[1].uri == src_uri
        @test any(occursin("SPDX-License-Identifier: MIT", e.new_text) for e in edits[1].edits)
    end
end
