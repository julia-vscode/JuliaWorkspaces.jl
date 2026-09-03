# The TOML layer of the workspace (src/layer_toml_tree.jl): TomlSyntax-backed
# parse results with real ranges, and the TOML item walk (skeleton, bodies,
# maps) with the v2 backdating contract.

@testsnippet TomlTreeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, update_file!, get_diagnostic,
        get_toml_syntax_tree, derived_toml_syntax_tree, derived_toml_syntax_diagnostics,
        derived_toml_file_skeleton, derived_toml_file_bodies, derived_toml_file_maps,
        derived_toml_item_body, TomlItemRef, TomlItemRow, BodyTree, bt_node_count
    using JuliaWorkspaces.URIs2: URI

    function toml_ws(src; name="Project.toml")
        jw = JuliaWorkspace()
        uri = URI("file:///pr/$name")
        add_file!(jw, TextFile(uri, SourceText(src, "toml")))
        return jw, uri
    end

    slice(src, r) = String(codeunits(src)[first(r):last(r)-1])   # exclusive-end ranges
    rows(jw, uri) = derived_toml_file_skeleton(jw.runtime, uri).items
    row_of(jw, uri, key) = only(filter(r -> r.key == key, rows(jw, uri)))
end

@testitem "toml layer: diagnostics carry real ranges" setup=[TomlTreeWS] begin
    src = "a = 1\nb = \nc = 2\n"
    jw, uri = toml_ws(src)
    ds = derived_toml_syntax_diagnostics(jw.runtime, uri)
    @test length(ds) == 1
    @test ds[1].severity === :error
    @test ds[1].source == "TomlSyntax.jl"
    @test ds[1].message == "unexpected start of value"
    @test ds[1].range == 11:11   # zero-width, before the newline
    @test slice(src, ds[1].range) == ""

    src = "[t\nx = 1\n"
    jw, uri = toml_ws(src)
    ds = derived_toml_syntax_diagnostics(jw.runtime, uri)
    @test [d.message for d in ds] == ["expected end of table ']'"]
    @test ds[1].range == 3:3

    # Semantic errors point at the offending key.
    src = "a = 1\n[t]\nx.y = 1\n[t.x]\n"
    jw, uri = toml_ws(src)
    ds = derived_toml_syntax_diagnostics(jw.runtime, uri)
    @test [d.message for d in ds] == ["key already defined"]
    @test slice(src, ds[1].range) == "t.x"

    # Syntax and semantic diagnostics interleave in byte order.
    src = "a = 1\na = 2\nb = \n"
    jw, uri = toml_ws(src)
    ds = derived_toml_syntax_diagnostics(jw.runtime, uri)
    @test [d.message for d in ds] == ["key already has a value", "unexpected start of value"]
    @test slice(src, ds[1].range) == "a"

    # And they surface as `toml_syntax_errors` on the file.
    diags = get_diagnostic(jw, uri)
    @test [(d.code, d.severity) for d in diags] == [(:toml_syntax_errors, :error), (:toml_syntax_errors, :error)]
    @test slice(src, diags[1].range) == "a"

    # Config files get them too.
    jw, uri = toml_ws("[rules]\nx = \n"; name="JuliaLint.toml")
    @test any(d -> d.code === :toml_syntax_errors, get_diagnostic(jw, uri))
end

@testitem "toml layer: the table keeps every intact item" setup=[TomlTreeWS] begin
    src = """
    name = "Foo"
    uuid = "12345678-1234-1234-1234-123456789abc"
    broken =
    [deps]
    Bar = "abcdef01-1234-1234-1234-123456789abc"
    """
    jw, uri = toml_ws(src)
    t = derived_toml_syntax_tree(jw.runtime, uri)
    @test t["name"] == "Foo"
    @test t["deps"] == Dict("Bar" => "abcdef01-1234-1234-1234-123456789abc")
    @test !haskey(t, "broken")
    @test get_toml_syntax_tree(jw, uri) === t
    @test length(derived_toml_syntax_diagnostics(jw.runtime, uri)) == 1

    # A clean file has no diagnostics and the same dict the stdlib gives.
    jw, uri = toml_ws("a = 1\nb = [1.5, 'x']\n[c.d]\ne = 1979-05-27\n")
    @test isempty(derived_toml_syntax_diagnostics(jw.runtime, uri))
    @test derived_toml_syntax_tree(jw.runtime, uri) == Dict("a" => 1, "b" => Any[1.5, "x"], "c" => Dict("d" => Dict("e" => JuliaWorkspaces.TomlSyntax.Dates.Date(1979, 5, 27))))
end

