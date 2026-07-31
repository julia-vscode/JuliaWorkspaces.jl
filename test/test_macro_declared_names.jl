@testsnippet MacroDeclWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: _macro_owner_confirmed, derived_macro_declared_names_index,
        derived_module_macro_declared_names, derived_module_visible_names
    using JuliaWorkspaces.URIs2: URI

    # A workspace with `root_src` as the root file, plus any extra files, plus
    # (optionally) a sibling workspace package that declares `@declare_input`.
    function macro_ws(root_src::String; root_uri=URI("file:///t/src/T.jl"),
                      extra=Dict{URI,String}(), with_salsa_package::Bool=false)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(root_uri, SourceText(root_src, "julia")))
        for (u, s) in extra
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        if with_salsa_package
            add_file!(jw, TextFile(URI("file:///ws/Salsa/Project.toml"), SourceText("""
            name = "Salsa"
            uuid = "1fbf2c77-44e2-4d5d-8131-0fa618a5c278"
            version = "2.5.1"
            """, "toml")))
            add_file!(jw, TextFile(URI("file:///ws/Salsa/src/Salsa.jl"), SourceText("""
            module Salsa
            macro declare_input(ex) end
            export @declare_input
            end
            """, "julia")))
        end
        return jw, root_uri
    end
end

@testitem "macro-declared: owner confirmation via a workspace package" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation fails without the import" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a same-named submodule does not confirm" setup=[MacroDeclWS] begin
    # `Salsa` here is a submodule of this very root, so the import target is
    # `:tree`, not the owner package.
    jw, root = macro_ws("""
    module T
    module Salsa
    macro declare_input(ex) end
    end
    using .Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a local macro shadows the bare spelling only" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    macro declare_input(ex) end
    @declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    # Bare: the local macro wins, so this is confirmed FOREIGN.
    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
    # Qualified: a local macro cannot shadow `Salsa.@declare_input`.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a colon list that doesn't name the module binds no qualifier" setup=[MacroDeclWS] begin
    # `using Salsa: bar` binds only `bar` in real Julia, never `Salsa` itself
    # — so a qualified `Salsa.@declare_input` can't be confirmed through it.
    jw, root = macro_ws("""
    module T
    using Salsa: bar
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a colon list naming the module itself binds it" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa: Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: an aliased whole-module import binds the alias, not the original name" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    import Salsa as S
    S.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["S"], name="@declare_input"))
    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation via the environment store" setup=[MacroDeclWS] begin
    # Base is always in the baked stdlib stores, so this exercises the store
    # branch with no workspace package involved.
    jw, root = macro_ws("""
    module T
    @deprecate oldf newf
    end
    """)

    # `Base` needs no import to be in scope, so the spelling check accepts a
    # bare or `Base.`-qualified use without an import record.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@deprecate"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Base"], name="@deprecate"))
end

@testitem "macro-declared: the index records confirmed names only" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    idx = derived_macro_declared_names_index(jw.runtime, root)
    @test sort([n for ((p, n), _) in idx if p == ["T"]]) ==
        ["delete_foo!", "foo", "set_foo!"]

    names = derived_module_macro_declared_names(jw.runtime, root, ["T"])
    @test sort(collect(keys(names))) == ["delete_foo!", "foo", "set_foo!"]
    # All three point at the one declaring statement.
    @test length(unique(values(names))) == 1
    @test names["foo"].file == root

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T", "Nope"]))
end

@testitem "macro-declared: an unconfirmed macrocall records nothing" setup=[MacroDeclWS] begin
    # No Salsa package in the workspace and no project, so the owner cannot be
    # confirmed by either branch.
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """)

    @test isempty(derived_macro_declared_names_index(jw.runtime, root))
    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
end

@testitem "macro-declared: a duplicate name resolves last-in-splice-order" setup=[MacroDeclWS] begin
    inc = URI("file:///t/src/inc.jl")
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    include("inc.jl")
    end
    """; extra=Dict(inc => """
    Salsa.@declare_input foo(rt)::Int
    """), with_salsa_package=true)

    names = derived_module_macro_declared_names(jw.runtime, root, ["T"])
    # The included file is spliced after the root's own statement, so its
    # declaration wins — the same rule `_declare!` applies.
    @test names["set_foo!"].file == inc
end

