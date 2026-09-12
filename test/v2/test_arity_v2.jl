# The v2 arity machinery (src/v2/layer_arity_v2.jl): per-item `MethodArity`
# from BodyTrees, and the per-root (module path, name) → arities funnel.

@testsnippet ArityWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        MethodArity
    using JuliaWorkspaces.URIs2: URI

    const AR_URI = URI("file:///ar/src/Root.jl")

    function ar_workspace(files::Pair{String,String}...)
        jw = JuliaWorkspace()
        for (path, src) in files
            add_file!(jw, TextFile(URI("file:///ar/src/$path"), SourceText(src, "julia")))
        end
        return jw
    end
    ar_workspace(src::String) = ar_workspace("Root.jl" => src)

    # The arity of the FIRST (usually only) method of `name` at the root module.
    function ar_first(src::String, name::String)
        jw = ar_workspace(src)
        arities = JW.derived_v2_method_arities(jw.runtime, AR_URI, String[], name)
        (arities === nothing || isempty(arities)) && return arities
        return only(arities)
    end

    ma(minargs, maxargs, kws=Symbol[], kwsplat=false) =
        MethodArity(minargs, maxargs, kws, kwsplat)
    const ANY_ARITY = MethodArity(0, typemax(Int), Symbol[], true)
end

@testitem "arity: positional counting" setup=[ArityWS] begin
    @test ar_first("f(x, y) = 1\n", "f") == ma(2, 2)
    @test ar_first("function f() end\n", "f") == ma(0, 0)
    # Defaults widen the max only.
    @test ar_first("f(x, y=1, z=2) = 1\n", "f") == ma(1, 3)
    # Splats and explicit Vararg declarations unbound the max.
    @test ar_first("f(x, xs...) = 1\n", "f") == ma(1, typemax(Int))
    @test ar_first("f(x, xs::Vararg{Int}) = 1\n", "f") == ma(1, typemax(Int))
    @test ar_first("f(::Vararg{Int}) = 1\n", "f") == ma(0, typemax(Int))
    # A literal-N Vararg consumes exactly N.
    @test ar_first("f(x, y::Vararg{Int,3}) = 1\n", "f") == ma(4, 4)
    @test ar_first("f(y::Base.Vararg{Int,2}) = 1\n", "f") == ma(2, 2)
    # Wheres, return types and @nospecialize don't change the count.
    @test ar_first("f(x::T, ::T) where T = 1\n", "f") == ma(2, 2)
    @test ar_first("function f(x)::Int\n    x\nend\n", "f") == ma(1, 1)
    @test ar_first("f(@nospecialize(x), y) = 1\n", "f") == ma(2, 2)
    # A callable-object definition binds no name, so only the struct's own
    # (field-less, hence positionally permissive) entry exists.
    jw = ar_workspace("struct C end\nfunction (c::C)(x, y) end\n")
    @test JW.derived_v2_method_arities(jw.runtime, AR_URI, String[], "C") ==
        [ma(0, typemax(Int))]
end

@testitem "arity: keywords" setup=[ArityWS] begin
    @test ar_first("f(x; a, b=2) = 1\n", "f") == ma(1, 1, [:a, :b])
    @test ar_first("f(x; a::Int=1) = 1\n", "f") == ma(1, 1, [:a])
    @test ar_first("f(x; kws...) = 1\n", "f") == ma(1, 1, Symbol[], true)
    # A positional default whose value is a call still counts as positional.
    @test ar_first("f(x=g(1); a=2) = 1\n", "f") == ma(0, 1, [:a])
end

@testitem "arity: macro-wrapped definitions" setup=[ArityWS] begin
    # Signature-preserving wrappers keep the written arity.
    @test ar_first("@inline f(x, y) = 1\n", "f") == ma(2, 2)
    @test ar_first("Base.@propagate_inbounds f(x) = 1\n", "f") == ma(1, 1)
    # A docstring is not a wrapper.
    @test ar_first("\"doc\"\nf(x) = 1\n", "f") == ma(1, 1)
    # Any other wrapper may rewrite the signature: permissive.
    @test ar_first("@memoize f(x) = 1\n", "f") == ANY_ARITY
    # Nested: one non-preserving layer is enough.
    @test ar_first("@memoize @inline f(x) = 1\n", "f") == ANY_ARITY
    # Definitions under `@static if` sit inside a macrocall's arguments too —
    # deliberately MORE permissive than v1's direct-parent rule (safe
    # direction: over-accepting arities only removes findings).
    @test ar_first("@static if true\n    f(x) = 1\nend\n", "f") == ANY_ARITY
