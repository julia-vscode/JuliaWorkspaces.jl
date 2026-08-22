# `soft_scope_ambiguity` (lint_lowering_rules.jl): Julia's soft-scope
# ambiguity warning, statically, via a second lowering into an anchor module
# seeded with the enclosing module's plain-global names.

@testsnippet SoftScopeWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const SS_URI = URI("file:///ss/src/F.jl")

    function ss_workspace(src::String; flag=true, config=nothing)
        jw = JuliaWorkspace()
        config !== nothing &&
            add_file!(jw, TextFile(URI("file:///ss/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(SS_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    ss_diags(jw; uri=SS_URI) =
        filter(d -> d.code === :soft_scope_ambiguity, get_diagnostic(jw, uri))
end

@testitem "soft scope: the seeded-anchor partition-kind assumption holds" begin
    # The rule's whole mechanism rests on the seed (`global x = nothing`,
    # eval'd — `setglobal!` cannot CREATE a binding on Julia ≥1.12) producing
    # the value-carrying, non-const global binding that JuliaLowering's
    # `is_defined_and_owned_global` tests for. Pin it.
    m = Module(:SeedProbe)
    Core.eval(m, Expr(:global, Expr(:(=), :probe, nothing)))
    @test Base.binding_kind(m, :probe) === Base.PARTITION_KIND_GLOBAL
end

@testitem "soft scope: positives" setup=[SoftScopeWS] begin
    # The canonical shape: a global, then a separate top-level loop assigning it.
    src = "s = 0\nfor i in 1:3\n    s += 1\nend\n"
    jw = ss_workspace(src)
    d = only(ss_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test occursin("Assignment to `s` in soft scope is ambiguous", d.message)
    @test occursin("`global s`", d.message)
    # The range points at the assignment inside the loop.
    @test first(d.range) > findfirst("for", src)[1]

    # while and try are soft scopes too.
    jw = ss_workspace("s = 0\nwhile s < 3\n    s = s + 1\nend\n")
    @test !isempty(ss_diags(jw))
    jw = ss_workspace("s = 0\ntry\n    s = 1\ncatch\nend\n")
    @test !isempty(ss_diags(jw))

    # `global x` declarations count as globals.
    jw = ss_workspace("global g = 0\nfor i in 1:3\n    g = i\nend\n")
    @test !isempty(ss_diags(jw))
end

@testitem "soft scope: negatives" setup=[SoftScopeWS] begin
    # Explicit disambiguation.
    jw = ss_workspace("s = 0\nfor i in 1:3\n    global s += 1\nend\n")
    @test isempty(ss_diags(jw))
    jw = ss_workspace("s = 0\nfor i in 1:3\n    local s = 1\n    s += 1\nend\n")
    @test isempty(ss_diags(jw))

    # The iteration variable is always a fresh local — no ambiguity.
    jw = ss_workspace("i = 99\nfor i in 1:3\n    println(i)\nend\n")
    @test isempty(ss_diags(jw))

    # Function bodies are hard scope.
    jw = ss_workspace("s = 0\nfunction f()\n    for i in 1:3\n        s = i\n    end\n    return s\nend\n")
    @test isempty(ss_diags(jw))

    # Consts, functions and datatypes never soft-scope-warn.
    jw = ss_workspace("const c = 1\nfor i in 1:3\n    c = i\nend\n")
    @test isempty(ss_diags(jw))
    jw = ss_workspace("f() = 1\nfor i in 1:3\n    f = i\nend\n")
    @test isempty(ss_diags(jw))

    # No matching global at all: a plain new local in the loop.
    jw = ss_workspace("for i in 1:3\n    fresh = i\nend\n")
    @test isempty(ss_diags(jw))

    # A `let` is hard scope even at top level.
    jw = ss_workspace("s = 0\nlet\n    s = 1\nend\n")
    @test isempty(ss_diags(jw))

    # @testset bodies (let-wrapped) and @testitem bodies are immune.
    jw = ss_workspace("s = 0\n@testset \"t\" begin\n    for i in 1:3\n        s = i\n    end\nend\n")
    @test isempty(ss_diags(jw))
    jw = ss_workspace("s = 0\n@testitem \"t\" begin\n    for i in 1:3\n        s = i\n    end\nend\n")
    @test isempty(ss_diags(jw))
end

@testitem "soft scope: cross-file global in the same module" setup=[SoftScopeWS] begin
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(SS_URI, SourceText("include(\"defs.jl\")\nfor i in 1:3\n    s += i\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ss/src/defs.jl"), SourceText("s = 0\n", "julia")))
    set_v2_enabled!(jw, true)
    @test !isempty(ss_diags(jw))
end

@testitem "soft scope: flag and config" setup=[SoftScopeWS] begin
    src = "s = 0\nfor i in 1:3\n    s += 1\nend\n"
    jw = ss_workspace(src; flag=false)
    @test isempty(ss_diags(jw))
    jw = ss_workspace(src; config="[rules]\nsoft_scope_ambiguity = \"off\"\n")
    @test isempty(ss_diags(jw))
    jw = ss_workspace(src; config="[rules]\nsoft_scope_ambiguity = \"warning\"\n")
    @test only(ss_diags(jw)).severity === :warning
end

@testitem "soft scope: corpus false-positive sweep" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    root_dir = pkgdir(JuliaWorkspaces)
    jw = JuliaWorkspace()
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

    hits = String[]
    for uri in uris
        for f in JW.derived_semantic_lint_findings(jw.runtime, uri)
            f.rule_id === :soft_scope_ambiguity &&
                push!(hits, "$(uri) $(f.range): $(f.message)")
        end
    end
    isempty(hits) || println("soft_scope_ambiguity corpus hits:\n  " * join(hits, "\n  "))
    @test isempty(hits)
end
