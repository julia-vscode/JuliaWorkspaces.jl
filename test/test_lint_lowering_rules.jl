@testsnippet LoweringLintWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: LOWERING_TAKEOVER_RULES,
        derived_item_semantic_findings, derived_semantic_lint_findings,
        derived_file_inventory, ItemRef, update_file!
    using JuliaWorkspaces.URIs2: URI

    const LL_URI = URI("file:///ll/src/F.jl")

    function ll_workspace(src::String; flag=true, config::Union{Nothing,String}=nothing)
        jw = JuliaWorkspace()
        if config !== nothing
            add_file!(jw, TextFile(URI("file:///ll/JuliaLint.toml"), SourceText(config, "toml")))
        end
        add_file!(jw, TextFile(LL_URI, SourceText(src, "julia")))
        flag && set_lowering_lint!(jw, true)
        return jw
    end

    ll_codes(jw, code) = filter(d -> d.code === code, get_diagnostic(jw, LL_URI))

    function ll_item_ref(jw, name; uri=LL_URI)
        inv = derived_file_inventory(jw.runtime, uri)
        return ItemRef(uri, only(filter(i -> i.name == name, inv.items)).id)
    end

    const UNUSED_SRC = """
    function f(a, b)
        c = a + 1
        d = 2
        return c
    end
    """
end

@testitem "lowering lint: flag off is exactly legacy behavior" setup=[LoweringLintWS] begin
    jw = ll_workspace(UNUSED_SRC; flag=false)
    for code in (:unused_binding, :unused_function_argument)
        # Whatever StaticLint reports, nothing comes from the lowering producer.
        @test !any(d -> d.source == "JuliaWorkspaces.jl", ll_codes(jw, code))
    end
end

@testitem "lowering lint: unused local and argument flagged, StaticLint suppressed" setup=[LoweringLintWS] begin
    jw = ll_workspace(UNUSED_SRC)

    db = ll_codes(jw, :unused_binding)
    @test length(db) == 1
    @test db[1].source == "JuliaWorkspaces.jl"
    @test occursin("`d`", db[1].message)
    @test db[1].severity === :hint

    da = ll_codes(jw, :unused_function_argument)
    @test length(da) == 1
    @test da[1].source == "JuliaWorkspaces.jl"
    @test occursin("`b`", da[1].message)

    # The range points at the declaration site.
    rng = db[1].range
    @test occursin("d", UNUSED_SRC[first(rng):last(rng)-1])
end

@testitem "lowering lint: loop variables count, negatives stay silent" setup=[LoweringLintWS] begin
    # Unused loop variable is flagged.
    jw = ll_workspace("function f()\n    s = 0\n    for i in 1:3\n        s += 1\n    end\n    return s\nend\n")
    @test any(d -> occursin("`i`", d.message), ll_codes(jw, :unused_binding))

    # `_`-prefixed names are the intentional-unused convention.
    jw = ll_workspace("function f(_unused, x)\n    return x\nend\n")
    @test isempty(ll_codes(jw, :unused_function_argument))

    # A local used only inside a macrocall is NOT unused (semi-transparency).
    jw = ll_workspace("function f()\n    x = 1\n    @show x\n    return nothing\nend\n")
    @test isempty(ll_codes(jw, :unused_binding))

    # A local read by a closure is used.
    jw = ll_workspace("function f()\n    c = 1\n    g = () -> c + 1\n    return g()\nend\n")
    @test !any(d -> occursin("`c`", d.message), ll_codes(jw, :unused_binding))

    # Unused top-level globals are out of scope for this rule.
    jw = ll_workspace("unused_global_thing = 1\n")
    @test isempty(ll_codes(jw, :unused_binding))
end

@testitem "lowering lint: config severity and disabling are honored" setup=[LoweringLintWS] begin
    jw = ll_workspace(UNUSED_SRC;
        config="[rules]\nunused_binding = \"warning\"\n")
    db = ll_codes(jw, :unused_binding)
    @test length(db) == 1
    @test db[1].severity === :warning

    # Both takeover rules off => the gate is closed, nothing is produced.
    jw = ll_workspace(UNUSED_SRC;
        config="[rules]\nunused_binding = \"off\"\nunused_function_argument = \"off\"\n")
    @test isempty(ll_codes(jw, :unused_binding))
    @test isempty(ll_codes(jw, :unused_function_argument))
    @test isempty(derived_semantic_lint_findings(jw.runtime, LL_URI))
end

@testitem "lowering lint: interpolation inside a quoted macrocall is a read" setup=[LoweringLintWS] begin
    # A macrocall inside a `quote` is data — never expanded — so it must be
    # materialized faithfully. Flattening it would destroy the `$` nodes and
    # make the interpolated variable look unused (both engines' worst FP class
    # in the 2026-08-11 top-100 sweep).
    jw = ll_workspace("macro m(T)\n    quote\n        @generated f(\$(esc(T))) = 1\n    end\nend\n")
    @test isempty(ll_codes(jw, :unused_function_argument))

    # Same shape without the nested macrocall, as a control.
    jw = ll_workspace("macro m(T)\n    quote\n        f(\$(esc(T))) = 1\n    end\nend\n")
    @test isempty(ll_codes(jw, :unused_function_argument))

    # A macro argument that really is unused must still be reported.
    jw = ll_workspace("macro m(x)\n    quote\n        1 + 1\n    end\nend\n")
    @test length(ll_codes(jw, :unused_function_argument)) == 1
