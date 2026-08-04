@testsnippet ImplicitScopeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TextFile, SourceText, add_file!, derived_file_analysis,
        derived_julia_legacy_syntax_tree, derived_stdlib_only_env, _implicit_member
    using JuliaWorkspaces.URIs2: URI
    const SL = JuliaWorkspaces.StaticLint
    const CP = JuliaWorkspaces.CSTParser
    const SS = JuliaWorkspaces.SymbolServer

    # A workspace of files, keyed by URI. The first pair is the root. Language is
    # picked from the extension so a `.toml` isn't fed to the julia-file nodes as
    # if it were source. Project discovery itself is path-based and does not
    # depend on the language tag.
    function ws_files(pairs...)
        jw = JuliaWorkspace()
        for (u, s) in pairs
            lang = endswith(string(u), ".toml") ? "toml" : "julia"
            add_file!(jw, TextFile(u, SourceText(s, lang)))
        end
        return jw
    end

    # A minimal Project.toml body naming a workspace package.
    project_toml(name, uuid) = """
    name = "$name"
    uuid = "$uuid"
    version = "0.1.0"
    """

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

    # A type. Assert what consumers actually ask — `get_eventual_datatype`, which
    # follows `.extends` — and NOT the store type the provider happens to hold: on a
    # 64-bit build `Base.vals[:Int]` is the constructor `FunctionStore` while
    # `Core.vals[:Int]` is the `DataTypeStore`, and both answer the same question.
    #
    # `Int` is still the order witness, but branched on the env instead of hardcoded:
    # where BOTH modules export it, the FIRST in `IMPLICIT_SCOPE_MODULES` must win, so
    # reversing that tuple fails here. Where Base's store has no `Int` the lookup
    # accepts — a 32-bit build, `Int === Int32` — Core is the only provider and the
    # order says nothing. Do not collapse this to an order-blind form.
    env = derived_stdlib_only_env(rt)
    syms = SL.getsymbols(env)
    # Whether Base provides `Int` AT ALL is the platform-dependent part, so it is
    # asked rather than assumed; that the winner is the earlier module is not.
    base_provides = SL.isexportedby(:Int, syms[:Base]) &&
        SL.maybe_lookup(syms[:Base].vals[:Int], env) !== nothing
    intval, iprov = _implicit_member(rt, root, foo, "Int")
    @test iprov == (base_provides ? ["Base"] : ["Core"])
    @test SL.get_eventual_datatype(intval, env) isa SS.DataTypeStore
    @test SL.resolves_to_datatype(intval, env)

    # The fall-through to a LATER module in the list, which nothing else here pins —
    # and which is what a build whose Base has no `Int` takes for real (`:Int` is
    # absent from `names(Base)` before 1.12, and `exportednames` is seeded from that).
    # The witness is derived, not named, so it survives the two export lists drifting
    # between versions; on 1.12 it is `ccall`, and on 1.11 `Int` is itself one.
    core_only = [n for n in syms[:Core].exportednames
                 if SL.isexportedby(n, syms[:Core]) && !SL.isexportedby(n, syms[:Base])]
    if !isempty(core_only)
        cm = _implicit_member(rt, root, foo, String(first(core_only)))
        @test cm !== nothing && cm[2] == ["Core"]
    end

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

