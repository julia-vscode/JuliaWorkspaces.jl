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

    # The expansion key of the file's `idx`-th OPAQUE macrocall row (its single
    # site), computed directly so it stays valid after the key has settled.
    # (A macrocall's arguments are walked into items of their own, so plain
    # item indices do not enumerate the macrocalls.)
    function exp_key_for(jw, uri, idx)
        rows = filter(r -> r.kind === :opaque_macrocall, JW.derived_v2_file_skeleton(jw.runtime, uri).items)
        id = rows[idx].id
        env = JW.derived_v2_expansion_env(jw.runtime, uri)
        ctx = JW.derived_v2_expansion_context(jw.runtime, uri)
        site = only(JW.derived_v2_item_expansion_sites(jw.runtime, JW.V2ItemRef(uri, id)))
        return JW.ExpansionKey((env.env_hash, ctx.ctx_hash, site.mac_hash))
    end

    # The key of the first expansion site of the file's `idx`-th item (any
    # kind) — for body-level macrocalls.
    function exp_key_for_site(jw, uri, idx)
        id = JW.derived_v2_file_skeleton(jw.runtime, uri).items[idx].id
        env = JW.derived_v2_expansion_env(jw.runtime, uri)
        ctx = JW.derived_v2_expansion_context(jw.runtime, uri)
        site = first(JW.derived_v2_item_expansion_sites(jw.runtime, JW.V2ItemRef(uri, id)))
        return JW.ExpansionKey((env.env_hash, ctx.ctx_hash, site.mac_hash))
    end

    exp_blind(jw, uri) = JW.derived_v2_module_has_opaque_macrocall(jw.runtime, uri, String[])
    exp_names(jw, uri) = JW.derived_v2_module_names(jw.runtime, uri, String[])
    const EXP_OPT_IN = "[rules]\nanalysis_boundary = \"warning\"\n"
end

@testitem "expansion: the source fallback blinds missing_reference and keeps soft-scope findings" setup=[ExpansionWS] begin
    # MacroTools' `if @capture(ex, f_ where {params1__}) … f …`: the
    # expansion binds `f`, but when the lowering cannot digest it and falls
    # back to the source, the reads of `f` are not missing references.
    src = "function g(ex)\n    if @cap(ex, f_)\n        f\n    end\nend\n"
    jw, uri = exp_make_jw(src)
    ref = exp_first_ref(jw, uri)
    key = exp_key_for_site(jw, uri, 1)
    mr(jw) = count(f -> f.rule_id === :missing_reference, JW.derived_item_missing_reference_findings(jw.runtime, ref))
    settle!(jw, key => (status=:ok, text="(f = 1; break; true)"))   # indigestible: `break` outside a loop
    @test JW.derived_item_lowering(jw.runtime, ref).fallback
    @test mr(jw) == 0
    settle!(jw, key => (status=:ok, text="(f = 1; true)"))          # digestible: `f` is bound
    @test !JW.derived_item_lowering(jw.runtime, ref).fallback
    @test mr(jw) == 0

    # ForwardDiff's `v = f(x)` at the top level then `for f in fs; v = f(X);
    # @test v … end`: an indigestible expansion of the `@test` must not lose
    # the soft-scope finding.
    src2 = "v = 1\nfor f in fs\n    v = f(2)\n    @chk v\nend\n"
    jw2, uri2 = exp_make_jw(src2)
    rows = JW.derived_v2_file_skeleton(jw2.runtime, uri2).items
    loop = JW.V2ItemRef(uri2, rows[end].id)
    key2 = first(JW.derived_v2_item_expansion_sites(jw2.runtime, loop))
    env2 = JW.derived_v2_expansion_env(jw2.runtime, uri2); ctx2 = JW.derived_v2_item_expansion_context(jw2.runtime, loop)
    settle!(jw2, JW.ExpansionKey((env2.env_hash, ctx2.ctx_hash, key2.mac_hash)) => (status=:ok, text="(1 = v)"))   # indigestible: an invalid assignment target
    @test JW.derived_item_lowering(jw2.runtime, loop).fallback
    @test count(f -> f.rule_id === :soft_scope_ambiguity, JW.derived_item_soft_scope_findings(jw2.runtime, loop)) == 1
end

