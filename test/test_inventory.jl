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
end
