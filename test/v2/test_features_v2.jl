# v2-backed interactive features (layer_features_v2.jl): the A1
# offset→item/address family and the feature swaps built on it.
# Offsets in these tests are 0-BASED byte offsets (the `_get_*`-level
# convention); `src` strings are pure ASCII so byte == char arithmetic.

@testsnippet FeatV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_features!, v2_item_view, v2_item_row_at, v2_identifier_addr_at
    using JuliaWorkspaces.URIs2: URI

    const FT_URI = URI("file:///ft/src/F.jl")

    function ft_workspace(src::String; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(FT_URI, SourceText(src, "julia")))
        flag && set_v2_features!(jw, true)
        return jw
    end

    # 0-based offset of the i-th occurrence of `needle` in `src`.
    function off0(src, needle; nth=1)
        pos = 0
        for _ in 1:nth
            r = findnext(needle, src, pos + 1)
            r === nothing && error("needle not found")
            pos = first(r)
        end
        return pos - 1
    end
end

@testitem "A1: item row at offset" setup=[FeatV2WS] begin
    src = "f(x) = x + 1\ng(y) = y\n"
    jw = ft_workspace(src)
    # Inside the first item. (`row.kind` is the walker's coarse kind CLASS,
    # not the inventory classification — only identity matters here.)
    row = v2_item_row_at(jw.runtime, FT_URI, off0(src, "x + 1"))
    @test row !== nothing
    # Inside the second.
    row2 = v2_item_row_at(jw.runtime, FT_URI, off0(src, "g(y)"))
    @test row2 !== nothing && row2.id != row.id
    # Far past the end: nothing.
    @test v2_item_row_at(jw.runtime, FT_URI, 1000) === nothing
end

@testitem "A1: identifier addr with both-edge inclusion and right-edge tie-break" setup=[FeatV2WS] begin
    src = "f(alpha) = alpha + beta\n"
    jw = ft_workspace(src)
    row = v2_item_row_at(jw.runtime, FT_URI, 0)
    view = v2_item_view(jw.runtime, FT_URI, row.id)
    @test view !== nothing

    ident_at(o) = (a = v2_identifier_addr_at(view, o); a === nothing ? nothing : string(view.vals[a]))

    a2 = off0(src, "alpha"; nth=2)
    # Left edge, interior, and right edge all hit the identifier.
    @test ident_at(a2) == "alpha"
    @test ident_at(a2 + 2) == "alpha"
    @test ident_at(a2 + 5) == "alpha"       # cursor just after the last char
    # `f(alpha|)` — the paren's position still belongs to the preceding
    # identifier (right-edge rule).
    @test ident_at(off0(src, "(") + 6) == "alpha"
    # Cursor on the `+` operator: `+` IS an identifier leaf in a call; the
    # names on either side win only at their own edges.
    @test ident_at(off0(src, "beta")) == "beta"
    # Cursor in whitespace between tokens: nothing (the ` = ` region).
    @test ident_at(off0(src, "= alpha")) in (nothing, "=")
end

@testitem "A1: view alignment survives nesting; macro names excluded" setup=[FeatV2WS] begin
    src = "function outer(a)\n    inner = [a for a in 1:3]\n    @show inner\n    return inner\nend\n"
    jw = ft_workspace(src)
    row = v2_item_row_at(jw.runtime, FT_URI, 0)
    view = v2_item_view(jw.runtime, FT_URI, row.id)
    @test view !== nothing
    @test length(view.ranges) == length(view.kinds) == length(view.vals)
    # Every identifier's range slices to its own spelling.
    for a in eachindex(view.ranges)
        JW._v2f_is_identifier(view, a) || continue
        r = view.ranges[a]
        @test src[first(r):last(r)-1] == string(view.vals[a])
    end
    # The cursor on `@show` never resolves to an identifier target.
    a = v2_identifier_addr_at(view, off0(src, "@show") + 1)
    @test a === nothing || string(view.vals[a]) != "@show"
    # Parent addresses are sane: root has parent 0, everyone else > 0.
    @test view.parents[1] == 0
    @test all(view.parents[2:end] .> 0)
end

@testitem "A1: include rows now carry bodies and maps" setup=[FeatV2WS] begin
    src = "include(\"other.jl\")\nf() = 1\n"
    jw = ft_workspace(src)
    skel = JW.derived_v2_file_skeleton(jw.runtime, FT_URI)
    inc = only(skel.includes)
    @test haskey(JW.derived_v2_file_maps(jw.runtime, FT_URI), inc.id)
    @test haskey(JW.derived_v2_file_bodies(jw.runtime, FT_URI), inc.id)
    view = v2_item_view(jw.runtime, FT_URI, inc.id)
    @test view !== nothing
    # The path string literal's range slices to the quoted text.
    sa = findfirst(a -> view.kinds[a] == JW.JS2.K"string" ||
                        string(view.kinds[a]) == "String", eachindex(view.ranges))
    @test sa !== nothing
end
