using StaticLint, SymbolServer
using CSTParser, Test
using StaticLint: scopeof, bindingof, refof, errorof, check_all, getenv



@testmodule shared_static_lint begin
    using JuliaWorkspaces
    const CSTParser = JuliaWorkspaces.CSTParser
    const StaticLint = JuliaWorkspaces.StaticLint

    export parse_and_pass, check_resolved, get_hints, get_env, collect_hints
    export module_name, find_module_by_name, find_first

    const TEST_URI = JuliaWorkspaces.URIs2.uri"file://test.jl"

    # New-structure equivalent of the old `StaticLint.collect_hints(cst, server)`:
    # returns the diagnostics produced for the single test file.
    get_hints(jw) = get_diagnostic(jw, TEST_URI)

    # New-structure equivalent of the old `getenv(server.files[""], server)` /
    # `server.external_env`: the resolved `StaticLint.ExternalEnv` for the test file.
    function get_env(jw)
        rt = jw.runtime
        project_uri = JuliaWorkspaces.derived_project_uri_for_root(rt, TEST_URI)
        return project_uri === nothing ?
            JuliaWorkspaces.derived_stdlib_only_env(rt) :
            JuliaWorkspaces.derived_environment(rt, project_uri)
    end

    # Faithful equivalent of the old `StaticLint.collect_hints(x, server)`:
    # collects hints/errors from a (sub)tree of the test file.
    function collect_hints(x, meta_dict, jw; missingrefs=:all)
        rt = jw.runtime
        res = JuliaWorkspaces.derived_static_lint_meta_for_root(rt, TEST_URI)
        return StaticLint.collect_hints(x, get_env(jw), res.workspace_packages, meta_dict, missingrefs)
    end

    function parse_and_pass(s; dynamic::DynamicMode=DynamicOff)
        our_uri = TEST_URI
        jw = JuliaWorkspaces.JuliaWorkspace(;dynamic=dynamic)
        add_file!(jw, TextFile(our_uri, SourceText(s, "julia")))

        if dynamic==DynamicIndexingOnly
            JuliaWorkspaces.wait_until_ready(jw)
        end

        cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, our_uri)
        meta_dict, workspace_packages = JuliaWorkspaces.derived_static_lint_meta_for_root(jw.runtime, our_uri)
        
        return cst, meta_dict, jw
    end

    function get_ids(x, ids=[])
        if JuliaWorkspaces.StaticLint.headof(x) === :IDENTIFIER
            push!(ids, x)
        elseif x.args !== nothing
            for a in x.args
                get_ids(a, ids)
            end
        end
        ids
    end

    function check_resolved(s)
        cst, meta_dict = parse_and_pass(s)
        IDs = get_ids(cst)
        [(JuliaWorkspaces.StaticLint.refof(i, meta_dict) !== nothing) for i in IDs]
    end

    # Simple iterative DFS utilities (no recursive predicate calls)
    function module_name(ex::CSTParser.EXPR)::Union{String,Nothing}
        if CSTParser.defines_module(ex)
            n = CSTParser.get_name(ex)
            if CSTParser.isidentifier(n)
                return CSTParser.valof(n)
            elseif StaticLint.headof(n) === :NONSTDIDENTIFIER && length(n.args) == 2
                return CSTParser.valof(n.args[2])
            end
        end
        return nothing
    end

    function find_module_by_name(root::CSTParser.EXPR, name::String)
        stack = CSTParser.EXPR[root]
        while !isempty(stack)
            x = pop!(stack)
            if module_name(x) == name
                return x
            end
            if x.args !== nothing
                for a in x.args
                    a isa CSTParser.EXPR && push!(stack, a)
                end
            end
        end
        return nothing
    end

    function find_first(root::CSTParser.EXPR, f::Function)
        stack = CSTParser.EXPR[root]
        while !isempty(stack)
            x = pop!(stack)
            if f(x)
                return x
            end
            if x.args !== nothing
                for a in x.args
                    a isa CSTParser.EXPR && push!(stack, a)
                end
            end
        end
        return nothing
    end

    # Adapter to support do-block call style: find_first(root) do x ... end
    find_first(f::Function, root::CSTParser.EXPR) = find_first(root, f)
end




@testitem "Basic bindings" setup=[shared_static_lint] begin

    @test check_resolved("""
x
x = 1
x
""")  == [false, true, true]

    @test check_resolved("""
x, y
x = y = 1
x, y
""")  == [false, false, true, true, true, true]

    @test check_resolved("""
x, y
x, y = 1, 1
x, y
""")  == [false, false, true, true, true, true]

    @test check_resolved("""
M
module M end
M
""")  == [false, true, true]

    @test check_resolved("""
f
f() = 0
f
""")  == [false, true, true]

    @test check_resolved("""
f
function f end
f
""")  == [false, true, true]

    @test check_resolved("""
f
function f() end
f
""")  == [false, true, true]

    @test check_resolved("""
function f(a)
end
""")  == [true, true]

    @test check_resolved("""
f, a
function f(a)
a
end
f, a
""")  == [false, false, true, true, true, true, false]


    @test check_resolved("""
x
let x = 1
x
end
x
""")  == [false, true, true, false]

    @test check_resolved("""
x,y
let x = 1, y = 1
x, y
end
x, y
""")  == [false, false, true, true, true, true, false, false]

    @test check_resolved("""
function f(a...)
f(a)
end
""")  == [true, true, true, true]

    @test check_resolved("""
for i = 1:1
end
""")  == [true]

    @test check_resolved("""
[i for i in 1:1]
""")  == [true, true]

    @test check_resolved("""
[i for i in 1:1 if i]
""")  == [true, true, true]

# @test check_resolved("""
# @deprecate f(a) sin(a)
# f
# """)  == [true, true, true, true, true, true]

    @test check_resolved("""
@deprecate f sin
f
""")  == [true, true, true, true]

    @test check_resolved("""
module Mod
f = 1
end
using .Mod: f
f
""") == [true, true, true, true, true]

    @test check_resolved("""
module Mod
module SubMod
f() = 1
end
using .SubMod: f
f
end
""") == [true, true, true, true, true, true]

    @test check_resolved("""
struct T
field
end
function f(arg::T)
arg.field
end
""") == [true, true, true, true, true, true, true]

    if VERSION > v"1.8-"
        @test check_resolved("""
        mutable struct T
            const field
        end
        function f(arg::T)
            arg.field
        end
        """) == [true, true, true, true, true, true, true]
    end

    @test check_resolved("""
f(arg) = arg
""") == [1, 1, 1]

    @test check_resolved("-(r::T) where T = r") == [1, 1, 1, 1]
    @test check_resolved("[k * j for j = 1:10 for k = 1:10]") == [1, 1, 1, 1]
    @test check_resolved("[k * j for j in 1:10 for k in 1:10]") == [1, 1, 1, 1]

end



@testitem "macros" setup=[shared_static_lint] begin
    @test check_resolved("""
        @enum(E,a,b)
        E
        a
        b
        """)  == [true, true, true, true, true, true, true]

    @test check_resolved("""
        @enum E a b
        E
        a
        b
        """)  == [true, true, true, true, true, true, true]

    @test check_resolved("""
        @enum E begin
        a
        b
        end
        E
        a
        b
        """)  == [true, true, true, true, true, true, true]
end

@testitem "tuple args destructuring" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2))
        arg1, arg2
    end""")
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
end

@testitem "tuple args with default" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2) = (1,2))
        arg1, arg2
    end""")
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
end

@testitem "tuple args with type annotation" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2)::Tuple{Int,Int})
        arg1, arg2
    end""")
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
    @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
end

@testitem "unused type params check" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    f() where T
    f() where {T,S}
    f() where {T<:Any}
    """)
    
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[2], meta_dict) == JuliaWorkspaces.StaticLint.UnusedTypeParameter
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[2], meta_dict) == JuliaWorkspaces.StaticLint.UnusedTypeParameter
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[3], meta_dict) == JuliaWorkspaces.StaticLint.UnusedTypeParameter
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[3].args[2], meta_dict) == JuliaWorkspaces.StaticLint.UnusedTypeParameter
end

