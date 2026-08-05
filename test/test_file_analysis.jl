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

@testitem "derived_file_analysis: a store function extended in a sibling is not false-flagged" setup=[FileAnalysisWS] begin
    # `Base.relpath(a,b,c)` overload lives in sibling a.jl; the 3-arg call in b.jl
    # is valid but the overload isn't in Base's env store, so check_call must
    # decline rather than false-flag IncorrectCallArgs.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "Base.relpath(a::AbstractString, b::AbstractString, c::AbstractString) = a\n",
        B => "f() = relpath(\"a\", \"b\", \"c\")\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) || occursin("method call error", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: cross-file argument-count check for project functions" setup=[FileAnalysisWS] begin
    # A module-level project function's method set spans files; the arg count is
    # checked against the FULL set (from the inventory, no sibling analysis).
    mm(fa) = [d.message for d in fa.diagnostics if occursin("No method matching", d.message)]

    # `f` defined only in a sibling, called with a wrong arity: flagged w/ detail.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "f(x) = x\n",
        B => "g() = f(1, 2)\n",
    ))
    d = mm(JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B))
    @test length(d) == 1 && occursin("Expected 1 argument, got 2", d[1])

    # A call matching a sibling method's arity is NOT flagged (arities aggregate
    # across files: f(x) in a.jl + f(x,y) in b.jl).
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "f(x) = x\n",
        B => "f(x, y) = x\ng() = f(1, 2)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, B)))

    # A bare forward declaration contributes no arity ⇒ no false positive.
    jw3 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "function f end\n",
        B => "g() = f(1)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw3.runtime, ROOT, B)))
end

@testitem "derived_file_analysis: every inner constructor counts towards a struct's arity" setup=[FileAnalysisWS] begin
    # A struct's cross-file arity comes from the inventory (`struct_nargs`), which
    # must cover ALL inner constructors — not just the first one, or calls to the
    # others false-flag.
    mm(fa) = [d.message for d in fa.diagnostics if occursin("No method matching", d.message)]

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => """
        struct S
            x::Int
            S(x) = new(x)
            S(x, y) = new(x + y)
        end
        """,
        B => "f() = (S(1), S(1, 2))\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)))

    # An arity no inner constructor accepts is still flagged.
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => """
        struct S
            x::Int
            S(x) = new(x)
            S(x, y) = new(x + y)
        end
        """,
        B => "f() = S(1, 2, 3)\n",
    ))
    @test length(mm(JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, B))) == 1
end

@testitem "derived_file_analysis: a field's docstring does not inflate a struct's arity" setup=[FileAnalysisWS] begin
    # The docstring is a bare string child of the struct body, not a field, so a
    # documented field must not make the struct demand an extra argument.
    mm(fa) = [d.message for d in fa.diagnostics if occursin("No method matching", d.message)]
    root_src = "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
    docfield = "struct S\n    \"the a field\"\n    a::Int\nend\n"

    flagged(a_src, call) = mm(JuliaWorkspaces.derived_file_analysis(
        ws_with(Dict(ROOT => root_src, A => a_src, B => "g() = $call\n")).runtime, ROOT, B))

    @test isempty(flagged(docfield, "S(1)"))
    # The real field count is still enforced.
    @test length(flagged(docfield, "S(1, 2)")) == 1
end

@testitem "derived_file_analysis: a method-call error names the mismatch" setup=[FileAnalysisWS] begin
    # the flagged call renders a specific reason, not the bare
    # "Possible method call error." — here an arity mismatch on a store function.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "f() = sqrt(1, 2, 3)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    d = only(x for x in fa.diagnostics if occursin("method matching", x.message))
    @test occursin("sqrt", d.message)
    @test occursin("Expected 1 argument", d.message) && occursin("got 3", d.message)
end

@testitem "derived_file_analysis: a store call with no workspace extension still flags" setup=[FileAnalysisWS] begin
    # guard: the decline is precise — a genuinely wrong call to a store function
    # the workspace does NOT extend must still flag.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "f() = sqrt(1, 2, 3)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test any(d -> occursin("method matching", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: a store function extended via unqualified import is not false-flagged" setup=[FileAnalysisWS] begin
    # `import Base: relpath` then a bare 3-arg `relpath(...) = ...` extends
    # Base.relpath; the 3-arg call in b.jl is valid and must not false-flag.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "import Base: relpath\nrelpath(a::AbstractString, b::AbstractString, c::AbstractString) = a\n",
        B => "f() = relpath(\"a\", \"b\", \"c\")\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) || occursin("method call error", d.message), fa.diagnostics)
end

@testitem "derived_file_analysis: a store fn imported and extended in one file checks both method sets" setup=[FileAnalysisWS] begin
    # `import Base: show` + a 3-arg overload + a 2-arg call ALL in one file: the
    # call's `func_ref` is a `Binding` wrapping Base.show's `FunctionStore`, whose
    # method set is the store methods PLUS the workspace overload. Gate 1 must not
    # check only the workspace (3-arg) arities and false-flag the valid 2-arg call
    # (`show(io, x)` is a real Base method).
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "import Base: show\nshow(io::IO, x::Int, extra) = x\ng(io) = show(io, 5)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) || occursin("method call error", d.message), fa.diagnostics)

    # Guard: a genuinely wrong arity (matching NO store method and NO overload)
    # on the same imported+extended function must still flag.
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "import Base: size\nsize(x::Int, a, b, c) = a\ng() = size()\n",
    ))
    fa2 = JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, B)
    @test any(d -> occursin("method matching", d.message), fa2.diagnostics)

    # A call matching ONLY the workspace overload's arity (no store method) is
    # accepted through the workspace-arity branch even with a store present.
    jw3 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "import Base: show\nshow(io::IO, x::Int, extra) = x\ng(io) = show(io, 1, 2)\n",
    ))
    fa3 = JuliaWorkspaces.derived_file_analysis(jw3.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) || occursin("method call error", d.message), fa3.diagnostics)

    # DataTypeStore path: an imported+extended type. `Set([1])` matches a Base
    # constructor; the workspace adds a 3-arg constructor. Neither call is flagged.
    jw4 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "import Base: Set\nSet(a::Int, b::Int, c::Int) = a\nf() = Set([1])\nh() = Set(1, 2, 3)\n",
    ))
    fa4 = JuliaWorkspaces.derived_file_analysis(jw4.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) || occursin("method call error", d.message), fa4.diagnostics)
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

@testitem "derived_file_analysis: a sibling reorder leaves referencing analyses untouched" setup=[FileAnalysisWS] begin
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

    # Swap `a` and `b`. Item ids are content-based, so no name's id moves — the
    # edit is invisible to every consumer that only holds ItemRefs.
    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("""
    b() = 2
    a() = 1
    c() = 3
    """, "julia")))

    # B references only `c` — untouched either way.
    recv_b = CountReceiver()
    TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, B), recv_b)
    @test get(recv_b.counts, "derived_file_analysis", 0) == 0

    # D references `a` — whose ItemRef the reorder leaves alone, so D's outbound
    # target is unchanged and its analysis backdates too.
    recv_d = CountReceiver()
    fa_d1 = TL.with_tracing(() -> JuliaWorkspaces.derived_file_analysis(rt, ROOT, d), recv_d)
    @test get(recv_d.counts, "derived_file_analysis", 0) == 0
    new_a = only(filter(o -> o.name == "a", fa_d1.outbound)).target
    @test new_a !== nothing
    @test new_a == old_a
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

    # swap the adjacent same-kind `a`/`b`: with content-based ids no id moves,
    # so the tree's value and the name/kind set are both identical
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

    # B references only `c`: its per-name item backdates, so the analysis never
    # re-executes
    @test get(recv.counts, "derived_file_analysis", 0) == 0
    # the tree re-executes (the inventory's `order` fields moved) but its VALUE
    # is now unchanged, so it backdates
    @test get(recv.counts, "derived_module_tree", 0) == 1
    # `derived_module_names` re-executes (its dependency's value changed) but
    # BACKDATES: the name→kind set is unchanged, so its consumer early-exits.
    # Exactly once: only ["MainPkg"]'s names were pulled in this scenario.
    @test get(recv.counts, "derived_module_names", 0) == 1
    @test get(recv.counts, "probe_names", 0) == 0

    # A reorder leaves all three declaring ItemRefs untouched — that is what lets
    # the counts above be zero.
    after_declared = JuliaWorkspaces.derived_module_declared(rt, ROOT, ["MainPkg"])
    @test after_declared["a"] == before_declared["a"]
    @test after_declared["b"] == before_declared["b"]
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

@testitem "derived_file_analysis: a re-exported name used through `using` is not a missing ref" setup=[FileAnalysisWS] begin
    # `Child` re-exports `bar`, which it imported from `Prov` (not declared in
    # `Child`). `using .Child` in the enclosing module must make `bar` visible,
    # so the `bar()` use is not reported "Missing reference: bar".
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        module Prov
        export bar
        bar() = 1
        end
        module Child
        using ..Prov
        export bar
        end
        using .Child
        useit() = bar()
        end
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, ROOT)
    # No missing-ref, and — since `bar` binds as `:unknown` — no false
    # arg-count flag on the `bar()` call either: no diagnostic mentions `bar`.
    @test !any(d -> occursin("bar", d.message), fa.diagnostics)
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
    @test !any(d -> occursin("method matching", d.message) || occursin("Possible method call error", d.message), fa_a.diagnostics)

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
    @test any(d -> occursin("method matching", d.message) || occursin("Possible method call error", d.message), fa_l.diagnostics)

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
    @test !any(d -> occursin("method matching", d.message) || occursin("Possible method call error", d.message), fa_sl.diagnostics)
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
    # ... and the two sets are byte-identical (no sanctioned divergence here).
    # The old whole-closure pass never sees macro-declared names, so adding a
    # `@declare_input` or `@deprecate` to this fixture would break this
    # assertion legitimately — that is not a regression.
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

