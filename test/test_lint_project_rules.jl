# Tests for the package-quality lint rules ported from Aqua.jl:
# missing_compat (Aqua test_deps_compat) and unused_dependency (Aqua
# test_stale_deps, static variant).

@testitem "missing_compat: off by default, on in strict" begin
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    """

    jw = JuliaWorkspace()
    uri = URI("file:///pr/Project.toml")
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))
    @test !any(d -> d.code === :missing_compat, get_diagnostic(jw, uri))

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(uri, SourceText(project, "toml")))
    diags = filter(d -> d.code === :missing_compat, get_diagnostic(jw, uri))
    # `Bar` has no compat, and `[compat]` has no `julia` entry.
    @test length(diags) == 2
    @test all(d -> d.severity === :warning, diags)
end

@testitem "missing_compat: flags deps, extras, weakdeps and julia" begin
    using JuliaWorkspaces.URIs2: URI

    function compat_diags(project; rules = "missing_compat = \"warning\"")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\n$rules\n", "toml")))
        uri = URI("file:///pr/Project.toml")
        add_file!(jw, TextFile(uri, SourceText(project, "toml")))
        return filter(d -> d.code === :missing_compat, get_diagnostic(jw, uri)), project
    end

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

    [weakdeps]
    Baz = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"

    [extras]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [compat]
    Bar = "2"
    """

    ds, text = compat_diags(project)
    # LinearAlgebra (stdlibs included!), Baz, Test, julia — but not Bar.
    @test length(ds) == 4
    @test any(d -> occursin("`LinearAlgebra` in `[deps]`", d.message), ds)
    @test any(d -> occursin("`Baz` in `[weakdeps]`", d.message), ds)
    @test any(d -> occursin("`Test` in `[extras]`", d.message), ds)
    @test any(d -> occursin("no `julia` entry", d.message), ds)
    @test !any(d -> occursin("`Bar`", d.message), ds)

    # The dep finding points at the entry's key in [deps].
    d = only(filter(d -> occursin("`LinearAlgebra`", d.message), ds))
    @test text[first(d.range):last(d.range)-1] == "LinearAlgebra"

    # A fully covered project is clean.
    ds, _ = compat_diags("""
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [compat]
    julia = "1.10"
    Bar = "2"
    """)
    @test isempty(ds)
end

@testitem "missing_compat: options gate julia/extras/weakdeps and ignore names" begin
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"

    [weakdeps]
    Baz = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"

    [extras]
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    """

    function messages(rules)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\n$rules\n", "toml")))
        uri = URI("file:///pr/Project.toml")
        add_file!(jw, TextFile(uri, SourceText(project, "toml")))
        return [d.message for d in get_diagnostic(jw, uri) if d.code === :missing_compat]
    end

    all_msgs = messages("missing_compat = \"warning\"")
    @test length(all_msgs) == 4

    msgs = messages("missing_compat = { severity = \"warning\", check_julia = false }")
    @test !any(m -> occursin("julia", m), msgs)
    @test length(msgs) == 3

    msgs = messages("missing_compat = { severity = \"warning\", check_extras = false }")
    @test !any(m -> occursin("`Test`", m), msgs)

    msgs = messages("missing_compat = { severity = \"warning\", check_weakdeps = false }")
    @test !any(m -> occursin("`Baz`", m), msgs)

    msgs = messages("missing_compat = { severity = \"warning\", ignore = [\"Bar\", \"Test\"] }")
    @test !any(m -> occursin("`Bar`", m) || occursin("`Test`", m), msgs)
    @test length(msgs) == 2
end

@testitem "missing_compat: only packages are checked" begin
    using JuliaWorkspaces.URIs2: URI

    # A non-package environment (no name/uuid) declares deps without compat all
    # the time; the rule stays silent there.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
        SourceText("[rules]\nmissing_compat = \"warning\"\n", "toml")))
    uri = URI("file:///pr/Project.toml")
    add_file!(jw, TextFile(uri, SourceText("""
    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    """, "toml")))
    @test !any(d -> d.code === :missing_compat, get_diagnostic(jw, uri))
end

@testitem "missing_compat: invalid option values are config errors" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    config_uri = URI("file:///pr/JuliaLint.toml")
    add_file!(jw, TextFile(config_uri, SourceText("""
    [rules]
    missing_compat = { severity = "warning", check_julia = "nope", ignore = "Bar" }
    """, "toml")))
    msgs = [d.message for d in get_diagnostic(jw, config_uri) if d.code === :config_errors]
    @test any(m -> occursin("check_julia", m), msgs)
    @test any(m -> occursin("ignore", m), msgs)
end

@testitem "unused_dependency: flags deps never imported, respects weakdeps and usage forms" begin
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    Baz = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"
    Qux = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    Unused = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
    """

    function unused_diags(source; project = project, extra = Dict{String,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nunused_dependency = \"warning\"\n", "toml")))
        uri = URI("file:///pr/Project.toml")
        add_file!(jw, TextFile(uri, SourceText(project, "toml")))
        add_file!(jw, TextFile(URI("file:///pr/src/Foo.jl"), SourceText(source, "julia")))
        for (path, content) in extra
            add_file!(jw, TextFile(URI("file:///pr/$path"), SourceText(content, "julia")))
        end
        return filter(d -> d.code === :unused_dependency, get_diagnostic(jw, uri))
    end

    # Different import forms all count as usage; `Unused` is flagged.
    src = """
    module Foo
    using Bar
    import Baz: something
    import Qux as Q
    end
    """
    ds = unused_diags(src)
    @test length(ds) == 1
    @test occursin("`Unused`", ds[1].message)
    @test project[first(ds[1].range):last(ds[1].range)-1] == "Unused"

    # Imports in included files and submodules count.
    ds = unused_diags("""
    module Foo
    using Bar, Baz
    include("other.jl")
    module Sub
    import Qux
    end
    end
    """; extra = Dict("src/other.jl" => "using Qux\n"))
    @test length(ds) == 1
    @test occursin("`Unused`", ds[1].message)

    # `using Unused.Sub` uses the dep too (first path segment).
    ds = unused_diags("""
    module Foo
    using Bar, Baz, Qux
    using Unused.Sub
    end
    """)
    @test isempty(ds)
