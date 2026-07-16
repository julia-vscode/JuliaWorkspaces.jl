@testitem "inventory types: structural equality across separately built instances" begin
    using JuliaWorkspaces: FileInventory, InventoryItem, InventoryImport, InventoryExport,
        InventoryInclude, InventoryModule, ImportSymbol
    using JuliaWorkspaces.URIs2: URI

    make() = FileInventory(
        [InventoryItem(1, "f", :function, "f(x)", String[], String[]),
         InventoryItem(2, "S", :struct, nothing, ["a", "b"], ["M"])],
        [InventoryImport(3, :using, [".", "Sibling"], ImportSymbol[], nothing, ["M"])],
        [InventoryExport(4, :export, ["f"], String[])],
        [InventoryInclude(5, URI("file:///pkg/src/a.jl"), String[])],
        [InventoryModule(6, "M", false, String[])],
    )

    a = make()
    b = make()
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)

    c = FileInventory(
        [InventoryItem(1, "g", :function, "g(x)", String[], String[])],
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
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        push!(visited, (id=id, parent=copy(parent_module), offset=offset,
                        ismod=CSTParser.defines_module(x)))
    end

    # 7 item-like nodes: f, g (unwrapped), M, h, Inner, k, w — pre-order ids
    @test [v.id for v in visited] == collect(1:7)
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
        elseif_f(x) = x
    else
        else_f(x) = x
    end
    begin
        block_f(x) = x
    end
    w() = 4
    """
    cst = CSTParser.parse(src, true)

    visited = []
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        push!(visited, (id=id, parent=copy(parent_module), offset=offset))
    end

    # The if/elseif/else/begin containers themselves consume no id — only the
    # 4 defined functions plus the trailing `w` do.
    @test [v.id for v in visited] == collect(1:5)
    @test all(v -> v.parent == String[], visited)

    @test src[visited[1].offset + 1] == 'c'   # compat_f, inside the `if` branch
    @test src[visited[2].offset + 1] == 'e'   # elseif_f, inside the `elseif` branch
    @test src[visited[3].offset + 1] == 'e'   # else_f, inside the `else` branch
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

@testitem "inventory extraction: kinds, names, signatures, fields" setup=[InventoryWS] begin
    inv, _ = inventory_of("""
    f(x) = x + 1
    function g(a::Int, b; kw=1)
        a + b
    end
    macro m(ex) end
    const C = 1
    global G = 2
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
    @test byname("m").kind === :macro
    @test byname("C").kind === :const
    @test byname("G").kind === :global
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
    @test any(i -> i.kind === :opaque_macrocall, inv.items)
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
