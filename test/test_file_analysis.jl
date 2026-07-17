@testsnippet FileAnalysisWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TreeModuleContext, ItemRef
    using JuliaWorkspaces.URIs2: URI

    const SL = JuliaWorkspaces.StaticLint
    const CST = JuliaWorkspaces.CSTParser

    function ws_with(files::Dict{URI,String})
        jw = JuliaWorkspace()
        for (u, s) in files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    # Drive StaticLint's per-file traversal over `file`: non-local names
    # resolve through `root`'s module tree instead of followed includes.
    function run_per_file_pass(jw, root::URI, file::URI)
        rt = jw.runtime
        cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(rt, file)
        project_uri = JuliaWorkspaces.derived_project_uri_for_root(rt, root)
        env = project_uri === nothing ?
            JuliaWorkspaces.derived_stdlib_only_env(rt) :
            JuliaWorkspaces.derived_environment(rt, project_uri)
        path = JuliaWorkspaces.derived_file_module_path(rt, root, file)
        @assert path !== nothing "fixture file must be part of the root's module tree"
        ctx = TreeModuleContext(rt, root, path)
        meta_dict = Dict{UInt64,SL.Meta}()
        SL.semantic_pass(file, cst, env, meta_dict, rt; module_context=ctx)
        return cst, meta_dict, ctx
    end

    function find_identifiers(x, value::String, hits=CST.EXPR[])
        if SL.headof(x) === :IDENTIFIER && CST.valof(x) == value
            push!(hits, x)
        elseif x.args !== nothing
            for a in x.args
                find_identifiers(a, value, hits)
            end
        end
        return hits
    end

    function find_first_expr(f, root)
        stack = CST.EXPR[root]
        while !isempty(stack)
            x = pop!(stack)
            f(x) && return x
            if x.args !== nothing
                for a in x.args
                    a isa CST.EXPR && push!(stack, a)
                end
            end
        end
        return nothing
    end

    const ROOT = URI("file:///t/src/MainPkg.jl")
    const A = URI("file:///t/src/a.jl")
    const B = URI("file:///t/src/b.jl")
end

@testitem "file analysis: sibling-file name resolves to a TreeRef with the declaring ItemRef" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => "bcaller() = afunc()\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    x = only(find_identifiers(cst, "afunc"))
    r = SL.refof(x, meta_dict)
    @test r isa SL.TreeRef
    @test r.name == "afunc"
    @test r.kind === :function
    @test r.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["afunc"]
    @test r.origin_module == ["MainPkg"]
end

@testitem "file analysis: a using'd external name resolves to a TreeRef of kind :external_symbol" setup=[FileAnalysisWS] begin
    # `require` is NOT exported by Base (so the root scope's seeded Base
    # ModuleStore can't resolve it) — the only resolution path is the tree
    # context, through the sibling file's `using Base: require`.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        using Base: require
        include("b.jl")
        end
        """,
        B => "f() = require\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    x = only(find_identifiers(cst, "require"))
    r = SL.refof(x, meta_dict)
    @test r isa SL.TreeRef
    @test r.kind === :external_symbol
    @test r.origin_module == ["Base"]
    @test r.item === nothing
end

@testitem "file analysis: an unresolved name keeps missing-ref parity (no ref)" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => "g() = totally_undefined_name_xyz()\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    x = only(find_identifiers(cst, "totally_undefined_name_xyz"))
    @test !SL.hasref(x, meta_dict)
end

@testitem "file analysis: follow_includes=false leaves included names to the tree" setup=[FileAnalysisWS] begin
    # Analyzing the entry file itself: the `include("a.jl")` statement must
    # NOT splice a.jl's names into the local scope — `afunc` resolves through
    # the (child) tree context instead, as plain data.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        caller() = afunc()
        end
        """,
        A => "afunc() = 1\n",
    ))

    cst, meta_dict, ctx = run_per_file_pass(jw, ROOT, ROOT)
    @test ctx.path == String[]

    x = only(find_identifiers(cst, "afunc"))
    r = SL.refof(x, meta_dict)
    @test r isa SL.TreeRef
    @test !(r isa SL.Binding)
    @test r.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["afunc"]

    # and the module's local scope really doesn't contain the included name
    mod = find_first_expr(CST.defines_module, cst)
    sc = SL.scopeof(mod, meta_dict)
    @test sc isa SL.Scope
    @test !haskey(sc.names, "afunc")
end

@testitem "file analysis: a module declared in the analyzed file resolves its own names locally" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => """
        module Inner
        h() = 1
        g() = h()
        end
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    hs = find_identifiers(cst, "h")
    @test length(hs) == 2
    for x in hs
        r = SL.refof(x, meta_dict)
        @test r isa SL.Binding
        @test !(r isa SL.TreeRef)
    end
end

@testitem "file analysis: an in-file using of a tree module resolves through a child context" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Common
        export cfunc
        cfunc() = 1
        end
        """,
        B => """
        using .Common
        u() = cfunc()
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    # the import statement's own component resolved through the tree context
    common = only(find_identifiers(cst, "Common"))
    @test SL.hasref(common, meta_dict)

    x = only(find_identifiers(cst, "cfunc"))
    r = SL.refof(x, meta_dict)
    @test r isa SL.TreeRef
    @test r.kind === :function
    @test r.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Common"])["cfunc"]
end

@testitem "file analysis: colon-form and leaf imports of tree names complete the pass" setup=[FileAnalysisWS] begin
    # The final component of `using .Common: cfunc` / `import .Common.chelper`
    # resolves through the tree to a plain-data TreeRef — the pass must bind
    # it like any other import leaf instead of crashing.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Common
        export cfunc
        cfunc() = 1
        chelper() = 2
        end
        """,
        B => """
        using .Common: cfunc
        import .Common.chelper
        u() = cfunc()
        v() = chelper()
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    for name in ("cfunc", "chelper")
        hits = find_identifiers(cst, name)
        @test length(hits) == 2
        # the import statement's own leaf component: bound at the import
        # site, val carrying the plain-data tree target
        stmt = SL.refof(hits[1], meta_dict)
        @test stmt isa SL.Binding
        @test stmt.val isa SL.TreeRef
        @test stmt.val.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Common"])[name]
        # the body reference resolves (locally to the import binding or
        # through the tree — never left dangling)
        body = SL.refof(hits[2], meta_dict)
        @test body isa SL.Binding || body isa SL.TreeRef
    end
end

@testitem "file analysis: a qualified definition on a tree-imported module completes the pass" setup=[FileAnalysisWS] begin
    # `import .Common` binds "Common" with a module-typed, TreeRef-valued
    # binding; the qualified definition's `add_binding` module branch must
    # not assume the binding's val is an EXPR.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Common
        end
        """,
        B => """
        import .Common
        Common.newf() = 1
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    hits = find_identifiers(cst, "Common")
    @test length(hits) == 2
    for x in hits
        @test SL.hasref(x, meta_dict)
    end
    fn = find_first_expr(CST.defines_function, cst)
    @test SL.bindingof(fn, meta_dict) isa SL.Binding
end

@testitem "file analysis: no context handle remains reachable from the returned meta" setup=[FileAnalysisWS] begin
    # TreeModuleContext holds the Salsa runtime — it may live only inside the
    # running analysis. After semantic_pass returns, neither the root scope
    # nor any in-file module scope stored in meta may still hold one.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        module Inner
        h() = 1
        end
        caller() = afunc()
        end
        """,
        A => "afunc() = 1\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, ROOT)

    # tree resolution DID happen during the pass ...
    r = SL.refof(only(find_identifiers(cst, "afunc")), meta_dict)
    @test r isa SL.TreeRef

    # ... but no handle survives in any scope reachable from the meta
    leaked = sum(collect(values(meta_dict))) do m
        s = m.scope
        (s isa SL.Scope && s.modules isa Dict) || return 0
        count(v -> v isa SL.AbstractModuleContext, collect(values(s.modules)))
    end
    @test leaked == 0