end

@testitem "arity: structs" setup=[ArityWS] begin
    # Default constructor: exactly the field count; docstrings aren't fields.
    @test ar_first("struct S\n    a::Int\n    b\nend\n", "S") == ma(2, 2)
    @test ar_first("mutable struct S\n    \"doc\"\n    a::Int\nend\n", "S") == ma(1, 1)
    # Inner constructors are alternative methods: the union.
    src = """
    struct S
        a
        b
        S(x) = new(x, 1)
        function S(x, y, z)
            new(x, y)
        end
    end
    """
    @test ar_first(src, "S") == ma(1, 3)
    # Empty / field-less bodies answer any positional count (v1's rule).
    @test ar_first("struct S end\n", "S") == ma(0, typemax(Int))
    # A macro-wrapped struct likely gains constructors: permissive.
    @test ar_first("@kwdef struct S\n    a::Int = 1\nend\n", "S") == ANY_ARITY
end

@testitem "arity: zero-method declarations and non-callables" setup=[ArityWS] begin
    # `function f end`: an entry with NO arities — declared, zero methods.
    jw = ar_workspace("function f end\n")
    @test JW.derived_v2_method_arities(jw.runtime, AR_URI, String[], "f") == JW.MethodArity[]
    @test length(JW.derived_v2_method_items(jw.runtime, AR_URI, String[], "f")) == 1
    # Not declared as a callable: no key at all (callers decline).
    jw = ar_workspace("x = 1\nabstract type A end\nconst c = 2\n")
    for name in ("x", "A", "c", "nope")
        @test JW.derived_v2_method_arities(jw.runtime, AR_URI, String[], name) === nothing
    end
end

@testitem "arity: cross-file method sets and qualified extensions" setup=[ArityWS] begin
    jw = ar_workspace(
        "Root.jl" => """
        module Pkg
        include("a.jl")
        include("b.jl")
        module Sub
        g(x) = 1
        end
        Sub.g(x, y) = 2
        Base.push!(v, x, y, z, w) = 3
        end
        """,
        "a.jl" => "f(x) = 1\n",
        "b.jl" => "f(x, y) = 2\nstruct T\n    a\nend\nT(x, y) = T(x)\n",
    )
    rt = jw.runtime
    ars(path, name) = JW.derived_v2_method_arities(rt, AR_URI, path, name)

    # Methods split across included files accumulate in splice order.
    @test ars(["Pkg"], "f") == [ma(1, 1), ma(2, 2)]
    # A struct and its outer constructor both contribute.
    @test ars(["Pkg"], "T") == [ma(1, 1), ma(2, 2)]
    @test length(JW.derived_v2_method_items(rt, AR_URI, ["Pkg"], "T")) == 2
    # A qualified extension lands in the module its qualifier resolves to.
    @test ars(["Pkg", "Sub"], "g") == [ma(1, 1), ma(2, 2)]
    # A `Base.push!` extension resolves to no tree module: absent everywhere.
    @test ars(["Pkg"], "push!") === nothing
    @test ars(String[], "push!") === nothing
end

@testitem "arity: the funnel backdates on body edits" setup=[ArityWS] begin
    # An edit inside a function body leaves every arity untouched; an edit to a
    # signature changes exactly that name's entry.
    jw = ar_workspace("f(x) = 1\ng(y, z) = 2\n")
    rt = jw.runtime
    idx1 = JW.derived_v2_method_arities_index(rt, AR_URI)
    JW.update_file!(jw, TextFile(AR_URI, SourceText("f(x) = 100\ng(y, z) = 2\n", "julia")))
    @test JW.derived_v2_method_arities_index(jw.runtime, AR_URI) == idx1
    JW.update_file!(jw, TextFile(AR_URI, SourceText("f(x, w) = 100\ng(y, z) = 2\n", "julia")))
    idx3 = JW.derived_v2_method_arities_index(jw.runtime, AR_URI)
    @test idx3[(String[], "f")] == [ma(2, 2)]
    @test idx3[(String[], "g")] == idx1[(String[], "g")]
end
