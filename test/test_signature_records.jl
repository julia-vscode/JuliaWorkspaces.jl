@testitem "signature records: structural equality and Set semantics" begin
    using JuliaWorkspaces: TypeRef, TypeUnionExpr, TypeVarRef, UnknownType,
        SigSlot, VarargSpec, MethodSignature, LocatedSignature, NameMethods, TYPE_ANY, TypeExpr

    # Vector-carrying records must compare by content, not identity.
    @test TypeRef(["Base", "Int"]) == TypeRef(["Base", "Int"])
    @test hash(TypeRef(["Base", "Int"])) == hash(TypeRef(["Base", "Int"]))
    @test TypeRef(["Int"]) != TypeRef(["Base", "Int"])
    @test UnknownType() == UnknownType()
    @test TypeVarRef("T") != TypeRef(["T"])
    @test TypeUnionExpr([TypeRef(["Int"]), UnknownType()]) ==
          TypeUnionExpr([TypeRef(["Int"]), UnknownType()])

    sig(t) = MethodSignature([SigSlot(t, false)], nothing,
        Dict{String,TypeExpr}(), Symbol[], false)
    @test sig(TypeRef(["Own"])) == sig(TypeRef(["Own"]))
    @test sig(TypeRef(["Own"])) != sig(TypeRef(["Other"]))

    # Set collapses duplicates and equality is order-insensitive.
    a = LocatedSignature(["MainPkg"], sig(TypeRef(["Own"])))
    b = LocatedSignature(["MainPkg"], sig(TypeRef(["Other"])))
    @test Set([a, b, a]) == Set([b, a])
    @test NameMethods(Set([a, b]), false, false) == NameMethods(Set([b, a]), false, false)
    @test TYPE_ANY == TypeRef(["Core", "Any"])
end
