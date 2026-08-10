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