@testitem "references aggregation: each_reference is a plain function, not an ItemRef-keyed derived value" begin
    import JuliaWorkspaces
    # The M4 references/rename/highlight aggregation (`each_reference`) is a
    # request-time function: an `ItemRef` is volatile by design, so it must NOT
    # seed a Salsa derived value. Guard against a regression that memoizes it.
    srcdir = joinpath(pkgdir(JuliaWorkspaces), "src")
    offending = String[]
    for f in ("layer_file_analysis.jl", "layer_references.jl", "layer_module_tree.jl")
        for line in eachline(joinpath(srcdir, f))
            occursin("Salsa.@derived", line) || continue
            # No `@derived function derived_*reference*` (an aggregation keyed on
            # who-references-an-item would be an ItemRef-keyed volatile value).
            occursin(r"derived_\w*reference"i, line) && push!(offending, strip(line))
        end
    end
    @test isempty(offending)

    # `each_reference` exists as a plain function and is not registered as a
    # derived query.
    @test JuliaWorkspaces.each_reference isa Function
    @test !isdefined(JuliaWorkspaces, :derived_each_reference)
    @test !isdefined(JuliaWorkspaces, :derived_references)
end

@testitem "file analysis: an outer constructor for a sibling-file datatype does not shadow the struct" setup=[FileAnalysisWS] begin
    # Regression: a datatype declared in one file and its plain outer
    # constructor written in a SIBLING file, both reached through an
    # intermediary `packagedef.jl`-style include (the real Revise.jl shape:
    # `module Revise; include("packagedef.jl"); end` → types.jl `struct
    # WatchList` + utils.jl `WatchList() = ...`). In per-file traversal mode
    # the constructor's file can only see the struct through the module tree,
    # not as a local scope binding, so `WatchList() = ...` used to introduce a
    # shadowing local FUNCTION binding — making in-file `::WatchList`
    # annotations resolve to a non-DataType and emit a false
    # `InvalidTypeDeclaration` diagnostic, and misattributing every consumer to
    # the constructor rather than the struct. The whole-closure pass never had
    # this problem (the struct binding is already in the shared scope).
    pkgdef = URI("file:///t/src/packagedef.jl")
    types = URI("file:///t/src/types.jl")
    utils = URI("file:///t/src/utils.jl")
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("packagedef.jl")
        end
        """,
        pkgdef => """
        include("types.jl")
        include("utils.jl")
        """,
        types => """
        mutable struct WatchList
            x
        end
        """,
        utils => """
        WatchList() = WatchList(0)
        watched(l::WatchList) = l.x
        """,
    ))
    rt = jw.runtime

    # (a) both included files splice into the same module path.
    @test JuliaWorkspaces.derived_file_module_path(rt, ROOT, types) == ["MainPkg"]
    @test JuliaWorkspaces.derived_file_module_path(rt, ROOT, utils) == ["MainPkg"]

    # (b) the struct is the declared/visible winner at the module (datatype
    # wins over its own constructor).
    @test JuliaWorkspaces.derived_module_names(rt, ROOT, ["MainPkg"])["WatchList"] == :mutable_struct
    vis = JuliaWorkspaces.derived_module_visible_names(rt, ROOT, ["MainPkg"])
    @test haskey(vis, "WatchList") && vis["WatchList"].kind == :mutable_struct
    struct_ref = JuliaWorkspaces.derived_module_declared(rt, ROOT, ["MainPkg"])["WatchList"]
    @test struct_ref.file == types

    # (c) NO false `InvalidTypeDeclaration` diagnostic on utils.jl, and the
    # `::WatchList` annotation resolves to the tree struct (a TreeRef carrying
    # the struct's declaring ItemRef), not to the local constructor binding.
    fa = JuliaWorkspaces.derived_file_analysis(rt, ROOT, utils)
    @test !any(d -> occursin("non-DataType", d.message), fa.diagnostics)

    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(rt, utils)
    anns = find_identifiers(cst, "WatchList")
    decl_anns = filter(x -> (p = SL.parentof(x); p isa CST.EXPR && CST.isdeclaration(p)), anns)
    @test !isempty(decl_anns)   # the `l::WatchList` annotations
    ann_ref = SL.refof(first(decl_anns), fa.meta)
    @test ann_ref isa SL.TreeRef
    @test ann_ref.kind == :mutable_struct
    @test ann_ref.item == struct_ref

    # every in-file use of `WatchList` (annotations AND the constructor's own
    # call sites) resolves to the struct, not to a local constructor binding.
    @test !isempty(anns)
    @test all(x -> SL.refof(x, fa.meta) isa SL.TreeRef &&
                   SL.refof(x, fa.meta).item == struct_ref, anns)

    # (d) `derived_method_items` returns BOTH the struct and the constructor.
    mi = JuliaWorkspaces.derived_method_items(rt, ROOT, ["MainPkg"], "WatchList")
    @test length(mi) == 2
    @test any(r -> r.file == types, mi)
    @test any(r -> r.file == utils, mi)
end

@testitem "file analysis: a nested local closure shadowing a sibling-file datatype stays local" setup=[FileAnalysisWS] begin
    # Companion to the outer-constructor regression above: the method-extension
    # rule for a sibling-file datatype must only fire at MODULE/top-level scope,
    # not inside a nested function. Here `WatchList` is a datatype declared in a
    # sibling file, but `WatchList() = 5` is a legitimate LOCAL closure inside
    # `outer()` that deliberately shadows it. In per-file traversal mode the
    # method-extension branch (which sees the struct only through the module
    # tree) must NOT fire for this nested scope — otherwise both the closure
    # definition and the inner `WatchList()` call would misresolve to the
    # struct's TreeRef instead of the local function binding, matching neither
    # Julia's semantics nor the whole-closure pass.
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "mutable struct WatchList end\n",
        B => """
        function outer()
            WatchList() = 5
            return WatchList()
        end
        """,
    ))

    cst, meta_dict, _ = run_per_file_pass(jw, ROOT, B)

    struct_ref = JuliaWorkspaces.derived_module_declared(jw.runtime, ROOT, ["MainPkg"])["WatchList"]

    anns = find_identifiers(cst, "WatchList")
    @test length(anns) == 2   # the closure definition name and the inner call
    # No occurrence of the shadowing local `WatchList` may resolve to the
    # sibling struct's TreeRef.
    for x in anns
        r = SL.refof(x, meta_dict)
        @test !(r isa SL.TreeRef)
        @test !(r isa SL.TreeRef && r.item == struct_ref)
    end
    # The inner call resolves to the LOCAL closure binding.
    call_id = anns[end]
    @test SL.refof(call_id, meta_dict) isa SL.Binding
end

@testitem "derived_file_analysis: frozen meta carries no empty entries" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "afunc() = 1\n",
        B => """
        function bfunc(x)
            y = x + afunc()
            return y * 2
        end
        """,
    ))

    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)

    # `ensuremeta` residue (all fields `nothing`) is indistinguishable from
    # absence for every reader and must not survive the freeze.
    @test !isempty(fa.meta)
    @test all(values(fa.meta)) do m
        m.binding !== nothing || m.scope !== nothing || m.ref !== nothing || m.error !== nothing
    end

    # Queries against the pruned dict still resolve.
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, B)
    @test SL.refof(only(find_identifiers(cst, "afunc")), fa.meta) isa SL.TreeRef
    @test SL.scopeof(cst, fa.meta) isa SL.Scope
    xs = find_identifiers(cst, "y")
    @test length(xs) == 2
    @test all(x -> SL.hasbinding(x, fa.meta) || SL.hasref(x, fa.meta), xs)
end

@testitem "file analysis: a chain that leaves this file rules nothing out" setup=[FileAnalysisWS] begin
    # `Own <: MyAbs <: Integer` with `MyAbs` in a sibling: a real subtype whose
    # supertype walk dead-ends at a `TreeRef`. Ruling the call out would be a
    # false positive on correct code. The callee is a closure on purpose — a
    # module-level one is answered by the cross-file arity check instead — and
    # the argument is a typed parameter, since a constructor call's type is `Any`.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs <: Integer end\n",
        B => """
        struct Own <: MyAbs end
        function caller(v::Own)
            h(x::Integer) = 1
            return h(v)
        end
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test !any(d -> occursin("method matching", d.message) ||
                    occursin("method call error", d.message), fa.diagnostics)
end

