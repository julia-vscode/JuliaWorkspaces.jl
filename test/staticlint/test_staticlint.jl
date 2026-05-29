using StaticLint, SymbolServer
using CSTParser, Test
using StaticLint: scopeof, bindingof, refof, errorof, check_all, getenv



@testmodule shared_static_lint begin
    using JuliaWorkspaces

    export parse_and_pass, check_resolved

    function parse_and_pass(s; dynamic::DynamicMode=DynamicOff)
        our_uri = JuliaWorkspaces.URIs2.uri"file://test.jl"
        jw = JuliaWorkspaces.JuliaWorkspace(;dynamic=dynamic)
        add_file!(jw, TextFile(our_uri, SourceText(s, "julia")))

        if dynamic==DynamicIndexingOnly
            JuliaWorkspaces.wait_until_ready(jw)
        end

        cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, our_uri)
        meta_dict, workspace_packages = JuliaWorkspaces.derived_static_lint_meta_for_root(jw.runtime, our_uri)
        
        return cst, meta_dict
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
            # push children
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
# Adapter to support weird block call
find_first(f::Function, root::CSTParser.EXPR) = find_first(root, f)

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

@testitem "tuple args" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2))
        arg1, arg2
    end""")
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
    end

    let (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2) = (1,2))
        arg1, arg2
    end""")
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
    end

    let (cst, meta_dict) = parse_and_pass("""
    function f((arg1, arg2)::Tuple{Int,Int})
        arg1, arg2
    end""")
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][1], meta_dict)
        @test JuliaWorkspaces.StaticLint.hasref(cst[1][3][1][3], meta_dict)
    end
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

