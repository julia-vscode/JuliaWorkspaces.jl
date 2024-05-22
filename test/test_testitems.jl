@testitem "@testitem macro missing all args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Your @testitem is missing a name and code block.", 1:9)
end

@testitem "Wrong type for name" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem :foo
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Your @testitem must have a first argument that is of type String for the name.", 1:14)
end

@testitem "Code block missing" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo"
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Your @testitem is missing a code block argument.", 1:15)
end

@testitem "Final arg not a code block" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" 3
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The final argument of a @testitem must be a begin end block.", 1:17)
end

@testitem "None kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" bar begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The arguments to a @testitem must be in keyword format.", 1:29)
end

@testitem "Duplicate kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports=true default_imports=false begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The keyword argument default_imports cannot be specified more than once.", 1:68)
end

@testitem "Incomplete kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports= begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The final argument of a @testitem must be a begin end block.", 1:42)
end

@testitem "Wrong default_imports type kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" default_imports=4 begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The keyword argument default_imports only accepts bool values.", 1:43)
end

@testitem "non vector arg for tags kw" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=4 begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The keyword argument tags only accepts a vector of symbols.", 1:32)
end

@testitem "Wrong types in tags kw arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=[4, 8] begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "The keyword argument tags only accepts a vector of symbols.", 1:37)
end

@testitem "Unknown keyword arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" bar=true begin end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Unknown keyword argument.", 1:34)
end

@testitem "All parts correctly there" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testitem "foo" tags=[:a, :b] setup=[FooSetup] default_imports=true begin println() end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 1
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 0

    ti = test_results.testitems[1]

    @test ti.name == "foo"
    @test ti.project_uri === nothing
    @test ti.package_uri === nothing
    @test ti.package_name == ""
    @test ti.range == 1:87
    @test ti.code_range == 75:83
    @test ti.option_default_imports == true
    @test ti.option_tags == [:a, :b]
    @test ti.option_setup == [:FooSetup]
end

@testitem "@testsetup macro missing module arg" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsetup
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Your `@testsetup` is missing a `module ... end` block.", 1:length(content)-1)
end

@testitem "@testsetup macro extra args" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsetup "Foo" module end"""

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 0
    @test length(test_results.testerrors) == 1

    @test test_results.testerrors[1] == TestErrorDetail(uri"file://src/foo.jl", "Your `@testsetup` must have a single `module ... end` argument.", 1:length(content))
end

@testitem "@testsetup all correct" begin
    using JuliaWorkspaces: JuliaWorkspace, TestErrorDetail
    using JuliaWorkspaces.URIs2: @uri_str

    uri = uri"file://src/foo.jl"
    content = """@testsetup module Foo
        const BAR = 1
        qux() = 2
    end
    """

    jw = JuliaWorkspace()

    add_text_file(jw, TextFile(uri, SourceText(content, "julia")))

    test_results = get_test_items(jw, uri)

    @test length(test_results.testitems) == 0
    @test length(test_results.testsetups) == 1
    @test length(test_results.testerrors) == 0

    tsd = test_results.testsetups[1]

    @test tsd.name == :Foo
    @test tsd.range == 1:length(content)-1
    @test tsd.code_range == (length("@testsetup module Foo") + 1):(length(content) - 4)
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

        @test get_test_items(jw, file1_uri).testitems[1].project_uri == filepath2uri(joinpath(root_path, "project_detection", "TestPackage2"))
        @test get_test_items(jw, file2_uri).testitems[1].project_uri == filepath2uri(joinpath(root_path, "project_detection"))
        @test get_test_items(jw, file3_uri).testitems[1].project_uri === nothing
    end
end
