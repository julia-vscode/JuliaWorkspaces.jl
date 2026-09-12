# unbound_type_parameter (Aqua.jl `test_unbound_args` parity). The rule is
# v2-only — its producer is joined only in `derived_diagnostics_v2`
# (src/v2/bridge/lint_unbound_type_parameter_v2.jl) — so every item here turns
# the flag on, and the preset item pins that the rule emits nothing flag-off
# even under `strict`.

@testitem "unbound_type_parameter: core positives and negatives" begin
    using JuliaWorkspaces.URIs2: URI

    function utp_diags(source)
        jw = JuliaWorkspace()
        set_v2_enabled!(jw, true)
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nunbound_type_parameter = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, uri))
    end

    # The classic: a trailing vararg's element type is unbound for the empty
    # call. Verified against Test.detect_unbound_args on Julia 1.12.
    @test length(utp_diags("f(x::T...) where T = 1")) == 1
    @test length(utp_diags("f(x::Int, y::T...) where T = 1")) == 1
    @test isempty(utp_diags("f(x::T, y::T...) where T = 1"))

    # The range points at the parameter in the where clause.
    src = "f(x::T...) where T = 1"
    d = only(utp_diags(src))
    @test src[first(d.range):last(d.range)-1] == "T"
    @test first(d.range) > findfirst("where", src)[1]
    @test occursin("`T`", d.message)

    # Direct and invariant-parameter binding.
    @test isempty(utp_diags("f(x::T) where T = 1"))
    @test isempty(utp_diags("f(x::Vector{T}) where T = 1"))
    @test isempty(utp_diags("f(x::Vector{Vector{T}}) where T = 1"))
    @test isempty(utp_diags("f(x::AbstractArray{T,2}) where T = 1"))
    @test isempty(utp_diags("f(x::Base.RefValue{T}) where T = 1"))
    @test isempty(utp_diags("f(::Type{T}) where T = 1"))
    @test isempty(utp_diags("f(x::Val{T}) where T = 1"))

    # A `<:` upper bound binds covariantly (top level of an argument) but not
    # under an invariant parameter.
    @test isempty(utp_diags("f(x::Vector{<:T}) where T = 1"))
    @test isempty(utp_diags("f(x::Base.RefValue{<:AbstractVector{T}}) where T = 1"))
    @test length(utp_diags("f(x::Ref{Vector{<:T}}) where T = 1")) == 1

    # Union binds only when every branch binds.
    @test length(utp_diags("f(x::Union{Int,T}) where T = 1")) == 1
    @test isempty(utp_diags("f(x::Union{Vector{T},Ref{T}}) where T = 1"))

    # Tuples are covariant; a trailing Vararg element type does not bind, its
    # length `N` does.
    @test isempty(utp_diags("f(x::Tuple{T}) where T = 1"))
    @test isempty(utp_diags("f(x::Tuple{Vector{<:T}}) where T = 1"))
    @test length(utp_diags("f(x::Tuple{Vararg{T}}) where T = 1")) == 1
    @test length(utp_diags("f(x::Type{Tuple{Vararg{E}}}) where E = 1")) == 1
    @test length(utp_diags("_totuple(::Type{Tuple{Vararg{E}}}, itr, s...) where {E} = E")) == 1
    @test isempty(utp_diags("f(x::NTuple{N,Int}) where N = 1"))

    # `Vararg{T,N}` as the last argument: `N` binds, `T` does not.
    ds = utp_diags("f(x::Vararg{T,N}) where {T,N} = 1")
    @test length(ds) == 1
    @test occursin("`T`", ds[1].message)
end

@testitem "unbound_type_parameter: forms, kwargs, defaults, chains" begin
    using JuliaWorkspaces.URIs2: URI

    function utp_diags(source)
        jw = JuliaWorkspace()
        set_v2_enabled!(jw, true)
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nunbound_type_parameter = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, uri))
    end

    # Long form, callable objects, constructors, macro-wrapped definitions.
    @test length(utp_diags("function f(x::T...) where T\n    1\nend")) == 1
    @test isempty(utp_diags("function (o::CO{T})(x) where T\n    1\nend"))
    @test isempty(utp_diags("Foo{T}(x::T) where T = 1"))
    @test isempty(utp_diags("Foo{T}(x) where T = 1"))
    @test length(utp_diags("@inline f(x::T...) where T = 1")) == 1

    # A return-type annotation does not bind (the long form; in the short form
    # `f(x)::T where T = 1` the `where` belongs to the return type and there is
    # no method type parameter at all).
    @test length(utp_diags("function f(x)::T where T\n    return one(T)\nend")) == 1

    # Keyword argument types bind — lowering passes them positionally to the
    # keyword-body method (verified against Test.detect_unbound_args).
    @test isempty(utp_diags("f(x; y::T = 1) where T = 2"))
    @test length(utp_diags("f(x; y::Ref{Vector{<:T}} = Ref([[1]])) where T = 2")) == 1

    # Defaults do not unbind: the generated shorter methods drop the unused
    # type parameter entirely.
    @test isempty(utp_diags("f(x::T = 1) where T = 2"))
    @test isempty(utp_diags("f(x = 1, y::T = 2) where T = 2"))

    # A later parameter's upper bound binds an earlier one covariantly.
    @test isempty(utp_diags("f(x::S) where {T, S<:AbstractVector{T}} = 1"))
    @test isempty(utp_diags("f(x::(Vector{S} where S<:T)) where T = 1"))

    # Bounds on the parameter itself change nothing about bindedness; lower
    # bounds never bind.
    @test isempty(utp_diags("f(x::T) where {T<:Integer} = 1"))
    @test isempty(utp_diags("f(x::T) where Int<:T<:Real = 1"))
    @test length(utp_diags("f(x::S...) where {S>:Int} = 1")) == 1

    # Nested wheres.
    @test length(utp_diags("f(x::T, y::S...) where S where T = 1")) == 1

    # A parameter that is never mentioned again is unused_type_parameter's
    # finding, not this rule's.
    @test isempty(utp_diags("f(x) where T = 1"))
    @test isempty(utp_diags("function f(x) where T\n    1\nend"))
    # ... but one used in the body (or a non-binding position) is reported.
    @test length(utp_diags("f(x) where T = T[]")) == 1

    # Type expressions the model cannot interpret suppress the finding.
    @test isempty(utp_diags("f(x::my_type(T)) where T = 1"))
    @test isempty(utp_diags("f(x::@NamedTuple{a::T}) where T = 1"))

    # Anonymous functions and structs have no method where clause to check.
    @test isempty(utp_diags("struct Foo{T} end"))
    @test isempty(utp_diags("g = x -> x"))

    # Multiple parameters report individually.
    ds = utp_diags("f(x::T2, y::T3...) where {T1, T2, T3} = T1")
    @test length(ds) == 2
    @test any(d -> occursin("`T1`", d.message), ds)
    @test any(d -> occursin("`T3`", d.message), ds)
end

@testitem "unbound_type_parameter: off by default, on in strict, silent flag-off" begin
    using JuliaWorkspaces.URIs2: URI

    source = "f(x::T...) where T = 1\n"
    uri = URI("file:///pr/src/a.jl")

    # Default preset: off, even with the flag on.
    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    @test !any(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, uri))

    # Strict preset with the flag on: a warning.
    jw = JuliaWorkspace()
    set_v2_enabled!(jw, true)
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    diags = filter(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, uri))
    @test length(diags) == 1
    @test diags[1].severity === :warning

    # Flag off, the rule is v2-only: strict emits nothing for it.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))
    @test !any(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, uri))
end
