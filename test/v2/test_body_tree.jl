@testsnippet BodyTreeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: BodyTree, body_tree, body_tree_with_map,
        parse_julia_syntax_tree, derived_file_body_forest, derived_file_body_maps,
        derived_item_body, derived_item_body_hash, derived_file_inventory, ItemRef,
        update_file!
    using JuliaWorkspaces.URIs2: URI

    const BT_URI = URI("file:///bt/src/F.jl")

    function bt_workspace(src::String; uri=BT_URI)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        return jw
    end

    parse1(src) = parse_julia_syntax_tree(src)[1]

    function item_id(jw, name; uri=BT_URI)
        inv = derived_file_inventory(jw.runtime, uri)
        return only(filter(i -> i.name == name, inv.items)).id
    end

    # Preorder address of the first node satisfying `pred`, or nothing.
    function bt_addr_of(t::BodyTree, pred)
        addr = 0
        found = nothing
        function go(n)
            addr += 1
            if found === nothing && pred(n)
                found = addr
            end
            n.children === nothing && return
            foreach(go, n.children)
        end
        go(t)
        return found
    end

    function bt_count(t::BodyTree)
        n = 1
        t.children === nothing && return n
        for c in t.children
            n += bt_count(c)
        end
        return n
    end

    slice(content, r) = content[first(r):last(r)-1]  # ranges are exclusive-end
end

@testitem "body tree: structural value semantics" setup=[BodyTreeWS] begin
    t1 = body_tree(parse1("f(x) = x + 1"))
    t2 = body_tree(parse1("f(x) = x + 1"))
    @test t1 == t2
    @test isequal(t1, t2)
    @test hash(t1) == hash(t2)

    # Trivia inside the item is invisible: comments and whitespace don't matter.
    t3 = body_tree(parse1("function f(x)\n    # a comment\n    x  +  1\nend"))
    t4 = body_tree(parse1("function f(x)\n    x + 1\nend"))
    @test t3 == t4
    @test hash(t3) == hash(t4)

    # But the short form and the long form are different syntax.
    @test t1 != t3

    # Content differences are visible.
    @test body_tree(parse1("f(x) = x + 1")) != body_tree(parse1("f(x) = x + 2"))
    @test body_tree(parse1("f(x) = x + 1")) != body_tree(parse1("f(y) = y + 1"))
    @test body_tree(parse1("f() = 1")) != body_tree(parse1("f() = 1.0"))
    @test body_tree(parse1("\"str\"")) != body_tree(parse1(":str"))
end

@testitem "body tree: constructor-level distinctions" setup=[BodyTreeWS] begin
    leaf = body_tree(parse1("1")).children[1]
    @test leaf.children === nothing
    k = leaf.kind

    # Leaf values of different types are unequal even when `isequal` on the
    # raw values would say otherwise (isequal(1, UInt8(1)) is true).
    @test BodyTree(k, 1, nothing) != BodyTree(k, UInt8(1), nothing)

    # A leaf is not an interior node with zero children.
    @test BodyTree(k, nothing, nothing) != BodyTree(k, nothing, BodyTree[])
end

@testitem "body tree: map alignment with the tree walk" setup=[BodyTreeWS] begin
    src = "f(x) = x + 1"
    node = parse1(src).children[1]  # the item, not the toplevel wrapper
    tree, ranges = body_tree_with_map(node)

    @test tree == body_tree(node)
    @test length(ranges) == bt_count(tree)

    # Address 1 is the whole item.
    @test slice(src, ranges[1]) == "f(x) = x + 1"

    # A leaf address maps to that leaf's text.
    xaddr = bt_addr_of(tree, n -> n.val === :x)
    @test xaddr !== nothing
    @test slice(src, ranges[xaddr]) == "x"
end

@testitem "body tree: forest is position-independent, ids are content-addressed" setup=[BodyTreeWS] begin
    jw1 = bt_workspace("f(x) = x + 1\n")
    jw2 = bt_workspace("# header\n\n\ng() = 2\n\nf(x) = x + 1\n")

    id1 = item_id(jw1, "f")
    id2 = item_id(jw2, "f")
    @test id1 == id2  # content-addressed ids agree across files

    f1 = derived_file_body_forest(jw1.runtime, BT_URI)[id1]
    f2 = derived_file_body_forest(jw2.runtime, BT_URI)[id2]
    @test isequal(f1, f2)
    @test f1.hash == f2.hash
end

