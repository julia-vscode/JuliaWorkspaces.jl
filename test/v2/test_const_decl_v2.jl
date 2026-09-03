# v2 intra-module `const_decl` (lint_lowering_rules.jl): declaration
# conflicts from the module tree's ordered decl-event stream — whole-module,
# so cross-file redefinitions are new coverage over v1's scope-local check.

@testsnippet ConstDeclV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    cd_uri(name) = filepath2uri(joinpath(Sys.iswindows() ? "C:\\cd\\src" : "/cd/src", name))
    const CD_ROOT = cd_uri("Root.jl")

    function cd_workspace(files::Pair{String,String}...; flag=true, config=nothing)
        jw = JuliaWorkspace()
        config !== nothing && add_file!(jw, TextFile(
            filepath2uri(joinpath(Sys.iswindows() ? "C:\\cd" : "/cd", "JuliaLint.toml")),
            SourceText(config, "toml")))
        for (name, src) in files
            add_file!(jw, TextFile(cd_uri(name), SourceText(src, "julia")))
        end
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    cd_diags(jw; uri=CD_ROOT) =
        filter(d -> d.code === :const_decl, get_diagnostic(jw, uri))
end

@testitem "v2 const_decl: the three arms" setup=[ConstDeclV2WS] begin
    # A const re-declared.
    jw = cd_workspace("Root.jl" => "const x = 1\nconst x = 2\n")
    d = only(cd_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test d.message == "Cannot declare constant `x`; it already has a value."

    # A const over a plain assignment, and a datatype over an assignment.
    jw = cd_workspace("Root.jl" => "x = 1\nconst x = 2\n")
    @test occursin("Cannot declare constant `x`", only(cd_diags(jw)).message)
    jw = cd_workspace("Root.jl" => "T = 1\nstruct T end\n")
    @test occursin("Cannot declare constant `T`", only(cd_diags(jw)).message)

    # Reassigning a const / a datatype.
    jw = cd_workspace("Root.jl" => "const x = 1\nx = 2\n")
    @test only(cd_diags(jw)).message == "Invalid redefinition of constant `x`."
    jw = cd_workspace("Root.jl" => "struct T end\nT = 2\n")
    @test only(cd_diags(jw)).message == "Invalid redefinition of constant `T`."

    # A function over a plain value.
    jw = cd_workspace("Root.jl" => "x = 1\nfunction x() end\n")
    @test only(cd_diags(jw)).message == "Cannot define function `x`; it already has a value."
end

@testitem "v2 const_decl: exemptions stay silent" setup=[ConstDeclV2WS] begin
    # Method extension over a datatype; separate methods; const holding a
    # function later extended-by-name is silent (v1's type check, widened).
    jw = cd_workspace("Root.jl" => """
    struct T end
    T(v) = 1
    f() = 1
    f(x) = 2
    const g = identity
    """)
    @test isempty(cd_diags(jw))

    # `@static if` platform-const idiom and plain if branches.
    jw = cd_workspace("Root.jl" => """
    @static if Sys.iswindows()
        const SEP = ';'
    else
        const SEP = ':'
    end
    if VERSION >= v"1.9"
        const NEWISH = true
    else
        const NEWISH = false
    end
    """)
    @test isempty(cd_diags(jw))

    # The same definition twice (identical body).
    jw = cd_workspace("Root.jl" => "const x = 1\nconst x = 1\n")
    @test isempty(cd_diags(jw))

    # Function reassignment matches v1 (silent), as does assignment-over-assignment.
    jw = cd_workspace("Root.jl" => "f() = 1\nf = 2\nx = 1\nx = 2\n")
    @test isempty(cd_diags(jw))
end

@testitem "v2 const_decl: corpus FP classes stay silent" setup=[ConstDeclV2WS] begin
    # `const f(::Type{T}) = …` defines a METHOD; a second one adds a method,
    # never redeclares a constant (the SLEEFPirates idiom, 14/25 of the
    # sweep's sampled const_decl FPs).
    jw = cd_workspace("Root.jl" => """
    const vrange(::Type{Float64}) = 1.0
    const vrange(::Type{Float32}) = 1.0f0
    """)
    @test isempty(cd_diags(jw))

    # Callable-object methods bind no module-level name: the signature's `a`
    # is the instance parameter, not a declaration colliding with a real `a`.
    jw = cd_workspace("Root.jl" => """
    struct Dense end
    a = 1
    function (a::Dense)(x)
        return x
    end
    """)
    @test isempty(cd_diags(jw))
    jw = cd_workspace("Root.jl" => """
    struct Shift end
    (D::Shift)(x) = x
    const D = Shift()
    """)
    @test isempty(cd_diags(jw))

    # Includes inside mutually exclusive `@static if` branches: only one
    # branch's file ever runs, so their declarations must not pair.
    jw = cd_workspace(
        "Root.jl" => "@static if Sys.iswindows()\n    include(\"win.jl\")\nelse\n    include(\"unix.jl\")\nend\n",
        "win.jl" => "const backend = :win\n",
        "unix.jl" => "const backend = :unix\n")
    @test isempty(cd_diags(jw))
    @test isempty(cd_diags(jw; uri=cd_uri("win.jl")))
    @test isempty(cd_diags(jw; uri=cd_uri("unix.jl")))
end

@testitem "v2 const_decl: cross-file conflicts in one module" setup=[ConstDeclV2WS] begin
    jw = cd_workspace(
        "Root.jl" => "module M\nconst x = 1\ninclude(\"other.jl\")\nend\n",
        "other.jl" => "x = 2\n")
    # The finding sits in the file with the offending declaration.
    @test isempty(cd_diags(jw))
    d = only(cd_diags(jw; uri=cd_uri("other.jl")))
    @test d.message == "Invalid redefinition of constant `x`."
end

@testitem "v2 const_decl: local shapes surface as lowering_errors instead" setup=[ConstDeclV2WS] begin
    # `const` on a local and value-then-function inside one body are the
    # per-item lowering's territory, at :error — not this rule's.
    jw = cd_workspace("Root.jl" => "function f()\n    const y = 1\n    return y\nend\n")
    @test isempty(cd_diags(jw))
    @test !isempty(filter(d -> d.code === :lowering_errors, JuliaWorkspaces.get_diagnostic(jw, CD_ROOT)))
end

@testitem "v2 const_decl: takeover, flag, and config" setup=[ConstDeclV2WS] begin
    # Flag on: only the v2 producer reports.
    jw = cd_workspace("Root.jl" => "const x = 1\nx = 2\n")
    @test all(d -> d.source == "JuliaWorkspaces.jl", cd_diags(jw))
    # Flag off: nothing from v2.
    jw = cd_workspace("Root.jl" => "const x = 1\nx = 2\n"; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl", cd_diags(jw))
    # Rule off.
    jw = cd_workspace("Root.jl" => "const x = 1\nx = 2\n";
        config="[rules]\nconst_decl = \"off\"\n")
    @test isempty(cd_diags(jw))
end

@testitem "v2 const_decl: constructor methods on parametric aliases" setup=[ConstDeclV2WS] begin
    # A parametric type alias plus a constructor method on it — legal
    # (RandomExtensions' MakeN family), not "already has a value".
    jw = cd_workspace("Root.jl" => """
    struct Make{T,X} end
    Make0{T} = Make{T,Tuple{}}
    Make1{T} = Make{T,Tuple{X}} where X
    Make0{T}() where {T} = Make{T,Tuple{}}()
    Make1{T}(x) where {T} = Make{T,Tuple{typeof(x)}}()
    """)
    @test isempty(cd_diags(jw))
end
