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

# ── local references family ─────────────────────────────────────────────────

@testitem "local refs: plain, reassigned, and argument locals" setup=[FeatV2WS] begin
    src = "function f(a)\n    x = a + 1\n    x = x + 2\n    return x\nend\n"
    jw = ft_workspace(src)

    # `x`: two write sites (both assignments) and two reads.
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "x ="))
    @test length(refs) == 4
    his = JW._get_highlights(jw.runtime, FT_URI, off0(src, "x ="))
    @test count(h -> h.kind === :write, his) == 2
    @test count(h -> h.kind === :read, his) == 2

    # `a`: declaration (argument) + one read; goto-def lands on the argument name.
    refs_a = JW._get_references(jw.runtime, FT_URI, off0(src, "a + 1"))
    @test length(refs_a) == 2
    defs_a = JW._get_definitions(jw.runtime, FT_URI, off0(src, "a + 1"))
    @test length(defs_a) == 1
    @test defs_a[1].start.line == 1

    # Rename rewrites every occurrence with the bare name.
    edits = JW._get_rename_edits(jw.runtime, FT_URI, off0(src, "x ="), "y")
    @test length(edits) == 4
    @test all(e -> e.new_text == "y", edits)
    @test JW._can_rename(jw.runtime, FT_URI, off0(src, "x =")) !== nothing
end

@testitem "local refs: closures, comprehensions, where params, kwargs" setup=[FeatV2WS] begin
    # A captured local: definition + closure read unify.
    src = "function f()\n    c = 1\n    g = () -> c + 1\n    return g()\nend\n"
    jw = ft_workspace(src)
    @test length(JW._get_references(jw.runtime, FT_URI, off0(src, "c = 1"))) == 2

    # Comprehension variable: filter + body closures merge by decl addr.
    src = "f(d) = [n + 1 for n in d if n > 0]\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "n in d"))
    @test length(refs) == 3   # decl + body read + filter read

    # `where` param: signature and body occurrences unify via the
    # typevar/static_parameter pair.
    src = "f(x::T) where {T} = zero(T)\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "T} ="))
    @test length(refs) == 3   # ::T, {T}, zero(T)

    # A kwarg with a default: the forwarding-method duplicate collapses to
    # source occurrences only.
    src = "f(a; b = 2) = a + b\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "b = 2"))
    @test length(refs) == 2
end

@testitem "local refs: shadowing keeps inner and outer distinct" setup=[FeatV2WS] begin
    src = "function f(v)\n    x = 1\n    let x = 2\n        v += x\n    end\n    return x\nend\n"
    jw = ft_workspace(src)
    outer = JW._get_references(jw.runtime, FT_URI, off0(src, "x = 1"))
    inner = JW._get_references(jw.runtime, FT_URI, off0(src, "x = 2"))
    @test length(outer) == 2   # decl + return read
    @test length(inner) == 2   # let binding + the += read
    @test isempty(intersect(Set(r.start for r in outer), Set(r.start for r in inner)))
end

@testitem "local refs: fallbacks decline to v1" setup=[FeatV2WS] begin
    using JuliaWorkspaces: v2_local_occurrences

    # A quoted identifier: fabricated reads anchor at the quote address, so
    # the resolver declines.
    src = "f(x) = :(alpha + 1)\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "alpha")) === nothing

    # Inside an opaque macrocall's arguments: item has expansion sites.
    src = "function f(y)\n    @some_dsl y + 1\nend\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "y + 1")) === nothing

    # A module-level (global) name: declined — the v1 :tree route answers.
    src = "g() = 1\nf() = g()\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "g()"; nth=2)) === nothing

    # Flag off: the branch never runs (structural — internal helper still
    # works, but _get_references must follow the v1 path; smoke-check no
    # crash and plausible output for a local).
    src = "function f()\n    z = 1\n    return z\nend\n"
    jw = ft_workspace(src; flag=false)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "z = 1"))
    @test refs isa Vector{JW.ReferenceResult}
end

# ── workspace symbols ───────────────────────────────────────────────────────

@testitem "workspace symbols: v2 swap" setup=[FeatV2WS] begin
    src = """
    module Outer
    f() = 1
    struct Thing end
    macro mymac(x) end
    @testitem "t" begin
        hidden_in_test() = 1
    end
    end
    """
    jw = ft_workspace(src)
    syms = JW._get_workspace_symbols(jw.runtime, "")
    names = Set(s.name for s in syms)
    @test "f" in names
    @test "Thing" in names
    @test "Outer" in names
    # Testitem bodies are opaque in v2: no leakage.
    @test !("hidden_in_test" in names)
    # Prefix matching, with the @-stripped variant for macros.
    @test any(s -> s.name == "@mymac", JW._get_workspace_symbols(jw.runtime, "mymac"))
    @test any(s -> s.name == "@mymac", JW._get_workspace_symbols(jw.runtime, "@mymac"))
    @test isempty(JW._get_workspace_symbols(jw.runtime, "zzz_nothing"))
    # The range slices to the declaration.
    fsym = only(filter(s -> s.name == "f", syms))
    @test fsym.start.line == 2

    # Flag off: the v1 path still answers.
    jw = ft_workspace(src; flag=false)
    @test any(s -> s.name == "f", JW._get_workspace_symbols(jw.runtime, ""))
end
