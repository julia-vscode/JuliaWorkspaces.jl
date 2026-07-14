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

@testitem "Completions: var\"\" identifiers" begin
    # https://github.com/julia-vscode/julia-vscode/issues/3867
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # Apply a CompletionEdit to `src` (byte-based, end-exclusive positions).
    function apply_edit(src, edit)
        lines = split(src, '\n'; keepempty=true)
        lineoff(line) = sum(Int[ncodeunits(lines[l]) + 1 for l in 1:(line-1)])
        s = lineoff(edit.start.line) + edit.start.column
        e = lineoff(edit.stop.line) + edit.stop.column
        cu = codeunits(src)
        return String(vcat(cu[1:s-1], codeunits(edit.new_text), cu[e:end]))
    end

    struct_def = """
    struct Foo
        var"hello world"::Int
        normal::Int
    end
    foo = Foo(1, 2)
    """

    # `index_str` must end with the newline right after the cursor position
    function completions_for(trailer, index_str)
        source = struct_def * trailer
        uri = URI("file:///compvar/$(hash(trailer)).jl")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        index = findfirst(index_str, source)[end]
        return source, get_completions(jw, uri, index)
    end

    # 1) `foo.` offers the var"" field with proper quoting
    source, result = completions_for("foo.\n", "foo.\n")
    @test sort([i.label for i in result.items]) == ["normal", "var\"hello world\""]
    item = only(filter(i -> i.label == "var\"hello world\"", result.items))
    @test occursin("foo.var\"hello world\"\n", apply_edit(source, item.text_edit))

    # 2) `foo.var` offers the var"" field, replacing the typed `var`
    source, result = completions_for("foo.var\n", "foo.var\n")
    @test any(i -> i.label == "var\"hello world\"", result.items)
    item = only(filter(i -> i.label == "var\"hello world\"", result.items))
    @test occursin("foo.var\"hello world\"\n", apply_edit(source, item.text_edit))

    # 3) `foo.var"he` (unterminated string): no duplicated var" prefix
    source, result = completions_for("foo.var\"he\n", "foo.var\"he\n")
    @test any(i -> i.label == "var\"hello world\"", result.items)
    item = only(filter(i -> i.label == "var\"hello world\"", result.items))
    @test occursin("foo.var\"hello world\"\n", apply_edit(source, item.text_edit))

    # 4) `foo.var"he"` with the cursor before the auto-closed quote: the closing
    #    quote is part of the replaced range
    source_t = struct_def * "foo.var\"he\"\n"
    uri_t = URI("file:///compvar/terminated.jl")
    jw_t = JuliaWorkspace()
    add_file!(jw_t, TextFile(uri_t, SourceText(source_t, "julia")))
    index_t = findfirst("foo.var\"he", source_t)[end] + 1  # cursor after `he`, before `"`
    result_t = get_completions(jw_t, uri_t, index_t)
    @test any(i -> i.label == "var\"hello world\"", result_t.items)
    item_t = only(filter(i -> i.label == "var\"hello world\"", result_t.items))
    @test occursin("foo.var\"hello world\"\n", apply_edit(source_t, item_t.text_edit))

    # 5) plain fields are unaffected
    source, result = completions_for("foo.nor\n", "foo.nor\n")
    @test any(i -> i.label == "normal" && i.text_edit.new_text == "normal", result.items)

    # 6) scope completions quote non-identifier names
    scope_src = """
    var"top level thing" = 1
    top
    """
    uri_s = URI("file:///compvar/scope.jl")
    jw_s = JuliaWorkspace()
    add_file!(jw_s, TextFile(uri_s, SourceText(scope_src, "julia")))
    index_s = findfirst("top\n", scope_src)[end]
    result_s = get_completions(jw_s, uri_s, index_s)
    @test any(i -> i.label == "var\"top level thing\"", result_s.items)
    item_s = only(filter(i -> i.label == "var\"top level thing\"", result_s.items))
    @test occursin("var\"top level thing\"\n", apply_edit(scope_src, item_s.text_edit))
    @test !any(i -> i.text_edit.new_text == "top level thing", result_s.items)

    # 7) names that are only non-standard because of var"" quoting (macro-like,
    #    operator-like, or plain) always keep their quoting from the definition
    at_src = """
    struct Bar
        var"@asd"::Int
        var"+"::Int
        var"plain"::Int
    end
    bar = Bar(1, 2, 3)
    bar.
    """
    uri_at = URI("file:///compvar/atfield.jl")
    jw_at = JuliaWorkspace()
    add_file!(jw_at, TextFile(uri_at, SourceText(at_src, "julia")))
    index_at = findfirst("bar.\n", at_src)[end]
    result_at = get_completions(jw_at, uri_at, index_at)
    labels_at = sort([i.label for i in result_at.items])
    @test labels_at == ["var\"+\"", "var\"@asd\"", "var\"plain\""]
    item_at = only(filter(i -> i.label == "var\"@asd\"", result_at.items))
    @test occursin("bar.var\"@asd\"\n", apply_edit(at_src, item_at.text_edit))

    # 8) genuine macros in scope are not var""-wrapped
    macro_src = """
    macro mymacroxyz(x)
        x
    end
    @mymacr
    """
    uri_m = URI("file:///compvar/macros.jl")
    jw_m = JuliaWorkspace()
    add_file!(jw_m, TextFile(uri_m, SourceText(macro_src, "julia")))
    index_m = findfirst("@mymacr\n", macro_src)[end]
    result_m = get_completions(jw_m, uri_m, index_m)
    @test any(i -> i.label == "@mymacroxyz", result_m.items)
    @test !any(i -> i.label == "var\"@mymacroxyz\"", result_m.items)

    # 9) partially typed var"" identifier in scope completions
    scope_src2 = """
    var"top level thing" = 1
    var"top
    """
    uri_s2 = URI("file:///compvar/scope2.jl")
    jw_s2 = JuliaWorkspace()
    add_file!(jw_s2, TextFile(uri_s2, SourceText(scope_src2, "julia")))
    index_s2 = findfirst("var\"top\n", scope_src2)[end]
    result_s2 = get_completions(jw_s2, uri_s2, index_s2)
    @test any(i -> i.label == "var\"top level thing\"", result_s2.items)
    item_s2 = only(filter(i -> i.label == "var\"top level thing\"", result_s2.items))
    @test occursin("var\"top level thing\"\n", apply_edit(scope_src2, item_s2.text_edit))
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

@testitem "Completions: var\"\" module names don't crash import completions (#3867)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, CompletionResult
    using JuliaWorkspaces.URIs2: URI

    # relative-import completion with a var"" child module used to crash in
    # _child_module_names
    source = """
    module Outer
    module var"weird one" end
    module Inner end
    import .
    end
    """
    uri = URI("file:///compvarmod/test.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    index = findfirst("import .\n", source)[end]
    result = get_completions(jw, uri, index)
    labels = [i.label for i in result.items]
    @test "Inner" in labels
    @test "var\"weird one\"" in labels

    # a var"" module name in an existing `using .mod: x` statement used to
    # crash in _add_using_stmt when building import-mode completions
    source2 = """
    module Outer
    module var"weird module" end
    using .var"weird module": foo
    somepartialname
    end
    """
    uri2 = URI("file:///compvarmod/test2.jl")
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(uri2, SourceText(source2, "julia")))
    index2 = findfirst("somepartialname\n", source2)[end]
    result2 = get_completions(jw2, uri2, index2)
    @test result2 isa CompletionResult
end
