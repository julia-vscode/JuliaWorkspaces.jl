@testitem "Signatures: basic function call" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigTest"
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
    module SigTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigtest/src/SigTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigtest/src/SigTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Inside func() on line 3, col 6 (between the parens)
    idx = string_index(source, 3, 6)
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    @test any(s -> !isempty(s.parameters), result.signatures)
end

@testitem "Signatures: struct constructor" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigStruct"
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
    module SigStruct
    struct T
        a
        b
    end
    T()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigstruct/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigstruct/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigstruct/src/SigStruct.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigstruct/src/SigStruct.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Inside T() on line 6, col 3
    idx = string_index(source, 6, 3)
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
end

@testitem "Signatures: empty on non-call" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigEmpty"
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
    module SigEmpty
    x = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigempty/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigempty/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigempty/src/SigEmpty.jl"), SourceText(source, "julia")))

    uri = URI("file:///sigempty/src/SigEmpty.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # On "x = 1" — not a call, should return empty
    idx = string_index(source, 2, 1)
    result = get_signature_help(jw, uri, idx)
    @test isempty(result.signatures)
end

@testitem "Signatures: file without any project" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    source = """
    func(arg) = 1
    func()
    """

    jw = JuliaWorkspace()
    uri = URI("file:///lonely/script.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # Inside func() on line 2 — no Project.toml/Manifest.toml and no active
    # project anywhere, so the environment falls back to stdlib-only
    idx = ncodeunits("func(arg) = 1\n") + 5
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
end

@testitem "Signatures: struct constructor with var\"\" field (#3867)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    # a var"..." field must not crash signature help and must be labeled
    # with its quoted form
    source = """
    struct Foo
        var"hello world"::Int
        normal::Int
    end
    foo = Foo(
    """

    jw = JuliaWorkspace()
    uri = URI("file:///sigvar/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    idx = findfirst("Foo(", source)[end] + 1
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    sig = first(result.signatures)
    @test [p.label for p in sig.parameters] == ["var\"hello world\"", "normal"]
end

@testitem "Signatures: stdlib types unqualified and ::Any omitted" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    function sigs_for(call)
        jw = JuliaWorkspace()
        uri = URI("file:///sigshort/s.jl")
        add_file!(jw, TextFile(uri, SourceText(call, "julia")))
        return get_signature_help(jw, uri, ncodeunits(call)).signatures
    end

    # `identity(x)` has a single method with an untyped (::Any) argument, so
    # the `::Any` annotation must be dropped entirely.
    sigs = sigs_for("identity(")
    @test !isempty(sigs)
    s = first(sigs)
    @test occursin("identity(x) in Base", s.label)
    @test !occursin("Core.Any", s.label)
    @test !occursin("::", split(s.label, " in ")[1])
    @test s.parameters[1].label == (9, 10)  # the `x` in `identity(x)`
    @test s.parameters[1].documentation == ""

    # `print(io::IO, ...)` — the exported `IO` type must render without its
    # `Core.` module qualifier, both in the label and the parameter docs.
    psigs = sigs_for("print(")
    @test !isempty(psigs)
    @test !any(s -> occursin("Core.IO", s.label), psigs)
    @test any(s -> occursin("io::IO", s.label), psigs)
    @test any(s -> any(p -> p.documentation == "IO", s.parameters), psigs)
end

@testitem "Signatures: parameter labels are offset ranges into the signature" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    # `get` has stdlib methods with unnamed arguments (e.g. `get(::Base.EnvDict,
    # k, def)`). The LSP spec requires each parameter label to be either a
    # substring of the signature label or a `[start, end)` UTF-16 offset range
    # into it — never the internal placeholder `#unused#`. We emit offset ranges,
    # so each range must select exactly the parameter's text.
    source = """
    get(
    """

    jw = JuliaWorkspace()
    uri = URI("file:///sigunused/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # UTF-16 code-unit slice of `s` for a 0-based `[start, end)` range. The test
    # signatures are ASCII, so this coincides with a plain character slice.
    function utf16_slice(s, range)
        units = Char[]
        for c in s
            push!(units, c)
            codepoint(c) >= 0x10000 && push!(units, c)  # surrogate pair filler
        end
        return String(units[(range[1] + 1):range[2]])
    end

    result = get_signature_help(jw, uri, ncodeunits("get("))
    @test !isempty(result.signatures)
    params = [(sig.label, p) for sig in result.signatures for p in sig.parameters]
    for (label, p) in params
        @test p.label isa Tuple{Int,Int}
        start, stop = p.label
        @test 0 <= start <= stop
        @test !occursin("#unused#", utf16_slice(label, p.label))
    end
    # An unnamed argument selects a leading `::Type`; `get` has such methods
    # (e.g. `get(::Base.EnvDict, k, def)`), which used to be labeled `#unused#`.
    @test any(((label, p),) -> startswith(utf16_slice(label, p.label), "::"), params)
end

@testitem "Signatures: function with var\"\" argument (#3867)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    source = """
    func(var"weird arg", normal) = 1
    func(
    """

    jw = JuliaWorkspace()
    uri = URI("file:///sigvararg/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    idx = findfirst("\nfunc(", source)[end] + 1
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    sig = first(result.signatures)
    @test [p.label for p in sig.parameters] == ["var\"weird arg\"", "normal"]
end

@testitem "Signatures: methods with 0 positional arguments are not skipped" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    function sigs_for(call)
        jw = JuliaWorkspace()
        uri = URI("file:///sigzero/s.jl")
        add_file!(jw, TextFile(uri, SourceText(call, "julia")))
        return get_signature_help(jw, uri, ncodeunits(call)).signatures
    end

    # A function with a positional method and a keyword-only method: at the open
    # paren all methods are candidates, so both signatures must be offered — the
    # keyword-only `bar(; x)` has 0 positional parameters and must not be dropped.
    sigs = sigs_for("bar(x) = x\nbar(; x) = bar(x)\nbar(")
    labels = [s.label for s in sigs]
    @test any(l -> occursin("bar(x)", l), labels)
    @test any(l -> occursin("bar(; x)", l), labels)

    # A sole keyword-only method must still produce a popup (0 positional args).
    sigs = sigs_for("baz(; x) = x\nbaz(")
    @test !isempty(sigs)
    @test any(l -> occursin("baz(; x)", l.label), sigs)

    # A method that takes no arguments at all must also be offered at `(`.
    sigs = sigs_for("qux() = 1\nqux(")
    @test !isempty(sigs)
end

@testitem "Signatures: cross-file callee shows all method signatures with parameter names" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigCross"
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

    entry = """
    module SigCross
    include("a.jl")
    include("b.jl")
    caller() = greet(
    end
    """
    a_src = "greet(name) = 1\n"
    b_src = "greet(first, last) = 2\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigcross/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigcross/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigcross/src/SigCross.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///sigcross/src/a.jl"), SourceText(a_src, "julia")))
    add_file!(jw, TextFile(URI("file:///sigcross/src/b.jl"), SourceText(b_src, "julia")))

    uri = URI("file:///sigcross/src/SigCross.jl")
    idx = findfirst("greet(", entry)[end] + 1
    result = get_signature_help(jw, uri, idx)

    labels = [s.label for s in result.signatures]
    @test any(l -> occursin("greet(name)", l), labels)
    @test any(l -> occursin("greet(first, last)", l), labels)
    # Parameter names are carried through from the cross-file definitions.
    allparams = [p.label for s in result.signatures for p in s.parameters]
    @test "name" in allparams
    @test "first" in allparams && "last" in allparams
end

@testitem "Signatures: Base.println through the env store is unchanged" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigBase"
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

    # Inside a package module (the migrated per-file meta path), an env-store
    # callee — unqualified `println(` and qualified `Base.println(` — keeps
    # the old SymbolServer signature rendering.
    entry = """
    module SigBase
    f() = println(
    g() = Base.println(
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigbase/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigbase/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigbase/src/SigBase.jl"), SourceText(entry, "julia")))

    uri = URI("file:///sigbase/src/SigBase.jl")

    idx = findfirst("println(", entry)[end] + 1
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    @test any(s -> occursin("println(", s.label) && occursin(" in Base", s.label), result.signatures)

    idx_q = findlast("println(", entry)[end] + 1
    result_q = get_signature_help(jw, uri, idx_q)
    @test !isempty(result_q.signatures)
    @test any(s -> occursin("println(", s.label) && occursin(" in Base", s.label), result_q.signatures)
end

@testitem "Signatures: cross-file struct constructor shows field-based signature" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SigXStruct"
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

    entry = """
    module SigXStruct
    include("t.jl")
    caller() = T(
    end
    """
    t_src = """
    struct T
        a
        b
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sigxstruct/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigxstruct/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///sigxstruct/src/SigXStruct.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///sigxstruct/src/t.jl"), SourceText(t_src, "julia")))

    uri = URI("file:///sigxstruct/src/SigXStruct.jl")
    idx = findfirst("T(", entry)[end] + 1
    result = get_signature_help(jw, uri, idx)
    @test !isempty(result.signatures)
    sig = first(result.signatures)
    @test [p.label for p in sig.parameters] == ["a", "b"]
end
