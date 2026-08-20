@testitem "inventory types: structural equality across separately built instances" begin
    using JuliaWorkspaces: FileInventory, InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule, InventoryOpaqueMacro, InventoryTestItem, ImportSymbol
    using JuliaWorkspaces.URIs2: URI

    make() = FileInventory(
        [InventoryItem(1, 101, "f", String[], :function, "f(x)", String[], String[]),
         InventoryItem(2, 102, "S", String[], :struct, nothing, ["a", "b"], ["M"])],
        [InventoryImport(3, 103, :using, [".", "Sibling"], ImportSymbol[], nothing, ["M"])],
        [InventoryExport(4, 104, :export, ["f"], String[])],
        [InventoryInclude(5, 105, URI("file:///pkg/src/a.jl"), String[])],
        [InventoryModule(6, 106, "M", false, String[])],
        [InventoryOpaqueMacro(7, 107, ["M"])],
        [InventoryTestItem(8, 108, :testitem, "t", "#testitem#t#1", String[])],
    )

    a = make()
    b = make()
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)

    c = FileInventory(
        [InventoryItem(1, 101, "g", String[], :function, "g(x)", String[], String[])],
        a.imports, a.exports, a.includes, a.modules, a.opaque_macros, a.testitems)
    @test !isequal(a, c)

    # The test-item vector participates in the equality contract too.
    d = FileInventory(a.items, a.imports, a.exports, a.includes, a.modules, a.opaque_macros,
        [InventoryTestItem(8, 108, :testitem, "other", "#testitem#other#1", String[])])
    @test !isequal(a, d)
end

@testitem "inventory walker: visit order, ids, module nesting, doc unwrap, offsets" begin
    using JuliaWorkspaces: _foreach_toplevel_item
    using JuliaWorkspaces: CSTParser

    src = """
    f() = 1
    \"\"\"
    docs for g
    \"\"\"
    g(x) = x
    module M
    h() = 2
    module Inner
    k() = 3
    end
    end
    w() = 4
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset, _segment
        push!(visited, (order=order, id=id, parent=copy(parent_module), offset=offset,
                        ismod=CSTParser.defines_module(x)))
    end

    # 7 item-like nodes: f, g (unwrapped), M, h, Inner, k, w — pre-order.
    # `order` is the dense visit sequence; `id` is only required to identify a
    # statement uniquely within the file.
    @test [v.order for v in visited] == collect(1:7)
    @test allunique([v.id for v in visited])
    @test visited[1].parent == String[]          # f
    @test visited[2].parent == String[]          # g (doc-unwrapped)
    @test visited[3].ismod                       # M itself, at top level
    @test visited[3].parent == String[]
    @test visited[4].parent == ["M"]             # h
    @test visited[5].ismod                       # Inner
    @test visited[5].parent == ["M"]
    @test visited[6].parent == ["M", "Inner"]    # k
    @test visited[7].parent == String[]          # w

    # Offsets point at the actual item, not the doc wrapper: the byte at g's
    # offset begins the text "g(x)".
    g_off = visited[2].offset
    @test src[g_off + 1] == 'g'
    # And f's offset is 0.
    @test visited[1].offset == 0

    # Nested-module children: offsets must account for the module keyword
    # (trivia[1]) — regression guard for the args[1]-vs-trivia[1] fix.
    @test src[visited[4].offset + 1] == 'h'   # h inside M
    @test src[visited[6].offset + 1] == 'k'   # k inside M.Inner
    @test src[visited[7].offset + 1] == 'w'   # sibling after the module block
end

@testitem "inventory walker: if/elseif/else and begin blocks are transparent containers" begin
    using JuliaWorkspaces: _foreach_toplevel_item
    using JuliaWorkspaces: CSTParser

    src = """
    if VERSION > v"1.0"
        compat_f(x) = x
    elseif false
        mid_f(x) = x
    else
        tail_f(x) = x
    end
    begin
        block_f(x) = x
    end
    w() = 4
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset, _segment
        push!(visited, (order=order, id=id, parent=copy(parent_module), offset=offset))
    end

    # The if/elseif/else/begin containers themselves are never visited — only the
    # 4 defined functions plus the trailing `w` are.
    @test [v.order for v in visited] == collect(1:5)
    @test allunique([v.id for v in visited])
    @test all(v -> v.parent == String[], visited)

    # Names use distinct first letters (compat/mid/tail/block/w) so that a
    # regression swapping two branches' offsets can't pass by accident.
    @test src[visited[1].offset + 1] == 'c'   # compat_f, inside the `if` branch
    @test src[visited[2].offset + 1] == 'm'   # mid_f, inside the `elseif` branch
    @test src[visited[3].offset + 1] == 't'   # tail_f, inside the `else` branch
    @test src[visited[4].offset + 1] == 'b'   # block_f, inside the `begin...end` block
    @test src[visited[5].offset + 1] == 'w'   # sibling after everything
end

