@testitem "type inference by use" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof

    cst, meta_dict = parse_and_pass("""
    struct T
    end

    struct S
    end

    f(x::T) = 1
    g(x::S) = 1

    function ex1(x)
        f(x)
    end

    function ex2(x)
        f(x)
        g(x)
    end

    function ex3(x)
        if 1
            f(x)
        else
            f(x)
        end
    end

    function ex4(x)
        x
        if 1
            f(x)
        end
    end

    function ex5(x)
        if 1
            f(x)
        else
            g(x)
        end
    end

    function ex6(x)
        if 1
            y = x
            f(y)
        else
            g(x)
        end
    end

    function ex7(x)
        Base.throwto(x, ErrorException("asd"))
    end
    """);

    T = scopeof(cst, meta_dict).names["T"]
    S = scopeof(cst, meta_dict).names["S"]

    @test scopeof(scopeof(cst, meta_dict).names["ex1"].val, meta_dict).names["x"].type == T
    @test scopeof(scopeof(cst, meta_dict).names["ex2"].val, meta_dict).names["x"].type === nothing
    @test scopeof(scopeof(cst, meta_dict).names["ex3"].val, meta_dict).names["x"].type === nothing
    @test scopeof(scopeof(cst, meta_dict).names["ex4"].val, meta_dict).names["x"].type === nothing
    @test scopeof(scopeof(cst, meta_dict).names["ex5"].val, meta_dict).names["x"].type === nothing
    @test scopeof(scopeof(cst, meta_dict).names["ex6"].val, meta_dict).names["y"].type === T
    @test scopeof(scopeof(cst, meta_dict).names["ex7"].val, meta_dict).names["x"].type !== nothing
end


@testitem "loop iterator inference" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof

    cst, meta_dict = parse_and_pass("""
    begin
    abstract type T end
    X = Int[]
    Y = T[]
    end

    for x in 1 end
    for x in "abc" end
    for x in 1:10 end
    for x in 1.0:10.0 end
    for x in Int[1,2,3] end
    for x in X end
    for y in Y end
    """);

    @test scopeof(cst.args[2], meta_dict).names["x"].type === nothing
    @test JuliaWorkspaces.StaticLint.CoreTypes.ischar(scopeof(cst.args[3], meta_dict).names["x"].type)
    @test JuliaWorkspaces.StaticLint.CoreTypes.isint(scopeof(cst.args[4], meta_dict).names["x"].type)
    @test JuliaWorkspaces.StaticLint.CoreTypes.isfloat(scopeof(cst.args[5], meta_dict).names["x"].type)
    @test JuliaWorkspaces.StaticLint.CoreTypes.isint(scopeof(cst.args[6], meta_dict).names["x"].type)
    @test JuliaWorkspaces.StaticLint.CoreTypes.isint(scopeof(cst.args[7], meta_dict).names["x"].type)
    @test JuliaWorkspaces.StaticLint.CoreTypes.isint(scopeof(cst.args[7], meta_dict).names["x"].type)
    @test scopeof(cst.args[8], meta_dict).names["y"].type == scopeof(cst, meta_dict).names["T"]
end

@testitem "range iteration infers eltype from typed bounds" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, CoreTypes

    # A `lo:hi`/`lo:step:hi` range yields an element type from its bounds — not
    # just for numeric literals (`1:10`) but also for references with an inferred
    # type (`1:n`, `a:b`). When the bounds are all `Number`s they need not share
    # an exact type (the range still iterates numbers); the lower bound's type is
    # used as the approximation. A non-`Number` scalar range still requires the
    # bounds to match exactly (e.g. `'a':'z'` → Char).
    cst, meta_dict = parse_and_pass("""
    function g(n::Int, a::Int, b::Int, x::Float64)
        for i in 1:n end
        for i in a:b end
        for i in 1:2:n end
        for i in 1.0:x end
        for i in 1.0:n end
        for i in a:x end
        for i in 'a':'z' end
        for i in 1:length(n) end
    end
    """)

    body = scopeof(cst, meta_dict).names["g"].val.args[2]
    # body.args: [1]=1:n, [2]=a:b, [3]=1:2:n, [4]=1.0:x, [5]=1.0:n, [6]=a:x,
    #            [7]='a':'z', [8]=1:length(n)
    @test CoreTypes.isint(scopeof(body.args[1], meta_dict).names["i"].type)    # 1:n
    @test CoreTypes.isint(scopeof(body.args[2], meta_dict).names["i"].type)    # a:b
    @test CoreTypes.isint(scopeof(body.args[3], meta_dict).names["i"].type)    # 1:2:n
    @test CoreTypes.isfloat(scopeof(body.args[4], meta_dict).names["i"].type)  # 1.0:x
    # Mixed numeric bounds still infer (lower bound's type).
    @test CoreTypes.isfloat(scopeof(body.args[5], meta_dict).names["i"].type)  # 1.0:n -> Float64
    @test CoreTypes.isint(scopeof(body.args[6], meta_dict).names["i"].type)    # a:x  -> Int
    # Non-Number scalar range: exact-match path.
    @test CoreTypes.ischar(scopeof(body.args[7], meta_dict).names["i"].type)   # 'a':'z'
    # An unknown bound (`length(n)` is unresolved) stays inconclusive.
    @test scopeof(body.args[8], meta_dict).names["i"].type === nothing         # 1:length(n)
