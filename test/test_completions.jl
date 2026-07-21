@testitem "Completions: workspace tree names carry an exported/public tag" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # `foo`/`baz` are declared in a SIBLING file, so they reach the completion
    # only through the module tree (`_add_visible_name_completion`) — not a
    # local scope binding. The exported one must be tagged, matching hover; the
    # internal one gets no tag.
    project_toml = "name = \"CompTag\"\nuuid = \"a2345678-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n"
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[deps]\n"
    entry = "module CompTag\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
    a = "export item_exp\nitem_exp() = 1\nitem_int() = 3\n"
    b = "g() = item\n"   # complete the shared `item` prefix

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///comptag/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptag/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///comptag/src/CompTag.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///comptag/src/a.jl"), SourceText(a, "julia")))
    b_uri = URI("file:///comptag/src/b.jl")
    add_file!(jw, TextFile(b_uri, SourceText(b, "julia")))

    # Cursor right after the `item` partial in `g() = item`.
    result = get_completions(jw, b_uri, first(findfirst("item", b)) + 4)
    exp_item = filter(i -> i.label == "item_exp", result.items)
    int_item = filter(i -> i.label == "item_int", result.items)
    @test length(exp_item) == 1
    @test exp_item[1].detail_description == "exported"   # exported ⇒ tagged
    @test length(int_item) == 1
    @test int_item[1].detail_description === nothing      # internal ⇒ no tag
end

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
    # Fuzzy matches: transposition/omission typos reach their target
    @test is_completion_match("length", "lenght")
    @test is_completion_match("println", "pritnln")
    @test is_completion_match("Vector", "Vecotr")
    @test is_completion_match("filter", "fitler")
    @test is_completion_match("@test", "@tset")
    # ...but unrelated names stay below the cutoff
    @test !is_completion_match("Regex", "pri")
    @test !is_completion_match("setfield!", "shuffel")
end

