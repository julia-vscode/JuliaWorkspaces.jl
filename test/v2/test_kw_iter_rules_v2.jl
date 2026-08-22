# `kw_default_mismatch` + `incorrect_iter_spec` (literal arm) takeovers
# (lint_lowering_rules.jl). Projectless workspaces resolve against the
# core-only env, so `Base`/`Core` builtins are present stores.

@testsnippet KwIterWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const KI_URI = URI("file:///ki/src/Root.jl")

    function ki_workspace(src::String; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(KI_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    ki_diags(src, code; flag=true) =
        filter(d -> d.code === code, get_diagnostic(ki_workspace(src; flag), KI_URI))
end

@testitem "kw default mismatch: positives" setup=[KwIterWS] begin
    msg = "The default value provided does not match the specified argument type."
    positives = [
        "f(; x::String = 1) = x\n",
        "f(; x::Symbol = \"s\") = x\n",     # a literal never satisfies ::Symbol
        "f(; x::Int = 1.5) = x\n",
        "f(; x::Int = 0x01) = x\n",         # hex literals are unsigned
        "f(; x::Bool = 1) = x\n",
        "f(; x::Char = \"c\") = x\n",
        "f(; x::Float64 = 1) = x\n",
        "f(; x::Float32 = 1.5) = x\n",      # needs the f0 suffix
        "f(; x::UInt16 = 0x01) = x\n",      # 0x01 parses as UInt8
        "f(; x::Int8 = 1) = x\n",           # non-native signed width
        "f(x::String = 1) = x\n",           # positional kw entries count too
    ]
    for src in positives
        ds = ki_diags(src, :kw_default_mismatch)
        @test length(ds) == 1
        @test only(ds).message == msg
    end
    # The range points at the default value.
    src = "f(; x::Int = 1.5) = x\n"
    d = only(ki_diags(src, :kw_default_mismatch))
    @test startswith(src[d.range], "1.5")
end

@testitem "kw default mismatch: negatives" setup=[KwIterWS] begin
    @test isempty(ki_diags("""
    f(; a::String = "s", b::Int = 1, c::Bool = true, d::Char = 'c',
        e::Float64 = 1.5, g::Float32 = 1.5f0, h::UInt8 = 0x01,
        i::UInt16 = 0x0102, j::Symbol = :s, k::Int = -0) = a
    """, :kw_default_mismatch))
    # Non-literal defaults are never checked.
    @test isempty(ki_diags("f(; x::Int = g()) = x\n", :kw_default_mismatch))
    # A same-named workspace type or an alias declines.
    @test isempty(ki_diags("struct Int end\nf(; x::Int = 1.5) = x\n", :kw_default_mismatch))
    @test isempty(ki_diags("const MyInt = Int\nf(; x::MyInt = 1.5) = x\n", :kw_default_mismatch))
    # A where-bound name declines.
    @test isempty(ki_diags("f(; x::T = 1.5) where T = x\n", :kw_default_mismatch))
    # Flag off.
    @test isempty(ki_diags("f(; x::Int = 1.5) = x\n", :kw_default_mismatch; flag=false))
end

@testitem "iter spec: positives" setup=[KwIterWS] begin
    msg = "A loop iterator has been used that will likely error."
    for src in [
        "function f()\n    for i in 5\n    end\nend\n",
        "function f()\n    for i = 1.5\n    end\nend\n",
        "f(v) = [i for i in length(v)]\n",
        "function f(v)\n    for i in length(v)\n    end\nend\n",
        "function f(v)\n    for i in Base.length(v)\n    end\nend\n",
    ]
        ds = ki_diags(src, :incorrect_iter_spec)
        @test length(ds) == 1
        @test only(ds).message == msg
    end
    # Multi-spec loops report the offending spec.
    src = "function f(xs)\n    for i in 1:3, j in 5\n    end\nend\n"
    d = only(ki_diags(src, :incorrect_iter_spec))
    @test startswith(lstrip(src[d.range]), "j in 5")
end

@testitem "iter spec: negatives" setup=[KwIterWS] begin
    @test isempty(ki_diags("""
    function f(xs, v)
        for i in 1:3
        end
        for x in xs
        end
        for i in 1:length(v)
        end
        for i in eachindex(v)
        end
    end
    """, :incorrect_iter_spec))
    # A locally-shadowed `length` declines the whole item.
    @test isempty(ki_diags(
        "function f(length, v)\n    for i in length(v)\n    end\nend\n",
        :incorrect_iter_spec))
    # Quoted code and unknown-macro arguments are data.
    @test isempty(ki_diags("f() = :(for i in 5\nend)\n", :incorrect_iter_spec))
    @test isempty(ki_diags("@somedsl for i in 5\nend\n", :incorrect_iter_spec))
    # Flag off.
    @test isempty(ki_diags("f() = [i for i in 5]\n", :incorrect_iter_spec; flag=false))
end

# Differential: both rules' messages match v1's, count-per-file keyed.
@testitem "v2 kw/iter rules agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    const RULES = (:kw_default_mismatch, :incorrect_iter_spec)

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
    for uri in uris
        for rule in RULES
            n1 = count(f -> f.rule_id === rule,
                       JW.derived_new_static_lint_diagnostics(jw.runtime, uri))
            n2 = count(f -> f.rule_id === rule,
                       JW.derived_semantic_lint_findings(jw.runtime, uri))
            n2 > n1 && push!(v2_only, "$(uri): $(rule) v2=$(n2) v1=$(n1)")
            n1 > n2 && (v1_only[] += n1 - n2)
        end
    end
    println("kw/iter differential: v1_only=$(v1_only[])")
    isempty(v2_only) || println("v2-only findings (false-positive candidates):\n  " *
        join(first(v2_only, 40), "\n  "))
    @test v2_only == String[]
end
