# The `incorrect_call_args` takeover (arity arm) + `function_has_no_methods`
# (lint_lowering_rules.jl). Workspaces here have no project, so they are
# env-ready by construction and resolve against the core-only env — `Base` is
# a present store.

@testsnippet CallArgsWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const CA_URI = URI("file:///ca/src/Root.jl")

    function ca_workspace(files::Pair{String,String}...; flag=true)
        jw = JuliaWorkspace()
        for (path, src) in files
            add_file!(jw, TextFile(URI("file:///ca/src/$path"), SourceText(src, "julia")))
        end
        flag && set_v2_enabled!(jw, true)
        return jw
    end
    ca_workspace(src::String; kws...) = ca_workspace("Root.jl" => src; kws...)

    ca_diags(jw; uri=CA_URI) =
        filter(d -> d.code === :incorrect_call_args, get_diagnostic(jw, uri))
    ca_msgs(src) = [d.message for d in ca_diags(ca_workspace(src))]
end

@testitem "call args: workspace positives" setup=[CallArgsWS] begin
    # Too many / too few arguments against a single method.
    @test ca_msgs("f(x) = 1\nf(1, 2)\n") ==
        ["Possible method call error. Expected 1 argument, got 2."]
    @test ca_msgs("f(x, y) = 1\nf(1)\n") ==
        ["Possible method call error. Expected 2 arguments, got 1."]
    # The message ranges over a multi-method set.
    @test ca_msgs("f(x) = 1\nf(x, y) = 2\nf(1, 2, 3)\n") ==
        ["Possible method call error. Expected 1 to 2 arguments, got 3."]
    # Vararg methods render "at least" (v1's pluralization quirk included:
    # only the exact desc "1" is singular).
    @test ca_msgs("f(x, xs...) = 1\nf()\n") ==
        ["Possible method call error. Expected at least 1 arguments, got 0."]
    # An unsupported keyword.
    @test ca_msgs("f(x; a=1) = 1\nf(1; b=2)\n") ==
        ["Possible method call error. Unsupported keyword `b`."]
    # A zero-method forward declaration.
    @test ca_msgs("function f end\nf(1)\n") == ["Called function has no methods."]
    # A struct's default constructor.
    @test ca_msgs("struct S\n    a\nend\nS(1, 2)\n") ==
        ["Possible method call error. Expected 1 argument, got 2."]
    # The range points at the offending call (a last statement keeps its
    # trailing trivia, an established map property).
    src = "f(x) = 1\nf(1, 2)\n"
    jw = ca_workspace(src)
    d = only(ca_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test startswith(src[d.range], "f(1, 2)")
end

@testitem "call args: matching calls are silent" setup=[CallArgsWS] begin
    @test isempty(ca_msgs("""
    f(x, y=1; kw=2) = x
    g() = f(1)
    h() = f(1, 2; kw=3)
    struct S
        a
        S(x) = new(x)
        S(x, y) = new(x + y)
    end
    mk() = S(1, 2)
    """))
    # Defaults, kwsplat, bounded varargs.
    @test isempty(ca_msgs("f(; kws...) = 1\ng() = f(a=1, b=2)\n"))
    @test isempty(ca_msgs("f(x::Vararg{Int,3}) = 1\ng() = f(1, 2, 3)\n"))
end

@testitem "call args: exemptions decline" setup=[CallArgsWS] begin
    # A splatted call has an unknowable arity.
    @test isempty(ca_msgs("f(x) = 1\ng(xs) = f(xs...)\n"))
    # A do-block adds an argument the call doesn't spell.
    @test isempty(ca_msgs("g(xs) = map(xs) do x\n    x\nend\n"))
    # A locally-shadowed callee (a parameter) hides the global's methods.
    @test isempty(ca_msgs("f(x) = 1\ng(f, x) = f(x, x, x)\n"))
    # A definition signature is call-shaped but not a call — while a real call
    # in a default value stays checked.
    @test ca_msgs("f(x, y) = 1\ng(a = f(1)) = a\n") ==
        ["Possible method call error. Expected 2 arguments, got 1."]
    # `@test_throws` bodies are expected to error.
    @test isempty(ca_msgs("using Test\nf(x) = 1\ng() = @test_throws MethodError f(1, 2)\n"))
    # Unknown-macro arguments may be a DSL.
    @test isempty(ca_msgs("f(x) = 1\n@somedsl f(1, 2)\n"))
    # ...and an opaque macrocall blinds its whole module (its expansion could
    # add methods).
    @test isempty(ca_msgs("@somedsl x\nf(x) = 1\ng() = f(1, 2)\n"))
    # A macro-wrapped definition may be rewritten: permissive arity.
    @test isempty(ca_msgs("@memoize f(x) = 1\ng() = f(1, 2, 3)\n"))
    # Aliased functions through plain assignment decline.
    @test isempty(ca_msgs("f(x) = 1\nconst g = f\nh() = g(1, 2)\n"))
    # Import-then-extend: the method set spans the import target — declined.
    @test isempty(ca_msgs("import Base: sin\nsin(x, y) = x\ng() = sin(1, 2, 3)\n"))
    # Test-block bodies are declined wholesale.
    @test isempty(ca_msgs("f(x) = 1\n@testset \"t\" begin\n    f(1, 2)\nend\n"))
    @test isempty(ca_msgs("f(x) = 1\n@testitem \"t\" begin\n    f(1, 2)\nend\n"))
    # Quoted code is data.
    @test isempty(ca_msgs("f(x) = 1\ng() = :(f(1, 2))\n"))
end

@testitem "call args: external and qualified callees" setup=[CallArgsWS] begin
    # An implicit Base name, checked against the store.
    @test ca_msgs("g() = isempty()\n") ==
        ["Possible method call error. Expected 1 argument, got 0."]
    # A colon-imported store name.
    @test !isempty(ca_msgs("using Base: isempty\ng() = isempty()\n"))
    # A qualified store callee.
    @test !isempty(ca_msgs("g() = Base.isempty()\n"))
    # An `as`-renamed import declines (the store knows another name).
    @test isempty(ca_msgs("using Base: isempty as ie\ng() = ie()\n"))
    # A qualified workspace callee resolves through the module ledger.
    src = """
    module M
    g(x) = 1
    end
    h() = M.g(1, 2)
    """
    @test ca_msgs(src) == ["Possible method call error. Expected 1 argument, got 2."]
    # A workspace extension of a store function declines the name everywhere.
    @test isempty(ca_msgs("Base.isempty(x, y) = true\ng() = Base.isempty()\n"))
    @test isempty(ca_msgs("Base.isempty(x, y) = true\ng() = isempty()\n"))
end

@testitem "call args: cross-file method sets" setup=[CallArgsWS] begin
    jw = ca_workspace(
        "Root.jl" => "include(\"a.jl\")\ninclude(\"b.jl\")\nmain() = f(1, 2, 3)\n",
        "a.jl" => "f(x) = 1\n",
        "b.jl" => "f(x, y) = 2\ncallsite() = f(1)\n",
    )
    # The caller in b.jl sees a.jl's method too: f(1) matches, silent.
    @test isempty(ca_diags(jw; uri=URI("file:///ca/src/b.jl")))
    # Three arguments match neither.
    @test only(ca_diags(jw)).message ==
        "Possible method call error. Expected 1 to 2 arguments, got 3."
end

@testitem "call args: flag, config and takeover" setup=[CallArgsWS] begin
    src = "f(x) = 1\ng() = f(1, 2)\n"
    jw = ca_workspace(src; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl", ca_diags(jw))
    # Config off silences the takeover producer too.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ca/JuliaLint.toml"),
        SourceText("[rules]\nincorrect_call_args = \"off\"\n", "toml")))
    add_file!(jw, TextFile(CA_URI, SourceText(src, "julia")))
    set_v2_enabled!(jw, true)
    @test isempty(ca_diags(jw))
    # Flag on: only the v2 engine reports this rule id.
    jw = ca_workspace(src)
    @test all(d -> d.source == "JuliaWorkspaces.jl", ca_diags(jw))
end

# The corpus differential: v1's vs v2's `incorrect_call_args`-rule findings
# over this repo, keyed per file by (rule, range start) — messages legitimately
# differ (the type arm is not ported), and range ends can straddle trivia.
# v2-only findings are false-positive candidates and fail hard; v1-only
# findings are the expected residue of v2's wider declines (test blocks,
# partial-method names, blind modules, type-arm-only detections) and are
# printed for review.
@testitem "v2 call args agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

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
        v1 = Set(first(f.range) for f in JW.derived_new_static_lint_diagnostics(jw.runtime, uri)
                 if f.rule_id === :incorrect_call_args)
        v2 = Set(first(f.range) for f in JW.derived_semantic_lint_findings(jw.runtime, uri)
                 if f.rule_id === :incorrect_call_args)
        agreement[] += length(intersect(v1, v2))
        v1_only[] += length(setdiff(v1, v2))
        for s in setdiff(v2, v1)
            push!(v2_only, "$(uri) @$(s)")
        end
    end

    println("call-args differential: agreement=$(agreement[]) v1_only=$(v1_only[])")
    isempty(v2_only) || println("v2-only findings (false-positive candidates):\n  " *
        join(first(v2_only, 40), "\n  "))
    @test v2_only == String[]
end
