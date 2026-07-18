@testitem "infer_short_function_definition" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("f(arg) = arg")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isfunction(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_empty_function" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("function f end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isfunction(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_struct_datatype" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("struct T end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_mutable_struct_datatype" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("mutable struct T end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_abstract_type_datatype" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("abstract type T end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_primitive_type_datatype" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("primitive type T 8 end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_integer_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("x = 1")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isint(bindingof(cst.args[1].args[1], meta_dict).type)
    end
end

@testitem "infer_float_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("x = 1.0")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isfloat(bindingof(cst.args[1].args[1], meta_dict).type)
    end
end

@testitem "infer_char_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("x = 'c'")
        @test bindingof(cst.args[1].args[1], meta_dict).type === JuliaWorkspaces.StaticLint.CoreTypes.Char
    end
end

@testitem "infer_string_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("x = \"text\"")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isstring(bindingof(cst.args[1].args[1], meta_dict).type)
    end
end

@testitem "infer cross-file constructor through a TreeRef callee" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof, TreeRef
    using JuliaWorkspaces.URIs2: URI
    const DataTypeStore = JuliaWorkspaces.SymbolServer.DataTypeStore

    root = URI("file:///t/src/Root.jl")
    stale = URI("file:///t/src/stale.jl")
    jw = ws_files(
        root => "module Root\nusing Base: PkgId\ninclude(\"stale.jl\")\nend\n",
        stale => "function f(newmods)\n    for M in newmods\n        key = PkgId(M)\n        Base.insert_extension_triggers(key)\n    end\nend\n",
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, stale)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, stale)

    # The `PkgId` callee resolves cross-file to a TreeRef (not a Binding/store).
    pkgid = only(find_identifiers(cst, "PkgId"))
    @test refof(pkgid, fa.meta) isa TreeRef

    # `key = PkgId(M)` must infer `key::PkgId`, not fall back to a by-use guess.
    keyb = find_binding(cst, fa.meta, "key")
    @test keyb !== nothing
    @test keyb.type isa DataTypeStore
    @test occursin("PkgId", string(keyb.type.name))

    # ...and the method call on `key` no longer false-flags.
    @test isempty(fa.diagnostics)
end

@testitem "infer qualified constructor (getfield callee)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    const DataTypeStore = JuliaWorkspaces.SymbolServer.DataTypeStore

    let (cst, meta_dict) = parse_and_pass("function f(m)\n    key = Base.PkgId(m)\n    key\nend\n")
        keyb = find_binding(cst, meta_dict, "key")
        @test keyb !== nothing
        @test keyb.type isa DataTypeStore
        @test occursin("PkgId", string(keyb.type.name))
    end
end

@testitem "infer cross-file type annotation through a TreeRef" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, Binding
    using JuliaWorkspaces.URIs2: URI
    const DataTypeStore = JuliaWorkspaces.SymbolServer.DataTypeStore
    const CST = JuliaWorkspaces.CSTParser

    root = URI("file:///t/src/Root.jl")
    g = URI("file:///t/src/g.jl")
    jw = ws_files(
        root => "module Root\nusing Base: PkgId\ninclude(\"g.jl\")\nend\n",
        g => "g(x::PkgId) = x\n",
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, g)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, g)

    # the `x::PkgId` arg binding (attached to the `::` decl) narrows to PkgId,
    # even though the annotation resolved cross-file to a TreeRef.
    argdecl = find_first(x -> CST.isdeclaration(x) && bindingof(x, fa.meta) isa Binding, cst)
    @test argdecl !== nothing
    argb = bindingof(argdecl, fa.meta)
    @test argb.type isa DataTypeStore
    @test occursin("PkgId", string(argb.type.name))
end

@testitem "method through a const type alias with an unresolved base" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: URI

    # `const A = Foo{Int}` is a type alias (a `curly` is always a type
    # application), so `A(x) = ...` is a valid constructor definition — even when
    # the base `Foo` doesn't resolve to a datatype store (e.g. a foreign
    # parametric like Revise's `OrderedDict{Module,ExprsInfos}`). It must not
    # false-flag "Cannot define function ; it already has a value."
    root = URI("file:///t/src/M.jl")
    f = URI("file:///t/src/t.jl")
    jw = ws_files(
        root => "module M\ninclude(\"t.jl\")\nend\n",
        f => "const A = Foo{Int}\nA(x::Int) = A()\n",
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f)
    @test !any(d -> occursin("Cannot define function", d.message), fa.diagnostics)
