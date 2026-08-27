@testitem "@testitem macro missing all args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    pkg_dir = joinpath(@__DIR__, "..", "testdata", "TestPackageTestItems")
    src_file = joinpath(pkg_dir, "src", "testitem_all_parts.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(filepath2uri(joinpath(pkg_dir, "Project.toml")), SourceText(read(joinpath(pkg_dir, "Project.toml"), String), "toml")))
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 1
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 0

    ti = test_results.testitems[1]

    @test ti.name == "foo"
    @test ti.range == 1:87
    @test ti.code_range == 75:83
    @test ti.option_default_imports == true
    @test ti.option_tags == [:a, :b]
    @test ti.option_setup == [:FooSetup]
end

@testitem "test items outside package become errors" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    src_file = joinpath(@__DIR__, "..", "testdata", "not_a_package", "testitem_outside_pkg.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    te = test_results.testerrors[1]
    @test te.name == "foo"
    @test te.message == "Test items must be defined inside a Julia package."
end

@testitem "test setups outside package become errors" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    src_file = joinpath(@__DIR__, "..", "testdata", "not_a_package", "testmodule_outside_pkg.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    te = test_results.testerrors[1]
    @test te.name == "Foo"
    @test te.message == "Test setups must be defined inside a Julia package."
end

@testitem "@testmodule macro missing begin end" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
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
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    pkg_dir = joinpath(@__DIR__, "..", "testdata", "TestPackageTestItems")
    src_file = joinpath(pkg_dir, "src", "testmodule_all_correct.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(filepath2uri(joinpath(pkg_dir, "Project.toml")), SourceText(read(joinpath(pkg_dir, "Project.toml"), String), "toml")))
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 1
    @test length(test_results.testerrors) == 0

    tsd = test_results.testsetups[1]

    @test tsd.name == :Foo
    @test tsd.kind == :module
    @test tsd.range == 1:39
    @test tsd.code_range == (length("@testmodule Foo begin ") + 1):(39 - 4)
end

@testitem "@testsnippet all correct" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    pkg_dir = joinpath(@__DIR__, "..", "testdata", "TestPackageTestItems")
    src_file = joinpath(pkg_dir, "src", "testsnippet_all_correct.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(filepath2uri(joinpath(pkg_dir, "Project.toml")), SourceText(read(joinpath(pkg_dir, "Project.toml"), String), "toml")))
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 1
    @test length(test_results.testerrors) == 0

    tsd = test_results.testsetups[1]

    @test tsd.name == :Foo
    @test tsd.kind == :snippet
    @test tsd.range == 1:40
    @test tsd.code_range == (length("@testsnippet Foo begin ") + 1):(40 - 4)
end

@testitem "@testitem project detection" begin
    using Pkg
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, get_test_env
    using JuliaWorkspaces.URIs2: @uri_str, filepath2uri

    old = Base.active_project()
    try

        mktempdir() do root_path
            cp(joinpath(@__DIR__, "..", "testdata", "project_detection"), joinpath(root_path, "project_detection"))

            # Three packages, three ways of belonging to an environment: one
            # instantiated on its own, one dev'd into the enclosing project, and
            # one that no environment resolves at all.
            Pkg.activate(joinpath(root_path, "project_detection", "TestPackage2"))
            Pkg.instantiate()

            Pkg.activate(joinpath(root_path, "project_detection"))
            Pkg.develop(PackageSpec(path=joinpath(root_path, "project_detection", "TestPackage3")))
            Pkg.instantiate()

            jw = JuliaWorkspaces.workspace_from_folders([root_path])

            file1_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage2", "src", "TestPackage2.jl"))
            file2_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage3", "src", "TestPackage3.jl"))
            file3_uri = filepath2uri(joinpath(root_path, "project_detection", "TestPackage4", "src", "TestPackage4.jl"))

            @test get_test_env(jw, file1_uri).project_uri == filepath2uri(joinpath(root_path, "project_detection", "TestPackage2"))
            @test get_test_env(jw, file2_uri).project_uri == filepath2uri(joinpath(root_path, "project_detection"))
            @test get_test_env(jw, file3_uri).project_uri === nothing
        end
    finally
        Base.set_active_project(old)
    end
end

@testitem "module behind docstring" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: filepath2uri

    pkg_dir = joinpath(@__DIR__, "..", "testdata", "TestPackageTestItems")
    src_file = joinpath(pkg_dir, "src", "module_behind_docstring.jl")
    content = read(src_file, String)
    uri = filepath2uri(src_file)

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(filepath2uri(joinpath(pkg_dir, "Project.toml")), SourceText(read(joinpath(pkg_dir, "Project.toml"), String), "toml")))
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

@testitem "handle missing manifest gracefully" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: filepath2uri

    mktempdir() do temp_dir
        # Create a simple project that will work
        project_dir = joinpath(temp_dir, "SimpleProject")
        mkpath(project_dir)

        project_file = joinpath(project_dir, "Project.toml")
        write(
            project_file,
            """
name = "SimpleProject"
uuid = "12345678-1234-1234-1234-123456789abc"
version = "0.1.0"
""",
        )

        # NO MANIFEST - this makes derived_project return nothing

        # Create Julia file
        test_file = joinpath(temp_dir, "test.jl")
        write(test_file, "# Test file")

        # Add to workspace
        project_uri = filepath2uri(project_file)
        test_uri = filepath2uri(test_file)
        folder_uri = filepath2uri(project_dir)

        jw = JuliaWorkspace()
        add_file!(jw, TextFile(project_uri, SourceText(read(project_file, String), "toml")))
        add_file!(jw, TextFile(test_uri, SourceText("# test", "julia")))

        # Set project as active project
        JuliaWorkspaces.set_input_active_project!(jw.runtime, folder_uri)

        rt = jw.runtime

        # Verify derived_project returns nothing (no manifest)
        derived_result = JuliaWorkspaces.derived_project(rt, folder_uri)
        @test derived_result === nothing

        # This should work with defensive programming - no crash on .content_hash
        test_env = get_test_env(jw, test_uri)
        @test test_env isa JuliaWorkspaces.JuliaTestEnv
        @test test_env.project_uri === nothing  # Should be set to nothing due to lack of manifest
    end
end

@testitem "test env content hash covers manifests and test project files" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText, get_test_env
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    [deps]
    Inner = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.Inner]]
    deps = []
    path = "Inner"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    inner_project = """
    name = "Inner"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    inner_test_project = """
    [deps]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    """

    # Scenario 1: the package is deved into an active project (no manifest of its own)
    outer_manifest_uri = URI("file:///hashenv/Manifest.toml")
    inner_test_project_uri = URI("file:///hashenv/Inner/test/Project.toml")
    inner_src_uri = URI("file:///hashenv/Inner/src/Inner.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hashenv/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(outer_manifest_uri, SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hashenv/Inner/Project.toml"), SourceText(inner_project, "toml")))
    add_file!(jw, TextFile(inner_test_project_uri, SourceText(inner_test_project, "toml")))
    add_file!(jw, TextFile(inner_src_uri, SourceText("module Inner end", "julia")))
    JuliaWorkspaces.set_input_active_project!(jw.runtime, URI("file:///hashenv"))

    env0 = get_test_env(jw, inner_src_uri)
    @test env0.package_uri == URI("file:///hashenv/Inner")
    @test env0.project_uri == URI("file:///hashenv")
    hash0 = env0.env_content_hash
    @test hash0 isa String
    @test startswith(hash0, "x")

    # Stable when nothing relevant changes, and across an unrelated src edit
    @test get_test_env(jw, inner_src_uri).env_content_hash == hash0
    update_file!(jw, TextFile(inner_src_uri, SourceText("module Inner
x = 1
end", "julia")))
    @test get_test_env(jw, inner_src_uri).env_content_hash == hash0

    # (a) the active project's Manifest.toml changes
    update_file!(jw, TextFile(outer_manifest_uri, SourceText(manifest_toml * "
# edited
", "toml")))
    hash1 = get_test_env(jw, inner_src_uri).env_content_hash
    @test hash1 != hash0

    # (b) test/Project.toml under the package changes
    update_file!(jw, TextFile(inner_test_project_uri, SourceText(inner_test_project * "
# edited
", "toml")))
    hash2 = get_test_env(jw, inner_src_uri).env_content_hash
    @test hash2 != hash1
    @test hash2 != hash0

    # Scenario 2: a standalone package with its own Manifest.toml
    pkg_manifest = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    """
    pkg_manifest_uri = URI("file:///hashpkg/Manifest.toml")
    pkg_src_uri = URI("file:///hashpkg/src/Inner.jl")

    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///hashpkg/Project.toml"), SourceText(inner_project, "toml")))
    add_file!(jw2, TextFile(pkg_manifest_uri, SourceText(pkg_manifest, "toml")))
    add_file!(jw2, TextFile(pkg_src_uri, SourceText("module Inner end", "julia")))

    env3 = get_test_env(jw2, pkg_src_uri)
    @test env3.package_uri == URI("file:///hashpkg")
    hash3 = env3.env_content_hash
    @test get_test_env(jw2, pkg_src_uri).env_content_hash == hash3

    # (c) the package folder's own Manifest.toml changes
    update_file!(jw2, TextFile(pkg_manifest_uri, SourceText(pkg_manifest * "
# edited
", "toml")))
    hash4 = get_test_env(jw2, pkg_src_uri).env_content_hash
    @test hash4 != hash3
end

@testitem "derived_testenv for a file in a deved package of a project" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_env
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    [deps]
    Inner = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"

    [[deps.Inner]]
    deps = []
    path = "Inner"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    inner_project = """
    name = "Inner"
    uuid = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    version = "2.0.0"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///devedenv/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///devedenv/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///devedenv/Inner/Project.toml"), SourceText(inner_project, "toml")))
    add_file!(jw, TextFile(URI("file:///devedenv/Inner/src/Inner.jl"), SourceText("module Inner end", "julia")))

    # The deved package is the package, the outer folder is the project
    test_env = get_test_env(jw, URI("file:///devedenv/Inner/src/Inner.jl"))
    @test test_env.package_name == "Inner"
    @test test_env.package_uri == URI("file:///devedenv/Inner")
    @test test_env.project_uri == URI("file:///devedenv")
end

@testitem "Test-item detail equality distinguishes empty ranges by position" begin
    using JuliaWorkspaces: TestItemDetail, TestSetupDetail, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    u = uri"file:///t.jl"

    # Empty UnitRanges are == regardless of position (24:23 == 23:22); a shifted
    # empty range (e.g. an EOF marker after a trailing-trivia edit) must count as
    # a change, or Salsa backdating keeps the stale range.
    te_a = TestErrorDetail(u, "id", "n", "msg", 24:23)
    te_b = TestErrorDetail(u, "id", "n", "msg", 23:22)
    @test te_a != te_b
    @test !isequal(te_a, te_b)
    @test hash(te_a) != hash(te_b)

    ti_a = TestItemDetail(u, "id", "n", "code", 24:23, 24:23, true, Symbol[], Symbol[], false)
    ti_b = TestItemDetail(u, "id", "n", "code", 23:22, 23:22, true, Symbol[], Symbol[], false)
    @test ti_a != ti_b
    @test !isequal(ti_a, ti_b)
    @test hash(ti_a) != hash(ti_b)

    ts_a = TestSetupDetail(u, :n, :k, "code", 24:23, 24:23)
    ts_b = TestSetupDetail(u, :n, :k, "code", 23:22, 23:22)
    @test ts_a != ts_b
    @test !isequal(ts_a, ts_b)
    @test hash(ts_a) != hash(ts_b)

    # Identical values still compare equal (backdating must still work).
    @test te_b == TestErrorDetail(u, "id", "n", "msg", 23:22)
    @test isequal(ti_b, TestItemDetail(u, "id", "n", "code", 23:22, 23:22, true, Symbol[], Symbol[], false))
    @test hash(ts_b) == hash(TestSetupDetail(u, :n, :k, "code", 23:22, 23:22))
end

@testsnippet TestItemPackage begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: @uri_str, URI

    # A minimal in-memory package, so that test items in `test/bar.jl` resolve to a
    # package root and therefore get an id relative to it.
    function workspace_with(content)
        jw = JuliaWorkspace()

        add_file!(jw, TextFile(uri"file:///home/foo/Project.toml", SourceText("name = \"Foo\"\nuuid = \"12345678-1234-1234-1234-123456789012\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(uri"file:///home/foo/src/Foo.jl", SourceText("module Foo\nend\n", "julia")))
        add_file!(jw, TextFile(uri"file:///home/foo/test/bar.jl", SourceText(content, "julia")))

        return jw, uri"file:///home/foo/test/bar.jl"
    end
end

@testitem "skip defaults to false" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testitem "foo" begin end""")

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 1
    @test test_results.testitems[1].option_skip === false
end

@testitem "skip literal is carried through" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testitem "foo" skip=true begin end\n@testitem "bar" skip=false begin end""")

    test_results = get_test_items(jw, uri)

    @test length(test_results.testerrors) == 0
    @test test_results.testitems[1].option_skip === true
    @test test_results.testitems[2].option_skip === false
end

@testitem "skip expression is carried through as source text" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testitem "foo" skip=(VERSION < v"1.11") begin end""")

    test_results = get_test_items(jw, uri)

    @test length(test_results.testerrors) == 0
    # Parentheses are trivia to JuliaSyntax, so only the expression itself is sliced.
    @test test_results.testitems[1].option_skip == "VERSION < v\"1.11\""
end

@testitem "test item ids are package qualified, package relative and label based" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testitem "foo" begin end\n@testitem "bar" begin end""")

    test_results = get_test_items(jw, uri)

    @test [ti.id for ti in test_results.testitems] == ["Foo@12345678/test/bar.jl::foo", "Foo@12345678/test/bar.jl::bar"]
end

@testitem "test item ids are invariant under inserting an item above" setup=[TestItemPackage] begin
    jw1, uri = workspace_with("""@testitem "foo" begin end""")
    jw2, _ = workspace_with("""@testitem "inserted" begin end\n@testitem "foo" begin end""")

    id1 = only(get_test_items(jw1, uri).testitems).id
    id2 = get_test_items(jw2, uri).testitems[2].id

    @test id1 == id2 == "Foo@12345678/test/bar.jl::foo"
end

@testitem "duplicate test item labels get numbered ids and a definition error" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testitem "foo" begin end\n@testitem "foo" begin end\n@testitem "bar" begin end""")

    test_results = get_test_items(jw, uri)

    # Every occurrence is suffixed, not just the second one, so the error state is
    # visible in the id itself and each item stays individually addressable.
    @test [ti.id for ti in test_results.testitems] == ["Foo@12345678/test/bar.jl::foo#1", "Foo@12345678/test/bar.jl::foo#2", "Foo@12345678/test/bar.jl::bar"]

    @test length(test_results.testerrors) == 2
    @test all(te -> te.name == "foo", test_results.testerrors)
    @test all(te -> occursin("used more than once", te.message), test_results.testerrors)
    @test allunique(te.id for te in test_results.testerrors)
end

@testitem "duplicate test setup names produce a definition error" setup=[TestItemPackage] begin
    jw, uri = workspace_with("""@testmodule Foo begin end\n@testsnippet Foo begin end""")

    test_results = get_test_items(jw, uri)

    @test length(test_results.testsetups) == 2
    @test length(test_results.testerrors) == 2
    @test all(te -> te.name == "Foo", test_results.testerrors)
end

@testitem "get_test_items on untitled (non-file) URI" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: @uri_str

    jw = JuliaWorkspace()

    # A recognized package folder makes derived_package_folders non-empty, so
    # derived_package_for_file iterates it for the untitled file below.
    add_file!(jw, TextFile(uri"file:///home/foo/Project.toml", SourceText("name = \"Foo\"\nuuid = \"12345678-1234-1234-1234-123456789012\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(uri"file:///home/foo/src/Foo.jl", SourceText("module Foo\nend\n", "julia")))

    uri = uri"untitled:Untitled-1"
    content = """@testitem "foo" begin
    end
    """
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    # Non-file URIs have no filesystem path; this must not crash. The file is
    # not inside any package, so the testitem is reported as a testerror.
    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testerrors) == 1
end

@testitem "test items in different packages get different ids" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: URI

    # The bug this format exists to fix. Both packages contain `test/runtests.jl` with a
    # test item called "shared", so a package-relative id alone made them byte-identical —
    # and the runner keys work by id, so one of the two silently never ran.
    jw = JuliaWorkspace()
    for (folder, name, uuid) in (
            ("alpha", "Alpha", "aaaaaaaa-1234-1234-1234-123456789012"),
            ("beta", "Beta", "bbbbbbbb-1234-1234-1234-123456789012"))
        add_file!(jw, TextFile(URI("file:///home/$folder/Project.toml"),
            SourceText("name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///home/$folder/src/$name.jl"),
            SourceText("module $name\nend\n", "julia")))
        add_file!(jw, TextFile(URI("file:///home/$folder/test/runtests.jl"),
            SourceText("""@testitem "shared" begin end""", "julia")))
    end

    id_a = only(get_test_items(jw, URI("file:///home/alpha/test/runtests.jl")).testitems).id
    id_b = only(get_test_items(jw, URI("file:///home/beta/test/runtests.jl")).testitems).id

    @test id_a == "Alpha@aaaaaaaa/test/runtests.jl::shared"
    @test id_b == "Beta@bbbbbbbb/test/runtests.jl::shared"
    @test id_a != id_b
end

@testitem "same-named packages with different uuids get different ids" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: URI

    # A vendored copy sitting beside a dev checkout: same name, different package. The uuid
    # fragment is what separates them.
    jw = JuliaWorkspace()
    for (folder, uuid) in (("dev", "aaaaaaaa-1234-1234-1234-123456789012"),
                           ("vendor", "bbbbbbbb-1234-1234-1234-123456789012"))
        add_file!(jw, TextFile(URI("file:///home/$folder/Project.toml"),
            SourceText("name = \"Same\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///home/$folder/src/Same.jl"),
            SourceText("module Same\nend\n", "julia")))
        add_file!(jw, TextFile(URI("file:///home/$folder/test/runtests.jl"),
            SourceText("""@testitem "x" begin end""", "julia")))
    end

    id_dev = only(get_test_items(jw, URI("file:///home/dev/test/runtests.jl")).testitems).id
    id_vendor = only(get_test_items(jw, URI("file:///home/vendor/test/runtests.jl")).testitems).id

    @test id_dev != id_vendor
end

@testitem "the same package cloned twice mints the same id, by design" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_test_items
    using JuliaWorkspaces.URIs2: URI

    # Two worktrees of one package share a name AND a uuid, so their ids are identical.
    # That is deliberate and not a bug to "fix" here: the only thing separating two clones
    # is their location, and location differs between a dev checkout and a CI runner, so an
    # id cannot be both workspace-unique and portable. This one keeps portability; callers
    # that need uniqueness key on `(package_uri, id)`.
    jw = JuliaWorkspace()
    for folder in ("wt-a", "wt-b")
        add_file!(jw, TextFile(URI("file:///home/$folder/Project.toml"),
            SourceText("name = \"Clone\"\nuuid = \"cccccccc-1234-1234-1234-123456789012\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///home/$folder/src/Clone.jl"),
            SourceText("module Clone\nend\n", "julia")))
        add_file!(jw, TextFile(URI("file:///home/$folder/test/runtests.jl"),
            SourceText("""@testitem "x" begin end""", "julia")))
    end

    id_a = only(get_test_items(jw, URI("file:///home/wt-a/test/runtests.jl")).testitems).id
    id_b = only(get_test_items(jw, URI("file:///home/wt-b/test/runtests.jl")).testitems).id

    @test id_a == id_b == "Clone@cccccccc/test/runtests.jl::x"
end
