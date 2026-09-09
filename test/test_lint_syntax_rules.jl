# Tests for the purely syntactic lint rules (src/lint_syntax_rules.jl).

@testitem "Syntax rules: off by default, on in strict" begin
    using JuliaWorkspaces.URIs2: URI

    source = "check(x) = x == NaN\n"

    # No config: the rules are `:off` in the default preset and report nothing.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/src/a.jl"), SourceText(source, "julia")))
    @test !any(d -> d.code === :nan_comparison, get_diagnostic(jw, URI("file:///pr/src/a.jl")))

    # The strict preset switches them on as warnings.
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///pr/src/a.jl"), SourceText(source, "julia")))
    diags = filter(d -> d.code === :nan_comparison, get_diagnostic(jw, URI("file:///pr/src/a.jl")))
    @test length(diags) == 1
    @test diags[1].severity === :warning
end

@testitem "Syntax rules: nan_comparison flags ==/!= against NaN, not isnan or ===" begin
    using JuliaWorkspaces.URIs2: URI

    function nan_diags(source)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nnan_comparison = \"error\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :nan_comparison, get_diagnostic(jw, uri))
    end

    # Positive cases: infix, reversed operands, `!=`, unicode `≠`, prefix call
    # form, broadcast, chained comparison, and the sized NaN variants.
    @test length(nan_diags("f(x) = x == NaN")) == 1
    @test length(nan_diags("f(x) = NaN == x")) == 1
    @test length(nan_diags("f(x) = x != NaN")) == 1
    @test length(nan_diags("f(x) = x ≠ NaN")) == 1
    @test length(nan_diags("f(x) = ==(x, NaN)")) == 1
    @test length(nan_diags("f(x) = x .== NaN")) == 1
    @test length(nan_diags("f(x, y) = x == y == NaN")) == 1
    @test length(nan_diags("f(x) = x == NaN32")) == 1
    @test length(nan_diags("f(x) = x == NaN16")) == 1

    # The range covers the whole comparison.
    d = nan_diags("f(x) = x == NaN")[1]
    @test "f(x) = x == NaN"[first(d.range):last(d.range)-1] == "x == NaN"
    @test d.severity === :error
    @test occursin("isnan", d.message)

    # Negative cases: the correct idiom, identity comparison (a legitimate
    # bit-pattern test), ordering comparisons (always false but a different
    # rule's business), NaN as an ordinary value, and unrelated identifiers.
    @test isempty(nan_diags("f(x) = isnan(x)"))
    @test isempty(nan_diags("f(x) = x === NaN"))
    @test isempty(nan_diags("f(x) = x < NaN"))
    @test isempty(nan_diags("f(x) = x == Nan"))
    @test isempty(nan_diags("f() = [NaN, NaN]"))
    @test isempty(nan_diags("f(NaN) = 1"))
end