end

@testitem "file analysis: a sibling file's macro resolves through the tree" setup=[FileAnalysisWS] begin
    # macros are stored WITH the `@` prefix throughout the inventory layers,
    # so the reference site's "@mymac" hits the visible-names key directly.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        macro mymac(x)
            x
        end
        """,
        B => "w() = @mymac 1\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    x = only(find_identifiers(cst, "@mymac"))
    r = SL.refof(x, meta_dict)
    @test r isa SL.TreeRef
    @test r.kind === :macro
    @test r.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["@mymac"]
end

@testitem "file analysis: a bare name does not resolve against a macro-only declaration" setup=[FileAnalysisWS] begin
    # `@foo` and `foo` can coexist; when only `macro mymac` exists, a bare
    # `mymac` reference must MISS (missing-ref parity), not borrow the macro.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        macro mymac(x)
            x
        end
        """,
        B => "w() = mymac\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    x = only(find_identifiers(cst, "mymac"))
    @test !SL.hasref(x, meta_dict)
end

@testitem "derived_file_analysis: sibling + external + undefined references" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        using Base: require
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => """
        bcaller() = afunc() + totally_undefined_name_xyz()
        brequire() = require
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test fa isa JuliaWorkspaces.FileAnalysis

    # the frozen meta carries this file's refs
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, B)
    x = only(find_identifiers(cst, "afunc"))
    @test SL.refof(x, fa.meta) isa SL.TreeRef

    # outbound: the sibling entry with its declaring ItemRef
    ob = only(filter(o -> o.name == "afunc", fa.outbound))
    @test ob.target == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["afunc"]
    @test ob.origin_module == ["MainPkg"]
    @test ob.count == 1

    # outbound: the external entry has no ItemRef
    obr = only(filter(o -> o.name == "require", fa.outbound))
    @test obr.target === nothing
    @test obr.origin_module == ["Base"]

    @test issorted(fa.outbound, by=o -> (o.name, o.origin_module))

    # diagnostics: the undefined name is a missing ref; the resolved ones are not
    @test any(d -> occursin("totally_undefined_name_xyz", d.message), fa.diagnostics)
    @test !any(d -> occursin("afunc", d.message), fa.diagnostics)
    @test !any(d -> occursin("require", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: repeated references aggregate into one counted entry" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => """
        f() = afunc()
        g() = afunc()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    ob = only(filter(o -> o.name == "afunc", fa.outbound))
    @test ob.count == 2
end

@testitem "derived_file_analysis: a file not spliced under the root yields an empty analysis" setup=[FileAnalysisWS] begin
    other = URI("file:///t/src/other.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        end
        """,
        other => "ofunc() = 1\n",
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, other)

    @test isempty(fa.meta)
    @test isempty(fa.outbound)
    @test isempty(fa.diagnostics)
end

@testitem "derived_file_analysis: `check_all` lint hints reach the diagnostics" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => "f(x) = x == nothing\n",
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    @test any(d -> d.source == "StaticLint.jl" && occursin("nothing", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: unresolved in-file imports are marked and reported" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => """
        using .NoSuchModule
        k() = something_undefined_abc()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    # `mark_unresolved_imports!` ran: the failed component is reported ...
    @test any(d -> occursin("NoSuchModule", d.message), fa.diagnostics)
    # ... and the unresolved wildcard `using` suppresses missing-ref checks
    # in its scope (parity with the whole-closure pass)
    @test !any(d -> occursin("something_undefined_abc", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: an unrelated same-kind reorder does not re-run an import-bearing analysis" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    other = URI("file:///t/src/other.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("other.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sub
        export sfunc
        sfunc() = 1
        end
        """,
        other => """
        module Other
        o1() = 1
        o2() = 2
        end
        """,
        B => """
        using .Sub
        u() = sfunc()
        """,
    ))
    rt = jw.runtime

    # Untraced baseline: fills the memo cache so the traced call below only
    # counts what the edit actually invalidated (see the trace-baseline note
    # in test_module_tree.jl's invalidation testitem).
    fa0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    @test only(filter(o -> o.name == "sfunc", fa0.outbound)).target !== nothing

    # Reorder two same-kind functions in the UNRELATED module: their item
    # ids swap, so the tree VALUE changes — but nothing B's analysis
    # resolves through does. The import-path helpers must reach the tree
    # through per-module selectors, not the whole tree value, for this to
    # backdate.
    JuliaWorkspaces.update_file!(jw, TextFile(other, SourceText("""
    module Other
    o2() = 2
    o1() = 1
    end
    """, "julia")))

    recv = CountReceiver()
    TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, B), recv)
    @test get(recv.counts, "derived_file_analysis", 0) == 0
end

@testitem "derived_file_analysis: a referenced-name id shift re-runs only the analyses that reference it" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    d = URI("file:///t/src/d.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        include("d.jl")
        end
        """,
        A => """
        a() = 1
        b() = 2
        c() = 3
        """,
        B => "uc() = c()\n",
        d => "ua() = a()\n",
    ))
    rt = jw.runtime

    # untraced baseline (see the trace-baseline note in test_module_tree.jl)
    fa_b0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    @test only(filter(o -> o.name == "c", fa_b0.outbound)).target !== nothing
    fa_d0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, d)
    old_a = only(filter(o -> o.name == "a", fa_d0.outbound)).target
    @test old_a !== nothing

    # swap `a` and `b`: their (positional) item ids swap, `c`'s id is
    # untouched
    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("""
    b() = 2
    a() = 1
    c() = 3
    """, "julia")))

    # B references only `c` — its per-name item lookup backdates, so the
    # analysis must not re-execute
    recv_b = CountReceiver()
    TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, B), recv_b)
    @test get(recv_b.counts, "derived_file_analysis", 0) == 0

    # D references `a` — its outbound ItemRef changed, so exactly one
    # re-execution, with the updated target
    recv_d = CountReceiver()
    fa_d1 = TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, d), recv_d)
    @test get(recv_d.counts, "derived_file_analysis", 0) == 1
    new_a = only(filter(o -> o.name == "a", fa_d1.outbound)).target
    @test new_a !== nothing
    @test new_a != old_a
    @test new_a == JuliaWorkspaces.derived_module_declared(rt, ROOT, ["MainPkg"])["a"]
