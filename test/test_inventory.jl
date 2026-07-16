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