@testitem "pirates" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof, bindingof

    let (cst, meta_dict) = parse_and_pass("""
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
    let (cst, meta_dict) = parse_and_pass("""
    struct AreaIterator{T}
        array::AbstractMatrix{T}
        radius::Int
    end
    Base.eltype(::Type{AreaIterator{T}}) where T = Tuple{T, AbstractVector{T}}
    """)
        JuliaWorkspaces.StaticLint.check_for_pirates(cst[2], meta_dict)
        @test errorof(cst[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
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
    let (cst, meta_dict) = parse_and_pass("""
    abstract type At end
    struct Ty end
    Base.eltype(::Type{Ty{T}} where {T}) = 1
    Base.length(s::Ty{T} where T <: At) = 1
    """)
        @test JuliaWorkspaces.StaticLint.check_for_pirates(cst[3], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.check_for_pirates(cst[4], meta_dict) === nothing
    end

    let (cst, meta_dict) = parse_and_pass("""
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
end

@testitem "check_call" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    sin(1)
    sin(1,2)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) == JuliaWorkspaces.StaticLint.IncorrectCallArgs
    end

    let (cst, meta_dict) = parse_and_pass("""
    Base.sin(a,b) = 1
    function Base.sin(a,b)
        1
    end
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[1], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2].args[1], meta_dict) === nothing
    end

    let (cst, meta_dict) = parse_and_pass("""
    f(x) = 1
    f(1, 2)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectCallArgs
    end

    let (cst, meta_dict) = parse_and_pass("""
    view([1], 1, 2, 3)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1], meta_dict) === nothing
    end

    let (cst, meta_dict) = parse_and_pass("""
    f(a...) = 1
    f(1)
    f(1, 2)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === nothing
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[3], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    function func(a, b)
        func(a...)
    end
    """)
        m_counts = JuliaWorkspaces.StaticLint.func_nargs(cst.args[1])
        call_counts = JuliaWorkspaces.StaticLint.call_nargs(cst.args[1].args[2].args[1])
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[1].args[2].args[1], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    function func(@nospecialize args...) end
    func(1, 2)
    """)
        @test JuliaWorkspaces.StaticLint.func_nargs(cst.args[1]) == (0, typemax(Int), String[], false)
        @test JuliaWorkspaces.StaticLint.errorof(cst.args[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    argtail(x, rest...) = 1
    tail(x::Tuple) = argtail(x...)
    """)
        @test JuliaWorkspaces.StaticLint.func_nargs(cst[1]) == (1, typemax(Int), String[], false)
        @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    func(arg::Vararg{T,N}) where N = arg
    func(a,b)
    """)

        @test JuliaWorkspaces.StaticLint.func_nargs(cst[1]) == (0, typemax(Int), String[], false)
        @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    function f(a, b; kw = kw) end
    f(1,2, kw = 1)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    func(a,b,c,d) = 1
    func(a..., 2)
    """)
        JuliaWorkspaces.StaticLint.call_nargs(cst[2])
        @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
    @kwdef struct A
        x::Float64
    end
    A(x = 5.0)
    """)
        @test JuliaWorkspaces.StaticLint.errorof(cst[2], meta_dict) === nothing
    end
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
    let (cst, meta_dict) = parse_and_pass("""
    import Base: sin
    \"\"\"
    docs
    \"\"\"
    sin
    sin(a,b) = 1
    sin(1)
    """)
    # Checks that documented symbols are skipped
        @test isempty(JuliaWorkspaces.StaticLint.collect_hints(cst, JuliaWorkspaces.StaticLint.getenv(server.files[""], server)))
    end
    let (cst, meta_dict) = parse_and_pass("""
    import Base: sin
    sin(a,b) = 1
    sin(1)
    """)
    # Checks that documented symbols are skipped
        @test isempty(JuliaWorkspaces.StaticLint.collect_hints(cst, JuliaWorkspaces.StaticLint.getenv(server.files[""], server)))
    end
    let (cst, meta_dict) = parse_and_pass("""
        function f(a::F)::Bool where {F} a end
        """)
        # ensure we strip all type decl code from around signature
        @test isempty(JuliaWorkspaces.StaticLint.collect_hints(cst, JuliaWorkspaces.StaticLint.getenv(server.files[""], server)))
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

@testitem "JuMP macros" setup=[shared_static_lint] begin
        let (cst, meta_dict) = parse_and_pass("""
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
            @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
        end

        let (cst, meta_dict) = parse_and_pass("""
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
            @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
        end

        let (cst, meta_dict) = parse_and_pass("""
using JuMP
model = Model()
some_bound = 1
@variable(model, some_bound >= x7)
""")
            @test !StaticLint.hasref(cst[4][5][3])
        end

        let (cst, meta_dict) = parse_and_pass("""
using JuMP
model = Model()
some_bound = 1
@expression(model, ex, some_bound >= 1)
""")
            @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
        end

        let (cst, meta_dict) = parse_and_pass("""
using JuMP
model = Model()
@expression(model, expr, 1 == 1)
@constraint(model, con1, expr)
@constraint model con2 expr
""")
            @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
        end
end

@testitem "stdcall" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    ccall(:GetCurrentProcess, stdcall, Ptr{Cvoid}, ())""")
        StaticLint.collect_hints(cst, getenv(server.files[""], server))
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
    
    let (cst, meta_dict) = parse_and_pass("""
    stdcall
    """)
        @test !JuliaWorkspaces.StaticLint.hasref(cst[1], meta_dict)
    end
end

@testitem "check_if_conds" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    if true end
    """)
        StaticLint.check_if_conds(cst.args[1])
        @test cst.args[1].args[1].meta.error == StaticLint.ConstIfCondition
    end
    let (cst, meta_dict) = parse_and_pass("""
    if x = 1 end
    """)
        StaticLint.check_if_conds(cst.args[1])
        @test cst.args[1].args[1].meta.error == StaticLint.EqInIfConditional
    end
    let (cst, meta_dict) = parse_and_pass("""
    if a || x = 1 end
    """)
        StaticLint.check_if_conds(cst.args[1])
        @test cst.args[1].args[1].meta.error == StaticLint.EqInIfConditional
    end
    let (cst, meta_dict) = parse_and_pass("""
    if x = 1 && b end
    """)
        StaticLint.check_if_conds(cst.args[1])
        @test cst.args[1].args[1].meta.error == StaticLint.EqInIfConditional
    end
end


@testitem "check_farg_unused" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("function f(arg1, arg2) arg1 end")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[5]) === StaticLint.UnusedFunctionArgument
    end
    let (cst, meta_dict) = parse_and_pass("function f(arg1::T, arg2::T) arg1 end")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[5]) === StaticLint.UnusedFunctionArgument
    end
    let (cst, meta_dict) = parse_and_pass("function f(arg1, arg2::T, arg3 = 1, arg4::T = 1) end")
        StaticLint.check_farg_unused(cst.args[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst.args[1]).args[2]) === StaticLint.UnusedFunctionArgument
        @test StaticLint.errorof(CSTParser.get_sig(cst.args[1]).args[3]) === StaticLint.UnusedFunctionArgument
        @test StaticLint.errorof(CSTParser.get_sig(cst.args[1]).args[4].args[1]) === StaticLint.UnusedFunctionArgument
        @test StaticLint.errorof(CSTParser.get_sig(cst.args[1]).args[5].args[1]) === StaticLint.UnusedFunctionArgument
    end
    let (cst, meta_dict) = parse_and_pass("function f(arg) arg = 1 end")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === StaticLint.UnusedFunctionArgument
    end
    let (cst, meta_dict) = parse_and_pass(
            """function f(arg)
                x = arg
                arg = x
            end""")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("function f(arg) 1 end")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("f(arg) = true")
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
    end
    let (cst, meta_dict) = parse_and_pass("func(@nospecialize(arg)) = arg")
        StaticLint.check_farg_unused(cst[1])
        @test cst[1].args[1].args[2].meta.error === nothing
    end
    let (cst, meta_dict) = parse_and_pass("""
        function f(x,y,z)
            @. begin
                x = z
                y = z
            end
        end
        """)
        StaticLint.check_farg_unused(cst[1])
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[3]) === nothing
        @test StaticLint.errorof(CSTParser.get_sig(cst[1])[5]) === nothing
    end