@testitem "implicit scope: a colon-list member that is a MODULE carries a use-site chain" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    # `using ..Foo: Threads` picks a module-valued member out of Foo's implicit
    # scope; `Threads.nthreads()` then has to continue THROUGH the bound name. The
    # second hop is the assertion — the first only proves the name got bound to
    # something. What carries it is `qualified_module_target`'s `:external_symbol`
    # arm re-deriving `["Base"] + "Threads"` from the ref alone, NOT the
    # module-target ledger: this passes with `_implicit_member_lookup`'s synthesized
    # `ImportTarget` deleted. The ledger has its own test below.
    root = URI("file:///is9/src/T.jl")
    a = URI("file:///is9/src/a.jl")
    b = URI("file:///is9/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => "module Consumer\nusing ..Foo: Threads\ng() = Threads.nthreads()\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer"])

    # Bound like any other implicit-scope member: origin is the PROVIDER, and no
    # workspace item defines it.
    @test haskey(vis, "Threads")
    @test vis["Threads"].kind === :external_symbol
    @test vis["Threads"].origin_module == ["Base"]
    @test vis["Threads"].item === nothing

    # The colon-list name and the use site both bind...
    trefs = refs_of(jw, root, b, "Threads")
    @test length(trefs) == 2
    @test all(r -> r !== nothing, trefs)

    # ...and the chain continues THROUGH the binding into the env module.
    @test only(refs_of(jw, root, b, "nthreads")) isa SS.FunctionStore
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a module-valued colon-list member enters the module-target ledger" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    # The one thing `_implicit_member_lookup`'s synthesized `ImportTarget` is FOR.
    # It goes into pass 1's module-target ledger, whose only consumer is
    # `_reattempt_unresolved`: `Inner`'s `using ..Threads` names no tree module, so
    # it classifies `:unresolved` and the re-attempt looks `Threads` up in the
    # anchor's ledger and continues into `["Base", "Threads"]` from there. Delete the
    # synthesis and `nthreads` has no origin to be resolved against.
    root = URI("file:///isa/src/T.jl")
    a = URI("file:///isa/src/a.jl")
    b = URI("file:///isa/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => "module Foo\nf(x) = x\nend\n",
        b => """
        module Consumer
        using ..Foo: Threads
        module Inner
        using ..Threads: nthreads
        g() = nthreads()
        end
        end
        """,
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "Consumer", "Inner"])

    @test haskey(vis, "nthreads")
    @test vis["nthreads"].kind === :external_symbol
    # The PROVIDER is the extended path, which is the ledger entry's whole point:
    # without it the re-attempt finds no target and this name never resolves.
    @test vis["nthreads"].origin_module == ["Base", "Threads"]
    @test vis["nthreads"].item === nothing

    # The per-file pass does NOT keep up with the visibility layer here, and this
    # asserts that split rather than hiding it: `resolve_import_block` chains raw
    # `_get_field` calls, which have no arm for a `TreeRef` mid-path, so the import
    # statement is reported unresolved. Pre-existing to this fallback (the same
    # dead-end as `import Foo.Threads.nthreads`) and benign — the message promises
    # exactly that nothing through the statement is checked.
    @test diagnostics_of(jw, root, b) ==
        ["Failed to resolve `nthreads`. Anything imported through this statement is assumed to exist and will not be checked."]
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

