@testitem "Hover: basic identifiers and nothing cases" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverTest"
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
    module HoverTest

    1234
    Base
    +
    vari = 1234
    \"\"\"
        Text
    \"\"\"
    function func(arg) end
    func() = nothing
    module M end
    struct T end
    mutable struct T2 end
    for i = 1:1 end
    while true end
    begin end
    sin()

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hovertest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovertest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovertest/src/HoverTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///hovertest/src/HoverTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1  # +1 for newline
        end
        return idx + col
    end

    # Hovering over a bare integer literal should return nothing
    @test get_hover_text(jw, uri, index_of(source, 3, 2)) === nothing

    # Hovering over `Base` should produce hover text (it's a known module)
    result = get_hover_text(jw, uri, index_of(source, 4, 1))
    @test result !== nothing

    # Hovering over `+` operator should produce text
    result = get_hover_text(jw, uri, index_of(source, 5, 1))
    @test result !== nothing

    # Hovering over `vari` identifier should produce text
    result = get_hover_text(jw, uri, index_of(source, 6, 1))
    @test result !== nothing

    # Hovering over `func` in function definition should produce text
    result = get_hover_text(jw, uri, index_of(source, 10, 10))
    @test result !== nothing

    # Hovering over `func` in second method should produce text
    result = get_hover_text(jw, uri, index_of(source, 11, 1))
    @test result !== nothing
end

