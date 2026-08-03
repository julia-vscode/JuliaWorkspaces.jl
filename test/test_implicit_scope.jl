@testsnippet ImplicitScopeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TextFile, SourceText, add_file!, derived_file_analysis,
        derived_julia_legacy_syntax_tree, derived_stdlib_only_env, _implicit_member
    using JuliaWorkspaces.URIs2: URI
    const SL = JuliaWorkspaces.StaticLint
    const CP = JuliaWorkspaces.CSTParser
    const SS = JuliaWorkspaces.SymbolServer

    # A workspace of julia files, keyed by URI. The first pair is the root.
    function ws_files(pairs...)
        jw = JuliaWorkspace()
        for (u, s) in pairs
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    # The ref of every occurrence of `name` in `file`, analysed under `root`.
    function refs_of(jw, root::URI, file::URI, name::String)
        fa = derived_file_analysis(jw.runtime, root, file)
        cst = derived_julia_legacy_syntax_tree(jw.runtime, file)
        out = Any[]
        JuliaWorkspaces._walk_exprs(cst) do x
            CP.is_id_or_macroname(x) && CP.str_value(x) == name || return
            push!(out, SL.hasref(x, fa.meta) ? SL.refof(x, fa.meta) : nothing)
        end
        return out
    end

    diagnostics_of(jw, root::URI, file::URI) =
        [d.message for d in derived_file_analysis(jw.runtime, root, file).diagnostics]
end

@testitem "implicit scope: _implicit_member answers for Base/Core exports only" setup=[ImplicitScopeWS] begin
    root = URI("file:///is/src/T.jl")
    jw = ws_files(root => """
    module T
    module Foo
    f(x) = x
    end
    baremodule Bare
    end
    end
    """)
    rt = jw.runtime
    foo = ["T", "Foo"]

    # A function Base exports: the store value itself, the same shape a bare
    # `println` resolves to, paired with the module that provided it.
    val, prov = _implicit_member(rt, root, foo, "println")
    @test val isa SS.FunctionStore
    @test prov == ["Base"]

    # A module Base exports: NOT the ModuleStore — per-file meta must stay plain
    # data — but the `:external_module` TreeRef stand-in, which is what lets the
    # getfield chain continue past it.
    tr, tprov = _implicit_member(rt, root, foo, "Threads")
    @test tr isa SL.TreeRef
    @test tr.kind === :external_module
    @test tr.name == "Threads"
    @test tr.origin_module == ["Base"]
    @test tr.item === nothing
    @test tprov == ["Base"]

    # A type: `Base.vals[:Int]` is the CONSTRUCTOR (a FunctionStore) while
    # `Core.vals[:Int]` is the DataTypeStore. Assert what consumers actually ask —
    # `get_eventual_datatype`, which follows `.extends` — rather than the store type
    # Base happens to hold, so this passes whichever module answers first.
    # `Int` is exported by BOTH Base and Core, which makes it the order witness:
    # if the loop tried Core first (or the tuple were swapped), `intval` would
    # come back as Core's DataTypeStore instead, and `iprov` as ["Core"]. Do not
    # simplify this back to an order-blind form.
    env = derived_stdlib_only_env(rt)
    intval, iprov = _implicit_member(rt, root, foo, "Int")
    @test iprov == ["Base"]
    @test intval isa SS.FunctionStore
    @test SL.get_eventual_datatype(intval, env) isa SS.DataTypeStore
    @test SL.resolves_to_datatype(intval, env)

    # `public`, not exported: `using Base` does not bring it in, so neither does this.
    @test _implicit_member(rt, root, foo, "Filesystem") === nothing

    # Not a name either module provides.
    @test _implicit_member(rt, root, foo, "definitely_not_a_base_name") === nothing

    # A baremodule has no implicit `using`, so it gets nothing at all.
    bare = ["T", "Bare"]
    @test _implicit_member(rt, root, bare, "println") === nothing
    @test _implicit_member(rt, root, bare, "Threads") === nothing
    @test _implicit_member(rt, root, bare, "Int") === nothing
end