@testitem "Syntax rules: duplicate_branch_condition on identical if/elseif conditions" begin
    using JuliaWorkspaces.URIs2: URI

    function dup_diags(source)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nduplicate_branch_condition = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :duplicate_branch_condition, get_diagnostic(jw, uri))
    end

    # The basic dead branch.
    src = """
    function f(a)
        if a > 1
            1
        elseif a > 1
            2
        end
    end
    """
    ds = dup_diags(src)
    @test length(ds) == 1
    @test src[first(ds[1].range):last(ds[1].range)-1] == "a > 1"
    # It reports the LATER, unreachable condition.
    @test first(ds[1].range) > findfirst("elseif", src)[1]

    # Whitespace differences don't defeat the structural comparison.
    @test length(dup_diags("f(a) = if a>1; 1; elseif a > 1; 2; end")) == 1

    # A duplicate deeper in a longer chain, compared against ALL earlier
    # conditions, not just the immediately preceding one.
    @test length(dup_diags("f(a) = if a == 1; 1; elseif a == 2; 2; elseif a == 1; 3; end")) == 1

    # Complex but side-effect-free conditions are compared: boolean structure,
    # field access, indexing.
    @test length(dup_diags("f(a, b) = if a.x > 1 && b[2] < 3; 1; elseif a.x > 1 && b[2] < 3; 2; end")) == 1

    # Distinct conditions are fine.
    @test isempty(dup_diags("f(a) = if a > 1; 1; elseif a > 2; 2; else; 3; end"))
    @test isempty(dup_diags("f(a, b) = if a > 1; 1; elseif b > 1; 2; end"))

    # Conditions containing arbitrary calls or macros can legitimately repeat
    # (each evaluation may differ), so they are never reported.
    @test isempty(dup_diags("f() = if rand() < 0.5; 1; elseif rand() < 0.5; 2; end"))
    @test isempty(dup_diags("f(c) = if isready(c); 1; elseif isready(c); 2; end"))
    @test isempty(dup_diags("f() = if @isdefined(x); 1; elseif @isdefined(x); 2; end"))

    # Separate `if` statements are unrelated chains.
    @test isempty(dup_diags("""
    function f(a)
        if a > 1
            1
        end
        if a > 1
            2
        end
    end
    """))
end

@testitem "Syntax rules: string_concat_style flags string-literal concatenation" begin
    using JuliaWorkspaces.URIs2: URI

    function rule_diags(rule, source)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\n$rule = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === Symbol(rule), get_diagnostic(jw, uri))
    end

    @test length(rule_diags("string_concat_style", "f(x) = \"a\" * x")) == 1
    @test length(rule_diags("string_concat_style", "f(x) = x * \"b\"")) == 1
    @test length(rule_diags("string_concat_style", "f(x, y) = x * \"b\" * y")) == 1
    @test length(rule_diags("string_concat_style", "f(x) = *(x, \"b\")")) == 1

    # No literal involved: could be numeric multiplication — never reported.
    @test isempty(rule_diags("string_concat_style", "f(x, y) = x * y"))
    @test isempty(rule_diags("string_concat_style", "f(x) = 2 * x"))
    # Other operators on strings are not this rule's business.
    @test isempty(rule_diags("string_concat_style", "f(x) = \"a\" ^ 3"))
end

@testitem "Syntax rules: bare_using flags module-only using, not name lists" begin
    using JuliaWorkspaces.URIs2: URI

    function rule_diags(source)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nbare_using = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === :bare_using, get_diagnostic(jw, uri))
    end

    @test length(rule_diags("using Foo")) == 1
    @test length(rule_diags("using Foo.Bar")) == 1
    @test length(rule_diags("using ..Rel")) == 1
    # One finding per bare module, so both are individually actionable.
    @test length(rule_diags("using Foo, Bar")) == 2

    # The range covers the module path, not the whole statement.
    d = rule_diags("using Foo, Bar")
    src = "using Foo, Bar"
    @test src[first(d[1].range):last(d[1].range)-1] == "Foo"
    @test src[first(d[2].range):last(d[2].range)-1] == "Bar"

    # Explicit name lists and imports are the recommended forms.
    @test isempty(rule_diags("using Foo: x"))
    @test isempty(rule_diags("using Foo: x, y"))
    @test isempty(rule_diags("import Foo"))
end

@testitem "Syntax rules: debug_statement and async_task flag their macros" begin
    using JuliaWorkspaces.URIs2: URI

    function rule_diags(rule, source)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\n$rule = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        return filter(d -> d.code === Symbol(rule), get_diagnostic(jw, uri))
    end

    @test length(rule_diags("debug_statement", "f(x) = @show x")) == 1
    @test length(rule_diags("debug_statement", "f(x) = Base.@show x")) == 1
    @test isempty(rule_diags("debug_statement", "f(x) = @info x"))
    # `@showprogress` etc. are different macros.
    @test isempty(rule_diags("debug_statement", "f(x) = @showtime x"))

    @test length(rule_diags("async_task", "f() = @async g()")) == 1
    @test isempty(rule_diags("async_task", "f() = Threads.@spawn g()"))
    @test isempty(rule_diags("async_task", "f() = @sync g()"))