@testsnippet InventoryWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function inventory_of(src::String; uri=URI("file:///inv/src/F.jl"), extra_files=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        for (u, s) in extra_files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return JuliaWorkspaces.derived_file_inventory(jw.runtime, uri), jw
    end
end

@testitem "inventory: a field modifier does not hide the field" setup=[InventoryWS] begin
    fields_of(src) = only(filter(i -> i.name == "S", inventory_of(src)[1].items)).field_names

    # `@atomic` wraps the declaration in a macrocall whose last argument is the
    # field, in both the bare and the defaulted spelling. Asking `_field_name` about
    # the macrocall itself yielded nothing, so the field was missing entirely.
    @test fields_of("mutable struct S\n    @atomic a::Int\n    b::Int\nend\n") == ["a", "b"]
    @test fields_of("mutable struct S\n    @atomic a::Int = 1\nend\n") == ["a"]
    # A macrocall that leaves no field declaration behind still contributes no name.
    @test fields_of("struct S\n    @weird a, b\n    c::Int\nend\n") == ["c"]
end

@testitem "inventory extraction: kinds, names, signatures, fields" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    f(x) = x + 1
    function g(a::Int, b; kw=1)
        a + b
    end
    macro m(ex) end
    const C = 1
    global G = 2
    global juliadir::String
    global p, q::Int
    x = 3
    abstract type A end
    struct S
        a
        b::Int
        const c
    end
    mutable struct MS
        q
    end
    @enum Color red green
    module M
    inner() = 1
    end
    @somethingunknown foo bar
    """)

    byname(n) = only(filter(i -> i.name == n, inv.items))

    @test byname("f").kind === :function
    @test byname("f").signature == "f(x)"
    @test byname("g").kind === :function
    @test occursin("g(a::Int, b", byname("g").signature)
    # macros are stored WITH the `@` prefix (matching `export @m` spelling)
    @test byname("@m").kind === :macro
    @test isempty(filter(i -> i.name == "m", inv.items))
    @test byname("C").kind === :const
    @test byname("G").kind === :global
    # Declaration-only typed globals (`global x::T`, no assignment) must still be
    # extracted so they enter the module's declared/visible names (Revise's
    # module-wide `global juliadir::String`). The comma form mixes a bare name
    # and a typed declaration.
    @test byname("juliadir").kind === :global
    @test byname("p").kind === :global
    @test byname("q").kind === :global
    @test byname("x").kind === :assignment
    @test byname("A").kind === :abstract
    @test byname("S").kind === :struct
    @test byname("S").field_names == ["a", "b", "c"]
    @test byname("MS").kind === :mutable_struct
    @test byname("Color").kind === :enum
    @test byname("red").kind === :enum_member
    @test byname("green").kind === :enum_member
    @test byname("inner").parent_module == ["M"]
    @test only(filter(m -> m.name == "M", inv.modules)).bare == false
    # `@somethingunknown foo bar` is walked TRANSPARENTLY (bare identifier
    # args produce no items) — `:opaque_macrocall` rows are reserved for the
    # isolated-scope macros (testitem/testset families), see
    # `_is_isolated_scope_macrocall` and the dedicated macrocall testitems.
    @test !any(i -> i.kind === :opaque_macrocall, inv.items)
    @test isempty(filter(i -> i.name in ("foo", "bar"), inv.items))
end

@testitem "inventory extraction: operator and var\"\" macro spellings" setup=[InventoryWS] begin
    # Operator-named macro: `get_name` resolves to the OPERATOR node `+`, so the
    # name must come through `_symbol_name` (not `_item_name`, which drops
    # operators) and then get the `@` prefix like any other macro.
    inv, _ = inventory_of("macro +(a, b) end")
    plus = only(filter(i -> i.kind === :macro, inv.items))
    @test plus.name == "@+"
    @test isempty(filter(i -> i.name == "+", inv.items))

    # `var""`-named macros ARE handled on this CSTParser lineage (probed): the
    # NONSTDIDENTIFIER unwraps through `StaticLint.valofid`. When the var"" text
    # already carries the `@`, it is kept as-is; when it does not, the `@`
    # prefix is added — either way the stored name is the `@`-spelled macro.
    inv2, _ = inventory_of("macro var\"@weird\"() end")
    @test only(filter(i -> i.kind === :macro, inv2.items)).name == "@weird"

    inv3, _ = inventory_of("macro var\"weird\"() end")
    @test only(filter(i -> i.kind === :macro, inv3.items)).name == "@weird"
end

@testitem "inventory extraction: imports, exports, includes" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/a.jl")
    inv, _ = inventory_of("""
    using Base64
    using ..Sibling: helper, other
    import Foo.Bar as FB
    export f, S
    public g
    include("a.jl")
    f() = 1
    """; extra_files=Dict(a_uri => "z() = 1\n"))

    us = inv.imports
    @test any(i -> i.kind === :using && i.path == ["Base64"], us)
    sib = only(filter(i -> "Sibling" in i.path, us))
    @test sib.path == [".", ".", "Sibling"]
    @test sort([s.name for s in sib.symbols]) == ["helper", "other"]
    @test all(s -> s.alias === nothing, sib.symbols)
    fb = only(filter(i -> i.alias !== nothing, us))
    @test fb.kind === :import
    @test fb.path == ["Foo", "Bar"]
    @test fb.alias == "FB"

    @test only(filter(e -> e.kind === :export, inv.exports)).names == ["f", "S"]
    @test only(filter(e -> e.kind === :public, inv.exports)).names == ["g"]

    @test only(inv.includes).target == a_uri
end

@testitem "inventory: testitem-family bodies get their own node" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    top() = 1
    @testitem "one" begin
        include("shared.jl")
        inside() = 2
        using Foo
    end
    @testmodule Setup begin
        setupfn() = 3
    end
    @testsnippet Snip begin
        snipfn() = 4
    end
    """)

    tis = inv.testitems
    @test [(t.kind, t.label) for t in tis] ==
        [(:testitem, "one"), (:testmodule, "Setup"), (:testsnippet, "Snip")]
    @test all(t -> t.parent_module == String[], tis)
    @test allunique([t.segment for t in tis])

    seg = tis[1].segment
    # The body's statements are recorded UNDER the test item, not at file level.
    @test only(filter(i -> i.name == "inside", inv.items)).parent_module == [seg]
    @test only(inv.includes).parent_module == [seg]
    @test only(inv.imports).parent_module == [seg]
    # ...and the enclosing module is untouched.
    @test only(filter(i -> i.name == "top", inv.items)).parent_module == String[]

    # The macrocall still produces its `:opaque_macrocall` usage row in the
    # ENCLOSING module — consumers filter on that and must keep seeing it.
    opaque = filter(i -> i.kind === :opaque_macrocall, inv.items)
    @test sort([i.name for i in opaque]) == ["@testitem", "@testmodule", "@testsnippet"]
    @test all(i -> i.parent_module == String[], opaque)
end

@testitem "inventory: repeated test-item names get distinct segments" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    @testitem "a" begin
        f1() = 1
    end
    @testitem "a" begin
        f2() = 2
    end
    """)
    segs = [t.segment for t in inv.testitems]
    @test length(segs) == 2
    @test allunique(segs)
    @test only(filter(i -> i.name == "f1", inv.items)).parent_module == [segs[1]]
    @test only(filter(i -> i.name == "f2", inv.items)).parent_module == [segs[2]]

    # Identical statements in two bodies must still get distinct ids.
    @test only(filter(i -> i.name == "f1", inv.items)).id !=
          only(filter(i -> i.name == "f2", inv.items)).id
end

@testitem "inventory: an empty test-item body still gets a record" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    @testitem "empty" begin
    end
    """)
    @test length(inv.testitems) == 1
    @test inv.testitems[1].label == "empty"
