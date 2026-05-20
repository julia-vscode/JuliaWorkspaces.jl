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

@testitem "infer_string_literal" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: bindingof
    let (cst, meta_dict) = parse_and_pass("x = \"text\"")
        @test JuliaWorkspaces.StaticLint.CoreTypes.isstring(bindingof(cst.args[1].args[1], meta_dict).type)
    end
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