@testitem "Hover: closer keywords" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverCloser"
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
    module HoverCloser

    function foo(x)
        x + 1
    end

    for i = 1:10
        i
    end

    while true
        break
    end

    module Inner
    end

    struct MyStruct
        a
    end

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hovercloser/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovercloser/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hovercloser/src/HoverCloser.jl"), SourceText(source, "julia")))

    uri = URI("file:///hovercloser/src/HoverCloser.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hover on `end` of function definition (line 5)
    result = get_hover_text(jw, uri, index_of(source, 5, 1))
    @test result !== nothing
    @test occursin("foo", result)

    # Hover on `end` of for loop (line 9)
    result = get_hover_text(jw, uri, index_of(source, 9, 1))
    @test result !== nothing
    @test occursin("for", result)

    # Hover on `end` of while loop (line 13)
    result = get_hover_text(jw, uri, index_of(source, 13, 1))
    @test result !== nothing
    @test occursin("while", result)

    # Hover on `end` of module Inner (line 16)
    result = get_hover_text(jw, uri, index_of(source, 16, 1))
    @test result !== nothing
    @test occursin("Inner", result)
end

@testitem "Hover: docstrings" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverDocs"
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
    module HoverDocs

    "I have a docstring"
    Base.@kwdef struct SomeStruct
        a
    end

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverdocs/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverdocs/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverdocs/src/HoverDocs.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverdocs/src/HoverDocs.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over SomeStruct should include the docstring
    result = get_hover_text(jw, uri, index_of(source, 4, 22))
    @test result !== nothing
    @test occursin("I have a docstring", result)
end

@testitem "Hover: struct field position" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverFields"
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
    module HoverFields

    struct S
        a
        b
        c
        d
        e
        f
        g
    end
    S(1,2,3,4,5,6,7)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverfields/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverfields/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverfields/src/HoverFields.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverfields/src/HoverFields.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over argument in S(1,...) constructor call — the `1` is arg 1 which corresponds to field `a`
    result = get_hover_text(jw, uri, index_of(source, 12, 3))
    @test result !== nothing
    @test occursin("a", result) || occursin("Argument 1", result)
end

@testitem "Hover: qualified function argument position" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverQual"
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
    module HoverQual

    module M
        f(a,b,c,d,e) = 1
    end
    M.f(1,2,3,4,5)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverqual/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverqual/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverqual/src/HoverQual.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverqual/src/HoverQual.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hovering over the first argument `1` in `M.f(1,2,3,4,5)` line 6
    result = get_hover_text(jw, uri, index_of(source, 6, 5))
    @test result !== nothing
    @test occursin("Argument `a` (1 of 5)", result) && occursin("M.f", result)
end

@testitem "Hover: argument parameter names in call position" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HoverArgNames"
    uuid = "72345678-1234-1234-1234-123456789abc"
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
    module HoverArgNames

    f(alpha, beta, gamma, delta, epsilon) = 1
    f(1, 2, 3, 4, 5)

    g(x::Int, aaa, bbb, ccc) = 1
    g(x::String, ddd, eee, fff) = 2
    g(1, 2, 3, 4)
    g("s", 2, 3, 4)

    struct T
        fa
        fb
        fc
        fd
        fe
    end
    T(w, x, y, z) = T(w, x, y, z, 0)
    T(1, 2, 3, 4)

    h(1, 2, 3, 4, 5)

    arr1 = [1, 2, 3]
    arr2 = [4, 5, 6]
    copyto!(arr1, 1, arr2, 1, 3)

    q(x::Int, qaa, qbb, qcc) = 1
    q(x::String, qdd, qee, qff) = 2
    qval = 1.5
    q(qval, 2, 3, 4)

    sv(sa, sb, sc, sd, sxs...) = 1
    svt = (4, 5)
    sv(1, 2, 3, svt..., 9)

    kh(alpha, beta, gamma, delta; opt = 1) = 1
    kh(1, 2, 3, 4; opt = 5)

    va(x, y, z, a, b, c...) = x + y
    va(1, 2, 3, 4, 5, 6, 7, 8)

    struct P{X}
        pa::X
        pb::X
        pc::X
        pd::X
        pe::X
    end
    P{X}(w, x, y, z) where X = P{X}(w, x, y, z, zero(X))
    P{Int}(1, 2, 3, 4)

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hoverargnames/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverargnames/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hoverargnames/src/HoverArgNames.jl"), SourceText(source, "julia")))

    uri = URI("file:///hoverargnames/src/HoverArgNames.jl")

    hover_at(needle) = get_hover_text(jw, uri, findfirst(needle, source).stop)

    # Workspace function: parameter name from the method definition
    result = hover_at("f(1, 2")
    @test result !== nothing
    @test occursin("Argument `beta` (2 of 5) in call to `f`", result)

    # Two same-arity methods: the Int literal selects the ::Int method
    result = hover_at("g(1, 2")
    @test result !== nothing
    @test occursin("Argument `aaa` (2 of 4) in call to `g`", result)

    # ... and the String literal selects the ::String method
    result = hover_at("g(\"s\", 2")
    @test result !== nothing
    @test occursin("Argument `ddd` (2 of 4) in call to `g`", result)

    # Constructor call resolved to the outer constructor, not the field list
    result = hover_at("T(1")
    @test result !== nothing
    @test occursin("Argument `w` (1 of 4) in call to `T`", result)

    # Unresolvable callee: old positional-only text is preserved
    result = hover_at("h(1")
    @test result !== nothing
    @test occursin("Argument 1 of 5 in call to `h`", result)
    @test !occursin("(1 of 5)", result)

    # SymbolServer-backed method: name comes from the method store
    result = hover_at("copyto!(arr1, 1")
    @test result !== nothing
    @test occursin(r"Argument `\w+` \(2 of 5\) in call to `copyto!`", result)

    # No type-compatible method: keep the positional text instead of showing
    # a name from an overload the call doesn't match
    result = hover_at("q(qval, 2")
    @test result !== nothing
    @test occursin("Argument 2 of 4 in call to `q`", result)
    @test !occursin(r"Argument `\w+`", result)

    # Splat in the call: names before the splat resolve...
    result = hover_at("sv(1, 2")
    @test result !== nothing
    @test occursin("Argument `sb` (2 of 4) in call to `sv`", result)

    # ...but positions at/after the splat are unknowable
    result = hover_at("svt..., 9")
    @test result !== nothing
    @test occursin(r"Argument 5 of \d+ in call to `sv`", result)
    @test !occursin(r"Argument `\w+`", result)

    # Keyword arguments after `;` don't shift the positional index
    result = hover_at("kh(1, 2")
    @test result !== nothing
    @test occursin("Argument `beta` (2 of 4) in call to `kh`", result)

    # Curly callee: parametric constructor call resolves through `P{Int}`
    result = hover_at("P{Int}(1")
    @test result !== nothing
    @test occursin("Argument `w` (1 of 4) in call to `P`", result)

    # Method-side vararg: fixed positions show their name...
    result = hover_at("va(1, 2")
    @test result !== nothing
    @test occursin("Argument `y` (2 of 8) in call to `va`", result)

    # ...and positions bound to the trailing vararg show `name...`,
    # from the slot itself to the last argument
    result = hover_at("va(1, 2, 3, 4, 5, 6")
    @test result !== nothing
    @test occursin("Argument `c...` (6 of 8) in call to `va`", result)

    result = hover_at("6, 7, 8")
    @test result !== nothing
    @test occursin("Argument `c...` (8 of 8) in call to `va`", result)
end

@testitem "get_doc_from_word: basic matching" begin
    using JuliaWorkspaces: JuliaWorkspace, get_doc_from_word

    jw = JuliaWorkspace()

    # Exact match for a well-known Base symbol
    result = get_doc_from_word(jw, "println")
    @test result != "No results found."
    @test occursin("println", result)

    # Fuzzy match — close misspelling
    result = get_doc_from_word(jw, "printl")
    @test result != "No results found."

    # Completely nonsensical word should return no results
    result = get_doc_from_word(jw, "zzznotarealsymbolxxx")
    @test result == "No results found."
end

@testitem "Hover: standalone file (no project)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    # No Project.toml or Manifest.toml — just a bare Julia source file.
    # This exercises the _stdlib_only_env() fallback path.
    source = """
    module Standalone

    function myfunc(x)
        return x + 1
    end

    myvar = 42

    struct MyStruct
        field1::Int
    end

    println("hello")

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///standalone/src/Standalone.jl"), SourceText(source, "julia")))

    uri = URI("file:///standalone/src/Standalone.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hover on locally-defined function name "myfunc" (line 3, col 10)
    result = get_hover_text(jw, uri, index_of(source, 3, 10))
    @test result !== nothing

    # Hover on locally-defined variable "myvar" (line 7, col 1)
    result = get_hover_text(jw, uri, index_of(source, 7, 1))
    @test result !== nothing

    # Hover on stdlib function "println" (line 13, col 1)
    result = get_hover_text(jw, uri, index_of(source, 13, 1))
    @test result !== nothing

    # Hover on integer literal should return nothing (line 7, col 9 = "42")
    result = get_hover_text(jw, uri, index_of(source, 7, 9))
    @test result === nothing
end

@testitem "Hover: package without manifest (pre-DJP)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    # Project.toml present but NO Manifest.toml — simulates the window
    # between opening a project and DJP completing.
    project_toml = """
    name = "PreDJP"
    uuid = "aabbccdd-1122-3344-5566-778899aabbcc"
    version = "0.1.0"
    """

    source = """
    module PreDJP

    function greet(name)
        println("Hello, \$name!")
    end

    counter = 0

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///predjp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///predjp/src/PreDJP.jl"), SourceText(source, "julia")))

    uri = URI("file:///predjp/src/PreDJP.jl")

    function index_of(src, line, col)
        lines = split(src, '\n')
        idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # Hover on locally-defined function "greet" (line 3, col 10)
    result = get_hover_text(jw, uri, index_of(source, 3, 10))
    @test result !== nothing

    # Hover on stdlib function "println" (line 4, col 5)
    result = get_hover_text(jw, uri, index_of(source, 4, 5))
    @test result !== nothing

    # Hover on local variable "counter" (line 7, col 1)
    result = get_hover_text(jw, uri, index_of(source, 7, 1))
    @test result !== nothing
end

@testitem "Hover: docs from @doc macro (#1377)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    source = """
    @doc "Function doc via @doc" function docfun() end
    @doc "Struct doc via @doc" struct DocType end
    @doc "Variable doc via @doc" docvar = 1
    @doc raw\"\"\"Raw doc via @doc\"\"\" function rawdocfun() end
    docfun
    DocType
    docvar
    rawdocfun
    """

    jw = JuliaWorkspace()
    uri = URI("file:///docmacro/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # offset (1-based) of (1-based line, col); col 2 lands mid-identifier.
    function index_of(src, line, col)
        lines = split(src, '\n'); idx = 0
        for l in 1:(line - 1)
            idx += ncodeunits(lines[l]) + 1
        end
        return idx + col
    end

    # The explicit `@doc "..."` form (macroname `@doc`, not the implicit
    # `:globalrefdoc`) must be recognised — including a raw-string payload and
    # `@doc "..." target` referencing a binding via its refs.
    @test occursin("Function doc via @doc", get_hover_text(jw, uri, index_of(source, 5, 2)))
    @test occursin("Struct doc via @doc", get_hover_text(jw, uri, index_of(source, 6, 2)))
    @test occursin("Variable doc via @doc", get_hover_text(jw, uri, index_of(source, 7, 2)))
    @test occursin("Raw doc via @doc", get_hover_text(jw, uri, index_of(source, 8, 2)))
end

@testitem "Hover: struct constructor argument field (#1392)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    # Hovering an argument of a struct's default constructor names the field.
    # This routes through _get_fcall_position → struct_nargs(val, env, …); the
    # env threading is the applicable part of the JuliaFormatter-v2 PR. Needs
    # >= 4 fields (get_fcall_position returns early for fewer).
    source = """
    struct Foo
        a
        b
        c
        d
    end
    Foo(1, 2, 3, 4)
    """

    jw = JuliaWorkspace()
    uri = URI("file:///structarg/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # offset of the `2` argument (line 8: `Foo(1, 2, 3, 4)`).
    rng = findfirst("Foo(1, 2", source)
    result = get_hover_text(jw, uri, last(rng))
    @test result !== nothing
    @test occursin("Datatype field `b` of Foo", result)
end

@testitem "Hover: keyword parameter in definition signature" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text, get_expr1
    using JuliaWorkspaces: derived_julia_legacy_syntax_tree
    using JuliaWorkspaces.URIs2: URI
    import CSTParser

    # CSTParser folds the `;` separator into the preceding positional argument's
    # `fullspan`, so the `parameters` node directly follows an IDENTIFIER with no
    # separator token in between. A boundary heuristic in `get_expr1` used to grab
    # that preceding identifier, so hovering the keyword parameter `y` resolved to
    # the positional `x` instead.
    source = "g(x;y)=x+y\n"

    jw = JuliaWorkspace()
    uri = URI("file:///kwparam/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # Hovering the keyword parameter `y` (index 5) must resolve to `y`, not `x`.
    result = get_hover_text(jw, uri, 5)
    @test result !== nothing
    clean = replace(result, "\r" => "")
    @test occursin("```julia\ny\n```", clean)
    @test !occursin("```julia\nx\n```", clean)

    # Direct unit check on the offset lookup: offset 4 (0-based) is the `y` of the
    # parameters block, offset 2 is the positional `x`.
    cst = CSTParser.parse(source)
    @test CSTParser.str_value(get_expr1(cst, 4)) == "y"
    @test CSTParser.str_value(get_expr1(cst, 2)) == "x"
end

@testsnippet HoverCrossWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    const PROJECT_TOML = """
    name = "HoverX"
    uuid = "a2345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    const MANIFEST_TOML = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    const ENTRY_URI = URI("file:///hoverx/src/HoverX.jl")
    const A_URI = URI("file:///hoverx/src/a.jl")
    const B_URI = URI("file:///hoverx/src/b.jl")

    # A three-file package: the hovered file `b.jl` references names DECLARED
    # in the sibling `a.jl` (resolved through the module tree in per-file
    # mode, so their refs are plain-data `TreeRef`s, not merged Bindings).
    function hoverx_workspace(a_src::String, b_src::String; entry_extra::String="")
        entry = """
        module HoverX
        $(entry_extra)include("a.jl")
        include("b.jl")
        end
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///hoverx/Project.toml"), SourceText(PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(URI("file:///hoverx/Manifest.toml"), SourceText(MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(ENTRY_URI, SourceText(entry, "julia")))
        add_file!(jw, TextFile(A_URI, SourceText(a_src, "julia")))
        add_file!(jw, TextFile(B_URI, SourceText(b_src, "julia")))
        return jw
    end

    hover_at(jw, src::String, needle::String; uri=B_URI) =
        get_hover_text(jw, uri, findfirst(needle, src).stop)
end

@testitem "Hover: cross-file function shows docstring and signatures" setup=[HoverCrossWS] begin
    a_src = """
    \"\"\"
    greet docs
    \"\"\"
    greet(name) = 1
    greet(first, last) = 2
    """
    b_src = "caller(x) = greet(x)\n"
    jw = hoverx_workspace(a_src, b_src)

    # Byte parity with the old whole-closure rendering (captured by probe):
    # the docstring, then one signature block per method, in splice order.
    result = hover_at(jw, b_src, "caller(x) = gree")
    @test result == "greet docs\n```julia\ngreet(name)\n```\n```julia\ngreet(first, last)\n```\n"
end

@testitem "Hover: cross-file struct shows docstring and fields" setup=[HoverCrossWS] begin
    a_src = """
    "CrossS docs"
    struct CrossS
        fielda
        fieldb
    end
    """
    b_src = "maker() = CrossS(1, 2)\n"
    jw = hoverx_workspace(a_src, b_src)

    result = hover_at(jw, b_src, "CrossS")
    @test result !== nothing
    @test occursin("CrossS docs", result)
    @test occursin("fielda", result)
    @test occursin("fieldb", result)
end

@testitem "Hover: cross-file const and assignment show typed definition and docstring" setup=[HoverCrossWS] begin
    a_src = """
    "CONSTX docs"
    const CONSTX = 42

    "v docs"
    myglobal = [1, 2]
    """
    b_src = """
    cuse() = CONSTX
    guse() = myglobal
    """
    jw = hoverx_workspace(a_src, b_src)

    # Byte parity with the old rendering (probe-captured): the typed
    # definition block first, then the docstring.
    @test hover_at(jw, b_src, "cuse() = CONSTX") ==
        "\n```julia\nCONSTX::Int64 = 42\n```\n\nCONSTX docs"
    @test hover_at(jw, b_src, "guse() = myglobal") ==
        "\n```julia\nmyglobal = [1, 2]\n```\n\nv docs"
end

@testitem "Hover: external symbol through a sibling file's using is unchanged" setup=[HoverCrossWS] begin
    # `partition` is brought in by `using Base.Iterators` in the ENTRY file;
    # in per-file mode the hovered file's ref is a `TreeRef` of kind
    # `:external_symbol`, which must render the env store docs as before.
    a_src = "unrelated() = 1\n"
    b_src = "puse(v) = partition(v, 2)\n"
    jw = hoverx_workspace(a_src, b_src; entry_extra="using Base.Iterators\n")

    result = hover_at(jw, b_src, "puse(v) = partition")
    @test result !== nothing
    @test occursin("Iterate over a collection", result)
    @test occursin("is a function with", result)
end

@testitem "Hover: qualified use of a sibling-file module member" setup=[HoverCrossWS] begin
    a_src = """
    module SubM
    "subm fn docs"
    subfn() = 1
    end
    """
    b_src = """
    using .SubM
    moduse() = SubM.subfn()
    """
    jw = hoverx_workspace(a_src, b_src)

    # The qualified member renders docstring + signature (old parity).
    @test hover_at(jw, b_src, "SubM.subfn") == "subm fn docs\n```julia\nsubfn()\n```\n"

    # Hovering the module NAME renders a compact module reference (the old
    # pass dumped the module's entire body — deliberately NOT preserved; see
    # the M4 task-5 change-list).
    result = hover_at(jw, b_src, "moduse() = SubM")
    @test result !== nothing
    @test occursin("module SubM", result)
    @test !occursin("subfn() = ", result)
end

@testitem "Hover: cross-file operator definition resolves through visibility" setup=[HoverCrossWS] begin
    # Operators are not resolved through the tree context during the per-file
    # pass (identifier-gated), so hover's operator fallback must consult the
    # module's visible names.
    a_src = "⊕(a, b) = a + b\n"
    b_src = "opuse() = 1 ⊕ 2\n"
    jw = hoverx_workspace(a_src, b_src)

    @test hover_at(jw, b_src, "1 ⊕") == "\n```julia\na ⊕ b\n```\n"
end

@testitem "Hover: cross-file call argument names" setup=[HoverCrossWS] begin
    a_src = """
    f5(alpha, beta, gamma, delta, epsilon) = 1

    struct CrossT
        fa
        fb
        fc
        fd
    end
    """
    b_src = """
    argname() = f5(1, 2, 3, 4, 5)
    maker() = CrossT(1, 2, 3, 4)
    """
    jw = hoverx_workspace(a_src, b_src)

    # Parameter names come from the cross-file method definition (old parity).
    result = hover_at(jw, b_src, "f5(1, 2")
    @test result !== nothing
    @test occursin("Argument `beta` (2 of 5) in call to `f5`", result)

    # Constructor-call arguments name the struct's fields (old parity: the
    # datatype-field rendering, reproduced cross-file from the materialized
    # struct EXPR).
    result = hover_at(jw, b_src, "CrossT(1, 2")
    @test result !== nothing
    @test occursin("Datatype field `fb` of CrossT", result)
end

@testitem "Hover: local variable rendering is unchanged" setup=[HoverCrossWS] begin
    a_src = "unrelated() = 1\n"
    b_src = """
    function lvar()
        localx = 3
        return localx
    end
    """
    jw = hoverx_workspace(a_src, b_src)

    result = hover_at(jw, b_src, "return localx")
    @test result !== nothing
    @test occursin("localx", result)
end

@testitem "Hover: deved workspace-package function resolves cross-root" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    main_project = """
    name = "MainP"
    uuid = "b2345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """
    b_project = """
    name = "B"
    uuid = "c2345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    entry = """
    module MainP
    using B
    f() = myfunc(1)
    g() = B.myfunc(1)
    end
    """
    b_entry = """
    module B
    export myfunc
    "myfunc docs"
    myfunc(alpha) = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsph/Main/Project.toml"), SourceText(main_project, "toml")))
    add_file!(jw, TextFile(URI("file:///wsph/Main/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsph/Main/src/MainP.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///wsph/B/Project.toml"), SourceText(b_project, "toml")))
    add_file!(jw, TextFile(URI("file:///wsph/B/src/B.jl"), SourceText(b_entry, "julia")))

    uri = URI("file:///wsph/Main/src/MainP.jl")

    # Both the `using`-bring-in reference and the qualified one resolve
    # through B's OWN root's tree (`_method_items_root` cross-root dispatch).
    result = get_hover_text(jw, uri, findfirst("f() = myfunc", entry).stop)
    @test result !== nothing
    @test occursin("myfunc docs", result)
    @test occursin("myfunc(alpha)", result)

    result_q = get_hover_text(jw, uri, findfirst("B.myfunc", entry).stop)
    @test result_q !== nothing
    @test occursin("myfunc docs", result_q)
    @test occursin("myfunc(alpha)", result_q)
end

@testitem "Hover: docstring edit in the defining file re-executes no analysis" setup=[HoverCrossWS] begin
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    a_src = """
    \"\"\"
    greet docs
    \"\"\"
    greet(name) = 1
    """
    b_src = "caller(x) = greet(x)\n"
    jw = hoverx_workspace(a_src, b_src)

    # Untraced baseline fills the memo caches.
    idx = findfirst("caller(x) = gree", b_src).stop
    result = get_hover_text(jw, B_URI, idx)
    @test occursin("greet docs", result)

    # Edit ONLY the docstring in the DEFINING file. Docs live outside the
    # inventory by design: the inventory value is equal, every dependent
    # backdates, and NO per-file analysis re-executes — yet hover serves the
    # fresh docstring (materialized request-time via `derived_item_positions`).
    update_file!(jw, TextFile(A_URI, SourceText(replace(a_src, "greet docs" => "greet docs EDITED"), "julia")))

    recv = CountReceiver()
    result = TL.with_tracing(() -> get_hover_text(jw, B_URI, idx), recv)
    @test occursin("greet docs EDITED", result)
    @test get(recv.counts, "derived_file_analysis", 0) == 0
end
