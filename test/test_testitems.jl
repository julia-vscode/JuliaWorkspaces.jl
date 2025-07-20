@testitem "@testitem macro missing all args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testitem is missing a name and code block.", 1:9)
end

@testitem "Wrong type for name" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem :foo
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testitem must have a first argument that is of type String for the name.", 1:14)
end

@testitem "Code block missing" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo"
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "Your @testitem is missing a code block argument.", 1:15)
end

@testitem "Final arg not a code block" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" 3
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The final argument of a @testitem must be a begin end block.", 1:17)
end

@testitem "None kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" bar begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The arguments to a @testitem must be in keyword format.", 1:29)
end

@testitem "Duplicate kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports=true default_imports=false begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The keyword argument default_imports cannot be specified more than once.", 1:68)
end

@testitem "Incomplete kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports= begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The final argument of a @testitem must be a begin end block.", 1:42)
end

@testitem "Wrong default_imports type kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports=4 begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The keyword argument default_imports only accepts bool values.", 1:43)
end

@testitem "non vector arg for tags kw" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=4 begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The keyword argument tags only accepts a vector of symbols.", 1:32)
end

@testitem "Wrong types in tags kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=[4, 8] begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "The keyword argument tags only accepts a vector of symbols.", 1:37)
end

@testitem "Unknown keyword arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" bar=true begin end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "foo", "Unknown keyword argument.", 1:34)
end

@testitem "All parts correctly there" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=[:a, :b] setup=[FooSetup] default_imports=true begin println() end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 1
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 0

    ti = test_results.testitems[1]

    @test ti.name == "foo"
    @test ti.id == "file://src/foo.jl:1"
    @test ti.range == 1:87
    @test ti.code_range == 75:83
    @test ti.option_default_imports == true
    @test ti.option_tags == [:a, :b]
    @test ti.option_setup == [:FooSetup]
end

@testitem "@testmodule macro missing begin end" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testmodule
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testmodule is missing a name and code block.", 1:length(content)-1)
end

@testitem "@testsnippet macro missing begin end block" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsnippet
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testsnippet is missing a name and code block.", 1:length(content)-1)
end

@testitem "@testmodule macro extra args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testmodule "Foo" begin end"""

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testmodule must have a first argument that is an identifier for the name.", 1:length(content))
end

@testitem "@testsnippet macro extra args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsnippet "Foo" begin end"""

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "file://src/foo.jl:error1", "Test definition error", "Your @testsnippet must have a first argument that is an identifier for the name.", 1:length(content))
end

@testitem "@testmodule all correct" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testmodule Foo begin const BAR = 1 end"""

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 1
    @test length(test_results.testerrors) == 0

    tsd = test_results.testsetups[1]

    @test tsd.name == :Foo
    @test tsd.kind == :module
    @test tsd.range == 1:length(content)
    @test tsd.code_range == (length("@testmodule Foo begin ") + 1):(length(content) - 4)
end

@testitem "@testsnippet all correct" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsnippet Foo begin const BAR = 1 end"""

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 1
    @test length(test_results.testerrors) == 0

    tsd = test_results.testsetups[1]

    @test tsd.name == :Foo
    @test tsd.kind == :snippet
    @test tsd.range == 1:length(content)
    @test tsd.code_range == (length("@testsnippet Foo begin ") + 1):(length(content) - 4)
end

@testitem "@testitem project detection" begin
    using Pkg
    using JuliaWorkspaces: JuliaWorkspace
    using JuliaWorkspaces.URIs2: @uri_str, filepath2uri

    mktempdir() do root_path
        cp(joinpath(@__DIR__, "data", "project_detection"), joinpath(root_path, "project_detection"))

        Pkg.activate(joinpath(root_path, "project_detection", "TestPackage2"))
        Pkg.instantiate()

        Pkg.activate(joinpath(root_path, "project_detection"))
        Pkg.develop(PackageSpec(path=joinpath(root_path, "project_detection", "TestPackage3")))
        Pkg.instantiate()

        jw = JuliaWorkspaces.workspace_from_folders([root_path])

        file1_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage2", "src", "TestPackage2.jl"))
        file2_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage3", "src", "TestPackage3.jl"))
        file3_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage4", "src", "TestPackage4.jl"))
    end
end

@testitem "module behind docstring" begin
    using JuliaWorkspaces: JuliaWorkspace
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """
        "Foo"
        module Foo
            @testitem "Test1" begin
                @test 1 + 1 == 2
            end
        end
    """

    jw = JuliaWorkspace()

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 1

    ti = test_results.testitems[1]

    @test ti.name == "Test1"
end

@testitem "versioned manifest files are detected" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: filepath2uri

    mktempdir() do temp_dir
        # Create project with versioned manifest
        project_dir = joinpath(temp_dir, "VersionedProject")
        mkpath(project_dir)
        
        project_file = joinpath(project_dir, "Project.toml")
        write(project_file, """
name = "VersionedProject"
uuid = "12345678-1234-1234-1234-123456789abc"
version = "0.1.0"

[deps]
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
""")
        
        # Create versioned manifest
        versioned_manifest = joinpath(project_dir, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
        write(versioned_manifest, """
julia_version = "$(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
manifest_format = "2.0"
project_hash = "test"

[[deps.Random]]
deps = ["SHA", "Serialization"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.10.0"

[[deps.SHA]]
uuid = "ea8e919c-285b-4e28-92e2-21d1dda8b7a7"
version = "0.7.0"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
version = "1.10.0"
""")
        
        # Add to workspace
        project_uri = filepath2uri(project_file)
        manifest_uri = filepath2uri(versioned_manifest)
        folder_uri = filepath2uri(project_dir)
        
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(project_uri, SourceText(read(project_file, String), "toml")))
        add_file!(jw, TextFile(manifest_uri, SourceText(read(versioned_manifest, String), "toml")))
        
        # Test that versioned manifest IS now detected
        rt = jw.runtime
        potential_projects = JuliaWorkspaces.derived_potential_project_folders(rt)
        
        @test haskey(potential_projects, folder_uri)
        project_info = potential_projects[folder_uri]
        @test project_info.project_file !== nothing
        @test project_info.manifest_file !== nothing  # FIXED: versioned manifest now detected
        
        # This should now return a valid project
        derived_result = JuliaWorkspaces.derived_project(rt, folder_uri)
        @test derived_result !== nothing
        @test derived_result isa JuliaWorkspaces.JuliaProject
    end
end