end

@testitem "unused_dependency: weakdeps, extensions, ignore, boundaries" begin
    using JuliaWorkspaces.URIs2: URI

    function diags(; project, files, rules = "unused_dependency = \"warning\"")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\n$rules\n", "toml")))
        uri = URI("file:///pr/Project.toml")
        add_file!(jw, TextFile(uri, SourceText(project, "toml")))
        for (path, content) in files
            add_file!(jw, TextFile(URI("file:///pr/$path"), SourceText(content, "julia")))
        end
        return filter(d -> d.code === :unused_dependency, get_diagnostic(jw, uri))
    end

    # A dep used only in an extension is used; weakdeps are never flagged.
    project = """
    name = "Foo"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"

    [deps]
    Bar = "6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22"
    ExtOnly = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [weakdeps]
    Trigger = "3c9a1b52-1f0f-4a9e-9c7d-7a1e0b7d4c11"

    [extensions]
    FooTriggerExt = "Trigger"
    """
    @test isempty(diags(; project, files = Dict(
        "src/Foo.jl" => "module Foo\nusing Bar\nend\n",
        "ext/FooTriggerExt.jl" => "module FooTriggerExt\nusing Trigger, ExtOnly\nend\n",
    )))

    # Nested extension layout works too.
    @test isempty(diags(; project, files = Dict(
        "src/Foo.jl" => "module Foo\nusing Bar\nend\n",
        "ext/FooTriggerExt/FooTriggerExt.jl" => "module FooTriggerExt\nusing Trigger, ExtOnly\nend\n",
    )))

    # Without the extension usage, ExtOnly is flagged — and ignore exempts it.
    base_files = Dict("src/Foo.jl" => "module Foo\nusing Bar\nend\n")
    ds = diags(; project, files = base_files)
    @test length(ds) == 1 && occursin("`ExtOnly`", ds[1].message)
    @test isempty(diags(; project, files = base_files,
        rules = "unused_dependency = { severity = \"warning\", ignore = [\"ExtOnly\"] }"))

    # A computed include could hide the import: the whole check goes silent.
    @test isempty(diags(; project, files = Dict(
        "src/Foo.jl" => "module Foo\nusing Bar\ninclude(joinpath(@__DIR__, computed))\nend\n",
    )))
    # Same for an include whose target file is missing.
    @test isempty(diags(; project, files = Dict(
        "src/Foo.jl" => "module Foo\nusing Bar\ninclude(\"not_there.jl\")\nend\n",
    )))

    # A non-package env, or a package without its entry file, is silent.
    @test isempty(diags(; project = "[deps]\nBar = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\n",
        files = Dict("src/Foo.jl" => "module Foo\nend\n")))
    @test isempty(diags(; project, files = Dict{String,String}()))
end
