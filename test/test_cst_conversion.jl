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
        # `;` width folds onto the rightmost leaf (often trivia) of the
        # preceding sibling, not its last positional arg
        "f(g(a; b=1); c=2)",
        "f(a, g(b; c=1); d=2)",
        "f((a); b=1)",
        "f([a]; b=1)",
        "f(a[1]; b=1)",
        # explicit begin-block bodies are not wrapped a second time
        "x -> begin x end",
        "f() = begin x end",
        # sibling `;` groups nest recursively; empty groups get nothing trivia
        "f(a; b; c)",
        "f(;)",
        "f(x;)",
        # toplevel `;` width lands on the preceding statement's rightmost leaf
        "f(); b",
        "g(); h()",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: call syntax via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "f(x; y=1)",             # parameters node
        "f(x, y=1; z=2, w)",
        "f(x...)",
        "f(; x)",
        "f.(x)",                 # dotcall
        "a.b",                   # getfield with quotenode
        "a.b.c",
        "a.:b",
        "A{T}",                  # curly
        "A{T} where T",
        "a[1]",                  # ref
        "a[1, 2]",
        "a[end]",
        "@m x y",                # macrocall
        "@m(x)",
        "m\"str\"",              # string macro
        "f(x) do y\n    y\nend", # do
        "g(f, xs) do y; y; end",
        "x |> f",
        "a ∘ b",
        "f(g(x))",
        "(f)(x)",
        # inherited from Task 6 concerns: parameters under non-call parents
        "f.(x; y=1)",
        "@m(x; y=1)",
        "T{a; b}",
        "f(a; b...)",
        "f(::Int)",
        # consecutive `;`: widths of ALL adjacent separators fold onto the
        # last real preceding leaf (BEGIN itself when nothing else precedes)
        "begin a;; b end",
        "begin ;; end",
        "a;; b",
        # bare extra `;` in an arg list: the empty group collapses away
        # (a single empty group survives only when all groups are empty)
        "f(a;;b)",
        "f(;;)",
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

    # `;` width must land somewhere even under parent forms whose oracle
    # layout isn't implemented yet — sums have to stay balanced regardless
    for src in ["(; a=1)", "f.(x; y=1)", "@m(x; y=1)", "T{a; b}"]
        @test CSTConversion.check_spans(CSTConversion.build_cst(src)) === nothing
    end

    # corpus runner runs end to end on this package's own test file
    report = joinpath(mktempdir(), "report.md")
    stats = CSTCorpus.run_corpus([@__FILE__]; report_path=report)
    @test stats.total == 1
    @test stats.errored == 0
    @test isfile(report)

    # invariant sweep: every src/ file the converter can parse must satisfy
    # check_spans, whatever its oracle-diff status
    for f in CSTCorpus.julia_files(normpath(joinpath(@__DIR__, "..", "src")))
        ex = try
            CSTConversion.build_cst(read(f, String))
        catch
            continue   # converter errors are tracked by the corpus report
        end
        @test (f, CSTConversion.check_spans(ex)) == (f, nothing)
    end
end