end

@testitem "check redefinition of const" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    T = 1
    struct T end
    """)
        @test cst[2].meta.error == StaticLint.CannotDeclareConst
    end
    let (cst, meta_dict) = parse_and_pass("""
    struct T end
    T = 1
    """)
        @test cst[2].meta.error == StaticLint.InvalidRedefofConst
    end
    let (cst, meta_dict) = parse_and_pass("""
    struct T end
    T() = 1
    """)
        @test cst[2].meta.error === nothing
    end
end

@testitem "hoisting of inner constructors" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("""
    struct ASDF
        x::Int
        y::Int
        ASDF(x::Int) = new(x, 1)
    end
    ASDF(1)
    """)
        # Check inner constructor is hoisted
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
end

@testitem "using statements" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    let (cst, meta_dict) = parse_and_pass("using Base.Filesystem: Filesystem")
        @test StaticLint.hasref(cst.args[1].args[1].args[2].args[1])
    end
    let (cst, meta_dict) = parse_and_pass("using Base: Ordering")
        @test StaticLint.hasbinding(cst.args[1].args[1].args[2].args[1])
    end
    let (cst, meta_dict) = parse_and_pass("""
        module Outer
        module Inner
        x = 1
        export x
        end
        using .Inner
        end
        using .Outer: x, rand
        """)
        @test StaticLint.hasbinding(cst.args[2].args[1].args[2].args[1])
        @test StaticLint.hasbinding(cst.args[2].args[1].args[3].args[1])
    end
end

@testitem "don't report unknown getfields when a custom getproperty is defined" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    let (cst, meta_dict) = parse_and_pass("""
    struct T end
    Base.getproperty(x::T, s) = 1
    T
    """)
        @test StaticLint.has_getproperty_method(bindingof(cst.args[1]))
        @test StaticLint.has_getproperty_method(refof(cst.args[3]))
    end
    let (cst, meta_dict) = parse_and_pass("""
    struct T
        f1
        f2
    end
    Base.getproperty(x::T, s) = (x,s)
    f(x::T) = x.f3
    """)
        @test !StaticLint.hasref(cst.args[3].args[2].args[1].args[2].args[1])
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
    let (cst, meta_dict) = parse_and_pass("""
    struct T{S}
        f1
        f2
    end
    Base.getproperty(x::T{Int}, s) = (x,s)
    f(x::T) = x.f3
    """)
        @test !StaticLint.hasref(cst.args[3].args[2].args[1].args[2].args[1])
        @test StaticLint.is_type_of_call_to_getproperty(cst.args[2].args[1].args[2].args[2].args[1])
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end

    let (cst, meta_dict) = parse_and_pass("f(x::Module) = x.parent1")
        @test StaticLint.has_getproperty_method(server.external_env.symbols[:Core][:Module], getenv(server.files[""], server))
        @test !StaticLint.has_getproperty_method(server.external_env.symbols[:Core][:DataType], getenv(server.files[""], server))
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
    let (cst, meta_dict) = parse_and_pass("f(x::DataType) = x.sdf")
        @test !isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
end

@testitem "using of self" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    let (cst, meta_dict) = parse_and_pass("""
    function f(a::rand) a end
    function f(a::Base.rand) a end
    function f(a::Int) a end
    Base.Int32(x) = 1
    function f(a::Int32) a end
    Base.fetch(x) = 1
    function f(a::fetch) a end
    """)
        @test errorof(cst.args[1].args[1].args[2]) === StaticLint.InvalidTypeDeclaration
        @test errorof(cst.args[2].args[1].args[2]) === StaticLint.InvalidTypeDeclaration
        @test errorof(cst.args[3].args[1].args[2]) === nothing
        @test errorof(cst.args[5].args[1].args[2]) === nothing
        @test errorof(cst.args[7].args[1].args[2]) === StaticLint.InvalidTypeDeclaration
    end

    @testset "interpret @eval" begin # e.g. `using StaticLint: StaticLint`
        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval adf = 1
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test !StaticLint.scopehasbinding(scopeof(cst[1]), "adf")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval a,d,f = 1,2,3
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "a")
            @test StaticLint.scopehasbinding(scopeof(cst), "d")
            @test StaticLint.scopehasbinding(scopeof(cst), "f")
            @test !StaticLint.scopehasbinding(scopeof(cst[1]), "a")
            @test !StaticLint.scopehasbinding(scopeof(cst[1]), "d")
            @test !StaticLint.scopehasbinding(scopeof(cst[1]), "f")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let
        @eval a = 1
        @eval d = 2
        @eval f = 3
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "a")
            @test StaticLint.scopehasbinding(scopeof(cst), "d")
            @test StaticLint.scopehasbinding(scopeof(cst), "f")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "a")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "d")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "f")
        end

        let (cst, meta_dict) = parse_and_pass("""
    let name = :adf
        @eval \$name = 1
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "adf")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let name = [:adf]
        @eval \$name = 1
    end
    """)
            @test !StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "adf")
        end

        let (cst, meta_dict) = parse_and_pass("""
    for name = [:adf, :asdf, :asdfs]
        @eval \$name = 1
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test StaticLint.scopehasbinding(scopeof(cst), "asdf")
            @test StaticLint.scopehasbinding(scopeof(cst), "asdfs")
        end
        let (cst, meta_dict) = parse_and_pass("""
    for name = (:adf, :asdf, :asdfs)
        @eval \$name = 1
    end
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test StaticLint.scopehasbinding(scopeof(cst), "asdf")
            @test StaticLint.scopehasbinding(scopeof(cst), "asdfs")
        end
        let (cst, meta_dict) = parse_and_pass("""
    let name = :adf
        @eval \$name(x) = 1
    end
    adf(1,2)
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "adf")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "adf")
            @test errorof(cst.args[2]) === StaticLint.IncorrectCallArgs
        end
        let (cst, meta_dict) = parse_and_pass("""
    for name in (:sdf, :asdf)
        @eval \$name(x) = 1
    end
    sdf(1,2)
    """)
            @test StaticLint.scopehasbinding(scopeof(cst), "sdf")
            @test !StaticLint.scopehasbinding(scopeof(cst.args[1]), "asdf")
            @test errorof(cst[2]) === StaticLint.IncorrectCallArgs
        end
    end
