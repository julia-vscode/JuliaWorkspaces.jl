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