@testitem "type params check" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    f(x::T) where T
    f(x::T,y::S) where {T,S}
    f(x::T) where {T<:Any}
    """)
        @test !JuliaWorkspaces.StaticLint.haserror(cst.args[1].args[2], meta_dict)
        @test !JuliaWorkspaces.StaticLint.haserror(cst.args[2].args[2], meta_dict)
        @test !JuliaWorkspaces.StaticLint.haserror(cst.args[2].args[3], meta_dict)
        @test !JuliaWorkspaces.StaticLint.haserror(cst.args[3].args[2], meta_dict)
    end
end


@testitem "overwrites_imported_function" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof

    let (cst, meta_dict) = parse_and_pass("""
    import Base:sin
    using Base:cos
    sin(x) = 1
    cos(x) = 1
    Base.tan(x) = 1
    """)
        @test JuliaWorkspaces.StaticLint.overwrites_imported_function(refof(cst[3][1][1], meta_dict))
        @test !JuliaWorkspaces.StaticLint.overwrites_imported_function(refof(cst[4][1][1], meta_dict))
        @test JuliaWorkspaces.StaticLint.overwrites_imported_function(refof(cst[5][1][1][3][1], meta_dict))
    end
end

@testitem "pirates basic type piracy" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    (cst, meta_dict) = parse_and_pass("""
    import Base:sin
    struct T end
    sin(x::Int) = 1
    sin(x::T) = 1
    sin(x::Array{T}) = 1
    """)
    JuliaWorkspaces.StaticLint.check_for_pirates(cst.args[3], meta_dict)
    JuliaWorkspaces.StaticLint.check_for_pirates(cst.args[4], meta_dict)
    @test errorof(cst.args[3], meta_dict) === JuliaWorkspaces.StaticLint.TypePiracy
    @test errorof(cst.args[4], meta_dict) === nothing
end

@testitem "pirates parametric eltype no piracy" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    (cst, meta_dict) = parse_and_pass("""
    struct AreaIterator{T}
        array::AbstractMatrix{T}
        radius::Int
    end
    Base.eltype(::Type{AreaIterator{T}}) where T = Tuple{T, AbstractVector{T}}
    """)
    JuliaWorkspaces.StaticLint.check_for_pirates(cst[2], meta_dict)
    @test errorof(cst[2], meta_dict) === nothing
end

@testitem "pirates array element type piracy" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    (cst, meta_dict) = parse_and_pass("""
    import Base:sin
    abstract type T end
    sin(x::Array{T}) = 1
    sin(x::Array{<:T}) = 1
    sin(x::Array{Number}) = 1
    sin(x::Array{<:Number}) = 1
    """)
    @test errorof(cst[3], meta_dict) === nothing
    @test errorof(cst[4], meta_dict) === nothing
    @test errorof(cst[5], meta_dict) === JuliaWorkspaces.StaticLint.TypePiracy
    @test errorof(cst[6], meta_dict) === JuliaWorkspaces.StaticLint.TypePiracy
end

@testitem "pirates where clause no piracy" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    (cst, meta_dict) = parse_and_pass("""
    abstract type At end
    struct Ty end
    Base.eltype(::Type{Ty{T}} where {T}) = 1
    Base.length(s::Ty{T} where T <: At) = 1
    """)
    @test JuliaWorkspaces.StaticLint.check_for_pirates(cst[3], meta_dict) === nothing
    @test JuliaWorkspaces.StaticLint.check_for_pirates(cst[4], meta_dict) === nothing
end

@testitem "pirates not-equal definition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    (cst, meta_dict) = parse_and_pass("""
    !=(a,b) = true
    Base.:!=(a,b) = true
    !=(a::T,b::T) = true
    !=(a::T,b::T) where T= true
    """)
    @test errorof(cst[1], meta_dict) === JuliaWorkspaces.StaticLint.NotEqDef
    @test errorof(cst[2], meta_dict) === JuliaWorkspaces.StaticLint.NotEqDef
    @test errorof(cst[3], meta_dict) === JuliaWorkspaces.StaticLint.NotEqDef
    @test errorof(cst[4], meta_dict) === JuliaWorkspaces.StaticLint.NotEqDef
end

@testitem "pirates with nested where clauses (#436)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, TypePiracy

    # Piracy detection must strip all (nested) `where` clauses to find the name.
    (cst, meta_dict) = parse_and_pass("""
    import Base:sin
    sin(x::Array{Number}) where {S} = 1
    sin(x::Array{Number}) where {S} where {R} = 1
    sin(x::Array{Number}) where {S} where {R} where {Q} = 1
    """)
    @test errorof(cst[2], meta_dict) === TypePiracy
    @test errorof(cst[3], meta_dict) === TypePiracy
    @test errorof(cst[4], meta_dict) === TypePiracy
end

@testitem "check_call incorrect call args" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    sin(1)
    sin(1,2)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[1], meta_dict) === nothing
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) == JuliaWorkspaces.StaticLint.IncorrectCallArgs
end

@testitem "_super resolves declared supertype (#446)" setup=[shared_static_lint] begin
    CSTParser = JuliaWorkspaces.CSTParser

    function sup(src)
        cst, meta_dict, jw = parse_and_pass(src)
        env = get_env(jw)
        JuliaWorkspaces.StaticLint._super(cst.args[1], env.symbols, meta_dict)
    end

    # primitive-type supertype must resolve (the `:primitive` head was a typo).
    @test CSTParser.valof(sup("primitive type MyInt <: Integer 8 end")) == "Integer"
    @test CSTParser.valof(sup("abstract type MyAbs <: Real end")) == "Real"
    @test CSTParser.valof(sup("struct MyS <: Number end")) == "Number"
end

@testitem "check_call function with no methods (#445)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, FunctionHasNoMethods, IncorrectCallArgs

    # A bare forward declaration `function f end` defines no methods, so any
    # call to it can only MethodError.
    for src in ["function f end\nf(1)", "function f end\nf()", "function f end\nf(1, 2, 3)"]
        cst, meta_dict = parse_and_pass(src)
        @test errorof(cst.args[2], meta_dict) === FunctionHasNoMethods
    end

    # Once a real method exists, normal arg-count checking applies.
    let (cst, meta_dict) = parse_and_pass("function f end\nf(x) = x\nf(1)")
        @test errorof(cst.args[3], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("function f end\nf(x) = x\nf(1, 2, 3)")
        @test errorof(cst.args[3], meta_dict) === IncorrectCallArgs
    end
end

@testitem "check_call method definition" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    Base.sin(a,b) = 1
    function Base.sin(a,b)
        1
    end
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[1], meta_dict) === nothing
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[1], meta_dict) === nothing
end

@testitem "check_call too many positional args" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    f(x) = 1
    f(1, 2)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectCallArgs
end

@testitem "check_call builtin varargs" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    view([1], 1, 2, 3)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[1], meta_dict) === nothing
end

@testitem "check_call vararg definition" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    f(a...) = 1
    f(1)
    f(1, 2)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === nothing
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[3], meta_dict) === nothing
end

@testitem "check_call splat in recursive call" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function func(a, b)
        func(a...)
    end
    """)
    m_counts = JuliaWorkspaces.StaticLint.func_nargs(cst.args[1])
    call_counts = JuliaWorkspaces.StaticLint.call_nargs(cst.args[1].args[2].args[1])
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[2].args[1], meta_dict) === nothing
end

@testitem "check_call nospecialize varargs" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function func(@nospecialize args...) end
    func(1, 2)
    """)
    @test JuliaWorkspaces.StaticLint.func_nargs(cst.args[1]) == (0, typemax(Int), String[], false)
    @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === nothing
end

@testitem "check_call splat from tuple type" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    argtail(x, rest...) = 1
    tail(x::Tuple) = argtail(x...)
    """)
    @test JuliaWorkspaces.StaticLint.func_nargs(cst[1]) == (1, typemax(Int), String[], false)
    @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
end

@testitem "check_call Vararg with where" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    func(arg::Vararg{T,N}) where N = arg
    func(a,b)
    """)

    @test JuliaWorkspaces.StaticLint.func_nargs(cst[1]) == (0, typemax(Int), String[], false)
    @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
end

@testitem "check_call keyword default reference" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    function f(a, b; kw = kw) end
    f(1,2, kw = 1)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
end

@testitem "check_call splat with trailing positional" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    func(a,b,c,d) = 1
    func(a..., 2)
    """)
    JuliaWorkspaces.StaticLint.call_nargs(cst[2])
    @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
end

@testitem "check_call kwdef constructor" setup=[shared_static_lint] begin
    (cst, meta_dict) = parse_and_pass("""
    @kwdef struct A
        x::Float64
    end
    A(x = 5.0)
    """)
    @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
end

@testitem "check_call kwdef const fields" setup=[shared_static_lint] begin
    if VERSION >= v"1.10"
        let (cst, meta_dict) = parse_and_pass("""
            @kwdef mutable struct A
                const x::Float64
            end
            A(x = 5.0)
            """)
            @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
        end
        let (cst, meta_dict) = parse_and_pass("""
            @kwdef mutable struct A
                const x::Float64 = 1.0
            end
            A(x = 5.0)
            """)
            @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
        end
    end
end

@testitem "check_call documented symbol skipped" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: @uri_str

    cst, meta_dict, jw = parse_and_pass("""
        import Base: sin
        \"\"\"
        docs
        \"\"\"
        sin
        sin(a,b) = 1
        sin(1)
        """)

    # Checks that documented symbols are skipped
    @test isempty(get_diagnostic(jw, uri"file://test.jl"))
end

@testitem "check_call imported function overload" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: @uri_str

    cst, meta_dict, jw = parse_and_pass("""
        import Base: sin
        sin(a,b) = 1
        sin(1)
        """)

    # Checks that documented symbols are skipped
    @test isempty(get_diagnostic(jw, uri"file://test.jl"))
end

@testitem "check_call strip type declaration from signature" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: @uri_str

    cst, meta_dict, jw = parse_and_pass("""
        function f(a::F)::Bool where {F} a end
        """)

    # ensure we strip all type decl code from around signature
    @test isempty(get_diagnostic(jw, uri"file://test.jl"))
end

@testitem "check_call strip nested where clauses (#436)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, IncorrectCallArgs

    # A default positional arg makes the definition's signature read like a call
    # with a keyword arg, so the self-signature match falls back to comparing
    # against the stripped signature — which must strip *all* `where` clauses,
    # regardless of nesting depth.
    (cst, meta_dict) = parse_and_pass("""
        f1(c::TT=[1,1]) where {TT<:AbstractVector{T}} where {T} = (c,TT,T)
        f2(c::TT=[1,1]) where {TT<:AbstractVector} = (c,TT)
        f3(c::TT) where {TT<:AbstractVector{T}} where {T} = (c,TT,T)
        f4(c::TT=[1,1]) where {TT<:AbstractArray{T,N}} where {T} where {N} = (c,TT,T,N)
        """)
    has_callargs_err(x) = errorof(x, meta_dict) === IncorrectCallArgs
    for i in 1:4
        @test find_first(cst[i], has_callargs_err) === nothing
    end
end

@testitem "check_modulename" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    module Mod1
    module Mod11
    end
    end
    module Mod2
    module Mod2
    end
    end
    """)
        JuliaWorkspaces.StaticLint.check_modulename(cst.args[1], meta_dict)
        JuliaWorkspaces.StaticLint.check_modulename(cst.args[1].args[3].args[1], meta_dict)
        JuliaWorkspaces.StaticLint.check_modulename(cst.args[2], meta_dict)
        JuliaWorkspaces.StaticLint.check_modulename(cst.args[2].args[3].args[1], meta_dict)

        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[2], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[3].args[1].args[2], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[2], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[3].args[1].args[2], meta_dict) === JuliaWorkspaces.StaticLint.InvalidModuleName
    end
end


@testitem "non-std var syntax" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasref, bindingof, getmeta

    if !(VERSION < v"1.3")
        cst, meta_dict = parse_and_pass("""
            var"name" = 1
            var"func"(arg) = arg
            function var"func1"() end
            name
            func
            func1
            struct AnyType
                var"anything"
            end
            anything(x::AnyType) = x.var"anything"
            """)

        @test all(n in keys(getmeta(cst, meta_dict).scope.names) for n in ("name", "func"))
        @test hasref(cst[4], meta_dict)
        @test hasref(cst[5], meta_dict)
        @test hasref(cst[6], meta_dict)
        @test cst.args[8].args[2].args[1].args[2].args[1] in bindingof(cst.args[7].args[3].args[1], meta_dict).refs
    end
end

@testitem "JuMP @variable parenthesized" setup=[shared_static_lint] begin
        (cst, meta_dict, jw) = parse_and_pass("""
using JuMP
model = Model()
some_bound = 1
@variable(model, x0)
@variable(model, x1, somekw=1)
@variable(model, x2 <= 1)
@variable(model, x3 >= 1)
@variable(model, 1 <= x4)
@variable(model, 1 >= x5)
@variable(model, x6 >= some_bound)
# @variable(model, some_bound >= x7)
""")
        @test isempty(get_hints(jw))
end

@testitem "JuMP @variable space-separated" setup=[shared_static_lint] begin
        (cst, meta_dict, jw) = parse_and_pass("""
