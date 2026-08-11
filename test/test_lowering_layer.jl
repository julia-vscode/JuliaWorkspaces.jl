@testsnippet LoweringWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: BodyTree, ItemLowering, LoweringFinding, LoweredBinding,
        BindingUse, ITEM_LOWERING_UNAVAILABLE, LOWERING_AVAILABLE,
        derived_file_lowering_forest, derived_item_lowering_body,
        derived_file_lowering_maps, derived_item_lowering,
        derived_file_inventory, ItemRef, update_file!
    using JuliaWorkspaces.URIs2: URI

    const LW_URI = URI("file:///lw/src/F.jl")

    function lw_workspace(src::String; uri=LW_URI)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        return jw
    end

    function lw_item_ref(jw, name; uri=LW_URI)
        inv = derived_file_inventory(jw.runtime, uri)
        return ItemRef(uri, only(filter(i -> i.name == name, inv.items)).id)
    end
end

@testitem "lowering layer: availability matches the version gate" setup=[LoweringWS] begin
    @test LOWERING_AVAILABLE == (VERSION >= v"1.12")
    if !LOWERING_AVAILABLE
        jw = lw_workspace("f(x) = x + 1\n")
        ref = lw_item_ref(jw, "f")
        @test derived_item_lowering(jw.runtime, ref) === ITEM_LOWERING_UNAVAILABLE
        @test derived_item_lowering_body(jw.runtime, ref) === nothing
    else
        @test true
    end
end

@testitem "lowering layer: plain items lower with bindings and uses" setup=[LoweringWS] begin
    if LOWERING_AVAILABLE
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
        naddrs = length(derived_file_lowering_maps(jw.runtime, LW_URI)[ref.id])
        @test all(u -> 0 <= u.addr <= naddrs, low.uses)
    else
        @test true
    end
end

@testitem "lowering layer: backdates across position-only edits" setup=[LoweringWS] begin
    if LOWERING_AVAILABLE
        src = "function f(a)\n    a + 1\nend\n"
        jw = lw_workspace(src)
        ref = lw_item_ref(jw, "f")

        low1 = derived_item_lowering(jw.runtime, ref)
        body1 = derived_item_lowering_body(jw.runtime, ref)
        maps1 = derived_file_lowering_maps(jw.runtime, LW_URI)[ref.id]
        @test low1.status == :ok

        # Whitespace above + comment inside: same value, shifted map.
        update_file!(jw, TextFile(LW_URI, SourceText(
            "# header\n\n\nfunction f(a)\n    # note\n    a + 1\nend\n", "julia")))
        low2 = derived_item_lowering(jw.runtime, ref)
        body2 = derived_item_lowering_body(jw.runtime, ref)
        maps2 = derived_file_lowering_maps(jw.runtime, LW_URI)[ref.id]

        @test isequal(body1, body2)
        @test isequal(low1, low2)
        @test maps1 != maps2

        # Content edit changes the result.
        update_file!(jw, TextFile(LW_URI, SourceText(
            "function f(a)\n    b = a + 1\n    b\nend\n", "julia")))
        low3 = derived_item_lowering(jw.runtime, ref)
        @test low3.status == :ok
        @test !isequal(low1, low3)
    else
        @test true
    end
end

@testitem "lowering layer: macrocalls are opaque, not fatal" setup=[LoweringWS] begin
    if LOWERING_AVAILABLE
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
        inv = derived_file_inventory(jw.runtime, LW_URI)
        mc = filter(i -> i.kind == :opaque_macrocall || i.kind == :macrocall, inv.items)
        if !isempty(mc)
            mlow = derived_item_lowering(jw.runtime, ItemRef(LW_URI, first(mc).id))
            @test mlow === nothing || mlow.status == :ok
        end
    else
        @test true
    end
end

@testitem "lowering layer: lowering errors become findings, not crashes" setup=[LoweringWS] begin
    if LOWERING_AVAILABLE
        # `break` outside any loop is rejected by lowering (not by the parser).
        jw = lw_workspace("function f()\n    break\nend\n")
        ref = lw_item_ref(jw, "f")

        low = derived_item_lowering(jw.runtime, ref)
        @test low isa ItemLowering
        @test low.status == :error
        @test !isempty(low.findings)
        @test low.findings[1].msg != ""
    else
        @test true
    end
end

@testitem "lowering layer: missing files and items degrade quietly" setup=[LoweringWS] begin
    if LOWERING_AVAILABLE
        jw = lw_workspace("f(x) = x\n")
        missing_ref = ItemRef(URI("file:///lw/src/Missing.jl"), Int64(1))
        @test derived_item_lowering(jw.runtime, missing_ref) === nothing
        @test derived_item_lowering_body(jw.runtime, missing_ref) === nothing

        # Malformed file: no crash.
        update_file!(jw, TextFile(LW_URI, SourceText("f(x = ) := +\n", "julia")))
        @test derived_file_lowering_forest(jw.runtime, LW_URI) isa Dict
    else
        @test true
    end
end
