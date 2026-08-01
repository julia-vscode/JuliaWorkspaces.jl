@testitem "inventory types: structural equality across separately built instances" begin
    using JuliaWorkspaces: FileInventory, InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule, ImportSymbol
    using JuliaWorkspaces.URIs2: URI

    make() = FileInventory(
        [InventoryItem(1, 101, "f", String[], :function, "f(x)", String[], String[]),
         InventoryItem(2, 102, "S", String[], :struct, nothing, ["a", "b"], ["M"])],
        [InventoryImport(3, 103, :using, [".", "Sibling"], ImportSymbol[], nothing, ["M"])],
        [InventoryExport(4, 104, :export, ["f"], String[])],
        [InventoryInclude(5, 105, URI("file:///pkg/src/a.jl"), String[])],
        [InventoryModule(6, 106, "M", false, String[])],
    )

    a = make()
    b = make()
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)

    c = FileInventory(
        [InventoryItem(1, 101, "g", String[], :function, "g(x)", String[], String[])],
        a.imports, a.exports, a.includes, a.modules)
    @test !isequal(a, c)
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
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset
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
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset
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
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset
        push!(visited, (order=order, id=id, head=CSTParser.headof(x), offset=offset))
    end

    # 3 item-like nodes: foo's `function` (unwrapped from the macrocall),
    # baz's assignment (unwrapped from the call-form macrocall, past the
    # opening paren), and the `@testset` macrocall itself (isolating scope —
    # stays opaque; `inner` is never visited).
    @test [v.order for v in visited] == collect(1:3)
    @test allunique([v.id for v in visited])
    @test visited[1].head === :function
    @test src[visited[1].offset + 1] == 'f'   # `function ...`
    @test src[visited[2].offset + 1] == 'b'   # `baz() = 1`
    @test visited[3].head === :macrocall
    @test length(visited) == 3
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
    # isolating macros (testitem family + testset family) leak nothing
    @test isempty(filter(i -> i.name in ("leaky1", "leaky2", "leaky3", "leaky4", "leaky5"), inv.items))
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

@testitem "inventory parity: qualified test macros match StaticLint's bare-only special cases" setup=[InventoryWS] begin
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

    # StaticLint's `_is_testmodule_macro`/`_is_testsnippet_macro`
    # (macros.jl:335-336) are bare-identifier-only: a QUALIFIED
    # `X.@testmodule` gets no prebuilt isolating scope there, so the old
    # traversal descends into it and binds its contents at module level —
    # the inventory must descend identically.
    names = Set(i.name for i in inv.items)
    @test "tm_f" in names
    @test "ts_f" in names
    # `@testitem` (and `@testset`/`@safetestset`) isolate via
    # `is_scope_introducing_macrocall` (scope.jl:144-153), which DOES unwrap
    # the qualified form — those stay opaque.
    @test !("ti_f" in names)
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
    @test all(it -> it.method_sig === nothing && it.signature === nothing, md)
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

@testitem "inventory: records bare and qualified parameter types" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText,
        MethodSignatureRecord, _recorded_type_path, _sig_is_judgeable
    using JuliaWorkspaces.URIs2: URI

    # What the cross-file type check actually reads off a record: one resolvable
    # name path per positional parameter (`String[]` = no opinion), and whether the
    # record may judge a call at all.
    paths(it) = begin
        tv = Set{String}(v.name for v in it.method_sig.where_vars)
        [something(_recorded_type_path(p.type, tv), String[]) for p in it.method_sig.params]
    end
    judgeable(it) = _sig_is_judgeable(MethodSignatureRecord(String[], it.kind, it.method_sig))

    u = URI("file:///pt/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    f(x::Int, y::CSTParser.EXPR) = 1
    g(a, b::String) = 2
    h(v::Vector{Int}) = 3
    k(x::T) where T<:Real = 4
    m(x::Int, ys...) = 5
    n(p::NamedTuple{(:w,),Tuple{String}}) = 6
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)

    # bare + qualified, positionally aligned
    @test paths(items["f"]) == [["Int"], ["CSTParser", "EXPR"]]
    # unannotated parameter records as unknown, not as absent
    @test paths(items["g"]) == [String[], ["String"]]
    # parametric: unknown in this slice (the head is NOT resolved alone)
    @test paths(items["h"]) == [String[]]
    # a where-bound type variable is method-local, never a resolvable name
    @test paths(items["k"]) == [String[]]
    # a positional splat makes alignment unknowable -> the record cannot judge
    @test !judgeable(items["m"])
    @test all(judgeable, (items["f"], items["g"], items["h"], items["k"], items["n"]))
    # value positions must not be harvested as type names
    @test paths(items["n"]) == [String[]]
end