@testitem "expansion: a site inside an in-file module expands in that module" setup=[ExpansionWS] begin
    # PlotsBase's `Commons.jl` declares `module Commons` with its own macro
    # and uses it inside: the child must expand in `PlotsBase.Commons`, not
    # in the file's splice module `PlotsBase`, or the macro is undefined.
    src = "module Commons\nusing Printf\nmacro gen(names...)\n    :(nothing)\nend\n@gen a b\nend\n@gen c\n"
    jw, uri = exp_make_jw(src)
    rows = filter(r -> r.kind === :opaque_macrocall, JW.derived_v2_file_skeleton(jw.runtime, uri).items)
    @test length(rows) == 2
    inner = only(filter(r -> r.parent_module == ["Commons"], rows))
    outer = only(filter(r -> isempty(r.parent_module), rows))
    ctx_inner = JW.derived_v2_item_expansion_context(jw.runtime, JW.V2ItemRef(uri, inner.id))
    ctx_outer = JW.derived_v2_item_expansion_context(jw.runtime, JW.V2ItemRef(uri, outer.id))
    @test ctx_inner.modpath == ["MyPkg", "Commons"]
    @test ctx_outer.modpath == ["MyPkg"]
    @test ctx_outer == JW.derived_v2_expansion_context(jw.runtime, uri)
    @test "using Printf" in ctx_inner.imports
    @test !("using Printf" in ctx_outer.imports)
    @test ctx_inner.ctx_hash != ctx_outer.ctx_hash
    # The required set carries the item's own context to the child.
    req = JW.derived_required_macro_expansions(jw.runtime)
    by_item = Dict(r.item_id => r for r in req)
    @test by_item[inner.id].ctx_module == ["MyPkg", "Commons"]
    @test by_item[outer.id].ctx_module == ["MyPkg"]
    @test by_item[inner.id].ctx_id != by_item[outer.id].ctx_id
end

@testitem "expansion: an expansion the lowering cannot digest falls back to the source" setup=[ExpansionWS] begin
    # StatsPlots' `@recipe function f(...)  group != nothing … end`: the DSL
    # expands cleanly to an `apply_recipe` method the lowering rejects. The
    # macrocall row is the carrier of the source-shape findings inside the
    # recipe, so it must still lower from its source — as a failed expansion
    # does — or a SUCCESSFUL expansion silences them.
    src = "@recipe function f(x)\n    x != nothing\nend\n"
    jw, uri = exp_make_jw(src)
    row = only(filter(r -> r.kind === :opaque_macrocall, JW.derived_v2_file_skeleton(jw.runtime, uri).items))
    ref = JW.V2ItemRef(uri, row.id)
    row_nc(jw) = count(f -> f.rule_id === :nothing_comparison, JW.derived_item_semantic_findings(jw.runtime, ref))
    file_nc(jw) = count(f -> f.rule_id === :nothing_comparison, JW.derived_semantic_lint_findings(jw.runtime, uri))
    key = exp_key_for(jw, uri, 1)
    # Pending: the source fallback reports it.
    @test row_nc(jw) == 1
    n_file = file_nc(jw)
    @test n_file >= 1
    # A digestible expansion keeps it (the walk is over the source body).
    settle!(jw, key => (status=:ok, text="function f(x)\n    x != nothing\nend"))
    @test JW.derived_item_lowering(jw.runtime, ref).status === :ok
    @test row_nc(jw) == 1
    @test file_nc(jw) == n_file
    # An expansion the lowering rejects (`break` outside a loop): the item
    # lowers from its source instead of losing every finding.
    settle!(jw, key => (status=:ok, text="function f(x)\n    x != nothing\n    break\nend"))
    @test JW.derived_item_lowering(jw.runtime, ref).status === :ok
    @test row_nc(jw) == 1
    @test file_nc(jw) == n_file
    # Failed expansion: the fallback, as before.
    settle!(jw, key => (status=:failed, text="boom"))
    @test row_nc(jw) == 1
    @test file_nc(jw) == n_file
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


