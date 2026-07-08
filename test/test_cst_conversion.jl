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
    # (the infix `+` leaf reclassifies to Identifier in JuliaSyntax 1.x)
    ls, leading = leaves_of("x + 1")
    @test leading == 0
    @test [l.kind for l in ls] == [K"Identifier", K"Identifier", K"Integer"]
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
        local ls, lead = leaves_of(src)
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
        # `;` before `end` in end-terminated, non-block-bodied type decls folds
        # onto the preceding leaf (no block body to hold it)
        "abstract type A; end",
        "primitive type P 8; end",
        "abstract type A end;",
        # short-form def whose RHS is itself an anon `function`: the def
        # discriminator keys on a genuine `function` keyword LEAF, not a nested
        # K"function" child
        "f(x) = function (y) y end",
        "f(x) = function g() end",
        # bare unary `::T` (call-shaped T) kwarg default is not a return-type
        # def; its wrapped body block keeps EXPR[] trivia
        "f(::typeof(x) = x) = 1",
        "g(::typeof(sin) = sin) = 1",
        "f(x::Int)::Int = x",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: word-operator reclassification via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        # comparison-chain word operators label OPERATOR, not IDENTIFIER
        "p isa typeinfo <: Pair",
        "a in b in c",
        "a isa B",
        # export/public name lists reclassify word operators too
        "export isa",
        "export in, isa",
        "export a, b",
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
        # `begin`/`end` as an index literal → BEGIN/END; as a field/symbol
        # or quoted name → IDENTIFIER (regression: `.end` was wrongly kept
        # as the END literal, matched only for `.begin`)
        "a[begin]",
        "a[begin:end]",
        "a.begin",
        "a.end",
        "(a).end",
        "f().end",
        ":begin",
        ":end",
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
        # bare qualified macrocall (no args) grows span to fullspan
        "function g()\nBase.@_inline_meta\nx\nend",
        "Base.@inline_meta\ny",
        # dotted assignment quotes to an OPERATOR atom; dotted broadcast stays a quote
        ":(.=)",
        ":(.+)",
        ":(.==)",
        # interpolated-string call arg followed by `;` params: the `;` folds
        # onto the trailing chunk (childsums stay balanced)
        "f(\"\$x\"; k=1)",
        "printstyled(\" x\$flags \"; color=:y)",
        "pipeline(`a \$b`; c)",
        # `let bindings ; body end`: the `;` folds onto the bindings
        "let x=1; y end",
        "let s; x end",
        "let i=1; f(); end",
        # `;`-fold onto a qualified macrocall inside a paren-block
        "(Base.@m; x)",
        "(Base.@_inline_meta; f(x))",
        # a lone bare cell in a multi-row matrix still gets the cell quirk
        "[1 2; 3]",
        "Float64[1 2; 3]",
        "T[1 2; 3]",
        # do-block with no params: the `;` folds onto the DO keyword
        "f(x) do; y end",
        "f(x) do; end",
        "f(a) do; g(b) do; z end end",
        # a dotted `.=` broadcast as a call arg stays operator-headed (not :kw)
        "f(x .= y)",
        "Matrix(C .= 2.0 .* A) ≈ B ≈ D",
        "@m(a .= b)",
        # quoted dotted compound assignment fuses to an OPERATOR atom
        ":(.+=)",
        ":(.*=)",
        # parenthesized signature is a function def (block-wrapped body)
        "(f(x)) = y",
        "(f(x) where T) = y",
        "(x) = y",
        # var\"...\" as a module name keeps EXPR[] trivia
        "module var\"#I\"\nend",
        # one-line `try; ...; end;` in a quote: the trailing `;` after END is
        # excluded from the try's span (END-terminated)
        "quote try; f(); catch; false; finally; end; end",
        # triple-string leading chunk with content (dedented to "") stays an arg
        "\"\"\"\n\$(a)\nb\"\"\"",
        # empty catch body: degenerate block before else, FALSE (var-less)
        # before finally, plain block when it has a var
        "try\ncatch\nelse\nend",
        "try\nx\ncatch\ny\nelse\nz\nend",
        "try\nf()\ncatch\nfinally\nend",
        "try\nf()\ncatch E\nfinally\nend",
        # global-const with a multi-line RHS: span measured to the last arg
        "global const x = if a\nb\nend",
        "const global pkgio = verbose ? y : z",
        # inherited deferred: bare return + explicit `;` in begin/do blocks
        "begin return; end",
        "f(x) do y; return; end",
        # qualified-macrocall span quirk propagates through a nesting macrocall
        "x = @eval M.@m(a)\n\ny",
        "@eval M.@m(a)\ny",
        # dotted-operator prefix calls unwrap parens like the non-dotted path
        ".+(x)",
        ".+(a,b)",
        ".!(x)",
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

