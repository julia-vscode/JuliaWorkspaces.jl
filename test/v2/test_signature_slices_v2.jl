# The signature slicing helpers (layer_features_v2.jl): as-written signature
# text, and assembled labels with UTF-16 parameter ranges, both from source
# slices at map ranges.

@testsnippet SigSliceWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, V2ItemRef
    using JuliaWorkspaces.URIs2: URI

    const SS_URI = URI("file:///ssl/src/Root.jl")

    function ss_workspace(src::String)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(SS_URI, SourceText(src, "julia")))
        set_v2_enabled!(jw, true)
        return jw
    end

    # The item declaring `name`, via the inventory.
    function ss_ref(jw, name)
        for item in JW.derived_v2_file_inventory(jw.runtime, SS_URI).items
            item.name == name && return V2ItemRef(SS_URI, item.id)
        end
        return nothing
    end

    ss_text(src, name) = (jw = ss_workspace(src);
        JW.v2_item_signature_text(jw.runtime, ss_ref(jw, name)))
    ss_sigs(src, name) = (jw = ss_workspace(src);
        JW.v2_item_signature_params(jw.runtime, ss_ref(jw, name)))

    # Check the label/range invariant: each range slices the label to a
    # parameter text (ASCII labels: UTF-16 offsets == character offsets).
    function ss_params(sig)
        return [sig.label[(nextind(sig.label, 0, r[1] + 1)):(nextind(sig.label, 0, r[2]))]
                for r in sig.param_ranges]
    end
end

@testitem "signature slices: as-written text" setup=[SigSliceWS] begin
    @test ss_text("f(x, y=1) = x\n", "f") == "f(x, y=1)"
    # Wheres and return types are kept as written.
    @test ss_text("function g(x::T)::Int where T\n    x\nend\n", "g") ==
        "g(x::T)::Int where T"
    # A multi-line signature collapses to one line.
    @test ss_text("function h(a,\n           b::Int)\n    a\nend\n", "h") ==
        "h(a, b::Int)"
    @test ss_text("function f end\n", "f") == "f"
    # A struct yields its whole definition.
    @test ss_text("struct S\n    a::Int\nend\n", "S") == "struct S a::Int end"
    # Non-callables yield nothing.
    @test ss_text("x = 1\n", "x") === nothing
end

@testitem "signature slices: labels and parameter ranges" setup=[SigSliceWS] begin
    sig = only(ss_sigs("f(a, b::Int, c...; k=1, ks...) = a\n", "f"))
    @test sig.label == "f(a, b::Int, c...; k=1, ks...)"
    @test ss_params(sig) == ["a", "b::Int", "c..."]

    # Wheres and return types drop from the label.
    sig = only(ss_sigs("function g(x::T)::Int where T\n    x\nend\n", "g"))
    @test sig.label == "g(x::T)"
    @test ss_params(sig) == ["x::T"]

    # Anonymous and @nospecialize parameters keep their call-relevant spelling.
    sig = only(ss_sigs("h(::Int, @nospecialize(y)) = y\n", "h"))
    @test ss_params(sig) == ["::Int", "y"]

    # `function f end` offers no signatures.
    @test isempty(ss_sigs("function f end\n", "f"))

    # A functor signature reads as a call (functor items bind no inventory
    # name, so the ref comes from the skeleton row directly).
    jw = ss_workspace("function (c::Vector)(x)\n    x\nend\n")
    row = only(JW.derived_v2_file_skeleton(jw.runtime, SS_URI).items)
    sig = only(JW.v2_item_signature_params(jw.runtime, V2ItemRef(SS_URI, row.id)))
    @test sig.label == "(c::Vector)(x)"
    @test ss_params(sig) == ["x"]
end

@testitem "signature slices: structs" setup=[SigSliceWS] begin
    # The implicit field constructor, docstring skipped, subtype dropped,
    # curly kept.
    sigs = ss_sigs("""
    struct S{T} <: AbstractVector{T}
        "doc"
        a::T
        b
    end
    """, "S")
    sig = only(sigs)
    @test sig.label == "S{T}(a::T, b)"
    @test ss_params(sig) == ["a::T", "b"]

    # Inner constructors replace the implicit one.
    sigs = ss_sigs("""
    struct P
        a
        P(x) = new(x)
        function P(x, y::Int)
            new(x + y)
        end
    end
    """, "P")
    @test length(sigs) == 2
    @test sigs[1].label == "P(x)"
    @test sigs[2].label == "P(x, y::Int)"
    @test ss_params(sigs[2]) == ["x", "y::Int"]
end
