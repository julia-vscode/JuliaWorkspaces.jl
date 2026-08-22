# The shape-rule takeovers (lint_lowering_rules.jl `derived_item_shape_findings`):
# `pointless_boolean` + `const_if_condition` (+ `literal_use`, commit 2) — pure
# syntax shapes, no lowering/visibility/env.

@testsnippet ShapeRulesWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const SH_URI = URI("file:///sh/src/Root.jl")

    function sh_workspace(src::String; flag=true, config=nothing)
        jw = JuliaWorkspace()
        config !== nothing &&
            add_file!(jw, TextFile(URI("file:///sh/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(SH_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    sh_diags(src, code; kws...) =
        filter(d -> d.code === code, get_diagnostic(sh_workspace(src; kws...), SH_URI))
end

@testitem "shape rules: pointless boolean" setup=[ShapeRulesWS] begin
    or_msg = "The first argument of a `||` call is a boolean literal."
    and_msg = "An argument of a `&&` call is a boolean literal."
    # `||` flags on a FIRST boolean literal only; `&&` on either (v1's
    # deliberate asymmetry — `iszero(x) && false` is a real-world shape).
    @test only(sh_diags("f(x) = true || g(x)\n", :pointless_boolean)).message == or_msg
    @test isempty(sh_diags("f(x) = g(x) || false\n", :pointless_boolean))
    @test only(sh_diags("f(x) = true && g(x)\n", :pointless_boolean)).message == and_msg
    @test only(sh_diags("f(x) = iszero(x) && false\n", :pointless_boolean)).message == and_msg
    # Clean chains are silent.
    @test isempty(sh_diags("f(x, y) = x || y && g(x)\n", :pointless_boolean))
    # The range covers the whole binary expression.
    src = "f(x) = true || g(x)\n"
    d = only(sh_diags(src, :pointless_boolean))
    @test startswith(src[d.range], "true || g(x)")
end

@testitem "shape rules: const if condition" setup=[ShapeRulesWS] begin
    msg = "A boolean literal has been used as the conditional of an if statement - it will either always or never run."
    src = "function f()\n    if true\n        1\n    end\nend\n"
    d = only(sh_diags(src, :const_if_condition))
    @test d.message == msg
    @test d.source == "JuliaWorkspaces.jl"
    # The range points at the condition literal.
    @test startswith(src[d.range], "true")
    # Ternaries parse as `if` and flag, exactly as v1's `:if`-headed check.
    @test !isempty(sh_diags("f(x) = true ? 1 : 2\n", :const_if_condition))
    # `elseif` conditions are exempt in both engines.
    @test isempty(sh_diags(
        "function f(x)\n    if x\n        1\n    elseif false\n        2\n    end\nend\n",
        :const_if_condition))
    # Non-literal conditions are silent.
    @test isempty(sh_diags("function f(x)\n    if x\n        1\n    end\nend\n",
        :const_if_condition))
end

@testitem "shape rules: exemptions and skips" setup=[ShapeRulesWS] begin
    # `@static if false` is a deliberate compile-time toggle — exempt, and
    # (documented name-based delta vs v1's identity resolution) a shadowing
    # user macro spelled `@static` buys the same exemption.
    @test isempty(sh_diags(
        "function f()\n    @static if false\n        1\n    end\nend\n",
        :const_if_condition))
    # ...but only the DIRECT `if` argument: a nested `if true` inside the
    # branch still flags.
    @test !isempty(sh_diags(
        "function f()\n    @static if false\n        if true\n            1\n        end\n    end\nend\n",
        :const_if_condition))
    # Quoted code is data; unknown-macro arguments may be a DSL;
    # `@test_throws` bodies are expected to error.
    @test isempty(sh_diags("f() = :(true || g())\n", :pointless_boolean))
    @test isempty(sh_diags("f() = @somedsl true || g()\n", :pointless_boolean))
    @test isempty(sh_diags("using Test\nf() = @test_throws ErrorException (true || g())\n",
        :pointless_boolean))
    # Test-block bodies stay covered — these rules need no resolution context.
    @test !isempty(sh_diags(
        "@testitem \"t\" begin\n    if true\n        1\n    end\nend\n",
        :const_if_condition))
    @test !isempty(sh_diags(
        "@testset \"t\" begin\n    x = true || g()\nend\n",
        :pointless_boolean))
end

@testitem "shape rules: flag and config" setup=[ShapeRulesWS] begin
    src = "f(x) = true || g(x)\nfunction h()\n    if true\n        1\n    end\nend\n"
    jw = sh_workspace(src; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl",
               filter(d -> d.code in (:pointless_boolean, :const_if_condition),
                      get_diagnostic(jw, SH_URI)))
    @test isempty(sh_diags(src, :pointless_boolean;
        config="[rules]\npointless_boolean = \"off\"\n"))
    @test isempty(sh_diags(src, :const_if_condition;
        config="[rules]\nconst_if_condition = \"off\"\n"))
    # Flag on: only the v2 engine reports these ids.
    jw = sh_workspace(src)
    for code in (:pointless_boolean, :const_if_condition)
        @test all(d -> d.source == "JuliaWorkspaces.jl",
                  filter(d -> d.code === code, get_diagnostic(jw, SH_URI)))
    end
end

# Corpus differential: messages match v1's, count-per-file keys. v2-only
# findings fail hard; v1-only residue (top-level `if` chains — the walker is
# transparent through them — plus quoted code and unknown-macro arguments,
# which v1 lints) is printed for review.
@testitem "v2 shape rules agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    const RULES = (:pointless_boolean, :const_if_condition, :literal_use)

    root_dir = pkgdir(JuliaWorkspaces)
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Project.toml")),
        SourceText(read(joinpath(root_dir, "Project.toml"), String), "toml")))
    add_file!(jw, TextFile(filepath2uri(joinpath(root_dir, "Manifest.toml")),
        SourceText("julia_version = \"1.12.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"0\"\n\n[deps]\n", "toml")))
    uris = JuliaWorkspaces.URIs2.URI[]
    for sub in ("src", "test")
        isdir(joinpath(root_dir, sub)) || continue
        for (d, _, fs) in walkdir(joinpath(root_dir, sub))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") || continue
                p = joinpath(d, f)
                uri = filepath2uri(p)
                add_file!(jw, TextFile(uri, SourceText(read(p, String), "julia")))
                push!(uris, uri)
            end
        end
    end
    @test length(uris) > 50
    JW.set_v2_enabled!(jw, true)

    v2_only = String[]
    v1_only = Ref(0)
    agreement = Ref(0)
    for uri in uris
        for rule in RULES
            n1 = count(f -> f.rule_id === rule,
                       JW.derived_new_static_lint_diagnostics(jw.runtime, uri))
            n2 = count(f -> f.rule_id === rule,
                       JW.derived_semantic_lint_findings(jw.runtime, uri))
            agreement[] += min(n1, n2)
            n2 > n1 && push!(v2_only, "$(uri): $(rule) v2=$(n2) v1=$(n1)")
            n1 > n2 && (v1_only[] += n1 - n2)
        end
    end
    println("shape-rules differential: agreement=$(agreement[]) v1_only=$(v1_only[])")
    isempty(v2_only) || println("v2-only findings (false-positive candidates):\n  " *
        join(first(v2_only, 40), "\n  "))
    @test v2_only == String[]
end