@testitem "cst-conv: broken code invariants" begin
    using CSTParser
    using JuliaWorkspaces: CSTConversion

    walk(x, count) = begin
        count[] += 1
        x.args === nothing || foreach(a -> walk(a, count), x.args)
    end

    # Full CSTParser iterate/getindex traversal (the exact protocol StaticLint's
    # include walker uses); it must not throw on any broken shape — an
    # arity/slot mismatch (e.g. an errortoken misfiled into args) surfaces here
    # as a BoundsError even when check_spans is clean.
    iterate_walk(x) = (for c in x; iterate_walk(c); end)

    for src in [
        "function f(",
        "a +",
        "f(x,",
        "if a",
        "struct",
        "a.b.",
        "\"unterminated",
        "x = @",
        "function f() en",
        "a ? b",
        "[1, 2",
        "module A function g() end",
        # unterminated end-keyword forms: the missing `end` must land as a
        # trivia END-placeholder, not a spurious extra arg that breaks iterate
        "for i in 1:10\n",
        "while true\n",
        "try\nfoo(\n",
        "function f()\n",
        "macro m()\n",
        "begin\nfor i in xs\n",
        "module M\nwhile c\n",
        # trailing trivia folded into a dropped error marker must not
        # materialize as a width-bearing filler arg (ternary arity break)
        "a ? b\n",
        "a ? b \n",
        "x = a ? b\n",
        "a ? b :\n",
        "if a \n",
        "struct \n",
        "while true \n",
        # truncated triple-quoted docstrings: error kids inside a K"string"
        # node must extend the content run, not double as close quotes
        # (overlapping-chunk childsum bug found by a depot prefix sweep)
        "\"\"\"\n\\",
        "\"\"\"",
        "\"\"\"\n    doc\n\n```julia\nf(\"# x\\\"",
        "\"\"\"\n```\n\\\"",
        # bare quote leaf under an error node (no wrapping string node)
        "= \"",
        "= \"abc",
    ]
        ex = CSTConversion.build_cst(src)
        @test ex isa CSTParser.EXPR
        @test ex.fullspan == sizeof(src)
        @test CSTConversion.check_spans(ex) === nothing
        # error subtrees must be traversable by StaticLint-style recursion
        count = Ref(0)
        walk(ex, count)
        @test count[] > 0
        # and by CSTParser's own iterate protocol
        @test (iterate_walk(ex); true)
    end

    # three degenerate whole-file shapes from the divergence log: must
    # never throw even though they carry no real statement content
    for src in [";", ";; a", "\"just a docstring\""]
        ex = CSTConversion.build_cst(src)
        @test ex.fullspan == sizeof(src)
        @test CSTConversion.check_spans(ex) === nothing
    end

    # regression: a module missing its closing `end` entirely (the getfield
    # completion trigger shape, `module M\nBase.\nend\n`, where the dangling
    # `Base.` consumes the literal `end` as its field name) must match
    # CSTParser's own missing-token convention (errortoken wrapping a
    # zero-width END in trivia[2]), not leak a 4th :module arg — the leak
    # broke CSTParser's own iterate protocol with a BoundsError downstream.
    for src in ["module CompDot\nBase.\nend\n", "module A\nBase.\nend\n"]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end

@testitem "cst-conv: single-parse salsa integration" begin
    using CSTParser, JuliaSyntax
    using JuliaSyntax: kind, @K_str
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URI

    content = "f(x) = x + 1\n"
    jw = JuliaWorkspace()
    uri = URI("file:///a.jl")
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    cst = JuliaWorkspaces.get_legacy_cst(jw, uri)
    @test cst isa CSTParser.EXPR
    @test JuliaWorkspaces.CSTConversion.trees_equal(cst, CSTParser.parse(content, true))

    sn = JuliaWorkspaces.get_julia_syntax_tree(jw, uri)
    # syntax_node_at takes a 0-based offset (matching get_expr1): offset 7 is
    # byte 8, the RHS 'x'.
    @test JuliaWorkspaces.syntax_node_at(sn, 0) isa JuliaSyntax.SyntaxNode
    @test kind(JuliaWorkspaces.syntax_node_at(sn, 7)) == K"Identifier"

    # Boundary contract: 0-based, in-range only.
    sn2 = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, "x + 1")  # sizeof 5
    @test kind(JuliaWorkspaces.syntax_node_at(sn2, 0)) == K"Identifier"   # first leaf
    @test kind(JuliaWorkspaces.syntax_node_at(sn2, 4)) == K"Integer"      # last leaf
    @test_throws ArgumentError JuliaWorkspaces.syntax_node_at(sn2, -1)
    @test_throws ArgumentError JuliaWorkspaces.syntax_node_at(sn2, 5)     # == sizeof
end

@testitem "cst-conv: unterminated block diagnostics never throw" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URI,
        get_diagnostics_blocking

    # An unterminated for/while/try leaked an errortoken into args, breaking
    # CSTParser's iterate protocol; StaticLint's include walker then threw a
    # BoundsError and killed diagnostics for the whole workspace.
    for src in ["for i in 1:10\n", "while true\n", "try\nfoo(\n", "function f()\n",
                "a ? b\n"]
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///a.jl"), SourceText(src, "julia")))
        @test (get_diagnostics_blocking(jw); true)
    end
end

@testitem "cst-conv: deep nesting never throws (enlarged parse stack)" begin
    using CSTParser
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URI

    # Machine-generated deeply-nested `||` chain: overflows JuliaSyntax's
    # recursive-descent parser at the default task stack size.
    n = 50_000
    content = "x = " * join(fill("a", n), " || ") * "\n"

    jw = JuliaWorkspace()
    uri = URI("file:///deep.jl")
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    sn = JuliaWorkspaces.get_julia_syntax_tree(jw, uri)
    @test sn !== nothing

    cst = JuliaWorkspaces.get_legacy_cst(jw, uri)
    @test cst isa CSTParser.EXPR
    @test cst.fullspan == sizeof(content)
end