end

@testitem "inventory: @testset/@safetestset stay opaque" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    @testset "s" begin
        include("shared.jl")
        inner() = 1
    end
    @safetestset "t" begin
        other() = 2
    end
    """)
    @test isempty(inv.testitems)
    # No descent: nothing from either body reaches the inventory.
    @test isempty(filter(i -> i.name in ("inner", "other"), inv.items))
    @test isempty(inv.includes)
    @test sort([i.name for i in filter(i -> i.kind === :opaque_macrocall, inv.items)]) ==
        ["@safetestset", "@testset"]
end

@testitem "inventory: a nested test item nests its segment" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    @testitem "outer" begin
        @testitem "inner" begin
            deep() = 1
        end
    end
    """)
    outer = only(filter(t -> t.label == "outer", inv.testitems))
    inner = only(filter(t -> t.label == "inner", inv.testitems))
    @test outer.parent_module == String[]
    @test inner.parent_module == [outer.segment]
    @test only(filter(i -> i.name == "deep", inv.items)).parent_module ==
        [outer.segment, inner.segment]
end

@testitem "inventory: test items inside a module nest under it" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    module M
    @testitem "t" begin
        f() = 1
    end
    end
    """)
    ti = only(inv.testitems)
    @test ti.parent_module == ["M"]
    @test only(filter(i -> i.name == "f", inv.items)).parent_module == ["M", ti.segment]
end

@testitem "inventory firewall: test-item segments are position-free" setup=[InventoryWS] begin
    # The segment scheme must not encode offsets: an edit ABOVE a test item, or
    # inside one's body, has to leave the inventory `isequal` or every root's
    # module tree would rebuild on each keystroke.
    base(prefix, body) = """
    $prefix
    @testitem "a" begin
        f(x) = $body
    end
    @testitem "a" begin
        g(x) = x
    end
    """

    inv1, _ = inventory_of(base("# comment", "x + 1"))
    inv2, _ = inventory_of(base("# a much longer comment\n# and another line", "x * 2"))
    @test isequal(inv1, inv2)
    @test hash(inv1) == hash(inv2)

    # Renaming a test item IS an API change.
    inv3, _ = inventory_of(replace(base("# comment", "x + 1"), "\"a\" begin\n    f" => "\"b\" begin\n    f"))
    @test !isequal(inv1, inv3)
end

@testitem "testitem segments: keys match the CST's macrocall nodes" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///inv/src/F.jl")
    _, jw = inventory_of("""
    @testitem "a" begin
        f() = 1
    end
    @testmodule B begin
        g() = 2
    end
    """; uri)
    rt = jw.runtime

    segs = JuliaWorkspaces.derived_testitem_segments(rt, uri)
    inv = JuliaWorkspaces.derived_file_inventory(rt, uri)
    @test sort(collect(values(segs))) == sort([t.segment for t in inv.testitems])

    # Keyed on the macrocall EXPRs of the very CST the semantic pass traverses.
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(rt, uri)
    macrocalls = filter(a -> JuliaWorkspaces.CSTParser.ismacrocall(a), cst.args)
    @test length(macrocalls) == 2
    for mc in macrocalls
        @test haskey(segs, UInt64(objectid(mc)))
    end
end

@testitem "inventory firewall: body, comment, and docstring edits compare equal" setup=[InventoryWS] begin
    base(body) = """
    \"\"\"
    docs
    \"\"\"
    function f(x)
        $body
    end
    struct S
        a::Int
    end
    export f
    """

    inv1, _ = inventory_of(base("x + 1"))
    inv2, _ = inventory_of(base("x * 2\n    # a comment"))
    @test isequal(inv1, inv2)
    @test hash(inv1) == hash(inv2)

    # Docstring text is not part of the inventory.
    inv3, _ = inventory_of(replace(base("x + 1"), "docs" => "totally different docs"))
    @test isequal(inv1, inv3)

    # But an API change is.
    inv4, _ = inventory_of(replace(base("x + 1"), "f(x)" => "f(x, y)"))
    @test !isequal(inv1, inv4)
end

@testitem "item positions: ids agree with the inventory and offsets track edits" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    src1 = "f() = 1\ng() = 2\n"
    uri = URI("file:///inv/src/pos.jl")
    inv1, jw = inventory_of(src1; uri=uri)
    pos1 = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)

    f_item = only(filter(i -> i.name == "f", inv1.items))
    g_item = only(filter(i -> i.name == "g", inv1.items))
    @test pos1[f_item.id].offset == 0
    @test src1[pos1[g_item.id].offset + 1] == 'g'

    # A body edit above g shifts g's offset but keeps its id (inventory equal).
    src2 = "f() = 1 + 11111\ng() = 2\n"
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText(src2, "julia")))
    inv2 = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
    @test isequal(inv1, inv2)                       # firewall holds
    pos2 = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)
    @test src2[pos2[g_item.id].offset + 1] == 'g'   # same id, new offset
    @test pos2[g_item.id].offset != pos1[g_item.id].offset
end

@testitem "stable ids: inserting a statement does not renumber later items" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///inv/src/stable.jl")
    src1 = """
    f() = 1
    struct S
        a
    end
    g() = 2
    const K = 3
    """
    inv1, jw = inventory_of(src1; uri=uri)
    ids1 = Dict(i.name => i.id for i in inv1.items)
    orders1 = Dict(i.name => i.order for i in inv1.items)

    # Prepend a `using` line: adds a name to nothing, shifts every later
    # statement's position.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("using Printf\n" * src1, "julia")))
    inv2 = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
    ids2 = Dict(i.name => i.id for i in inv2.items)
    orders2 = Dict(i.name => i.order for i in inv2.items)

    @test keys(ids2) == keys(ids1)
    for n in keys(ids1)
        @test ids2[n] == ids1[n]        # identity is stable
        @test orders2[n] == orders1[n] + 1   # position is not
    end
end

@testitem "stable ids: ids are Int64 on every platform" begin
    using JuliaWorkspaces: InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule, ItemRef, _ItemIdAllocator, _mint_ids!, CSTParser

    # An id packs 46 hash bits with a 16-bit disambiguator, so it needs 62 bits.
    # `Int` is `Int32` on 32-bit platforms and cannot hold that — every id slot
    # must be explicitly `Int64` or those builds fail (and only there).
    for T in (InventoryItem, InventoryImport, InventoryExport, InventoryInclude, InventoryModule)
        @test fieldtype(T, :id) === Int64
        @test fieldtype(T, :order) === Int   # a dense counter; genuinely machine-sized
    end
    @test fieldtype(ItemRef, :id) === Int64

    cst = CSTParser.parse("f() = 1\n", true)
    _, id = _mint_ids!(_ItemIdAllocator(), cst.args[1], String[])
    @test id isa Int64
    @test id > 0
end

@testitem "stable ids: allocator keeps ids unique when a slot is taken" begin
    using JuliaWorkspaces: _ItemIdAllocator, _mint_ids!, CSTParser

    # Two statements with the SAME identity key must still get distinct ids…
    cst = CSTParser.parse("f(x::Int) = 1\nf(x::String) = 2\n", true)
    alloc = _ItemIdAllocator()
    o1, i1 = _mint_ids!(alloc, cst.args[1], String[])
    o2, i2 = _mint_ids!(alloc, cst.args[2], String[])
    @test (o1, o2) == (1, 2)
    @test i1 != i2

    # …and a statement whose computed slot is already taken probes to a free one
    # rather than aliasing onto it (the hash-collision / bucket-overflow path).
    alloc2 = _ItemIdAllocator()
    _, taken = _mint_ids!(alloc2, cst.args[1], String[])
    alloc3 = _ItemIdAllocator()
    push!(alloc3.assigned, taken)
    _, probed = _mint_ids!(alloc3, cst.args[1], String[])
    @test probed != taken
    @test probed == taken + 1
end

@testitem "stable ids: inserting a statement does not invalidate ItemRef consumers" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    Salsa.@derived function probe_declared(rt, root, path)
        return JuliaWorkspaces.derived_module_declared(rt, root, path)
    end

    jw = JuliaWorkspace()
    root_uri = URI("file:///t/src/F.jl")
    body = """
    f() = 1
    g() = 2
    """
    add_file!(jw, TextFile(root_uri, SourceText("module Pkg\n" * body * "end\n", "julia")))
    rt = jw.runtime

    # untraced baseline (see the trace-baseline note in test_module_tree.jl)
    before = probe_declared(rt, root_uri, ["Pkg"])
    @test Set(keys(before)) == Set(["f", "g"])

    # Insert a `using` line above both declarations: it adds a name to nothing
    # and shifts every later statement's position. The declaring ids must be
    # untouched and the consumer must not re-execute at all.
    recv = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(root_uri,
        SourceText("module Pkg\nusing Printf\n" * body * "end\n", "julia")))
    after = TL.with_tracing(() -> probe_declared(rt, root_uri, ["Pkg"]), recv)

    @test after == before
    @test get(recv.counts, "probe_declared", 0) == 0
end

@testitem "stable ids: identity survives signature edits and reordering" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///inv/src/stable2.jl")
    inv1, jw = inventory_of("f(x::Int) = 1\ng(y) = 2\n"; uri=uri)
    f1 = only(filter(i -> i.name == "f", inv1.items))
    g1 = only(filter(i -> i.name == "g", inv1.items))

    # An annotation edit changes the item (its signature/arity) but not its id.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("f(x::String) = 1\ng(y) = 2\n", "julia")))
    inv2 = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
    f2 = only(filter(i -> i.name == "f", inv2.items))
    @test f2.id == f1.id
    @test f2.signature != f1.signature

    # Swapping two differently-named declarations swaps their order, not their ids.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("g(y) = 2\nf(x::Int) = 1\n", "julia")))
    inv3 = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
    f3 = only(filter(i -> i.name == "f", inv3.items))
    g3 = only(filter(i -> i.name == "g", inv3.items))
    @test f3.id == f1.id
    @test g3.id == g1.id
    @test f3.order > g3.order
end

@testitem "stable ids: same-name methods disambiguate; shared-statement ids preserved" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    # Two methods of one generic in one file must still be distinguishable.
    inv, _ = inventory_of("f(x::Int) = 1\nf(x::String) = 2\nh() = 3\n";
                          uri=URI("file:///inv/src/multi.jl"))
    fs = filter(i -> i.name == "f", inv.items)
    @test length(fs) == 2
    @test allunique([i.id for i in fs])

    # Inserting a third method of `f` leaves an unrelated name's id alone.
    inv2, _ = inventory_of("f(x::Float64) = 0\nf(x::Int) = 1\nf(x::String) = 2\nh() = 3\n";
                           uri=URI("file:///inv/src/multi.jl"))
    @test only(filter(i -> i.name == "h", inv2.items)).id ==
          only(filter(i -> i.name == "h", inv.items)).id

    # Records minted from ONE statement still share an id — the module tree's
    # include-first tie-break and `_itemref_is_ambiguous` both depend on it.
    inv3, _ = inventory_of("a, b = 1, 2\n@enum E x y\n";
                           uri=URI("file:///inv/src/shared.jl"))
    @test only(filter(i -> i.name == "a", inv3.items)).id ==
          only(filter(i -> i.name == "b", inv3.items)).id
    enum_ids = [i.id for i in inv3.items if i.kind in (:enum, :enum_member)]
    @test length(enum_ids) == 3 && allunique([enum_ids[1]]) && all(==(enum_ids[1]), enum_ids)

    inv4, _ = inventory_of("const DATA = include(\"data.jl\")\n";
                           uri=URI("file:///inv/src/wrapped.jl"))
    @test only(inv4.items).id == only(inv4.includes).id

    # Every id in a file exercising many branches is distinct.
    inv5, _ = inventory_of("""
    module M
        q() = 1
    end
    abstract type A end
    macro m(x) end
    export q
    using Printf
    z = 1
    """; uri=URI("file:///inv/src/uniq.jl"))
    all_ids = vcat([i.id for i in inv5.items], [i.id for i in inv5.imports],
                   [i.id for i in inv5.exports], [i.id for i in inv5.includes],
                   [i.id for i in inv5.modules])
    @test allunique(all_ids)
end

@testitem "inventory invalidation: body edits backdate, API edits propagate" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # A downstream consumer of the inventory: recomputes only if the
    # inventory VALUE changed (Salsa early-exit on isequal).
    Salsa.@derived function probe_names(rt, uri)
        inv = JuliaWorkspaces.derived_file_inventory(rt, uri)
        return sort([i.name for i in inv.items])
    end

    uri = URI("file:///inv/src/fw.jl")
    src1 = "f(x) = x + 1\ng() = 2\n"
    _, jw = inventory_of(src1; uri=uri)
    rt = jw.runtime
    @test probe_names(rt, uri) == ["f", "g"]

    # Body edit: inventory re-executes (content changed) but its value is
    # equal, so the probe must NOT re-execute.
    recv = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("f(x) = x * 42\ng() = 2\n", "julia")))
    TL.with_tracing(() -> probe_names(rt, uri), recv)
    @test get(recv.counts, "derived_file_inventory", 0) == 1
    @test get(recv.counts, "probe_names", 0) == 0

    # API edit: both re-execute and the probe sees the new name.
    recv2 = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("f(x) = x * 42\nh() = 2\n", "julia")))
    result = TL.with_tracing(() -> probe_names(rt, uri), recv2)
    @test get(recv2.counts, "probe_names", 0) == 1
    @test result == ["f", "h"]
end

@testitem "inventory extraction: if/elseif/else/begin containers are transparent" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/cond_a.jl")
    inv, _ = inventory_of("""
    if VERSION > v"1.0"
        compat_f(x) = x
        include("cond_a.jl")
    elseif false
        elseif_f(x) = x
    else
        else_f(x) = x
    end
    begin
        block_f(x) = x
    end
    """; extra_files=Dict(a_uri => "w() = 1\n"))

    byname(n) = only(filter(i -> i.name == n, inv.items))
    @test byname("compat_f").kind === :function
    @test byname("compat_f").parent_module == String[]
    @test byname("elseif_f").kind === :function
    @test byname("else_f").kind === :function
    @test byname("block_f").kind === :function

    inc = only(inv.includes)
    @test inc.target == a_uri
    @test inc.parent_module == String[]
end

@testitem "inventory extraction: operator names survive in import symbols and export/public" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    using Base: +, map
    import Base: *
    export +, f
    public *
    f() = 1
    """)

    us = inv.imports
    using_stmt = only(filter(i -> i.kind === :using, us))
    @test sort([s.name for s in using_stmt.symbols]) == ["+", "map"]

    import_stmt = only(filter(i -> i.kind === :import, us))
    @test [s.name for s in import_stmt.symbols] == ["*"]

    exp = only(filter(e -> e.kind === :export, inv.exports))
    @test sort(exp.names) == ["+", "f"]
    pub = only(filter(e -> e.kind === :public, inv.exports))
    @test pub.names == ["*"]
