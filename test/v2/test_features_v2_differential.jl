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
            # Second cursor family: GLOBAL declaration sites — document
            # highlight is the only v2 consumer, compared with the same
            # equal-or-subset discipline.
            for b in low.bindings
                file_cursors[] >= 60 && break
                b.kind === :global || continue
                (b.is_internal || b.addr == Int32(0)) && continue
                a = Int(b.addr)
                (1 <= a <= length(view.ranges) && JW._v2f_is_identifier(view, a)) || continue
                offset0 = JW._v2f_start0(view.ranges[a])
                file_cursors[] += 1
                cursors[] += 1
                h_on = rngs(JW._get_highlights(jw_on.runtime, uri, offset0))
                h_off = rngs(JW._get_highlights(jw_off.runtime, uri, offset0))
                if h_on != h_off
                    if issubset(h_off, h_on)
                        push!(saw, :v2_superset)
                    elseif issubset(h_on, h_off)
                        push!(saw, :v1_superset)
                    else
                        push!(problems, "$(uri)@$(offset0) `$(b.name)`: crossing global-highlight sets on=$(length(h_on)) off=$(length(h_off))")
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

@testitem "v2 module-at agrees with v1 across the package corpus" begin
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

    problems = String[]
    samples = Ref(0)
    saw_mat = Set{Symbol}()
    for uri in uris
        maps = JW.derived_v2_file_maps(jw_on.runtime, uri)
        offsets = Set{Int}()
        for row in JW.derived_v2_file_skeleton(jw_on.runtime, uri).items
            length(offsets) >= 25 && break
            ranges = get(maps, row.id, nothing)
            (ranges === nothing || isempty(ranges)) && continue
            o = JW._v2f_start0(ranges[1])
            push!(offsets, o)
            o > 0 && push!(offsets, o - 1)
        end
        for o in sort!(collect(offsets))
            samples[] += 1
            a = JW._get_module_at(jw_on.runtime, uri, o)
            b = JW._get_module_at(jw_off.runtime, uri, o)
            a == b && continue
            # Declared class :file_head_prefix — v1's `_get_expr_or_parent`
            # walk starts at pos=1, so the first byte or two of a file answers
            # "Main" even when the file splices into a module; v2 reports the
            # splice prefix (the correct answer). Tightly keyed.
            if b == "Main" && o <= 1
                root = JW.derived_v2_best_root_for_uri(jw_on.runtime, uri)
                prefix = root === nothing ? nothing :
                    JW.derived_v2_file_module_path(jw_on.runtime, root, uri)
                if prefix !== nothing && a == join(prefix, ".")
                    push!(saw_mat, :file_head_prefix)
                    continue
                end
            end
            push!(problems, "$(uri)@$(o): on=$(a) off=$(b)")
        end
    end

    println("module-at differential: samples=$(samples[]) classes=$(sort!(collect(saw_mat)))")
    isempty(problems) || println("problems:\n  " * join(first(problems, 30), "\n  "))
    @test samples[] > 300
    @test problems == String[]
end

@testitem "v2 document links agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    root_dir = pkgdir(JuliaWorkspaces)

    function corpus_workspace(flag)
        jw = JuliaWorkspace()
        uris = JuliaWorkspaces.URIs2.URI[]
        for (d, _, fs) in walkdir(joinpath(root_dir, "src"))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") || continue
                p = joinpath(d, f)
                uri = filepath2uri(p)
                add_file!(jw, TextFile(uri, SourceText(read(p, String), "julia")))
                push!(uris, uri)
            end
        end
        flag && JW.set_v2_features!(jw, true)
        return jw, uris
    end

    jw_on, uris = corpus_workspace(true)
    jw_off, _ = corpus_workspace(false)

    problems = String[]
    total_on = Ref(0)
    saw_docstring = Ref(0)
    for uri in uris
        t_on = Set(string(l.target_uri) for l in JW._get_document_links(jw_on.runtime, uri))
        t_off = Set(string(l.target_uri) for l in JW._get_document_links(jw_off.runtime, uri))
        total_on[] += length(t_on)
        # v2-only targets would be phantom links: none allowed. v1-only
        # targets must come from docstring contents (the declared class) —
        # counted, not enumerated per target (string literals inside
        # docstrings are invisible to v2's walk by design).
        v2only = setdiff(t_on, t_off)
        isempty(v2only) ||
            push!(problems, "$(uri): v2-only link targets $(collect(v2only))")
        saw_docstring[] += length(setdiff(t_off, t_on))
    end

    println("document links differential: v2_links=$(total_on[]) v1_only_targets=$(saw_docstring[])")
    isempty(problems) || println("problems:\n  " * join(first(problems, 20), "\n  "))
    @test total_on[] > 20
    @test problems == String[]