@testitem "toml layer: skeleton rows" setup=[TomlTreeWS] begin
    src = "a = 1\n[t]\nx.y = 2\n\"q\" = 3\n[[arr]]\nz = 3\n[[arr]]\nz = 4\n"
    jw, uri = toml_ws(src)
    rs = rows(jw, uri)
    @test [(r.order, r.kind, r.key, r.table) for r in rs] == [
        (1, :keyval, ["a"], String[]),
        (2, :table, ["t"], String[]),
        (3, :keyval, ["x", "y"], ["t"]),
        (4, :keyval, ["q"], ["t"]),
        (5, :array_table, ["arr"], String[]),
        (6, :keyval, ["z"], ["arr"]),
        (7, :array_table, ["arr"], String[]),
        (8, :keyval, ["z"], ["arr"]),
    ]
    @test allunique(r.id for r in rs)
    # Ids are content addressed: the same item in another file gets the same id.
    jw2, uri2 = toml_ws(src; name="Other.toml")
    @test [r.id for r in rows(jw2, uri2)] == [r.id for r in rs]
    # Repeated headers keep distinct ids.
    @test rs[5].id != rs[7].id

    # Items after a syntax error survive.
    jw, uri = toml_ws("a = \n[t\nb = 2\nc = ]\nd = 4\n")
    @test [(r.kind, r.key) for r in rows(jw, uri)] == [(:keyval, ["a"]), (:table, [""]), (:keyval, ["b"]), (:keyval, ["c"]), (:keyval, ["d"])]

    # Nothing to walk.
    jw, uri = toml_ws("# just a comment\n")
    @test isempty(rows(jw, uri))
    @test isempty(derived_toml_file_maps(jw.runtime, uri))
end

@testitem "toml layer: bodies, maps and their alignment" setup=[TomlTreeWS] begin
    src = "a = 1\n[t]\nx.y = [1, {p = 'q'}]\n"
    jw, uri = toml_ws(src)
    bodies = derived_toml_file_bodies(jw.runtime, uri)
    maps = derived_toml_file_maps(jw.runtime, uri)
    for r in rows(jw, uri)
        @test bt_node_count(bodies[r.id]) == length(maps[r.id])
    end

    a = row_of(jw, uri, ["a"])
    @test slice(src, maps[a.id][1]) == "a = 1"
    @test slice(src, maps[a.id][2]) == "a"
    @test slice(src, maps[a.id][3]) == "a"
    @test slice(src, maps[a.id][4]) == "1"
    body = bodies[a.id]
    @test body.kind == JuliaWorkspaces.JS2.K"toml_keyval"
    @test body.children[2].val === Int64(1)
    @test derived_toml_item_body(jw.runtime, TomlItemRef(uri, a.id)) === body
    @test derived_toml_item_body(jw.runtime, TomlItemRef(uri, Int64(-1))) === nothing

    # A section item is its header only: two addresses beyond the section itself.
    t = row_of(jw, uri, ["t"])
    @test slice(src, maps[t.id][1]) == "[t]\nx.y = [1, {p = 'q'}]"
    @test slice(src, maps[t.id][2]) == "t"
    @test bt_node_count(bodies[t.id]) == 3

    xy = row_of(jw, uri, ["x", "y"])
    @test slice(src, maps[xy.id][1]) == "x.y = [1, {p = 'q'}]"
    @test bodies[xy.id].children[2].kind == JuliaWorkspaces.JS2.K"toml_array"
    @test slice(src, maps[xy.id][end]) == "'q'"
end

@testitem "toml layer: bodies backdate across position-only edits" setup=[TomlTreeWS] begin
    src = "a = 1\n[t]\nx.y = 2\n"
    jw, uri = toml_ws(src)
    before = Dict(r.key => derived_toml_item_body(jw.runtime, TomlItemRef(uri, r.id)) for r in rows(jw, uri))
    maps_before = derived_toml_file_maps(jw.runtime, uri)
    skel_before = derived_toml_file_skeleton(jw.runtime, uri)

    # Comments, blank lines and whitespace move everything but change nothing.
    src2 = "# header\n\na  =  1   # c\n\n[ t ]\n  x . y = 2\n"
    update_file!(jw, TextFile(uri, SourceText(src2, "toml")))
    after = Dict(r.key => derived_toml_item_body(jw.runtime, TomlItemRef(uri, r.id)) for r in rows(jw, uri))
    @test keys(after) == keys(before)
    for k in keys(before)
        @test after[k] == before[k]
        @test hash(after[k]) == hash(before[k])
    end
    @test derived_toml_file_skeleton(jw.runtime, uri) == skel_before
    @test derived_toml_file_maps(jw.runtime, uri) != maps_before

    # A value edit changes exactly that item's body.
    src3 = "a = 1\n[t]\nx.y = 3\n"
    update_file!(jw, TextFile(uri, SourceText(src3, "toml")))
    after3 = Dict(r.key => derived_toml_item_body(jw.runtime, TomlItemRef(uri, r.id)) for r in rows(jw, uri))
    @test after3[["a"]] == before[["a"]]
    @test after3[["t"]] == before[["t"]]
    @test after3[["x", "y"]] != before[["x", "y"]]
end
