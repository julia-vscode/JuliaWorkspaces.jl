# Process-free tests for DJP-side macro expansion (src/v2/layer_expansion.jl +
# the splice in layer_lowering.jl): everything from the harvest to the spliced
# lowering, driven by writing `input_macro_expansions` directly — no child
# process. The transport is covered by the reactor tests
# (test_dynamic_expansion.jl) and the end-to-end fixture.

@testsnippet ExpansionWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, update_file!
    using JuliaWorkspaces.URIs2: URI

    # A package WITH a manifest, so the file has a real project environment —
    # `derived_v2_expansion_env` requires one.
    function exp_make_jw(src)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pkg/Project.toml"), SourceText(
            "name = \"MyPkg\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9a5\"\nversion = \"1.0.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///pkg/Manifest.toml"), SourceText(
            "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n", "toml")))
        uri = URI("file:///pkg/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        JW.set_v2_enabled!(jw, true)
        JW.set_macro_expansion!(jw, true)
        return jw, uri
    end

    function exp_first_ref(jw, uri)
        inv = JW.derived_v2_file_inventory(jw.runtime, uri)
        return JW.V2ItemRef(uri, inv.items[1].id)
    end

    settle!(jw, pairs...) = JW.set_input_macro_expansions!(jw.runtime,
        Dict{JW.ExpansionKey,JW.ExpansionOutcome}(pairs...))
end

@testitem "expansion: harvest finds opaque macrocalls with content keys" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("""
    function f(x)
        @somemacro x
        return 1
    end
    g() = @othermacro 2
    plain() = 3
    """)

    req = JW.derived_required_macro_expansions(jw.runtime)
    @test length(req) == 2
    @test allunique(r.key for r in req)
    @test all(r -> r.imports == ["using MyPkg"], req)
    @test all(r -> r.key.env_hash == JW.derived_v2_expansion_env(jw.runtime, uri).env_hash, req)

    # Transparent and test-block macros are not expansion sites.
    jw2, uri2 = exp_make_jw("@inline h(x) = x\n")
    @test isempty(JW.derived_required_macro_expansions(jw2.runtime))

    # The flag off ⇒ empty harvest and empty per-item dict.
    JW.set_macro_expansion!(jw, false)
    @test isempty(JW.derived_required_macro_expansions(jw.runtime))
    @test isempty(JW.derived_item_expansions(jw.runtime, exp_first_ref(jw, uri)))
end

@testitem "expansion: splice changes lowering, union guard keeps fallback reads" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("""
    function f(x)
        @somemacro x
        return 1
    end
    """)
    ref = exp_first_ref(jw, uri)
    req = JW.derived_required_macro_expansions(jw.runtime)
    @test length(req) == 1
    key = req[1].key

    low1 = JW.derived_item_lowering(jw.runtime, ref)
    @test low1.status === :ok
    names1 = Set(b.name for b in low1.bindings)
    @test "y_from_macro" ∉ names1

    settle!(jw, key => (status=:ok, text="y_from_macro = x + 1"))

    low2 = JW.derived_item_lowering(jw.runtime, ref)
    @test low2.status === :ok
    by_name = Dict(b.name => b for b in low2.bindings)
    # The macro-introduced binding exists, anchors at addr 0 (rule-exempt)…
    @test haskey(by_name, "y_from_macro")
    @test by_name["y_from_macro"].addr == 0
    # …and the user argument still counts as read (kept by the union guard AND
    # genuinely read inside the expansion).
    @test by_name["x"].is_read

    # The settled key leaves the harvest.
    @test isempty(JW.derived_required_macro_expansions(jw.runtime))

    # No unused_binding finding may point at the macrocall: addr-0 bindings are
    # exempt in the rules.
    findings = JW.derived_item_semantic_findings(jw.runtime, ref)
    @test all(f -> f.rule_id != :unused_binding || true, findings)   # smoke: query runs
    @test !any(f -> f.addr == 0, findings)
end

@testitem "expansion: failed and unparseable results keep the fallback" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("""
    function f(x)
        @somemacro x
        return 1
    end
    """)
    ref = exp_first_ref(jw, uri)
    key = JW.derived_required_macro_expansions(jw.runtime)[1].key
    baseline = JW.derived_item_lowering(jw.runtime, ref)

    # :failed (the negative cache): identical lowering, and the key stops
    # being required.
    settle!(jw, key => (status=:failed, text=""))
    @test isequal(JW.derived_item_lowering(jw.runtime, ref), baseline)
    @test isempty(JW.derived_required_macro_expansions(jw.runtime))

    # :ok with unparseable text (a spliced runtime object): same fallback.
    settle!(jw, key => (status=:ok, text="\$(Expr(:meta, :garbage) 12 ["))
    @test isequal(JW.derived_item_lowering(jw.runtime, ref), baseline)
end

@testitem "expansion: position edits do not re-key, macro-def edits do" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("""
    function f(x)
        @somemacro x
        return 1
    end
    """)
    key1 = JW.derived_required_macro_expansions(jw.runtime)[1].key

    # A comment above everything shifts positions only: same key.
    update_file!(jw, TextFile(uri, SourceText("# c\nfunction f(x)\n    @somemacro x\n    return 1\nend\n", "julia")))
    key2 = JW.derived_required_macro_expansions(jw.runtime)[1].key
    @test key1 == key2

    # Adding a `macro` definition to the package changes the macro-defs hash,
    # which re-keys the context (D2b: deved macro edits re-expand).
    add_file!(jw, TextFile(URI("file:///pkg/src/m.jl"), SourceText("macro somemacro(x) esc(x) end\n", "julia")))
    key3 = JW.derived_required_macro_expansions(jw.runtime)[1].key
    @test key3.ctx_hash != key2.ctx_hash
    @test key3.mac_hash == key2.mac_hash
end

@testitem "expansion: readiness gate settles on ok, failed, and impossibility" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("""
    function f(x)
        @somemacro x
        return 1
    end
    """)
    key = JW.derived_required_macro_expansions(jw.runtime)[1].key

    # Pending: not ready. Settled (either way): ready.
    @test !JW.derived_file_expansion_ready(jw.runtime, uri)
    settle!(jw, key => (status=:failed, text=""))
    @test JW.derived_file_expansion_ready(jw.runtime, uri)
    settle!(jw, key => (status=:ok, text="x + 1"))
    @test JW.derived_file_expansion_ready(jw.runtime, uri)

    # Flag off: always ready.
    JW.set_macro_expansion!(jw, false)
    settle!(jw)
    @test JW.derived_file_expansion_ready(jw.runtime, uri)

    # No expansion sites: ready even while the flag is on.
    jw2, uri2 = exp_make_jw("plain() = 1\n")
    @test JW.derived_file_expansion_ready(jw2.runtime, uri2)
end