using JuMP
model = Model()
some_bound = 1
@variable model x0
@variable model x1 somekw=1
@variable model x2 <= 1
@variable model x3 >= 1
@variable model 1 <= x4
@variable model 1 >= x5
@variable model x6 >= some_bound
# @variable(model, some_bound >= x7)
""")
        @test isempty(get_hints(jw))
end

@testitem "JuMP @variable unresolved bound" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: hasref

    cst, meta_dict = parse_and_pass("""
        using JuMP
        model = Model()
        some_bound = 1
        @variable(model, some_bound >= x7)
        """)

    x7 = find_first(cst) do x
        CSTParser.isidentifier(x) && CSTParser.valof(x) == "x7"
    end
    @test x7 !== nothing
    @test !hasref(x7, meta_dict)
end

@testitem "JuMP @expression" setup=[shared_static_lint] begin
        (cst, meta_dict, jw) = parse_and_pass("""
using JuMP
model = Model()
some_bound = 1
@expression(model, ex, some_bound >= 1)
""")
        @test isempty(get_hints(jw))
end

@testitem "JuMP @constraint" setup=[shared_static_lint] begin
        (cst, meta_dict, jw) = parse_and_pass("""
using JuMP
model = Model()
@expression(model, expr, 1 == 1)
@constraint(model, con1, expr)
@constraint model con2 expr
""")
        @test isempty(get_hints(jw))
end

@testitem "stdcall in ccall" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("""
    ccall(:GetCurrentProcess, stdcall, Ptr{Cvoid}, ())""")
    @test isempty(get_hints(jw))
end

@testitem "stdcall as identifier" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasref
    cst, meta_dict = parse_and_pass("""
        stdcall
        """)
    
    @test !hasref(cst[1], meta_dict)
end

@testitem "check_if_conds constant condition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, ConstIfCondition

    cst, meta_dict = parse_and_pass("""
        if true end
        """)

    @test getmeta(cst.args[1].args[1], meta_dict).error == ConstIfCondition
end

@testitem "check_if_conds assignment in condition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, EqInIfConditional

    cst, meta_dict = parse_and_pass("""
        if x = 1 end
        """)

    @test getmeta(cst.args[1].args[1], meta_dict).error == EqInIfConditional
end

@testitem "check_if_conds assignment in or-condition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, EqInIfConditional

    cst, meta_dict = parse_and_pass("""
        if a || x = 1 end
        """)

    @test getmeta(cst.args[1].args[1], meta_dict).error == EqInIfConditional
end

@testitem "check_if_conds assignment in and-condition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, EqInIfConditional

    cst, meta_dict = parse_and_pass("""
        if x = 1 && b end
        """)

    @test getmeta(cst.args[1].args[1], meta_dict).error == EqInIfConditional
end


@testitem "check_farg_unused unused second argument" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, UnusedFunctionArgument

    cst, meta_dict = parse_and_pass("function f(arg1, arg2) arg1 end")

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
    @test errorof(CSTParser.get_sig(cst[1])[5], meta_dict) === UnusedFunctionArgument
end

@testitem "check_farg_unused unused typed second argument" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, UnusedFunctionArgument

    cst, meta_dict = parse_and_pass("function f(arg1::T, arg2::T) arg1 end")

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
    @test errorof(CSTParser.get_sig(cst[1])[5], meta_dict) === UnusedFunctionArgument
end

@testitem "check_farg_unused multiple unused arguments" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, UnusedFunctionArgument

    cst, meta_dict = parse_and_pass("function f(arg1, arg2::T, arg3 = 1, arg4::T = 1) end")

    @test errorof(CSTParser.get_sig(cst.args[1]).args[2], meta_dict) === UnusedFunctionArgument
    @test errorof(CSTParser.get_sig(cst.args[1]).args[3], meta_dict) === UnusedFunctionArgument
    @test errorof(CSTParser.get_sig(cst.args[1]).args[4].args[1], meta_dict) === UnusedFunctionArgument
    @test errorof(CSTParser.get_sig(cst.args[1]).args[5].args[1], meta_dict) === UnusedFunctionArgument
end

@testitem "check_farg_unused skipped argument (#330)" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, UnusedFunctionArgument

    # An underscore (or otherwise skipped) argument must not stop subsequent
    # arguments from being checked.
    let (cst, meta_dict) = parse_and_pass("function f(_, y)\n    return\nend")
        @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
        @test errorof(CSTParser.get_sig(cst[1])[5], meta_dict) === UnusedFunctionArgument
    end
    let (cst, meta_dict) = parse_and_pass("function f(x, _, z)\n    return\nend")
        @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === UnusedFunctionArgument
        @test errorof(CSTParser.get_sig(cst[1])[5], meta_dict) === nothing
        @test errorof(CSTParser.get_sig(cst[1])[7], meta_dict) === UnusedFunctionArgument
    end
end

@testitem "check_farg_unused reassigned argument" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, UnusedFunctionArgument

    cst, meta_dict = parse_and_pass("function f(arg) arg = 1 end")
    
    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === UnusedFunctionArgument
end

@testitem "check_farg_unused argument used before reassignment" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass(
            """function f(arg)
                x = arg
                arg = x
            end""")

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
end

@testitem "check_farg_unused literal body" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("function f(arg) 1 end")

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
end

@testitem "check_farg_unused short form definition" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("f(arg) = true")

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
end

@testitem "check_farg_unused nospecialize argument" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("func(@nospecialize(arg)) = arg")

    @test errorof(cst[1].args[1].args[2], meta_dict) === nothing
end

@testitem "check_farg_unused broadcast macro body" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""
        function f(x,y,z)
            @. begin
                x = z
                y = z
            end
        end
        """)

    @test errorof(CSTParser.get_sig(cst[1])[3], meta_dict) === nothing
    @test errorof(CSTParser.get_sig(cst[1])[5], meta_dict) === nothing
end

@testitem "const redefinition cannot declare const" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, CannotDeclareConst

    cst, meta_dict = parse_and_pass("""
        T = 1
        struct T end
        """)

    @test getmeta(cst[2], meta_dict).error == CannotDeclareConst
end

@testitem "const redefinition invalid redefinition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, InvalidRedefofConst

    (cst, meta_dict) = parse_and_pass("""
    struct T end
    T = 1
    """)
    @test getmeta(cst[2], meta_dict).error == InvalidRedefofConst
end

@testitem "const redefinition allows method definition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta

    cst, meta_dict = parse_and_pass("""
        struct T end
        T() = 1
        """)

    @test getmeta(cst[2], meta_dict).error === nothing
end

@testitem "importing a type is not a const redefinition (#352)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, InvalidRedefofConst

    has_error(cst, meta_dict, jw, err) =
        any(errorof(x, meta_dict) === err for (_, x) in collect_hints(cst, meta_dict, jw))

    let (cst, meta_dict, jw) = parse_and_pass("import Base: AbstractDict")
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        import Base: AbstractDict
        import Base: AbstractDict
        """)
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        using Base
        using Base: AbstractDict
        """)
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        import Base
        import Base: AbstractDict
        """)
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        using Base
        import Base: AbstractDict
        """)
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        import Base: AbstractDict
        const AbstractDict = 1
        """)
        @test has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end
end

@testitem "hoisting of inner constructors" setup=[shared_static_lint] begin
    let (cst, meta_dict, jw) = parse_and_pass("""
    struct ASDF
        x::Int
        y::Int
        ASDF(x::Int) = new(x, 1)
    end
    ASDF(1)
    """)
        # Check inner constructor is hoisted
        @test isempty(get_hints(jw))
    end
end

@testitem "using statements imported submodule self" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    using JuliaWorkspaces.StaticLint: hasref

    cst, meta_dict = parse_and_pass("using Base.Filesystem: Filesystem")

    @test hasref(cst.args[1].args[1].args[2].args[1], meta_dict)
end

@testitem "using statements single binding" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasbinding

    cst, meta_dict = parse_and_pass("using Base: Ordering")
    @test hasbinding(cst.args[1].args[1].args[2].args[1], meta_dict)
end

@testitem "using statements relative submodule" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasbinding

    cst, meta_dict = parse_and_pass("""
        module Outer
        module Inner
        x = 1
        export x
        end
        using .Inner
        end
        using .Outer: x, rand
        """)

    @test hasbinding(cst.args[2].args[1].args[2].args[1], meta_dict)
    @test hasbinding(cst.args[2].args[1].args[3].args[1], meta_dict)
end

@testitem "custom getproperty defines method" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    using JuliaWorkspaces.StaticLint: has_getproperty_method, bindingof, refof

    cst, meta_dict = parse_and_pass("""
        struct T end
        Base.getproperty(x::T, s) = 1
        T
        """)

    @test has_getproperty_method(bindingof(cst.args[1], meta_dict))
    @test has_getproperty_method(refof(cst.args[3], meta_dict))
end

@testitem "custom getproperty suppresses unknown field" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("""
    struct T
        f1
        f2
    end
    Base.getproperty(x::T, s) = (x,s)
    f(x::T) = x.f3
    """)
    @test !JuliaWorkspaces.StaticLint.hasref(cst.args[3].args[2].args[1].args[2].args[1], meta_dict)
    @test isempty(get_hints(jw))
end

@testitem "custom getproperty on parametric type" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("""
    struct T{S}
        f1
        f2
    end
    Base.getproperty(x::T{Int}, s) = (x,s)
    f(x::T) = x.f3
    """)
    @test !JuliaWorkspaces.StaticLint.hasref(cst.args[3].args[2].args[1].args[2].args[1], meta_dict)
    @test JuliaWorkspaces.StaticLint.is_type_of_call_to_getproperty(cst.args[2].args[1].args[2].args[2].args[1])
    @test isempty(get_hints(jw))
end

@testitem "custom getproperty Module builtin" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("f(x::Module) = x.parent1")
    env = get_env(jw)
    @test JuliaWorkspaces.StaticLint.has_getproperty_method(env.symbols[:Core][:Module], env)
    @test !JuliaWorkspaces.StaticLint.has_getproperty_method(env.symbols[:Core][:DataType], env)
    @test isempty(collect_hints(cst, meta_dict, jw))
end

@testitem "custom getproperty DataType reports unknown field" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("f(x::DataType) = x.sdf")
    @test !isempty(collect_hints(cst, meta_dict, jw))
end

@testitem "using of self" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    using JuliaWorkspaces.StaticLint: errorof, InvalidTypeDeclaration

    cst, meta_dict = parse_and_pass("""
        function f(a::rand) a end
        function f(a::Base.rand) a end
        function f(a::Int) a end
        Base.Int32(x) = 1
        function f(a::Int32) a end
        Base.fetch(x) = 1
        function f(a::fetch) a end
        """)
            
    @test errorof(cst.args[1].args[1].args[2], meta_dict) === InvalidTypeDeclaration
    @test errorof(cst.args[2].args[1].args[2], meta_dict) === InvalidTypeDeclaration
    @test errorof(cst.args[3].args[1].args[2], meta_dict) === nothing
    @test errorof(cst.args[5].args[1].args[2], meta_dict) === nothing
    @test errorof(cst.args[7].args[1].args[2], meta_dict) === InvalidTypeDeclaration
end

@testitem "interpret @eval" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, scopehasbinding, errorof, IncorrectCallArgs

        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval adf = 1
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test !scopehasbinding(scopeof(cst[1], meta_dict), "adf")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval a,d,f = 1,2,3
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "a")
            @test scopehasbinding(scopeof(cst, meta_dict), "d")
            @test scopehasbinding(scopeof(cst, meta_dict), "f")
            @test !scopehasbinding(scopeof(cst[1], meta_dict), "a")
            @test !scopehasbinding(scopeof(cst[1], meta_dict), "d")
            @test !scopehasbinding(scopeof(cst[1], meta_dict), "f")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval a = 1
        @eval d = 2
        @eval f = 3
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "a")
            @test scopehasbinding(scopeof(cst, meta_dict), "d")
            @test scopehasbinding(scopeof(cst, meta_dict), "f")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "a")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "d")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "f")
        end

        let (cst, meta_dict) = parse_and_pass("""
    let name = :adf
        @eval \$name = 1
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "adf")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let name = [:adf]
        @eval \$name = 1
    end
    """)
            @test !scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "adf")
        end

        let (cst, meta_dict) = parse_and_pass("""
    for name = [:adf, :asdf, :asdfs]
        @eval \$name = 1
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test scopehasbinding(scopeof(cst, meta_dict), "asdf")
            @test scopehasbinding(scopeof(cst, meta_dict), "asdfs")
        end
        let (cst, meta_dict) = parse_and_pass("""
    for name = (:adf, :asdf, :asdfs)
        @eval \$name = 1
    end
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test scopehasbinding(scopeof(cst, meta_dict), "asdf")
            @test scopehasbinding(scopeof(cst, meta_dict), "asdfs")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let name = :adf
        @eval \$name(x) = 1
    end
    adf(1,2)
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "adf")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "adf")
            @test errorof(cst.args[2], meta_dict) === IncorrectCallArgs
        end
        let (cst, meta_dict) = parse_and_pass("""
    for name in (:sdf, :asdf)
        @eval \$name(x) = 1
    end
    sdf(1,2)
    """)
            @test scopehasbinding(scopeof(cst, meta_dict), "sdf")
            @test !scopehasbinding(scopeof(cst.args[1], meta_dict), "asdf")
            @test errorof(cst[2], meta_dict) === IncorrectCallArgs
        end
end

@testitem "check for " setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    using JuliaWorkspaces.StaticLint: bindingof, refof

    cst, meta_dict = parse_and_pass("""
        module A
        module B
        struct T end
        end
        using .B
        function T(t::B.T)
        end
        end
        """)

    @test bindingof(cst.args[1].args[3].args[3], meta_dict) != refof(cst.args[1].args[3].args[3].args[1].args[2].args[2].args[2].args[1], meta_dict)
    @test bindingof(cst.args[1].args[3].args[1].args[3].args[1], meta_dict) == refof(cst.args[1].args[3].args[3][2][3][3][3][1], meta_dict)
end

@testitem "misc Bool import and overload" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    (cst, meta_dict, jw) = parse_and_pass("""
    import Base: Bool
    function Bool(x) x end
    ^(z::Complex, n::Bool) = n ? z : one(z)
    """)
    @test isempty(get_hints(jw))
end

@testitem "misc parametric return type signature" setup=[shared_static_lint] begin
    (cst, meta_dict, jw) = parse_and_pass("""
    (rand(d::Vector{T})::T) where {T}  =  1
    """)
    @test isempty(get_hints(jw))
end

@testitem "Test self" setup=[shared_static_lint] begin
    # Smoke test: load every file in the JuliaWorkspaces `src` folder into a
    # workspace and request diagnostics for all of them. We don't assert on the
    # contents here, the point is simply to make sure the full pipeline runs to
    # completion without crashing on a realistic, sizeable codebase.
    src_folder = normpath(joinpath(@__DIR__, "..", "..", "src"))

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_folder_from_disc!(jw, src_folder)

    for uri in get_text_files(jw)
        @test get_diagnostic(jw, uri) !== nothing
    end
end

@testitem "Test @irrational" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    using Base:@irrational
    @irrational ase 0.45343 π
    ase
    """)

    @test isempty(get_hints(jw))
