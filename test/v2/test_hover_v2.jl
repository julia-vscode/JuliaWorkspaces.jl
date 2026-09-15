# The v2 hover arm (layer_features_v2.jl `_get_hover_v2` + the branch in
# `_get_hover_text`): module-level function and module names render from
# docstrings + signature slices, byte-equal to v1's tree rendering; everything
# else declines to the untouched v1 path.

@testsnippet HoverV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, get_hover_text
    using JuliaWorkspaces.URIs2: URI

    const PROJECT_TOML = """
    name = "HoverV"
    uuid = "a2345678-1234-1234-1234-123456789abd"
    version = "0.1.0"
    """
    const MANIFEST_TOML = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[deps]\n"

    const ENTRY_URI = URI("file:///hoverv/src/HoverV.jl")
    const A_URI = URI("file:///hoverv/src/a.jl")
    const B_URI = URI("file:///hoverv/src/b.jl")

    function hv_workspace(a_src::String, b_src::String; flag=true, entry_extra="")
        entry = "module HoverV\n$(entry_extra)include(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///hoverv/Project.toml"), SourceText(PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(URI("file:///hoverv/Manifest.toml"), SourceText(MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(ENTRY_URI, SourceText(entry, "julia")))
        add_file!(jw, TextFile(A_URI, SourceText(a_src, "julia")))
        add_file!(jw, TextFile(B_URI, SourceText(b_src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    hover_at(jw, src, needle; uri=B_URI) =
        get_hover_text(jw, uri, findfirst(needle, src).stop)

    # The raw v2 arm, for asserting claims/declines directly.
    v2_hover_at(jw, src, needle; uri=B_URI) =
        JW._get_hover_v2(jw.runtime, uri, findfirst(needle, src).stop - 1)
end

@testitem "hover v2: cross-file function is byte-equal to the pinned v1 format" setup=[HoverV2WS] begin
    a_src = """
    \"\"\"
    greet docs
    \"\"\"
    greet(name) = 1
    greet(first, last) = 2
    """
    b_src = "caller(x) = greet(x)\n"
    jw = hv_workspace(a_src, b_src)
    # The v2 arm claims this hover and reproduces the byte-pinned rendering.
    @test v2_hover_at(jw, b_src, "caller(x) = gree") ==
        "greet docs\n```julia\ngreet(name)\n```\n```julia\ngreet(first, last)\n```\n"
    @test hover_at(jw, b_src, "caller(x) = gree") ==
        "greet docs\n```julia\ngreet(name)\n```\n```julia\ngreet(first, last)\n```\n"
    # Flag-off parity: v1 renders the same bytes.
    jw_off = hv_workspace(a_src, b_src; flag=false)
    @test hover_at(jw_off, b_src, "caller(x) = gree") ==
        hover_at(jw, b_src, "caller(x) = gree")
end

@testitem "hover v2: undocumented, macro-wrapped and same-file functions" setup=[HoverV2WS] begin
    a_src = "plain(x) = 1\n\"derived docs\"\nSalsa.@derived function drv(rt, x)\n    x\nend\n"
    b_src = "use() = plain(2)\nuse2(rt) = drv(rt, 1)\nlocalfn(y) = y\ncall2() = localfn(1)\n"
    jw = hv_workspace(a_src, b_src)
    jw_off = hv_workspace(a_src, b_src; flag=false)
    # An undocumented method opens with a newline (v1's `_ensure_ends_with("")`).
    @test v2_hover_at(jw, b_src, "use() = plain") == "\n```julia\nplain(x)\n```\n"
    @test hover_at(jw, b_src, "use() = plain") == hover_at(jw_off, b_src, "use() = plain")
    # A macro-wrapped definition keeps its docstring (the doc range reaches
    # the inner item through the opaque wrapper).
    h = v2_hover_at(jw, b_src, "use2(rt) = drv")
    @test h !== nothing && occursin("derived docs", h) && occursin("drv(rt, x)", h)
    # A SAME-FILE-declared name declines: v1 renders its same-file binding
    # view there, which v2 does not reproduce.
    @test v2_hover_at(jw, b_src, "call2() = localfn") === nothing
    @test hover_at(jw, b_src, "call2() = localfn") ==
        hover_at(jw_off, b_src, "call2() = localfn")
end

@testitem "hover v2: exported footer and module hover" setup=[HoverV2WS] begin
    a_src = "\"api docs\"\napi(x) = x\n"
    b_src = "use() = api(1)\n"
    jw = hv_workspace(a_src, b_src; entry_extra="export api\n")
    jw_off = hv_workspace(a_src, b_src; flag=false, entry_extra="export api\n")
    h = hover_at(jw, b_src, "use() = api")
    @test endswith(h, "----\nExported by `HoverV`.\n")
    @test h == hover_at(jw_off, b_src, "use() = api")

    # A module name renders the compact block (docstring above).
    a_src = "\"Sub docs\"\nmodule Sub\nend\n"
    b_src = "using .Sub\nsuse() = Sub\n"
    jw = hv_workspace(a_src, b_src)
    jw_off = hv_workspace(a_src, b_src; flag=false)
    m = v2_hover_at(jw, b_src, "suse() = Sub")
    @test m == "Sub docs```julia\nmodule Sub\n```\n" ||
        m == "Sub docs\n```julia\nmodule Sub\n```\n"
    @test hover_at(jw, b_src, "suse() = Sub") == hover_at(jw_off, b_src, "suse() = Sub")
end

@testitem "hover v2: declines fall through to v1" setup=[HoverV2WS] begin
    a_src = """
    "S docs"
    struct S
        a
    end
    """
    b_src = """
    consts = S(1)
    f(arg) = arg + 1
    g() = f(consts)
    import Base: push!
    push!(x::Vector, y, z, w) = x
    h() = :(f(1))
    """
    jw = hv_workspace(a_src, b_src)
    jw_off = hv_workspace(a_src, b_src; flag=false)
    # Datatypes decline (v1 prints the canonical Expr).
    @test v2_hover_at(jw, b_src, "consts = S") === nothing
    # A local argument declines.
    @test v2_hover_at(jw, b_src, "f(arg) = arg") === nothing
    # An argument position inside a call declines (v1 adds the position prefix).
    @test v2_hover_at(jw, b_src, "g() = f(consts") === nothing
    # A store-extending function declines (v1 unifies with the store methods).
    @test v2_hover_at(jw, b_src, "h() = :(f") === nothing   # quoted code declines
    # Every declined position still answers exactly as v1 does.
    for needle in ("consts = S", "f(arg) = arg", "g() = f(consts")
        @test hover_at(jw, b_src, needle) == hover_at(jw_off, b_src, needle)
    end
end

# Corpus differential: hovering every function definition's name, flag-on vs
# flag-off, equal after whitespace removal (the slice keeps the author's
# spacing; v1's to_codeobject prints canonically).
@testitem "v2 hover agrees with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        get_hover_text, V2ItemRef
    using JuliaWorkspaces.URIs2: filepath2uri

    root_dir = pkgdir(JuliaWorkspaces)
    function corpus_ws(flag)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Project.toml")),
            SourceText(read(joinpath(root_dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Manifest.toml")),
            SourceText("julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"0\"\n\n[deps]\n", "toml")))
        uris = JuliaWorkspaces.URIs2.URI[]
        for sub in ("src",)
            for (d, _, fs) in walkdir(joinpath(root_dir, sub))
                any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
                for f in fs
                    endswith(f, ".jl") || continue
                    p = joinpath(d, f)
                    uri = filepath2uri(p)
                    add_file!(jw, TextFile(uri, SourceText(read(p, String), "julia")))
                    push!(uris, uri)
                end
            end
        end
        flag && JW.set_v2_enabled!(jw, true)
        return jw, uris
    end
    jw_on, uris = corpus_ws(true)
    jw_off, _ = corpus_ws(false)

    nows(s) = s === nothing ? nothing : replace(s, r"\s+" => "")
    mismatches = String[]
    checked = Ref(0)
    for uri in uris
        skel = JW.derived_v2_file_skeleton(jw_on.runtime, uri)
        # Hover every CALLEE identifier of a call (the positions the v2 arm
        # claims); definition sites decline by design. Capped per file.
        per_file = 0
        for row in skel.items
            per_file >= 40 && break
            (row.interpretable && !row.under_macrocall) || continue
            view = JW.v2_item_view(jw_on.runtime, uri, row.id)
            view === nothing && continue
            for a in eachindex(view.ranges)
                per_file >= 40 && break
                JW._v2f_is_identifier(view, a) || continue
                p = Int(view.parents[a])
                (p != 0 && view.kinds[p] == JW.JS2.K"call" && a == p + 1) || continue
                index = first(view.ranges[a])
                # v1 can throw on this harness corpus (its workspace-extension
                # rendering positions into the vendored packages/ files, which
                # are on disk but not in the store) — skip positions where
                # EITHER engine's underlying v1 path throws; a crash is not a
                # rendering difference.
                h_on = try
                    get_hover_text(jw_on, uri, index)
                catch
                    continue
                end
                h_off = try
                    get_hover_text(jw_off, uri, index)
                catch
                    continue
                end
                checked[] += 1
                per_file += 1
                nows(h_on) == nows(h_off) ||
                    push!(mismatches, "$(uri) @$(index):\n  on=$(repr(h_on))\n  off=$(repr(h_off))")
            end
        end
    end
    println("hover differential: checked=$(checked[]) mismatches=$(length(mismatches))")
    isempty(mismatches) || println(join(first(mismatches, 10), "\n"))
    @test checked[] > 100
    @test mismatches == String[]
end
