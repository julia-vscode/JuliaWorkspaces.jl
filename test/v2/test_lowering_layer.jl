@testsnippet LoweringWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: BodyTree, ItemLowering, LoweringFinding, LoweredBinding,
        BindingUse, derived_v2_file_bodies, derived_item_lowering_body,
        derived_v2_file_maps, derived_item_lowering,
        derived_v2_file_inventory, derived_v2_file_skeleton, V2ItemRef, update_file!
    using JuliaWorkspaces.URIs2: URI

    const LW_URI = URI("file:///lw/src/F.jl")

    function lw_workspace(src::String; uri=LW_URI)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        return jw
    end

    function lw_item_ref(jw, name; uri=LW_URI)
        inv = derived_v2_file_inventory(jw.runtime, uri)
        return V2ItemRef(uri, only(filter(i -> i.name == name, inv.items)).id)
    end
end

@testitem "lowering layer: plain items lower with bindings and uses" setup=[LoweringWS] begin
    jw = lw_workspace("""
    function f(a, b)
        c = a + b
        c * 2
    end
    """)
    ref = lw_item_ref(jw, "f")

    low = derived_item_lowering(jw.runtime, ref)
    @test low isa ItemLowering
    @test low.status == :ok
    @test isempty(low.findings)

    names = Dict(b.id => b for b in low.bindings)
    user = [b for b in low.bindings if !b.is_internal]
    @test any(b -> b.name == "a" && b.kind == :argument, user)
    @test any(b -> b.name == "b" && b.kind == :argument, user)
    @test any(b -> b.name == "c" && b.kind == :local, user)
    @test any(b -> b.name == "f" && b.kind == :global, user)

    # Uses reference existing bindings at real addresses.
    @test !isempty(low.uses)
    @test all(u -> haskey(names, u.binding), low.uses)
    naddrs = length(derived_v2_file_maps(jw.runtime, LW_URI)[ref.id])
    @test all(u -> 0 <= u.addr <= naddrs, low.uses)
end

@testitem "lowering layer: backdates across position-only edits" setup=[LoweringWS] begin
    src = "function f(a)\n    a + 1\nend\n"
    jw = lw_workspace(src)
    ref = lw_item_ref(jw, "f")

    low1 = derived_item_lowering(jw.runtime, ref)
    body1 = derived_item_lowering_body(jw.runtime, ref)
    maps1 = derived_v2_file_maps(jw.runtime, LW_URI)[ref.id]
    @test low1.status == :ok

    # Whitespace above + comment inside: same value, shifted map.
    update_file!(jw, TextFile(LW_URI, SourceText(
        "# header\n\n\nfunction f(a)\n    # note\n    a + 1\nend\n", "julia")))
    low2 = derived_item_lowering(jw.runtime, ref)
    body2 = derived_item_lowering_body(jw.runtime, ref)
    maps2 = derived_v2_file_maps(jw.runtime, LW_URI)[ref.id]

    @test isequal(body1, body2)
    @test isequal(low1, low2)
    @test maps1 != maps2

    # Content edit changes the result.
    update_file!(jw, TextFile(LW_URI, SourceText(
        "function f(a)\n    b = a + 1\n    b\nend\n", "julia")))
    low3 = derived_item_lowering(jw.runtime, ref)
    @test low3.status == :ok
    @test !isequal(low1, low3)
end