@testitem "inventory: items carry method signatures and supertypes" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, UnknownType, TYPE_ANY, SigSlot

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        abstract type MyAbs end
        struct Own <: MyAbs
            a
            b::Int
        end
        struct Other end
        target(x::MyAbs) = 1
        function f end
        end
        """,
    ))
    inv = JuliaWorkspaces.derived_file_inventory(jw.runtime, ROOT)
    byname = Dict(i.name => i for i in inv.items)

    @test byname["MyAbs"].supertype == TYPE_ANY
    @test byname["Own"].supertype == TypeRef(["MyAbs"])
    @test byname["Other"].supertype == TYPE_ANY

    # Struct constructor: no inner constructor, so `method_sig` is nothing and
    # `ctor_sigs` holds the default record — one all-Unknown slot per field.
    @test byname["Own"].method_sig === nothing
    @test length(byname["Own"].ctor_sigs) == 1
    @test [sl.type for sl in byname["Own"].ctor_sigs[1].slots] == [UnknownType(), UnknownType()]

    @test byname["target"].method_sig !== nothing
    @test byname["target"].method_sig.slots[1].type == TypeRef(["MyAbs"])

    # Forward declaration: no signature, no arity — shape data absent, kind present.
    @test byname["f"].method_sig === nothing && byname["f"].arity === nothing
end

@testitem "signature index: per-name sets with completeness markers" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: LocatedSignature

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::MyAbs) = 1\nabstract type MyAbs end\nfunction fwd end\n",
        B => "target(x::MyAbs, y) = 2\n",
    ))
    rt = jw.runtime

    nm = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")
    @test length(nm.signatures) == 2
    @test all(ls -> ls.defined_in == ["MainPkg"], nm.signatures)
    @test !nm.has_unknown_shapes && !nm.has_forward_decl

    fwd = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "fwd")
    @test isempty(fwd.signatures) && fwd.has_forward_decl

    # Unknown name → the empty, marker-free answer.
    miss = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "nope")
    @test miss == JuliaWorkspaces.EMPTY_NAME_METHODS

    # Moving a method between files leaves the per-name value ==.
    before = nm
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nfunction fwd end\n",
        B => "target(x::MyAbs) = 1\ntarget(x::MyAbs, y) = 2\n",
    ))
    after = JuliaWorkspaces.derived_method_signatures(jw2.runtime, ROOT, ["MainPkg"], "target")
    @test before == after
end

@testitem "signature index: a macro-declared name still marks has_unknown_shapes" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "@deprecate oldname newname\n",
        B => "oldname(x) = 1\n",
    ))
    rt = jw.runtime

    nm = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "oldname")
    @test !isempty(nm.signatures)
    @test nm.has_unknown_shapes
end

@testitem "backdating: a type-only edit leaves arity answers equal" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "target(x::Int) = 1\n",
        B => "caller(y) = target(y)\n",
    ))
    rt = jw.runtime
    arities_before = JuliaWorkspaces.derived_method_arities(rt, ROOT, ["MainPkg"], "target")
    sigs_before = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")

    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("target(x::String) = 1\n", "julia")))

    @test JuliaWorkspaces.derived_method_arities(rt, ROOT, ["MainPkg"], "target") == arities_before
    @test JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target") != sigs_before
end

@testitem "backdating: moving a method between files leaves the signature set equal" setup=[FileAnalysisWS] begin
    # A real cross-file caller (in a third file, `C`) so the diagnostic being
    # asserted unchanged is an actual definite-mismatch method-call flag, not
    # just C's self-contained lint hints. `target(:sym)` types as `Symbol`,
    # which intersects neither `Int` nor `String` — a definite rule-out.
    mm(fa) = [d.message for d in fa.diagnostics if occursin("No method matching", d.message)]

    C = URI("file:///t/src/c.jl")
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\ninclude(\"c.jl\")\nend\n",
        A => "target(x::Int) = 1\ntarget(x::String) = 2\n",
        B => "\n",
        C => "good() = target(1)\nbad() = target(:sym)\n",
    ))
    rt = jw.runtime
    before = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")
    c_before = mm(JuliaWorkspaces.derived_file_analysis(rt, ROOT, C))
    @test length(c_before) == 1

    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("target(x::Int) = 1\n", "julia")))
    JuliaWorkspaces.update_file!(jw, TextFile(B, SourceText("target(x::String) = 2\n", "julia")))

    after = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "target")
    @test after == before

    # C's own flag (unrelated to the move — its calls never resolve through
    # A or B directly) survives the move unchanged.
    c_after = mm(JuliaWorkspaces.derived_file_analysis(rt, ROOT, C))
    @test c_after == c_before

    # And matches a from-cold rebuild of the already-moved state.
    jw2 = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\ninclude(\"c.jl\")\nend\n",
        A => "target(x::Int) = 1\n",
        B => "target(x::String) = 2\n",
        C => "good() = target(1)\nbad() = target(:sym)\n",
    ))
    c_cold = mm(JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, C))
    @test c_cold == c_after
end

@testitem "backdating: moving a struct with an inner constructor between files leaves the signature set equal" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct T\n    x\n    T(x::Int; scale=1) = new(x * scale)\nend\n",
        B => "\n",
    ))
    rt = jw.runtime
    before = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "T")
    @test !isempty(before.signatures)

    JuliaWorkspaces.update_file!(jw, TextFile(A, SourceText("\n", "julia")))
    JuliaWorkspaces.update_file!(jw, TextFile(B, SourceText("struct T\n    x\n    T(x::Int; scale=1) = new(x * scale)\nend\n", "julia")))

    after = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "T")
    @test after == before

    # A keyword rename is the one edit `ctor_sigs` actually tracks by name
    # (slot types are erased, positional parameter names aren't recorded) —
    # proves the equality above isn't vacuous.
    JuliaWorkspaces.update_file!(jw, TextFile(B, SourceText("struct T\n    x\n    T(x::Int; factor=1) = new(x * factor)\nend\n", "julia")))
    renamed = JuliaWorkspaces.derived_method_signatures(rt, ROOT, ["MainPkg"], "T")
    @test renamed != before
end

@testitem "tree_resolve: workspace names, store names, unknowns" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TypeRef
    const SS = JuliaWorkspaces.SymbolServer

    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\n",
        B => "caller() = 1\n",
    ))
    rt = jw.runtime
    resolve = JuliaWorkspaces._tree_type_resolver(rt, ROOT)

    own = resolve(TypeRef(["Own"]), ["MainPkg"])
    @test own isa SL.TreeDataType && own.key == (["MainPkg"], "Own")
    @test own.sup == TypeRef(["MyAbs"])

    # Store name (Base is visible everywhere) → a store value the subtype walk
    # understands: the DATATYPE, not the constructor `FunctionStore` `Base.Int`
    # actually holds.
    int = resolve(TypeRef(["Int"]), ["MainPkg"])
    @test int isa SS.DataTypeStore
    # Qualified store name — `Base.AbstractString` is a `VarRef` alias in the
    # store, and an unfollowed alias compares against nothing.
    @test resolve(TypeRef(["Base", "AbstractString"]), ["MainPkg"]) isa SS.DataTypeStore
    # Unknown → nothing, silently.
    @test resolve(TypeRef(["NoSuchName"]), ["MainPkg"]) === nothing
    # The walk crosses tree → store: Own <: MyAbs <: Any ends definitely.
    myabs = resolve(TypeRef(["MyAbs"]), ["MainPkg"])
    @test SL._issubtype(own, myabs, nothing, nothing) === true
end

@testitem "tree_resolve: a re-exported package type keys on where it is declared" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TypeRef, JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    # `T` is declared in WP's SUBMODULE and re-exported by WP, so the two
    # spellings bind it under different modules (`WP` vs `WP.Sub`). Keying a
    # `TreeDataType` on the binding module would give one type two keys — and a
    # definite `false` between a type and itself.
    main_project = "name = \"MainP\"\nuuid = \"b2345678-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n"
    manifest_toml = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc123\"\n\n[deps]\n"
    wp_project = "name = \"WP\"\nuuid = \"c2345678-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsptype/Main/Project.toml"), SourceText(main_project, "toml")))
    add_file!(jw, TextFile(URI("file:///wsptype/Main/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///wsptype/Main/src/MainP.jl"),
        SourceText("module MainP\nusing WP\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///wsptype/WP/Project.toml"), SourceText(wp_project, "toml")))
    add_file!(jw, TextFile(URI("file:///wsptype/WP/src/WP.jl"),
        SourceText("module WP\ninclude(\"sub.jl\")\nusing .Sub\nexport T, Ab\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///wsptype/WP/src/sub.jl"),
        SourceText("module Sub\nabstract type Ab end\nstruct T <: Ab end\nexport T, Ab\nend\n", "julia")))

    main_root = URI("file:///wsptype/Main/src/MainP.jl")
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, main_root)

    reexported = resolve(TypeRef(["T"]), ["MainP"])
    qualified = resolve(TypeRef(["WP", "Sub", "T"]), ["MainP"])
    @test reexported isa SL.TreeDataType && qualified isa SL.TreeDataType
    @test reexported.key == (["WP", "Sub"], "T")
    @test reexported.key == qualified.key
    @test SL._has_type_intersection(reexported, qualified, nothing, nothing) === true

    # The supertype walk starts in the DECLARING module, so `Ab` resolves the
    # same way from either spelling.
    ab = resolve(TypeRef(["Ab"]), ["MainP"])
    @test ab isa SL.TreeDataType && ab.key == (["WP", "Sub"], "Ab")
    @test SL._issubtype(reexported, ab, nothing, nothing) === true
end

@testitem "parity: bare identifier, sibling-file callee flags a definite mismatch" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        """,
        B => """
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    msgs = [d.message for d in fa.diagnostics]
    flagged = filter(m -> occursin("method call error", m) || occursin("No method matching", m), msgs)
    @test length(flagged) == 1   # `bad` flags, `good` does not
    # The one flag names the argument's own type, not the `Any` the legacy
    # binding-type slot falls back to for a sibling-file annotation.
    @test occursin("target(::Other)", only(flagged))
    # Both calls were really compared against the record, and only one was ruled out.
    @test rec.comparisons >= 2 && rec.rule_outs == 1
end

@testitem "parity: both include orders give identical diagnostics" setup=[FileAnalysisWS] begin
    # Two methods of one name, split across the files, plus a call checked
    # against their union: the answer is the whole root's method set, so it
    # cannot depend on which file the include tree reaches first.
    function msgs(includes::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\n$includes\nend\n",
            A => "struct Own end\ntarget(x::Own) = 1\n",
            B => """
            struct Other end
            target(x::Other) = 2
            good(v::Own) = target(v)
            bad(w::Int) = target(w)
            """,
        ))
        return sort([d.message for d in JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B).diagnostics])
    end
    ab = msgs("include(\"a.jl\")\ninclude(\"b.jl\")")
    ba = msgs("include(\"b.jl\")\ninclude(\"a.jl\")")
    @test ab == ba
    flagged = filter(m -> occursin("No method matching", m) || occursin("method call error", m), ab)
    @test length(flagged) == 1
    @test occursin("target(::Int64)", only(flagged))
end

@testitem "parity: bare identifier, closure callee flags a definite mismatch" setup=[FileAnalysisWS] begin
    # Types live in the SAME file as the closure: the EXPR path resolves
    # annotations through local bindings only — its cross-file hop is a
    # later deferral and is NOT asserted here.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        function caller(v::Own, w::Other)
            target(x::MyAbs) = 1
            target(v)
            target(w)
        end
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity: closure callee resolves sibling-file types through the records" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\n",
        B => """
        function caller(v::Own, w::Other)
            target(x::MyAbs) = 1
            target(v)
            target(w)
        end
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1   # `target(w)` flags, `target(v)` does not
    @test occursin("target(::Other)", only(flagged).message)
    # `target(v)`'s match short-circuits in `sig_match_any(::Binding)`'s direct
    # check; `target(w)`'s mismatch does not, so it falls through to the
    # `.refs` loop and is compared (and ruled out) a second time.
    @test rec.comparisons >= 2 && rec.rule_outs == 2