end

@testitem "quoted getfield" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: errorof, getmeta, bindingof, get_method

    let (cst, meta_dict, jw) = parse_and_pass("Base.:sin")
        @test isempty(collect_hints(cst[1], meta_dict, jw))
    end
    @testset "quoted getfield" begin
        let (cst, meta_dict, jw) = parse_and_pass("Base.:sin")
            @test isempty(collect_hints(cst.args[1], meta_dict, jw))
        end

        let (cst, meta_dict, jw) = parse_and_pass("""
    sin(1,1)
    Base.sin(1,1)
    Base.:sin(1,1)
    """)
            @test errorof(cst.args[1], meta_dict) === errorof(cst.args[2], meta_dict) === errorof(cst.args[3], meta_dict)
        end
    end
    @testset "overloading" begin
# overloading of a function that happens to be exported into the current scope.
        let (cst, meta_dict, jw) = parse_and_pass("""
    Base.sin() = nothing
    sin()
    """)
            @test haskey(getmeta(cst, meta_dict).scope.names, "sin") #
            @test first(getmeta(cst, meta_dict).scope.names["sin"].refs) == get_env(jw).symbols[:Base][:sin]
            @test isempty(collect_hints(cst[2], meta_dict, jw))
        end
# As above but for user defined function
        let (cst, meta_dict, jw) = parse_and_pass("""
    module M
    f(x) = nothing
    end
    M.f(a,b) = nothing
    M.f(1,2)
    """)
            @test !haskey(getmeta(cst, meta_dict).scope.names, "f")
            @test errorof(cst.args[3], meta_dict) === nothing
        end

        let (cst, meta_dict, jw) = parse_and_pass("""
sin(1,1)
Base.sin(1,1)
Base.:sin(1,1)
""")
            @test errorof(cst[1], meta_dict) === errorof(cst[2], meta_dict) === errorof(cst[3], meta_dict)
        end
    end
# Non exported function is overloaded
    let (cst, meta_dict, jw) = parse_and_pass("""
    Base.argtail() = nothing
    Base.argtail()
    """)
        @test !haskey(getmeta(cst, meta_dict).scope.names, "argtail") #
        @test isempty(collect_hints(cst, meta_dict, jw))
    end