end

@testitem "v2 document symbols agree with v1 across the package corpus" begin
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

    # Names of symbols whose ancestors are all containers (Module=2,
    # Namespace=3, or Enum=10 — v2 nests @enum members under the enum symbol
    # while v1 lists them flat) — the top-level-scope definition surface.
    function scope_names!(out, syms)
        for s in syms
            push!(out, startswith(s.name, "@") ? s.name[nextind(s.name, 1):end] : s.name)
            s.kind in (2, 3, 10) && scope_names!(out, s.children)
        end
        return out
    end

    problems = String[]
    total_on = Ref(0)
    for uri in uris
        on = JW._get_document_symbols(jw_on.runtime, uri)
        off = JW._get_document_symbols(jw_off.runtime, uri)
        n_on = scope_names!(Set{String}(), on)
        n_off = scope_names!(Set{String}(), off)
        total_on[] += length(n_on)
        for name in setdiff(n_off, n_on)
            # Every v1-only scope name must be macro-declared machinery or a
            # name inside a @testitem body (opaque in v2) — verified against
            # the v1 inventory: any name with a plain-declaration v1 row that
            # v2 misses is a hard failure.
            inv1 = JW.derived_file_inventory(jw_off.runtime, uri)
            rows = [i for i in inv1.items if i.name == name || i.name == "@" * name]
            plain = [i for i in rows if i.kind !== :macro_declared]
            ti_segments = Set{String}(ti.segment for ti in inv1.testitems)
            in_ti(i) = any(seg -> seg in ti_segments, i.parent_module)
            if !isempty(plain) && !all(in_ti, plain)
                push!(problems, "$(uri): v1-only scope symbol `$name` with a plain declaration")
            end
        end
    end

    println("document symbols differential: v2 scope symbols=$(total_on[])")
    isempty(problems) || println("problems:\n  " * join(first(problems, 30), "\n  "))
    @test total_on[] > 500
    @test problems == String[]
end

@testitem "v2 block range agrees with v1 across the package corpus" begin
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

    flat(b) = b === nothing ? nothing :
        (b.block_start, b.highlight_start, b.highlight_stop, b.block_stop)

    problems = String[]
    samples = Ref(0)
    v2_answers = Ref(0)
    for uri in uris
        maps = JW.derived_v2_file_maps(jw_on.runtime, uri)
        offsets = Set{Int}()
        for row in JW.derived_v2_file_skeleton(jw_on.runtime, uri).items
            length(offsets) >= 40 && break
            ranges = get(maps, row.id, nothing)
            (ranges === nothing || isempty(ranges)) && continue
            s = JW._v2f_start0(ranges[1])
            e = JW._v2f_stop0(ranges[1])
            push!(offsets, s)
            push!(offsets, (s + e) ÷ 2)
            push!(offsets, e + 1)   # gap byte
        end
        for o in sort!(collect(offsets))
            samples[] += 1
            a = flat(JW._get_current_block_range(jw_on.runtime, uri, o))
            b = flat(JW._get_current_block_range(jw_off.runtime, uri, o))
            a == b && continue
            # Declared class :v2_answers — v1 returns NOTHING (its doc-wrapped
            # module-body walk gives up) where v2 produces a block; strictly
            # more useful, counted rather than failed. Everything else fails.
            if b === nothing && a !== nothing
                v2_answers[] += 1
            else
                push!(problems, "$(uri)@$(o): on=$(a) off=$(b)")
            end
        end
    end

    println("block range differential: samples=$(samples[]) v2_answers_where_v1_nothing=$(v2_answers[])")
    isempty(problems) || println("problems:\n  " * join(first(problems, 20), "\n  "))
    @test samples[] > 500
    @test problems == String[]
end