end

@testitem "parity: closure callee needs the mid-walk hop, not just call-side resolution" setup=[FileAnalysisWS] begin
    # `Own`'s own supertype (`OtherAbs`) is unrelated to `MyAbs` — ruling this
    # out needs `_super` to walk PAST `Own`'s immediate supertype and hit the
    # sibling-file `TreeRef` mid-chain (`OtherAbs`), not merely the call-side
    # annotation read: a fixture built only from directly cross-file/same-file
    # annotations can't tell the mid-walk hop apart from a plain "not ruled
    # out" (both read as "no flag"). Confirmed by temporarily disabling the
    # `sup_a isa TreeRef` conversion in `_issubtype`: this fixture drops to 0
    # flags, while the earlier (non-discriminating) mid-walk fixture does not
    # change either way.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nabstract type OtherAbs end\n",
        B => """
        struct Own <: OtherAbs end
        function caller(v::Own)
            target(x::MyAbs) = 1
            target(v)
        end
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("target(::Own)", only(flagged).message)
    # The one call's mismatch never short-circuits (see the comment above), so
    # it is compared, and ruled out, twice.
    @test rec.comparisons >= 1 && rec.rule_outs == 2
end

@testitem "parity: bare identifier, same-file module-level callee flags a definite mismatch" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity: bare identifier, store callee flags a definite mismatch" setup=[FileAnalysisWS] begin
    # `iseven` has an `iseven(n::Real)` method (an ABSTRACT store param — the
    # good arm must match through ancestry, not by luck), and every one of its
    # methods (Missing/AbstractFloat/Real/Number) resolves cleanly in a
    # stdlib-only env, so `Other`'s plain `Any` supertype rules all of them
    # out. (`sin` was tried first: its store record set also includes
    # LinearAlgebra-typed methods that this env can't resolve, which read as
    # unknown rather than ruled out and left `bad` permanently unflagged.)
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => """
        struct Other end
        struct MyReal <: Real end
        good(v::MyReal) = iseven(v)
        bad(w::Other) = iseven(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity: bare identifier, one-file root reports like a same-file module-level callee" setup=[FileAnalysisWS] begin
    # The same source analysed as a project-less one-file root: the file IS
    # its whole tree, so the record path must reach the same verdict. (True
    # "no root" cannot be expressed through derived_file_analysis — a file
    # outside every root produces no analysis at all, which is the silent
    # end of the degradation map by construction.)
    jw = ws_with(Dict(
        B => """
        abstract type MyAbs end
        struct Own <: MyAbs end
        struct Other end
        target(x::MyAbs) = 1
        good(v::Own) = target(v)
        bad(w::Other) = target(w)
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, B, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity: the type phase declines wherever the record set is partial" setup=[FileAnalysisWS] begin
    # Every case here is correct code whose callee has methods, or keywords, the
    # signature records do not list. Exhausting the records would flag it.
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    # A workspace overload of a Base function: the records hold the workspace's
    # share of `length`'s methods only.
    @test isempty(callflags("import Base: length\nstruct D end\nlength(d::D) = 1\n",
                            "caller(v::Vector) = length(v)\n"))

    # `; kwargs...` accepts any keyword.
    @test isempty(callflags("struct T end\ng(x::T; kwargs...) = 2\n",
                            "caller(v::T) = g(v; anything=1)\n"))

    # A keyword declared with a type and a default is still a keyword.
    @test isempty(callflags("struct T end\nf(x::T, y::Int; define::Bool=true) = 1\n",
                            "caller(v::T) = f(v, 1; define=false)\n"))

    # A type parameter can bind a VALUE, so a typevar argument types nothing.
    @test isempty(callflags("struct P{Q} end\nd!(b::Bool) = 1\n",
                            "caller(p::P{Q}) where {Q} = d!(Q)\n"))

    # A datatype's records model the field constructor, not its keyword form.
    @test isempty(callflags("Base.@kwdef struct FS\n    inc::Int = 1\n    exc::Int = 2\nend\n",
                            "mk() = FS(; inc=3, exc=4)\n"))

    # A keyword splat passes an unknown — possibly empty — keyword set.
    @test isempty(callflags("struct O end\nf(x::O) = 1\n",
                            "caller(v::O, kw) = f(v; kw...)\n"))
    # Same at a store-backed callee, which reads the call's keywords the same way.
    @test isempty(callflags("struct O end\nnoop(x::O) = 1\n",
                            "caller(kw) = sin(1; kw...)\n"))
end

@testitem "parity: store callee with a workspace overload — union of both method sets" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "import Base: iseven\nstruct D end\niseven(d::D) = true\nstruct Other end\n",
        B => """
        import Base: iseven
        good1(d::D) = iseven(d)        # served by the workspace overload
        good2(x::Int) = iseven(x)      # served by the store's own methods
        bad(w::Other) = iseven(w)      # served by neither: flag
        """,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)
end

@testitem "parity: placement (e) — store callee with workspace overload, per shape" setup=[FileAnalysisWS] begin
    # For each shape, `iseven` (or a workspace-defined stand-in) is bound via
    # `import Base: ...` in both files and also overloaded in the workspace;
    # `good1` is served only by the workspace half of the union, `good2` only
    # by the store half, and `bad` by neither. The bare shape is covered by
    # "parity: store callee with a workspace overload — union of both method
    # sets" above — not repeated here.
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    # parametric: the workspace half carries the shape — a head-only match
    # (`D{Int}` vs. the call's `D{String}`) — the store half is unrelated.
    flagged = callflags(
        "import Base: iseven\nstruct D{T} end\niseven(d::D{Int}) = true\nstruct Other end\n",
        """
        import Base: iseven
        good1(d::D{String}) = iseven(d)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)

    # union: the workspace half's parameter is a `Union` of two workspace types.
    flagged = callflags(
        "import Base: iseven\nstruct P end\nstruct Q end\nstruct Other end\niseven(x::Union{P,Q}) = true\n",
        """
        import Base: iseven
        good1(p::P) = iseven(p)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)

    # where: the workspace half's typevar is bounded by a workspace abstract
    # type unrelated to the store's own `Real`/`Number` bounds.
    flagged = callflags(
        "import Base: iseven\nabstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\niseven(x::T) where {T<:MyAbs} = true\n",
        """
        import Base: iseven
        good1(o::Own) = iseven(o)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)

    # vararg: the workspace half carries the shape — `iseven`'s own methods are
    # all unary, so a multi-arg call can only be served by the workspace side.
    flagged = callflags(
        "import Base: iseven\nstruct D end\niseven(d::D, xs::D...) = true\nstruct Other end\n",
        """
        import Base: iseven
        good1(d::D) = iseven(d, d, d)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w, w)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)

    # optional: the workspace half carries the shape via a defaulted slot.
    flagged = callflags(
        "import Base: iseven\nstruct D end\niseven(d::D, y::Int=1) = true\nstruct Other end\n",
        """
        import Base: iseven
        good1(d::D) = iseven(d, 2)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w, 2)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)

    # keywords: the workspace half carries the shape via a declared keyword.
    flagged = callflags(
        "import Base: iseven\nstruct D end\niseven(d::D; k=1) = true\nstruct Other end\n",
        """
        import Base: iseven
        good1(d::D) = iseven(d; k=2)
        good2(x::Int) = iseven(x)
        bad(w::Other) = iseven(w; k=2)
        """)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)