@testitem "expansion env: manifest-less packages route to the standalone project" setup=[ExpansionWS] begin
    # A plain checkout (Project.toml, no Manifest.toml) has no project in
    # `derived_project_for_file`'s sense, but the dynamic tier materializes a
    # standalone scratch project for it — expansion batches route there (M1b).
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nm/Project.toml"), SourceText(
        "name = \"NoManifest\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9a6\"\nversion = \"1.0.0\"\n", "toml")))
    uri = URI("file:///nm/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText("f(x) = @somemacro x\n", "julia")))
    JW.set_v2_enabled!(jw, true)
    JW.set_macro_expansion!(jw, true)

    env = JW.derived_v2_expansion_env(jw.runtime, uri)
    @test env !== nothing
    @test env.key isa JW.CreateStandaloneProjectKey
    pkg = JW.derived_package(jw.runtime, URI("file:///nm"))
    @test env.env_hash == pkg.content_hash
    # The harvest picks the site up through the standalone env.
    @test !isempty(JW.derived_required_macro_expansions(jw.runtime))

    # Test files' env is the TEST child, which the expansion revive path
    # cannot serve — deferred, expansion stays off for them.
    test_uri = URI("file:///nm/test/runtests.jl")
    add_file!(jw, TextFile(test_uri, SourceText("g() = @somemacro 1\n", "julia")))
    @test JW.derived_v2_expansion_env(jw.runtime, test_uri) === nothing

    # A manifest-bearing package keeps the watch-env route.
    jw2, uri2 = exp_make_jw("f(x) = @somemacro x\n")
    @test JW.derived_v2_expansion_env(jw2.runtime, uri2).key isa JW.WatchEnvironmentKey
end

@testitem "expansion ctx: module path travels and re-keys the context" setup=[ExpansionWS] begin
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mp/Project.toml"), SourceText(
        "name = \"MP\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9a7\"\nversion = \"1.0.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///mp/Manifest.toml"), SourceText(
        "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///mp/src/MP.jl"), SourceText(
        "module MP\nmodule Sub\ninclude(\"b.jl\")\nend\ninclude(\"a.jl\")\nend\n", "julia")))
    uri = URI("file:///mp/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText("f(x) = @check_args x\n", "julia")))
    sub_uri = URI("file:///mp/src/b.jl")
    add_file!(jw, TextFile(sub_uri, SourceText("g(x) = @check_args x\n", "julia")))
    JW.set_v2_enabled!(jw, true)
    JW.set_macro_expansion!(jw, true)

    ctx = JW.derived_v2_expansion_context(jw.runtime, uri)
    @test ctx.modpath == ["MP"]
    req = JW.derived_required_macro_expansions(jw.runtime)
    a_req = only(r for r in req if r.file == uri)
    @test a_req.ctx_module == ["MP"]

    # A file spliced into a nested submodule carries the deeper path.
    sub_ctx = JW.derived_v2_expansion_context(jw.runtime, sub_uri)
    @test sub_ctx.modpath == ["MP", "Sub"]
    # Both contexts carry the same imports (just `using MP`), so the module
    # path alone must separate the ctx hashes — the child caches per ctx id,
    # and distinct modules must never share a cache slot.
    @test sub_ctx.imports == ctx.imports
    @test sub_ctx.ctx_hash != ctx.ctx_hash

    # A computed-include orphan of the package (and the entry file itself)
    # falls back to the package root module, so internal macros still resolve.
    orphan = URI("file:///mp/src/orphan.jl")
    add_file!(jw, TextFile(orphan, SourceText("h(x) = @check_args x\n", "julia")))
    @test JW.derived_v2_expansion_context(jw.runtime, orphan).modpath == ["MP"]
    @test JW.derived_v2_expansion_context(jw.runtime, URI("file:///mp/src/MP.jl")).modpath == ["MP"]
end

# ── expansion-derived declarations ──────────────────────────────────────────

@testitem "expansion decls: a clean expansion declares its names and un-blinds the module" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    jw, uri = exp_make_jw("""
    @defgen foo
    use_it() = foo(1)
    """)
    set_input_env_ready!(jw.runtime, true)
    ref = JW.V2ItemRef(uri, JW.derived_v2_file_skeleton(jw.runtime, uri).items[1].id)

    # Pending: the macrocall is opaque, the module blind, nothing declared —
    # and the default preset says nothing about it.
    @test exp_blind(jw, uri)
    @test !haskey(exp_names(jw, uri), "foo")
    @test JW.derived_v2_item_expansion_status(jw.runtime, ref).status === :pending
    @test !any(d -> d.code === :analysis_boundary, get_diagnostic(jw, uri))

    # Settled clean: `foo` is an ordinary declaration, the module sees again,
    # and the later use resolves.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="foo(x) = x + 1"))
    @test JW.derived_v2_item_expansion_status(jw.runtime, ref).status === :ok
    @test !exp_blind(jw, uri)
    @test exp_names(jw, uri)["foo"] === :function
    @test !any(d -> d.code === :missing_reference, get_diagnostic(jw, uri))
    @test !any(d -> d.code === :analysis_boundary, get_diagnostic(jw, uri))

    # The static tree (what the expansion context is computed from) never
    # sees the harvested declaration — that is the cycle guard.
    @test !haskey(JW.derived_v2_module_tree_static(jw.runtime, uri).modules[1].declared, "foo")
    @test haskey(JW.derived_v2_module_tree(jw.runtime, uri).modules[1].declared, "foo")
end

@testitem "expansion decls: blocks, docstrings, exports and imports are harvested" setup=[ExpansionWS] begin
    jw, uri = exp_make_jw("@define_all\n")
    # Several top-level statements (parsed into one block), a `begin` block
    # inside, a docstring wrapper, exports, a `public` (top level only, the
    # parser rejects it inside a block), imports, and a hygiene gensym.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="""
    begin
        struct Gen
            a
        end
        Gen(x) = Gen(1)
    end
    Core.@doc "docs" helper(y) = y
    const LIMIT = 3
    export Gen, helper
    public LIMIT
    using Statistics
    import LinearAlgebra: dot as dt
    var"#7#hidden"() = 1
    """))
    @test !exp_blind(jw, uri)
    names = exp_names(jw, uri)
    @test names["Gen"] === :struct
    @test names["helper"] === :function
    @test names["LIMIT"] === :const
    @test !any(startswith("#"), keys(names))
    @test JW.derived_v2_module_exports(jw.runtime, uri, String[]) == ["Gen", "helper"]
    imps = JW.derived_v2_module_imports(jw.runtime, uri, String[])
    @test any(i -> i.kind === :using && i.target.path == ["Statistics"], imps)
    @test any(i -> i.kind === :import && i.target.path == ["LinearAlgebra"] &&
                   i.symbols == [(name="dot", alias="dt")], imps)
end

@testitem "expansion decls: what keeps a macrocall opaque" setup=[ExpansionWS] begin
    # Failed: blind.
    jw, uri = exp_make_jw("@defgen foo\n")
    ref = JW.V2ItemRef(uri, JW.derived_v2_file_skeleton(jw.runtime, uri).items[1].id)
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:failed, text="LoadError: UndefVarError: `@defgen` not defined\n  stack"))
    @test exp_blind(jw, uri)
    @test JW.derived_v2_item_expansion_decls(jw.runtime, ref) === nothing
    st = JW.derived_v2_item_expansion_status(jw.runtime, ref)
    @test st.status === :failed
    @test st.error == "LoadError: UndefVarError: `@defgen` not defined"

    # Unparseable `:ok` text: blind.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="\$(Expr(:meta, :garbage) 12 ["))
    @test exp_blind(jw, uri)

    # An `eval`/`include` inside the expansion, a nested module, an
    # unexpanded unknown macro, or an import below statement level: blind.
    for text in [
        "Core.eval(@__MODULE__, :(x = 1))",
        "for n in names\n    eval(:(\$n() = 1))\nend",
        "include(\"gen.jl\")",
        "module Inner\nend",
        "@unknown_leftover foo",
        "try\n    using Statistics\ncatch\nend",
        # The child's Expr-printer fallback (BitFlags' `Expr(:toplevel, …)`
        # with hygienic-scope nodes): parseable, but not the macro's code.
        "\$(Expr(:toplevel, :(primitive type Foo 8 end)))",
        # Globals declared inside a loop may be computed per iteration.
        "for i in 1:3\n    global f\nend",
    ]
        settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text=text))
        @test exp_blind(jw, uri)
    end

    # A `let` declares only its globals (Rmath's deferred-free idiom): those
    # names are harvested, the module is not blind.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok,
        text="let tracker = []\n    global foo_deferred\n    function foo_deferred()\n        tracker\n    end\n    helper() = 1\nend"))
    @test !exp_blind(jw, uri)
    @test exp_names(jw, uri)["foo_deferred"] === :global
    @test !haskey(exp_names(jw, uri), "helper")
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="global bare_g\nglobal assigned_g = 2"))
    @test exp_names(jw, uri)["bare_g"] === :global
    @test exp_names(jw, uri)["assigned_g"] === :global

    # A `$(Expr(:meta, :doc))` marker inside a generated function (BitFlags'
    # `@bitflag`) is a benign splice — harvested, not opaque.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok,
        text="primitive type Flags <: Integer 32 end\nfunction Flags(x::Integer)\n    \$(Expr(:meta, :doc))\n    x\nend\nconst FLAG_A = Flags(1)"))
    @test !exp_blind(jw, uri)
    @test exp_names(jw, uri)["Flags"] === :primitive
    @test exp_names(jw, uri)["FLAG_A"] === :const

    # Two opaque rows, one still pending: blind until both settle.
    jw2, uri2 = exp_make_jw("@defgen foo\n@defgen bar\n")
    settle!(jw2, exp_key_for(jw2, uri2, 1) => (status=:ok, text="foo() = 1"))
    @test exp_blind(jw2, uri2)
    @test haskey(exp_names(jw2, uri2), "foo")
    settle!(jw2, exp_key_for(jw2, uri2, 1) => (status=:ok, text="foo() = 1"),
                 exp_key_for(jw2, uri2, 2) => (status=:ok, text="bar() = 2"))
    @test !exp_blind(jw2, uri2)

    # An interpolating `@eval` never clears, whatever the child returned.
    jw3, uri3 = exp_make_jw("const names = (:a, :b)\n@eval \$(names[1])(x) = x\n")
    settle!(jw3, exp_key_for(jw3, uri3, 1) => (status=:ok, text="Core.eval(Main, :(a(x) = x))"))
    @test exp_blind(jw3, uri3)

    # Flag off: the expanded inventory IS the static one — blind.
    JW.set_macro_expansion!(jw, false)
    @test exp_blind(jw, uri)
end

@testitem "expansion: an unexpanded unknown macro in a body blinds the item for missing_reference" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # MacroTools' idiom: `@capture` binds `fcall`/`body`, which the rest of
    # the function reads. Unexpanded, the fallback cannot know that.
    src = """
    function splitdef(fdef)
        @capture(fdef, function fcall_ body_ end)
        return (fcall, body)
    end
    plain(x) = undefined_thing(x)
    """
    jw, uri = exp_make_jw(src)
    set_input_env_ready!(jw.runtime, true)
    mr(jw, uri) = [d.message for d in get_diagnostic(jw, uri) if d.code === :missing_reference]
    # Pending: the item is silent; the plain item still reports.
    @test mr(jw, uri) == ["Missing reference: undefined_thing"]
    # `@capture` itself is not an unresolved reference either.
    @test !any(occursin("capture", m) for m in mr(jw, uri))
    # Failed / unparseable: still silent.
    settle!(jw, exp_key_for_site(jw, uri, 1) => (status=:failed, text="boom"))
    @test mr(jw, uri) == ["Missing reference: undefined_thing"]
    settle!(jw, exp_key_for_site(jw, uri, 1) => (status=:ok, text="if #= x =#, fcall = nothing, body = nothing"))
    @test mr(jw, uri) == ["Missing reference: undefined_thing"]
    # A clean expansion binding the names: the item is analyzed, nothing new.
    settle!(jw, exp_key_for_site(jw, uri, 1) => (status=:ok, text="begin\n    fcall = fdef.args[1]\n    body = fdef.args[2]\n    true\nend"))
    @test mr(jw, uri) == ["Missing reference: undefined_thing"]
    # …and an expansion that does NOT bind them makes the reads real findings.
    settle!(jw, exp_key_for_site(jw, uri, 1) => (status=:ok, text="true"))
    @test sort(mr(jw, uri)) == ["Missing reference: body", "Missing reference: fcall", "Missing reference: undefined_thing"]
    # A known effect-free macro never blinds the item.
    jw2, uri2 = exp_make_jw("function g(x)\n    @info \"hi\"\n    return undefined_thing(x)\nend\n")
    set_input_env_ready!(jw2.runtime, true)
    @test mr(jw2, uri2) == ["Missing reference: undefined_thing"]
end

@testitem "expansion decls: harvested imports never surface as unresolved_import, arguments are not doubled" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # A macro whose expansion `using`s something unresolvable: the module's
    # imports gain the row (visibility), but no unresolved_import diagnostic
    # appears at the macrocall — the user never wrote that statement.
    jw, uri = exp_make_jw("@load_deps\nexport a\n")
    set_input_env_ready!(jw.runtime, true)
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="using NoSuchDep_xyz\nexport a, b\nb() = 1"))
    imps = JW.derived_v2_module_imports(jw.runtime, uri, String[])
    @test any(i -> i.target.path == ["NoSuchDep_xyz"], imps)
    @test !any(d -> d.code === :unresolved_import, get_diagnostic(jw, uri))
    # `a` was exported by the source already: exported once; `b` is new.
    @test sort(JW.derived_v2_module_exports(jw.runtime, uri, String[])) == ["a", "b"]

    # An import spelled in the macro's arguments is one row, not two.
    jw2, uri2 = exp_make_jw("@wrap_using using Statistics\n")
    settle!(jw2, exp_key_for(jw2, uri2, 1) => (status=:ok, text="using Statistics"))
    @test count(i -> i.target.path == ["Statistics"], JW.derived_v2_module_imports(jw2.runtime, uri2, String[])) == 1
end

@testitem "expansion: cmd-literal interpolations are reads in every expansion state" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # `run(`ffmpeg -v $level`)`: the EST keeps `$level` inside a raw CmdString,
    # so without the synthesized reads `level` looked unused while the
    # expansion was pending or failed — and the finding vanished once the DJP
    # spliced `Base.cmd_gen(…)` (Plots' animation.jl in the corpus).
    src = """
    function g(fn, loop)
        verbose_level = 3
        pattern = joinpath("a", "b")
        run(`ffmpeg -v \$verbose_level -i \$(basename(pattern)) -loop \$loop \$fn`)
    end
    """
    jw, uri = exp_make_jw(src)
    set_input_env_ready!(jw.runtime, true)
    unused(jw, uri) = [d.message for d in get_diagnostic(jw, uri)
                       if d.code in (:unused_binding, :unused_function_argument)]
    @test isempty(unused(jw, uri))                                    # pending
    @test !any(d -> d.code === :missing_reference, get_diagnostic(jw, uri))
    key = exp_key_for_site(jw, uri, 1)
    settle!(jw, key => (status=:failed, text=""))
    @test isempty(unused(jw, uri))                                    # failed
    settle!(jw, key => (status=:ok, text="Base.cmd_gen(((\"ffmpeg\",), (\"-v\",), (verbose_level,), (\"-i\",), (basename(pattern),), (\"-loop\",), (loop,), (fn,)))"))
    @test isempty(unused(jw, uri))                                    # ok
    # String macros interpolate too: Bonito's `js"…$(x)…"`, LaTeXStrings'
    # `L"%$x"`, and `$name` inside a triple-quoted string macro (WGLMakie).
    # `raw"$x"` does not, but a phantom read is the silent direction.
    jw3, uri3 = exp_make_jw("""
    function w(session, scene_ser, uuid, x, unused_here)
        err = "nope"
        a = js\"\"\"
            const s = \$(scene_ser);
            console.log(\$uuid, \$(string(err)));
        \"\"\"
        b = L"%\$x"
        c = raw"\$unused_here"
        return (a, b, c, session)
    end
    """)
    set_input_env_ready!(jw3.runtime, true)
    @test isempty(unused(jw3, uri3))
    @test !any(d -> d.code === :missing_reference, get_diagnostic(jw3, uri3))
    # A genuinely unused local next to the cmd still reports, in every state.
    jw2, uri2 = exp_make_jw("function h(fn)\n    dead = 1\n    run(`open \$fn`)\nend\n")
    set_input_env_ready!(jw2.runtime, true)
    @test unused(jw2, uri2) == ["Variable `dead` has been assigned but not used."]
    # No interpolation: nothing synthesized, and the flag stays off-path.
    JW.set_macro_expansion!(jw2, false)
    @test unused(jw2, uri2) == ["Variable `dead` has been assigned but not used."]
end

@testitem "expansion: diagnostics only grow as expansions settle" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # The pending-state contract: whatever is reported while every expansion
    # is still pending must still be reported after they settle — nothing
    # appears and then vanishes when the DJP catches up. One file mixing a
    # clean top-level macro, a `@capture`-style body macro, a genuine missing
    # reference and an expansion with an unresolvable import.
    src = """
    @defgen foo
    @load_deps
    function splitdef(fdef)
        @capture(fdef, function fcall_ body_ end)
        return (fcall, body)
    end
    use_it() = foo(1) + undefined_thing()
    unused_arg(x) = 1
    """
    keyof(d) = (d.code, first(d.range), d.message)
    for (config, outcomes) in [
            (nothing, [(status=:ok, text="foo(x) = x"), (status=:ok, text="using NoSuchDep_xyz"),
                       (status=:ok, text="begin\n    fcall = fdef.args[1]\n    body = fdef.args[2]\nend")]),
            (nothing, [(status=:failed, text="boom"), (status=:failed, text="boom"), (status=:failed, text="boom")]),
            (EXP_OPT_IN, [(status=:failed, text="boom"), (status=:ok, text="using NoSuchDep_xyz"), (status=:failed, text="boom")]),
        ]
        jw, uri = exp_make_jw(src)
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///pkg/JuliaLint.toml"), SourceText(config, "toml")))
        set_input_env_ready!(jw.runtime, true)
        before = Set(keyof(d) for d in get_diagnostic(jw, uri))
        @test !any(k -> k[1] === :analysis_boundary, before)
        # Settle one site at a time: every intermediate state must also be
        # a superset of the previous one.
        keys_ = [exp_key_for(jw, uri, 1), exp_key_for(jw, uri, 2), exp_key_for_site(jw, uri, 3)]
        settled = Pair{JW.ExpansionKey,JW.ExpansionOutcome}[]
        prev = before
        for (k, o) in zip(keys_, outcomes)
            push!(settled, k => o)
            settle!(jw, settled...)
            now = Set(keyof(d) for d in get_diagnostic(jw, uri))
            @test issubset(prev, now)
            prev = now
        end
        @test ("Missing reference: undefined_thing" in (k[3] for k in prev)) == (outcomes[1].status === :ok)
    end
end

@testitem "expansion decls: restated argument definitions are not redeclarations" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # `@wrap struct S … end`: the walker already enumerated `S` from the
    # arguments; the expansion restating it must not pair as a const_decl
    # conflict, and the module is un-blinded.
    jw, uri = exp_make_jw("@wrap struct S\n    a::Int\nend\n")
    set_input_env_ready!(jw.runtime, true)
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="begin\n    struct S\n        a::Int\n    end\n    Base.hash(s::S, h::UInt) = hash(s.a, h)\nend"))
    @test !exp_blind(jw, uri)
    @test exp_names(jw, uri)["S"] === :struct
    @test count(e -> e[1] == "S", JW.derived_v2_module_decl_events(jw.runtime, uri, String[])) == 1
    @test !any(d -> d.code === :const_decl, get_diagnostic(jw, uri))
end

@testitem "expansion decls: the opt-in boundary notice for unexpanded macros" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    function notice_jw(src; config=EXP_OPT_IN)
        jw, uri = exp_make_jw(src)
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///pkg/JuliaLint.toml"), SourceText(config, "toml")))
        set_input_env_ready!(jw.runtime, true)
        return jw, uri
    end
    notices(jw, uri) = filter(d -> d.code === :analysis_boundary, get_diagnostic(jw, uri))

    # Pending: no notice yet (it settles later).
    jw, uri = notice_jw("@defgen foo\nuse_it() = foo(1)\n")
    @test isempty(notices(jw, uri))
    # Failed: one warning at the macrocall, naming the macro, the error's
    # first line and the suppressed rules.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:failed, text="UndefVarError: `@defgen` not defined\nmore"))
    ns = notices(jw, uri)
    @test length(ns) == 1
    @test ns[1].severity === :warning
    @test occursin("Macro `@defgen`", ns[1].message)
    @test occursin("expansion failed: UndefVarError: `@defgen` not defined", ns[1].message)
    @test !occursin("more", ns[1].message)
    @test occursin("missing_reference", ns[1].message)
    @test !any(d -> d.code === :missing_reference, get_diagnostic(jw, uri))
    # Expanded to unmodelled code.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="include(\"gen.jl\")"))
    @test occursin("cannot model", only(notices(jw, uri)).message)
    # Clean: the notice goes away with the blindness.
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="foo(x) = x"))
    @test isempty(notices(jw, uri))

    # Expansion disabled: the notice says so.
    JW.set_macro_expansion!(jw, false)
    @test occursin("macro expansion is disabled", only(notices(jw, uri)).message)

    # The default preset: silent in every one of those states.
    jw, uri = notice_jw("@defgen foo\nuse_it() = foo(1)\n"; config=nothing)
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:failed, text="boom"))
    @test isempty(get_diagnostic(jw, uri))
    JW.set_macro_expansion!(jw, false)
    @test isempty(get_diagnostic(jw, uri))
end

@testitem "expansion decls: a harvested const alias survives a source-level constructor" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # MathOptInterface: `MOI.Utilities.@model(Model, ...)` expands to
    # `const Model{T} = GenericModel{T,...}` while the source spells
    # `function Model(; kw...)`. Both declarations survive: the alias makes
    # `x::Model` a type annotation, and the pair is no const_decl conflict.
    src = "@model Model\nfunction Model(; kw...)\n    Model{Float64}()\nend\nread!(io, model::Model) = model\n"
    jw, uri = exp_make_jw(src)
    set_input_env_ready!(jw.runtime, true)
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="const Model{T} = Base.Dict{T,Int}"))
    @test !exp_blind(jw, uri)
    events = JW.derived_v2_module_decl_events(jw.runtime, uri, String[])
    @test Set(e[2] for e in events if e[1] == "Model") == Set([:const, :function])
    diags = get_diagnostic(jw, uri)
    @test !any(d -> d.code === :invalid_type_declaration, diags)
    @test !any(d -> d.code === :const_decl, diags)

    # A macro re-emitting a const the file already has (ArrayLayouts'
    # `@layoutmul`) is not a const_decl conflict either.
    jw2, uri2 = exp_make_jw("const Qs = Union{Int,Float64}\n@layoutmul Qs\nlast(x::Qs) = x\n")
    set_input_env_ready!(jw2.runtime, true)
    settle!(jw2, exp_key_for(jw2, uri2, 1) => (status=:ok, text="const Qs = Union{Int,Float64}\nfoo(x::Qs) = x"))
    @test !exp_blind(jw2, uri2)
    @test !any(d -> d.code === :const_decl, get_diagnostic(jw2, uri2))
end

@testitem "expansion decls: a bare-module @reexport clears through its expansion" setup=[ExpansionWS] begin
    using JuliaWorkspaces: set_input_env_ready!, get_diagnostic
    # MLStyle: `@reexport MatchImpl` expands to `using .MatchImpl; export
    # gen_match, …`; harvested, the submodule that does `using MLStyle` sees
    # the re-exported name.
    jw, uri = exp_make_jw("""
    module MatchImpl
    export gen_match
    gen_match() = 1
    end
    @reexport MatchImpl
    module AST
    using ..MyPkgRoot
    g() = gen_match()
    end
    """)
    set_input_env_ready!(jw.runtime, true)
    @test exp_blind(jw, uri)
    mr(jw, uri) = [d.message for d in get_diagnostic(jw, uri) if d.code === :missing_reference]
    @test isempty(mr(jw, uri))   # blind root: silent
    settle!(jw, exp_key_for(jw, uri, 1) => (status=:ok, text="begin\n    using .MatchImpl\n    export gen_match\nend"))
    @test !exp_blind(jw, uri)
    @test "gen_match" in JW.derived_v2_module_exports(jw.runtime, uri, String[])
end

@testitem "expansion env: extension files and workspace members route to the child that has their code" setup=[ExpansionWS] begin
    using JuliaWorkspaces: derived_package, ResolveExtensionEnvironmentKey, WatchEnvironmentKey,
        set_input_extension_environments!
    using JuliaWorkspaces.URIs2: uri2filepath
    project = "name = \"MyPkg\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9a5\"\nversion = \"1.0.0\"\n\n[weakdeps]\nBar = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\n\n[extensions]\nMyPkgBarExt = \"Bar\"\n"
    manifest_with_bar = "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n\n[[deps.Bar]]\ngit-tree-sha1 = \"0123456789abcdef0123456789abcdef01234567\"\nuuid = \"6b0e2f31-8d55-4f2a-9d10-2b6c5e8f9a22\"\nversion = \"1.0.0\"\n"
    manifest_bare = "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n"
    ext_src = "module MyPkgBarExt\nusing MyPkg, Bar\nf(x) = @bar_macro x\nend\n"
    function build(manifest)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pkg/Project.toml"), SourceText(project, "toml")))
        add_file!(jw, TextFile(URI("file:///pkg/Manifest.toml"), SourceText(manifest, "toml")))
        add_file!(jw, TextFile(URI("file:///pkg/src/MyPkg.jl"), SourceText("module MyPkg end\n", "julia")))
        add_file!(jw, TextFile(URI("file:///pkg/ext/MyPkgBarExt.jl"), SourceText(ext_src, "julia")))
        JW.set_v2_enabled!(jw, true)
        JW.set_macro_expansion!(jw, true)
        return jw
    end
    ext = URI("file:///pkg/ext/MyPkgBarExt.jl")

    # The package's own manifest covers the trigger: the package's watch child
    # serves the extension, in the extension's real module.
    jw = build(manifest_with_bar)
    env = JW.derived_v2_expansion_env(jw.runtime, ext)
    @test env.key == WatchEnvironmentKey(uri2filepath(URI("file:///pkg")), JW.derived_project(jw.runtime, URI("file:///pkg")).content_hash)
    ctx = JW.derived_v2_expansion_context(jw.runtime, ext)
    @test ctx.modpath == ["MyPkg", "MyPkgBarExt"]
    # (The scratch-module imports are the file's TOP-LEVEL statements plus
    # the parent; the extension's own `using Bar` sits inside its module and
    # is served by the real module the child resolves via get_extension.)
    @test "using MyPkg" in ctx.imports
    @test only(r for r in JW.derived_required_macro_expansions(jw.runtime) if r.file == ext).ctx_module == ["MyPkg", "MyPkgBarExt"]

    # No environment covers the trigger: nothing to expand in until the
    # extension-environment child delivers, then that child serves it.
    jw = build(manifest_bare)
    @test JW.derived_v2_expansion_env(jw.runtime, ext) === nothing
    @test !any(r -> r.file == ext, JW.derived_required_macro_expansions(jw.runtime))
    pkg = derived_package(jw.runtime, URI("file:///pkg"))
    key = ResolveExtensionEnvironmentKey(uri2filepath(URI("file:///pkg")), pkg.content_hash)
    set_input_extension_environments!(jw.runtime, Dict(key => URI("file:///scratch/ext-env-MyPkg")))
    env = JW.derived_v2_expansion_env(jw.runtime, ext)
    @test env.key == key
    @test env.env_hash == pkg.content_hash
    # A src/ file keeps the package's own child.
    @test JW.derived_v2_expansion_env(jw.runtime, URI("file:///pkg/src/MyPkg.jl")).key isa WatchEnvironmentKey

    # A workspace member's files expand in the ROOT's child (the only one a
    # workspace has).
    root_project = "name = \"Root\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1\"\nversion = \"1.0.0\"\n\n[workspace]\nprojects = [\"lib/Sub\"]\n"
    root_manifest = "julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n\n[[deps.Root]]\npath = \".\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c1\"\nversion = \"1.0.0\"\n\n[[deps.Sub]]\npath = \"lib/Sub\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2\"\nversion = \"0.1.0\"\n"
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mono/Project.toml"), SourceText(root_project, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/Manifest.toml"), SourceText(root_manifest, "toml")))
    add_file!(jw, TextFile(URI("file:///mono/src/Root.jl"), SourceText("module Root end\n", "julia")))
    add_file!(jw, TextFile(URI("file:///mono/lib/Sub/Project.toml"), SourceText("name = \"Sub\"\nuuid = \"6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9c2\"\nversion = \"0.1.0\"\n", "toml")))
    member_file = URI("file:///mono/lib/Sub/src/Sub.jl")
    add_file!(jw, TextFile(member_file, SourceText("module Sub\nf(x) = @sub_macro x\nend\n", "julia")))
    JW.set_v2_enabled!(jw, true)
    JW.set_macro_expansion!(jw, true)
    root_hash = JW.derived_project(jw.runtime, URI("file:///mono")).content_hash
    env = JW.derived_v2_expansion_env(jw.runtime, member_file)
    @test env.key == WatchEnvironmentKey(uri2filepath(URI("file:///mono")), root_hash)
    @test env.env_hash == root_hash
end
