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

    # the `Base` module ref survives as plain data, not as the ModuleStore
    rbase = SL.refof(only(find_identifiers(cst, "Base")), fa.meta)
    @test rbase isa SL.TreeRef
    @test rbase.name == "Base"
    @test rbase.kind === :module

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