end

@testitem "parity: store callee with a qualified extension in the current root" setup=[FileAnalysisWS] begin
    # `Base.iseven(::D2) = true` is a QUALIFIED extension: its resolved
    # qualifier is never a tree module, so `derived_method_items`/the
    # signature index drops it exactly like `derived_external_method_extensions`
    # does for the arity side — `tree.ext_records` is the only channel that
    # sees it.
    bsrc = """
    import Base: iseven
    good(d::D2) = iseven(d)   # served by the qualified extension's own record
    bad(w::Other) = iseven(w)
    """
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct D2 end\nBase.iseven(::D2) = true\nstruct Other end\n",
        B => bsrc,
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    # The generic message carries no type name here (`describe_call_mismatch`
    # returns `nothing` for this callee shape) — pin the flag to `bad`'s own
    # call by its source range instead.
    @test SubString(bsrc, only(flagged).range) == "iseven(w)\n"
end

@testitem "parity: store callee with a deved dependency's workspace extension" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    # DevPkg is DEVED into MainP (a Manifest `[deps.DevPkg]` entry with a
    # `path`, no registry version): its `Base.iseven(::E) = true` lives in
    # DevPkg's OWN root's signature index, never MainP's, and in no jstore
    # either — `tree.ext_records` walks every deved dependency root, and the
    # extension's own parameter type (`E`, declared inside DevPkg) resolves
    # through `tree.ext_resolve`, started at DevPkg's root rather than MainP's.
    main_project = "name = \"MainP\"\nuuid = \"b2345678-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n"
    dev_uuid = "cccccccc-dddd-eeee-ffff-000000000000"
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]

    [[deps.DevPkg]]
    path = "../DevPkg"
    uuid = "$dev_uuid"
    version = "0.1.0"
    """
    dev_project = "name = \"DevPkg\"\nuuid = \"$dev_uuid\"\nversion = \"0.1.0\"\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///devroot/Main/Project.toml"), SourceText(main_project, "toml")))
    add_file!(jw, TextFile(URI("file:///devroot/Main/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///devroot/Main/src/MainP.jl"),
        SourceText("""
        module MainP
        using DevPkg
        import Base: iseven
        struct D end
        iseven(d::D) = true
        f(e::E) = iseven(e)        # served by the deved dependency's extension
        good2(x::Int) = iseven(x)  # served by the store's own methods
        bad(s::String) = iseven(s) # served by neither: flag
        end
        """, "julia")))
    add_file!(jw, TextFile(URI("file:///devroot/DevPkg/src/DevPkg.jl"),
        SourceText("module DevPkg\nstruct E end\nBase.iseven(::E) = true\nexport E\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///devroot/DevPkg/Project.toml"), SourceText(dev_project, "toml")))

    main_root = URI("file:///devroot/Main/src/MainP.jl")
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, main_root, main_root)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("String", only(flagged).message)
end

@testitem "parity: a deved dependency's own Project.toml is not required for its extension's control" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText
    using JuliaWorkspaces.URIs2: URI

    # Same shape as the deved-dependency testitem above but DevPkg has NO
    # `Project.toml` of its own — a manifest dev dep still names it, but it
    # never becomes a recognized workspace-package FOLDER
    # (`derived_workspace_package_roots`), so `E` never resolves at the CALL
    # SITE either (an accepted, unrelated blind spot: `f` stays silent either
    # way). `tree_ext_records` still finds DevPkg's root directly from
    # `derived_workspace_deved_packages` (the Manifest entry alone, no
    # `Project.toml` needed there), and hands `tree_ext_resolve` that SAME
    # root via `_ext_defined_in_roots` — not a `defined_in[1]` name lookup,
    # which `derived_workspace_package_roots` would answer `nothing` for
    # here. Regression guard for the bug the name-lookup fallback had: a
    # resolver started at the wrong (current) root can't resolve `E`, and an
    # unresolvable extension parameter widens to Any, silently matching
    # every argument — including this `bad(s::String)` control.
    main_project = "name = \"MainP\"\nuuid = \"b2345678-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n"
    dev_uuid = "cccccccc-dddd-eeee-ffff-000000000000"
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]

    [[deps.DevPkg]]
    path = "../DevPkg"
    uuid = "$dev_uuid"
    version = "0.1.0"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///devroot2/Main/Project.toml"), SourceText(main_project, "toml")))
    add_file!(jw, TextFile(URI("file:///devroot2/Main/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///devroot2/Main/src/MainP.jl"),
        SourceText("""
        module MainP
        using DevPkg
        import Base: iseven
        struct D end
        iseven(d::D) = true
        f(e::E) = iseven(e)
        bad(s::String) = iseven(s) # must still flag
        end
        """, "julia")))
    add_file!(jw, TextFile(URI("file:///devroot2/DevPkg/src/DevPkg.jl"),
        SourceText("module DevPkg\nstruct E end\nBase.iseven(::E) = true\nexport E\nend\n", "julia")))
    # No DevPkg/Project.toml.

    main_root = URI("file:///devroot2/Main/src/MainP.jl")
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, main_root, main_root)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("String", only(flagged).message)
end

@testitem "parity: a bare, unimported store callee the workspace extends is checked against the union" setup=[FileAnalysisWS] begin
    # No `import` in `B`: `iseven` resolves through the implicit `using Base`
    # straight to the raw `SymbolServer.FunctionStore`, never a `Binding` — the
    # callee shape `check_call`'s `tree.extended` early-return arm handles
    # directly, distinct from the `Binding`-wrapped store value the qualified-
    # extension testitem above exercises.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct D end\nBase.iseven(d::D) = true\nstruct Other end\n",
        B => """
        good1(d::D) = iseven(d)       # served by the sibling's qualified extension
        good2(x::Int) = iseven(x)     # served by the store
        bad(w::Other) = iseven(w)     # neither: flag
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("Other", only(flagged).message)
    # `good1` compared against the extension record, `good2` against the
    # store's own methods, `bad` against both halves and ruled out by each —
    # real comparisons happened on both sides of the union, not a lucky skip.
    @test rec.comparisons >= 3 && rec.rule_outs >= 2
end

@testitem "parity: an unreadable workspace extension declines the raw-store union check" setup=[FileAnalysisWS] begin
    # `function Base.iseven end` is a QUALIFIED forward declaration: it registers
    # as a workspace extension of `Base.iseven` (`derived_external_method_extensions`
    # sees the qualifier), but has no body, so its inventory item's `method_sig`
    # is `nothing` — the extension record set is an under-approximation. Exhausting
    # it would license a wrong verdict, so the union check must decline entirely
    # rather than fall back to the store half alone.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "function Base.iseven end\nstruct Other end\n",
        B => "bad(w::Other) = iseven(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test isempty(flagged)
end

@testitem "parity: methods defined when the code runs are not indexed" setup=[FileAnalysisWS] begin
    # A method born from `eval`, or from a macro nothing here can expand, leaves
    # no record behind, so a name's record set reads as complete when it is not
    # and a call the invisible method serves is ruled out. Both calls below are
    # correct; the flags are accepted false positives — such code can define
    # methods for any function in any module, so nothing can mark the records
    # partial without withholding every type opinion everywhere.
    function flagged(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("No method matching", d.message) ||
                           occursin("method call error", d.message), fa.diagnostics)
    end

    # `@eval` under a loop defines `f(::Int)` and `f(::Float64)`.
    @test_broken isempty(flagged("struct O end\nfor T in (Int, Float64)\n    @eval f(x::\$T) = 1\nend\nf(x::O) = 2\n",
                                 "caller() = f(3)\n"))
    # `@gen` expands to a method of `genf`, naming no `eval` at all.
    @test_broken isempty(flagged("struct O end\nmacro gen() :(genf(x::Int) = 1) end\n@gen\ngenf(x::O) = 2\n",
                                 "caller() = genf(1)\n"))
end

