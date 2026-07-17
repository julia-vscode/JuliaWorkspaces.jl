@testitem "Symbols: document symbols basic" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "SymTest"
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
    module SymTest
    a = 1
    b = 2
    function func() end
    struct T
        field1
        field2
    end
    module Inner end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///symtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///symtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///symtest/src/SymTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///symtest/src/SymTest.jl")

    symbols = get_document_symbols(jw, uri)
    @test !isempty(symbols)

    # The top-level module should contain the bindings
    names = [s.name for s in symbols]
    # Check we have typical symbols — the module itself should be one
    all_names = String[]
    function collect_names(syms)
        for s in syms
            push!(all_names, s.name)
            collect_names(s.children)
        end
    end
    collect_names(symbols)
    @test "func" in all_names
    @test "T" in all_names
    @test "Inner" in all_names
end

@testitem "Symbols: workspace symbols search" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "WsSymTest"
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
    module WsSymTest
    my_global_func(x) = x + 1
    another_func(y) = y * 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wssymtest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wssymtest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wssymtest/src/WsSymTest.jl"), SourceText(source, "julia")))

    # Search for "my_" — should find my_global_func
    results = get_workspace_symbols(jw, "my_")
    @test !isempty(results)
    @test any(r -> r.name == "my_global_func", results)

    # Search for "another" — should find another_func
    results2 = get_workspace_symbols(jw, "another")
    @test !isempty(results2)
    @test any(r -> r.name == "another_func", results2)

    # Search for "nonexistent" — should be empty
    results3 = get_workspace_symbols(jw, "nonexistent")
    @test isempty(results3)
end

