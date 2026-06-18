module TestPackage3

using TestItems

@testitem "Foo" begin
    @test 1 == 1
end

end