@testitem "parity: real-corpus operand defects never rule a call out" setup=[FileAnalysisWS] begin
    # Every fixture here is correct code from the 80-package corpus sweep,
    # reduced; each was ruled out by an argument the decision path typed wrongly.
    # The control beside it must still flag, or the fix has only silenced things.
    function flags(src::String)
        jw = ws_with(Dict(ROOT => src))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, ROOT)
        return filter(d -> occursin("No method matching", d.message) ||
                           occursin("method call error", d.message), fa.diagnostics)
    end

    # A hex literal's width comes from its DIGIT count: `0x4000_0001` is UInt32.
    @test isempty(flags("module P\nhasleaf(l::UInt32) = true\nf() = (leaf = 0x4000_0001; hasleaf(leaf))\ng() = hasleaf(0x0000_0007)\nend\n"))
    @test length(flags("module P\nhasleaf(l::UInt32) = true\nh() = hasleaf(0x0000_0000_0000_0007)\nend\n")) == 1

    # A local bound to a type NAME holds a type, so it matches a `::Type{…}` slot.
    @test isempty(flags("module Q\nP(::Type{Float64}) = 1\nQ2(::DataType) = 1\nR(::Type) = 1\nb() = (T = Float64; P(T))\nc() = (T = Float64; Q2(T))\nd() = (T = Float64; R(T))\nend\n"))
    @test length(flags("module Q\nP(::Type{Float64}) = 1\nbad() = (T = \"s\"; P(T))\nend\n")) == 1

    # A qualified extension binds the workspace's SHARE of another module's
    # generic; the owner's own methods are not in that binding.
    @test isempty(flags("module S\nstruct Ax end\nBase.axes(A::Ax) = ()\nBase.axes(A::Ax, d) = ()\ng(A::AbstractArray, d) = length(Base.axes(A, d))\nend\n"))
    # A qualified extension of a WORKSPACE module keeps its full set, and its checks.
    @test length(flags("module S2\nmodule Inner\nfoo(x::Int) = 1\nend\nInner.foo(x::String) = 2\ng() = Inner.foo(1.0)\nend\n")) == 1

    # A `where` typevar passed as an argument may bind a value: no opinion — and
    # the DECISION must use the same operand the message reports.
    @test isempty(flags("module T2\nf(x::NamedTuple{an}, y::NamedTuple{bn}) where {an,bn} = Base.merge_names(an, bn)\nend\n"))

    # `using Base: UUID` binds the name locally; a constructor call through the
    # imported name is the store type it stands for, not the import binding.
    @test isempty(flags("module U\nusing Base: PkgId, UUID\nf() = PkgId(UUID(42), \"x\")\ng(x::Base.UUID) = x\nh() = g(UUID(42))\nend\n"))
    @test isempty(flags("module U2\nimport Base: UUID\ng(x::UUID) = x\nh() = g(UUID(42))\nend\n"))
    @test length(flags("module U3\nusing Base: UUID, Dict\ng(x::Base.UUID) = x\nbad() = g(Dict(1=>2))\nend\n")) == 1

    # `(x,)::Ref{Any}` binds the ELEMENT: the container's type is not `x`'s.
    @test isempty(flags("module V\nstruct D end\nmycols(df::D) = 1\ng((x,)::Ref{Any}) = mycols(x)\nend\n"))
    # A `Tuple{…}` annotation does spell each element out, and still rules out.
    @test length(flags("module V2\nstruct D end\nmycols(df::D) = 1\ng((x, y)::Tuple{Ref{Any},Int}) = (mycols(x), y)\nend\n")) == 1
end

@testitem "parity: an anonymous constructor's methods are not indexed" setup=[FileAnalysisWS] begin
    # `(::Type{T})(x::Cenum{T2}) where T<:Integer` binds no name, so nothing
    # records it and `Integer(x)` is ruled out against Base's constructor set as
    # if it were complete. The call is correct — no decline for this form exists
    # yet, and the flag is an accepted false positive.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "(::Type{T})(x::Cenum{T2}) where {T<:Integer,T2<:Integer} = T(bitstring(x))\n",
        # The type is declared HERE on purpose: a sibling-file annotation leaves
        # the argument untyped, and an untyped argument rules nothing out, so the
        # form under test would not be reached at all.
        B => "abstract type Cenum{T<:Integer} end\nconv(x::Cenum) = Integer(x)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("No method matching", d.message) ||
                          occursin("method call error", d.message), fa.diagnostics)
    @test_broken isempty(flagged)
end

@testitem "parity: optional slots align before the vararg pad" setup=[FileAnalysisWS] begin
    # `f(a, b="x", xs::T...)`: a call that fills the optional slot must compare
    # it against the OPTIONAL's type, not the vararg's element type.
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    @test isempty(callflags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\n",
                            "caller() = f9(1, \"y\")\n"))
    @test isempty(callflags("f10(a::Int, b::String=\"x\", xs::Vararg{Float64,2}) = 1\n",
                            "caller() = f10(1, \"y\", 1.0, 2.0)\n"))
    # The same alignment in the legacy path, where the callee is a local closure
    # matched against its own definition EXPR.
    @test isempty(callflags("struct Z end\n",
                            "function caller()\n    g(a::Int, b::String=\"x\", xs::Float64...) = 1\n    g(1, \"y\")\nend\n"))

    # Still ruled out when the optional slot genuinely does not fit.
    @test length(callflags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\n",
                           "caller() = f9(1, 2.0, 3.0)\n")) == 1
end

@testitem "parity/qualified: Base-qualified annotation, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Base.AbstractString) = 1\n",
        B => "good(v::String) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/qualified: workspace-module-qualified annotation" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef

    jw = ws_with(Dict(
        ROOT => """
        module MainPkg
        module Inner
        abstract type MyAbs end
        end
        include("a.jl")
        include("b.jl")
        end
        """,
        A => "struct Own <: Inner.MyAbs end\nstruct Other end\ntarget(x::Inner.MyAbs) = 1\n",
        B => "good(v::Own) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1

    # Whitebox: `flagged == 1` alone does not distinguish a real match from an
    # indeterminate wave-through — `_issubtype`/`_has_type_intersection` treat
    # `nothing` as "not ruled out", so a regression that broke ONLY the
    # module-descent supertype resolution would leave `good` silently
    # indeterminate while `bad` still flags on its own annotation, and the
    # count would stay green. Resolve both names directly and assert a
    # DEFINITE subtype relation, plus the key equality the descent must reach.
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, ROOT)
    own = resolve(TypeRef(["Own"]), ["MainPkg"])
    myabs = resolve(TypeRef(["Inner", "MyAbs"]), ["MainPkg"])
    @test own isa SL.TreeDataType && myabs isa SL.TreeDataType
    @test myabs.key == (["MainPkg", "Inner"], "MyAbs")
    @test SL._issubtype(own, myabs, nothing, nothing) === true
end

@testitem "parity/parametric: head-only comparison, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Vector{Int}) = 1\n",
        B => """
        good(v::Vector{String}) = target(v)   # heads equal; type args are a non-goal
        bad(w::Other) = target(w)
        """,
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("target(::Other)", only(flagged).message)
    @test rec.comparisons >= 2 && rec.rule_outs == 1
end

@testitem "parity/inner-where: `Vector{T} where T` annotation is its head" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::Vector{T} where T) = 1\n",
        B => "good(v::Vector{Int}) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/dispatch-only: a nameless `::T` slot still types" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "abstract type MyAbs end\nstruct Own <: MyAbs end\nstruct Other end\ntarget(::MyAbs, y::Int) = 1\n",
        B => "good(v::Own) = target(v, 1)\nbad(w::Other) = target(w, 1)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "parity/shapes: closure callee flags each shape's definite mismatch" setup=[FileAnalysisWS] begin
    # Types stay in the SAME file as the closure in every shape below; the
    # cross-file hop for a closure callee is a later deferral, not asserted here.
    function flagged(src::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
            B => src,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    @test length(flagged("""
    struct Other end
    function caller(v::Vector{String}, w::Other)
        target(x::Vector{Int}) = 1
        target(v)
        target(w)
    end
    """)) == 1

    @test length(flagged("""
    struct Other end
    function caller(v::Vector{Int}, w::Other)
        target(x::Vector{T} where T) = 1
        target(v)
        target(w)
    end
    """)) == 1

    @test length(flagged("""
    abstract type MyAbs end
    struct Own <: MyAbs end
    struct Other end
    function caller(v::Own, w::Other)
        target(::MyAbs, y::Int) = 1
        target(v, 1)
        target(w, 1)
    end
    """)) == 1

    @test length(flagged("""
    struct P end
    struct Q end
    struct Other end
    function caller(v::P, w::Other)
        target(x::Union{P,Q}) = 1
        target(v)
        target(w)
    end
    """)) == 1

    @test length(flagged("""
    struct Other end
    function caller(v::Float64, w::Other)
        target(x::T) where {T <: Real} = 1
        target(v)
        target(w)
    end
    """)) == 1
end

@testitem "parity/shapes: same-file module-level callee flags each shape's definite mismatch" setup=[FileAnalysisWS] begin
    function flagged(src::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
            B => src,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    @test length(flagged("""
    struct Other end
    target(x::Vector{Int}) = 1
    good(v::Vector{String}) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    struct Other end
    target(x::Vector{T} where T) = 1
    good(v::Vector{Int}) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    abstract type MyAbs end
    struct Own <: MyAbs end
    struct Other end
    target(::MyAbs, y::Int) = 1
    good(v::Own) = target(v, 1)
    bad(w::Other) = target(w, 1)
    """)) == 1

    @test length(flagged("""
    struct P end
    struct Q end
    struct Other end
    target(x::Union{P,Q}) = 1
    good(v::P) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    struct Other end
    target(x::T) where {T <: Real} = 1
    good(v::Float64) = target(v)
    bad(w::Other) = target(w)
    """)) == 1
end

@testitem "parity/shapes: one-file root reports like a same-file module-level callee" setup=[FileAnalysisWS] begin
    function flagged(src::String)
        jw = ws_with(Dict(B => src))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, B, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    @test length(flagged("""
    struct Other end
    target(x::Vector{Int}) = 1
    good(v::Vector{String}) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    struct Other end
    target(x::Vector{T} where T) = 1
    good(v::Vector{Int}) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    abstract type MyAbs end
    struct Own <: MyAbs end
    struct Other end
    target(::MyAbs, y::Int) = 1
    good(v::Own) = target(v, 1)
    bad(w::Other) = target(w, 1)
    """)) == 1

    @test length(flagged("""
    struct P end
    struct Q end
    struct Other end
    target(x::Union{P,Q}) = 1
    good(v::P) = target(v)
    bad(w::Other) = target(w)
    """)) == 1

    @test length(flagged("""
    struct Other end
    target(x::T) where {T <: Real} = 1
    good(v::Float64) = target(v)
    bad(w::Other) = target(w)
    """)) == 1
end

@testitem "parity/union: workspace members rule out member-wise, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct P end\nstruct Q end\nstruct Other end\ntarget(x::Union{P,Q}) = 1\n",
        B => "good(v::P) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
end

@testitem "resolve_record_type: a mixed union keeps member opinions" setup=[FileAnalysisWS] begin
    using JuliaWorkspaces: TypeRef, TypeUnionExpr, MethodSignature, SigSlot, TypeExpr
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\nend\n",
        A => "struct P end\nstruct Other end\n",
    ))
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, ROOT)
    sig = MethodSignature([SigSlot(TypeUnionExpr(TypeExpr[TypeRef(["P"]), TypeRef(["Int"])]), false)],
        nothing, Dict{String,TypeExpr}(), Symbol[], false)
    u = SL.resolve_record_type(sig.slots[1].type, sig, ["MainPkg"], resolve)
    @test u isa SL.ResolvedUnion && length(u.members) == 2
    # A real store, not `nothing`: one member (`Int`) is a genuine env type, and
    # ruling it out needs `_super` to walk its ACTUAL supertype chain.
    env = JuliaWorkspaces.derived_stdlib_only_env(jw.runtime)
    store = SL.getsymbols(env)
    other = resolve(TypeRef(["Other"]), ["MainPkg"])
    @test SL._has_type_intersection(other, u, store, nothing) === false
    p = resolve(TypeRef(["P"]), ["MainPkg"])
    @test SL._has_type_intersection(p, u, store, nothing) === true