@testitem "Symbols: var\"\" bindings are included (#3867)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_workspace_symbols
    using JuliaWorkspaces.URIs2: URI

    source = """
    var"top level thing" = 1
    normal_thing = 2
    """

    jw = JuliaWorkspace()
    uri = URI("file:///symvar/test.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    results = get_workspace_symbols(jw, "")
    names = [r.name for r in results]
    @test "top level thing" in names
    @test "normal_thing" in names

    # query matching works against the raw name
    results2 = get_workspace_symbols(jw, "top")
    @test any(r -> r.name == "top level thing", results2)
end

# ============================================================================
# Inventories-migration parity (Task 8, M4): symbols now come from the per-file
# analysis meta (document symbols) and the per-file inventory + item positions
# (workspace symbols), never the whole-root static-lint pass. The old pass is
# still live until M5, so these testitems reproduce its output inline and
# assert the new path against it.
# ============================================================================

@testitem "Symbols: document symbols match old whole-closure path" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_document_symbols
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces as JW

    project_toml = """
    name = "DocSymT"
    uuid = "42345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"
    [deps]
    """
    source = """
    module DocSymT
    my_func(x) = x + 1
    const MyConst = 42
    gg = 3
    struct MyStruct
        f1
    end
    macro mymac(x)
        x
    end
    abstract type MyAbstract end
    module Inner
        inner_fn() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///docsymt/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///docsymt/Manifest.toml"), SourceText(manifest_toml, "toml")))
    uri = URI("file:///docsymt/src/DocSymT.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    rt = jw.runtime
    root = JW.derived_best_root_for_uri(rt, uri)

    # OLD path reproduced inline: whole-closure meta + the (unchanged) walk.
    old_md = JW.derived_static_lint_meta_for_root(rt, root).meta_dict
    cst = JW.derived_julia_legacy_syntax_tree(rt, uri)
    st = JW.input_text_file(rt, uri).content
    old_syms = JW._collect_document_symbols(cst, old_md, st)

    new_syms = get_document_symbols(jw, uri)

    function flat(syms, out=Tuple{String,Int,Int,Int,Int,Int}[])
        for s in syms
            push!(out, (s.name, s.kind, s.start.line, s.start.column, s.stop.line, s.stop.column))
            flat(s.children, out)
        end
        return out
    end

    @test !isempty(flat(new_syms))
    @test flat(old_syms) == flat(new_syms)
end

@testitem "Symbols: workspace symbols parity with old path" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_workspace_symbols
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces as JW

    project_toml = """
    name = "WsParity"
    uuid = "52345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"
    [deps]
    """
    source = """
    module WsParity
    my_func(x) = x + 1
    another(y) = y * 2
    struct MyStruct
        f1
    end
    macro mymac(x)
        x
    end
    abstract type MyAbstract end
    module Inner
        inner_fn() = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsparity/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsparity/Manifest.toml"), SourceText(manifest_toml, "toml")))
    uri = URI("file:///wsparity/src/WsParity.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    rt = jw.runtime

    # OLD workspace symbols reproduced inline.
    function old_ws(q)
        out = Tuple{String,Int,Int,Int,Int}[]
        for u in JW.derived_text_files(rt)
            r = JW.derived_best_root_for_uri(rt, u)
            r === nothing && continue
            md = JW.derived_static_lint_meta_for_root(rt, r).meta_dict
            c = JW.derived_julia_legacy_syntax_tree(rt, u)
            for (rng, b) in JW._collect_toplevel_bindings_w_loc(c, md, query=q)
                s = JW._offset_to_position(rt, u, first(rng))
                e = JW._offset_to_position(rt, u, last(rng))
                push!(out, (JW._get_name_of_binding(b.name), s.line, s.column, e.line, e.column))
            end
        end
        return out
    end

    ot = Dict(t[1] => (t[2], t[3], t[4], t[5]) for t in old_ws(""))
    nt = Dict(r.name => (r.start.line, r.start.column, r.stop.line, r.stop.column) for r in get_workspace_symbols(jw, ""))

    # Definition-family items (functions, structs, abstract types, modules)
    # keep byte-identical (name, uri, range) triples vs the old pass.
    for nm in ["my_func", "another", "MyStruct", "MyAbstract", "WsParity", "Inner", "inner_fn"]
        @test haskey(nt, nm)
        @test nt[nm] == ot[nm]
    end

    # Macros are @-spelled in the inventory (M4 convention): the returned name
    # changes mymac -> @mymac, but the RANGE is unchanged from the old bare name.
    @test haskey(nt, "@mymac")
    @test !haskey(nt, "mymac")
    @test nt["@mymac"] == ot["mymac"]

    # The full name set is identical modulo that one @-rename.
    @test sort(collect(keys(nt))) == sort(replace(collect(keys(ot)), "mymac" => "@mymac"))
end

@testitem "Symbols: workspace @-macro findable by bare and @ query; kinds served" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_workspace_symbols
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "WsMac"
    uuid = "62345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"
    [deps]
    """
    source = """
    module WsMac
    my_func(x) = x + 1
    struct MyStruct
        f1
    end
    macro mymac(x)
        x
    end
    @testitem "should not be a symbol" begin
        z = 1
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsmac/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsmac/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsmac/src/WsMac.jl"), SourceText(source, "julia")))

    # A @-macro item is findable by BOTH the bare and the @-spelled query.
    @test any(r -> r.name == "@mymac", get_workspace_symbols(jw, "mymac"))
    @test any(r -> r.name == "@mymac", get_workspace_symbols(jw, "@mymac"))

    # Filtering stays case-sensitive prefix (mirrors the old startswith filter).
    @test isempty(get_workspace_symbols(jw, "MY_"))

    # Isolated-scope macrocalls (@testitem) are not workspace symbols.
    @test !any(r -> r.name == "@testitem", get_workspace_symbols(jw, ""))

    # SymbolKinds are now served from the inventory (old path hard-coded 1).
    kinds = Dict(r.name => r.kind for r in get_workspace_symbols(jw, ""))
    @test kinds["my_func"] == 12   # Function
    @test kinds["MyStruct"] == 23  # Struct
    @test kinds["@mymac"] == 12    # Function (no LSP Macro kind)
end
