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
        # pre-existing gap found via Task 8 corpus probing: a parenless
        # prefix-op call never gets any trivia, so it must be `nothing`
        "!x",
        "!f(x)",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: control flow and containers via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "if a\nb\nend",
        "if a\nb\nelse\nc\nend",
        "if a\nb\nelseif c\nd\nelse\ne\nend",
        "a ? b : c",
        "while a\nb\nend",
        "for i in xs\ni\nend",
        "for i = 1:10, j in ys\nend",
        "for (a, b) in xs end",
        "try\na\ncatch\nend",
        "try\na\ncatch err\nb\nfinally\nc\nend",
        "try\na\ncatch e\nb\nelse\nc\nend",
        "let x = 1\nx\nend",
        "let\nend",
        "return",
        "return x",
        "break",
        "continue",
        "(a, b)",
        "(a,)",
        "(;a=1)",
        "[1, 2]",
        "[1 2]",
        "[1 2; 3 4]",
        "[1; 2;; 3; 4]",
        "Int[1, 2]",
        "[x for x in xs]",
        "[x for x in xs if x > 0]",
        "(x for x in xs)",
        "[x + y for x in xs, y in ys]",
        "Dict(a => b)",
        "a:b",
        "a:b:c",
        # inherited concerns: paren-block and trailing-`;` vcat
        "(a; b)",
        "[a;]",
        # nested ternary: K"?" reuses the kind for the nested composite node
        # (same trap as if/elseif), which must stay in args, not trivia
        "a ? b : c ? d : e",
        "a ? b ? c : d : e",
        # bare `return` span extends over the keyword's trailing trivia
        # (span = fullspan via the synthetic NOTHING arg), incl. the
        # enclosing trivia-less block measured to it
        "function f()\n    return\nend",
        "while c\n    return\nend",
        "function f()\n    return\n    g()\nend",
        # multi-`for` generators nest inverted under :flatten wrappers
        "[x for x in xs for y in x]",
        "[x for a in as for b in bs for c in cs]",
        "(x for a in as for b in bs)",
        "[x for a in as, b in bs for c in cs]",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: strings and operators via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "\"a\$b c\"",            # interpolation: CSTParser splits chunks differently
        "\"a\$(b + c)d\"",
        "\"\"\"\ntriple \$x\n\"\"\"",
        "`cmd \$x`",
        "```\ncmd\n```",
        "raw\"no \$interp\"",
        "'\\n'",
        "\"esc\\\"aped\"",
        "-x",                    # unary call
        "!x",
        "+x",
        "x'",                    # postfix adjoint
        "x''",
        "a .+ b",                # broadcast infix
        ".!x",
        "a && b",
        "a || b && c",
        "a <: B",
        "a >: B",
        "a === b",
        "x...",
        "&x",
        "::Int",
        "2x",                    # juxtaposition
        "2(x + 1)",
        "a = b = c",             # right-assoc chained assignment
        "a += 1",
        "a .= b",
        "x = \"\"\"\n a\n\"\"\"",
        # inherited concerns
        "\"a\\\n b\"",           # line continuation: multi-chunk string
        "m`c`",                  # cmd macro
        "a && return",
        "A.@m x",                # dotted macrocall
        "@m.n x",                # qualified macrocall name
        "a < b < c",             # comparison chain
        "{a, b}",                # standalone braces
        # raw-flagged (macro-wrapped) strings skip escape processing except
        # for halving backslash runs before a quote/chunk-end
        "r\"\\d+\"",
        "raw\"a\\nb\"",
        "b\"\\x00\"",
        "r\"[/\\\\]+\"",
        "raw\"tr\\\\\\\\\"",
        "raw\"a\\\\\\\"b\"",
        # a BARE string literal as the whole $(...) keeps its :string wrapper
        "\"\$(\"nested\")\"",
        "\"pre\$(\"lit\")post\"",
        "\"\"\"triple \$(\"a\")\"\"\"",
        "`x \$(\"a\")`",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: imports and docstrings via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "using A",
        "using A, B",
        "using A: x, y",
        "using A.B.C",
        "import A",
        "import A as B",
        "import A: x as y",
        "import ..A",
        "export a, b",
        "\"\"\"\ndoc\n\"\"\"\nf(x) = x",
        "\"doc\"\nmodule A end",
        "@doc \"x\" f",
        "quote\nx\nend",
        ":(x + y)",
        ":x",
        "\$x",
        "\$(x)",
        "x where {T, S}",
        "GC.@preserve a f(a)",
        "if VERSION > v\"1.6\" end",
        # more import/export shapes found in the corpus
        "import A.@m",
        "import A.B.@m",
        "using A: @m",
        "import Base: +, -",
        "export @uri_str",
        "export a, @m",
        "using A.B: c",
        # quote-form taxonomy: :quotenode vs :quote vs block form
        ":foo",
        ":(x)",
        ":(if x end)",
        "quote\nend",
        "quote\na\nb\nend",
        # word operators quote as OPERATOR only when colon-prefixed
        ":where", ":in", ":isa",
        "p.in", "p.:in", "a.where",
        # docstring on various targets
        "\"d\"\nf() = 1",
        "\"d\"\nstruct A end",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: containers and burn-down via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        # tuple / vect / ref / braces / typed forms carrying keyword-kinded args
        "(a, :b)",
        "(a,)",
        "(;a=1)",
        "(a=b,)",              # named-tuple field keeps `=` (not `:kw`)
        "(start=x, stop=y)",
        "[a, :b]",
        "a[i, :b]",
        "a[end]",
        "{a, :b}",
        "T[x for x in xs]",
        "T[1 2]",
        "T[1;2]",
        "T[1 2; 3 4]",
        "T[1;;2]",
        "a[i; j]",
        "for Typ in (:Ldiv, :Rdiv)\nend",
        # composite matrix cells get empty (not nothing) trivia
        "[\"a\" => 1\n\"b\" => 2]",
        "[a -b]",
        "[a -b; -c -d]",
        "[a+b c]",
        "[f(x) c]",
        # dotted comparison chains fuse `.`+op into one OPERATOR
        "a .== b .== c",
        "a .=== b",
        # var\"...\" nonstandard identifiers
        "var\"foo\"",
        "var\"@x\"",
        "esc(var\"@m\")",
        # macro args keep `=` as assignment, never `:kw`
        "Base.@propagate_inbounds f() = 1",
        "@m a=1",
        "@m f()=1",
        # nested where clauses (kind-reuse trap)
        "f() where {T} where {N} = x",
        # global/local/const with multiple comma-separated names
        "local a, b",
        "global a, b",
        "local pipe, fork, dup2",
        # bare `return` in a short-circuit grows the operator/block span
        "c && return",
        "function f()\nc && return\nend",
        "a && b",
        # file-level and toplevel `;` bookkeeping
        "x = 1;",
        "1;",
        ";;",
        "f();",
        "return\n",
        # empty-body elseif measures span to its (empty) block
        "if r isa X\nelseif r isa Y\nend",
        # qualified macrocall with parens has span == fullspan
        "x = M.@m(a)\ny",
        "if a\nb = M.@m(\"v\")\nend",
        "x = M.@m(a) + z",
        # operator-as-callee: `+(x)` unwraps to a call, `-`/`!`/`~` keep the
        # bracketed operand
        "+(x)",
        "*(x)",
        "+(::T) = x",
        "-(x)",
        "!(x)",
        "+(::Infinity) = R()",
        # vect element keeps `=` as assignment
        "[a=b]",
        # word operators in selective imports become OPERATOR
        "import Base: in",
        "import Base: +, in, -",
        # interpolated getfield field name (K\"inert\") → quotenode
        "Base.\$f",
        "f.\$g",
        # Float32 literal
        "2f0",
        "1.0f0",
        # while/for with a keyword-kinded condition
        "while let x=1\nx\nend\ny\nend",
        "while c\nx\nend",
        "for i in x\ni\nend",
        # row span with spaces around the `;`
        "[1 2 ; 3 4]",
        "[a b ; c d]",
        # `begin` as an index literal → BEGIN; as a field/symbol → IDENTIFIER
        "a[begin]",
        "a[begin:end]",
        "a.begin",
        ":begin",
        # return-type-annotated short function def wraps its body in a block
        "f()::T = a, b",
        "g()::Tuple{Int,Int} = a, b",
        "x::Int = 5",
        # var\"...\" quoted as a symbol keeps :quotenode
        ":var\"@x\"",
        # a bare `@m` macrocall followed by `;` grows its span to fullspan
        "@m;x",
        "begin @m; x end",
        ":(@_inline_meta; det(x))",
        # quoted dotted operator fuses to one OPERATOR
        ":.&",
        ":.+",
        # -/!/~ operator defs keep a directly-parenthesized operand as brackets
        "macro -(ex)\nend",
        "macro ~(ex)\nend",
        "function -(x) end",
        # operator-as-function-call for <: / >: / ::
        "<:(a, b)",
        "<:(a, b, c)",
        ">:(a, b)",
        # string getfield field name is used directly (no quotenode)
        "a.\"prop\"",
        # global/const nesting: const is outermost
        "global const x = 1",
        "const global x = 1",
        # right-nested juxtaposition of 3+ factors
        "4A'B'",
        "2A'B'C'",
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

    # matrix literals: bare cells carry empty (not nothing) args/trivia with
    # real width — check_spans must not demand a childsum there
    for src in ["[1 2; 3 4]", "[1; 2;; 3; 4]"]
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
