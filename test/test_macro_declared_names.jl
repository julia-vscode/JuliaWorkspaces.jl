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
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis,
        derived_stdlib_only_env, derived_julia_legacy_syntax_tree

    function find_identifiers(x, value::String, hits=CSTParser.EXPR[])
        if StaticLint.headof(x) === :IDENTIFIER && CSTParser.valof(x) == value
            push!(hits, x)
        elseif x.args !== nothing
            for a in x.args
                find_identifiers(a, value, hits)
            end
        end
        return hits
    end

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

    # Two halves, because the second alone cannot fail: `:macro_declared` sits
    # outside check_call's kind gate (`func_ref.kind in (:function, :macro,
    # :struct, :mutable_struct)`), so no IncorrectCallArgs fires whether or
    # not the ref resolves at all — a pre-feature `nothing` ref also declines.
    # The first half pins the actual mechanism that keeps this site safe: the
    # declaration's own `foo` resolves to a TreeRef of kind :macro_declared.
    # If that kind were ever widened to :function, THIS assertion is what
    # would catch it before the arity check started firing.
    foo_callee = only(find_identifiers(cst, "foo"))
    ref = StaticLint.refof(foo_callee, fa.meta)
    @test ref isa StaticLint.TreeRef
    @test ref.kind === :macro_declared

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

@testitem "macro-declared: completion kind is a method, not a variable" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: _completion_kind_for_visible, CompletionKinds

    @test _completion_kind_for_visible(:macro_declared) == CompletionKinds.Method
end

@testitem "macro-declared: hover names the declaring macro and no signature" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_hover_text, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """; with_salsa_package=true)

    src = get_text_file(jw, root).content.content
    off = first(findfirst("set_foo!", src))
    h = get_hover_text(jw, root, off)
    @test h !== nothing
    @test occursin("set_foo!", h)
    @test occursin("@declare_input", h)
    # The input's own signature must not be presented as this name's signature.
    @test !occursin("foo(rt, x::Int)", h)
end

@testitem "macro-declared: go-to-definition lands on the declaring macrocall" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_definitions, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    end
    """; with_salsa_package=true)

    src = get_text_file(jw, root).content.content
    off = first(findfirst("set_foo!(rt, 1, 2)", src))
    defs = get_definitions(jw, root, off)
    @test length(defs) == 1
    @test defs[1].uri == root
    # It lands on the declaring statement `foo(rt, x::Int)::V`, which starts on
    # the same line as `Salsa.@declare_input` (1-based: module=1, using=2,
    # declare_input=3).
    @test defs[1].start.line == 3
end

@testitem "macro-declared: find-references matches on name, not just id" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: get_references, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
        set_foo!(rt, 3, 4)
        delete_foo!(rt, 1)
    end
    end
    """; with_salsa_package=true)

    src = get_text_file(jw, root).content.content
    off = first(findfirst("set_foo!(rt, 1, 2)", src))
    refs = get_references(jw, root, off)
    # All three names share one id, so an id-only join would return the
    # `delete_foo!` site too. Only the two `set_foo!` uses may come back.
    @test length(refs) == 2
end

@testitem "macro-declared: rename is refused" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: can_rename, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    g(x) = x
    end
    """; with_salsa_package=true)

    src = get_text_file(jw, root).content.content
    # A generated name: refused, because the declaration site has no such token.
    off = first(findfirst("set_foo!(rt, 1, 2)", src))
    @test can_rename(jw, root, off) === nothing

    # An ordinary declaration is still renameable.
    off_g = first(findfirst("g(x) = x", src))
    @test can_rename(jw, root, off_g) !== nothing
end

@testitem "macro-declared: the index does not read visibility" setup=[MacroDeclWS] begin
    # If `derived_macro_declared_names_index` ever consulted visibility, this
    # computation would re-enter an in-progress query. Salsa raises
    # DependencyCycleException for that — but only under debug mode, so assert
    # debug mode is on, or the failure mode becomes unbounded recursion instead
    # (see layer_visibility.jl's note on the same hazard).
    using JuliaWorkspaces: Salsa
    @test Salsa.Debug.debug_enabled()

    jw, root = macro_ws("""
    module T
    using Salsa
    using .Sub
    Salsa.@declare_input foo(rt, x::Int)::V
    module Sub
    bar() = 1
    export bar
    end
    end
    """; with_salsa_package=true)

    vis = derived_module_visible_names(jw.runtime, root, ["T"])
    @test haskey(vis, "set_foo!")
    @test haskey(vis, "bar")
