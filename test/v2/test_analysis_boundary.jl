# `analysis_boundary` (lint_lowering_rules.jl): one notice per construct the
# linter cannot see through, so the silence of the suppressed rules is never
# mistaken for a clean result. Computed includes keep their ComputedInclude
# notice (include_errors); this rule covers `@eval`/`eval` boundaries.

@testsnippet BoundaryWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    const AB_URI = URI("file:///ab/src/R.jl")

    function ab_workspace(src::String; flag=true, config=nothing)
        jw = JuliaWorkspace()
        config !== nothing &&
            add_file!(jw, TextFile(URI("file:///ab/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(AB_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    ab_diags(jw; uri=AB_URI) =
        filter(d -> d.code === :analysis_boundary, get_diagnostic(jw, uri))
end

@testitem "analysis_boundary: interpolated @eval notices and blinds" setup=[BoundaryWS] begin
    # A loop over a non-literal collection: one notice, module blinded
    # (the literal-tuple form is extractable and covered separately).
    src = "syms = (:a, :b)\nfor f in syms\n    @eval \$f(x) = x\nend\n"
    jw = ab_workspace(src)
    ds = ab_diags(jw)
    @test length(ds) == 1
    @test occursin("missing_reference", only(ds).message)
    @test only(ds).severity === :information
    @test JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])

    # The same @eval inside a function body: the body-marker path.
    src = "function load!(d)\n    for k in keys(d)\n        @eval const \$k = 1\n    end\nend\n"
    jw = ab_workspace(src)
    @test length(ab_diags(jw)) == 1
    @test JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])

    # A bare `eval(expr)` call in a body is a boundary too.
    jw = ab_workspace("function g(ex)\n    eval(ex)\nend\n")
    @test length(ab_diags(jw)) == 1

    # A DIRECT top-level interpolated @eval statement takes the walker's
    # opaque-row path rather than the body-marker path — same one notice.
    jw = ab_workspace("const names = (:a, :b)\n@eval \$(names[1])(x) = x\n")
    @test length(ab_diags(jw)) == 1
    @test JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])
end

@testitem "analysis_boundary: modeled @eval stays silent" setup=[BoundaryWS] begin
    # Uninterpolated `@eval f(x) = 1` keeps its inner definition as an
    # ordinary modeled item — no notice, no blindness.
    jw = ab_workspace("@eval f(x) = x\n")
    @test isempty(ab_diags(jw))
    @test !JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])
    @test haskey(JW.derived_v2_module_names(jw.runtime, AB_URI, String[]), "f")

    # `$` inside a quote that is merely DATA (no eval) is not a boundary.
    jw = ab_workspace("q(x) = :(g(\$x))\n")
    @test isempty(ab_diags(jw))
end

@testitem "analysis_boundary: extractable @eval loops declare and stay silent" setup=[BoundaryWS] begin
    # `for f in (:a, :b); @eval $f(x) = … end` iterates literal symbols: the
    # generated names are enumerable statically — declared, no blindness, no
    # notice (v1's interpret_eval counterpart).
    src = "for f in (:generated_a, :generated_b)\n    @eval \$f(x) = x\nend\nuse_it() = generated_a(1)\n"
    jw = ab_workspace(src)
    @test isempty(ab_diags(jw))
    @test !JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])
    names = JW.derived_v2_module_names(jw.runtime, AB_URI, String[])
    @test get(names, "generated_a", nothing) === :function
    @test get(names, "generated_b", nothing) === :function
    @test !any(d -> d.code === :missing_reference && occursin("generated_a", d.message),
               JuliaWorkspaces.get_diagnostic(jw, AB_URI))

    # Destructured loops and const forms extract too.
    jw = ab_workspace("for (f, s) in ((:pa, :sa), (:pb, :sb))\n    @eval \$f(x) = \$s\nend\n")
    @test isempty(ab_diags(jw))
    names = JW.derived_v2_module_names(jw.runtime, AB_URI, String[])
    @test haskey(names, "pa") && haskey(names, "pb")
    jw = ab_workspace("for c in (:red, :green)\n    @eval const \$c = 1\nend\n")
    @test isempty(ab_diags(jw))
    @test get(JW.derived_v2_module_names(jw.runtime, AB_URI, String[]), "red", nothing) === :const

    # A non-literal iteration cannot extract: boundary notice + blindness stay.
    jw = ab_workspace("for f in name_list\n    @eval \$f(x) = x\nend\n")
    @test length(ab_diags(jw)) == 1
    @test JW.derived_v2_module_has_opaque_macrocall(jw.runtime, AB_URI, String[])
    # A computed name position cannot extract either.
    jw = ab_workspace("for f in (:a, :b)\n    @eval \$(Symbol(f, :_new))(x) = x\nend\n")
    @test length(ab_diags(jw)) == 1
end

@testitem "analysis_boundary: flag and preset gates" setup=[BoundaryWS] begin
    src = "for f in (:a, :b)\n    @eval \$f(x) = x\nend\n"
    # v2 flag off: nothing (v2-only producer).
    jw = ab_workspace(src; flag=false)
    @test isempty(ab_diags(jw))
    # Rule off by config.
    jw = ab_workspace(src; config="[rules]\nanalysis_boundary = \"off\"\n")
    @test isempty(ab_diags(jw))
    # Minimal preset ships it off.
    jw = ab_workspace(src; config="preset = \"minimal\"\n")
    @test isempty(ab_diags(jw))
end