@testitem "Completions: fuzzy match surfaces typo'd store symbols" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    source = """
    module FuzzyComp

    lenght
    pri

    end
    """

    jw = JuliaWorkspace()
    uri = URI("file:///fuzzycomp/src/FuzzyComp.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Typo'd partial "lenght" (line 3, col 7): no prefix match exists, the
    # fuzzy tier surfaces `length`
    index = string_index(source, 3, 7)
    result = get_completions(jw, uri, index)
    @test any(item -> item.label == "length", result.items)

    # Partial "pri" (line 4, col 4): prefix matches (print, println, ...) must
    # rank above the fuzzy-only match `pi`
    index = string_index(source, 4, 4)
    result = get_completions(jw, uri, index)
    print_idx = findfirst(i -> i.label == "print", result.items)
    pi_idx = findfirst(i -> i.label == "pi", result.items)
    @test print_idx !== nothing
    @test pi_idx !== nothing
    @test print_idx < pi_idx
end

@testitem "Completions: relevance ranking unit" begin
    using JuliaWorkspaces: JuliaWorkspaces

    _match_rank = JuliaWorkspaces._match_rank
    # exact match beats case-sensitive prefix beats case-insensitive prefix beats fuzzy
    @test _match_rank("epsilon", "epsilon") < _match_rank("epsilon", "epsi")
    @test _match_rank("epsilon", "epsi") < _match_rank("Epsilon", "epsi")
    @test _match_rank("Epsilon", "epsi") < _match_rank("betaepsilon", "epsi")
    # case-sensitive prefix (uppercase input) is as good as a lowercase prefix match
    @test _match_rank("Epsilon", "Epsi") == _match_rank("epsilon", "epsi")
end

@testitem "Completions: latex sort order prioritises case match" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompLatexSort"
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
    module CompLatexSort
    \\epsi
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///complatexsort/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///complatexsort/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///complatexsort/src/CompLatexSort.jl"), SourceText(source, "julia")))

    uri = URI("file:///complatexsort/src/CompLatexSort.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # after "\epsi" (line 2, col 6)
    index = string_index(source, 2, 6)
    result = get_completions(jw, uri, index)

    lower = findfirst(i -> i.label == "\\epsilon", result.items)
    upper = findfirst(i -> i.label == "\\Epsilon", result.items)
    @test lower !== nothing
    @test upper !== nothing
    # both still offered, but the case-matching lowercase symbol ranks first
    @test result.items[lower].sort_text !== nothing
    @test result.items[upper].sort_text !== nothing
    @test result.items[lower].sort_text < result.items[upper].sort_text
end

@testitem "Completions: nearer scope sorts first" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CompScopeSort"
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

    source = """
    module CompScopeSort
    myouter = 1
    function f()
        myinner = 2
        my
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///compscopesort/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscopesort/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///compscopesort/src/CompScopeSort.jl"), SourceText(source, "julia")))

    uri = URI("file:///compscopesort/src/CompScopeSort.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # after "    my" (line 5, col 7)
    index = string_index(source, 5, 7)
    result = get_completions(jw, uri, index)

    inner = findfirst(i -> i.label == "myinner", result.items)
    outer = findfirst(i -> i.label == "myouter", result.items)
    @test inner !== nothing
    @test outer !== nothing
    # the binding in the nearer (function) scope ranks above the module-level one
    @test result.items[inner].sort_text < result.items[outer].sort_text
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
        uri"file:///t.jl", st, JuliaWorkspaces.MetaDict(), env, :normal, Dict{String,Any}(), nothing,
        nothing, nothing, nothing,
        Dict{String,Tuple{String,Int}}())

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

@testitem "Completions: getfield via type-asserted assignment" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    structs = """
    abstract type Parent end
    struct Child1 <: Parent
        field1::Int
    end
    struct Child2 <: Parent
        field2::String
    end
    """

    function fields_at(source, marker)
        uri = URI("file:///compassert/test.jl")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        index = findfirst(marker, source)[end]
        sort([item.label for item in get_completions(jw, uri, index).items])
    end

    # Rebinding through an assertion: `x = x::Child1`
    rebind = structs * """
    function foo(x::Parent)
        x = x::Child1
        x.
    end
    """
    @test fields_at(rebind, "\n    x.\n") == ["field1"]

    # Fresh variable bound to an asserted value: `y = x::Child1`
    freshvar = structs * """
    function foo(x::Parent)
        y = x::Child1
        y.
    end
    """
    @test fields_at(freshvar, "\n    y.\n") == ["field1"]

    # Untyped parameter still narrows through the assertion.
    untyped = structs * """
    function foo(x)
        y = x::Child1
        y.
    end
    """
    @test fields_at(untyped, "\n    y.\n") == ["field1"]

    # Partial field text still matches.
    partial = structs * """
    function foo(x::Parent)
        y = x::Child1
        y.fie
    end
    """
    @test fields_at(partial, "y.fie") == ["field1"]

    # Baseline: an abstract declared type with no assertion yields no fields.
    baseline = structs * """
    function foo(x::Parent)
        x.
    end
    """
    @test fields_at(baseline, "\n    x.\n") == String[]
end

@testitem "Completions: getfield type assertion narrows per branch" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    source = """
    abstract type Parent end
    struct Child1 <: Parent
        field1::Int
    end
    struct Child2 <: Parent
        field2::String
    end
    function f(x::Parent)
        if x isa Child1
            y = x::Child1
            y.
        else
            y = x::Child2
            y.
        end
    end
    """
    uri = URI("file:///compassertbranch/test.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    dots = collect(findall("y.\n", source))
    if_fields = sort([i.label for i in get_completions(jw, uri, dots[1][end]).items])
    else_fields = sort([i.label for i in get_completions(jw, uri, dots[2][end]).items])
    @test if_fields == ["field1"]
    @test else_fields == ["field2"]
end

# --- Per-file analyses + module visibility (inventories milestone) -----------

@testitem "Completions: unqualified completion sees sibling-file names" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # entry file declares the package module, includes a sibling and a leaf;
    # module-level names from the entry file and colon-imported sibling names
    # must be offered in the leaf even though the leaf's own meta no longer
    # reaches the module scope.
    function make_ws(leafsrc; host="crossfile1")
        project_toml = """
        name = "MainPkg"
        uuid = "12345678-1234-1234-1234-123456789abc"
        version = "0.1.0"
        """
        manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
        entry = """
        module MainPkg
        include("sib.jl")
        include("leaf.jl")
        using .Sib: exported_fn
        mainfn(x) = 2x
        end
        """
        sib = """
        module Sib
        export exported_fn, @mymac
        exported_fn(x) = x
        unexported_fn(x) = x
        macro mymac(x) x end
        struct SibStruct
            fielda::Int
        end
        end
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///$host/Project.toml"), SourceText(project_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///$host/Manifest.toml"), SourceText(manifest_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///$host/src/MainPkg.jl"), SourceText(entry, "julia")))
        add_file!(jw, TextFile(URI("file:///$host/src/sib.jl"), SourceText(sib, "julia")))
        add_file!(jw, TextFile(URI("file:///$host/src/leaf.jl"), SourceText(leafsrc, "julia")))
        return jw, URI("file:///$host/src/leaf.jl")
    end

    # module-level function declared in the entry file
    leaf1 = "mainf\n"
    jw1, uri1 = make_ws(leaf1; host="crossfile1")
    labels1 = [i.label for i in get_completions(jw1, uri1, findfirst("mainf\n", leaf1)[end]).items]
    @test "mainfn" in labels1

    # colon-imported sibling function (visible at module level via the entry file)
    leaf2 = "exported_f\n"
    jw2, uri2 = make_ws(leaf2; host="crossfile2")
    labels2 = [i.label for i in get_completions(jw2, uri2, findfirst("exported_f\n", leaf2)[end]).items]
    @test "exported_fn" in labels2

    # a file-local binding shadows a same-named visibility entry: exactly one item
    leaf3 = """
    function exported_fn(y)
        y
    end
    exported_f
    """
    jw3, uri3 = make_ws(leaf3; host="crossfile3")
    items3 = get_completions(jw3, uri3, findfirst("exported_f\n", leaf3)[end]).items
    @test count(i -> i.label == "exported_fn", items3) == 1

    # rule 4: the enclosing module's own name (self-binding) appears exactly once
    leaf4 = "MainPk\n"
    jw4, uri4 = make_ws(leaf4; host="crossfile4")
    items4 = get_completions(jw4, uri4, findfirst("MainPk\n", leaf4)[end]).items
    @test count(i -> i.label == "MainPkg", items4) == 1

    # Base exported names still come from the env stores
    leaf5 = "printl\n"
    jw5, uri5 = make_ws(leaf5; host="crossfile5")
    labels5 = [i.label for i in get_completions(jw5, uri5, findfirst("printl\n", leaf5)[end]).items]
    @test "println" in labels5
end

@testitem "Completions: cross-file items carry their defining-file docstring" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, update_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "DocPkg"
    uuid = "d2345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    entry = """
    module DocPkg
    include("sib.jl")
    include("leaf.jl")
    using .Sib
    end
    """
    sib = """
    module Sib
    export documented_fn
    \"\"\"
    documented_fn does a thing
    \"\"\"
    documented_fn(x) = x
    end
    """
    leaf = "documented_f\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///docpkg/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///docpkg/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///docpkg/src/DocPkg.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///docpkg/src/sib.jl"), SourceText(sib, "julia")))
    leaf_uri = URI("file:///docpkg/src/leaf.jl")
    add_file!(jw, TextFile(leaf_uri, SourceText(leaf, "julia")))

    # The completion for a sibling-declared name carries its docstring UPFRONT
    # (no completionItem/resolve handler exists) — resolved request-time from
    # the declaring file via `item_documentation`.
    item = only(filter(i -> i.label == "documented_fn",
        get_completions(jw, leaf_uri, findfirst("documented_f\n", leaf)[end]).items))
    @test item.documentation !== nothing
    @test occursin("documented_fn does a thing", item.documentation)

    # Editing ONLY the docstring in the declaring file surfaces in a fresh
    # completion (docs live outside the inventory; the position leaf reparses).
    update_file!(jw, TextFile(URI("file:///docpkg/src/sib.jl"),
        SourceText(replace(sib, "does a thing" => "does a thing EDITED"), "julia")))
    item2 = only(filter(i -> i.label == "documented_fn",
        get_completions(jw, leaf_uri, findfirst("documented_f\n", leaf)[end]).items))
    @test item2.documentation !== nothing
    @test occursin("does a thing EDITED", item2.documentation)
end

@testitem "Completions/Hover: interpolated docstrings stringify (no MethodError)" begin
    # A docstring containing `$(...)` interpolation does NOT parse as a plain
    # String literal — its payload `to_codeobject`s to a `:string` `Expr`. The
    # doc extraction (`item_documentation`) must yield a `String` so neither the
    # completion path (which passed the raw value to `_sanitize_docstring`, the
    # original crash) nor the hover path chokes.
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "DocInterp"
    uuid = "e3345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    entry = """
    module DocInterp
    include("sib.jl")
    include("leaf.jl")
    using .Sib
    end
    """
    # docstring with STRING INTERPOLATION in the payload
    sib = """
    module Sib
    export Colex
    \"\"\"
        \$(@__MODULE__()).Colex <: Base.Order.Ordering
    The colexicographic ordering for `SmallBitSet`.
    See also [`\$(@__MODULE__()).Lex`](@ref).
    \"\"\"
    struct Colex end
    end
    """
    leaf = "Col\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///docinterp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///docinterp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///docinterp/src/DocInterp.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///docinterp/src/sib.jl"), SourceText(sib, "julia")))
    leaf_uri = URI("file:///docinterp/src/leaf.jl")
    add_file!(jw, TextFile(leaf_uri, SourceText(leaf, "julia")))
    sib_uri = URI("file:///docinterp/src/sib.jl")

    # Completion: must NOT crash and must carry a sane String docstring.
    item = only(filter(i -> i.label == "Colex",
        get_completions(jw, leaf_uri, findfirst("Col\n", leaf)[end]).items))
    @test item.documentation isa String
    @test occursin("colexicographic ordering", item.documentation)

    # Hover on the defining struct name: must NOT crash and render the doc.
    hover = get_hover_text(jw, sib_uri, findfirst("struct Colex", sib)[end])
    @test hover isa String
    @test occursin("colexicographic ordering", hover)
end

@testitem "Completions: dot-completion on a workspace module lists its names" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "MainPkg"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    entry = """
    module MainPkg
    include("sib.jl")
    include("leaf.jl")
    end
    """
    sib = """
    module Sib
    export exported_fn, @mymac
    exported_fn(x) = x
    unexported_fn(x) = x
    macro mymac(x) x end
    struct SibStruct
        fielda::Int
    end
    end
    """
    leaf = """
    function leaffn()
        Sib.
    end
    """
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsdot/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsdot/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsdot/src/MainPkg.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///wsdot/src/sib.jl"), SourceText(sib, "julia")))
    add_file!(jw, TextFile(URI("file:///wsdot/src/leaf.jl"), SourceText(leaf, "julia")))
    uri = URI("file:///wsdot/src/leaf.jl")

    idx = findfirst("Sib.\n", leaf)[end]
    labels = [i.label for i in get_completions(jw, uri, idx).items]
    # old (whole-closure) behavior: ALL names, not just exported ones —
    # matched by the per-file path (probe-verified)
    @test "exported_fn" in labels
    @test "unexported_fn" in labels
    @test "SibStruct" in labels
    # deferred Task-1 minor: member macro resolution through the tree
    @test "@mymac" in labels
    # the module's self-binding is offered exactly once
    @test count(==("Sib"), labels) <= 1

    # partial dot-completion filters
    leaf_p = """
    function leaffn()
        Sib.expo
    end
    """
    jwp = JuliaWorkspace()
    add_file!(jwp, TextFile(URI("file:///wsdotp/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jwp, TextFile(URI("file:///wsdotp/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jwp, TextFile(URI("file:///wsdotp/src/MainPkg.jl"), SourceText(entry, "julia")))
    add_file!(jwp, TextFile(URI("file:///wsdotp/src/sib.jl"), SourceText(sib, "julia")))
    add_file!(jwp, TextFile(URI("file:///wsdotp/src/leaf.jl"), SourceText(leaf_p, "julia")))
    urip = URI("file:///wsdotp/src/leaf.jl")
    idxp = findfirst("Sib.expo", leaf_p)[end]
    labelsp = [i.label for i in get_completions(jwp, urip, idxp).items]
    @test "exported_fn" in labelsp
end

@testitem "Completions: dot-completion on an external module through per-file refs" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "MainPkg"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    entry = """
    module MainPkg
    include("leaf.jl")
    end
    """
    # `Base` resolves to the env-store stand-in in per-file meta
    leaf = """
    function leaffn()
        Base.r
    end
    """
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///extdot/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///extdot/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///extdot/src/MainPkg.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///extdot/src/leaf.jl"), SourceText(leaf, "julia")))
    uri = URI("file:///extdot/src/leaf.jl")

    idx = findfirst("Base.r", leaf)[end]
    labels = [i.label for i in get_completions(jw, uri, idx).items]
    @test "rand" in labels
end

@testitem "Completions: struct fields through tree-resolved types" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    # the struct is declared in the ENTRY file; the leaf sees it only through
    # the module tree (its ref is a struct-kind TreeRef with an ItemRef)
    function make_ws(leafsrc; host)
        project_toml = """
        name = "MainPkg"
        uuid = "12345678-1234-1234-1234-123456789abc"
        version = "0.1.0"
        """
        manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
        entry = """
        module MainPkg
        struct MainStruct
            fielda::Int
            fieldb::String
        end
        include("leaf.jl")
        end
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///$host/Project.toml"), SourceText(project_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///$host/Manifest.toml"), SourceText(manifest_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///$host/src/MainPkg.jl"), SourceText(entry, "julia")))
        add_file!(jw, TextFile(URI("file:///$host/src/leaf.jl"), SourceText(leafsrc, "julia")))
        return jw, URI("file:///$host/src/leaf.jl")
    end

    # annotated parameter
    leaf1 = """
    function leafg(z::MainStruct)
        z.
        1 + 1
    end
    """
    jw1, uri1 = make_ws(leaf1; host="treestruct1")
    idx1 = findfirst("z.\n", leaf1)[end]
    @test sort([i.label for i in get_completions(jw1, uri1, idx1).items]) == ["fielda", "fieldb"]

    # constructor-call assignment
    leaf2 = """
    function leafh()
        x = MainStruct(1, "a")
        x.
        1 + 1
    end
    """
    jw2, uri2 = make_ws(leaf2; host="treestruct2")
    idx2 = findfirst("x.\n", leaf2)[end]
    @test sort([i.label for i in get_completions(jw2, uri2, idx2).items]) == ["fielda", "fieldb"]

    # type-asserted assignment
    leaf3 = """
    function leafi(w)
        y = w::MainStruct
        y.fie
        1 + 1
    end
    """
    jw3, uri3 = make_ws(leaf3; host="treestruct3")
    idx3 = findfirst("y.fie", leaf3)[end]
    @test sort([i.label for i in get_completions(jw3, uri3, idx3).items]) == ["fielda", "fieldb"]
end

@testitem "Completions: import-mode member completions on a stdlib" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "MainPkg"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    entry = """
    module MainPkg
    include("leaf.jl")
    end
    """
    leaf = """
    import Base: floo
    """
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///impstdlib/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///impstdlib/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///impstdlib/src/MainPkg.jl"), SourceText(entry, "julia")))
    add_file!(jw, TextFile(URI("file:///impstdlib/src/leaf.jl"), SourceText(leaf, "julia")))
    uri = URI("file:///impstdlib/src/leaf.jl")

    idx = findfirst("floo\n", leaf)[end]
    labels = [i.label for i in get_completions(jw, uri, idx).items]
    @test "floor" in labels
end

@testitem "Completions: public vs internal unexported symbols get distinct import notes" begin
    using JuliaWorkspaces: JuliaWorkspaces
    const SS = JuliaWorkspaces.SymbolServer

    # tst_exp exported, tst_pub public-but-unexported, tst_int internal.
    # (values are irrelevant to the note; ispublicby only needs the name present)
    vals = Dict{Symbol,Any}(:tst_exp => nothing, :tst_pub => nothing, :tst_int => nothing)
    mod = SS.ModuleStore(SS.VarRef(nothing, :M), vals, "",
                         [:tst_exp], [:tst_exp, :tst_pub], Symbol[])

    @test occursin("public (but unexported)", JuliaWorkspaces._unexported_import_note(mod, "tst_pub"))
    @test occursin("internal", JuliaWorkspaces._unexported_import_note(mod, "tst_int"))
    # sanity: an exported name is public too
    @test occursin("public", JuliaWorkspaces._unexported_import_note(mod, "tst_exp"))
end

@testitem "Completions: labelDetails carry exported/public/internal status" begin
    using JuliaWorkspaces: JuliaWorkspaces
    using JuliaWorkspaces.URIs2: @uri_str
    const SS = JuliaWorkspaces.SymbolServer
    const SL = JuliaWorkspaces.StaticLint

    # External module members: tag comes from the module's export/public lists.
    mvr = SS.VarRef(nothing, :M)
    gen(s) = SS.GenericStore(SS.VarRef(mvr, Symbol(s)), SS.FakeTypeName(SS.VarRef(nothing, :Any), SS.FakeTypeName[]), "")
    vals = Dict{Symbol,Any}(:tst_exp => gen("tst_exp"), :tst_pub => gen("tst_pub"), :tst_int => gen("tst_int"))
    mod = SS.ModuleStore(mvr, vals, "", [:tst_exp], [:tst_exp, :tst_pub], Symbol[])
    env = SL.ExternalEnv(Dict(:M => mod), Dict{SS.VarRef,Vector{SS.VarRef}}(), Symbol[])
    st = JuliaWorkspaces.SourceText("tst_", "julia"); cst = JuliaWorkspaces.CSTParser.parse("tst_")
    state = JuliaWorkspaces._CompletionState(4, Dict{String,JuliaWorkspaces.CompletionResultItem}(), 4, 4, nothing, cst,
        uri"file:///t.jl", st, JuliaWorkspaces.MetaDict(), env, :normal, Dict{String,Any}(), nothing, nothing, nothing, nothing,
        Dict{String,Tuple{String,Int}}())
    JuliaWorkspaces._collect_completions(mod, "tst_", state, true)   # inclexported ⇒ offer all
    @test state.completions["tst_exp"].detail_description == "exported"
    @test state.completions["tst_pub"].detail_description == "public"
    @test state.completions["tst_int"].detail_description == "internal"

    # Workspace bindings: exported/public tagged; internal/local untagged.
    @test JuliaWorkspaces._completion_details_label(SL.Binding(cst, cst, nothing, [], false, true)) == "exported"
    @test JuliaWorkspaces._completion_details_label(SL.Binding(cst, cst, nothing, [], true, false)) == "public"
    @test JuliaWorkspaces._completion_details_label(SL.Binding(cst, cst, nothing, [], false, false)) === nothing
end

@testitem "Completions: using-brought external names still offered" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_completions
    using JuliaWorkspaces.URIs2: URI
    uri = URI("file:///cmp/Foo.jl")
    jw = JuliaWorkspace()
    # `partition` is exported by Base.Iterators; `using Base.Iterators` keeps it
    # offered as an unqualified completion (exercises the shared ext-origins path).
    src = "module Foo\nusing Base.Iterators\nparti\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    result = get_completions(jw, uri, first(findfirst("parti", src)) + 5)
    @test any(item -> startswith(item.label, "partition"), result.items)
end