end

@testitem "derived_file_analysis: import-bound tree references count in the outbound table" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sib
        export f
        f() = 1
        end
        """,
        B => """
        using .Sib: f as g
        h1() = g()
        h2() = g()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    f_item = JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Sib"])["f"]

    # every site resolves to the file-local import binding, whose val is the
    # tree target — all aggregated under the SOURCE name: the statement's
    # `f` leaf and its `as`-alias `g` (2) plus the two body uses of `g`
    ob_f = only(filter(o -> o.name == "f", fa.outbound))
    @test ob_f.target == f_item
    @test ob_f.origin_module == ["MainPkg", "Sib"]
    @test ob_f.count == 4

    # no separate row under the BOUND name — the alias is file-local
    @test !any(o -> o.name == "g", fa.outbound)
end

@testitem "derived_file_analysis: a whole-module import contributes an outbound row for the module" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sib
        f() = 1
        end
        """,
        B => """
        using .Sib
        q() = Sib.f()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    # the statement's `Sib` component (import binding with a TreeRef val)
    # and the qualified use's `Sib` (direct TreeRef) aggregate into one row
    ob = only(filter(o -> o.name == "Sib", fa.outbound))
    @test ob.target == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["Sib"]
    @test ob.origin_module == ["MainPkg"]
    @test ob.count == 2
end

@testitem "derived_file_analysis: no handles or module stores survive in the frozen value" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => """
        module Inner
        h() = 1
        end
        usebase() = Base.sqrt(2.0)
        w() = afunc()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    MS = JuliaWorkspaces.SymbolServer.ModuleStore

    # tree resolution did happen
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, B)
    @test SL.refof(only(find_identifiers(cst, "afunc")), fa.meta) isa SL.TreeRef

    # the `Base` module ref survives as plain data, not as the ModuleStore —
    # kind `:external_module` marks it as an env-store stand-in,
    # distinguishable from tree-resolved `:module` TreeRefs
    rbase = SL.refof(only(find_identifiers(cst, "Base")), fa.meta)
    @test rbase isa SL.TreeRef
    @test rbase.name == "Base"
    @test rbase.kind === :external_module

    # ... but never entered the outbound table (it resolved through the env
    # stores, not through the tree)
    @test !any(o -> o.name == "Base", fa.outbound)

    # leaf symbol stores are kept: `sqrt` stays resolved
    @test SL.hasref(only(find_identifiers(cst, "sqrt")), fa.meta)

    leaks = sum(collect(values(fa.meta))) do m
        n = 0
        s = m.scope
        if s isa SL.Scope && s.modules isa Dict
            n += count(v -> v isa SL.AbstractModuleContext || v isa MS, collect(values(s.modules)))
        end
        m.ref isa MS && (n += 1)
        b = m.binding
        if b isa SL.Binding
            b.val isa MS && (n += 1)
            b.type isa MS && (n += 1)
        end
        n
    end
    @test leaks == 0
end

# --- Invalidation acceptance: the milestone's spec-level criteria. The
# mechanism-level fix-wave testitems above ("an unrelated same-kind reorder
# does not re-run an import-bearing analysis", "a referenced-name id shift
# re-runs only the analyses that reference it") pin the id-free import-path
# selectors, the per-name item granularity, and the shifted-name counterpart
# (exactly one re-execution with the outbound ItemRef updated); the items
# below assert the acceptance criteria themselves and reference — rather than
# re-prove — that coverage.

@testitem "invalidation acceptance: a body edit re-analyzes exactly the edited file" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc(x) = x + 1\n",
        B => "bcaller() = afunc(1)\n",
    ))
    rt = jw.runtime

    # untraced baseline (see the trace-baseline note in test_module_tree.jl's
    # invalidation testitem: cold-cache execution is not what we measure)
    fa_a0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, A)
    @test !isempty(fa_a0.meta)
    fa_b0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    @test only(filter(o -> o.name == "afunc", fa_b0.outbound)).target !== nothing
    JuliaWorkspaces.derived_module_tree(rt, ROOT)

    # body edit in A: name/kind sets untouched, only the definition body
    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("afunc(x) = x * 42\n", "julia")))

    # the edited file's analysis re-executes (its own CST changed) ...
    recv_a = CountReceiver()
    TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, A), recv_a)
    @test get(recv_a.counts, "derived_file_analysis", 0) == 1
    @test get(recv_a.counts, "derived_module_tree", 0) == 0

    # ... the sibling's analysis and the module tree never do (the inventory
    # backdates, so everything downstream of it early-exits)
    recv_b = CountReceiver()
    fa_b1 = TL.with_tracing(recv_b) do
        fa = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
        JuliaWorkspaces.derived_module_tree(rt, ROOT)
        fa
    end
    @test get(recv_b.counts, "derived_file_analysis", 0) == 0
    @test get(recv_b.counts, "derived_module_tree", 0) == 0
    @test only(filter(o -> o.name == "afunc", fa_b1.outbound)).target !== nothing
end

@testitem "invalidation acceptance: a same-kind adjacent reorder leaves unshifted-name consumers untouched" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # A consumer of the id-carrying name→kind projection: re-executes only if
    # `derived_module_names`'s VALUE changed (Salsa early-exit on isequal).
    Salsa.@derived function probe_names(rt, root)
        return JuliaWorkspaces.derived_module_names(rt, root, ["MainPkg"])
    end

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        a() = 1
        b() = 2
        c() = 3
        """,
        B => "uc() = c()\n",
    ))
    rt = jw.runtime

    # untraced baseline (see the trace-baseline note in test_module_tree.jl)
    fa_b0 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    @test only(filter(o -> o.name == "c", fa_b0.outbound)).target !== nothing
    JuliaWorkspaces.derived_module_tree(rt, ROOT)
    @test probe_names(rt, ROOT)["c"] === :function
    before_declared = JuliaWorkspaces.derived_module_declared(rt, ROOT, ["MainPkg"])

    # swap the adjacent same-kind `a`/`b`: their item ids swap, the
    # name/kind SET is identical, `c`'s id is untouched
    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("""
    b() = 2
    a() = 1
    c() = 3
    """, "julia")))

    recv = CountReceiver()
    TL.with_tracing(recv) do
        JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
        JuliaWorkspaces.derived_module_tree(rt, ROOT)
        probe_names(rt, ROOT)
    end

    # B references only the unshifted `c`: its per-name item backdates, so
    # the analysis never re-executes
    @test get(recv.counts, "derived_file_analysis", 0) == 0
    # the tree's VALUE changed (the ItemRefs for `a`/`b` swapped): exactly
    # one re-execution
    @test get(recv.counts, "derived_module_tree", 0) == 1
    # `derived_module_names` re-executes (its dependency's value changed) but
    # BACKDATES: the name→kind set is unchanged, so its consumer early-exits.
    # Exactly once: only ["MainPkg"]'s names were pulled in this scenario.
    @test get(recv.counts, "derived_module_names", 0) == 1
    @test get(recv.counts, "probe_names", 0) == 0

    # sanity: the ids really did shift (this is the fixture the fix-wave
    # testitem "a referenced-name id shift re-runs only the analyses that
    # reference it" builds on — the counterpart case, a file referencing a
    # SHIFTED name re-executing exactly once with its outbound ItemRef
    # updated, is pinned there and not re-proven here)
    after_declared = JuliaWorkspaces.derived_module_declared(rt, ROOT, ["MainPkg"])
    @test after_declared["a"] != before_declared["a"]
    @test after_declared["b"] != before_declared["b"]
    @test after_declared["c"] == before_declared["c"]