@testitem "inventory: method_sig is nothing for non-methods and backdates on body edits" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText, update_file!
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///pt2/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("module P\nconst C = 1\nf(x::Int) = 1\nend\n", "julia")))
    inv1 = derived_file_inventory(jw.runtime, u)
    @test Dict(it.name => it for it in inv1.items)["C"].method_sig === nothing

    # a body-only edit must leave the inventory `isequal` so Salsa backdates
    update_file!(jw, TextFile(u, SourceText("module P\nconst C = 1\nf(x::Int) = 99\nend\n", "julia")))
    inv2 = derived_file_inventory(jw.runtime, u)
    @test isequal(inv1, inv2)
end

@testitem "inventory: a where-clause bound does not shadow a same-named parameter type" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText, _recorded_type_path
    using JuliaWorkspaces.URIs2: URI

    paths(it) = begin
        tv = Set{String}(v.name for v in it.method_sig.where_vars)
        [something(_recorded_type_path(p.type, tv), String[]) for p in it.method_sig.params]
    end

    u = URI("file:///pt3/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    f(x::T, y::Real) where T<:Real = 4
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)

    # `T`'s bound (`Real`) must not be collected as a type-variable name: `y`'s
    # own, unrelated `Real` parameter only happens to share its spelling.
    @test paths(items["f"]) == [String[], ["Real"]]
end

@testitem "inventory: keyword args, defaulted positional args, and explicit Vararg" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText,
        MethodSignatureRecord, _recorded_type_path, _sig_is_judgeable
    using JuliaWorkspaces.URIs2: URI

    paths(it) = begin
        tv = Set{String}(v.name for v in it.method_sig.where_vars)
        [something(_recorded_type_path(p.type, tv), String[]) for p in it.method_sig.params]
    end
    judgeable(it) = _sig_is_judgeable(MethodSignatureRecord(String[], it.kind, it.method_sig))

    u = URI("file:///pt4/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    f(x::Int; y::String="a") = 1
    g(x::Int, z::Int=2) = 2
    h(x::Vararg{Int}) = 3
    i(x::Vararg) = 4
    j(x::Base.Vararg) = 5
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)

    # a keyword arg lives in `:parameters` and must not disturb positional alignment
    @test paths(items["f"]) == [["Int"]]
    # a defaulted POSITIONAL arg is still positional, not a keyword
    @test paths(items["g"]) == [["Int"], ["Int"]]
    # explicit `::Vararg{T}` / bare `::Vararg` make alignment unknowable, like a splat
    @test !judgeable(items["h"])
    @test !judgeable(items["i"])
    # A DOTTED `Base.Vararg` is variadic too, and reaches the same role, so
    # alignment is readable from the role alone.
    @test items["j"].method_sig.params[1].role === :vararg
    @test !judgeable(items["j"])
    @test judgeable(items["f"]) && judgeable(items["g"])
end

@testitem "inventory: dispatch-only (unary `::T`) parameters record their type" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText,
        MethodSignatureRecord, _recorded_type_path, _sig_is_judgeable
    using JuliaWorkspaces.URIs2: URI

    paths(it) = begin
        tv = Set{String}(v.name for v in it.method_sig.where_vars)
        [something(_recorded_type_path(p.type, tv), String[]) for p in it.method_sig.params]
    end
    judgeable(it) = _sig_is_judgeable(MethodSignatureRecord(String[], it.kind, it.method_sig))

    u = URI("file:///pt5/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    f(::Int) = 1
    g(::Int, y::String) = 2
    q(x::Int, ::String) = 3
    h(::Base.AbstractString) = 4
    k(::Vector{Int}) = 5
    w(::T) where T<:Real = 6
    v(x, ::Vararg{Int}) = 7
    z(::Vararg) = 8
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)

    # an anonymous parameter still occupies exactly one positional slot
    @test paths(items["f"]) == [["Int"]]
    # mixed anonymous/named: alignment must be preserved in both directions
    @test paths(items["g"]) == [["Int"], ["String"]]
    @test paths(items["q"]) == [["Int"], ["String"]]
    # qualified, same as the named form
    @test paths(items["h"]) == [["Base", "AbstractString"]]
    # parametric and where-bound stay unknown, same as the named form
    @test paths(items["k"]) == [String[]]
    @test paths(items["w"]) == [String[]]
    # an anonymous Vararg is still variadic -> alignment unknowable
    @test !judgeable(items["v"])
    @test !judgeable(items["z"])
end