@testitem "implicit scope: cross-file member access matches single-file, cell for cell" setup=[ImplicitScopeWS] begin
    # The parity matrix. `Foo` is declared in a sibling file, so every lookup goes
    # through the module tree; single-file mode already resolves all of these, and
    # this asserts the tree path now agrees.
    root = URI("file:///is2/src/T.jl")
    a = URI("file:///is2/src/a.jl")
    b = URI("file:///is2/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => """
        g1() = Foo.f(1)
        g2() = Foo.println(2)
        g3() = Foo.Threads.nthreads()
        g4() = Foo.Filesystem
        """,
    )

    # The module's own member: unchanged.
    @test only(refs_of(jw, root, b, "f")) isa SL.TreeRef

    # A Base export reached as a member: the store value, as in single-file mode.
    @test only(refs_of(jw, root, b, "println")) isa SS.FunctionStore

    # A Base-exported MODULE, and the chain continuing past it — the second hop is
    # what proves the stand-in is resolvable and not just present.
    tr = only(refs_of(jw, root, b, "Threads"))
    @test tr isa SL.TreeRef
    @test tr.kind === :external_module
    @test tr.origin_module == ["Base"]
    @test only(refs_of(jw, root, b, "nthreads")) isa SS.FunctionStore

    # `public`, not exported: still unresolved, and this is the assertion that fails
    # if the implementation reads `publicnames` or the full `vals`.
    @test only(refs_of(jw, root, b, "Filesystem")) === nothing

    # Nothing new is flagged.
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a module's own declaration shadows the implicit scope" setup=[ImplicitScopeWS] begin
    # `Foo` declares its own `println`, so `Foo.println` must be Foo's, not Base's.
    # The fallback is consulted only after the tree lookup misses.
    root = URI("file:///is3/src/T.jl")
    a = URI("file:///is3/src/a.jl")
    b = URI("file:///is3/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nprintln(x) = x\nend\n",
        b => "g() = Foo.println(2)\n",
    )
    r = only(refs_of(jw, root, b, "println"))
    @test r isa SL.TreeRef
    @test r.kind !== :external_module
    @test r.item !== nothing && r.item.file == a
end

@testitem "implicit scope: a baremodule member stays unresolved" setup=[ImplicitScopeWS] begin
    root = URI("file:///is4/src/T.jl")
    a = URI("file:///is4/src/a.jl")
    b = URI("file:///is4/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "baremodule Bare\nf(x) = x\nend\n",
        b => "g1() = Bare.f(1)\ng2() = Bare.println(2)\ng3() = Bare.Threads\n",
    )
    # Its own member still resolves...
    @test only(refs_of(jw, root, b, "f")) isa SL.TreeRef
    # ...but it has no implicit `using`, so these do not.
    @test only(refs_of(jw, root, b, "println")) === nothing
    @test only(refs_of(jw, root, b, "Threads")) === nothing
end

@testitem "implicit scope: a colon-list member can come from the implicit scope" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    root = URI("file:///is5/src/T.jl")
    a = URI("file:///is5/src/a.jl")
    b = URI("file:///is5/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => "module Consumer\nusing ..Foo: println, f\ng() = println(f(1))\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer"])

    # `f` is Foo's own declaration: unchanged.
    @test haskey(vis, "f")
    @test vis["f"].origin_module == ["T", "Foo"]

    # `println` came from Foo's implicit `using Base`, so it binds as an external
    # symbol whose origin module is the PROVIDER — that is the path
    # resolve_treeref_store walks to find it in the env.
    @test haskey(vis, "println")
    @test vis["println"].kind === :external_symbol
    @test vis["println"].origin_module == ["Base"]
    @test vis["println"].item === nothing

    # ...and both occurrences resolve — the name in the colon list and the call site
    # in `g` — rather than being reported as missing references.
    prefs = refs_of(jw, root, b, "println")
    @test length(prefs) == 2
    @test all(r -> r !== nothing, prefs)
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a colon-list member that is public-not-exported stays unknown" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    root = URI("file:///is6/src/T.jl")
    a = URI("file:///is6/src/a.jl")
    b = URI("file:///is6/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => "module Consumer\nusing ..Foo: Filesystem\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer"])

    # Julia binds the name lexically even when the import is wrong, so the entry
    # exists — but it must stay `:unknown`, NOT resolve to Base.Filesystem.
    @test haskey(vis, "Filesystem")
    @test vis["Filesystem"].kind === :unknown
end
