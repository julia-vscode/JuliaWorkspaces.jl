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