end

@testitem "invalidation acceptance: a new name/export in a sibling re-analyzes the referencing file and clears its missing-ref diagnostic" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # --- New declared name in a sibling file of the same module.
    jw1 = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => "bcaller() = brandnew_xyz()\n",
    ))
    rt1 = jw1.runtime

    # untraced baseline (see the trace-baseline note in test_module_tree.jl):
    # the reference is a missing ref before the edit
    fa_b0 = JuliaWorkspaces.derived_file_analysis(rt1, ROOT, B)
    @test any(d -> occursin("brandnew_xyz", d.message), fa_b0.diagnostics)
    @test !any(o -> o.name == "brandnew_xyz", fa_b0.outbound)

    JuliaWorkspaces.update_file!(jw1, TextFile(A, SourceText("""
    afunc() = 1
    brandnew_xyz() = 2
    """, "julia")))

    recv1 = CountReceiver()
    fa_b1 = TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt1, ROOT, B), recv1)
    @test get(recv1.counts, "derived_file_analysis", 0) == 1
    @test !any(d -> occursin("brandnew_xyz", d.message), fa_b1.diagnostics)
    ob = only(filter(o -> o.name == "brandnew_xyz", fa_b1.outbound))
    @test ob.target == JuliaWorkspaces.derived_module_declared(rt1, ROOT, ["MainPkg"])["brandnew_xyz"]

    # --- New export in a used tree submodule: `using .Sub` only brings in
    # exports, so exporting the existing name is what makes it visible.
    jw2 = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sub
        sfunc() = 1
        end
        """,
        B => """
        using .Sub
        q() = sfunc()
        """,
    ))
    rt2 = jw2.runtime

    fa_q0 = JuliaWorkspaces.derived_file_analysis(rt2, ROOT, B)
    @test any(d -> occursin("sfunc", d.message), fa_q0.diagnostics)

    JuliaWorkspaces.update_file!(jw2, TextFile(A, SourceText("""
    module Sub
    export sfunc
    sfunc() = 1
    end
    """, "julia")))

    recv2 = CountReceiver()
    fa_q1 = TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt2, ROOT, B), recv2)
    @test get(recv2.counts, "derived_file_analysis", 0) == 1
    @test !any(d -> occursin("sfunc", d.message), fa_q1.diagnostics)
    @test only(filter(o -> o.name == "sfunc", fa_q1.outbound)).target ==
        JuliaWorkspaces.derived_module_declared(rt2, ROOT, ["MainPkg", "Sub"])["sfunc"]
end

@testitem "invalidation acceptance: keystroke cost — a body edit in a 10-file fixture costs exactly one analysis" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    # 10 files: the entry file plus f1..f9, each fᵢ (i ≥ 2) referencing a
    # name declared in fᵢ₋₁ — every file has real cross-file resolution work.
    file_uris = [URI("file:///t/src/f$i.jl") for i in 1:9]
    files = Dict{URI,String}(
        ROOT => "module MainPkg\n" * join(("include(\"f$i.jl\")" for i in 1:9), "\n") * "\nend\n",
    )
    files[file_uris[1]] = "fn1() = 1\n"
    for i in 2:9
        files[file_uris[i]] = "fn$i() = $i\ng$i() = fn$(i - 1)()\n"
    end
    jw = ws_with(files)
    rt = jw.runtime
    all_uris = [ROOT; file_uris]

    # untraced baseline over ALL analyses (see the trace-baseline note in
    # test_module_tree.jl — the cold cache fill is not the measurement)
    for u in all_uris
        JuliaWorkspaces.derived_file_analysis(rt, ROOT, u)
    end
    fa9 = JuliaWorkspaces.derived_file_analysis(rt, ROOT, file_uris[9])
    @test only(filter(o -> o.name == "fn8", fa9.outbound)).target !== nothing

    # the keystroke: a body edit in f5 (name/kind sets unchanged)
    JuliaWorkspaces.update_file!(jw, TextFile(file_uris[5], SourceText("fn5() = 500\ng5() = fn4()\n", "julia")))

    # re-pull every analysis: exactly ONE re-executes (the edited file's own)
    recv = CountReceiver()
    TL.with_tracing(recv) do
        for u in all_uris
            JuliaWorkspaces.derived_file_analysis(rt, ROOT, u)
        end
    end
    @test get(recv.counts, "derived_file_analysis", 0) == 1
    @test get(recv.counts, "derived_module_tree", 0) == 0
end

@testitem "file analysis: local file scope wins over the tree context" setup=[FileAnalysisWS] begin
    # `afunc` is declared both in a sibling file and locally in the analyzed
    # file — the file-local binding must win (resolution order: file-local
    # scopes first, the tree context last).
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => """
        afunc() = 2
        localcaller() = afunc()
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    hits = find_identifiers(cst, "afunc")
    @test length(hits) == 2
    r = SL.refof(hits[2], meta_dict)
    @test r isa SL.Binding