end

@testitem "infer_module" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("module A end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.ismodule(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_baremodule" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("baremodule A end")
        @test JuliaWorkspaces.StaticLint.CoreTypes.ismodule(bindingof(cst.args[1], meta_dict).type)
    end
end

@testitem "infer_struct_function_parameter_type" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
struct T end
            function f(x::T) x end
            """)
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
        @test JuliaWorkspaces.StaticLint.CoreTypes.isfunction(bindingof(cst.args[2], meta_dict).type)
        @test bindingof(cst.args[2].args[1].args[2], meta_dict).type == bindingof(cst.args[1], meta_dict)
        @test refof(cst.args[2].args[2].args[1], meta_dict) == bindingof(cst.args[2].args[1].args[2], meta_dict)
    end
end

@testitem "infer_struct_with_constructor_overload" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
struct T end
T() = 1
        function f(x::T) x end
        """)
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
        @test JuliaWorkspaces.StaticLint.CoreTypes.isfunction(bindingof(cst.args[3], meta_dict).type)
        @test bindingof(cst.args[3].args[1].args[2], meta_dict).type == bindingof(cst.args[1], meta_dict)
        @test refof(cst.args[3].args[2].args[1], meta_dict) == bindingof(cst.args[3].args[1].args[2], meta_dict)
    end
end

@testitem "infer_variable_struct_instantiation" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("""
        struct T end
        t = T()
        """)
        @test JuliaWorkspaces.StaticLint.CoreTypes.isdatatype(bindingof(cst.args[1], meta_dict).type)
        @test bindingof(cst.args[2].args[1], meta_dict).type == bindingof(cst.args[1], meta_dict)
    end
end

@testitem "infer_qualified_module_import_access" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
module A
module B
x = 1
end
module C
import ..B
B.x
end
        end
        """)
        @test refof(cst.args[1].args[3].args[2].args[3].args[2].args[2].args[1], meta_dict) == bindingof(cst[1].args[3].args[1].args[3].args[1].args[1], meta_dict)
    end
end

@testitem "infer_nested_struct_field_access" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
        struct T0
            x
        end
        struct T1
            field::T0
        end
        function f(arg::T1)
            arg.field.x
        end
        """);
        @test refof(cst.args[3].args[2].args[1].args[1].args[1], meta_dict) == bindingof(cst.args[3].args[1].args[2], meta_dict)
        @test refof(cst.args[3].args[2].args[1].args[1].args[2].args[1], meta_dict) == bindingof(cst.args[2].args[3].args[1], meta_dict)
        @test refof(cst.args[3].args[2].args[1].args[2].args[1], meta_dict) == bindingof(cst.args[1].args[3].args[1], meta_dict)
    end
end

@testitem "infer_raw_string_macro" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof
    let (cst, meta_dict) = parse_and_pass("""raw\"whatever\"""")
        @test refof(cst.args[1].args[1], meta_dict) !== nothing
    end
end