end

@testitem "check for " setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    let (cst, meta_dict) = parse_and_pass("""
    module A
    module B
    struct T end
    end
    using .B
    function T(t::B.T)
    end
    end
    """)
        @test bindingof(cst.args[1].args[3].args[3]) != refof(cst.args[1].args[3].args[3].args[1].args[2].args[2].args[2].args[1])
        @test bindingof(cst.args[1].args[3].args[1].args[3].args[1]) == refof(cst.args[1].args[3].args[3][2][3][3][3][1])
    end
end
@testitem "misc" setup=[shared_static_lint] begin # e.g. `using StaticLint: StaticLint`
    let (cst, meta_dict) = parse_and_pass("""
    import Base: Bool
    function Bool(x) x end
    ^(z::Complex, n::Bool) = n ? z : one(z)
    """)
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
    let (cst, meta_dict) = parse_and_pass("""
    (rand(d::Vector{T})::T) where {T}  =  1
    """)
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
end
@testitem "Test self" setup=[shared_static_lint] begin
    empty!(server.files)
    f = StaticLint.loadfile(server, joinpath(@__DIR__, "..", "src", "StaticLint.jl"))
    StaticLint.semantic_pass(f)
end

let (cst, meta_dict) = parse_and_pass("""
using Base:@irrational
@irrational ase 0.45343 π
ase
""")
    @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