end

@testitem "derived_file_analysis: a macro-wrapped sibling declaration resolves cross-file" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        SomeMod.@somemacro function mfunc(x)
            x
        end
        """,
        B => "caller() = mfunc(1)\n",
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    @test !any(d -> occursin("mfunc", d.message), fa.diagnostics)
    @test only(filter(o -> o.name == "mfunc", fa.outbound)).target !== nothing
end

@testitem "derived_file_analysis: an unindexed external whole-module import still binds its name" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        import NotIndexedPkg
        include("b.jl")
        end
        """,
        B => "caller() = NotIndexedPkg.foo()\n",
    ))
    rt = jw.runtime

    # the import statement itself still warns (resolution failed) ...
    fa_root = JuliaWorkspaces.derived_file_analysis(rt, ROOT, ROOT)
    @test any(d -> occursin("NotIndexedPkg", d.message), fa_root.diagnostics)

    # ... but per that warning's own contract ("anything imported through
    # this statement is assumed to exist"), the bound name must not be
    # reported missing at its use sites in sibling files.
    vn = JuliaWorkspaces.derived_module_visible_names(rt, ROOT, ["MainPkg"])
    @test haskey(vn, "NotIndexedPkg")
    fa_b = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    @test !any(d -> occursin("NotIndexedPkg", d.message), fa_b.diagnostics)
end

@testitem "derived_file_analysis: by-use inference never overrides a tree-backed type annotation" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        struct S
            a
        end
        """,
        B => """
        g(y::VersionNumber) = y
        function f(x::S)
            g(x)
            return x.a
        end
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    # `x` is DECLARED `::S` — a sibling-file struct that resolves through the
    # module tree. The legacy `Binding.type` slot can't carry that (TreeRef),
    # so by-use inference used to kick in (`g(x)` pins `VersionNumber`, an
    # env type WITH fields) and the field check then flagged the real field
    # `a` as a missing reference. The whole-closure pass never did this: the
    # resolved annotation always set the type before by-use could guess.
    @test !any(d -> occursin("Missing reference: a", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: a sibling file's failed wildcard using suppresses missing-ref hints module-wide" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        using NotIndexedPkg
        include("b.jl")
        end
        """,
        B => """
        caller() = some_wildcard_provided_name()
        module Inner
        inner_caller() = another_undefined_name()
        end
        """,
    ))
    rt = jw.runtime

    fa_b = JuliaWorkspaces.derived_file_analysis(rt, ROOT, B)
    # `using NotIndexedPkg` (in the SIBLING entry file) failed to resolve, so
    # any bare name in MainPkg's scope may come from it — parity with the
    # whole-closure pass's `scope.unresolved_wildcard_import` suppression,
    # which spans all files spliced into the module
    @test !any(d -> occursin("some_wildcard_provided_name", d.message), fa_b.diagnostics)
    # ... but a module DECLARED INSIDE the analyzed file is its own scope
    # boundary (`in_unresolved_wildcard_import_scope` stops at modules): the
    # suppression must not leak into it
    @test any(d -> occursin("another_undefined_name", d.message), fa_b.diagnostics)
end

@testitem "derived_file_analysis: relative-dot imports at the analyzed file's own top level resolve through tree parents" setup=[FileAnalysisWS] begin
    # Shape 1: single-dot colon-form whose module component was ALREADY bound
    # by a preceding `import .URIs2` (the binding's val is a plain-data
    # TreeRef) — the colon members must continue the walk through the
    # denoted tree module, not dead-end on the Binding.
    u2 = URI("file:///t/src/URIs2.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("URIs2.jl")
        include("a.jl")
        end
        """,
        u2 => """
        module URIs2
        struct URI
            s
        end
        uri2filepath(u) = u.s
        macro uri_str(s) end
        export URI, uri2filepath, @uri_str
        end
        """,
        A => """
        import .URIs2
        using .URIs2: uri2filepath
        using .URIs2: URI, @uri_str
        u() = uri2filepath(URI("file:///x"))
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, A)
    @test !any(d -> occursin("Failed to resolve", d.message), fa.diagnostics)
    @test !any(d -> occursin("Missing reference", d.message), fa.diagnostics)
    @test only(filter(o -> o.name == "uri2filepath", fa.outbound)).target !== nothing

    # Shape 2: a multi-dot relative import at the analyzed file's own top
    # level — the dot-walk must continue past the parentless file scope into
    # the tree context's PARENT modules.
    proto = URI("file:///t/src/proto.jl")
    jw2 = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        module Inner
        include("proto.jl")
        end
        end
        """,
        A => """
        module Sib
        export sfunc
        sfunc() = 1
        end
        """,
        proto => """
        using ..Sib: sfunc
        caller() = sfunc()
        """,
    ))
    fa2 = JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, proto)
    @test !any(d -> occursin("Relative import", d.message), fa2.diagnostics)
    @test !any(d -> occursin("Failed to resolve", d.message), fa2.diagnostics)
    @test !any(d -> occursin("Missing reference", d.message), fa2.diagnostics)
    @test only(filter(o -> o.name == "sfunc", fa2.outbound)).target !== nothing

    # Shape 3: the relative path lands on a name bound by the parent module's
    # own import of a WORKSPACE PACKAGE — the walk continues cross-root into
    # the package's tree (this is the protocol.jl `using ..JSONRPC: ...`
    # pattern from the real-workspace differential).
    wp_proj = URI("file:///t/pkgs/WP/Project.toml")
    wp_entry = URI("file:///t/pkgs/WP/src/WP.jl")
    proto_wp = URI("file:///t/src/proto_wp.jl")
    jw_wp = ws_with(Dict(
        ROOT => """
        module MainPkg
        import WP
        module Inner
        include("proto_wp.jl")
        end
        end
        """,
        wp_entry => """
        module WP
        macro dict_readable(x) end
        struct RequestType
            x
        end
        export @dict_readable, RequestType
        end
        """,
        proto_wp => """
        using ..WP: @dict_readable, RequestType
        r(x::RequestType) = x
        """,
    ))
    add_file!(jw_wp, TextFile(wp_proj, SourceText("""
    name = "WP"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0009"
    version = "0.1.0"
    """, "toml")))
    fa_wp = JuliaWorkspaces.derived_file_analysis(jw_wp.runtime, ROOT, proto_wp)
    @test !any(d -> occursin("Failed to resolve", d.message), fa_wp.diagnostics)
    @test !any(d -> occursin("Missing reference", d.message), fa_wp.diagnostics)

    # Shape 4: an ABSOLUTE import of a workspace package in the analyzed
    # file itself — the whole-closure pass resolves it through its
    # `workspace_packages` dict; per-file mode must reach the same package
    # through the tree (the script-root `using JuliaWorkspaces` pattern).
    abs_wp = URI("file:///t/src/abs_wp.jl")
    JuliaWorkspaces.add_file!(jw_wp, TextFile(abs_wp, SourceText("""
    using WP
    import WP: RequestType
    r2(x::RequestType) = x
    """, "julia")))
    fa_abs = JuliaWorkspaces.derived_file_analysis(jw_wp.runtime, abs_wp, abs_wp)
    @test !any(d -> occursin("could not be indexed", d.message), fa_abs.diagnostics)
    @test !any(d -> occursin("Failed to resolve", d.message), fa_abs.diagnostics)
    @test !any(d -> occursin("Missing reference", d.message), fa_abs.diagnostics)

    # Too many dots is still an error: three levels up from Inner does not exist.
    proto3 = URI("file:///t/src/proto3.jl")
    jw3 = ws_with(Dict(
        ROOT => """
        module MainPkg
        module Inner
        include("proto3.jl")
        end
        end
        """,
        proto3 => "using ....Nowhere: nope\n",
    ))
    fa3 = JuliaWorkspaces.derived_file_analysis(jw3.runtime, ROOT, proto3)
    @test any(d -> occursin("Relative import has more leading dots", d.message), fa3.diagnostics)