@testitem "infer_custom_macro_string_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
        macro mac_str() end
        mac"whatever"
        """)
        @test refof(cst.args[2].args[1], meta_dict) == bindingof(cst.args[1], meta_dict)
    end
end

@testitem "infer_list_comprehension_variable_reference" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("[i * j for i = 1:10 for j = i:10]")
        @test refof(cst.args[1].args[1].args[1].args[1].args[2].args[2].args[2], meta_dict) == bindingof(cst.args[1].args[1].args[1].args[2].args[1], meta_dict)
    end
end

@testitem "infer_list_comprehension_multiple_iterators" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("[i * j for i = 1:10, j = 1:10 for k = i:10]")
        @test refof(cst.args[1].args[1].args[1].args[1].args[2].args[2].args[2], meta_dict) == bindingof(cst.args[1].args[1].args[1].args[2].args[1], meta_dict)
    end
end

@testitem "infer_module_import_statement" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof
    let (cst, meta_dict) = parse_and_pass("""
        module Reparse
        end
        using .Reparse, CSTParser
        """)
        @test refof(cst.args[2].args[1].args[2], meta_dict).val == bindingof(cst[1], meta_dict)
    end
end

@testitem "infer_module_self_reference" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, refof, scopeof
    let (cst, meta_dict) = parse_and_pass("""
        module A
        A
        end
        """)
        @test scopeof(cst, meta_dict).names["A"] == scopeof(cst.args[1], meta_dict).names["A"]
        @test refof(cst.args[1].args[2], meta_dict) == bindingof(cst.args[1], meta_dict)
        @test refof(cst.args[1].args[3].args[1], meta_dict) == bindingof(cst.args[1], meta_dict)
    end
end

@testitem "error_function_incorrect_call_args" setup=[shared_static_lint] begin
    using JuliaWorkspaces: DynamicIndexingOnly
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
    sin(1,2,3)
    """)
        @test errorof(cst.args[1], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectCallArgs
    end
end

@testitem "error_for_loop_incorrect_iter_specs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        for i in length(1) end
        for i in 1.1 end
        for i in 1 end
        for i in 1:1 end
        """)
        @test errorof(cst.args[1].args[1], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst.args[2].args[1], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst.args[3].args[1], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst.args[4].args[1], meta_dict) === nothing
    end
end

@testitem "error_list_comp_incorrect_iter_specs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        [i for i in length(1) end]
        [i for i in 1.1 end]
        [i for i in 1 end]
        [i for i in 1:1 end]
        """)
        @test errorof(cst[1][2][3], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst[2][2][3], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst[3][2][3], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
        @test errorof(cst[4][2][3], meta_dict) === nothing
    end
end

@testitem "error_int_param_for_loop" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        function f(x::Int)
            for i in x
                println(i)
            end
        end
        """)
        @test errorof(cst[1][3][1][2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
    end
end

@testitem "error_number_param_for_loop" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        function f(x::Number)
            for i in x
                println(i)
            end
        end
        """)
        @test errorof(cst[1][3][1][2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
    end
end

@testitem "error_int_literal_for_loop" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        x = 3
        for i in x
            println(i)
        end
        """)
        @test errorof(cst[2][2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
    end
end

@testitem "error_float_literal_for_loop" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        x = 3.2
        for i in x
            println(i)
        end
        """)
        @test errorof(cst[2][2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
    end
end

@testitem "error_type_annotated_float_for_loop" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    let (cst, meta_dict) = parse_and_pass("""
        x::Float64 = 3.2 * 2
        for i in x
            println(i)
        end
        """)
        @test errorof(cst[2][2], meta_dict) === JuliaWorkspaces.StaticLint.IncorrectIterSpec
    end
end

@testitem "error_nothing_equality_comparison" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    for (cst, meta_dict) in parse_and_pass.(["a == nothing", "nothing == a"])
        @test errorof(cst[1][2], meta_dict) === JuliaWorkspaces.StaticLint.NothingEquality
    end
end

@testitem "error_nothing_inequality_comparison" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: errorof
    for (cst, meta_dict) in parse_and_pass.(["a != nothing", "nothing != a"])
        @test errorof(cst[1][2], meta_dict) === JuliaWorkspaces.StaticLint.NothingNotEq
    end
end

@testitem "infer_struct_field_in_refs" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("""
        struct Graph
            children:: T
        end

        function test()
            g = Graph()
            f = g.children
        end""")
        @test cst.args[2].args[2].args[2].args[2].args[2].args[1] in bindingof(cst.args[1].args[3].args[1], meta_dict).refs
    end
end

@testitem "infer_special_source_module_variables" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: refof
    let (cst, meta_dict) = parse_and_pass("""
        __source__
        __module__
        macro m()
            __source__
            __module__
        end""")
        @test refof(cst[1], meta_dict) === nothing
        @test refof(cst[2], meta_dict) === nothing
        @test refof(cst[3][3][1], meta_dict) !== nothing
        @test refof(cst[3][3][2], meta_dict) !== nothing
    end
end

@testitem "infer_destructuring_with_type_info" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, getmeta
    let (cst, meta_dict) = parse_and_pass("""
        struct Foo
            x::DataType
            y::Float64
        end
        (;x, y) = Foo(1,2)
        x
        y
        """)
        mx = getmeta(cst.args[3], meta_dict)
        @test mx.ref.type.name.name.name == :DataType
        my = getmeta(cst.args[4], meta_dict)
        @test my.ref.type.name.name.name == :Float64
    end
end

@testitem "typed tuple-destructure arg infers element types positionally" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof, headof, Binding
    CSTParser = JuliaWorkspaces.CSTParser
    walk(f, x) = (f(x); x.args !== nothing && foreach(a -> walk(f, a), x.args))

    # `(a, b)::Tuple{T1, T2}` (e.g. Revise's
    # `location_string((file, line)::Tuple{AbstractString, Any},)`) must give each
    # element its POSITIONAL parameter type, not the whole `Tuple{...}` type.
    let (cst, meta_dict) = parse_and_pass("""
        location_string((file, line)::Tuple{AbstractString, Any},) = abspath(file)
        """)
        types = Dict{String,Any}()
        walk(cst) do x
            if headof(x) === :IDENTIFIER
                b = bindingof(x, meta_dict)
                b isa Binding && b.type !== nothing && (types[CSTParser.valof(x)] = b.type)
            end
        end
        @test types["file"].name.name.name == :AbstractString
        @test types["line"].name.name.name == :Any
    end
end

@testitem "bounded Vararg{T,N} matching (#422)" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: func_nargs, match_method, ExternalEnv, errorof, IncorrectCallArgs
    using JuliaWorkspaces.SymbolServer: MethodStore, FakeTypeName, FakeTypeofVararg, VarRef, EnvStore

    int = FakeTypeName(VarRef(VarRef(nothing, :Core), :Int64), Any[])
    any_t = FakeTypeName(VarRef(VarRef(nothing, :Core), :Any), Any[])
    mk(sig) = MethodStore(:f, :M, "/tmp/M.jl", Int32(1), sig, Symbol[], any_t)

    m_bound = mk(Pair{Any,Any}[:x => FakeTypeofVararg(int, 3)])
    m_unb   = mk(Pair{Any,Any}[:x => FakeTypeofVararg(int)])
    m_pref  = mk(Pair{Any,Any}[:p => int, :x => FakeTypeofVararg(int, 2)])

    # func_nargs: bounded → exact, unbounded → typemax.
    @test func_nargs(m_bound) == (3, 3,            Symbol[], false)
    @test func_nargs(m_unb)   == (0, typemax(Int), Symbol[], false)
    @test func_nargs(m_pref)  == (3, 3,            Symbol[], false)

    md = Dict{UInt64,JuliaWorkspaces.StaticLint.Meta}()
    store = EnvStore()
    mm(args, m) = match_method(Any[args...], Any[], m, store, md)

    @test mm((),                   m_bound) == false
    @test mm((int, int),           m_bound) == false
    @test mm((int, int, int),      m_bound) == true
    @test mm((int, int, int, int), m_bound) == false

    @test mm((),                        m_unb) == true
    @test mm((int, int),                m_unb) == true
    @test mm((int, int, int, int, int), m_unb) == true

    @test mm((int,),               m_pref) == false
    @test mm((int, int, int),      m_pref) == true
    @test mm((int, int, int, int), m_pref) == false

    # Full lint pipeline (EXPR path): bounded arity mismatches flag, matching
    # arities and unbounded varargs stay clean.
    for (src, expected) in [
        ("f(x::Vararg{Int,3}) = x\nf(1,2,3)"   => nothing),
        ("f(x::Vararg{Int,3}) = x\nf(1,2)"     => IncorrectCallArgs),
        ("f(x::Vararg{Int,3}) = x\nf()"        => IncorrectCallArgs),
        ("f(x::Vararg{Int,3}) = x\nf(1,2,3,4)" => IncorrectCallArgs),
        ("f(x::Vararg{Int,0}) = x\nf()"        => nothing),
        ("f(x::Vararg{Int,0}) = x\nf(1)"       => IncorrectCallArgs),
        ("f(x::Int...)        = x\nf(1,2,3)"   => nothing),
        ("h(p::Int, x::Vararg{Int,2}) = (p,x)\nh(1,2,3)" => nothing),
        ("h(p::Int, x::Vararg{Int,2}) = (p,x)\nh(1)"     => IncorrectCallArgs),
    ]
        cst, meta_dict = parse_and_pass(src)
        @test errorof(cst.args[2], meta_dict) === expected
    end
end