# As above but for user defined function
    let (cst, meta_dict, jw) = parse_and_pass("""
    module M
    ff(x) = nothing
    end
    M.ff() = nothing
    M.ff()
    """)
        @test !haskey(getmeta(cst, meta_dict).scope.names, "ff")
        @test isempty(collect_hints(cst[3], meta_dict, jw))
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
    import Base: argtail
    Base.argtail() = nothing
    Base.argtail()
    argtail()
    """)
        @test getmeta(cst, meta_dict).scope.names["argtail"] === bindingof(cst[1][2][3][1], meta_dict)
        @test get_method(getmeta(cst, meta_dict).scope.names["argtail"].refs[2]) isa CSTParser.EXPR
        @test getmeta(cst[3][1][3][1], meta_dict).ref == getmeta(cst, meta_dict).scope.names["argtail"]
        @test isempty(collect_hints(cst, meta_dict, jw))
    end
end

@testitem "on demand resolving of export statements" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof

    cst, meta_dict = parse_and_pass("""
        module TopModule
        abstract type T end
        export T
        module SubModule
        using ..TopModule
        T
        end
        end""")

    @test refof(cst.args[1].args[3].args[3].args[3].args[2], meta_dict) !== nothing
end


@testitem "check kw default definition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    function kw_default_ok(s)
        cst, meta_dict = parse_and_pass(s)
        @test errorof(cst.args[1].args[2].args[2], meta_dict) === nothing
    end

    function kw_default_notok(s)
        cst, meta_dict = parse_and_pass(s)
        @test errorof(cst.args[1].args[2].args[2], meta_dict) == JuliaWorkspaces.StaticLint.KwDefaultMismatch
    end

    kw_default_ok("f(x::Float64 = 0.1)")
    kw_default_ok("f(x::Float64 = f())")
    kw_default_ok("f(x::Float32 = f())")
    kw_default_ok("f(x::Float32 = 3f0")
    kw_default_ok("f(x::Float32 = 3_0f0")
    kw_default_ok("f(x::Float32 = 0f00")
    kw_default_ok("f(x::Float32 = -0f02")
    kw_default_ok("f(x::Float32 = Inf32")
    kw_default_ok("f(x::Float32 = 30f3")
    kw_default_ok("f(x::String = \"1\")")
    kw_default_ok("f(x::String = f())")
    kw_default_ok("f(x::Symbol = :x")
    kw_default_ok("f(x::Symbol = f()")
    kw_default_ok("f(x::Char = 'a'")
    kw_default_ok("f(x::Bool = true")
    kw_default_ok("f(x::Bool = false")
    kw_default_ok("f(x::UInt8 = 0b0100_0010")
    kw_default_ok("f(x::UInt16 = 0b0000_0000_0000")
    kw_default_ok("f(x::UInt32 = 0b00000000000000000000000000000000")
    kw_default_ok("f(x::UInt8 = 0o000")
    kw_default_ok("f(x::UInt16 = 0o0_0_0_0_0_0")
    kw_default_ok("f(x::UInt32 = 0o000000000")
    kw_default_ok("f(x::UInt64 = 0o000_000_000_000_0")
    kw_default_ok("f(x::UInt8 = 0x0")
    kw_default_ok("f(x::UInt16 = 0x0000")
    kw_default_ok("f(x::UInt32 = 0x00000")
    kw_default_ok("f(x::UInt32 = -0x00000")
    kw_default_ok("f(x::UInt64 = 0x0000_0000_0")
    kw_default_ok("f(x::UInt128 = 0x00000000_00000000_00000000_00000000")
    kw_default_ok("f(x::UInt128 = 0x00000000_00000000_00000000_00000000")
    if Sys.WORD_SIZE == 64
        kw_default_ok("f(x::Int64 = 0")
        kw_default_ok("f(x::UInt = 0x0000_0000_0")
    else
        kw_default_ok("f(x::Int32 = 0")
        kw_default_ok("f(x::UInt = 0x0000_0")
    end
    kw_default_ok("f(x::Int = 1)")
    kw_default_ok("f(x::Int = f())")
    kw_default_ok("f(x::Int8 = Int8(0)")
    kw_default_ok("f(x::Int8 = convert(Int8,0)")

    if Sys.WORD_SIZE == 64
        kw_default_notok("f(x::Int8 = 0")
        kw_default_notok("f(x::Int16 = 0")
        kw_default_notok("f(x::Int32 = 0")
        kw_default_notok("f(x::Int64 = 0x0000_0000_0")
        kw_default_notok("f(x::Int128 = 0")
    else
        kw_default_notok("f(x::Int8 = 0")
        kw_default_notok("f(x::Int16 = 0")
        kw_default_notok("f(x::Int32 = 0x0000_0")
        kw_default_notok("f(x::Int64 = 0")
        kw_default_notok("f(x::Int128 = 0")
    end
    kw_default_notok("f(x::Int8 = 0000_0000")
    kw_default_notok("f(x::Int16 = 0000_0000")
    kw_default_notok("f(x::Int128 = 0000_0000")
    kw_default_notok("f(x::Float64 = 1)")
    kw_default_notok("f(x::Float32 = 3.4")
    kw_default_notok("f(x::Float32 = -23.")
    kw_default_notok("f(x::Int = 0.1)")
    kw_default_notok("f(x::String = 0.1)")
    kw_default_notok("f(x::Symbol = \"a\"")
    kw_default_notok("f(x::Char = \"a\"")
    kw_default_notok("f(x::Bool = 1")
    kw_default_notok("f(x::Bool = 0x01")
    kw_default_notok("f(x::UInt8 = 0b000000000")
    kw_default_notok("f(x::UInt16 = 0b0000_0000_0000_0000_0")
    kw_default_notok("f(x::UInt32 = 0b0")
    kw_default_notok("f(x::UInt64 = 0b0_0")
    kw_default_notok("f(x::UInt128 = 0b0")
    kw_default_notok("f(x::UInt8 = 0o0000")
    kw_default_notok("f(x::UInt16 = 0o0")
    kw_default_notok("f(x::UInt32 = 0o00000000000000")
    kw_default_notok("f(x::UInt64 = 0o0_0")
    kw_default_notok("f(x::UInt128 = 0o00")
    kw_default_notok("f(x::UInt8 = 0x000")
    kw_default_notok("f(x::UInt16 = 0x00000")
    kw_default_notok("f(x::UInt32 = 0x0000_00_000")
    kw_default_notok("f(x::UInt64 = 0x000_0_0")
    kw_default_notok("f(x::UInt128 = 0x000000")
end

@testitem "check_use_of_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""
        module \"a\" end
        abstract type \"\"\"123\"\"\" end
        primitive type 1 8 end
        struct 1.0 end
        mutable struct 'a' end
        1 = 1
        f(true = 1)
        123::123
        123 isa false
        """)

    @test errorof(cst.args[1].args[2], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[2].args[1], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[3].args[1], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[4].args[2], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[5].args[2], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[6].args[1], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[7].args[2].args[1], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[8].args[2], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
    @test errorof(cst.args[9].args[3], meta_dict) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
end

@testitem "check_break_continue" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""
        for i = 1:10
            continue
        end
        break
        """)
    
    @test errorof(cst.args[1].args[2].args[1], meta_dict) === nothing
    @test errorof(cst.args[2], meta_dict) === JuliaWorkspaces.StaticLint.ShouldBeInALoop
end

@testitem "@." setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasref

    cst, meta_dict = parse_and_pass("@. a + b")    

    @test hasref(cst.args[1].args[1], meta_dict)
end

@testitem "using" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasbinding, getmeta

    cst, meta_dict = parse_and_pass("using Base")
    @test hasbinding(cst.args[1].args[1].args[1], meta_dict)

    cst, meta_dict = parse_and_pass("using Base.Meta")
    @test !hasbinding(cst.args[1].args[1].args[1], meta_dict)
    @test hasbinding(cst.args[1].args[1].args[2], meta_dict)
    @test haskey(getmeta(cst, meta_dict).scope.modules, :Meta)

    cst, meta_dict = parse_and_pass("using Core.Compiler.Pair")
    @test !hasbinding(cst.args[1].args[1].args[1], meta_dict)
    @test !hasbinding(cst.args[1].args[1].args[2], meta_dict)
    @test hasbinding(cst.args[1].args[1].args[3], meta_dict)

    cst, meta_dict = parse_and_pass("using Base.UUID, Base.any")
    @test hasbinding(cst.args[1].args[1].args[2], meta_dict)
    @test hasbinding(cst.args[1].args[2].args[2], meta_dict)

    cst, meta_dict = parse_and_pass("using Base.Meta: quot, lower")
    @test hasbinding(cst.args[1].args[1].args[2].args[1], meta_dict)
    @test hasbinding(cst.args[1].args[1].args[3].args[1], meta_dict)

    cst, meta_dict = parse_and_pass("using Base.Meta: quot, lower")
end

@testitem "issue 1609" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst1, meta_dict1 = parse_and_pass("function g(@nospecialize(x), y) x + y end")
    cst2, meta_dict2 = parse_and_pass("function g(@nospecialize(x), y) y end")
    @test !haserror(cst1.args[1].args[1].args[2].args[3], meta_dict1)
    @test haserror(cst2.args[1].args[1].args[2].args[3], meta_dict2)
end

@testitem "j-vsc issue 1835" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""const x::T = x
        local const x = 1""")

    @test errorof(cst.args[1], meta_dict) === (VERSION < v"1.8.0-DEV.1500" ? JuliaWorkspaces.StaticLint.TypeDeclOnGlobalVariable : nothing)
    @test errorof(cst.args[2], meta_dict) === JuliaWorkspaces.StaticLint.UnsupportedConstLocalVariable
end

@testitem "issue 1609" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst1, meta_dict1 = parse_and_pass("function g(@nospecialize(x), y) x + y end")
    cst2, meta_dict2 = parse_and_pass("function g(@nospecialize(x) = 1) x end")
    cst3, meta_dict3 = parse_and_pass("function g(@nospecialize(x) = 1, y = 2) x + y end")
    cst4, meta_dict4 = parse_and_pass("function g(@nospecialize(x), y) y end")
    @test !haserror(cst1.args[1].args[1].args[2].args[3], meta_dict1)
    @test !haserror(cst2.args[1].args[1].args[2].args[1], meta_dict2)
    @test !haserror(cst3.args[1].args[1].args[2].args[1], meta_dict3)
    @test haserror(cst4.args[1].args[1].args[2].args[3], meta_dict4)
end

@testitem "issue #226" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst, meta_dict = parse_and_pass("function my_function(::Any...) end")
    @test !haserror(cst.args[1].args[1].args[2], meta_dict)
end

@testitem "issue #218" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""
    struct Asdf end

    function foo(x)
        if x > 0
            ret = Asdf
        else
            ret = "hello"
        end
    end

    function foo(x)
        if x > 0
            ret = Asdf()
        else
            ret = "hello"
        end
    end""")

    @test errorof(cst.args[2].args[2].args[1].args[3].args[1].args[1], meta_dict) !== JuliaWorkspaces.StaticLint.InvalidRedefofConst
    @test errorof(cst.args[3].args[2].args[1].args[3].args[1].args[1], meta_dict) !== JuliaWorkspaces.StaticLint.InvalidRedefofConst
end

@testitem "issue #382" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst, meta_dict = parse_and_pass("""
    function f(a::T, invert=false)::T where {T <: Integer}
        invert ? -a : a
    end""")
    @test !haserror(cst.args[1].args[1].args[1].args[1], meta_dict)
end

@testitem "issue #210" setup=[shared_static_lint] begin
    if VERSION > v"1.5-"
        cst, meta_dict, jw = parse_and_pass("""h()::@NamedTuple{a::Int,b::String} = (a=1, b = "s")""")
        @test isempty(get_hints(jw))
    end
end

@testitem "Base.@kwdef" setup=[shared_static_lint] begin
    if isdefined(Base, Symbol("@kwdef"))
        cst, meta_dict, jw = parse_and_pass("""
        Base.@kwdef struct T
            arg = 1
        end""")
        @test isempty(get_hints(jw))
    end
end

@testitem "type inference by use" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof

    cst, meta_dict = parse_and_pass("""
    f(x::String) = true
    function g(x)
        f(x)
    end""")
    @test bindingof(cst.args[2].args[1].args[2], meta_dict).type !== nothing

    cst, meta_dict = parse_and_pass("""
    f(x::String) = true
    f(x::Char) = true
    function g(x)
        f(x)
    end""")
    @test bindingof(cst.args[3].args[1].args[2], meta_dict).type === nothing

    cst, meta_dict = parse_and_pass("""
    f(x::String) = true
    f1(x::String) = true
    function g(x)
        f(x)
        f1(x)
    end""")
    @test bindingof(cst.args[3].args[1].args[2], meta_dict).type !== nothing

    cst, meta_dict = parse_and_pass("""
    f(x::String) = true
    f1(x::Char) = true
    function g(x)
        f(x)
        f1(x)
    end""")
    @test bindingof(cst.args[3].args[1].args[2], meta_dict).type === nothing

    cst, meta_dict = parse_and_pass("""
    f(x::String) = true
    f1(x) = true
    function g(x)
        f(x)
        f1(x)
    end""")
    @test bindingof(cst.args[3].args[1].args[2], meta_dict).type !== nothing
end

# @testitem "forward relative using/import" begin
#    cst, meta_dict = parse_and_pass("""
# module A
# module B
#     module C
#         using ..Sibling
#         f() = Sibling.g()
#     end
#     module Sibling
#         export g
#         g() = 1
#     end
# end
# end
# """)
#    # f’s body Sibling.g should resolve
#    fcall = cst.args[1].args[3].args[1].args[3].args[2]   # C’s f() definition
#    # Sibling.g call: fcall.args[2].args[1] is the call; its callee is getfield
#    callee = fcall.args[2].args[1].args[1]               # Sibling
#    @test StaticLint.hasref(callee)
# end

@testitem "forward relative using/import" setup=[shared_static_lint] begin
    import CSTParser
    using JuliaWorkspaces.StaticLint: hasref

    cst, meta_dict = parse_and_pass("""
    module A
    module B
        module C
            using ..Sibling
            f() = Sibling.g()
        end
        module Sibling
            export g
            g() = 1
        end
    end
    end
    """)

    modC = find_module_by_name(cst, "C")
    @test modC !== nothing

    fexpr = find_first(modC) do x
        CSTParser.defines_function(x) &&
            CSTParser.isidentifier(CSTParser.get_name(x)) &&
            CSTParser.valof(CSTParser.get_name(x)) == "f"
    end
    @test fexpr !== nothing

    gget = find_first(fexpr, CSTParser.is_getfield_w_quotenode)
    @test gget !== nothing

    lhs = gget.args[1]                    # Sibling
    rhsid = gget.args[2].args[1]          # g (inside QuoteNode)

    @test JuliaWorkspaces.StaticLint.hasref(lhs, meta_dict)
    @test JuliaWorkspaces.StaticLint.hasref(rhsid, meta_dict)
end

@testitem "too many dots" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, RelativeImportTooManyDots

    cst, meta_dict, jw = parse_and_pass("""
        module A
            import ....X
        end
        """)
    errs = collect_hints(cst, meta_dict, jw)
    @test any(err -> errorof(err[2], meta_dict) === RelativeImportTooManyDots, errs)
end