end

@testitem "quoted getfield" setup=[shared_static_lint] begin
    let (cst, meta_dict) = parse_and_pass("Base.:sin")
        @test isempty(StaticLint.collect_hints(cst[1], getenv(server.files[""], server)))
    end
    @testset "quoted getfield" begin
        let (cst, meta_dict) = parse_and_pass("Base.:sin")
            @test isempty(StaticLint.collect_hints(cst.args[1], getenv(server.files[""], server)))
        end

        let (cst, meta_dict) = parse_and_pass("""
    sin(1,1)
    Base.sin(1,1)
    Base.:sin(1,1)
    """)
            @test errorof(cst.args[1]) === errorof(cst.args[2]) === errorof(cst.args[3])
        end
    end
    @testset "overloading" begin
# overloading of a function that happens to be exported into the current scope.
        let (cst, meta_dict) = parse_and_pass("""
    Base.sin() = nothing
    sin()
    """)
            @test haskey(cst.meta.scope.names, "sin") #
            @test first(cst.meta.scope.names["sin"].refs) == server.external_env.symbols[:Base][:sin]
            @test isempty(StaticLint.collect_hints(cst[2], getenv(server.files[""], server)))
        end
# As above but for user defined function
        let (cst, meta_dict) = parse_and_pass("""
    module M
    f(x) = nothing
    end
    M.f(a,b) = nothing
    M.f(1,2)
    """)
            @test !haskey(cst.meta.scope.names, "f")
            @test errorof(cst.args[3]) === nothing
        end

        let (cst, meta_dict) = parse_and_pass("""
sin(1,1)
Base.sin(1,1)
Base.:sin(1,1)
""")
            @test errorof(cst[1]) === errorof(cst[2]) === errorof(cst[3])
        end
    end
# Non exported function is overloaded
    let (cst, meta_dict) = parse_and_pass("""
    Base.argtail() = nothing
    Base.argtail()
    """)
        @test !haskey(cst.meta.scope.names, "argtail") #
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
# As above but for user defined function
    let (cst, meta_dict) = parse_and_pass("""
    module M
    ff(x) = nothing
    end
    M.ff() = nothing
    M.ff()
    """)
        @test !haskey(cst.meta.scope.names, "ff")
        @test isempty(StaticLint.collect_hints(cst[3], getenv(server.files[""], server)))
    end

    let (cst, meta_dict) = parse_and_pass("""
    import Base: argtail
    Base.argtail() = nothing
    Base.argtail()
    argtail()
    """)
        @test cst.meta.scope.names["argtail"] === bindingof(cst[1][2][3][1])
        @test StaticLint.get_method(cst.meta.scope.names["argtail"].refs[2]) isa CSTParser.EXPR
        @test cst[3][1][3][1].meta.ref == cst.meta.scope.names["argtail"]
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
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
    @test errorof(cst.args[6].args[1]) === JuliaWorkspaces.StaticLint.InappropriateUseOfLiteral
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
        cst, meta_dict = parse_and_pass("""h()::@NamedTuple{a::Int,b::String} = (a=1, b = "s")""")
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
    end
end

@testitem "Base.@kwdef" setup=[shared_static_lint] begin
    if isdefined(Base, Symbol("@kwdef"))
        cst, meta_dict = parse_and_pass("""
        Base.@kwdef struct T
            arg = 1
        end""")
        @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
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

    @test StaticLint.hasref(lhs)
    @test StaticLint.hasref(rhsid)
end

@testitem "too many dots" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
        module A
            import ....X
        end
        """)
    errs = StaticLint.collect_hints(cst, getenv(server.files[""], server))
    @test any(err -> StaticLint.errorof(err[2]) === StaticLint.RelativeImportTooManyDots, errs)
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
    cst, meta_dict = parse_and_pass("""
    function f(arg; kw = arg)
        arg * kw
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
end

@testitem "handle shadow bindings on method" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    f(x) = 1
    g = f
    g(1)
    """)
    @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
end

@testitem "documented symbol resolving" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    \"\"\"
    doc
    \"\"\"
    func
    func(x) = 1
    """)
    @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))

    cst, meta_dict = parse_and_pass("""
    \"\"\"
    doc
    \"\"\"
    func(a,b)::Int
    func(x, b) = 1
    """)
    @test isempty(StaticLint.collect_hints(cst, getenv(server.files[""], server)))