end

@testitem "derived_file_analysis: the tree context resolves before global stores" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "filter(x) = x\n",
        B => """
        u() = filter(1)
        v() = sum([1])
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    # `filter` is declared at module level in a sibling: the module-declared
    # name SHADOWS Base's export (Julia semantics), so the reference must
    # resolve through the `:__tree__` context — by explicit rule, not by
    # Symbol-hash iteration order over `scope.modules`.
    fx = only(find_identifiers(cst, "filter"))
    fr = SL.refof(fx, meta_dict)
    @test fr isa SL.TreeRef
    @test fr.item !== nothing

    # A non-shadowed Base export still falls through to the store.
    sx = only(find_identifiers(cst, "sum"))
    sr = SL.refof(sx, meta_dict)
    @test !(sr isa SL.TreeRef)
    @test sr !== nothing
end

@testitem "derived_file_analysis: method-set lints decline for tree-visible callees" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        # A sees only a forward declaration and a single method of `f` — the
        # module's full method set provably extends beyond this file (the
        # names are visible through the tree context), so per-file
        # FunctionHasNoMethods / IncorrectCallArgs would be false positives.
        A => """
        function pe end
        pe_caller() = pe(1)
        f(x) = x
        f_caller() = f(1, 2)
        """,
        B => """
        pe(x) = x
        f(x, y) = x + y
        """,
    ))
    rt = jw.runtime

    fa_a = JuliaWorkspaces.derived_file_analysis(rt, ROOT, A)
    @test !any(d -> occursin("Called function has no methods", d.message), fa_a.diagnostics)
    @test !any(d -> occursin("Possible method call error", d.message), fa_a.diagnostics)

    # A LOCAL (function-scope) callee is not tree-visible: its method set is
    # fully in view, so the arity check must still fire.
    local_uri = URI("file:///t/src/local.jl")
    jw2 = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("local.jl")
        end
        """,
        local_uri => """
        function outer()
            g(x) = x
            return g(1, 2)
        end
        """,
    ))
    fa_l = JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, local_uri)
    @test any(d -> occursin("Possible method call error", d.message), fa_l.diagnostics)

    # The whole-closure pass is untouched: it sees the full method set and
    # never produced these lints on this fixture in the first place — and its
    # `check_all` path takes no tree-visibility predicate at all.
    old = JuliaWorkspaces.derived_static_lint_diagnostics_for_root(rt, ROOT)
    @test !any(d -> occursin("method", d.message), Iterators.flatten(values(old)))

    # The gate is scope-aware: a call inside a module DECLARED IN the
    # analyzed file checks visibility at that module's path, not the file's
    # splice path (the real-workspace StaticLint.jl shape — the module's
    # other files hold the wider method set).
    sl = URI("file:///t/src/sl.jl")
    scope2 = URI("file:///t/src/scope2.jl")
    jw3 = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("sl.jl")
        end
        """,
        sl => """
        module Lint
        include("scope2.jl")
        hs(m) = 1
        caller() = hs(1, 2)
        end
        """,
        scope2 => "hs(a, b) = 2\n",
    ))
    fa_sl = JuliaWorkspaces.derived_file_analysis(jw3.runtime, ROOT, sl)
    @test !any(d -> occursin("Possible method call error", d.message), fa_sl.diagnostics)
end

@testitem "qualified use through a tree-module lhs resolves members to TreeRefs" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sib
        export f
        f() = 1
        struct T
            x::Int
        end
        end
        """,
        B => """
        using .Sib
        q() = Sib.f()
        w() = Sib.T
        bad() = Sib.nope()
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)
    declared = JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Sib"])

    # `Sib.f` — the member resolves through the module's visible names to a
    # TreeRef carrying the declaring ItemRef
    rf = SL.refof(only(find_identifiers(cst, "f")), meta_dict)
    @test rf isa SL.TreeRef
    @test rf.kind === :function
    @test rf.item == declared["f"]
    @test rf.origin_module == ["MainPkg", "Sib"]

    # `Sib.T` — a struct member resolves the same way
    rt_ = SL.refof(only(find_identifiers(cst, "T")), meta_dict)
    @test rt_ isa SL.TreeRef
    @test rt_.kind === :struct
    @test rt_.item == declared["T"]
    @test rt_.origin_module == ["MainPkg", "Sib"]

    # a member the module does not declare gets no ref (missing-ref parity
    # with the old pass's getfield behavior for source-module lhs)
    @test !SL.hasref(only(find_identifiers(cst, "nope")), meta_dict)
end

@testitem "qualified use members flow into the outbound table" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sib
        export f
        f() = 1
        struct T
            x::Int
        end
        end
        """,
        B => """
        using .Sib
        q() = Sib.f()
        w() = Sib.T
        bad() = Sib.nope()
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    declared = JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Sib"])

    # the file gets BOTH a `Sib` row (the lhs) and member rows with targets
    ob_sib = only(filter(o -> o.name == "Sib", fa.outbound))
    @test ob_sib.target == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["Sib"]
    # the `using .Sib` component plus the three qualified lhs uses
    @test ob_sib.count == 4

    ob_f = only(filter(o -> o.name == "f", fa.outbound))
    @test ob_f.target == declared["f"]
    @test ob_f.origin_module == ["MainPkg", "Sib"]
    @test ob_f.count == 1

    ob_t = only(filter(o -> o.name == "T", fa.outbound))
    @test ob_t.target == declared["T"]

    # the unresolved member contributes no row
    @test !any(o -> o.name == "nope", fa.outbound)
end

@testitem "qualified use through an import-bound tree module lhs resolves" setup=[FileAnalysisWS] begin
    # `import .Sib` binds `Sib` in the file's scope as a Binding whose val is
    # the plain-data TreeRef — member resolution must continue through it.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        module Sib
        f() = 1
        end
        """,
        B => """
        import .Sib
        q() = Sib.f()
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    rf = SL.refof(only(find_identifiers(cst, "f")), meta_dict)
    @test rf isa SL.TreeRef
    @test rf.kind === :function
    @test rf.item == JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg", "Sib"])["f"]
end

@testitem "qualified use through an external module stand-in lhs resolves via the env store" setup=[FileAnalysisWS] begin
    # The SIBLING file binds `Iterators` (an env module) at module level; the
    # analyzed file's `Iterators` lhs therefore resolves through the tree to
    # an env-module stand-in TreeRef, and the member must resolve through the
    # env `ModuleStore` like the old getfield path.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "using Base.Iterators\n",
        B => """
        t(x) = Iterators.take(x, 1)
        miss(x) = Iterators.surely_not_a_member_xyz(x)
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    # the lhs is a tree-resolved env stand-in, not a ModuleStore
    rit = SL.refof(first(find_identifiers(cst, "Iterators")), meta_dict)
    @test rit isa SL.TreeRef
    @test rit.kind === :external_symbol
    @test rit.origin_module == ["Base", "Iterators"]

    # the member resolved through the store (leaf SymStore ref, no TreeRef —
    # matching what direct `Base.Iterators.take` gets)
    tk = only(find_identifiers(cst, "take"))
    @test SL.hasref(tk, meta_dict)
    @test SL.refof(tk, meta_dict) isa JuliaWorkspaces.SymbolServer.SymStore

    # a name the store does not have stays unresolved
    @test !SL.hasref(only(find_identifiers(cst, "surely_not_a_member_xyz")), meta_dict)