end

@testitem "inventory extraction: using X: a as b records the bound alias, not the source name" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    using X: a as b
    using Y: c
    """)

    x_imp = only(filter(i -> "X" in i.path, inv.imports))
    @test x_imp.symbols == [(name="a", alias="b")]

    y_imp = only(filter(i -> "Y" in i.path, inv.imports))
    @test y_imp.symbols == [(name="c", alias=nothing)]
end

@testitem "inventory extraction: _render_sig rethrows InterruptException, swallows other errors" setup=[InventoryWS] begin
    using JuliaWorkspaces: _render_sig
    using JuliaWorkspaces: CSTParser

    struct _BoomInterrupt end
    struct _BoomOther end
    CSTParser.get_sig(::_BoomInterrupt) = throw(InterruptException())
    CSTParser.get_sig(::_BoomOther) = error("boom")

    @test_throws InterruptException _render_sig(_BoomInterrupt())
    @test _render_sig(_BoomOther()) === nothing
end

@testitem "inventory extraction: qualified method extensions get a qualifier, local bindings don't" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    Base.foo(x) = 1
    function Base.Iterators.bar() end
    f(x) = x
    """)

    byname(n) = only(filter(i -> i.name == n, inv.items))
    @test byname("foo").qualifier == ["Base"]
    @test byname("bar").qualifier == ["Base", "Iterators"]
    @test byname("f").qualifier == String[]