@testitem "macro-declared: names land in the module that declares them" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    module Inner
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    end
    end
    """; with_salsa_package=true)

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
    @test haskey(derived_module_macro_declared_names(jw.runtime, root, ["T", "Inner"]), "set_foo!")
end

@testitem "macro-declared: confirmed names are visible in their module" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].origin === :declared
    @test vis["set_foo!"].origin_module == ["T"]
    @test vis["set_foo!"].item !== nothing
end

@testitem "macro-declared: a real declaration beats a macro-declared name" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    set_foo!(rt, x, v) = nothing
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    # The hand-written method wins: it is real text.
    @test vis["set_foo!"].kind === :function
end

@testitem "macro-declared: a macro-declared name beats a wildcard bring-in" setup=[MacroDeclWS] begin
    prov = URI("file:///ws/Prov/src/Prov.jl")
    jw, root = macro_ws("""
    module T
    using Salsa
    using .Sub
    Salsa.@declare_input foo(rt, x::Int)::V
    module Sub
    set_foo!() = 1
    export set_foo!
    end
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    # Declaration tier (3) beats a wildcard `using` bring-in (tier 1).
    @test vis["set_foo!"].kind === :macro_declared
end

@testitem "macro-declared: the union is a no-op without a modelled macrocall" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    f(x) = x
    end
    """; with_salsa_package=true)

    @test isempty(derived_module_macro_declared_names(jw.runtime, root, ["T"]))
    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "f")
    @test !any(vn -> vn.kind === :macro_declared, values(vis))
end

@testitem "macro-declared: an exported name comes in through `using .Sub`" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    module Sub
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    export set_foo!
    end
    using .Sub
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].item !== nothing
end

@testitem "macro-declared: a colon-list member keeps its kind and item" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    module Sub
    using Salsa
    Salsa.@declare_input foo(rt)::Int
    end
    using .Sub: set_foo!
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    # Without the fix this binds as `:unknown` with no item, so hover and
    # go-to-definition go dead even though the name resolves.
    @test vis["set_foo!"].kind === :macro_declared
    @test vis["set_foo!"].item !== nothing
end

@testitem "macro-declared: uses of the generated names are not missing refs" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        foo(rt, 1)
        set_foo!(rt, 1, 2)
        delete_foo!(rt, 1)
    end
    end
    """; with_salsa_package=true)

    # Drive the per-file pass, not the whole-closure query: the
    # macro-declared-names visibility union only ever feeds a `module_context`
    # pass, and that per-file pass is also what production diagnostics
    # actually use (`derived_new_static_lint_diagnostics` →
    # `derived_file_analysis`). The whole-closure query
    # (`derived_static_lint_meta_for_root`) never consults it.
    fa = derived_file_analysis(jw.runtime, root, root)
    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, Dict{String,Any}(), fa.meta, :all)
    flagged = [CSTParser.valof(x) for (_, x) in hints]

    @test "set_foo!" ∉ flagged
    @test "delete_foo!" ∉ flagged
    @test "foo" ∉ flagged
    # And nothing new: `Salsa` itself is a workspace package here, so it resolves.
    @test isempty(flagged)
end

@testitem "macro-declared: the declaration site is not reported as a bad call" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, derived_file_analysis,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    fa = derived_file_analysis(jw.runtime, root, root)
    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, Dict{String,Any}(), fa.meta, :all)

    # `foo` at the declaration now RESOLVES (it did not before), and it is not a
    # definition signature, so it reads as a call. It must not be flagged.
    errs = [StaticLint.errorof(x, fa.meta) for (_, x) in hints]
    @test !any(e -> e === StaticLint.IncorrectCallArgs, errs)
end

@testitem "macro-declared: an unconfirmed macro still flags its names" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    # A LOCAL `@declare_input` (bare spelling) is confirmed foreign, so the
    # generated names do not exist and their uses must be reported.
    jw, root = macro_ws("""
    module T
    macro declare_input(ex) end
    @declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """)

    fa = derived_file_analysis(jw.runtime, root, root)
    cst = derived_julia_legacy_syntax_tree(jw.runtime, root)
    env = derived_stdlib_only_env(jw.runtime)
    hints = StaticLint.collect_hints(cst, env, Dict{String,Any}(), fa.meta, :all)
    @test "set_foo!" in [CSTParser.valof(x) for (_, x) in hints]
end