end

@testitem "qualified use still resolves external chains through the store path" setup=[FileAnalysisWS] begin
    # `Base.Iterators.take` never touches the tree: `Base` is the seeded root
    # ModuleStore and the whole chain resolves through the old getfield arms.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => "t(x) = Base.Iterators.take(x, 1)\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    @test SL.hasref(only(find_identifiers(cst, "take")), meta_dict)
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    # env-resolved chains never masquerade as tree-resolved outbound rows
    @test !any(o -> o.name in ("Base", "Iterators", "take"), fa.outbound)
end

@testitem "qualified use through a workspace-package module lhs resolves cross-root" setup=[FileAnalysisWS] begin
    wp_proj = URI("file:///t/pkgs/WP/Project.toml")
    wp_entry = URI("file:///t/pkgs/WP/src/WP.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        import WP
        include("b.jl")
        end
        """,
        wp_entry => """
        module WP
        wpfunc() = 1
        end
        """,
        B => "c() = WP.wpfunc()\n",
    ))
    add_file!(jw, TextFile(wp_proj, SourceText("""
    name = "WP"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0010"
    version = "0.1.0"
    """, "toml")))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    rf = SL.refof(only(find_identifiers(cst, "wpfunc")), meta_dict)
    @test rf isa SL.TreeRef
    @test rf.kind === :function
    @test rf.item == JuliaWorkspaces.derived_module_declared(jw.runtime, wp_entry, ["WP"])["wpfunc"]
    @test rf.origin_module == ["WP"]

    # ... and the member flows into the outbound table with its target
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    ob = only(filter(o -> o.name == "wpfunc", fa.outbound))
    @test ob.target == rf.item
end

@testitem "regression guard: instance-field access through a tree-annotated lhs stays unflagged" setup=[FileAnalysisWS] begin
    # The M3 differential's JDAP only-old class (`framecode.unique_files`,
    # `frame.world`, ...): getfield through a VARIABLE whose type annotation
    # resolved to a TreeRef. The old pass's hints on this class are partly
    # cross-vintage false positives (old is not gold); pin the new behavior —
    # no ref, and no missing-ref hint — so the qualified-module work never
    # accidentally turns this class into new diagnostics.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => """
        struct FrameCode
            scope
            src
        end
        """,
        B => "g(framecode::FrameCode) = framecode.unique_files\n",
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)
    @test !SL.hasref(only(find_identifiers(cst, "unique_files")), meta_dict)

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("unique_files", d.message), fa.diagnostics)
end

# --- derived_new_static_lint_diagnostics: the per-file consumer face --------
# The uri-level query the diagnostics layer switches onto in M4: for every
# root the file belongs to, union that root's per-file analysis diagnostics
# (cross-root dedup = the old `derived_static_lint_diagnostics` behavior).

@testitem "derived_new_static_lint_diagnostics: matches the old per-uri query on a clean fixture" setup=[FileAnalysisWS] begin
    proj = URI("file:///t/parity/Project.toml")
    manifest = URI("file:///t/parity/Manifest.toml")
    src = URI("file:///t/parity/src/ParityPkg.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(proj, SourceText("""
    name = "ParityPkg"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0011"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(manifest, SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(src, SourceText("""
    module ParityPkg
    f(x) = x == nothing
    g() = undefined_ref_xyz()
    end
    """, "julia")))
    rt = jw.runtime

    new = JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, src)
    old = JuliaWorkspaces.derived_static_lint_diagnostics(rt, src)

    # both cover the missing ref and the nothing-equality lint hint ...
    @test any(d -> occursin("undefined_ref_xyz", d.message), new)
    @test any(d -> occursin("nothing", d.message), new)
    # ... and the two sets are byte-identical (no sanctioned divergence here)
    @test new == old
    @test new isa Set{JuliaWorkspaces.Diagnostic}
end

@testitem "derived_new_static_lint_diagnostics: a file in two roots unions both roots' analyses" setup=[FileAnalysisWS] begin
    root1 = URI("file:///t/two/src/R1.jl")
    root2 = URI("file:///t/two/src/R2.jl")
    sib1 = URI("file:///t/two/src/sib1.jl")
    sib2 = URI("file:///t/two/src/sib2.jl")
    shared = URI("file:///t/two/src/shared.jl")
    jw = ws_with(Dict(
        # root1's tree resolves n1 (via sib1) but not n2
        root1 => """
        module R1
        include("sib1.jl")
        include("shared.jl")
        end
        """,
        # root2's tree resolves n2 (via sib2) but not n1
        root2 => """
        module R2
        include("sib2.jl")
        include("shared.jl")
        end
        """,
        sib1 => "n1() = 1\n",
        sib2 => "n2() = 2\n",
        shared => "use() = n1() + n2()\n",
    ))
    # a project so both roots pass the consumer's project-less-root gate
    add_file!(jw, TextFile(URI("file:///t/two/Project.toml"), SourceText("""
    name = "Two"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0013"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///t/two/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    rt = jw.runtime

    @test JuliaWorkspaces.derived_roots_for_uri(rt, shared) == Set([root1, root2])

    res = JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, shared)

    d1 = JuliaWorkspaces.derived_file_analysis(rt, root1, shared).diagnostics
    d2 = JuliaWorkspaces.derived_file_analysis(rt, root2, shared).diagnostics

    # each root sees exactly one of the two names as missing ...
    @test any(d -> occursin("n2", d.message), d1) && !any(d -> occursin("n1", d.message), d1)
    @test any(d -> occursin("n1", d.message), d2) && !any(d -> occursin("n2", d.message), d2)
    # ... and the query is precisely the union across both roots
    @test res == union(Set(d1), Set(d2))
    @test any(d -> occursin("n1", d.message), res)
    @test any(d -> occursin("n2", d.message), res)
