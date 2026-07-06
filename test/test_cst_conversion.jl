@testitem "cst-conv: tree diff basics" begin
    using CSTParser
    using JuliaWorkspaces: CSTConversion

    a = CSTParser.parse("f(x) = x + 1", true)
    b = CSTParser.parse("f(x) = x + 1", true)
    c = CSTParser.parse("f(x) = x + 2", true)
    d = CSTParser.parse("f(x) = x +  1", true)   # same tree, different trivia width

    @test CSTConversion.trees_equal(a, b)
    @test CSTConversion.first_tree_diff(a, b) === nothing
    @test !CSTConversion.trees_equal(a, c)
    @test CSTConversion.first_tree_diff(a, c) isa String
    @test !CSTConversion.trees_equal(a, d)      # fullspans must be compared
end

@testitem "cst-conv: leaf flattening" begin
    using JuliaSyntax
    using JuliaSyntax: @K_str
    using JuliaWorkspaces: CSTConversion

    function leaves_of(src)
        stream = JuliaSyntax.ParseStream(src)
        JuliaSyntax.parse!(stream; rule=:all)
        green = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
        CSTConversion.flatten_leaves(green, src)
    end

    # "x + 1" → tokens x,+,1 ; ws folded into preceding token's fullspan
    ls, leading = leaves_of("x + 1")
    @test leading == 0
    @test [l.kind for l in ls] == [K"Identifier", K"+", K"Integer"]
    @test [l.pos for l in ls] == [1, 3, 5]
    @test [l.span for l in ls] == [1, 1, 1]
    @test [l.fullspan for l in ls] == [2, 2, 1]

    # comments are trivia too
    ls, _ = leaves_of("x # hi\ny")
    @test [l.kind for l in ls] == [K"Identifier", K"Identifier"]
    @test ls[1].fullspan == 7     # "x # hi\n"
    @test ls[2].pos == 8

    # file-leading trivia is reported separately
    ls, leading = leaves_of("  x")
    @test leading == 2
    @test ls[1].pos == 3

    # invariant: leaves tile the file
    for src in ["f(a; b=1) do x\n  x\nend", "\"str\\n\" * `cmd`", ""]
        ls, lead = leaves_of(src)
        @test lead + sum(l -> l.fullspan, ls; init=0) == sizeof(src)
    end
end