end

@testitem "inventory extraction: includet and assignment-wrapped includes" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/inc_a.jl")
    inv, jw = inventory_of("""
    includet("inc_a.jl")
    const DATA = include("inc_a.jl")
    """; extra_files=Dict(a_uri => "z() = 1\n"))

    @test length(inv.includes) == 2
    @test all(i -> i.target == a_uri, inv.includes)
    @test Set(JuliaWorkspaces.derived_includes(jw.runtime, URI("file:///inv/src/F.jl"))) == Set([a_uri])

    @test only(filter(i -> i.name == "DATA", inv.items)).kind === :const
end

@testitem "inventory extraction: include inside a nested module (walker/include-record offset join)" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI

    a_uri = URI("file:///inv/src/nested_inc.jl")
    inv, _ = inventory_of("""
    module Outer
    module Inner
    include("nested_inc.jl")
    end
    end
    """; extra_files=Dict(a_uri => "q() = 1\n"))

    inc = only(inv.includes)
    @test inc.target == a_uri
    @test inc.parent_module == ["Outer", "Inner"]
end

@testitem "inventory extraction: Base.@enum via the qualified-macro path" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    Base.@enum Color red green
    """)

    @test only(filter(i -> i.name == "Color", inv.items)).kind === :enum
    @test only(filter(i -> i.name == "red", inv.items)).kind === :enum_member
    @test only(filter(i -> i.name == "green", inv.items)).kind === :enum_member
end

@testitem "inventory parity: operator-named function definitions" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    +(a, b) = 1
    Base.:+(a, b) = 2
    function Base.:*(a, b) end
    """)
    plus_local = only(filter(i -> i.name == "+" && isempty(i.qualifier), inv.items))
    @test plus_local.kind === :function
    plus_base = only(filter(i -> i.name == "+" && i.qualifier == ["Base"], inv.items))
    @test plus_base.kind === :function
    star = only(filter(i -> i.name == "*", inv.items))
    @test star.qualifier == ["Base"]