@testitem "lowering layer: items containing macrocalls are position-free" setup=[LoweringWS] begin
    # Regression: EST macrocalls carry an Expr-style `LineNumberNode` (file + line)
    # as their second child's value. Stored verbatim it landed in `BodyTree.hash`,
    # so ~40% of real items stopped backdating on a line shift and their hash
    # depended on the file's name. See `_normalize_v2_value`.
    src = "function h()\n    @assert 1 == 1\n    return 2\nend\n"
    jw = lw_workspace(src)
    ref = lw_item_ref(jw, "h")
    body1 = derived_item_lowering_body(jw.runtime, ref)
    @test body1 !== nothing

    # A pure line shift must leave the value identical.
    update_file!(jw, TextFile(LW_URI, SourceText("# pad\n\n" * src, "julia")))
    body2 = derived_item_lowering_body(jw.runtime, ref)
    @test isequal(body1, body2)
    @test body1.hash == body2.hash

    # The same source in a DIFFERENT file must produce the same value too.
    other = URI("file:///lw/src/Other.jl")
    jw2 = lw_workspace(src; uri=other)
    body3 = derived_item_lowering_body(jw2.runtime, lw_item_ref(jw2, "h"; uri=other))
    @test isequal(body1, body3)

    # No LineNumberNode carrying a real position survives anywhere in the tree.
    function each_leaf(f, bt)
        if bt.children === nothing
            f(bt)
        else
            for c in bt.children; each_leaf(f, c); end
        end
    end
    each_leaf(body1) do leaf
        leaf.val isa LineNumberNode && @test leaf.val == LineNumberNode(0, :body)
    end
end

@testitem "lowering layer: macrocalls are opaque, not fatal" setup=[LoweringWS] begin
    jw = lw_workspace("""
    function f(x)
        @show x
        x + 1
    end

    @kwdef_like_macrocall_item(1, 2)
    """)
    ref = lw_item_ref(jw, "f")

    low = derived_item_lowering(jw.runtime, ref)
    @test low.status == :ok
    # `x` (argument) still resolved outside the macrocall.
    @test any(b -> b.name == "x" && b.kind == :argument && !b.is_internal, low.bindings)
    # Nothing from inside the opaque macrocall leaks: no binding named "show".
    @test !any(b -> b.name == "@show", low.bindings)

    # A bare top-level macrocall item lowers as pure opaque without error.
    inv = derived_v2_file_inventory(jw.runtime, LW_URI)
    mc = filter(i -> i.kind == :opaque_macrocall || i.kind == :macrocall, inv.items)
    if !isempty(mc)
        mlow = derived_item_lowering(jw.runtime, V2ItemRef(LW_URI, first(mc).id))
        @test mlow === nothing || mlow.status == :ok
    end
end

@testitem "lowering layer: lowering errors become findings, not crashes" setup=[LoweringWS] begin
    # `break` outside any loop is rejected by lowering (not by the parser).
    jw = lw_workspace("function f()\n    break\nend\n")
    ref = lw_item_ref(jw, "f")

    low = derived_item_lowering(jw.runtime, ref)
    @test low isa ItemLowering
    @test low.status == :error
    @test !isempty(low.findings)
    @test low.findings[1].msg != ""
end

@testitem "lowering layer: module items are excluded, inner items lower" setup=[LoweringWS] begin
    jw = lw_workspace("module M\ng(x) = x + 1\nend\n")
    inv = derived_v2_file_inventory(jw.runtime, LW_URI)

    mod_id = only(filter(m -> m.name == "M", inv.modules)).id
    @test derived_item_lowering_body(jw.runtime, V2ItemRef(LW_URI, mod_id)) === nothing
    @test derived_item_lowering(jw.runtime, V2ItemRef(LW_URI, mod_id)) === nothing
    @test !haskey(derived_v2_file_bodies(jw.runtime, LW_URI), mod_id)

    glow = derived_item_lowering(jw.runtime, lw_item_ref(jw, "g"))
    @test glow !== nothing && glow.status == :ok
end

@testitem "lowering layer: missing files and items degrade quietly" setup=[LoweringWS] begin
    jw = lw_workspace("f(x) = x\n")
    missing_ref = V2ItemRef(URI("file:///lw/src/Missing.jl"), Int64(1))
    @test derived_item_lowering(jw.runtime, missing_ref) === nothing
    @test derived_item_lowering_body(jw.runtime, missing_ref) === nothing

    # Malformed file: no crash.
    update_file!(jw, TextFile(LW_URI, SourceText("f(x = ) := +\n", "julia")))
    @test derived_v2_file_bodies(jw.runtime, LW_URI) isa Dict
end
