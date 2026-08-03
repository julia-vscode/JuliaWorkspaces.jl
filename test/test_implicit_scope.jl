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
    env = derived_stdlib_only_env(rt)
    intval, _ = _implicit_member(rt, root, foo, "Int")
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