@testitem "inventory: withholding a record's types cannot change its judgeability" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText,
        MethodSignatureRecord, _sig_is_judgeable, _blank_types
    using JuliaWorkspaces.URIs2: URI

    # Withholding costs a record its TYPE opinion and nothing else. Judgeability is
    # an alignment question, so it must answer the same either way — including for
    # the anonymous/dotted `Vararg` shapes, whose alignment signal would otherwise
    # be read off the very type field blanking erases.
    u = URI("file:///pt6/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    a(x::Int, y::String) = 1
    b(x, ::Vararg{Int}) = 2
    c(x, ::Base.Vararg) = 3
    d(x::Vararg{Int}) = 4
    e(x::Int, ys...) = 5
    g(xs::Vararg{Int,3}) = 6
    h(x::T) where T<:Real = 7
    i(x::Int; k::String="a") = 8
    struct S
        f1::Int
    end
    end
    """, "julia")))
    items = Dict(it.name => it for it in derived_file_inventory(jw.runtime, u).items)
    rec(it, sig) = MethodSignatureRecord(String[], it.kind, sig)
    for it in values(items)
        it.method_sig === nothing && continue
        @test _sig_is_judgeable(rec(it, it.method_sig)) ==
            _sig_is_judgeable(rec(it, _blank_types(it.method_sig)))
    end

    # Not vacuous: both sides of the invariant occur here.
    @test _sig_is_judgeable(rec(items["a"], _blank_types(items["a"].method_sig)))
    for n in ("b", "c", "d", "e", "g", "S")
        @test !_sig_is_judgeable(rec(items[n], _blank_types(items[n].method_sig)))
    end
end

@testitem "signature record: derived arity equals func_nargs over this package's own source" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: _method_signature, _arity_of, _render_sig, MethodArity
    using JuliaWorkspaces: CSTParser, StaticLint

    # Every callable definition anywhere in a file, not just the top-level ones,
    # so nested closures and quoted definitions are covered too.
    function each_def!(out, x)
        x isa CSTParser.EXPR || return out
        (CSTParser.defines_function(x) || CSTParser.defines_macro(x)) && push!(out, x)
        x.args === nothing && return out
        for a in x.args
            each_def!(out, a)
        end
        return out
    end

    srcdir = joinpath(pkgdir(JuliaWorkspaces), "src")
    ndefs = Ref(0)
    mismatches = String[]
    for (dir, _, names) in walkdir(srcdir), n in names
        endswith(n, ".jl") || continue
        path = joinpath(dir, n)
        cst = CSTParser.parse(read(path, String), true)
        for d in each_def!(CSTParser.EXPR[], cst)
            StaticLint._is_real_method(d) || continue
            ndefs[] += 1
            expected = MethodArity(StaticLint.func_nargs(d)...)
            sig = _method_signature(d)
            got = sig === nothing ? nothing : _arity_of(sig)
            got == expected && continue
            push!(mismatches, string(relpath(path, srcdir), ": ", something(_render_sig(d), "<unrenderable>"),
                                     "\n      func_nargs -> ", expected,
                                     "\n      _arity_of  -> ", got))
        end
    end

    # Guard against a vacuous pass (a broken walk finding nothing to compare).
    @test ndefs[] > 1000
    isempty(mismatches) || println("\n", length(mismatches), " arity mismatches:\n",
                                   join(mismatches, "\n"))
    @test isempty(mismatches)
end

@testitem "signature record: derived arity on hand-written shapes" begin
    using JuliaWorkspaces: _method_signature, _arity_of, MethodArity
    using JuliaWorkspaces: CSTParser, StaticLint

    defof(src) = CSTParser.parse(src, true).args[1]
    arity(src) = _arity_of(_method_signature(defof(src)))
    oracle(src) = MethodArity(StaticLint.func_nargs(defof(src))...)
    both(src) = (arity(src), oracle(src))

    inf = typemax(Int)

    @test arity("f(::Int) = 1") == MethodArity(1, 1, Symbol[], false)
    @test arity("f(x, ys...) = 1") == MethodArity(1, inf, Symbol[], false)
    @test arity("f(x::Vararg{Int,3}) = 1") == MethodArity(3, 3, Symbol[], false)
    @test arity("f(x::Int=1; k::String=\"a\", kw...) = 1") == MethodArity(0, 1, [:k], true)
    @test arity("f(x::T, y::Real) where T<:Real = 1") == MethodArity(2, 2, Symbol[], false)
    @test arity("f(x::T) where T>:Int = 1") == MethodArity(1, 1, Symbol[], false)
    @test arity("f(x::Vector{T}) where T = 1") == MethodArity(1, 1, Symbol[], false)
    @test arity("Base.:+(a, b) = 1") == MethodArity(2, 2, Symbol[], false)
    @test arity("function f(@nospecialize(x), y) end") == MethodArity(2, 2, Symbol[], false)
    # Every `Vararg` spelling is unbounded, dotted included.
    @test arity("f(x::Vararg{Int}) = 1") == MethodArity(0, inf, Symbol[], false)
    @test arity("f(x::Base.Vararg{Int}) = 1") == MethodArity(0, inf, Symbol[], false)
    # A splat carrying a BOUNDED `Vararg` is unbounded: `func_nargs` reads the
    # bound only from an unsplatted declaration, so the derived count must not
    # read it back out of the recorded type either.
    @test arity("f(xs::Vararg{Int,3}...) = 1") == MethodArity(0, inf, Symbol[], false)
    @test arity("f(x, xs::Vararg{Int,3}...) = 1") == MethodArity(1, inf, Symbol[], false)

    for src in ("f(::Int) = 1", "f(x, ys...) = 1", "f(x::Vararg{Int,3}) = 1",
                "f(x::Int=1; k::String=\"a\", kw...) = 1", "f(x::T, y::Real) where T<:Real = 1",
                "f(x::T) where T>:Int = 1", "f(x::Vector{T}) where T = 1", "Base.:+(a, b) = 1",
                "function f(@nospecialize(x), y) end", "f(x::Vararg{Int}) = 1",
                "f(x::Base.Vararg{Int}) = 1", "f(x, ::Vararg{Int}) = 1",
                "f(xs::Vararg{Int,3}...) = 1", "f(x, xs::Vararg{Int,3}...) = 1",
                "f(xs::Vararg{Int}...) = 1", "f(xs::Vararg{Int,N}...) where N = 1")
        a, o = both(src)
        @test a == o
    end

    # A macro-wrapped definition: `func_nargs`'s permissive early return needs an
    # env to resolve the macro, and the inventory has none, so the counts stay
    # exact. `shape_unknown` is what makes the derived arity permissive, and it
    # is set by callers that CAN tell (see below).
    wrapped = CSTParser.parse("@inline f(x, y) = 1", true).args[1].args[3]
    @test StaticLint._is_real_method(wrapped)
    @test _arity_of(_method_signature(wrapped)) == MethodArity(StaticLint.func_nargs(wrapped)...)
    @test _arity_of(_method_signature(wrapped)) == MethodArity(2, 2, Symbol[], false)
end

@testitem "signature record: shape_unknown makes the derived arity permissive" begin
    using JuliaWorkspaces: MethodSignature, SigParam, SigTypeVar, ParamType, MethodArity, _arity_of

    params = [SigParam("x", ParamType(["Int"]), :positional)]
    known = MethodSignature(params, SigParam[], false, SigTypeVar[], false)
    unknown = MethodSignature(params, SigParam[], false, SigTypeVar[], true)

    @test _arity_of(known) == MethodArity(1, 1, Symbol[], false)
    @test _arity_of(unknown) == MethodArity(0, typemax(Int), Symbol[], true)
end

@testitem "signature record: parameter roles, names and types as written" begin
    using JuliaWorkspaces: _method_signature, _is_unknown_type, SigParam, SigTypeVar, ParamType
    using JuliaWorkspaces: CSTParser

    sigof(src) = _method_signature(CSTParser.parse(src, true).args[1])
    unknown = ParamType()

    s = sigof("f(x::Int, ::Base.AbstractString, y::Vector{T}=T[], zs...; k::String=\"a\", kw...) where T<:Real = 1")
    @test s.params == [
        SigParam("x", ParamType(["Int"]), :positional),
        SigParam("", ParamType(["Base", "AbstractString"]), :positional),
        SigParam("y", ParamType(["Vector"], [ParamType(["T"])], ""), :optional),
        SigParam("zs", unknown, :vararg),
    ]
    @test s.kwargs == [SigParam("k", ParamType(["String"]), :keyword),
                       SigParam("kw", unknown, :vararg)]
    @test s.kwsplat
    @test s.where_vars == [SigTypeVar("T", ParamType(["Real"]))]
    @test !s.shape_unknown

    # A `where`-bound variable is recorded as written; the record does not
    # collapse it to unknown, the `where_vars` list is what identifies it.
    @test sigof("f(x::T) where T = 1").params == [SigParam("x", ParamType(["T"]), :positional)]

    # Upper bounds only: `T>:B` licenses nothing, a chain's upper is the top.
    @test _is_unknown_type(sigof("f(x::T) where T = 1").where_vars[1].upper)
    @test sigof("f(x::T) where T = 1").where_vars == [SigTypeVar("T", unknown)]
    @test sigof("f(x::T) where T>:Int = 1").where_vars == [SigTypeVar("T", unknown)]
    @test sigof("f(x::T) where Int<:T<:Real = 1").where_vars == [SigTypeVar("T", ParamType(["Real"]))]
    @test sigof("f(x::T, y::S) where {T, S<:Real} = 1").where_vars ==
        [SigTypeVar("T", unknown), SigTypeVar("S", ParamType(["Real"]))]

    # A value position is never harvested as a type name (`Val{:String}` must
    # not record `String`), but it is still recorded as a value.
    v = sigof("f(x::Val{:String}) = 1").params[1].type
    @test v.path == ["Val"]
    @test v.args == [ParamType(String[], ParamType[], ":String")]
    @test isempty(v.args[1].path)

    # A bounded `Vararg{T,N}` keeps its literal N, which is what the derived
    # count reads back.
    @test sigof("f(x::Vararg{Int,3}) = 1").params ==
        [SigParam("x", ParamType(["Vararg"], [ParamType(["Int"]), ParamType(String[], ParamType[], "3")], ""), :vararg)]

    @test sigof("const x = 1") === nothing
end

@testitem "signature record: InventoryItem carries it, and it backdates" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText, update_file!
    using JuliaWorkspaces: SigParam, SigTypeVar, ParamType, MethodArity, _arity_of
    using JuliaWorkspaces.URIs2: URI

    u = URI("file:///sr/src/P.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(u, SourceText("""
    module P
    const C = 1
    f(x::Int, ys...) = 1
    struct S
        a::Int
    end
    end
    """, "julia")))
    inv1 = derived_file_inventory(jw.runtime, u)
    items = Dict(it.name => it for it in inv1.items)

    @test items["C"].method_sig === nothing
    # A struct carries its constructor's shape: one parameter per field, with
    # the type opinion withheld.
    @test items["S"].method_sig !== nothing
    @test items["S"].method_sig.params == [SigParam("a", ParamType(), :positional)]
    @test _arity_of(items["S"].method_sig) == MethodArity(1, 1, Symbol[], false)
    @test items["f"].method_sig !== nothing
    @test items["f"].method_sig.params ==
        [SigParam("x", ParamType(["Int"]), :positional), SigParam("ys", ParamType(), :vararg)]
    @test _arity_of(items["f"].method_sig) == MethodArity(1, typemax(Int), Symbol[], false)

    # A body-only edit must leave the inventory `isequal` so Salsa backdates.
    update_file!(jw, TextFile(u, SourceText("""
    module P
    const C = 1
    f(x::Int, ys...) = 99
    struct S
        a::Int
    end
    end
    """, "julia")))
    @test isequal(inv1, derived_file_inventory(jw.runtime, u))
end

@testitem "signature record: derived struct arity equals struct_nargs over this package's own source" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: _struct_signature, _arity_of, MethodArity
    using JuliaWorkspaces: CSTParser, StaticLint

    # Every struct anywhere in a file, not just the top-level ones, so structs
    # nested in quotes or macro bodies are covered too.
    function each_struct!(out, x)
        x isa CSTParser.EXPR || return out
        CSTParser.defines_struct(x) && push!(out, x)
        x.args === nothing && return out
        for a in x.args
            each_struct!(out, a)
        end
        return out
    end

    srcdir = joinpath(pkgdir(JuliaWorkspaces), "src")
    nstructs = Ref(0)
    mismatches = String[]
    for (dir, _, names) in walkdir(srcdir), n in names
        endswith(n, ".jl") || continue
        path = joinpath(dir, n)
        cst = CSTParser.parse(read(path, String), true)
        for d in each_struct!(CSTParser.EXPR[], cst)
            nstructs[] += 1
            expected = MethodArity(StaticLint.struct_nargs(d)...)
            got = _arity_of(_struct_signature(d))
            got == expected && continue
            text = try
                first(string(CSTParser.to_codeobject(d)), 200)
            catch
                "<unrenderable>"
            end
            push!(mismatches, string(relpath(path, srcdir), ": ", text,
                                     "\n      struct_nargs -> ", expected,
                                     "\n      _arity_of    -> ", got))
        end
    end

    # Guard against a vacuous pass (a broken walk finding nothing to compare).
    @test nstructs[] > 100
    isempty(mismatches) || println("\n", length(mismatches), " struct arity mismatches:\n",
                                   join(mismatches, "\n"))
    @test isempty(mismatches)
end

@testitem "signature record: struct signatures on hand-written shapes" begin
    using JuliaWorkspaces: _struct_signature, _arity_of, _is_unknown_type
    using JuliaWorkspaces: MethodArity, SigParam, SigTypeVar, ParamType
    using JuliaWorkspaces: CSTParser, StaticLint

    function structof(src)
        cst = CSTParser.parse(src, true)
        out = CSTParser.EXPR[]
        walk(x) = begin
            x isa CSTParser.EXPR || return
            CSTParser.defines_struct(x) && push!(out, x)
            x.args === nothing && return
            foreach(walk, x.args)
        end
        walk(cst)
        return first(out)
    end
    sigof(src) = _struct_signature(structof(src))
    arity(src) = _arity_of(sigof(src))
    oracle(src) = MethodArity(StaticLint.struct_nargs(structof(src))...)

    inf = typemax(Int)
    unknown = ParamType()

    plain = "struct S; a::Int; b; end"
    macro_wrapped = "@foo struct S; a::Int; end"
    kwdef = "Base.@kwdef struct S; a::Int = 1; end"
    documented = "\"doc\" struct S; a::Int; end"
    doc_field = "struct S; \"field doc\"; a::Int; end"
    empty_body = "struct S end"
    doc_only_body = "struct S; \"nothing but a docstring\"; end"
    inner_same = "struct S; x; S(a) = new(a); end"
    inner_differing = "struct S; x; S(a, b) = new(); S(a, b, c, d) = new(); end"
    inner_splat = "struct S; x; S(a...) = new(); end"
    inner_kws = "struct S; x; S(a; k=1) = new(); S(a, b; j=2, kw...) = new(); end"
    parametric = "struct Foo{T} <: Bar; x::T; end"
    parametric_bounded = "struct Foo{T<:Real, S} <: Bar{T}; x::T; y::S; end"
    const_field = "mutable struct S; const a::Int; b; end"
    atomic_field = "mutable struct S; @atomic a::Int; end"

    all_shapes = [plain, macro_wrapped, kwdef, documented, doc_field, empty_body,
                  doc_only_body, inner_same, inner_differing, inner_splat, inner_kws,
                  parametric, parametric_bounded, const_field, atomic_field]

    # The gate: the derived arity reproduces `struct_nargs` for every shape.
    for src in all_shapes
        @test arity(src) == oracle(src)
    end

    # Arm 3: one parameter per field, named, with the type opinion withheld.
    @test arity(plain) == MethodArity(2, 2, Symbol[], false)
    @test sigof(plain).params ==
        [SigParam("a", unknown, :positional), SigParam("b", unknown, :positional)]
    @test !sigof(plain).shape_unknown
    @test all(p -> _is_unknown_type(p.type), sigof(plain).params)
    @test isempty(sigof(plain).kwargs)

    # A field's docstring is not a field.
    @test arity(doc_field) == MethodArity(1, 1, Symbol[], false)
    @test sigof(doc_field).params == [SigParam("a", unknown, :positional)]

    @test sigof(const_field).params ==
        [SigParam("a", unknown, :positional), SigParam("b", unknown, :positional)]
    @test sigof(atomic_field).params == [SigParam("a", unknown, :positional)]

    # Arm 1: a macro-wrapped struct may gain arbitrary constructors, so its
    # shape is unknown — unlike a method, this needs no environment to tell.
    @test sigof(macro_wrapped).shape_unknown
    @test arity(macro_wrapped) == MethodArity(0, inf, Symbol[], true)
    @test sigof(kwdef).shape_unknown
    @test arity(kwdef) == MethodArity(0, inf, Symbol[], true)
    # A doc wrapper adds no constructors, so it is not that macro.
    @test !sigof(documented).shape_unknown
    @test arity(documented) == MethodArity(1, 1, Symbol[], false)

    # An empty body answers permissively but claims no keyword splat, which is
    # why it is a vararg parameter and not `shape_unknown`.
    for src in (empty_body, doc_only_body)
        @test !sigof(src).shape_unknown
        @test sigof(src).params == [SigParam("", unknown, :vararg)]
        @test arity(src) == MethodArity(0, inf, Symbol[], false)
    end

    # Arm 2: the union of the inner constructors' ranges.
    @test arity(inner_same) == MethodArity(1, 1, Symbol[], false)
    @test sigof(inner_same).params == [SigParam("", unknown, :positional)]
    @test arity(inner_differing) == MethodArity(2, 4, Symbol[], false)
    @test sigof(inner_differing).params ==
        [SigParam("", unknown, :positional), SigParam("", unknown, :positional),
         SigParam("", unknown, :optional), SigParam("", unknown, :optional)]
    @test arity(inner_splat) == MethodArity(0, inf, Symbol[], false)
    @test sigof(inner_splat).params == [SigParam("", unknown, :vararg)]
    @test arity(inner_kws) == MethodArity(1, 2, [:k, :j], true)
    @test sigof(inner_kws).kwargs ==
        [SigParam("k", unknown, :keyword), SigParam("j", unknown, :keyword)]
    @test sigof(inner_kws).kwsplat
    # The field itself is not a parameter once inner constructors exist.
    @test length(sigof(inner_same).params) == 1

    # The struct's own type parameters become the record's type variables.
    @test sigof(parametric).where_vars == [SigTypeVar("T", unknown)]
    @test sigof(parametric).params == [SigParam("x", unknown, :positional)]
    @test sigof(parametric_bounded).where_vars ==
        [SigTypeVar("T", ParamType(["Real"])), SigTypeVar("S", unknown)]
    @test sigof(macro_wrapped).where_vars == SigTypeVar[]
end

@testitem "signature record: every callable inventory item carries one, and it derives the right arity" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, derived_item_positions, TextFile, SourceText,
        MethodArity, _arity_of
    using JuliaWorkspaces: CSTParser, StaticLint
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    # End to end over the real inventory, against an oracle taken from the item's
    # OWN defining EXPR (reached through the position map): every item that
    # declares a callable must carry a record, and that record must derive the
    # count `func_nargs`/`struct_nargs` gives for the same EXPR. This is the only
    # guard on the coverage the per-root index filters by `method_sig === nothing`
    # — a construction site that forgets the record drops arity coverage silently.
    # Both directions are asserted: the reverse (a record on something the oracle
    # does not call callable) would ADD index entries, and so arity opinions.
    #
    # `_classify_item!` recurses into a `const`/`global` wrapper with the STATEMENT's
    # id, so the oracle has to unwrap the same layer to reach the definition.
    function unwrap_wrapper(x)
        x isa CSTParser.EXPR || return x
        (CSTParser.headof(x) === :const || CSTParser.headof(x) === :global) || return x
        for inner in something(x.args, CSTParser.EXPR[])
            inner isa CSTParser.EXPR && CSTParser.isassignment(inner) && return inner
        end
        return x
    end

    srcdir = joinpath(pkgdir(JuliaWorkspaces), "src")
    jw = JuliaWorkspace()
    uris = URI[]
    for (dir, _, names) in walkdir(srcdir), n in names
        endswith(n, ".jl") || continue
        path = joinpath(dir, n)
        u = filepath2uri(path)
        add_file!(jw, TextFile(u, SourceText(read(path, String), "julia")))
        push!(uris, u)
    end

    nmethods, nstructs, unjoined = Ref(0), Ref(0), Ref(0)
    bad = String[]
    for u in uris
        pos = derived_item_positions(jw.runtime, u)
        for it in derived_file_inventory(jw.runtime, u).items
            entry = get(pos, it.id, nothing)
            if entry === nothing
                # An item the position map cannot reach carries no EXPR to build
                # the oracle from, so its record can only be counted, not checked.
                # Require none: a record nothing verifies is a hole in this guard.
                # A site that forgot BOTH the record and the position entry stays
                # invisible either way — without an EXPR there is nothing to
                # detect it with.
                it.method_sig === nothing || (unjoined[] += 1)
                continue
            end
            x = unwrap_wrapper(entry.expr)
            expected = if it.kind in (:struct, :mutable_struct) && CSTParser.defines_struct(x)
                nstructs[] += 1
                MethodArity(StaticLint.struct_nargs(x)...)
            elseif it.kind in (:function, :macro, :const, :global) && StaticLint._is_real_method(x)
                nmethods[] += 1
                MethodArity(StaticLint.func_nargs(x)...)
            else
                # The reverse direction: nothing the oracle declines to call a
                # callable may carry a record, or the index gains an arity opinion
                # for a name that has no method.
                it.method_sig === nothing ||
                    push!(bad, string(basename(string(u)), ": ", it.name, " (", it.kind,
                                      ") carries a method_sig but is not a callable declaration"))
                continue
            end
            if it.method_sig === nothing
                push!(bad, string(basename(string(u)), ": ", it.name, " (", it.kind, ") has no method_sig"))
            elseif _arity_of(it.method_sig) != expected
                push!(bad, string(basename(string(u)), ": ", it.name, " (", it.kind, ")",
                                  "\n      oracle    -> ", expected,
                                  "\n      _arity_of -> ", _arity_of(it.method_sig)))
            end
        end
    end

    # Guard against a vacuous pass (a broken join finding nothing to compare).
    # Floors sit just under the real counts, so a partially-broken join fails.
    @test nmethods[] > 1200
    @test nstructs[] > 110
    @test unjoined[] == 0
    isempty(bad) || println("\n", length(bad), " items whose record is missing, extra or wrong:\n",
                            join(bad, "\n"))
    @test isempty(bad)
end

@testitem "signature record: a struct's synthesised parameter list is bounded" begin
    using JuliaWorkspaces: _struct_signature, _arity_of, MethodArity, SigParam, ParamType
    using JuliaWorkspaces: CSTParser, StaticLint

    function structof(src)
        cst = CSTParser.parse(src, true)
        out = CSTParser.EXPR[]
        walk(x) = begin
            x isa CSTParser.EXPR || return
            CSTParser.defines_struct(x) && push!(out, x)
            x.args === nothing && return
            foreach(walk, x.args)
        end
        walk(cst)
        return first(out)
    end
    sigof(src) = _struct_signature(structof(src))
    oracle(src) = MethodArity(StaticLint.struct_nargs(structof(src))...)
    inf = typemax(Int)

    # A literal `Vararg{T,N}` bound in an inner constructor sets the range, so the
    # spelled-out synthesis would be N entries long inside a cached value.
    spread(n) = "struct S; x; S() = new(); S(a::Vararg{Int,$n}) = new(); end"
    required(n) = "struct S; x; S(a::Vararg{Int,$n}) = new(); end"

    # Just under the threshold: still the exact range, and still small.
    under = sigof(spread(254))
    @test _arity_of(under) == MethodArity(0, 254, Symbol[], false)
    @test _arity_of(under) == oracle(spread(254))
    @test length(under.params) == 254
    @test Base.summarysize(under) < 100_000

    # Just over it: the range degrades to unbounded, which accepts strictly more.
    over = sigof(spread(255))
    @test _arity_of(over) == MethodArity(0, inf, Symbol[], false)
    @test over.params == [SigParam("", ParamType(), :vararg)]

    # Likewise when the REQUIRED count alone is too large to spell out.
    many = sigof(required(2000))
    @test _arity_of(many) == MethodArity(0, inf, Symbol[], false)
    @test many.params == [SigParam("", ParamType(), :vararg)]

    # The clamp is memory, so pin memory: a record that used to cost tens of
    # megabytes is now a handful of bytes.
    for src in (spread(255), required(2000), spread(200_000), required(200_000))
        s = sigof(src)
        @test Base.summarysize(s) < 5_000
        # Never narrower than what `struct_nargs` admits: only ever more permissive.
        o, d = oracle(src), _arity_of(sigof(src))
        @test d.minargs <= o.minargs && d.maxargs >= o.maxargs
    end
end

@testitem "arity: an anonymous `::Vararg` is variadic on both the count and record sides" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText, MethodArity,
        _arity_of, _method_signature
    using JuliaWorkspaces.URIs2: URI
    const SL = JuliaWorkspaces.StaticLint
    const CP = JuliaWorkspaces.CSTParser

    sigof(src) = _method_signature(CP.parse(src, true).args[1])
    oracle(src) = MethodArity(SL.func_nargs(CP.parse(src, true).args[1])...)

    # The bug: a unary `::T` is not `isdeclaration`, so every `Vararg` test missed
    # the anonymous spelling and counted it as one ordinary positional.
    for (src, expected) in (
        ("f(x, ::Vararg{Int}) = 1",      MethodArity(1, typemax(Int), Symbol[], false)),
        ("f(::Vararg{Int}) = 1",         MethodArity(0, typemax(Int), Symbol[], false)),
        ("f(x, ::Vararg) = 1",           MethodArity(1, typemax(Int), Symbol[], false)),
        ("f(x, ::Base.Vararg{Int}) = 1", MethodArity(1, typemax(Int), Symbol[], false)),
        # a bounded anonymous Vararg consumes exactly N, as the bound form does
        ("f(x, ::Vararg{Int,3}) = 1",    MethodArity(4, 4, Symbol[], false)),
        ("f(::Vararg{Int,2}) = 1",       MethodArity(2, 2, Symbol[], false)),
    )
        @test oracle(src) == expected
        @test _arity_of(sigof(src)) == expected
        # the record must agree with the count side, which is what the whole
        # signature record rests on
        @test _arity_of(sigof(src)) == oracle(src)
    end

    # the bound spellings were already correct and must not move
    for src in ("f(x, y::Vararg{Int}) = 1", "f(x, ys...) = 1", "f(x, y::Vararg{Int,3}) = 1",
                "f(x, ::Int) = 1", "f(x::Int, y) = 1")
        @test _arity_of(sigof(src)) == oracle(src)
    end

    # an anonymous `::Vararg` now reaches the `:vararg` role, which is what makes
    # alignment readable without consulting the type
    roles(src) = [p.role for p in sigof(src).params]
    @test roles("f(x, ::Vararg{Int}) = 1") == [:positional, :vararg]
    @test roles("f(x, ::Base.Vararg) = 1") == [:positional, :vararg]
    @test roles("f(x, ::Int) = 1") == [:positional, :positional]
end

@testitem "arity: an anonymous `::Vararg` is not judged positionally across files" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: derived_file_inventory, TextFile, SourceText,
        _method_signature, _sig_is_judgeable, _blank_types, MethodSignatureRecord
    using JuliaWorkspaces.CSTParser: parse

    sigof(src) = _method_signature(parse(src, true).args[1])
    rec(src) = MethodSignatureRecord(String[], :function, sigof(src))

    # A variadic parameter list cannot be lined up with a call's arguments, so its
    # types may not judge one — and that must hold for the anonymous spelling too.
    for src in ("f(x, ::Vararg{Int}) = 1", "f(x, ::Base.Vararg) = 1",
                "f(x, y::Vararg{Int}) = 1", "f(x, ys...) = 1")
        @test !_sig_is_judgeable(rec(src))
    end
    @test _sig_is_judgeable(rec("f(x::Int, y::String) = 1"))

    # judgeability reads only roles, so blanking the types cannot change it
    for src in ("f(x, ::Vararg{Int}) = 1", "f(x, ::Base.Vararg) = 1",
                "f(x::Int, y::String) = 1", "f(x, ys...) = 1")
        r = rec(src)
        blanked = MethodSignatureRecord(r.defmod, r.kind, _blank_types(r.sig))
        @test _sig_is_judgeable(r) == _sig_is_judgeable(blanked)
    end
end
