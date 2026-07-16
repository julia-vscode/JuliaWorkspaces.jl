@testitem "inventory types: structural equality across separately built instances" begin
    using JuliaWorkspaces: FileInventory, InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule
    using JuliaWorkspaces.URIs2: URI

    make() = FileInventory(
        [InventoryItem(1, "f", :function, "f(x)", String[], String[]),
         InventoryItem(2, "S", :struct, nothing, ["a", "b"], ["M"])],
        [InventoryImport(3, :using, [".", "Sibling"], String[], nothing, ["M"])],
        [InventoryExport(4, :export, ["f"], String[])],
        [InventoryInclude(5, URI("file:///pkg/src/a.jl"), String[])],
        [InventoryModule(6, "M", false, String[])],
    )

    a = make()
    b = make()
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)

    c = FileInventory(
        [InventoryItem(1, "g", :function, "g(x)", String[], String[])],
        a.imports, a.exports, a.includes, a.modules)
    @test !isequal(a, c)
end

@testitem "inventory walker: visit order, ids, module nesting, doc unwrap, offsets" begin
    using JuliaWorkspaces: _foreach_toplevel_item
    using JuliaWorkspaces: CSTParser

    src = """
    f() = 1
    \"\"\"
    docs for g
    \"\"\"
    g(x) = x
    module M
    h() = 2
    module Inner
    k() = 3
    end
    end
    w() = 4
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        push!(visited, (id=id, parent=copy(parent_module), offset=offset,
                        ismod=CSTParser.defines_module(x)))
    end

    # 7 item-like nodes: f, g (unwrapped), M, h, Inner, k, w — pre-order ids
    @test [v.id for v in visited] == collect(1:7)
    @test visited[1].parent == String[]          # f
    @test visited[2].parent == String[]          # g (doc-unwrapped)
    @test visited[3].ismod                       # M itself, at top level
    @test visited[3].parent == String[]
    @test visited[4].parent == ["M"]             # h
    @test visited[5].ismod                       # Inner
    @test visited[5].parent == ["M"]
    @test visited[6].parent == ["M", "Inner"]    # k
    @test visited[7].parent == String[]          # w

    # Offsets point at the actual item, not the doc wrapper: the byte at g's
    # offset begins the text "g(x)".
    g_off = visited[2].offset
    @test src[g_off + 1] == 'g'
    # And f's offset is 0.
    @test visited[1].offset == 0

    # Nested-module children: offsets must account for the module keyword
    # (trivia[1]) — regression guard for the args[1]-vs-trivia[1] fix.
    @test src[visited[4].offset + 1] == 'h'   # h inside M
    @test src[visited[6].offset + 1] == 'k'   # k inside M.Inner
    @test src[visited[7].offset + 1] == 'w'   # sibling after the module block
end

@testsnippet InventoryWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function inventory_of(src::String; uri=URI("file:///inv/src/F.jl"), extra_files=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        for (u, s) in extra_files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return JuliaWorkspaces.derived_file_inventory(jw.runtime, uri), jw
    end
end

@testitem "inventory extraction: kinds, names, signatures, fields" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    f(x) = x + 1
    function g(a::Int, b; kw=1)
        a + b
    end
    macro m(ex) end
    const C = 1
    global G = 2
    x = 3
    abstract type A end
    struct S
        a
        b::Int
        const c
    end
    mutable struct MS
        q
    end
    @enum Color red green
    module M
    inner() = 1
    end
    @somethingunknown foo bar
    """)

    byname(n) = only(filter(i -> i.name == n, inv.items))

    @test byname("f").kind === :function
    @test byname("f").signature == "f(x)"
    @test byname("g").kind === :function
    @test occursin("g(a::Int, b", byname("g").signature)
    @test byname("m").kind === :macro
    @test byname("C").kind === :const
    @test byname("G").kind === :global
    @test byname("x").kind === :assignment
    @test byname("A").kind === :abstract
    @test byname("S").kind === :struct
    @test byname("S").field_names == ["a", "b", "c"]
    @test byname("MS").kind === :mutable_struct
    @test byname("Color").kind === :enum
    @test byname("red").kind === :enum_member
    @test byname("green").kind === :enum_member
    @test byname("inner").parent_module == ["M"]
    @test only(filter(m -> m.name == "M", inv.modules)).bare == false
    @test any(i -> i.kind === :opaque_macrocall, inv.items)
end

@testitem "inventory extraction: imports, exports, includes" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/a.jl")
    inv, _ = inventory_of("""
    using Base64
    using ..Sibling: helper, other
    import Foo.Bar as FB
    export f, S
    public g
    include("a.jl")
    f() = 1
    """; extra_files=Dict(a_uri => "z() = 1\n"))

    us = inv.imports
    @test any(i -> i.kind === :using && i.path == ["Base64"], us)
    sib = only(filter(i -> "Sibling" in i.path, us))
    @test sib.path == [".", ".", "Sibling"]
    @test sort(sib.symbols) == ["helper", "other"]
    fb = only(filter(i -> i.alias !== nothing, us))
    @test fb.kind === :import
    @test fb.path == ["Foo", "Bar"]
    @test fb.alias == "FB"

    @test only(filter(e -> e.kind === :export, inv.exports)).names == ["f", "S"]
    @test only(filter(e -> e.kind === :public, inv.exports)).names == ["g"]

    @test only(inv.includes).target == a_uri
end

@testitem "inventory firewall: body, comment, and docstring edits compare equal" setup=[InventoryWS] begin
    base(body) = """
    \"\"\"
    docs
    \"\"\"
    function f(x)
        $body
    end
    struct S
        a::Int
    end
    export f
    """

    inv1, _ = inventory_of(base("x + 1"))
    inv2, _ = inventory_of(base("x * 2\n    # a comment"))
    @test isequal(inv1, inv2)
    @test hash(inv1) == hash(inv2)

    # Docstring text is not part of the inventory.
    inv3, _ = inventory_of(replace(base("x + 1"), "docs" => "totally different docs"))
    @test isequal(inv1, inv3)

    # But an API change is.
    inv4, _ = inventory_of(replace(base("x + 1"), "f(x)" => "f(x, y)"))
    @test !isequal(inv1, inv4)
end