end

@testitem "unused bindings" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    function f(arg, arg2)
        arg*arg2
        arg3 = 1
    end
    """)
    @test errorof(cst[1][3][2][1]) !== nothing

    cst, meta_dict = parse_and_pass("""
    function f()
        arg = false
        while arg
            if arg
            end
            arg = true
        end
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    function f(arg)
        arg
        while true
            arg = 1
        end
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    function f(arg)
        arg
        while true
            while true
                arg = 1
            end
        end
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    function f()
        (a = 1, b = 2)
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    function f()
        arg = 0
        if 1
            while true
                arg = 1
            end
        end
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
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
    cst, meta_dict = parse_and_pass("""
    struct T{S,R} where S <: Number where R <: Number
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    struct T{S,R} <: Number where S <: Number
        x::S
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
end

@testitem "where type param infer" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    foo(u::Union) = 1
    function foo(x::T) where {T}
        x + foo(T)
    end
    """)

    @test cst[2].meta.scope.names["T"].type isa SymbolServer.DataTypeStore
    @test isempty(StaticLint.collect_hints(cst, server))
end

@testitem "where type param infer" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    bar(u::Union) = 1
    foo(x::T, y::S, q::V) where {T, S <: V} where {V <: Integer} = x + y + q + bar(S) + bar(T) + bar(V)
    """)

    @test cst[2].meta.scope.names["T"].type isa SymbolServer.DataTypeStore
    @test cst[2].meta.scope.names["S"].type isa SymbolServer.DataTypeStore
    @test cst[2].meta.scope.names["V"].type isa SymbolServer.DataTypeStore
    @test isempty(StaticLint.collect_hints(cst, server))
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
    cst, meta_dict = parse_and_pass("""function foo(a; p) a+p end
    foo(1, p = true)""")
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""function foo(a; p) a end
    foo(1, p = true)""")
    @test cst[1][2][4][1].meta.error != false

    cst, meta_dict = parse_and_pass("""function foo(a; p::Bool) a+p end
    foo(1, p = true)""")
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""function foo(a; p::Bool) a end
    foo(1, p = true)""")
    @test cst[1][2][4][1].meta.error != false
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
    cst, meta_dict = parse_and_pass("""
    module Sup
    function myfunc end
    module SubA
    import ..myfunc
    myfunc(x::Int) = println("hello Int: ", x) # Cannot define function ; it already has a value.
    end # module

    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

end


@testitem "macrocall bindings: #2187" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    function f(url = 1, file = 1)
        @info "Downloading" source = url dest = file
        return nothing
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
end

@testitem "aliased import: #974" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    const CC = Core.Compiler
    import .CC: div
    """)
    @test isempty(StaticLint.collect_hints(cst, server))

    cst, meta_dict = parse_and_pass("""
    const C = Core
    import .C: div
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
end

@testitem "kwarg refs" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb; ccc)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in cst.args[1].meta.scope.names
        @test length(b.refs) == 2
    end

    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb::Foo; ccc::Bar)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in cst.args[1].meta.scope.names
        @test length(b.refs) == 2
    end

    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb=1; ccc=2)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in cst.args[1].meta.scope.names
        @test length(b.refs) == 2
    end
    cst, meta_dict = parse_and_pass("""
    function foo(aaa, bbb::Foo=1; ccc::Bar=2)
        return aaa + bbb + ccc
    end
    """)
    for (_, b) in cst.args[1].meta.scope.names
        @test length(b.refs) == 2
    end
end