@testitem "add eval method to modules/toplevel scope" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst, meta_dict = parse_and_pass("""
        module M
        expr = :(a + b)
        eval(expr)
        end
        """)
    @test !haserror(cst.args[1].args[3].args[2], meta_dict)

    cst, meta_dict = parse_and_pass("""
    expr = :(a + b)
    eval(expr)
    """)
    @test !haserror(cst.args[2], meta_dict)
end

@testitem "reparse" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: hasref

    cst, meta_dict = parse_and_pass("""
    x = 1
    function f(arg)
        x
    end
    """)
    @test hasref(cst.args[2].args[2].args[1], meta_dict)
end

@testitem "duplicate function argument" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict = parse_and_pass("""
    f(a,a) = a
    """)
    @test errorof(cst[1][1][5], meta_dict) == JuliaWorkspaces.StaticLint.DuplicateFuncArgName
end

@testitem "type alias bindings" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta

    cst, meta_dict = parse_and_pass("""
    T{S} = Vector{S}
    """)
    @test haskey(getmeta(cst, meta_dict).scope.names, "T")
    @test haskey(getmeta(cst[1], meta_dict).scope.names, "S")
end

@testitem ":call w/ :parameters traverse order" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    function f(arg; kw = arg)
        arg * kw
    end
    """)
    @test isempty(get_hints(jw))
end

@testitem "handle shadow bindings on method" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    f(x) = 1
    g = f
    g(1)
    """)
    @test isempty(get_hints(jw))
end

@testitem "documented symbol resolving" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    \"\"\"
    doc
    \"\"\"
    func
    func(x) = 1
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    \"\"\"
    doc
    \"\"\"
    func(a,b)::Int
    func(x, b) = 1
    """)
    @test isempty(get_hints(jw))
end

@testitem "unused bindings" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof

    cst, meta_dict, jw = parse_and_pass("""
    function f(arg, arg2)
        arg*arg2
        arg3 = 1
    end
    """)
    @test errorof(cst[1][3][2][1], meta_dict) !== nothing

    cst, meta_dict, jw = parse_and_pass("""
    function f()
        arg = false
        while arg
            if arg
            end
            arg = true
        end
    end
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    function f(arg)
        arg
        while true
            arg = 1
        end
    end
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    function f(arg)
        arg
        while true
            while true
                arg = 1
            end
        end
    end
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    function f()
        (a = 1, b = 2)
    end
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    function f()
        arg = 0
        if 1
            while true
                arg = 1
            end
        end
    end
    """)
    @test isempty(get_hints(jw))
end

@testitem "unwrap sig" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, haserror

    cst, meta_dict = parse_and_pass("""
    function multiply!(x::T, y::Integer) where {T} end
    multiply!(1, 3)
    """)
    @test errorof(cst[2], meta_dict) === nothing

    cst, meta_dict = parse_and_pass("""
    function multiply!(x::T, y::Integer)::T where {T} end
    multiply!(1, 3)
    """)
    @test errorof(cst[2], meta_dict) === nothing

    cst, meta_dict = parse_and_pass("function f(z::T)::Nothing where T end")
    @test haserror(cst[1].args[1].args[1].args[1].args[2], meta_dict)

    cst, meta_dict = parse_and_pass("function f(z::T) where T end")
    @test haserror(cst[1].args[1].args[1].args[2], meta_dict)
end

@testitem "clear .type refs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof

    cst, meta_dict = parse_and_pass("""
    struct T end
    function f(x::T)
    end
    """)
    @test bindingof(cst[2][2][3], meta_dict).type == bindingof(cst[1], meta_dict)
end

@testitem "clear .type refs" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    struct T{S,R} where S <: Number where R <: Number
    end
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    struct T{S,R} <: Number where S <: Number
        x::S
    end
    """)
    @test isempty(get_hints(jw))
end

@testitem "where type param infer" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta

    cst, meta_dict, jw = parse_and_pass("""
    foo(u::Union) = 1
    function foo(x::T) where {T}
        x + foo(T)
    end
    """)

    @test getmeta(cst[2], meta_dict).scope.names["T"].type isa JuliaWorkspaces.SymbolServer.DataTypeStore
    @test isempty(get_hints(jw))
end

@testitem "where type param infer" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta

    cst, meta_dict, jw = parse_and_pass("""
    bar(u::Union) = 1
    foo(x::T, y::S, q::V) where {T, S <: V} where {V <: Integer} = x + y + q + bar(S) + bar(T) + bar(V)
    """)

    @test getmeta(cst[2], meta_dict).scope.names["T"].type isa JuliaWorkspaces.SymbolServer.DataTypeStore
    @test getmeta(cst[2], meta_dict).scope.names["S"].type isa JuliaWorkspaces.SymbolServer.DataTypeStore
    @test getmeta(cst[2], meta_dict).scope.names["V"].type isa JuliaWorkspaces.SymbolServer.DataTypeStore
    @test isempty(get_hints(jw))
end

@testitem "softscope" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof, bindingof, scopeof, loose_refs

    cst, meta_dict = parse_and_pass("""
    function foo()
        x = 1
        x
        if rand(Bool)
            x = 2
        end
        x
        while rand(Bool)
            x = 3
        end
        x
        for _ in 1:2
            x = 4
            y = 1
        end
        x
    end
    """)

    # check soft-scope bindings are lifted to parent scope
    @test refof(cst[1][3][2], meta_dict) == bindingof(cst[1][3][1][1], meta_dict)
    @test refof(cst[1][3][4], meta_dict) == bindingof(cst[1][3][3][3][1][1], meta_dict)
    @test refof(cst[1][3][6], meta_dict) == bindingof(cst[1][3][5][3][1][1], meta_dict)
    @test refof(cst[1][3][8], meta_dict) == bindingof(cst[1][3][7][3][1][1], meta_dict)

    # check binding made in soft-scope with no matching binidng in parent scope isn't lifted
    @test !haskey(scopeof(cst[1], meta_dict).names, "y")
    @test haskey(scopeof(cst[1][3][7], meta_dict).names, "y")


    @test length(loose_refs(bindingof(cst[1][3][1][1], meta_dict), meta_dict)) == 8
    @test length(loose_refs(bindingof(cst[1][3][3][3][1][1], meta_dict), meta_dict)) == 8
    @test length(loose_refs(bindingof(cst[1][3][5][3][1][1], meta_dict), meta_dict)) == 8
    @test length(loose_refs(bindingof(cst[1][3][7][3][1][1], meta_dict), meta_dict)) == 8

    cst, meta_dict = parse_and_pass("""
    function foo()
        for _ in 1:2
            x = 1
            x
        end
        x
        x = 1
        x
    end
    """)
    @test length(loose_refs(bindingof(cst[1][3][1][3][1][1], meta_dict), meta_dict)) == 2
    @test length(loose_refs(bindingof(cst[1][3][3][1], meta_dict), meta_dict)) == 2
end

# @testitem "test workspace packages" begin
#     empty!(server.files)
#     s1 = """
#     module WorkspaceMod
#     inner_sym = 1
#     exported_sym = 1
#     export exported_sym
#     end"""
#     f1 = StaticLint.File("workspacemod.jl", s1, CSTParser.parse(s1, true), nothing, server)
#     StaticLint.setroot(f1, f1)
#     StaticLint.setfile(server, f1.path, f1)
#     StaticLint.semantic_pass(f1)
#     server.workspacepackages["WorkspaceMod"] = f1
#     s2 = """
#     using WorkspaceMod
#     exported_sym
#     WorkspaceMod.inner_sym
#     """
#     f2 = StaticLint.File("someotherfile.jl", s2, CSTParser.parse(s2, true), nothing, server)
#     StaticLint.setroot(f2, f2)
#     StaticLint.setfile(server, f2.path, f2)
#     StaticLint.semantic_pass(f2)
#     @test StaticLint.hasref(StaticLint.getcst(f2)[1][2][1])
#     @test StaticLint.hasref(StaticLint.getcst(f2)[2])
#     @test StaticLint.hasref(StaticLint.getcst(f2)[3][3][1])
# end

@testitem "#1218" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    cst, meta_dict, jw = parse_and_pass("""function foo(a; p) a+p end
    foo(1, p = true)""")
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""function foo(a; p) a end
    foo(1, p = true)""")
    @test haserror(cst[1][2][4][1], meta_dict)

    cst, meta_dict, jw = parse_and_pass("""function foo(a; p::Bool) a+p end
    foo(1, p = true)""")
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""function foo(a; p::Bool) a end
    foo(1, p = true)""")
    @test haserror(cst[1][2][4][1], meta_dict)
end

@testitem "import as ..." setup=[shared_static_lint] begin
    if Meta.parse("import a as b", raise = false).head !== :error
        cst, meta_dict = parse_and_pass("""import Base as base""")
        @test JuliaWorkspaces.StaticLint.hasbinding(cst[1][2][3], meta_dict)
        @test !JuliaWorkspaces.StaticLint.hasbinding(cst[1][2][1][1], meta_dict)

        # incomplete expressinon should not error
        cst, meta_dict = parse_and_pass("""import Base as""")
    end
end


@testitem "#1218" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    module Sup
    function myfunc end
    module SubA
    import ..myfunc
    myfunc(x::Int) = println("hello Int: ", x) # Cannot define function ; it already has a value.
    end # module

    end
    """)
    @test isempty(get_hints(jw))

end


@testitem "macrocall bindings: #2187" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    function f(url = 1, file = 1)
        @info "Downloading" source = url dest = file
        return nothing
    end
    """)
    @test isempty(get_hints(jw))
end