end

@testitem "derived_new_static_lint_diagnostics: a file in no root yields an empty set" setup=[FileAnalysisWS] begin
    # A mutual include cycle with no external entry: neither file is a root
    # (both are included), so there are no roots at all.
    a = URI("file:///t/none/a.jl")
    b = URI("file:///t/none/b.jl")
    jw = ws_with(Dict(
        a => "include(\"b.jl\")\nfa() = 1\n",
        b => "include(\"a.jl\")\nfb() = 1\n",
    ))
    rt = jw.runtime

    @test isempty(JuliaWorkspaces.derived_roots_for_uri(rt, a))
    res = JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, a)
    @test res isa Set{JuliaWorkspaces.Diagnostic}
    @test isempty(res)
end

@testitem "derived_new_static_lint_diagnostics: a sibling body edit does not re-execute the query for another file" setup=[FileAnalysisWS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc(x) = x + 1\n",
        B => "bcaller() = afunc(1)\n",
    ))
    rt = jw.runtime

    # untraced baseline (cold-cache fill is not the measurement)
    JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, A)
    JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, B)

    # body edit in the sibling B: A's per-file analysis (and its consumer
    # query) depend on neither B's CST nor anything B's edit backdates
    JuliaWorkspaces.update_file!(jw, TextFile(B, SourceText("bcaller() = afunc(2)\n", "julia")))

    recv = CountReceiver()
    TL.with_tracing(() -> JuliaWorkspaces.derived_new_static_lint_diagnostics(rt, A), recv)
    @test get(recv.counts, "derived_new_static_lint_diagnostics", 0) == 0
    @test get(recv.counts, "derived_file_analysis", 0) == 0
end

@testitem "derived_file_analysis: a colon import of an INDEXED external is never swept into UnresolvedImport" setup=[FileAnalysisWS] begin
    # Regression guard for the imports.jl `first_unresolved_import_component`
    # clause that treats an `:external_symbol` module-path component as
    # unresolved: it must fire ONLY for the unindexed stand-in. A module that
    # is actually in the env (Base) resolves its path to a ModuleStore (not a
    # TreeRef), and its members to store leaves — neither can hit the new
    # unresolved arm, so no spurious "Failed to resolve" appears.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("b.jl")
        end
        """,
        B => """
        using Base: sqrt
        import Base: floor
        r(x) = sqrt(x) + floor(x)
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)
    # both `sqrt` sites (the colon-import component and the use) resolved
    # through the env store; likewise `floor`
    @test all(x -> SL.hasref(x, meta_dict), find_identifiers(cst, "sqrt"))
    @test all(x -> SL.hasref(x, meta_dict), find_identifiers(cst, "floor"))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("Failed to resolve", d.message), fa.diagnostics)
    @test !any(d -> occursin("Missing reference", d.message), fa.diagnostics)
end