end

@testitem "Syntax rules: severity-only config edit does not re-run the walk" begin
    using JuliaWorkspaces.URIs2: URI

    # The enabled-rule set is its own derived query precisely so that a config
    # edit that changes a severity (but not which rules are on) leaves it
    # unchanged and lets Salsa backdate: the parse + walk in
    # `derived_syntax_lint_findings` must produce identical findings, and only
    # materialization in `derived_diagnostics` changes.
    jw = JuliaWorkspace()
    config_uri = URI("file:///pr/JuliaLint.toml")
    add_file!(jw, TextFile(config_uri, SourceText("[rules]\nnan_comparison = \"warning\"\n", "toml")))
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText("f(x) = x == NaN", "julia")))

    d1 = filter(d -> d.code === :nan_comparison, get_diagnostic(jw, uri))
    @test length(d1) == 1
    @test d1[1].severity === :warning

    JuliaWorkspaces.update_file!(jw, TextFile(config_uri, SourceText("[rules]\nnan_comparison = \"error\"\n", "toml")))

    d2 = filter(d -> d.code === :nan_comparison, get_diagnostic(jw, uri))
    @test length(d2) == 1
    @test d2[1].severity === :error
end

@testitem "Syntax rules: fused parse runs every check, config filters" begin
    using JuliaWorkspaces.URIs2: URI
    const JW = JuliaWorkspaces

    # The fused parse (`derived_julia_parse_products`) runs ALL syntax checks
    # unconditionally, so its findings are independent of the lint config; the
    # enabled set is applied as a filter in `derived_syntax_lint_findings`.
    jw = JuliaWorkspace()
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText("f(x) = x == NaN\ng() = @async h()\n", "julia")))

    # No config at all: the unfiltered findings still contain both rules...
    all_findings = JW.derived_all_syntax_lint_findings(jw.runtime, uri)
    @test Set(f.rule_id for f in all_findings) == Set([:nan_comparison, :async_task])

    # ...while the filtered query reports nothing (both rules default to off).
    @test isempty(JW.derived_syntax_lint_findings(jw.runtime, uri))

    # Enabling one rule surfaces exactly that one.
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
        SourceText("[rules]\nnan_comparison = \"error\"\n", "toml")))
    filtered = JW.derived_syntax_lint_findings(jw.runtime, uri)
    @test [f.rule_id for f in filtered] == [:nan_comparison]

    # And the test-detail product comes out of the same parse: this file has
    # no test items, so the raw details are empty rather than missing.
    raw = JW.derived_raw_test_details(jw.runtime, uri)
    @test isempty(raw.testitems) && isempty(raw.testsetups) && isempty(raw.testerrors)
end

@testitem "Syntax rules: unbound_type_parameter core positives and negatives" begin
    using JuliaWorkspaces.URIs2: URI

    function utp_diags(source)
        jw = JuliaWorkspace()
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

@testitem "Syntax rules: unbound_type_parameter forms, kwargs, defaults, chains" begin
    using JuliaWorkspaces.URIs2: URI

    function utp_diags(source)
        jw = JuliaWorkspace()
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

@testitem "Syntax rules: unbound_type_parameter off by default, on in strict" begin
    using JuliaWorkspaces.URIs2: URI

    source = "f(x::T...) where T = 1\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/src/a.jl"), SourceText(source, "julia")))
    @test !any(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, URI("file:///pr/src/a.jl")))

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///pr/src/a.jl"), SourceText(source, "julia")))
    diags = filter(d -> d.code === :unbound_type_parameter, get_diagnostic(jw, URI("file:///pr/src/a.jl")))
    @test length(diags) == 1
    @test diags[1].severity === :warning
end