@testitem "implicit scope: a workspace-package colon-list member can come from the implicit scope" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    # Prov and Consumer are separate workspace packages (own Project.toml, own
    # root), so `Consumer`'s `using Prov: println` resolves through the
    # `:workspace_package` branch of `_member_lookup`, not `:tree`.
    prov_toml = URI("file:///wsp1/Prov/Project.toml")
    prov_src = URI("file:///wsp1/Prov/src/Prov.jl")
    cons_toml = URI("file:///wsp1/Consumer/Project.toml")
    cons_src = URI("file:///wsp1/Consumer/src/Consumer.jl")

    jw = ws_files(
        prov_toml => project_toml("Prov", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee2001"),
        prov_src => "module Prov\nend\n",
        cons_toml => project_toml("Consumer", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee2002"),
        cons_src => "module Consumer\nusing Prov: println\ng() = println()\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, cons_src, ["Consumer"])

    @test haskey(vis, "println")
    @test vis["println"].kind === :external_symbol
    @test vis["println"].origin_module == ["Base"]
    @test vis["println"].item === nothing

    # The case above alone can't catch a `root`/`entry` mix-up: neither package
    # has a Manifest.toml, so both resolve to the SAME shared stdlib-only env, and
    # Consumer's own tree has no "Prov" node either way — a wrong `root` and the
    # right `entry` land on the same `println`. Force a real divergence with a
    # BARE provider: the bareness gate (`derived_module_is_bare`) is keyed on
    # whichever root is passed in. The right `entry` finds BareProv's own bare
    # declaration and honours the gate (`:unknown`); the wrong `root`
    # (Consumer2's own tree, which has no "BareProv" node) defaults to "not
    # bare" and would wrongly let `println` through as `:external_symbol`.
    bare_toml = URI("file:///wsp2/BareProv/Project.toml")
    bare_src = URI("file:///wsp2/BareProv/src/BareProv.jl")
    cons2_toml = URI("file:///wsp2/Consumer2/Project.toml")
    cons2_src = URI("file:///wsp2/Consumer2/src/Consumer2.jl")

    ok_toml = URI("file:///wsp2/OkProv/Project.toml")
    ok_src = URI("file:///wsp2/OkProv/src/OkProv.jl")

    jw2 = ws_files(
        bare_toml => project_toml("BareProv", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee2003"),
        bare_src => "baremodule BareProv\nend\n",
        ok_toml => project_toml("OkProv", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee2005"),
        ok_src => "module OkProv\nend\n",
        cons2_toml => project_toml("Consumer2", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee2004"),
        cons2_src => "module Consumer2\nusing BareProv: println\nusing OkProv: max\nend\n",
    )
    vis2 = derived_module_visible_names(jw2.runtime, cons2_src, ["Consumer2"])

    @test haskey(vis2, "println")
    @test vis2["println"].kind === :unknown

    # The positive control for THIS workspace: `:unknown` above has to mean "the
    # provider is bare", not "no workspace package was discovered here at all" —
    # which would give the same answer. A non-bare sibling package in the same
    # workspace does resolve its implicit-scope member.
    @test haskey(vis2, "max")
    @test vis2["max"].kind === :external_symbol
    @test vis2["max"].origin_module == ["Base"]
end

@testitem "implicit scope: a wildcard using of a WORKSPACE PACKAGE withholds only its exports" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    # The `:workspace_package` arm of the same export-list test. `Prov` wildcard-
    # `using`s the deved `Other`, so `Prov.parse` could be Other's and is withheld,
    # while `Prov.println` cannot be and stays Base's. Read off `Other`'s own
    # `derived_module_exports` — never its visible names, which would re-enter the
    # query this runs inside.
    other_toml = URI("file:///wsp3/Other/Project.toml")
    other_src = URI("file:///wsp3/Other/src/Other.jl")
    prov_toml = URI("file:///wsp3/Prov/Project.toml")
    prov_src = URI("file:///wsp3/Prov/src/Prov.jl")
    cons_toml = URI("file:///wsp3/Cons/Project.toml")
    cons_src = URI("file:///wsp3/Cons/src/Cons.jl")

    jw = ws_files(
        other_toml => project_toml("Other", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee3001"),
        other_src => "module Other\nexport parse\nparse(x) = x\nend\n",
        prov_toml => project_toml("Prov", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee3002"),
        prov_src => "module Prov\nusing Other\nend\n",
        cons_toml => project_toml("Cons", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee3003"),
        cons_src => "module Cons\nusing Prov: parse, println\nend\n",
    )
    vis = derived_module_visible_names(jw.runtime, cons_src, ["Cons"])

    @test haskey(vis, "parse")
    @test vis["parse"].kind === :unknown

    @test haskey(vis, "println")
    @test vis["println"].kind === :external_symbol
    @test vis["println"].origin_module == ["Base"]
end

@testitem "implicit scope: a member the target got from its OWN imports stays unknown" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_visible_names

    # `Outer.parse` is Inner's `parse`, brought in by Outer's own colon-list import.
    # That is an IMPORT binding, which `derived_module_names` — the miss gate at this
    # call site — does not report, so without a guard the lookup falls through to the
    # implicit scope and answers `Base.parse`, pointing hover and go-to-definition at
    # the wrong function. `:unknown` is the honest answer: following the import means
    # expanding Outer's own visible names, which cannot be done from inside the
    # visibility computation. Names in this class are common (`parse`, `merge`,
    # `count`, `keys`, `filter`, `get`, `run`).
    root = URI("file:///is7/src/T.jl")
    a = URI("file:///is7/src/a.jl")
    b = URI("file:///is7/src/b.jl")
    jw = ws_files(
        root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        a => """
        module Inner
        export parse
        parse(x) = x
        end
        module Outer
        using ..Inner: parse
        end
        module Wild
        using ..Inner
        end
        module ExtWild
        using Base.Iterators
        end
        module Unrelated
        using ..Inner: f
        end
        """,
        b => """
        module User
        using ..Outer: parse
        h() = parse("x")
        end
        module WildUser
        using ..Wild: parse, println
        end
        module ExtWildUser
        using ..ExtWild: flatten, println
        end
        module UnrelatedUser
        using ..Unrelated: println
        end
        """,
    )
    vis = derived_module_visible_names(jw.runtime, root, ["T", "User"])
    @test haskey(vis, "parse")
    @test vis["parse"].kind === :unknown
    @test vis["parse"].origin_module != ["Base"]

    # A wildcard `using` in the target withholds the names that target could
    # ACTUALLY bring in, not every name. `Wild` wildcard-`using`s `Inner`, whose
    # export list is exactly `parse`: so `Wild.parse` is withheld (it is Inner's,
    # and following it is the recursion we cannot make)...
    wvis = derived_module_visible_names(jw.runtime, root, ["T", "WildUser"])
    @test haskey(wvis, "parse")
    @test wvis["parse"].kind === :unknown

    # ...while `Wild.println` is Base's, because no export list in `Wild`'s imports
    # contains it. Declining here too is what made a provider's unrelated
    # `using SomePkg` stop resolving every Base member it has.
    @test haskey(wvis, "println")
    @test wvis["println"].kind === :external_symbol
    @test wvis["println"].origin_module == ["Base"]

    # The same split for an `:external` target, which is the shape that actually
    # occurs: `Base.Iterators` exports `flatten` and does not export `println`.
    evis = derived_module_visible_names(jw.runtime, root, ["T", "ExtWildUser"])
    @test evis["flatten"].kind === :unknown
    @test evis["println"].kind === :external_symbol
    @test evis["println"].origin_module == ["Base"]

    # ...and the guard is narrow: a target whose imports name OTHER symbols keeps
    # answering from the implicit scope.
    uvis = derived_module_visible_names(jw.runtime, root, ["T", "UnrelatedUser"])
    @test uvis["println"].kind === :external_symbol
    @test uvis["println"].origin_module == ["Base"]

    # A `Base.parse` `FunctionStore` ref would feed `check_call`, and `parse("x")`
    # matches no `Base.parse` method by type. It does not currently flag (a TreeRef
    # callee isn't `is_something_with_methods`, and one `Base.parse` method is
    # vararg-shaped anyway), so this is a guard, not the discriminating assertion:
    # nothing about the mis-resolution may become a spurious hint either.
    @test isempty(diagnostics_of(jw, root, b))
end

@testitem "implicit scope: a member of a module with a failed wildcard `using` stays unresolved" setup=[ImplicitScopeWS] begin
    using JuliaWorkspaces: derived_module_unresolved_wildcard_using

    # A wildcard `using` whose target does not resolve can bring in ANY name, and
    # the visible-names face cannot enumerate them — so it is the one case where a
    # visible-names miss does NOT mean "no import accounts for this name", and the
    # implicit scope must decline. Confidently answering `Base.parse` here would
    # also feed `check_call`, turning a call that is fine into a hint, on code
    # whose import already promised nothing through it would be checked.
    #
    # `Sib` exists so the qualified access itself is not what fails.
    function foo_ws(tag, body, use)
        root = URI("file:///is8$tag/src/T.jl")
        a = URI("file:///is8$tag/src/a.jl")
        b = URI("file:///is8$tag/src/b.jl")
        jw = ws_files(
            root => "module T\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
            a => "module Sib\nsib(x) = x\nend\nmodule Foo\n$body\nend\n",
            b => use,
        )
        return (jw, root, b)
    end

    # An `:external` target the environment doesn't have, and an `:unresolved`
    # relative one: both unenumerable, so `Foo.parse` stays ref-less and silent.
    for (tag, body) in (("a", "using NotAnIndexedPackage"), ("b", "using ..NoSuchSibling"))
        jw, root, b = foo_ws(tag, body, "g() = Foo.parse(1)\n")
        @test derived_module_unresolved_wildcard_using(jw.runtime, root, ["T", "Foo"])
        @test only(refs_of(jw, root, b, "parse")) === nothing
        @test isempty(diagnostics_of(jw, root, b))
    end

    # The narrowness control, and the reason it is `Base.Iterators` rather than a
    # package: this workspace has no Project.toml, so the env is stdlib-only —
    # `using SomeStdlib` would read as unresolved too unless the stdlib cache
    # happens to be loaded, and the control would assert nothing. A wildcard
    # `using` whose exports ARE enumerable must keep answering from Base.
    jw, root, b = foo_ws("c", "using Base.Iterators", "h() = Foo.println(2)\n")
    @test !derived_module_unresolved_wildcard_using(jw.runtime, root, ["T", "Foo"])
    @test only(refs_of(jw, root, b, "println")) isa SS.FunctionStore
    @test isempty(diagnostics_of(jw, root, b))

    # A COLON-form `using` of an unresolvable target binds only the listed names,
    # so it says nothing about any other member: the fallback still applies.
    jw, root, b = foo_ws("d", "using NotAnIndexedPackage: whatever", "h() = Foo.println(2)\n")
    @test !derived_module_unresolved_wildcard_using(jw.runtime, root, ["T", "Foo"])
    @test only(refs_of(jw, root, b, "println")) isa SS.FunctionStore
end