@testitem "aliased import: #974" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    const CC = Core.Compiler
    import .CC: div
    """)
    @test isempty(get_hints(jw))

    cst, meta_dict, jw = parse_and_pass("""
    const C = Core
    import .C: div
    """)
    @test isempty(get_hints(jw))
end

@testitem "kwarg refs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta

    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb; ccc)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in getmeta(cst.args[1], meta_dict).scope.names
        @test length(b.refs) == 2
    end

    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb::Foo; ccc::Bar)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in getmeta(cst.args[1], meta_dict).scope.names
        @test length(b.refs) == 2
    end

    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb=1; ccc=2)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in getmeta(cst.args[1], meta_dict).scope.names
        @test length(b.refs) == 2
    end
    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb::Foo=1; ccc::Bar=2)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in getmeta(cst.args[1], meta_dict).scope.names
        @test length(b.refs) == 2
    end
end

@testitem "iteration over 1:length(...)" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("arr = []; [1 for _ in 1:length(arr)]")
    @test isempty(collect_hints(cst, meta_dict, jw))
    cst, meta_dict, jw = parse_and_pass("arr = []; [arr[i] for i in 1:length(arr)]")
    @test length(collect_hints(cst, meta_dict, jw)) == 2
    cst, meta_dict, jw = parse_and_pass("arr = []; [i for i in 1:length(arr)]")
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for _ in 1:length(arr)
    end
    """)
    @test isempty(collect_hints(cst, meta_dict, jw))
    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for i in 1:length(arr)
        arr[i]
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 2
    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for i in 1:length(arr)
        println(i)
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for _ in 1:length(arr), _ in 1:length(arr)
    end
    """)
    @test isempty(collect_hints(cst, meta_dict, jw))
    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for i in 1:length(arr), j in 1:length(arr)
        arr[i] + arr[j]
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 4
    cst, meta_dict, jw = parse_and_pass("""
    arr = []
    for i in 1:length(arr), j in 1:length(arr)
        println(i + j)
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr::Vector)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr::Array)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr::Matrix)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr::Array{T,N}) where T where N
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 0

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr::AbstractArray)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 4

    cst, meta_dict, jw = parse_and_pass("""
    function f(arr)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(collect_hints(cst, meta_dict, jw)) == 4
end

@testitem "assigned but not used with loops" setup=[shared_static_lint] begin
    cst, meta_dict, jw = parse_and_pass("""
    function a!(v)
        next = 0
        for i in eachindex(v)
            current = next
            next = sin(current)
            while true
                current = next
                next = sin(current)
            end
            v[i] = current
        end
    end
    """)
    @test isempty(get_hints(jw))
    cst, meta_dict, jw = parse_and_pass("""
    function f(v)
        next = 0
        for _ in v
            foo = next
            for _ in v
                next = foo
            end
            foo = sin(next)
        end
    end
    """)
    @test isempty(get_hints(jw))
end

@testitem "macro definition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: getmeta, get_method

    cst, meta_dict = parse_and_pass("""
    module JumpToMacroDoesNotWork
        export @mymacro

        macro mymacro()
        end
    end

    JumpToMacroDoesNotWork.@mymacro(1+1)
    """)
    m = cst.args[end].args[1].args[2].args[1]
    methods = Set()
    for r in getmeta(m, meta_dict).ref.refs
        method = get_method(r)
        if method !== nothing
            push!(methods, method)
        end
    end

    @test !isempty(methods)
end

@testitem "correctly mark public bindings" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof

    if VERSION >= v"1.12"
        cst, meta_dict = parse_and_pass("""
            module TopModule
            abstract type T end
            struct Foo <: T end
            export T
            public Foo

            module SubModule
            using ..TopModule
            T
            TopModule.Foo
            end

            end""")

        @test refof(cst.args[1].args[3].args[3].args[1], meta_dict) !== nothing
        @test refof(cst.args[1].args[3].args[4].args[1], meta_dict).is_public
        @test refof(cst.args[1].args[3].args[5].args[3].args[3].args[2].args[1], meta_dict).is_public
    end
end

@testitem "circular binding resolution does not overflow (#404)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: @uri_str

    # `const Bar = Foo.Bar` inside `module Foo` makes resolving `Foo.Bar`
    # recurse into itself; without a visited guard in `_get_field` the
    # semantic pass stack-overflows.
    jw = JuliaWorkspace()
    root = uri"file:///d/test.jl"
    add_file!(jw, TextFile(root, SourceText(
        "module Foo\nimport Bar\nimport Bar: foo\ninclude(\"test2.jl\")\nend\n", "julia")))
    add_file!(jw, TextFile(uri"file:///d/test2.jl", SourceText("const Bar = Foo.Bar\n", "julia")))

    meta_dict, _ = JuliaWorkspaces.derived_static_lint_meta_for_root(jw.runtime, root)
    @test meta_dict isa Dict
end

@testitem "@testitem/@testset blocks have isolated scopes (#405)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof, errorof, refof, Scope, InvalidRedefofConst, CannotDeclareConst

    has_error(cst, meta_dict, jw, err) =
        any(errorof(x, meta_dict) === err for (_, x) in collect_hints(cst, meta_dict, jw))

    function get_ids(x, ids=[])
        if JuliaWorkspaces.StaticLint.headof(x) === :IDENTIFIER
            push!(ids, x)
        elseif x.args !== nothing
            for a in x.args
                get_ids(a, ids)
            end
        end
        ids
    end

    # Sibling @testitem blocks each run in their own module — reusing const/
    # struct names across them must not be flagged.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @testitem "A" begin
            const X = 1
            struct Foo end
        end
        @testitem "B" begin
            const X = 2
            struct Foo end
        end
        """)
        @test scopeof(cst.args[1], meta_dict) isa Scope
        @test scopeof(cst.args[2], meta_dict) isa Scope
        @test scopeof(cst.args[1], meta_dict) !== scopeof(cst.args[2], meta_dict)
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
        @test !has_error(cst, meta_dict, jw, CannotDeclareConst)
    end

    # @testset blocks evaluate in a local scope; same isolation applies.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @testset "A" begin
            const X = 1
        end
        @testset "B" begin
            const X = 2
        end
        """)
        @test scopeof(cst.args[1], meta_dict) isa Scope
        @test scopeof(cst.args[2], meta_dict) isa Scope
        @test !has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    # A genuine redefinition within a single block is still reported.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @testitem "A" begin
            const X = 1
            const X = 2
        end
        """)
        @test has_error(cst, meta_dict, jw, InvalidRedefofConst)
    end

    # References to file-level bindings still resolve from inside the block.
    let (cst, meta_dict, jw) = parse_and_pass("""
        helper(x) = x
        @testitem "A" begin
            helper(1)
        end
        """)
        helpers = filter(x -> JuliaWorkspaces.CSTParser.valof(x) == "helper", get_ids(cst.args[2]))
        @test length(helpers) == 1
        @test refof(helpers[1], meta_dict) !== nothing
    end
end

@testitem "assignment to outer local inside inner scope (#393)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, UnusedBinding

    function has_unused(src)
        cst, meta_dict, jw = parse_and_pass(src)
        any(errorof(x, meta_dict) === UnusedBinding for (_, x) in collect_hints(cst, meta_dict, jw))
    end

    # Assigning to a variable already local in an enclosing scope reassigns it
    # rather than introducing a new (unused) local.
    @test !has_unused("""
        function f()
            x = 1
            let y = 2
                x = y + 1
            end
            return x
        end""")

    @test !has_unused("""
        function f()
            x = 1
            let
                let
                    x = 2
                end
            end
            return x
        end""")

    # Closure capturing/reassigning an outer local.
    @test !has_unused("""
        function f()
            x = 1
            g() = (x = 2)
            g()
            return x
        end""")

    # `do` block (also a closure).
    @test !has_unused("""
        function f()
            x = 1
            map([1]) do _
                x = 2
            end
            return x
        end""")

    # Nested soft scopes reaching an enclosing local.
    @test !has_unused("""
        function f()
            x = 1
            for i in 1:2
                for j in 1:2
                    x = i + j
                end
            end
            return x
        end""")

    # A genuinely unused local introduced inside a `let` is still flagged.
    @test has_unused("""
        function f()
            let
                z = 1
            end
        end""")

    # An explicit `local` inside a `let` introduces a distinct binding; here the
    # inner unused `local x` is still flagged.
    @test has_unused("""
        function f()
            x = 1
            @show x
            let
                local x = 2
            end
        end""")
end

@testitem "@nospecialize without argument (#390)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: func_nargs
    using JuliaWorkspaces.CSTParser: parse, EXPR

    @test func_nargs(parse("function f(@nospecialize) end")) == (1, 1, Symbol[], false)
    @test func_nargs(parse("function f(@nospecialize()) end")) == (1, 1, Symbol[], false)
    @test func_nargs(parse("f(@nospecialize) = 1")) == (1, 1, Symbol[], false)

    # Full pipeline: defining and calling such a function must not crash.
    cst, meta_dict, jw = parse_and_pass("""
        function f(@nospecialize(x))
            @nospecialize
            return x
        end
        f(1)
        """)
    @test cst isa EXPR
end

@testitem "constructors on parameterized type aliases (#394)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, CannotDefineFuncAlreadyHasValue

    has_error(cst, meta_dict, jw, err) =
        any(errorof(x, meta_dict) === err for (_, x) in collect_hints(cst, meta_dict, jw))

    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        struct Container{T}
            value::T
        end
        const IntContainer = Container{Int}
        function IntContainer(x::Float64)
            return IntContainer(round(Int, x))
        end
        end
        """)
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        struct Foo{A,B} end
        const Bar = Foo{Int}
        const Baz = Bar{Int}
        Baz() = 1
        end
        """)
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end
end