end

@testitem "parity/where: an upper-bounded typevar rules out, sibling callee" setup=[FileAnalysisWS] begin
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "struct Other end\ntarget(x::T) where {T <: Real} = 1\n",
        B => "good(v::Float64) = target(v)\nbad(w::Other) = target(w)\n",
    ))
    rec = SL.MatchRecorder()
    SL._match_recorder[] = rec
    fa = try
        JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    finally
        SL._match_recorder[] = nothing
    end
    flagged = filter(d -> occursin("method call error", d.message) ||
                          occursin("No method matching", d.message), fa.diagnostics)
    @test length(flagged) == 1
    @test occursin("target(::Other)", only(flagged).message)
    @test rec.comparisons >= 2 && rec.rule_outs == 1
end

@testitem "parity/where: a lower bound or unbounded typevar licenses nothing" setup=[FileAnalysisWS] begin
    # A lower bound (`T >: Int`) constrains the typevar from below, giving no
    # upper bound to rule a call out with; an unbounded `where T` gives none
    # either. These are reader facts about the record-side `where_var_and_bound`
    # (via `resolve_record_type`), not a new placement — sibling-file only.
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        rec = SL.MatchRecorder()
        SL._match_recorder[] = rec
        fa = try
            JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        finally
            SL._match_recorder[] = nothing
        end
        flagged = filter(d -> occursin("method call error", d.message) ||
                             occursin("No method matching", d.message), fa.diagnostics)
        return flagged, rec
    end

    flagged, rec = callflags("struct Other end\ntarget(x::T) where {T >: Int} = 1\n",
                             "callit(w::Other) = target(w)\n")
    @test isempty(flagged)
    # Silence must come from a declined comparison, not a candidate the pass
    # never reached.
    @test rec.comparisons >= 1 && rec.rule_outs == 0

    flagged, rec = callflags("struct Other end\ntarget(x::T) where T = 1\n",
                             "callit(w::Other) = target(w)\n")
    @test isempty(flagged)
    @test rec.comparisons >= 1 && rec.rule_outs == 0
end

@testitem "parity/vararg: every spelling aligns and rules out identically" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # dotted: typed pad rules out a definite mismatch
    @test isempty(callflags("f(a::Int, xs::Float64...) = 1", "c() = f(1, 2.0, 3.0)"))
    @test length(callflags("struct O end\nf(a::Int, xs::Float64...) = 1", "c(o::O) = f(1, o)")) == 1
    # anonymous ::Vararg: untyped pad accepts anything, count still open-ended
    @test isempty(callflags("f(a::Int, xs::Vararg) = 1", "c() = f(1, \"s\", 's')"))
    # ::Vararg{T}
    @test length(callflags("struct O end\nf(a::Int, xs::Vararg{Float64}) = 1", "c(o::O) = f(1, o)")) == 1
    # ::Vararg{T,N}: exact count, typed pad
    @test isempty(callflags("f(a::Int, xs::Vararg{Float64,2}) = 1", "c() = f(1, 1.0, 2.0)"))
    @test length(callflags("f(a::Int, xs::Vararg{Float64,2}) = 1", "c() = f(1, 1.0)")) == 1   # count, via the MethodArity channel — the arity gate short-circuits before the records path; the two windows are identical for a bound Vararg{T,N}
    # ::Base.Vararg{T}
    @test length(callflags("struct O end\nf(a::Int, xs::Base.Vararg{Float64}) = 1", "c(o::O) = f(1, o)")) == 1
end

@testitem "parity/optional: same-file, one-file-root, and a defaulted slot's own mismatch" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    function samefile_flags(src::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
            B => src,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    function oneroot_flags(src::String)
        jw = ws_with(Dict(B => src))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, B, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    @test isempty(samefile_flags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\ncaller() = f9(1, \"y\")\n"))
    @test length(samefile_flags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\ncaller() = f9(1, 2.0, 3.0)\n")) == 1

    @test isempty(oneroot_flags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\ncaller() = f9(1, \"y\")\n"))
    @test length(oneroot_flags("f9(a::Int, b::String=\"x\", xs::Float64...) = 1\ncaller() = f9(1, 2.0, 3.0)\n")) == 1

    # The optional slot's own annotation still rules out when the caller fills it explicitly.
    @test length(callflags("f(a::Int, b::String=\"x\") = 1\n", "caller() = f(1, 2.0)\n")) == 1
    @test isempty(callflags("f(a::Int, b::String=\"x\") = 1\n", "caller() = f(1)\n"))
end

@testitem "parity/keywords: name-checked gating, all placements agree" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    function oneroot_flags(src::String)
        jw = ws_with(Dict(B => src))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, B, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    function closure_callflags(src::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
            B => src,
        ))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end

    # Cross-file: keyword passed to method with no declared keywords → 1 flag
    @test length(callflags("struct T end\nf(x::T) = 1", "c(v::T) = f(v; k=1)")) == 1
    # Cross-file: declared keyword → no flags
    @test isempty(callflags("struct T end\nf(x::T; k=1) = 1", "c(v::T) = f(v; k=2)"))
    # Cross-file: wrong keyword name → 1 flag (MethodArity's name-membership gate)
    @test length(callflags("struct T end\nf(x::T; k=1) = 1", "c(v::T) = f(v; other=2)")) == 1
    # Cross-file: kwsplat accepts anything → no flags
    @test isempty(callflags("struct T end\nf(x::T; kws...) = 1", "c(v::T) = f(v; whatever=1)"))

    # Closure placement: `f` itself is nested inside `caller` — only `struct T`
    # stays at module level — so this exercises the EXPR descriptor engine
    # (_match_descriptor) exclusively, not the MethodArity/tree-arity channel.
    # Keyword passed to method with no declared keywords → 1 flag
    @test length(closure_callflags("struct T end\nfunction caller(v::T)\n  f(x::T) = 1\n  f(v; k=1)\nend")) == 1
    # Closure placement: declared keyword → no flags
    @test isempty(closure_callflags("struct T end\nfunction caller(v::T)\n  f(x::T; k=1) = 1\n  f(v; k=2)\nend"))
    # Closure placement: wrong keyword name → 1 flag (the engine's own
    # name-membership gate — this placement has no MethodArity channel to
    # fall back on, so it pins the gate added to _match_descriptor itself)
    @test length(closure_callflags("struct T end\nfunction caller(v::T)\n  f(x::T; k=1) = 1\n  f(v; other=2)\nend")) == 1
    # Closure placement: kwsplat accepts anything → no flags
    @test isempty(closure_callflags("struct T end\nfunction caller(v::T)\n  f(x::T; kws...) = 1\n  f(v; whatever=1)\nend"))

    # One-file-root variant of first arm: keyword passed to method with no declared keywords → 1 flag
    @test length(oneroot_flags("struct T end\nf(x::T) = 1\nc(v::T) = f(v; k=1)")) == 1
    # Store callee with a kw splat (`Base.ceil`'s `; digits, sigdigits, base`
    # methods): a MethodStore's kwsplat entry must not be name-checked as its
    # one declared keyword.
    @test isempty(oneroot_flags("c(v::Float64) = ceil(v; digits=2)"))
end

@testitem "parity/ctor-arg: a constructor-call argument carries its type" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # (c) constructed type declared in the sibling, call in B
    @test length(callflags("struct Own end\nstruct Other end\ntarget(x::Own) = 1\n",
                           "b1() = target(Other())\n")) == 1
    @test isempty(callflags("struct Own end\nstruct Other end\ntarget(x::Own) = 1\n",
                            "b2() = target(Own())\n"))
    # (b) same file
    @test length(callflags("struct Z end\n",
                           "struct Own end\nstruct Other end\ntarget(x::Own) = 1\nb3() = target(Other())\n")) == 1
    # (d) store type constructed: ArgumentError("x") vs a slot wanting a workspace type
    @test length(callflags("struct Own end\ntarget(x::Own) = 1\n",
                           "b4() = target(ArgumentError(\"x\"))\n")) == 1
    # (a) closure: whole path is local
    @test length(callflags("struct Z end\n",
                           "struct Own end\nstruct Other end\nfunction c()\n    t(x::Own) = 1\n    t(Other())\nend\n")) == 1
end

@testitem "parity: a forward-declared function with no methods flags, cross-file" setup=[FileAnalysisWS] begin
    function flagsof(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return [d.message for d in fa.diagnostics]
    end
    # sibling forward declaration, no methods anywhere: flag
    @test any(m -> occursin("no methods", m), flagsof("function f end\n", "c() = f()\n"))
    # a real method anywhere unflags it — here, beside the declaration
    @test !any(m -> occursin("no methods", m), flagsof("function f end\nf(x) = x\n", "c() = f(1)\n"))
end

@testitem "parity: a forward-declared function with no methods flags, same-file and one-file-root" setup=[FileAnalysisWS] begin
    # Same-file placement: declaration and call share one file.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"b.jl\")\nend\n",
        B => "function f end\nc() = f()\n",
    ))
    fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
    @test any(d -> occursin("no methods", d.message), fa.diagnostics)

    # One-file-root: no separate root/include indirection — the file is its
    # own whole tree.
    jw2 = ws_with(Dict(B => "function f end\nc() = f()\n"))
    fa2 = JuliaWorkspaces.derived_file_analysis(jw2.runtime, B, B)
    @test any(d -> occursin("no methods", d.message), fa2.diagnostics)
