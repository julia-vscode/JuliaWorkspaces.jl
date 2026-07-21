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

@testitem "method matching through a const type alias" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: URI

    # A `::Alias` arg annotation, where `Alias` is a `const` type alias (parametric
    # `const IntDict = Dict{Int,Int}` or not `const MyDict = Dict`), must narrow to
    # the aliased datatype so calls on the arg (`length(x)`) match. Previously the
    # arg took the opaque alias binding (type `DataType`, no supertype chain) and
    # every method call false-flagged "No method matching".
    root = URI("file:///t/src/M.jl")
    f = URI("file:///t/src/t.jl")
    jw = ws_files(
        root => "module M\ninclude(\"t.jl\")\nend\n",
        f => """
        const MyDict = Dict
        const IntDict = Dict{Int,Int}
        f(x::IntDict) = length(x)
        f(x::MyDict) = length(x)
        f(x::Dict) = length(x)
        """,
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f)
    @test !any(d -> occursin("No method matching", d.message), fa.diagnostics)
end

@testitem "narrow through a const alias whose base is cross-file/external" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces.StaticLint: bindingof, Binding, CoreTypes
    using JuliaWorkspaces.CSTParser: CSTParser
    const DataTypeStore = JuliaWorkspaces.SymbolServer.DataTypeStore

    # A `const Alias = T` whose base `T` is only visible cross-file / from another
    # module resolves per-file to an `:external_symbol` TreeRef (not a local
    # Binding/store). The alias must still follow that TreeRef to the real
    # datatype — both the bare form (`const PA = PkgId`) and the parametric form
    # (`const PAV = Vector{PkgId}`) — so `::Alias` args narrow and calls on them
    # don't false-flag. Uses `Base: PkgId` (always available in the test env).
    root = URI("file:///t/src/M.jl")
    f = URI("file:///t/src/t.jl")
    jw = ws_files(
        root => "module M\nusing Base: PkgId\ninclude(\"t.jl\")\nend\n",
        f => "const PA = PkgId\nconst PAV = Vector{PkgId}\nf(x::PA) = x.name\ng(x::PAV) = length(x)\n",
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, f)

    argtype(name) = begin
        t = nothing
        find_first(cst) do x
            if CSTParser.isdeclaration(x) && length(x.args) >= 2 &&
                    JuliaWorkspaces.StaticLint.isidentifier(x.args[2]) &&
                    CSTParser.valof(x.args[2]) == name && bindingof(x, fa.meta) isa Binding
                t = bindingof(x, fa.meta).type
                return true
            end
            false
        end
        t
    end

    # bare alias → the real PkgId datatype
    tpa = argtype("PA")
    @test tpa isa DataTypeStore && occursin("PkgId", string(tpa.name))
    # parametric alias → the container datatype (Array)
    @test argtype("PAV") isa DataTypeStore
    # `x.name` (a real PkgId field) and `length(::Vector)` must not false-flag
    @test !any(d -> occursin("No method matching", d.message) ||
                    occursin("has no field", d.message), fa.diagnostics)
end

@testitem "const alias with an unresolvable base does not false-flag calls" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: URI

    # When an alias's base can't be resolved at all (undefined name), the arg must
    # read as `Any` (type left unset) rather than the opaque alias binding — a
    # broken supertype chain would spuriously fail method matching. The bad base
    # is still reported as a missing reference; the method call must not be. Covers
    # both the bare (`const B2 = Undef`) and parametric (`const B1 = Undef{Int}`)
    # forms.
    root = URI("file:///t/src/M.jl")
    f = URI("file:///t/src/t.jl")
    jw = ws_files(
        root => "module M\ninclude(\"t.jl\")\nend\n",
        f => "const B1 = NoSuchType{Int}\nf(x::B1) = length(x)\nconst B2 = AlsoMissing\ng(x::B2) = length(x)\n",
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f)
    @test !any(d -> occursin("No method matching", d.message), fa.diagnostics)
    # the genuinely-broken bases are still surfaced
    @test any(d -> occursin("Missing reference", d.message), fa.diagnostics)
end

@testitem "local shadow of a global function is not checked against the global" setup=[shared_static_lint] begin
    using JuliaWorkspaces.URIs2: URI

    # A local closure or parameter that shadows a module-level function fully
    # replaces it — its method set is exactly its own, so calls must be checked
    # against the local, not the global's (cross-file) arity. Previously the
    # tree-arity gate keyed on the NAME and false-flagged the shadowed call.
    root = URI("file:///t/src/M.jl")
    f = URI("file:///t/src/t.jl")
    jw = ws_files(
        root => "module M\ninclude(\"t.jl\")\nend\n",
        f => """
        foo(a, b) = a + b
        function bar()
            foo(a) = a
            foo(1)
        end
        function bar(foo)
            foo(1)
        end
        """,
    )
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, root, f)
    @test !any(d -> occursin("No method matching", d.message), fa.diagnostics)

    # ...but a genuinely-wrong call to the (unshadowed) global still flags.
    g = URI("file:///t/src/g.jl")
    jw2 = ws_files(
        root => "module M\ninclude(\"g.jl\")\nend\n",
        g => "foo(a, b) = a + b\nbaz() = foo(1)\n",
    )
    fa2 = JuliaWorkspaces.derived_file_analysis(jw2.runtime, root, g)
    @test any(d -> occursin("No method matching", d.message), fa2.diagnostics)

    # A genuinely-wrong call to the LOCAL reports the local's arity, not the
    # shadowed global's (the message must not quote the global's 2 args).
    h = URI("file:///t/src/h.jl")
    jw3 = ws_files(
        root => "module M\ninclude(\"h.jl\")\nend\n",
        h => "foo(a, b) = a + b\nfunction bar()\n    foo(a) = a\n    foo(1, 2, 3)\nend\n",
    )
    fa3 = JuliaWorkspaces.derived_file_analysis(jw3.runtime, root, h)
    d = only(filter(x -> occursin("No method matching", x.message), fa3.diagnostics))
    @test occursin("Expected 1 argument", d.message) && occursin("got 3", d.message)
end

@testitem "infer property-destructure loop variable field types" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: CoreTypes
    # `for (; a, b) in coll` must infer each variable's OWN field type from the
    # element type of `coll`, not the whole element type for every variable
    # (Revise's `for (; reeval, mod, exs_infos, …) in reeval_infos`).
    let (cst, meta_dict) = parse_and_pass(
            "struct RI\n    a::Int\n    b::String\nend\nris = RI[]\nfor (; a, b) in ris\n    a\n    b\nend\n")
        ba = find_binding(cst, meta_dict, "a")
        bb = find_binding(cst, meta_dict, "b")
        @test ba !== nothing && CoreTypes.isint(ba.type)
        @test bb !== nothing && CoreTypes.isstring(bb.type)
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
