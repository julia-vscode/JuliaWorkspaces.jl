@testitem "Completions: latex completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompTest"
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
    module CompTest
    \\therefor
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comptest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptest/src/CompTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///comptest/src/CompTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # \therefor at end of partial (line 2, col 10 = after "\\therefor")
    index = string_index(source, 2, 10)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "\\therefore", result.items)
    # Check that the replacement text is the unicode char
    item = first(filter(i -> i.label == "\\therefore", result.items))
    @test item.text_edit.new_text == "∴"
end

@testitem "Completions: keyword / snippet completions" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, InsertFormats
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompKW"
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
    module CompKW
    f
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compkw/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkw/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkw/src/CompKW.jl"), SourceText(source, "julia")))

    uri = URI("file:///compkw/src/CompKW.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    index = string_index(source, 2, 2)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "for", result.items)
    @test any(item -> item.label == "function", result.items)
    # "for" snippet should have snippet format
    for_item = first(filter(i -> i.label == "for", result.items))
    @test for_item.insert_text_format == JuliaWorkspaces.InsertFormats.Snippet
end

@testitem "Completions: getfield completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompDot"
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
    module CompDot
    Base.
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compdot/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdot/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdot/src/CompDot.jl"), SourceText(source, "julia")))

    uri = URI("file:///compdot/src/CompDot.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "Base." (line 2, col 6)
    index = string_index(source, 2, 6)
    result = get_completions(jw, uri, index)
    @test length(result.items) > 10
end

@testitem "Completions: getfield partial completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompDotP"
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
    module CompDotP
    Base.r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compdotp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdotp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compdotp/src/CompDotP.jl"), SourceText(source, "julia")))

    uri = URI("file:///compdotp/src/CompDotP.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "Base.r" (line 2, col 7)
    index = string_index(source, 2, 7)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "rand", result.items)
end

@testitem "Completions: getfield completions for workspace structs" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    source = """
    mutable struct Foo{T}
        const val1::Int
        val2::T
        Foo(val1::Integer, val2::T) where T = new{T}(Int(val1), val2)
        Foo{T}(val1::Integer, val2::T) where T = new{T}(Int(val1), val2)
        Bar{V}(val1::Integer, val2::V) where V = new{V}(2 * Int(val1), val2)
        Bar{T}(val1::Integer, val2::T) where T = new{T}(Int(val1), val2)
    end
    x = Foo(1, 2)
    x.
    """

    uri = URI("file:///compfield/test.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    # right after "x."
    index = findfirst("\nx.\n", source)[end]
    result = get_completions(jw, uri, index)

    # only the fields, not type params or inner constructor names
    @test sort([item.label for item in result.items]) == ["val1", "val2"]

    # partial field: cursor at the end and in the middle of "va"
    source2 = replace(source, "x.\n" => "x.va\n")
    uri2 = URI("file:///compfield/test2.jl")
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(uri2, SourceText(source2, "julia")))

    index_mid = findfirst("x.va", source2)[end]  # between "v" and "a"
    for index in (index_mid, index_mid + 1)
        result2 = get_completions(jw2, uri2, index)
        @test sort([item.label for item in result2.items]) == ["val1", "val2"]
    end
end

@testitem "Completions: token completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompTok"
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
    module CompTok
    r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comptok/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptok/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptok/src/CompTok.jl"), SourceText(source, "julia")))

    uri = URI("file:///comptok/src/CompTok.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "r" (line 2, col 2)
    index = string_index(source, 2, 2)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "rand", result.items)
end

@testitem "Completions: scope variable completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompScope"
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
    module CompScope
    myvar = 1
    myv
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compscope/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscope/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscope/src/CompScope.jl"), SourceText(source, "julia")))

    uri = URI("file:///compscope/src/CompScope.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "myv" (line 3, col 4)
    index = string_index(source, 3, 4)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "myvar", result.items)
end

@testitem "Completions: import completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, CompletionResult
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompImp"
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
    module CompImp
    import Base: r
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compimp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compimp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compimp/src/CompImp.jl"), SourceText(source, "julia")))

    uri = URI("file:///compimp/src/CompImp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "import Base: r" (line 2, col 15 = right after "r")
    index = string_index(source, 2, 15)
    result = get_completions(jw, uri, index)
    # In a minimal workspace without symbol server data, Base members won't resolve,
    # so we just verify the function returns a valid result without error.
    @test result isa CompletionResult
end

@testitem "Completions: is_completion_match" begin
    using JuliaWorkspaces: is_completion_match

    # Test the exported fuzzy matching util
    @test is_completion_match("rand", "ran")
    @test is_completion_match("Base", "Bas")
    @test !is_completion_match("x", "rand")
    # Case-insensitive prefix match when prefix is lowercase
    @test is_completion_match("Base", "bas")
    # Case-sensitive when prefix has uppercase
    @test is_completion_match("Base", "Bas")
    @test !is_completion_match("base", "Bas")
end

@testitem "Completions: empty result for empty file" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, CompletionResult
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompEmpty"
    uuid = "82345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = ""

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compempty/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compempty/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compempty/src/CompEmpty.jl"), SourceText(source, "julia")))

    uri = URI("file:///compempty/src/CompEmpty.jl")

    result = get_completions(jw, uri, 1)
    @test result isa CompletionResult
    @test result.is_incomplete == true
end

@testitem "Completions: completion kinds" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, CompletionKinds
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompKinds"
    uuid = "92345678-1234-1234-1234-123456789abc"
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
    module CompKinds
    function f(kind_variable_arg)
        kind_variable_local = 1
        kind_variable_
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compkinds/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkinds/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compkinds/src/CompKinds.jl"), SourceText(source, "julia")))

    uri = URI("file:///compkinds/src/CompKinds.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "kind_variable_" (line 4, col 19)
    index = string_index(source, 4, 19)
    result = get_completions(jw, uri, index)
    @test any(i -> i.label == "kind_variable_local" && i.kind == CompletionKinds.Variable, result.items)
    @test any(i -> i.label == "kind_variable_arg" && i.kind == CompletionKinds.Variable, result.items)
end

@testitem "Completions: relative import completions" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompRelImp"
    uuid = "a2345678-1234-1234-1234-123456789abc"
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
    module CompRelImp
    module M end
    import .
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comprelimp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comprelimp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comprelimp/src/CompRelImp.jl"), SourceText(source, "julia")))

    uri = URI("file:///comprelimp/src/CompRelImp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # After "import ." (line 3, col 9)
    index = string_index(source, 3, 9)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "M", result.items)
end

@testitem "Completions: standalone file (no project)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # No Project.toml or Manifest.toml — exercises _stdlib_only_env() path.
    source = """
    module StandaloneComp

    function myfunc(x)
        return x + 1
    end

    printl
    myfun

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///standalonecomp/src/StandaloneComp.jl"), SourceText(source, "julia")))

    uri = URI("file:///standalonecomp/src/StandaloneComp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Completions for partial stdlib name "printl" (line 7, col 7)
    index = string_index(source, 7, 7)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "println", result.items)

    # Completions for partial local name "myfun" (line 8, col 6)
    index = string_index(source, 8, 6)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "myfunc", result.items)
end

@testitem "Completions: package without manifest (pre-DJP)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # Project.toml present but no Manifest.toml — pre-DJP state.
    project_toml = """
    name = "PreDJPComp"
    uuid = "bbccddee-1122-3344-5566-778899aabbcc"
    version = "0.1.0"
    """

    source = """
    module PreDJPComp

    function greet(name)
        println("Hello")
    end

    printl
    gree

    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///predjpcomp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///predjpcomp/src/PreDJPComp.jl"), SourceText(source, "julia")))

    uri = URI("file:///predjpcomp/src/PreDJPComp.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Completions for partial stdlib name "printl" (line 7, col 7)
    index = string_index(source, 7, 7)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "println", result.items)

    # Completions for partial local name "gree" (line 8, col 5)
    index = string_index(source, 8, 5)
    result = get_completions(jw, uri, index)
    @test !isempty(result.items)
    @test any(item -> item.label == "greet", result.items)
end

@testitem "Completions: unresolvable VarRef does not truncate module symbols" begin
    using JuliaWorkspaces: JuliaWorkspaces, SourceText
    using JuliaWorkspaces.URIs2: @uri_str
    const SS = JuliaWorkspaces.SymbolServer
    const SL = JuliaWorkspaces.StaticLint

    # Regression for the `_collect_completions` fix: a matching but unresolvable
    # `VarRef` symbol in a module (e.g. a re-export whose target is absent from
    # the store) must skip just that symbol — not abort the whole loop and drop
    # every remaining symbol in the module.
    modname = SS.VarRef(nothing, :M)
    genname(s) = SS.VarRef(modname, Symbol(s))
    gen(s) = SS.GenericStore(genname(s), SS.FakeTypeName(SS.VarRef(nothing, :Any), SS.FakeTypeName[]), "", true)

    goods = ["tst_a", "tst_b", "tst_c", "tst_d", "tst_e", "tst_f", "tst_g", "tst_h", "tst_i", "tst_j"]
    vals = Dict{Symbol,Any}()
    for g in goods
        vals[Symbol(g)] = gen(g)
    end
    # A dangling VarRef (its target is not in the depot) that also matches "tst".
    vals[:tst_bad] = SS.VarRef(modname, :tst_bad)

    mod = SS.ModuleStore(modname, vals, "", true, Symbol.(vcat(goods, ["tst_bad"])), Symbol[])
    # Empty depot ⇒ `_lookup(::VarRef, …)` returns nothing for the dangling ref.
    env = SL.ExternalEnv(Dict{Symbol,SS.ModuleStore}(), Dict{SS.VarRef,Vector{SS.VarRef}}(), Symbol[])

    st = SourceText("tst", "julia")
    cst = JuliaWorkspaces.CSTParser.parse("tst")
    state = JuliaWorkspaces._CompletionState(
        3, Dict{String,JuliaWorkspaces.CompletionResultItem}(), 3, 3, nothing, cst,
        uri"file:///t.jl", st, JuliaWorkspaces.MetaDict(), env, :normal, Dict{String,Any}(), nothing)

    JuliaWorkspaces._collect_completions(mod, "tst", state, true)

    labels = keys(state.completions)
    # Every resolvable symbol must be offered, regardless of where the dangling
    # VarRef falls in iteration order.
    for g in goods
        @test g in labels
    end
    @test !("tst_bad" in labels)
end
