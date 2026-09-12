# v2 `missing_reference` (lint_lowering_rules.jl): the post-pass join over
# lowering's anchor-module globals. Projectless workspaces are env-ready by
# construction and see the core-only env (Base/Core stores present).

@testsnippet MissRefV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const MR_URI = URI("file:///mr/src/F.jl")

    function mr_workspace(src::String; flag=true, config::Union{Nothing,String}=nothing)
        jw = JuliaWorkspace()
        config === nothing && add_file!(jw, TextFile(URI("file:///mr/JuliaLint.toml"), SourceText("[rules]\nmissing_reference = \"warning\"\nunresolved_import = \"warning\"\nincorrect_call_args = \"warning\"\n", "toml")))
        config !== nothing &&
            add_file!(jw, TextFile(URI("file:///mr/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(MR_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    mr_diags(jw; uri=MR_URI) =
        filter(d -> d.code === :missing_reference, get_diagnostic(jw, uri))
end

@testitem "v2 missing_reference: basics" setup=[MissRefV2WS] begin
    # An undefined bare name flags at the use site, once per use.
    jw = mr_workspace("f() = undefined_name_xyz\n")
    d = only(mr_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test d.message == "Missing reference: undefined_name_xyz"

    jw = mr_workspace("f() = undefined_a + undefined_a\n")
    ds = mr_diags(jw)
    @test length(ds) == 2
    @test length(unique(d.range for d in ds)) == 2

    # Locals, arguments, and declared siblings are not missing.
    jw = mr_workspace("g() = 1\nf(x) = begin y = x + 1; g() + y end\n")
    @test isempty(mr_diags(jw))

    # Names declared in a sibling file of the same module resolve.
    add = URI("file:///mr/src/other.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(MR_URI, SourceText("include(\"other.jl\")\nf() = from_other()\n", "julia")))
    add_file!(jw, TextFile(add, SourceText("from_other() = 1\n", "julia")))
    set_v2_enabled!(jw, true)
    @test isempty(mr_diags(jw))
    @test isempty(mr_diags(jw; uri=add))
end

@testitem "v2 missing_reference: implicit scope and imports" setup=[MissRefV2WS] begin
    # Base/Core exports and the builtins never flag.
    jw = mr_workspace("f() = println(length([1]))\ng() = Base.show\nh() = Core.Int\ni() = Main\n")
    @test isempty(mr_diags(jw))

    # A store-backed wildcard using brings in its exports.
    jw = mr_workspace("module M\nusing Base.Threads\nf() = nthreads()\nend\n")
    @test isempty(mr_diags(jw))

    # A colon import binds its name lexically even when the store is missing —
    # the import statement carries the diagnosis, never the use site.
    jw = mr_workspace("module M\nusing Printf: @sprintf, psetup\nf() = psetup()\nend\n")
    @test isempty(mr_diags(jw))

    # Qualified reads check only the root name.
    jw = mr_workspace("module M\nimport Base\nf() = Base.no_such_member_xyz()\nend\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = NoSuchModule.member\n")
    @test only(mr_diags(jw)).message == "Missing reference: NoSuchModule"
end

@testitem "v2 missing_reference: module blindness gates" setup=[MissRefV2WS] begin
    # An unresolved wildcard using silences the module…
    jw = mr_workspace("module M\nusing NotAPackage\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))
    # …but not a sibling module.
    jw = mr_workspace("module M\nusing NotAPackage\nend\nmodule N\nf() = undefined_xyz\nend\n")
    @test !isempty(mr_diags(jw))

    # A computed include may define anything.
    jw = mr_workspace("module M\ninclude(pathof_something())\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))

    # A top-level opaque macrocall may define anything.
    jw = mr_workspace("module M\n@some_dsl begin end\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))

    # A colon-list import whose target resolves nowhere (an unindexed
    # dependency, PlotsBase's `import ..Colors: Colorant`) still binds the
    # listed names — Julia binds them lexically — without blinding the
    # module for anything else.
    jw = mr_workspace("module M\nimport NotAPackage: thing\nf() = thing\ng() = other_undef\nend\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: other_undef"]
    jw = mr_workspace("module M\nmodule Inner\nimport ..Nope: thing as t\nf() = t\ng() = other_undef\nend\nend\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: other_undef"]

    # Declarations the walker used to step over: a chained assignment's inner
    # target, a conditional const under `||`, a `;`-terminated const.
    jw = mr_workspace("w = h = 500\nisdefined(Main, :U) || (const U = String)\nconst k = 1;\nf(x::U) = (h, k, x)\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: synthetic-read suppression intervals" setup=[MissRefV2WS] begin
    # Reads fabricated from an opaque macrocall's arguments are suppressed;
    # real reads in the same item still flag.
    jw = mr_workspace("function f()\n    @assert undefined_inside\n    return undefined_outside\nend\n")
    d = only(mr_diags(jw))
    @test d.message == "Missing reference: undefined_outside"

    # Identifiers inside a quote never flag — including interpolations.
    jw = mr_workspace("f() = :(undefined_in_quote + 1)\ng(x) = :(\$x + undefined_q)\n")
    @test isempty(mr_diags(jw))

    # var-strings and operators are exempt.
    jw = mr_workspace("f() = var\"weird name\"\ng(a, b) = a ⊕ b\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: item gates" setup=[MissRefV2WS] begin
    # Existence-guarded items are skipped whole.
    jw = mr_workspace("f() = @isdefined(maybe_undef) ? maybe_undef : 0\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = VERSION >= v\"1.9\" ? new_thing_xyz() : 0\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = isdefined(Main, :x) && undefined_maybe\n")
    @test isempty(mr_diags(jw))

    # Test blocks and testitems run with runtime imports this analysis cannot
    # see.
    jw = mr_workspace("@testset \"t\" begin\n    something_from_test()\nend\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("@testitem \"t\" begin\n    @test undefined_in_testitem()\nend\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: file-level suppression" setup=[MissRefV2WS] begin
    # An own-root helper under a package's test/ folder is silenced whole (a
    # @testitem includes it at runtime with invisible imports).
    project = "name = \"MrPkg\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee41\"\nversion = \"0.1.0\"\n"
    helper = URI("file:///mrp/test/helpers.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mrp/JuliaLint.toml"), SourceText("[rules]\nmissing_reference = \"warning\"\nunresolved_import = \"warning\"\nincorrect_call_args = \"warning\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///mrp/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(URI("file:///mrp/src/MrPkg.jl"), SourceText("module MrPkg\nend\n", "julia")))
    add_file!(jw, TextFile(helper, SourceText("helper_f() = undefined_from_helper\n", "julia")))
    set_v2_enabled!(jw, true)
    JW.set_input_env_ready!(jw.runtime, true)
    @test isempty(mr_diags(jw; uri=helper))
end

@testitem "v2 missing_reference: options, flag, and takeover" setup=[MissRefV2WS] begin
    # scope = "none" and the rule off are both silent.
    jw = mr_workspace("f() = undefined_name_xyz\n";
        config="[rules]\nmissing_reference = { severity = \"warning\", scope = \"none\" }\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = undefined_name_xyz\n";
        config="[rules]\nmissing_reference = \"off\"\n")
    @test isempty(mr_diags(jw))

    # Flag on: only the v2 producer reports (StaticLint suppressed).
    jw = mr_workspace("f() = undefined_name_xyz\n")
    @test all(d -> d.source == "JuliaWorkspaces.jl", mr_diags(jw))

    # Flag off: nothing from the v2 producer.
    jw = mr_workspace("f() = undefined_name_xyz\n"; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl", mr_diags(jw))
end

@testitem "missing_reference: assignments nested inside expressions bind" setup=[MissRefV2WS] begin
    # A raw `=` that is a direct child of a call is an assignment EXPRESSION
    # the parser deliberately kept (`kw` rewriting happens only in the parser,
    # or for macro-unwrapped signature arguments) — it must bind its name for
    # the rest of the scope. The round-2 sweep caught the transparent-macro
    # `=`→`kw` re-wrap over-applying here: 27/50 sampled missing_reference
    # findings were `if (m = match(...)) !== nothing` shapes.
    for src in [
        "g(s) = if (m = match(r\"a\", s)) !== nothing\n    m.match\nelse\n    nothing\nend\n",
        "k(F) = ((n = length(F)) > 0 || throw(ArgumentError(\"x\")); n)\n",
        "function p(xs)\n    while (l = length(xs)) > 0\n        pop!(xs)\n        l -= 1\n    end\nend\n",
        "q(c, r, bm) = (bm = bm[c, r]) == 0 ? nothing : bm\n",
        "w(a, f, c) = if a && (b = f()) != c\n    b\nend\n",
    ]
        jw = mr_workspace(src)
        @test isempty(mr_diags(jw))
    end
end

@testitem "missing_reference: doc signatures and guarded imports" setup=[MissRefV2WS] begin
    # A documented bare method signature never evaluates — its argument
    # names are not reads (AbstractFFTs, Compat, DBInterface, InverseFunctions).
    jw = mr_workspace("\"\"\"\n    stack(f, iter)\n\nDocs.\n\"\"\"\nstack(f, iter)\n")
    @test isempty(mr_diags(jw))

    # A `using`/`import` inside a try/if body may bring in any name: the
    # module is blind for missing_reference (silently in the default preset;
    # with a boundary notice when opted in), so a name that import may
    # provide is not flagged.
    src = """
    try
        import GR_jll
    catch
    end
    f() = GR_jll.libGR
    g() = something_from_gr()
    """
    jw = mr_workspace(src)
    @test isempty(mr_diags(jw))
    @test !any(d -> d.code === :analysis_boundary, JuliaWorkspaces.get_diagnostic(jw, MR_URI))
    jw = mr_workspace(src; config="[rules]\nanalysis_boundary = \"warning\"\n")
    @test isempty(mr_diags(jw))
    @test !isempty(filter(d -> d.code === :analysis_boundary && occursin("conditional", d.message),
                          JuliaWorkspaces.get_diagnostic(jw, MR_URI)))
end

@testitem "missing_reference: a whole-module using of a blind module blinds this one" setup=[MissRefV2WS] begin
    # MLStyle: `using MLStyle` inside a submodule, where MLStyle's own
    # `@reexport` computes its `export` list at expansion time — the used
    # module's exports are incomplete, so names here cannot be judged.
    jw = mr_workspace("""
    module Inner
    @generate_api names_go_here
    export foo
    end
    using .Inner
    g() = bar_from_inner()
    """)
    @test isempty(mr_diags(jw))
    # The same shape with a fully modeled Inner reports the typo.
    jw = mr_workspace("module Inner\nexport foo\nfoo() = 1\nend\nusing .Inner\ng() = bar_from_inner()\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: bar_from_inner"]
    # A colon-list using is exact and never blinds.
    jw = mr_workspace("module Inner\n@generate_api x\nexport foo\nfoo() = 1\nend\nusing .Inner: foo\ng() = bar_from_inner()\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: bar_from_inner"]
    # A runtime `@eval` inside Inner's function bodies blinds Inner itself
    # (it may define names there) but not its export list: the module that
    # `using`s it still judges its own names (PlotsBase's backend loops vs
    # its `Annotations` submodule).
    jw = mr_workspace("""
    module Inner
    export foo
    foo() = 1
    function make()
        @eval bar() = 2
    end
    use() = undefined_in_inner()
    end
    using .Inner
    g() = bar_from_inner()
    """)
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: bar_from_inner"]
end

@testitem "missing_reference: @reexport is modeled only in its using/import shapes" setup=[MissRefV2WS] begin
    # `@reexport using X` is walked as the import it wraps: no blindness, a
    # typo next to it still reports.
    jw = mr_workspace("module M\n@reexport using Base.Iterators\nf() = undefined_xyz\nend\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: undefined_xyz"]
    jw = mr_workspace("module M\n@reexport begin\n    using Base.Iterators\n    import Base.Threads\nend\nf() = undefined_xyz\nend\n")
    @test [d.message for d in mr_diags(jw)] == ["Missing reference: undefined_xyz"]
    # A bare-module argument (MLStyle's own same-named macro, computing its
    # export list at expansion time) is an unmodelled effect: opaque, blind.
    jw = mr_workspace("module M\nmodule Impl\nexport gen_match\ngen_match() = 1\nend\n@reexport Impl\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))
    @test JW.derived_v2_module_has_opaque_macrocall(jw.runtime, MR_URI, ["M"])
end