@testitem "body tree: values backdate across position-only edits" setup=[BodyTreeWS] begin
    src1 = "f(x) = x + 1\n"
    jw = bt_workspace(src1)
    ref = ItemRef(BT_URI, item_id(jw, "f"))

    b1 = derived_item_body(jw.runtime, ref)
    h1 = derived_item_body_hash(jw.runtime, ref)
    m1 = derived_file_body_maps(jw.runtime, BT_URI)[ref.id]
    @test b1 !== nothing
    @test h1 == b1.hash

    # Whitespace and comments above the item: value identical, map shifted.
    update_file!(jw, TextFile(BT_URI, SourceText("# comment\n\n\n" * src1, "julia")))
    b2 = derived_item_body(jw.runtime, ref)
    m2 = derived_file_body_maps(jw.runtime, BT_URI)[ref.id]
    @test isequal(b1, b2)
    @test derived_item_body_hash(jw.runtime, ref) == h1
    @test m1 != m2

    # A real content edit changes the value and the hash.
    update_file!(jw, TextFile(BT_URI, SourceText("f(x) = x + 2\n", "julia")))
    b3 = derived_item_body(jw.runtime, ref)
    @test b3 !== nothing
    @test !isequal(b1, b3)
    @test derived_item_body_hash(jw.runtime, ref) != h1
end

@testitem "body tree: comment inside the body backdates, map still shifts" setup=[BodyTreeWS] begin
    jw = bt_workspace("function f(x)\n    x + 1\nend\n")
    ref = ItemRef(BT_URI, item_id(jw, "f"))

    b1 = derived_item_body(jw.runtime, ref)
    m1 = derived_file_body_maps(jw.runtime, BT_URI)[ref.id]

    update_file!(jw, TextFile(BT_URI, SourceText("function f(x)\n    # note\n    x + 1\nend\n", "julia")))
    b2 = derived_item_body(jw.runtime, ref)
    m2 = derived_file_body_maps(jw.runtime, BT_URI)[ref.id]

    @test isequal(b1, b2)
    @test m1 != m2  # ranges after the comment shifted
end

@testitem "body tree: association coverage across wrappers" setup=[BodyTreeWS] begin
    src = """
    \"\"\"
    docstring
    \"\"\"
    f(x) = x

    begin
        g() = 1
    end

    if VERSION >= v"1.0"
        h() = 2
    else
        h2() = 3
    end

    struct S
        a::Int
    end

    const C = 42
    """
    jw = bt_workspace(src)
    inv = derived_file_inventory(jw.runtime, BT_URI)
    forest = derived_file_body_forest(jw.runtime, BT_URI)

    # Forest keys are a subset of inventory ids.
    inv_ids = Set(i.id for i in inv.items)
    @test all(id in inv_ids for id in keys(forest))

    # All the wrapped/plain items got a body tree.
    for name in ["f", "g", "h", "h2", "S", "C"]
        @test haskey(forest, item_id(jw, name))
    end

    # The docstring wrapper is transparent: f's tree is the function itself.
    @test isequal(forest[item_id(jw, "f")], body_tree(parse1("f(x) = x").children[1]))
end

@testitem "body tree: module items get no body tree" setup=[BodyTreeWS] begin
    src = "module M\ng() = 1\nend\n\nbaremodule B\nend\n"
    jw = bt_workspace(src)
    inv = JuliaWorkspaces.derived_file_inventory(jw.runtime, BT_URI)
    forest = derived_file_body_forest(jw.runtime, BT_URI)

    for name in ["M", "B"]
        mod_id = only(filter(m -> m.name == name, inv.modules)).id
        @test !haskey(forest, mod_id)
        @test derived_item_body(jw.runtime, ItemRef(BT_URI, mod_id)) === nothing
    end

    # Inner items still get trees.
    @test haskey(forest, item_id(jw, "g"))
end

@testitem "body tree: malformed and missing files degrade quietly" setup=[BodyTreeWS] begin
    jw = bt_workspace("f(x = ) := nonsense +\n")
    @test derived_file_body_forest(jw.runtime, BT_URI) isa Dict{Int64,<:BodyTree}
    @test derived_file_body_maps(jw.runtime, BT_URI) isa Dict{Int64,Vector{UnitRange{Int}}}

    missing_ref = ItemRef(URI("file:///bt/src/Missing.jl"), Int64(1))
    @test derived_item_body(jw.runtime, missing_ref) === nothing
    @test derived_item_body_hash(jw.runtime, missing_ref) == UInt64(0)
end
