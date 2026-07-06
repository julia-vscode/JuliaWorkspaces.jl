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

@testitem "cst-conv: terminals via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in ["x", "1", "1.5", "0x1f", "0b101", "0o17", "true", "false",
                "'a'", "\"str\"", "\"a\\nb\"", "\"\\t\"", "\"\\\\\"", "\"\\\"\"",
                "x ", "  x", "# only a comment", ""]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: core forms via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "a = 1",                 # binary syntax: op is the EXPR head
        "a + b",                 # infix call: op moves to args[1]
        "a + b + c",             # chained infix
        "a * b",
        "a == b",
        "(a)",                   # brackets with paren trivia
        "begin\na\nend",         # block with keyword trivia
        "a\nb\nc",               # multi-expression file
        "a; b",
        "f(x)",                  # prefix call
        "f()",
        "f(x, y)",               # comma trivia
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: definitions via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "function f() end",
        "function f(x, y=1; z) x end",
        "function f(x::Int)::Int x end",
        "f(x) = x",
        "x -> x + 1",
        "function (x) x end",
        "struct A end",
        "struct A{T} <: B\n    x::T\nend",
        "mutable struct A x end",
        "abstract type A end",
        "abstract type A{T} <: B end",
        "primitive type A 8 end",
        "macro m(x) x end",
        "module A\nf() = 1\nend",
        "baremodule A end",
        "f(x::T) where T = x",
        "f(x::T) where {T <: Number} = x",
        "const x = 1",
        "global x = 1",
        "local x = 1",
        "mutable struct A\n    const x::Int\nend",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: span invariants and corpus smoke" begin
    using JuliaWorkspaces: CSTConversion
    include(joinpath(@__DIR__, "cst_corpus.jl"))

    # invariants hold on converter output for valid and broken code
    for src in ["f(x) = x + 1", "function f(", "a +", ""]
        ex = CSTConversion.build_cst(src)
        @test ex.fullspan == sizeof(src)
        @test CSTConversion.check_spans(ex) === nothing
    end

    # corpus runner runs end to end on this package's own test file
    report = joinpath(mktempdir(), "report.md")
    stats = CSTCorpus.run_corpus([@__FILE__]; report_path=report)
    @test stats.total == 1
    @test stats.errored == 0
    @test isfile(report)
end