end

@testitem "lowering lint: one finding per source declaration" setup=[LoweringLintWS] begin
    # Desugaring duplicates a destructuring pattern into the filter closure and
    # the body closure; each reads only one name, but each read sits at a real
    # use site, so the variable counts as used.
    jw = ll_workspace("f(d) = [String(n) for (n, c) in d if c isa Int]\n")
    @test isempty(ll_codes(jw, :unused_binding))

    # Without the filter, `c` genuinely is unused.
    jw = ll_workspace("f(d) = [String(n) for (n, c) in d]\n")
    @test length(ll_codes(jw, :unused_binding)) == 1

    # Genuinely-unused names under a filter are still reported, once each.
    jw = ll_workspace("f(d) = [1 for (n, c) in d if true]\n")
    @test length(ll_codes(jw, :unused_binding)) == 2
end

@testitem "lowering lint: annotation macros are structurally transparent" setup=[LoweringLintWS] begin
    # `@inline` and friends hand their argument through unchanged, so they are
    # unwrapped without executing anything. Before this, `@inline f(x, y) = x`
    # hid the definition entirely and `@nospecialize` in argument position hid
    # the whole signature — together the largest source of missed bindings in
    # the top-100 corpus sweep.
    for src in ("@inline f(x, y) = x\n",
                "@inline function f(x, y)\n    return x\nend\n",
                "@noinline function f(x, y)\n    return x\nend\n",
                "Base.@propagate_inbounds function f(x, y)\n    return x\nend\n")
        jw = ll_workspace(src)
        codes = ll_codes(jw, :unused_function_argument)
        @test length(codes) == 1
        @test occursin("`y`", codes[1].message)
    end

    # `@nospecialize` sits in argument position: unwrapping it must leave the
    # signature intact, so BOTH unused arguments are still seen.
    jw = ll_workspace("f(@nospecialize(x::Int), y) = 1\n")
    @test length(ll_codes(jw, :unused_function_argument)) == 2

    # A local inside an `@inbounds` block is ordinary code.
    jw = ll_workspace("function f(x)\n    @inbounds begin\n        z = 1\n    end\n    return x\nend\n")
    @test length(ll_codes(jw, :unused_binding)) == 1

    # A macro NOT in the table stays opaque, and its identifiers count as reads.
    jw = ll_workspace("function f()\n    x = 1\n    @show x\n    nothing\nend\n")
    @test isempty(ll_codes(jw, :unused_binding))
end

@testitem "lowering lint: names mentioned inside a quote count as used" setup=[LoweringLintWS] begin
    # A quote lowers to inert data, so a name mentioned only inside one is not
    # lexically read — but renaming it changes what the quoted code means, and
    # for `@generated` bodies it breaks the generated method. Treat mentions
    # inside a quote as uses, the same way opaque macrocalls are treated.
    jw = ll_workspace("@generated function f(x, n)\n    return quote\n        x + 1\n    end\nend\n")
    codes = ll_codes(jw, :unused_function_argument)
    @test length(codes) == 1              # `n` only
    @test occursin("`n`", codes[1].message)

    jw = ll_workspace("function f(x)\n    return :(x + 1)\nend\n")
    @test isempty(ll_codes(jw, :unused_function_argument))

    # An argument mentioned nowhere — quote or otherwise — is still reported.
    jw = ll_workspace("@generated function f(x, n)\n    return quote\n        99\n    end\nend\n")
    @test length(ll_codes(jw, :unused_function_argument)) == 2
end

@testitem "lowering lint: default-valued arguments are still checked" setup=[LoweringLintWS] begin
    # An argument with a default desugars into a forwarding method that reads
    # the argument only to pass it on. That synthesized read carries the
    # declaration's own address, so it must not count as a use — otherwise
    # every optional positional argument and keyword argument silently stops
    # being checked.
    jw = ll_workspace("f(a, b = 2) = 3\n")
    @test length(ll_codes(jw, :unused_function_argument)) == 2

    jw = ll_workspace("f(x; verbose=false, pad=\"\") = x\n")
    @test length(ll_codes(jw, :unused_function_argument)) == 2

    # ... and a default-valued argument that IS used stays quiet.
    jw = ll_workspace("f(a, b = 2) = a + b\n")
    @test isempty(ll_codes(jw, :unused_function_argument))
end

@testitem "lowering lint: findings backdate across position-only edits" setup=[LoweringLintWS] begin
    jw = ll_workspace(UNUSED_SRC)
    ref = ll_item_ref(jw, "f")
    f1 = derived_item_semantic_findings(jw.runtime, ref)
    @test !isempty(f1)

    update_file!(jw, TextFile(LL_URI, SourceText("# header\n\n" * UNUSED_SRC, "julia")))
    f2 = derived_item_semantic_findings(jw.runtime, ref)
    @test isequal(f1, f2)
end