end

@testitem "inventory parity: tuple-destructuring assignments" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    a, b = 1, 2
    const x, y = 3, 4
    """)
    for (n, k) in [("a", :assignment), ("b", :assignment), ("x", :const), ("y", :const)]
        item = only(filter(i -> i.name == n, inv.items))
        @test item.kind === k
    end
    # Destructured names share their statement's walker id (position map
    # resolves the shared id to the whole statement).
    @test only(filter(i -> i.name == "a", inv.items)).id ==
          only(filter(i -> i.name == "b", inv.items)).id
end

@testitem "inventory parity: destructuring splats, nested tuples, property forms" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    a, b... = f()
    (x, (y, z)) = w
    (; f1, f2) = cfg
    const c, d... = f()
    const (m, (n, o)) = w
    const (; f3, f4) = cfg
    global e, g... = f()
    (; ta, tb::T) = cfg2
    (tc::T, td) = w2
    ((bx, by)) = w3
    (wa, wb)::T = w4
    ((wc, wd))::T = w5
    """)

    # Splat: both the plain and splatted name are bound, sharing the
    # statement's single walker id.
    a_item = only(filter(i -> i.name == "a", inv.items))
    b_item = only(filter(i -> i.name == "b", inv.items))
    @test a_item.kind === :assignment
    @test b_item.kind === :assignment
    @test a_item.id == b_item.id

    # Nested tuple: all three names bound, sharing the id.
    x_item = only(filter(i -> i.name == "x", inv.items))
    y_item = only(filter(i -> i.name == "y", inv.items))
    z_item = only(filter(i -> i.name == "z", inv.items))
    @test x_item.id == y_item.id == z_item.id

    # Property destructuring (`:tuple` with a `:parameters` child).
    f1_item = only(filter(i -> i.name == "f1", inv.items))
    f2_item = only(filter(i -> i.name == "f2", inv.items))
    @test f1_item.id == f2_item.id
    @test f1_item.kind === :assignment

    # `const` variants of all three shapes.
    for (n, k) in [("c", :const), ("d", :const), ("m", :const), ("n", :const), ("o", :const),
                   ("f3", :const), ("f4", :const)]
        item = only(filter(i -> i.name == n, inv.items))
        @test item.kind === k
    end

    # `global` variant of the splat shape.
    e_item = only(filter(i -> i.name == "e", inv.items))
    g_item = only(filter(i -> i.name == "g", inv.items))
    @test e_item.kind === :global
    @test g_item.kind === :global

    # Typed names (`::`-declared) inside property destructuring and a plain
    # nested tuple: both the bare and the typed name must be bound (the type
    # annotation is dropped, mirroring `mark_binding!`'s terminal case).
    ta_item = only(filter(i -> i.name == "ta", inv.items))
    tb_item = only(filter(i -> i.name == "tb", inv.items))
    @test ta_item.id == tb_item.id
    @test tb_item.kind === :assignment

    tc_item = only(filter(i -> i.name == "tc", inv.items))
    td_item = only(filter(i -> i.name == "td", inv.items))
    @test tc_item.id == td_item.id
    @test tc_item.kind === :assignment

    # Double-bracketed tuple lhs (`((x, y)) = w`): the outer `:brackets` wrap
    # unwraps to the inner tuple.
    bx_item = only(filter(i -> i.name == "bx", inv.items))
    by_item = only(filter(i -> i.name == "by", inv.items))
    @test bx_item.id == by_item.id
    @test bx_item.kind === :assignment

    # Whole-tuple type declaration (`(a, b)::T = w`): the OUTER lhs head is
    # `::` (isdeclaration), wrapping the tuple directly — both names must
    # still be bound (mark_binding!'s own `isdeclaration(x) &&
    # istuple(x.args[1])` case, bindings.jl:132).
    wa_item = only(filter(i -> i.name == "wa", inv.items))
    wb_item = only(filter(i -> i.name == "wb", inv.items))
    @test wa_item.id == wb_item.id
    @test wa_item.kind === :assignment

    # Same, with the tuple additionally bracketed (`((a, b))::T = w`):
    # `::` wraps `:brackets` wraps `:tuple`.
    wc_item = only(filter(i -> i.name == "wc", inv.items))
    wd_item = only(filter(i -> i.name == "wd", inv.items))
    @test wc_item.id == wd_item.id
    @test wc_item.kind === :assignment
end

@testitem "no-op update: identical content re-executes nothing downstream" setup=[InventoryWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL
    using JuliaWorkspaces: module_node

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # A downstream consumer one layer above the inventory (mirrors `probe_tree`
    # in test_module_tree.jl's invalidation testitem), so the assertions below
    # exercise the whole chain: input → inventory → tree → probe.
    Salsa.@derived function probe_noop(rt, uri)
        tree = JuliaWorkspaces.derived_module_tree(rt, uri)
        node = module_node(tree, String[])
        return sort(collect(keys(node.declared)))
    end

    src = "f(x) = x + 1\n"
    uri = URI("file:///inv/src/F.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    rt = jw.runtime

    # NOTE(trace-baseline): this untraced call performs the full computation
    # (inventory → tree → probe) once, so it's already in Salsa's memoized
    # cache before we trace the no-op update below — the pattern relies on
    # this prior full computation to make the "nothing re-executes" assertion
    # meaningful rather than vacuous.
    @test probe_noop(rt, uri) == ["f"]

    recv = CountReceiver()
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText(src, "julia")))
    TL.with_tracing(() -> probe_noop(rt, uri), recv)

    # Byte-identical content never even bumps the Salsa input's revision:
    # `set_input!`'s own "Early Exit Optimization Part 1"
    # (default_storage.jl:438-442) compares the new value against the cached
    # one via `isequal` — `TextFile`/`SourceText` are both `@auto_hash_equals`
    # — and skips the revision bump entirely when they match. So NOTHING
    # downstream re-executes, not even the inventory's own immediate reader:
    # a strictly stronger guarantee than the inventory's own early-cutoff
    # (which needs the input to actually change and the derived VALUE to
    # compare equal afterwards); confirmed empirically via tracing, not
    # merely assumed.
    @test get(recv.counts, "derived_file_inventory", 0) == 0
    @test get(recv.counts, "derived_module_tree", 0) == 0
    @test get(recv.counts, "probe_noop", 0) == 0