end

@testitem "parity: the no-methods verdict survives moving the forward declaration to a sibling file" setup=[FileAnalysisWS] begin
    root_src = "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
    function flags_at(a::String, b::String, callfile)
        jw = ws_with(Dict(ROOT => root_src, A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, callfile)
        return [d.message for d in fa.diagnostics]
    end

    # Declaration in a.jl, call in b.jl.
    @test any(m -> occursin("no methods", m), flags_at("function f end\n", "c() = f()\n", B))
    # Declaration MOVED to b.jl, call moved to a.jl — same verdict.
    @test any(m -> occursin("no methods", m), flags_at("c() = f()\n", "function f end\n", A))
end

@testitem "parity: an unknown-shaped name beside a forward decl is not definitely empty" setup=[FileAnalysisWS] begin
    # `oldname` gets both a forward declaration (`function oldname end`, kind
    # :function with no arity) and a macro-declared row for the same key
    # (`@deprecate` mints an :macro_declared item, which the index marks
    # `has_unknown_shapes` regardless of confirmation — see the analogous
    # "signature index: a macro-declared name still marks has_unknown_shapes"
    # test). The union is incomplete, so the definite-emptiness verdict must
    # decline even though the signature set is literally empty.
    #
    # A full diagnostic fixture cannot distinguish this from the pre-fix
    # behavior: with no arity and no store, the count phase never runs either
    # way, so the call is silent both before and after this feature — pinning
    # the index answer and the gate's own predicate is the only way to assert
    # the `has_unknown_shapes` branch actually does the excluding.
    jw = ws_with(Dict(
        ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        A => "@deprecate oldname newname\n",
        B => "function oldname end\n",
    ))
    nm = JuliaWorkspaces.derived_method_signatures(jw.runtime, ROOT, ["MainPkg"], "oldname")
    @test isempty(nm.signatures)
    @test nm.has_forward_decl
    @test nm.has_unknown_shapes
    # The gate's own predicate (checks.jl): definite emptiness requires
    # `!has_unknown_shapes`, so this NameMethods must not satisfy it.
    @test !(isempty(nm.signatures) && nm.has_forward_decl && !nm.has_unknown_shapes)
end

@testitem "parity/ctor: datatype callees rule out on keywords and alignment only" setup=[FileAnalysisWS] begin
    function callflags(a::String, b::String)
        jw = ws_with(Dict(
            ROOT => "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            A => a, B => b))
        fa = JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)
        return filter(d -> occursin("method call error", d.message) ||
                           occursin("No method matching", d.message), fa.diagnostics)
    end
    # keyword passed to a plain struct's field constructor: no method takes keywords
    @test length(callflags("struct S x end\n", "mk() = S(x = 1)\n")) == 1
    # field types are NOT an opinion: a 'wrong' positional type stays silent
    @test isempty(callflags("struct S x::Int end\n", "mk() = S(\"str\")\n"))
    # inner constructor with a keyword: presence accepted
    @test isempty(callflags("struct T\n    x\n    T(x::Int; scale=1) = new(x*scale)\nend\n",
                            "mk() = T(1; scale=2)\n"))
    # wrong keyword name on an inner constructor: name-checked, rules out
    @test length(callflags("struct T\n    x\n    T(x::Int; scale=1) = new(x*scale)\nend\n",
                           "mk() = T(1; nope=2)\n")) == 1
    # @kwdef keyword form stays silent (shape unknown behind the macro)
    @test isempty(callflags("Base.@kwdef struct FS\n    inc::Int = 1\nend\n",
                            "mk() = FS(; inc=3)\n"))
    # two inner constructors whose UNIONED arity (alignment OR'd across both)
    # would accept 1 positional + `scale`, but neither ctor alone does — the
    # per-signature match (not the merged-arity count phase) is what catches it.
    @test length(callflags("struct T\n    x\n    T(x::Int) = new(x)\n    T(; scale=1) = new(0)\nend\n",
                           "mk() = T(1; scale=2)\n")) == 1
    # empty-body struct: struct_nargs answers (0, typemax(Int)) — fully
    # permissive — for zero fields, so the count phase never rules anything
    # out here. Only the type phase's zero-slot default record can: this is
    # the one arm that isolates the exclusion-lift itself (verified red
    # against the pre-lift gate — see the report).
    @test length(callflags("struct S end\n", "mk() = S(1)\n")) == 1
    # a body member with no readable field name (`@weird a, b`) makes the
    # default record's slot count (from `field_names`) disagree with
    # `struct_nargs`' own member count — the mismatch must decline to no
    # record (shape unknown) rather than false-flag the correctly-shaped call.
    @test length(callflags("struct W\n    @weird a, b\n    c::Int\nend\n", "mk() = W(1)\n")) == 1
    @test isempty(callflags("struct W\n    @weird a, b\n    c::Int\nend\n", "mk() = W(1, 2)\n"))
end

@testitem "record-arm: TypeRef resolution never contradicts the store verdicts" setup=[FileAnalysisWS] begin
    # Same name table as "the rule-out check never contradicts real subtyping"
    # (test/staticlint/test_staticlint.jl); the two tables must not drift —
    # same floors, same pairs.
    concrete = ["Int8","Int64","UInt8","Float32","Float64","Bool","Char","String",
                "Symbol","Nothing","Dict","Set","Array","UnitRange","ArgumentError",
                "BoundsError","Rational","Complex"]
    bounds = ["Real","Signed","Unsigned","Integer","AbstractFloat","Number",
              "AbstractString","AbstractChar","AbstractDict","AbstractSet",
              "AbstractArray","DenseArray","AbstractRange","Exception","Function","Tuple"]
    using JuliaWorkspaces: TypeRef
    jw = ws_with(Dict(ROOT => "module MainPkg\nend\n"))
    resolve = JuliaWorkspaces._tree_type_resolver(jw.runtime, ROOT)
    # project-less root: the resolver and this lookup share the stdlib-only env
    env = JuliaWorkspaces.derived_stdlib_only_env(jw.runtime)
    syms = SL.getsymbols(env)
    function lookup(n)   # the store-side operand, as the store pin builds it
        for m in (:Core, :Base)
            haskey(syms, m) && haskey(syms[m], Symbol(n)) && return syms[m][Symbol(n)]
        end
        return nothing
    end
    function tally()
        mismatches = String[]
        resolved = 0
        for c in concrete, b in bounds
            rc = resolve(TypeRef([c]), ["MainPkg"]); rb = resolve(TypeRef([b]), ["MainPkg"])
            sc = lookup(c); sb = lookup(b)
            (rc === nothing || rb === nothing || sc === nothing || sb === nothing) && continue
            resolved += 1
            SL._has_type_intersection(rc, rb, syms, Dict{UInt64,SL.Meta}()) ===
                SL._has_type_intersection(sc, sb, syms, Dict{UInt64,SL.Meta}()) ||
                push!(mismatches, "$c vs $b")
        end
        return resolved, mismatches
    end
    resolved, mismatches = tally()
    @test isempty(mismatches)
    @test resolved >= 250    # floor against silent vacuity (18×16 = 288 pairs)
end