@testitem "iteration over 1:length(...)" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("arr = []; [1 for _ in 1:length(arr)]")
    @test isempty(StaticLint.collect_hints(cst, server))
    cst, meta_dict = parse_and_pass("arr = []; [arr[i] for i in 1:length(arr)]")
    @test length(StaticLint.collect_hints(cst, server)) == 2
    cst, meta_dict = parse_and_pass("arr = []; [i for i in 1:length(arr)]")
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    arr = []
    for _ in 1:length(arr)
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
    cst, meta_dict = parse_and_pass("""
    arr = []
    for i in 1:length(arr)
        arr[i]
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 2
    cst, meta_dict = parse_and_pass("""
    arr = []
    for i in 1:length(arr)
        println(i)
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    arr = []
    for _ in 1:length(arr), _ in 1:length(arr)
    end
    """)
    @test isempty(StaticLint.collect_hints(cst, server))
    cst, meta_dict = parse_and_pass("""
    arr = []
    for i in 1:length(arr), j in 1:length(arr)
        arr[i] + arr[j]
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 4
    cst, meta_dict = parse_and_pass("""
    arr = []
    for i in 1:length(arr), j in 1:length(arr)
        println(i + j)
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    function f(arr::Vector)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    function f(arr::Array)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    function f(arr::Matrix)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    function f(arr::Array{T,N}) where T where N
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 0

    cst, meta_dict = parse_and_pass("""
    function f(arr::AbstractArray)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 4

    cst, meta_dict = parse_and_pass("""
    function f(arr)
        for i in 1:length(arr), j in 1:length(arr)
            arr[i] + arr[j]
        end
    end
    """)
    @test length(StaticLint.collect_hints(cst, server)) == 4
end

@testitem "assigned but not used with loops" setup=[shared_static_lint] begin
    cst, meta_dict = parse_and_pass("""
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
    @test isempty(StaticLint.collect_hints(cst, server))
    cst, meta_dict = parse_and_pass("""
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
    @test isempty(StaticLint.collect_hints(cst, server))
end

@testitem "macro definition" setup=[shared_static_lint] begin
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
    for r in m.meta.ref.refs
        m = StaticLint.get_method(r)
        if m !== nothing
            push!(methods, m)
        end
    end

    @test !isempty(methods)
end

@testitem "correctly mark public bindings" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof

    if VERSION >= v"1.12"
        let (cst, meta_dict) = parse_and_pass("""
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
end

@testitem "IncludeLoop and DuplicateInclude" setup=[shared_static_lint] begin
    # Test duplicate include: main.jl includes a.jl twice
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), "x = 1\n")
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        include("a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.DuplicateInclude, hints)
        @test !any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
    end

    # Test circular include: a.jl includes b.jl, b.jl includes a.jl
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), """
        include("b.jl")
        """)
        write(joinpath(dir, "b.jl"), """
        include("a.jl")
        """)
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
    end
    # Test circular include: a.jl includes b.jl, b.jl includes a.jl
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), """
        include("b.jl")
        """)
        write(joinpath(dir, "b.jl"), """
        include("./a.jl")
        """)
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
        _, hints = StaticLint.lint_file(joinpath(dir, "a.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
        _, hints = StaticLint.lint_file(joinpath(dir, "b.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
    end

    # Test self-include: a.jl includes itself
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), """
        include("a.jl")
        """)
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
    end

    # Test no false positive: each file included exactly once
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), "x = 1\n")
        write(joinpath(dir, "b.jl"), "y = 2\n")
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        include("b.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test !any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
        @test !any(h -> errorof(h[1]) === StaticLint.DuplicateInclude, hints)
    end

    # Test normpath: relative paths with .. resolve correctly for includes
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "src", "sub"))
        write(joinpath(dir, "src", "a.jl"), "x = 1\n")
        # include via ../src/a.jl from sub/ should resolve to the same file as src/a.jl
        write(joinpath(dir, "src", "sub", "b.jl"), """
        include("../a.jl")
        """)
        write(joinpath(dir, "src", "main.jl"), """
        include("a.jl")
        include("sub/b.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "src", "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.DuplicateInclude, hints)
        @test !any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
        @test !any(h -> errorof(h[1]) === StaticLint.MissingFile, hints)
    end

    # Test normpath: ./file.jl resolves the same as file.jl
    mktempdir() do dir
        write(joinpath(dir, "a.jl"), "x = 1\n")
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        include("./a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.DuplicateInclude, hints)
        @test !any(h -> errorof(h[1]) === StaticLint.MissingFile, hints)
    end

    # Test normpath: circular include via .. is detected
    mktempdir() do dir
        mkpath(joinpath(dir, "sub"))
        write(joinpath(dir, "a.jl"), """
        include("sub/b.jl")
        """)
        write(joinpath(dir, "sub", "b.jl"), """
        include("../a.jl")
        """)
        write(joinpath(dir, "main.jl"), """
        include("a.jl")
        """)
        s = StaticLint.FileServer()
        _, hints = StaticLint.lint_file(joinpath(dir, "main.jl"), s; gethints=true)
        @test any(h -> errorof(h[1]) === StaticLint.IncludeLoop, hints)
    end
end
