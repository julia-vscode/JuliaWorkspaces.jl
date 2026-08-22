# The signature rules takeover: `type_piracy` (NotEqDef + import-then-extend)
# and `invalid_type_declaration` (lint_lowering_rules.jl). Projectless
# workspaces are env-ready and resolve against the core-only env.

@testsnippet SigRulesWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI

    const SR_URI = URI("file:///sr/src/Root.jl")

    function sr_workspace(src::String; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(SR_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    sr_diags(src, code; flag=true) =
        filter(d -> d.code === code, get_diagnostic(sr_workspace(src; flag), SR_URI))
end

@testitem "sig rules: NotEqDef" setup=[SigRulesWS] begin
    for src in ("!=(a, b) = true\n", "Base.:!=(a, b) = true\n",
                "function !=(a, b)\n    true\nend\n")
        ds = sr_diags(src, :type_piracy)
        @test length(ds) == 1
        @test occursin("Overload `==` instead", only(ds).message)
    end
    @test isempty(sr_diags("==(a, b) = true\n", :type_piracy))
end

@testitem "sig rules: type piracy" setup=[SigRulesWS] begin
    # Extending an imported external function with only external types.
    src = "import Base: push!\npush!(x::Vector, y::Int, z::Int) = x\n"
    d = only(sr_diags(src, :type_piracy))
    @test d.message ==
        "An imported function has been extended without using module defined typed arguments."
    @test d.source == "JuliaWorkspaces.jl"
    # Untyped arguments are piracy too (v1 parity).
    @test !isempty(sr_diags("import Base: push!\npush!(v, x, y, z) = v\n", :type_piracy))
    # The `import Base.push!` whole-path form counts as an import binding.
    @test !isempty(sr_diags("import Base.push!\npush!(v, x, y, z) = v\n", :type_piracy))

    # A workspace-owned argument type exempts the method.
    @test isempty(sr_diags(
        "import Base: push!\nstruct T end\npush!(x::Vector, y::T) = x\n", :type_piracy))
    # ...also inside curly parameters.
    @test isempty(sr_diags(
        "import Base: push!\nstruct T end\npush!(x::Vector{T}, y) = x\n", :type_piracy))
    # A where-bound typevar counts as owned (v1's Binding test).
    @test isempty(sr_diags(
        "import Base: push!\npush!(x::Vector, y::T) where T = x\n", :type_piracy))
    # An unresolvable type name declines the whole definition.
    @test isempty(sr_diags(
        "import Base: push!\npush!(x::Vector, y::Unknowable) = x\n", :type_piracy))
    # A plain new function (nothing imported) is not piracy.
    @test isempty(sr_diags("mine(x::Vector, y::Int) = x\n", :type_piracy))
    # Flag off: nothing.
    @test isempty(sr_diags("import Base: push!\npush!(v, x, y, z) = v\n", :type_piracy;
                           flag=false))
end

@testitem "sig rules: invalid type declaration" setup=[SigRulesWS] begin
    msg = "A non-DataType has been used in a type declaration statement."
    # A literal in type position.
    @test only(sr_diags("f(x::1) = x\n", :invalid_type_declaration)).message == msg
    # A workspace function used as a type.
    @test !isempty(sr_diags("g() = 1\nf(x::g) = x\n", :invalid_type_declaration))
    # An external non-datatype (Base function; the seam's `:datatype` widening
    # is what keeps `Int` silent).
    @test !isempty(sr_diags("f(x::sin) = x\n", :invalid_type_declaration))
    @test !isempty(sr_diags("f(x::Base.sin) = x\n", :invalid_type_declaration))
    # Real types — workspace and external, qualified included — are silent.
    @test isempty(sr_diags("""
    struct T end
    abstract type A end
    f(x::T, y::A, z::Int, w::Base.Int, v::AbstractString) = x
    g(x::Vector{Int}) = x
    h(x::T2) where T2 = x
    """, :invalid_type_declaration))
    # Keyword arguments are covered.
    @test !isempty(sr_diags("g() = 1\nf(; x::g = 1) = x\n", :invalid_type_declaration))
    @test isempty(sr_diags("f(; x::Int = 1) = x\n", :invalid_type_declaration))
    # Alias chains decline.
    @test isempty(sr_diags("const MyInt = Int\nf(x::MyInt) = x\n", :invalid_type_declaration))
    # The range points at the declaration (map ranges may keep trailing
    # trivia).
    src = "f(x::1) = x\n"
    d = only(sr_diags(src, :invalid_type_declaration))
    @test startswith(src[d.range], "x::1")
end

# Differential over the repo corpus: both rules' messages match v1's, so the
# key is (rule, count) per file. Zero-v2-only hard gate; v1-only residue
# (nested defs, alias-chain arms, unresolvable-name piracy) printed for review.
@testitem "v2 sig rules agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    const RULES = (:type_piracy, :invalid_type_declaration)

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
    println("sig-rules differential: v1_only=$(v1_only[])")
    isempty(v2_only) || println("v2-only findings (false-positive candidates):\n  " *
        join(first(v2_only, 40), "\n  "))
    @test v2_only == String[]
end