end

@testitem "macro-declared: ids survive an insertion above the declarations" setup=[MacroDeclWS] begin
    using JuliaWorkspaces: derived_file_inventory

    ids_for(src) = begin
        jw, root = macro_ws(src; with_salsa_package=true)
        Dict(it.name => it.id
             for it in derived_file_inventory(jw.runtime, root).items
             if it.kind === :macro_declared)
    end

    before = ids_for("""
    module T
    using Salsa
    Salsa.@declare_input a(rt)::Int
    Salsa.@declare_input b(rt)::Int
    end
    """)
    after = ids_for("""
    module T
    using Salsa
    Salsa.@declare_input z(rt)::Int
    Salsa.@declare_input a(rt)::Int
    Salsa.@declare_input b(rt)::Int
    end
    """)

    # The id key includes the input's own name, so inserting one above the
    # others leaves theirs untouched. Every derived value carrying these
    # ItemRefs depends on this.
    for n in ("a", "set_a!", "delete_a!", "b", "set_b!", "delete_b!")
        @test before[n] == after[n]
    end
end

@testitem "macro-declared: cross-root qualified access resolves" setup=[MacroDeclWS] begin
    # `Pkg.set_foo!` from a consumer root — the shape the language server itself
    # uses, and the one that goes through `qualified_module_target` →
    # `_get_field(::TreeModuleContext)` → the ID-FREE visibility projection.
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis

    consumer = URI("file:///ws/App/src/App.jl")
    jw, _ = macro_ws("""
    module Prov
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    export set_foo!
    end
    """; root_uri=URI("file:///ws/Prov/src/Prov.jl"), with_salsa_package=true)
    add_file!(jw, TextFile(URI("file:///ws/Prov/Project.toml"), SourceText("""
    name = "Prov"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0009"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///ws/App/Project.toml"), SourceText("""
    name = "App"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee000a"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(consumer, SourceText("""
    module App
    using Prov
    f(rt) = Prov.set_foo!(rt, 1, 2)
    end
    """, "julia")))

    fa = derived_file_analysis(jw.runtime, consumer, consumer)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, consumer)
    ids = CSTParser.EXPR[]
    walk(x) = (CSTParser.headof(x) === :IDENTIFIER && push!(ids, x);
               x.args === nothing || foreach(walk, x.args))
    walk(cst)
    target = only(filter(i -> CSTParser.valof(i) == "set_foo!", ids))
    @test StaticLint.hasref(target, fa.meta)
end

@testitem "macro-declared: cross-root wildcard `using Pkg` brings the names in" setup=[MacroDeclWS] begin
    # A BARE `set_foo!` in a consumer package, brought in by a wildcard
    # `using Prov`. This reaches the names by a different route than the
    # sibling-module case: `_target_bring_ins`' `:workspace_package` arm has no
    # explicit macro-declared fallback of its own — it takes whatever
    # `_cross_root_visible_names` reports for the provider, which includes the
    # union because that goes through the provider's FULL visible names. Nothing
    # else pins that, so a future change to either half could break this while
    # every `:tree`-arm test still passed.
    using JuliaWorkspaces: StaticLint, CSTParser, derived_file_analysis,
        derived_module_visible_names

    consumer = URI("file:///ws/App/src/App.jl")
    function two_roots(prov_src)
        jw, _ = macro_ws(prov_src; root_uri=URI("file:///ws/Prov/src/Prov.jl"),
                         with_salsa_package=true)
        add_file!(jw, TextFile(URI("file:///ws/Prov/Project.toml"), SourceText("""
        name = "Prov"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0009"
        version = "0.1.0"
        """, "toml")))
        add_file!(jw, TextFile(URI("file:///ws/App/Project.toml"), SourceText("""
        name = "App"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee000a"
        version = "0.1.0"
        """, "toml")))
        add_file!(jw, TextFile(consumer, SourceText("""
        module App
        using Prov
        f(rt) = set_foo!(rt, 1, 2)
        end
        """, "julia")))
        return jw
    end

    exported = """
    module Prov
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    export set_foo!
    end
    """
    jw = two_roots(exported)

    # The visibility entry carries the cross-root origin, not the sibling one, and
    # keeps the provider's ItemRef — which is what makes go-to-definition land in
    # Prov rather than nowhere.
    vn = derived_module_visible_names(jw.runtime, consumer, ["App"])["set_foo!"]
    @test vn.kind === :macro_declared
    @test vn.origin === :using_workspace_package
    @test vn.origin_module == ["Prov"]
    @test vn.item !== nothing
    @test vn.item.file == URI("file:///ws/Prov/src/Prov.jl")

    # ...and the bare use site resolves to it, with no missing-reference hint.
    fa = derived_file_analysis(jw.runtime, consumer, consumer)
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(jw.runtime, consumer)
    ids = CSTParser.EXPR[]
    walk(x) = (CSTParser.headof(x) === :IDENTIFIER && push!(ids, x);
               x.args === nothing || foreach(walk, x.args))
    walk(cst)
    target = only(filter(i -> CSTParser.valof(i) == "set_foo!", ids))
    r = StaticLint.refof(target, fa.meta)
    @test r isa StaticLint.TreeRef
    @test r.kind === :macro_declared
    @test r.item !== nothing && r.item.file == URI("file:///ws/Prov/src/Prov.jl")
    @test isempty(fa.diagnostics)

    # The export gate is what admits it: unexported, a wildcard brings nothing,
    # even though the name is still visible inside Prov itself. Without this the
    # assertions above would pass on a bring-in that ignored exports entirely.
    unexported = replace(exported, "export set_foo!\n" => "")
    jw2 = two_roots(unexported)
    @test !haskey(derived_module_visible_names(jw2.runtime, consumer, ["App"]), "set_foo!")
    @test haskey(derived_module_visible_names(jw2.runtime, URI("file:///ws/Prov/src/Prov.jl"), ["Prov"]), "set_foo!")
end

@testitem "macro-declared: origin :declared consumers tolerate the missing declared entry" setup=[MacroDeclWS] begin
    # A macro-declared name is visible with `origin = :declared` even though it
    # has no matching entry in `derived_module_declared` — that dict only ever
    # holds real bindings (bindings.jl-shaped declarations), never names a
    # macro invents. That's deliberate (see layer_visibility.jl:817), and the
    # two origin-filtering consumers below tolerate it: neither indexes
    # `derived_module_declared` on the strength of `origin`, so neither trips
    # over the missing entry. (`derived_module_visible_names_idfree` never
    # touches `derived_module_declared` at all — it only re-projects the
    # already-resolved `VisibleName`; `_in_scope_module_syms` filters via
    # `_IN_SCOPE_ORIGINS`, which excludes `:declared` outright.) No consumer in
    # the tree currently indexes `derived_module_declared` keyed on `origin ===
    # :declared` without also gating on `derived_module_names`/`haskey` first —
    # searched `\.origin\b`, `derived_module_declared(` across `src/`; see the
    # task report for the specific sites checked. So this test pins the
    # visible-vs-declared asymmetry itself, not a guard against a live
    # KeyError site.
    using JuliaWorkspaces: derived_module_declared, derived_module_visible_names_idfree,
        _in_scope_module_syms

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !haskey(derived_module_declared(jw.runtime, root, ["T"]), "set_foo!")
    @test haskey(derived_module_visible_names(jw.runtime, root, ["T"]), "set_foo!")
    # Exercise the two origin-filtering consumers; neither may throw, and a
    # macro-declared entry must not be mistaken for a loaded module.
    @test derived_module_visible_names_idfree(jw.runtime, root, ["T"]) isa Dict
    @test :set_foo! ∉ _in_scope_module_syms(jw.runtime, root, ["T"])
end

@testitem "macro-declared: the id-free projection backdates across an id shift" setup=[MacroDeclWS] begin
    # The id key is `(coarse kind, name AS WRITTEN, module path)` plus a
    # positional disambiguator among statements sharing that key (see
    # `_statement_id_key`/`_mint_ids!` in layer_inventory.jl). For a
    # `@deprecate` macrocall the "name as written" is the FIRST argument's own
    # call/identifier name, not the macro spelling — so two `@deprecate`s only
    # collide when that first argument names the same thing, e.g. two
    # `f`-overloads being deprecated. Different old-names (`oldb`/`olda`) never
    # collide and would make this test pass vacuously regardless of whether the
    # id-free projection actually strips the id.
    using JuliaWorkspaces: derived_module_visible_names_idfree, derived_file_inventory

    # The LAST-declared "f" item is the one that wins module-level dedup
    # (splice-order rule); pick it by `order`, since `after_src` has two.
    raw_id(src) = begin
        jw, root = macro_ws(src)
        items = [it for it in derived_file_inventory(jw.runtime, root).items
                 if it.kind === :macro_declared && it.name == "f"]
        last(sort(items; by=it -> it.order)).id
    end
    idfree(src) = begin
        jw, root = macro_ws(src)
        derived_module_visible_names_idfree(jw.runtime, root, ["T"])
    end

    before_src = """
    module T
    @deprecate f(x::Int) g(x)
    end
    """
    # Inserting a second `f`-deprecation ABOVE the first bumps its bucket
    # disambiguator (n: 0 -> 1), shifting its raw id — confirmed below — while
    # also making it the last-in-splice-order declaration of "f".
    after_src = """
    module T
    @deprecate f(x::Float64) h(x)
    @deprecate f(x::Int) g(x)
    end
    """

    # Premise: the surviving `f(x::Int)` statement's raw id actually shifts.
    @test raw_id(before_src) != raw_id(after_src)

    a = idfree(before_src)
    b = idfree(after_src)
    @test haskey(a, "f") && haskey(b, "f")
    # The id-free projection is unchanged across that shift — the whole point
    # of that seam.
    @test isequal(a["f"], b["f"])
end

@testitem "macro-declared: an inert row does not out-vote a real declaration" setup=[MacroDeclWS] begin
    # `_emit_macro_declarations!` runs at the top of `_classify_item!`, so a
    # single statement that ALSO derives macro-declared names shares its id
    # with the inert row it produces. `@deprecate f(x) = 1` is not a valid
    # `@deprecate` call (its first argument is a full function definition,
    # not `old`/`new`), but the derivation still extracts "f" from it, and the
    # statement itself is classified a second time as a genuine function.
    # `_build_kind_index` must report the real kind, not the inert one.
    using JuliaWorkspaces: derived_module_names, derived_file_inventory

    jw, root = macro_ws("""
    module T
    @deprecate f(x) = 1
    end
    """)

    # Premise: the statement really does produce both an inert row and a real
    # item sharing one id.
    items = [it for it in derived_file_inventory(jw.runtime, root).items if it.name == "f"]
    @test length(items) == 2
    @test length(unique(it.id for it in items)) == 1
    @test Set(it.kind for it in items) == Set([:macro_declared, :function])

    @test derived_module_names(jw.runtime, root, ["T"])["f"] === :function
end

@testitem "macro-declared: an inert row does not make a real declaration unrenameable" setup=[MacroDeclWS] begin
    # The same shared-id shape as above, on the RENAME path. `f` is written right
    # there in the source, so it is renameable; refusing it would make rename
    # silently do nothing. The precedence lives in `_macro_declared_item`, so this
    # and `_build_kind_index` cannot disagree about which row speaks for the name.
    using JuliaWorkspaces: can_rename, get_rename_edits, get_text_file

    jw, root = macro_ws("""
    module T
    @deprecate f(x) = 1
    g(x) = x
    end
    """)
    src = get_text_file(jw, root).content.content

    off = first(findfirst("f(x) = 1", src))
    @test can_rename(jw, root, off) !== nothing
    @test !isempty(get_rename_edits(jw, root, off, "renamed"))

    # An unrelated declaration is unaffected, and a genuinely macro-declared name
    # is still refused — the precedence only rescues names written in the source.
    off_g = first(findfirst("g(x) = x", src))
    @test can_rename(jw, root, off_g) !== nothing

    jw2, root2 = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    h(rt) = set_foo!(rt, 1, 2)
    end
    """; with_salsa_package=true)
    src2 = get_text_file(jw2, root2).content.content
    @test can_rename(jw2, root2, first(findlast("set_foo!", src2))) === nothing
end

@testitem "macro-declared: get_rename_edits refuses a macro-declared name" setup=[MacroDeclWS] begin
    # `_can_rename` refuses a macro-declared target, but `_get_rename_edits`
    # is a separate mutation-producing entry point and must refuse
    # independently: a client without `prepareSupport` calls it directly,
    # skipping prepareRename.
    using JuliaWorkspaces: get_rename_edits, get_text_file

    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    function use(rt)
        set_foo!(rt, 1, 2)
    end
    g(x) = x
    end
    """; with_salsa_package=true)

    src = get_text_file(jw, root).content.content

    off = first(findfirst("set_foo!(rt, 1, 2)", src))
    @test isempty(get_rename_edits(jw, root, off, "bar!"))

    # Not vacuous: an ordinary function in the same file still produces edits.
    off_g = first(findfirst("g(x) = x", src))
    @test !isempty(get_rename_edits(jw, root, off_g, "h"))
end

@testitem "macro-declared: the cycle invariant holds across a mutual dev-dependency" setup=[MacroDeclWS] begin
    # Two workspace packages that each `using` the other, one owning the
    # modelled macro. The index reads only the owner's tree and no tree
    # consumes any index, so A→B and B→A both terminate (design doc,
    # "Confirmation" §2) — but cycle detection is debug-gated, so an actual
    # cycle would hang here rather than raise, per the same note as the
    # same-root/cross-root cycle tests above. Assert debug mode first.
    using JuliaWorkspaces: Salsa
    @test Salsa.Debug.debug_enabled()

    jw, root = macro_ws("""
    module P
    using Salsa
    using Q
    Salsa.@declare_input foo(rt, x::Int)::V
    export set_foo!
    end
    """; root_uri=URI("file:///ws/P/src/P.jl"), with_salsa_package=true)

    add_file!(jw, TextFile(URI("file:///ws/P/Project.toml"), SourceText("""
    name = "P"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"
    version = "0.1.0"
    """, "toml")))

    q_root = URI("file:///ws/Q/src/Q.jl")
    add_file!(jw, TextFile(URI("file:///ws/Q/Project.toml"), SourceText("""
    name = "Q"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(q_root, SourceText("""
    module Q
    using P
    bar() = 1
    export bar
    end
    """, "julia")))

    vis_p = derived_module_visible_names(jw.runtime, root, ["P"])
    @test haskey(vis_p, "set_foo!")
    @test haskey(vis_p, "bar")

    vis_q = derived_module_visible_names(jw.runtime, q_root, ["Q"])
    @test haskey(vis_q, "set_foo!")
    @test haskey(vis_q, "bar")
end

@testitem "macro-declared: a baremodule has no implicit owner to confirm against" setup=[MacroDeclWS] begin
    # `@deprecate`'s owner is `Base`, which needs no import — but only in a module
    # that HAS the implicit `using Base`. A `baremodule` does not, so neither
    # `@deprecate` nor `Base` itself is in scope there and the macrocall declares
    # nothing. Confirming it anyway minted a phantom declared name.
    using JuliaWorkspaces: derived_macro_declared_names_index

    names_of(src) = begin
        jw, root = macro_ws(src)
        sort([n for ((_, n), _) in derived_macro_declared_names_index(jw.runtime, root)])
    end

    # An ordinary module: Base is in scope, so the owner confirms.
    @test names_of("module T\n@deprecate f g\nend\n") == ["f"]

    # A baremodule: nothing to confirm against, in either spelling. `Base.@deprecate`
    # fails too — `Base` is not a binding in a baremodule either.
    @test names_of("baremodule T\n@deprecate f g\nend\n") == String[]
    @test names_of("baremodule T\nBase.@deprecate f g\nend\n") == String[]

    # ...but an EXPLICIT `using Base` restores it, by falling through to the ordinary
    # import requirement rather than by a special case.
    @test names_of("baremodule T\nusing Base\n@deprecate f g\nend\n") == ["f"]
end