end

@testitem "inventory parity: ternaries produce no junk position ids" setup=[InventoryWS] begin
    using JuliaWorkspaces.URIs2: URI
    uri = URI("file:///inv/src/tern.jl")
    # The ternary is a BARE top-level statement (not an assignment rhs) so it
    # actually reaches the walker's `:if` container arm, and its branches are
    # multi-arg calls so that, unguarded, descending into their `.args` mints
    # several junk ids (one per call child) instead of the ternary being
    # treated as a single opaque statement.
    inv, jw = inventory_of("f() = 1\ncond = true\ncond ? h(1, 2) : k(3, 4)\ng() = 2\n"; uri=uri)
    pos = JuliaWorkspaces.derived_item_positions(jw.runtime, uri)
    inv_ids = Set(vcat([i.id for i in inv.items], [m.id for m in inv.modules],
                       [i.id for i in inv.imports], [e.id for e in inv.exports],
                       [i.id for i in inv.includes]))
    # Every position-map id corresponds to a walked statement; none may come
    # from descending into ternary call arguments.
    @test Set(keys(pos)) ⊇ inv_ids
    @test length(pos) <= 4 + 1   # f, cond, the ternary statement itself, g (+1 slack)
end

@testitem "inventory parity audit: module-level bindables are never invisible" setup=[InventoryWS] begin
    # Deliberate exceptions (documented, not extracted): names bound inside
    # scoped constructs (for/while/let/try/function bodies — introduces_scope),
    # opaque macrocalls, and testitem-family macros (deferred per spec).
    inv, _ = inventory_of("""
    if VERSION > v"1.0"
        cond_f(x) = x
        begin
            nested_g() = 1
        end
    elseif false
        alt_f() = 2
    else
        other_f() = 3
    end
    const C = 1
    global G = 2
    +(a, b) = 1
    p, q = 1, 2
    @enum Fruit apple banana
    \"\"\"doc\"\"\"
    struct DocS end
    module M
    m_f() = 1
    end
    """)
    names = Set(i.name for i in inv.items)
    for expected in ["cond_f", "nested_g", "alt_f", "other_f", "C", "G", "+",
                     "p", "q", "Fruit", "apple", "banana", "DocS", "m_f"]
        @test expected in names
    end
end

@testitem "inventory walker: non-isolating macrocalls are transparent containers" begin
    using JuliaWorkspaces: _foreach_toplevel_item
    using JuliaWorkspaces: CSTParser

    src = """
    Salsa.@derived function foo(x)
        x
    end
    @bar(baz() = 1)
    @testset "s" begin
        inner() = 1
    end
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset, _segment
        push!(visited, (order=order, id=id, head=CSTParser.headof(x), offset=offset))
    end

    # 5 nodes: `Salsa.@derived` and `@bar` are effect-unknown macros, so each
    # emits its macrocall row (for `opaque_macros`) BEFORE its transparently
    # walked contents — foo's `function` and baz's assignment (past the
    # call-form's opening paren). `@testset` is a KNOWN isolating-scope macro:
    # one opaque item, no extra row, `inner` never visited.
    @test [v.order for v in visited] == collect(1:5)
    @test allunique([v.id for v in visited])
    @test visited[1].head === :macrocall
    @test src[visited[1].offset + 1] == 'S'   # `Salsa.@derived ...`
    @test visited[2].head === :function
    @test src[visited[2].offset + 1] == 'f'   # `function ...`
    @test visited[3].head === :macrocall      # `@bar(...)`
    @test src[visited[4].offset + 1] == 'b'   # `baz() = 1`
    @test visited[5].head === :macrocall      # `@testset`
    @test length(visited) == 5
end

@testitem "inventory extraction: macro-wrapped declarations, imports, and includes surface" setup=[InventoryWS] begin
    a_uri = URI("file:///inv/src/a.jl")
    inv, _ = inventory_of("""
    Salsa.@derived function derived_foo(rt)
        1
    end
    @auto_hash_equals struct D
        a
    end
    Base.@kwdef struct K
        x = 1
    end
    @static if VERSION > v"1.0"
        import SomePkg
        cond_mf() = 1
    else
        cond_mg() = 2
    end
    @static if true
        include("a.jl")
    end
    @testitem "t" begin
        leaky1() = 1
    end
    @testset "s" begin
        leaky2() = 1
    end
    @testmodule TM begin
        leaky3() = 1
    end
    @testsnippet TS begin
        leaky4() = 1
    end
    @safetestset "st" begin
        leaky5() = 1
    end
    """; extra_files=Dict(a_uri => "z() = 1\n"))

    byname(n) = only(filter(i -> i.name == n, inv.items))
    @test byname("derived_foo").kind === :function
    @test byname("derived_foo").signature == "derived_foo(rt)"
    @test byname("D").kind === :struct
    @test byname("D").field_names == ["a"]
    @test byname("K").kind === :struct
    @test byname("cond_mf").kind === :function
    @test byname("cond_mg").kind === :function
    # a `using`/`import` inside a macro-wrapped `@static if` is a real import
    @test any(i -> i.kind === :import && i.path == ["SomePkg"], inv.imports)
    # an `include` inside a macro-wrapped `@static if` is a real include event
    @test any(inc -> inc.target == a_uri, inv.includes)
    # The testset family stays fully opaque — nothing from those bodies is
    # recorded at all.
    @test isempty(filter(i -> i.name in ("leaky2", "leaky5"), inv.items))
    # The testitem family IS descended into, but nothing leaks to the enclosing
    # module: each name is recorded under its own test item's node.
    segs = Dict(t.label => t.segment for t in inv.testitems)
    @test byname("leaky1").parent_module == [segs["t"]]
    @test byname("leaky3").parent_module == [segs["TM"]]
    @test byname("leaky4").parent_module == [segs["TS"]]
    @test !any(i -> i.name in ("leaky1", "leaky3", "leaky4") && isempty(i.parent_module), inv.items)
end

@testitem "inventory parity: typed and parenthesized assignment lhs emit their identifier" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    x::Int = 1
    (y) = 1
    const z::Float64 = 2
    """)

    byname(n) = only(filter(i -> i.name == n, inv.items))
    @test byname("x").kind === :assignment
    @test byname("y").kind === :assignment
    @test byname("z").kind === :const
