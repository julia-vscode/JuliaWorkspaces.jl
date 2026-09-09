# Tests for the undocumented_public_name rule (Aqua.jl's
# test_undocumented_names, statically).

@testitem "undocumented_public_name: Aqua fixture parity" begin
    using JuliaWorkspaces.URIs2: URI

    function undoc_diags(source; path = "src/Pkg.jl", name = "Pkg")
        project = """
        name = "$name"
        uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
        version = "0.1.0"
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nundocumented_public_name = \"warning\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///pr/Project.toml"), SourceText(project, "toml")))
        uri = URI("file:///pr/$path")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :undocumented_public_name, get_diagnostic(jw, uri)), source
    end

    # Aqua's PkgWithUndocumentedNames: the undocumented exports are flagged,
    # the documented ones are not.
    src = """
    module Pkg

    \"""
        documented_function
    \"""
    function documented_function end

    function undocumented_function end

    \"""
        DocumentedStruct
    \"""
    struct DocumentedStruct end

    struct UndocumentedStruct end

    export documented_function, DocumentedStruct
    export undocumented_function, UndocumentedStruct

    end
    """
    ds, text = undoc_diags(src)
    @test length(ds) == 2
    @test any(d -> occursin("`undocumented_function`", d.message), ds)
    @test any(d -> occursin("`UndocumentedStruct`", d.message), ds)
    # The finding points at the name inside the export statement.
    d = only(filter(d -> occursin("`UndocumentedStruct`", d.message), ds))
    @test text[first(d.range):last(d.range)-1] == "UndocumentedStruct"
    @test first(d.range) > findfirst("export undocumented_function", text)[1]

    # Aqua's PkgWithoutUndocumentedNames: all documented, no findings.
    ds, _ = undoc_diags("""
    module Pkg

    \"""
        documented_function
    \"""
    function documented_function end

    export documented_function

    end
    """)
    @test isempty(ds)

    # Aqua's PkgWithUndocumentedNamesInSubmodule: an undocumented submodule is
    # flagged (its name is a public name of itself); the root module is exempt.
    src = """
    module Pkg

    module SubModule
    struct UndocumentedStruct end
    end

    end
    """
    ds, text = undoc_diags(src)
    @test length(ds) == 1
    @test occursin("`SubModule`", ds[1].message)
    @test occursin("docstring", ds[1].message)
    @test text[first(ds[1].range):last(ds[1].range)-1] == "SubModule"
    # ... and a documented submodule is fine; its unexported private struct
    # stays unflagged either way.
    ds, _ = undoc_diags("""
    module Pkg

    \"""
        SubModule
    \"""
    module SubModule
    struct UndocumentedStruct end
    end

    end
    """)
    @test isempty(ds)
end

@testitem "undocumented_public_name: docstring forms, public, re-exports, macros" begin
    using JuliaWorkspaces.URIs2: URI

    function undoc_msgs(source; files = Dict{String,String}())
        project = """
        name = "Pkg"
        uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
        version = "0.1.0"
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nundocumented_public_name = \"warning\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///pr/Project.toml"), SourceText(project, "toml")))
        add_file!(jw, TextFile(URI("file:///pr/src/Pkg.jl"), SourceText(source, "julia")))
        for (path, content) in files
            add_file!(jw, TextFile(URI("file:///pr/$path"), SourceText(content, "julia")))
        end
        msgs = String[]
        for path in vcat(["src/Pkg.jl"], collect(keys(files)))
            for d in get_diagnostic(jw, URI("file:///pr/$path"))
                d.code === :undocumented_public_name && push!(msgs, d.message)
            end
        end
        return msgs
    end

    # Every doc form counts: doc on `function foo end`, on a const, on a
    # short-form function, a bare `"..." name` doc, `@doc`, a doc on a
    # signature only, and a doc on one method of several.
    @test isempty(undoc_msgs("""
    module Pkg

    "doc" function f1 end
    "doc" const C = 1
    "doc" f2(x) = x
    f3() = 1
    "doc" f3
    "doc" f4(x, y)
    f4(x, y) = x + y
    @doc "doc" f5
    f5() = 1
    "doc" f6(x::Int) = x
    f6(x::String) = x
    "doc" macro m() end

    export f1, C, f2, f3, f4, f5, f6, @m

    end
    """))

    # `public` names need docs too; the message says so.
    msgs = undoc_msgs("""
    module Pkg
    f() = 1
    public f
    end
    """)
    @test length(msgs) == 1
    @test occursin("public", msgs[1])

    # A re-exported name (bound by `using`, not declared here) is skipped.
    @test isempty(undoc_msgs("""
    module Pkg
    using Base: sort!
    export sort!
    end
    """))

    # An exported name that is not defined at all is missing_reference's
    # finding, not this rule's.
    @test isempty(undoc_msgs("""
    module Pkg
    export not_defined_here
    end
    """))

    # The docstring may live in another file of the same module, and exports
    # in included files are checked (and located) in their own file.
    @test isempty(undoc_msgs("""
    module Pkg
    include("impl.jl")
    include("exports.jl")
    end
    """; files = Dict(
        "src/impl.jl" => "\"doc\" f() = 1\n",
        "src/exports.jl" => "export f\n",
    )))
    msgs = undoc_msgs("""
    module Pkg
    include("impl.jl")
    include("exports.jl")
    end
    """; files = Dict(
        "src/impl.jl" => "f() = 1\n",
        "src/exports.jl" => "export f\n",
    ))
    @test length(msgs) == 1
    @test occursin("`f`", msgs[1])

    # An undocumented macro export is flagged under its `@` name.
    msgs = undoc_msgs("""
    module Pkg
    macro m() end
    export @m
    end
    """)
    @test length(msgs) == 1
    @test occursin("`@m`", msgs[1])
end

@testitem "undocumented_public_name: off by default, on in strict" begin
    using JuliaWorkspaces.URIs2: URI

    project = """
    name = "Pkg"
    uuid = "5c0ad2b5-2f9c-4b2c-9f0c-1e5c4dd1a1cd"
    version = "0.1.0"
    """
    source = "module Pkg\nf() = 1\nexport f\nend\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/Project.toml"), SourceText(project, "toml")))
    uri = URI("file:///pr/src/Pkg.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    @test !any(d -> d.code === :undocumented_public_name, get_diagnostic(jw, uri))

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///pr/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    ds = filter(d -> d.code === :undocumented_public_name, get_diagnostic(jw, uri))
    @test length(ds) == 1
    @test ds[1].severity === :warning
end