end

@testitem "Vector{T} infer" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof

    cst, meta_dict = parse_and_pass("""
    struct T
        t1
    end
    struct S
        s1::Vector{T}
    end

    function f(s::S)
        t = s.s1[1]
        t # This should be inferred as T
    end
    """)

    @test scopeof(scopeof(cst, meta_dict).names["f"].val, meta_dict).names["t"].type == scopeof(cst, meta_dict).names["T"]
end

@testitem "destructuring aliased constructor (#398)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, CoreTypes

    # Unpacking via a `const` alias of a struct must resolve field types
    # (and not crash / infinitely recurse).
    cst, meta_dict = parse_and_pass("""
    struct Foo
        a::Int
        b::Int
    end

    const FOO = Foo

    function bar(x)
        (; a, b) = FOO(x, 2x)
        a + b
    end
    """)

    barscope = scopeof(scopeof(cst, meta_dict).names["bar"].val, meta_dict)
    @test CoreTypes.isint(barscope.names["a"].type)
    @test CoreTypes.isint(barscope.names["b"].type)
end

@testitem "destructuring direct constructor" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, CoreTypes

    cst, meta_dict = parse_and_pass("""
    struct Foo
        a::Int
        b::Int
    end

    function bar(x)
        (; a, b) = Foo(x, 2x)
        a + b
    end
    """)

    barscope = scopeof(scopeof(cst, meta_dict).names["bar"].val, meta_dict)
    @test CoreTypes.isint(barscope.names["a"].type)
    @test CoreTypes.isint(barscope.names["b"].type)
end

@testitem "element type is only inferred for scalar indexing (#449)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, errorof, IncorrectCallArgs

    has_callargs(cst, meta_dict, jw) =
        any(errorof(x, meta_dict) === IncorrectCallArgs for (_, x) in collect_hints(cst, meta_dict, jw))

    # A `:`/range/vector slice (or an index of unknown/non-Integer type) of a
    # `Matrix{T}`/`Vector{T}` yields an array, not an element, so the variable
    # must NOT be inferred as the element type `T` — which made `similar(x)`
    # flag a spurious method-call error.
    for idx in (":, L", "1:2, 1", ":", "idxs")
        cst, meta_dict, jw = parse_and_pass("""
            function foobar(M::Matrix{T}, idxs) where T<:Number
                L = size(M, 2)
                x = M[$idx]
                xn = similar(x)
            end
            """)
        fscope = scopeof(scopeof(cst, meta_dict).names["foobar"].val, meta_dict)
        @test fscope.names["x"].type === nothing
        @test !has_callargs(cst, meta_dict, jw)
    end

    # Provably-scalar indices still infer the element type: an integer literal,
    # `begin`/`end`, or a reference whose type is any `Number` subtype (`Int`,
    # `UInt8`, `Float64`, …) — not just `Int`.
    for idx in ("1", "begin", "end", "i", "j", "k")
        cst, meta_dict = parse_and_pass("""
            struct T
                t1
            end
            struct S
                s1::Vector{T}
            end
            function f(s::S, i::Int, j::UInt8, k::Float64)
                t = s.s1[$idx]
                t
            end
            """)
        fscope = scopeof(scopeof(cst, meta_dict).names["f"].val, meta_dict)
        @test fscope.names["t"].type == scopeof(cst, meta_dict).names["T"]
    end
end

@testitem "scalar indexing by a loop variable propagates the element type" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, Binding, valofid

    function binding_named(meta_dict, name)
        for (_, m) in meta_dict
            b = m.binding
            b isa Binding && b.name !== nothing && valofid(b.name) == name && return b
        end
        return nothing
    end

    # A loop variable iterating an Integer range is itself an Integer index, so
    # indexing a `Vector{T}` with it inside the loop body yields `T`. This also
    # exercises that an assignment in the for-loop *body* is no longer mistaken
    # for the loop's iteration spec.
    for header in ("for i in 1:n", "for i in 1:n, k in 1:n")
        cst, meta_dict = parse_and_pass("""
            struct T
                t1
            end
            struct S
                s1::Vector{T}
            end
            function f(s::S, n::Int)
                $header
                    x = s.s1[i]
                end
            end
            """)
        T = scopeof(cst, meta_dict).names["T"]
        x = binding_named(meta_dict, "x")
        @test x !== nothing && x.type == T
    end
end

@testitem "assignments in a for-loop body are not loop iteration specs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: Binding, valofid

    function binding_named(meta_dict, name)
        for (_, m) in meta_dict
            b = m.binding
            b isa Binding && b.name !== nothing && valofid(b.name) == name && return b
        end
        return nothing
    end

    # `is_loop_iter_assignment` must distinguish the iteration spec (`i = 1:n`)
    # from ordinary body assignments. A body assignment to a function-call result
    # must NOT be inferred as that call's element type.
    cst, meta_dict = parse_and_pass("""
        foo() = 1
        function f(n::Int)
            for i in 1:n
                z = foo()
            end
        end
        """)
    z = binding_named(meta_dict, "z")
    @test z !== nothing
    @test z.type === nothing
end
