@testsnippet BodyTreeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: BodyTree, bt_node_count, _build_body_tree_v2!, JS2

    # The item's tree, built the same way the walker builds it.
    function bt_of(src::String)
        root = JS2.parseall(JS2.SyntaxTree, src; filename="bt.jl")
        return _build_body_tree_v2!(nothing, JS2.children(root)[1])
    end

    function bt_with_map(src::String)
        root = JS2.parseall(JS2.SyntaxTree, src; filename="bt.jl")
        ranges = UnitRange{Int}[]
        tree = _build_body_tree_v2!(ranges, JS2.children(root)[1])
        return tree, ranges
    end

    # Preorder address of the first node satisfying `pred`, or nothing.
    function bt_addr_of(t::BodyTree, pred)
        addr = 0
        found = nothing
        function go(n)
            addr += 1
            found === nothing && pred(n) && (found = addr)
            n.children === nothing && return
            foreach(go, n.children)
        end
        go(t)
        return found
    end

    slice(content, r) = content[first(r):last(r)-1]  # ranges are exclusive-end
end

@testitem "body tree: structural value semantics" setup=[BodyTreeWS] begin
    t1 = bt_of("f(x) = x + 1")
    t2 = bt_of("f(x) = x + 1")
    @test t1 == t2
    @test isequal(t1, t2)
    @test hash(t1) == hash(t2)

    # Trivia inside the item is invisible: comments and whitespace don't matter.
    t3 = bt_of("function f(x)\n    # a comment\n    x  +  1\nend")
    t4 = bt_of("function f(x)\n    x + 1\nend")
    @test t3 == t4
    @test hash(t3) == hash(t4)

    # But the short form and the long form are different syntax (different EST
    # kinds: `K"="` vs `K"function"`).
    @test t1 != t3

    # Content differences are visible.
    @test bt_of("f(x) = x + 1") != bt_of("f(x) = x + 2")
    @test bt_of("f(x) = x + 1") != bt_of("f(y) = y + 1")
    @test bt_of("f() = 1") != bt_of("f() = 1.0")
    @test bt_of("\"str\"") != bt_of(":str")
end

@testitem "body tree: constructor-level distinctions" setup=[BodyTreeWS] begin
    leaf = bt_of("1")
    @test leaf.children === nothing
    k = leaf.kind

    # Leaf values of different types are unequal even when `isequal` on the raw
    # values would say otherwise (isequal(1, UInt8(1)) is true).
    @test BodyTree(k, 1, nothing) != BodyTree(k, UInt8(1), nothing)

    # A leaf is not an interior node with zero children.
    @test BodyTree(k, nothing, nothing) != BodyTree(k, nothing, BodyTree[])
end

@testitem "body tree: EST encodes flag-borne syntax structurally" setup=[BodyTreeWS] begin
    # These distinctions live in JuliaSyntax head FLAGS, which a BodyTree does
    # not carry. They survive anyway because the EST re-emits them as structure
    # (`(struct (Value true) …)`) or as distinct kinds. If a vendored-parser
    # refresh ever changed that, these are the tests that would catch it.
    @test bt_of("struct S end") != bt_of("mutable struct S end")
    @test bt_of("module M end") != bt_of("baremodule M end")
    @test bt_of("f(x) = 1") != bt_of("function f(x) 1 end")

    # And the values really are the discriminator, not incidental noise.
    @test bt_of("mutable struct S end").children[1].val === true
    @test bt_of("struct S end").children[1].val === false
    @test bt_of("module M end").children[1].val === true       # not bare
    @test bt_of("baremodule M end").children[1].val === false  # bare
end

@testitem "body tree: map alignment with the tree walk" setup=[BodyTreeWS] begin
    src = "f(x) = x + 1"
    tree, ranges = bt_with_map(src)

    @test tree == bt_of(src)
    @test length(ranges) == bt_node_count(tree)

    # Address 1 is the whole item.
    @test slice(src, ranges[1]) == "f(x) = x + 1"

    # A leaf address maps to that leaf's text.
    xaddr = bt_addr_of(tree, n -> n.val == "x")
    @test xaddr !== nothing
    @test slice(src, ranges[xaddr]) == "x"
end

@testitem "body tree: positions never enter the value" setup=[BodyTreeWS] begin
    # A BodyTree must be identical regardless of where the item sits and what
    # the file is called. Macrocalls are the interesting case: the EST hangs an
    # Expr-style `LineNumberNode` (file + line) off every one of them.
    src = "@inline f(x) = x + 1"
    a = bt_of(src)
    b = bt_of("\n\n\n" * src)
    @test isequal(a, b)
    @test a.hash == b.hash

    root = JS2.parseall(JS2.SyntaxTree, src; filename="COMPLETELY_DIFFERENT.jl")
    c = _build_body_tree_v2!(nothing, JS2.children(root)[1])
    @test isequal(a, c)
end