@testitem "where-wrapped type aliases (#438)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, CannotDefineFuncAlreadyHasValue

    has_error(cst, meta_dict, jw, err) =
        any(errorof(x, meta_dict) === err for (_, x) in collect_hints(cst, meta_dict, jw))

    # Aliasing a UnionAll via a `where` clause is a valid constructor target.
    let (cst, meta_dict, jw) = parse_and_pass("""
        const MyVec = Vector{T} where T

        MyVec(x::Int64) = [x]
        """)
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    # Multiple type variables in the `where` clause.
    let (cst, meta_dict, jw) = parse_and_pass("""
        const MyArray = Array{T,N} where {T,N}

        MyArray(x::Int64) = [x]
        """)
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    # User-defined struct aliased through a `where` clause.
    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        struct Foo{T} end
        const Bar = Foo{T} where T
        Bar(x::Int64) = 1
        end
        """)
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end
end

@testitem "function definition satisfying a `local` declaration (#349)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, CannotDefineFuncAlreadyHasValue

    has_error(cst, meta_dict, jw, err) =
        any(errorof(x, meta_dict) === err for (_, x) in collect_hints(cst, meta_dict, jw))

    # A bare `local f` declaration does not assign a value, so a later method
    # definition for that name is not a redefinition.
    let (cst, meta_dict, jw) = parse_and_pass("""
        function fun()
            local inner_fun
            let
                inner_fun(x) = x
            end
        end""")
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function fun()
            local inner_fun
            inner_fun(x) = x
        end""")
        @test !has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    # But once a value is assigned, defining a method is still flagged.
    let (cst, meta_dict, jw) = parse_and_pass("""
        function fun()
            local inner_fun
            inner_fun = 1
            inner_fun(x) = x
        end""")
        @test has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function fun()
            inner_fun = 1
            inner_fun(x) = x
        end""")
        @test has_error(cst, meta_dict, jw, CannotDefineFuncAlreadyHasValue)
    end
end

@testitem "constructor for existing type (#395)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, InvalidTypeDeclaration

    n_invalid(cst, meta_dict, jw) =
        count(e -> errorof(e, meta_dict) === InvalidTypeDeclaration,
              (e for (_, e) in collect_hints(cst, meta_dict, jw)))

    # Qualified `Base.BigFloat(x::MyNumber)` extends the type; later use of
    # BigFloat as a type decl is fine.
    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        struct MyNumber
            sign::Bool
            exponent::Int
            mantissa::Int
        end
        function Base.BigFloat(x::MyNumber)
            x
        end
        function foo(x::BigFloat)
            x
        end
        end
        """)
        @test n_invalid(cst, meta_dict, jw) == 0
    end

    # Same, extending via an explicit `import Base: BigFloat`.
    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        import Base: BigFloat
        struct MyNumber
            sign::Bool
            exponent::Int
            mantissa::Int
        end
        function BigFloat(x::MyNumber)
            x
        end
        function cube_root(x::BigFloat)
            x
        end
        end
        """)
        @test n_invalid(cst, meta_dict, jw) == 0
    end

    # A bare unqualified definition introduces a new local that shadows the
    # type, so the later type declaration is correctly flagged.
    let (cst, meta_dict, jw) = parse_and_pass("""
        module M
        struct MyNumber
            sign::Bool
            exponent::Int
            mantissa::Int
        end
        function BigFloat(x::MyNumber)
            x
        end
        function cube_root(x::BigFloat)
            x
        end
        end
        """)
        @test n_invalid(cst, meta_dict, jw) == 1
    end
end

@testitem "macro-rewritten call signature (#389)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: func_nargs, errorof, IncorrectCallArgs

    # An unknown macro wrapping a function can rewrite its call signature
    # (e.g. KernelAbstractions' @kernel), so a differing argument count must
    # not be flagged.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @kernel function mul2_kernel(A)
            A[I] = 2 * A[I]
        end
        mul2_kernel(dev, 64)
        """)
        env = get_env(jw)
        @test errorof(cst.args[2], meta_dict) === nothing
        @test func_nargs(cst.args[1].args[end], env, meta_dict) == (0, typemax(Int), Symbol[], true)
    end

    # Signature-preserving Base macros (@inline, ...) resolve to known Base
    # macros, so argument counts are still checked.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @inline function g(x)
            x
        end
        g(1, 2)
        """)
        env = get_env(jw)
        @test errorof(cst.args[2], meta_dict) === IncorrectCallArgs
        @test func_nargs(cst.args[1].args[end], env, meta_dict) == (1, 1, Symbol[], false)
    end

    # The module-qualified form (Base.@propagate_inbounds) resolves too.
    let (cst, meta_dict, jw) = parse_and_pass("""
        Base.@propagate_inbounds function h(a, b)
            a + b
        end
        h(1)
        """)
        @test errorof(cst.args[2], meta_dict) === IncorrectCallArgs
    end
end

@testitem "@enum with explicit values (#275)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: haserror

    # missing-reference hints are the collect_hints entries with no error code.
    missing_refs(cst, meta_dict, jw) =
        [x for (_, x) in collect_hints(cst, meta_dict, jw) if !haserror(x, meta_dict)]

    # Members given explicit values must still be bound and exportable.
    let (cst, meta_dict, jw) = parse_and_pass("@enum Foo x=1; export x")
        @test isempty(missing_refs(cst, meta_dict, jw))
    end

    let (cst, meta_dict, jw) = parse_and_pass("@enum Foo x=1 y=2")
        @test isempty(missing_refs(cst, meta_dict, jw))
    end

    # Block form with explicit values.
    let (cst, meta_dict, jw) = parse_and_pass("""
        @enum Foo begin
            x = 1
            y = 2
        end
        export x, y
        """)
        @test isempty(missing_refs(cst, meta_dict, jw))
    end

    # Mixed bare and explicit-value members; every identifier resolves.
    @test check_resolved("""
        @enum E a b=2 c
        E
        a
        b
        c
        """) == [true, true, true, true, true, true, true, true, true]
end

@testitem "property destructuring infers the field type (#357)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: scopeof

    # `(; s) = t` should infer `s`'s type as the field's declared type (S),
    # the same as the explicit `s = t.s`.
    cst, meta_dict = parse_and_pass("""
        struct S
            a
        end

        struct T
            s::S
        end

        function f1(t::T)
            (; s) = t
            a = s.a
        end

        function f2(t::T)
            s = t.s
            x = s.a
        end
        """)
    sc = scopeof(cst, meta_dict)
    S = sc.names["S"]
    @test scopeof(sc.names["f1"].val, meta_dict).names["s"].type == S
    @test scopeof(sc.names["f2"].val, meta_dict).names["s"].type == S
end

@testitem "hint offsets with unicode (#253)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: headof
    CSTParser = JuliaWorkspaces.CSTParser

    # Hint offsets are byte offsets into the source. Multibyte unicode
    # characters (e.g. `α`) preceding an error must not shift the reported
    # offset off the start of the flagged expression.
    src = "struct Buz\n    x::Integers\n    α::Array{Float65,1}\nend\n"
    cst, meta_dict, jw = parse_and_pass(src)
    cu = codeunits(src)
    hints = collect_hints(cst, meta_dict, jw)

    # For every hint carrying a value, byte offset + span extracts its own text.
    for (offset, x) in hints
        v = CSTParser.valof(x)
        v isa String || continue
        @test String(cu[offset+1:offset+x.span]) == v
    end

    # `Float65` sits after the multibyte `α`; its offset must be the byte offset.
    float65 = find_first(cst, x -> headof(x) === :IDENTIFIER && CSTParser.valof(x) == "Float65")
    @test float65 !== nothing
    off = first(o for (o, x) in hints if x === float65)
    @test String(cu[off+1:off+float65.span]) == "Float65"
    @test off == first(findfirst("Float65", src)) - 1  # 0-based byte offset
end

@testitem "using Base in baremodule (#368)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: headof, hasref
    CSTParser = JuliaWorkspaces.CSTParser

    # Top-level baremodule (no enclosing module to supply Base).
    let (cst, meta_dict, jw) = parse_and_pass("""
        baremodule Flags
        using Base: @enum
        @enum Flag flag
        end
        """)
        baseid = find_first(cst, x -> headof(x) === :IDENTIFIER && CSTParser.valof(x) == "Base")
        @test baseid !== nothing
        @test hasref(baseid, meta_dict)
        @test isempty(collect_hints(cst, meta_dict, jw))
    end
end

@testitem "global definition inside local scope (#315)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: headof, refof
    CSTParser = JuliaWorkspaces.CSTParser

    get_ids(x, ids=[]) = (headof(x) === :IDENTIFIER ? push!(ids, x) :
        (x.args !== nothing && foreach(a -> get_ids(a, ids), x.args)); ids)

    # `global function` / `global struct` / `global x = …` inside a local scope
    # must bind at the enclosing global scope so later uses resolve.
    let (cst, meta_dict, jw) = parse_and_pass("""
        let x = 1
            global function foo()
            end
        end

        function bar()
            foo()
        end
        """)
        @test isempty(collect_hints(cst, meta_dict, jw))
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        let
            global gvar = 1
            global gfunc(x) = x
            global struct GStruct end
        end

        use_gvar() = gvar
        use_gfunc() = gfunc(1)
        use_gstruct() = GStruct
        """)
        @test isempty(collect_hints(cst, meta_dict, jw))
    end

    # Bare `global single` followed by assignment.
    let (cst, meta_dict, jw) = parse_and_pass("""
        let
            global single
            single = 1
        end

        use_single() = single
        """)
        use = last(filter(id -> CSTParser.valof(id) == "single", get_ids(cst)))
        @test refof(use, meta_dict) !== nothing
    end

    # Comma-separated `global foo, bar, baz` — every name must be marked.
    let (cst, meta_dict, jw) = parse_and_pass("""
        let
            global foo, bar, baz
            foo = 1
            bar = 2
            baz = 3
        end

        use() = foo + bar + baz
        """)
        uses = filter(id -> CSTParser.valof(id) in ("foo", "bar", "baz"), get_ids(cst))[end-2:end]
        @test all(id -> refof(id, meta_dict) !== nothing, uses)
    end
end

@testitem "closures referencing variables defined later (#313)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, refof, bindingof, UnusedBinding

    has_unused(cst, meta_dict, jw) =
        any(errorof(x, meta_dict) === UnusedBinding for (_, x) in collect_hints(cst, meta_dict, jw))
    # A missing reference is collected as an identifier hint with no error code.
    has_missingref(cst, meta_dict, jw) =
        any(errorof(x, meta_dict) === nothing for (_, x) in collect_hints(cst, meta_dict, jw))

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            function g()
                println("hello, \$(who)")
            end
            who = "world"
            g()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            g() = who
            who = 1
            g()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            function g()
                function h()
                    return who
                end
                h()
            end
            who = 1
            g()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            let
                g() = v
                v = 1
                g()
            end
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    # A genuinely undefined reference is still reported.
    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            g() = undefined_var
            g()
        end""")
        @test has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    # Closure writes to an outer local declared later; both resolve to it.
    let (cst, meta_dict, jw) = parse_and_pass("""
        function foo()
            function bar()
                x = 2
            end
            local x
            bar()
            return x
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
        local_x = bindingof(cst[1][3][2][2], meta_dict)
        return_x = refof(cst[1][3][4][2], meta_dict)
        @test return_x === local_x
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            function g()
                return x
            end
            local x = 10
            g()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            function g1()
                return v
            end
            function g2()
                return v + 1
            end
            v = 1
            g1() + g2()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function foo()
            function reader()
                return x
            end
            function writer()
                x = 2
            end
            local x
            writer()
            reader()
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function f()
            function g()
                function h()
                    x = 99
                end
                h()
            end
            local x
            g()
            return x
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        function foo()
            function bar()
                tmp = x + 1
                x = tmp
                return tmp
            end
            local x = 0
            bar()
            return x
        end""")
        @test !has_missingref(cst, meta_dict, jw)
        @test !has_unused(cst, meta_dict, jw)
    end

    # A truly unused inner local is still flagged.
    let (cst, meta_dict, jw) = parse_and_pass("""
        function foo()
            function bar()
                y = 2
            end
            bar()
        end""")
        @test has_unused(cst, meta_dict, jw)
    end
end

@testitem "missing reference in macrocall args (#282)" setup=[shared_static_lint] begin
    CSTParser = JuliaWorkspaces.CSTParser

    # Identifiers passed as macro arguments must not be flagged as missing refs:
    # the macro may rewrite/introduce them.
    let (cst, meta_dict, jw) = parse_and_pass("""
        macro Jacobian(u, v, w)
            :( (u, v) -> \$w )
        end
        f = @Jacobian(u, v, u+v^2)
        """)
        @test isempty(collect_hints(cst, meta_dict, jw))
    end

    let (cst, meta_dict, jw) = parse_and_pass("""
        macro m(x)
            :(\$x)
        end
        @m(undefined_var)
        """)
        @test isempty(collect_hints(cst, meta_dict, jw))
    end

    # But identifiers in a user-written local scope (here a function body, even
    # when the function is wrapped by the doc macro) are still checked.
    let (cst, meta_dict, jw) = parse_and_pass("""
        \"\"\"
        docstring
        \"\"\"
        function foo()
            undefined_in_body
        end
        """)
        hints = collect_hints(cst, meta_dict, jw)
        @test length(hints) == 1
        @test CSTParser.valof(hints[1][2]) == "undefined_in_body"
    end
end
