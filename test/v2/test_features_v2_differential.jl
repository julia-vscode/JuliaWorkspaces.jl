# The references-family differential: over this repo's corpus, place the
# cursor at LOCAL-binding identifier occurrences (exactly the surface the v2
# swap answers) and compare flag-off (v1) vs flag-on (v2) results.
#
# Comparison discipline: the two engines legitimately disagree in DECLARED
# ways, each a ratchet class —
#   :v2_superset  — v2's real scoping finds occurrences v1's loose_refs walk
#       missed (closure captures through nested scopes, where-params);
#   :v1_superset  — v1's name-matched loose_refs over-reports (shadowed
#       bindings conflated) where v2 separates scopes;
#   :def_range_name_vs_expr — goto-def: v1 targets the whole defining
#       expression, v2 the declaration NAME (deliberate; v2 range must sit
#       INSIDE a v1 range);
#   :write_kind_delta — highlight ranges agree, read/write kinds differ.
# Anything else — crossing/disjoint reference sets, a v2 definition outside
# every v1 definition — fails hard.

@testitem "v2 local references agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    root_dir = pkgdir(JuliaWorkspaces)

    function corpus_workspace(flag)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Project.toml")),
            SourceText(read(joinpath(root_dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Manifest.toml")),
            SourceText("julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"0\"\n\n[deps]\n", "toml")))
        # EVERY src file goes into the workspace (v1's per-file analysis
        # demands the whole include closure as inputs — a missing vendored
        # file KeyErrors); cursors are only placed OUTSIDE the vendored dirs.
        uris = JuliaWorkspaces.URIs2.URI[]
        for (d, _, fs) in walkdir(joinpath(root_dir, "src"))
            vendored = any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages"))
            for f in fs
                endswith(f, ".jl") || continue
                p = joinpath(d, f)
                uri = filepath2uri(p)
                add_file!(jw, TextFile(uri, SourceText(read(p, String), "julia")))
                vendored || push!(uris, uri)
            end
        end
        flag && JW.set_v2_features!(jw, true)
        return jw, uris
    end

    jw_on, uris = corpus_workspace(true)
    jw_off, _ = corpus_workspace(false)
    @test length(uris) > 40

    rngs(v) = Set((r.start, r.stop) for r in v)

    saw = Set{Symbol}()
    problems = String[]
    cursors = Ref(0)
    declines = Ref(0)

    for uri in uris
        skel = JW.derived_v2_file_skeleton(jw_on.runtime, uri)
        maps = JW.derived_v2_file_maps(jw_on.runtime, uri)
        file_cursors = Ref(0)
        for row in skel.items
            file_cursors[] >= 40 && break
            (row.kind === :opaque_macrocall || !row.interpretable || row.under_macrocall) && continue
            ref = JW.V2ItemRef(uri, row.id)
            low = JW.derived_item_lowering(jw_on.runtime, ref)
            (low === nothing || low.status !== :ok) && continue
            view = JW.v2_item_view(jw_on.runtime, uri, row.id)
            view === nothing && continue
            # One cursor per local binding: its declaration site.
            for b in low.bindings
                file_cursors[] >= 40 && break
                b.kind in JW._V2_LOCAL_BINDING_KINDS || continue
                (b.is_internal || b.is_ssa || b.addr == Int32(0)) && continue
                a = Int(b.addr)
                (1 <= a <= length(view.ranges) && JW._v2f_is_identifier(view, a)) || continue
                offset0 = JW._v2f_start0(view.ranges[a])
                file_cursors[] += 1
                cursors[] += 1

                JW.v2_local_occurrences(jw_on.runtime, uri, offset0) === nothing && (declines[] += 1)

                r_on = rngs(JW._get_references(jw_on.runtime, uri, offset0))
                r_off = rngs(JW._get_references(jw_off.runtime, uri, offset0))
                if r_on != r_off
                    if issubset(r_off, r_on)
                        push!(saw, :v2_superset)
                    elseif issubset(r_on, r_off)
                        push!(saw, :v1_superset)
                    else
                        push!(problems, "$(uri)@$(offset0) `$(b.name)`: crossing reference sets on=$(length(r_on)) off=$(length(r_off))")
                    end
                end

                h_on = JW._get_highlights(jw_on.runtime, uri, offset0)
                h_off = JW._get_highlights(jw_off.runtime, uri, offset0)
                if rngs(h_on) == rngs(h_off)
                    Set((h.start, h.stop, h.kind) for h in h_on) ==
                        Set((h.start, h.stop, h.kind) for h in h_off) || push!(saw, :write_kind_delta)
                end

                d_on = JW._get_definitions(jw_on.runtime, uri, offset0)
                d_off = JW._get_definitions(jw_off.runtime, uri, offset0)
                if rngs(d_on) != rngs(d_off) && !isempty(d_on) && !isempty(d_off)
                    contained(dv2) = any(d1 -> (d1.start.line < dv2.start.line ||
                            (d1.start.line == dv2.start.line && d1.start.column <= dv2.start.column)) &&
                            (dv2.stop.line < d1.stop.line ||
                            (dv2.stop.line == d1.stop.line && dv2.stop.column <= d1.stop.column)), d_off)
                    if all(contained, d_on)
                        push!(saw, :def_range_name_vs_expr)
                    else
                        push!(problems, "$(uri)@$(offset0) `$(b.name)`: v2 definition outside every v1 definition")
                    end
                end
            end
        end
    end

    println("references differential: cursors=$(cursors[]) v2_declines=$(declines[]) " *
        "($(round(100declines[]/max(cursors[],1); digits=1))%) classes=$(sort!(collect(saw)))")
    isempty(problems) || println("problems:\n  " * join(first(problems, 30), "\n  "))
    @test cursors[] > 300
    @test problems == String[]
end

@testitem "v2 workspace symbols agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    root_dir = pkgdir(JuliaWorkspaces)

    function corpus_workspace(flag)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Project.toml")),
            SourceText(read(joinpath(root_dir, "Project.toml"), String), "toml")))
        add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Manifest.toml")),
            SourceText("julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"0\"\n\n[deps]\n", "toml")))
        for (d, _, fs) in walkdir(joinpath(root_dir, "src"))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") || continue
                p = joinpath(d, f)
                add_file!(jw, TextFile(filepath2uri(p), SourceText(read(p, String), "julia")))
            end
        end
        flag && JW.set_v2_features!(jw, true)
        return jw
    end

    on = JW._get_workspace_symbols(corpus_workspace(true).runtime, "")
    off = JW._get_workspace_symbols(corpus_workspace(false).runtime, "")
    key(s) = (s.name, s.uri)
    s_on, s_off = Set(key.(on)), Set(key.(off))

    # v2-only names would be phantom symbols: none allowed.
    v2_only = collect(setdiff(s_on, s_off))
    isempty(v2_only) || println("v2-only symbols:\n  " * join(first(v2_only, 20), "\n  "))
    @test isempty(v2_only)
    # v1-only names must be the macro-declared machinery (generated names like
    # `set_foo!` for `@declare_input foo(...)`), which v2 deliberately has no
    # rows for — verified per name against the V1 inventory's own kind, so a
    # plain source declaration v2 simply missed can never hide here.
    v1_only = collect(setdiff(s_off, s_on))
    jw_probe = corpus_workspace(false)
    for (name, uri) in v1_only
        inv1 = JW.derived_file_inventory(jw_probe.runtime, uri)
        kinds = [i.kind for i in inv1.items if i.name == name]
        @test !isempty(kinds) && all(k -> k === :macro_declared, kinds)
    end
    println("workspace symbols differential: on=$(length(s_on)) off=$(length(s_off)) v1_only=$(length(v1_only))")
    @test length(s_on) > 500
end