end

@testitem "inventory parity: qualified test macros match StaticLint's matchers" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    TestItems.@testmodule TM begin
        tm_f() = 1
    end
    TestItems.@testsnippet TS begin
        ts_f() = 1
    end
    TestItems.@testitem "t" begin
        ti_f() = 1
    end
    """)

    # StaticLint's `_is_testmodule_macro`/`_is_testsnippet_macro`/
    # `_is_testitem_macro` (macros.jl) all unwrap the qualified `X.@macro`
    # getfield form (mirroring `is_scope_introducing_macrocall`, scope.jl),
    # so a QUALIFIED form gets the same isolating treatment a bare one does:
    # each body opens its own `:testitem` node, and nothing lands at file level.
    @test [(t.kind, t.label) for t in inv.testitems] ==
        [(:testmodule, "TM"), (:testsnippet, "TS"), (:testitem, "t")]

    segs = Dict(t.label => t.segment for t in inv.testitems)
    byname(n) = only(filter(i -> i.name == n, inv.items))
    @test byname("tm_f").parent_module == [segs["TM"]]
    @test byname("ts_f").parent_module == [segs["TS"]]
    @test byname("ti_f").parent_module == [segs["t"]]
    @test !any(i -> i.name in ("tm_f", "ts_f", "ti_f") && isempty(i.parent_module), inv.items)
end

@testitem "macro-declared: name derivation for the modelled macros" begin
    using JuliaWorkspaces: CSTParser, _declare_input_names, _deprecate_names,
        _macro_declaration_rule, MACRO_DECLARATION_RULES

    # The first argument of the macrocall, which is `args[3]`.
    arg1(src) = CSTParser.parse(src, true).args[1].args[3]

    @test _declare_input_names(arg1("@declare_input foo(rt, x::Int)::V")) ==
        ["foo", "set_foo!", "delete_foo!"]
    @test _declare_input_names(arg1("Salsa.@declare_input bar(rt)::Int")) ==
        ["bar", "set_bar!", "delete_bar!"]
    # No `::` return type: Salsa itself rejects this, so we derive nothing.
    @test _declare_input_names(arg1("@declare_input baz(rt)")) == String[]
    # A `::` whose left side is not a call declares nothing: Salsa requires the
    # call form, so `x::T` is not an input declaration.
    @test _declare_input_names(arg1("@declare_input foo::Int")) == String[]

    @test _deprecate_names(arg1("@deprecate f(x::Int) g(x)")) == ["f"]
    @test _deprecate_names(arg1("@deprecate old new")) == ["old"]
    @test _deprecate_names(arg1("@deprecate f(x::T) where T g(x)")) == ["f"]
    @test _deprecate_names(arg1("Base.@deprecate (+)(a, b) plus(a, b)")) == ["+"]

    r = _macro_declaration_rule("@declare_input")
    @test r !== nothing && r.owner == ["Salsa"]
    @test _macro_declaration_rule("@deprecate").owner == ["Base"]
    @test _macro_declaration_rule("@nope") === nothing
    @test length(MACRO_DECLARATION_RULES) == 2
end

@testitem "macro-declared: inventory rows for a modelled macrocall" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, _BINDING_ITEM_KINDS, derived_module_tree,
        module_node
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///t/src/T.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    @deprecate oldf newf
    end
    """, "julia")))

    items = derived_file_inventory(jw.runtime, u).items
    md = [it for it in items if it.kind === :macro_declared]

    @test [it.name for it in md] ==
        ["foo", "set_foo!", "delete_foo!", "oldf"]

    # All three @declare_input names share the first argument's id and order.
    @test length(unique(it.id for it in md[1:3])) == 1
    @test length(unique(it.order for it in md[1:3])) == 1
    @test md[4].id != md[1].id

    # The spelling is recorded as written, qualifier included.
    @test md[1].declared_by == (qualifier=["Salsa"], name="@declare_input")
    @test md[4].declared_by == (qualifier=String[], name="@deprecate")

    # Inert: no shape, and outside the binding kinds, so nothing can treat
    # these as declarations before identity is confirmed.
    @test all(it -> it.arity === nothing && it.signature === nothing, md)
    @test :macro_declared ∉ _BINDING_ITEM_KINDS

    # The module tree must not see them.
    node = module_node(derived_module_tree(jw.runtime, u), ["T"])
    @test !haskey(node.declared, "set_foo!")
    @test !haskey(node.declared, "oldf")

    # Ordinary items still carry no spelling.
    ordinary = [it for it in items if it.kind !== :macro_declared]
    @test all(it -> it.declared_by === nothing, ordinary)
end

@testitem "macro-declared: only the first macro argument declares names" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///t/src/S.jl")
    jw = JuliaWorkspace()
    # `newf` is argument 2 and must contribute nothing; an unmodelled macro
    # contributes nothing at all.
    add_file!(jw, TextFile(u, SourceText("""
    @deprecate oldf newf
    @some_other_macro alpha beta
    """, "julia")))

    md = [it for it in derived_file_inventory(jw.runtime, u).items if it.kind === :macro_declared]
    @test [it.name for it in md] == ["oldf"]
end

@testitem "macro-declared: generated names are not workspace symbols" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_workspace_symbols
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///t/src/U.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    ordinary_fn(x) = x
    end
    """, "julia")))

    # The macro-generated name must not surface as a workspace symbol: nothing
    # has confirmed the macro's identity yet, so it stays inert.
    @test isempty(get_workspace_symbols(jw, "set_foo!"))

    # Not vacuous: an ordinary declaration in the same file IS found.
    @test any(r -> r.name == "ordinary_fn", get_workspace_symbols(jw, "ordinary_fn"))
end
