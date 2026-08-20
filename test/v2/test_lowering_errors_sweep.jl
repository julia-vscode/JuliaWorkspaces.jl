# Lowering-error surfacing (Harvest JuliaLowering): unit tests for the
# `lowering_errors` rule and the corpus sweep that gates it.

@testsnippet LoweringErrWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, update_file!, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    function le_workspace(src; config = "[rules]\nlowering_errors = \"warning\"\n", flag = true)
        jw = JuliaWorkspace()
        config === nothing || add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"), SourceText(config, "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        flag && JW.set_lowering_lint!(jw, true)
        return jw, uri
    end

    le_codes(jw, uri) = [(d.code, d.message) for d in get_diagnostic(jw, uri)]
end

@testitem "lowering_errors: shapes lowering rejects surface with real ranges" setup=[LoweringErrWS] begin
    # Invalid assignment target.
    jw, uri = le_workspace("1 = 2\n")
    diags = [d for d in get_diagnostic(jw, uri) if d.code === :lowering_errors]
    @test length(diags) == 1
    @test diags[1].message == "invalid syntax in left-hand side of assignment"
    @test diags[1].severity === :warning
    src = "1 = 2\n"
    @test src[first(diags[1].range):last(diags[1].range)-1] == "1"

    # try-without-catch is ALSO a JuliaSyntax syntax error, so the double-report
    # guard yields exactly one diagnostic, from the syntax tier.
    jw, uri = le_workspace("f() = try g() end\n")
    codes = le_codes(jw, uri)
    @test any(c -> c[1] === :syntax_errors, codes)
    @test !any(c -> c[1] === :lowering_errors, codes)

    # Duplicate struct field.
    jw, uri = le_workspace("struct S\n    a\n    a\nend\n")
    @test any(c -> c[1] === :lowering_errors && c[2] == "duplicate field name", le_codes(jw, uri))

    # Ambiguous destructuring splat.
    jw, uri = le_workspace("a, b..., c... = f()\n")
    @test any(c -> c[1] === :lowering_errors, le_codes(jw, uri))
end

@testitem "lowering_errors: off by default, gated by flag, opens the gate alone" setup=[LoweringErrWS] begin
    # Default preset: the rule ships :off.
    jw, uri = le_workspace("1 = 2\n"; config=nothing)
    @test !any(c -> c[1] === :lowering_errors, le_codes(jw, uri))

    # Rule on but v2 flag off: nothing.
    jw, uri = le_workspace("1 = 2\n"; flag=false)
    @test !any(c -> c[1] === :lowering_errors, le_codes(jw, uri))

    # lowering_errors alone (all takeover rules off) still opens the gate.
    jw, uri = le_workspace("1 = 2\n";
        config="[rules]\nlowering_errors = \"warning\"\nunused_binding = \"off\"\nunused_function_argument = \"off\"\n")
    @test any(c -> c[1] === :lowering_errors, le_codes(jw, uri))
end

@testitem "lowering_errors: suppressed on files with syntax errors and in test blocks" setup=[LoweringErrWS] begin
    # A broken file lowers recovered trees: only syntax_errors report.
    jw, uri = le_workspace("function broken(\n1 = 2\n")
    codes = le_codes(jw, uri)
    @test any(c -> c[1] === :syntax_errors, codes)
    @test !any(c -> c[1] === :lowering_errors, codes)

    # Test-block items are materialized in a synthetic `let`; module-level
    # constructs inside them are legal for the real macro — silence.
    jw, uri = le_workspace("@testitem \"t\" begin\n    struct Inner end\n    const c = 1\nend\n")
    @test !any(c -> c[1] === :lowering_errors, le_codes(jw, uri))

    # An item nested under a macrocall may be transformed by the macro:
    # `@kwdef` struct field defaults are illegal bare but fine expanded.
    jw, uri = le_workspace("Base.@kwdef struct S\n    a::Int = 1\nend\n")
    @test !any(c -> c[1] === :lowering_errors, le_codes(jw, uri))

    # An item CONTAINING a macrocall loses it to materialization stripping:
    # `function (@main)(args)` must not report "invalid function name".
    jw, uri = le_workspace("function (@main)(args)\n    return 0\nend\n")
    @test !any(c -> c[1] === :lowering_errors, le_codes(jw, uri))
end

@testitem "lowering_errors: findings backdate across position-only edits" setup=[LoweringErrWS] begin
    src = "f() = try g() end\n"
    jw, uri = le_workspace(src)
    skel = JW.derived_v2_file_skeleton(jw.runtime, uri)
    ref = JW.V2ItemRef(uri, skel.items[1].id)
    f1 = JW.derived_item_semantic_findings(jw.runtime, ref)
    @test !isempty(f1)

    update_file!(jw, TextFile(uri, SourceText("# c\n" * src, "julia")))
    f2 = JW.derived_item_semantic_findings(jw.runtime, ref)
    @test isequal(f1, f2)
end

@testitem "lowering_errors: zero findings across the package corpus" setup=[LoweringErrWS] begin
    # The ratchet: this repo lowers cleanly, so any `lowering_errors` finding
    # over the corpus is a false positive of the frame (synthetic
    # materialization, recovery artifacts, …). The allowlist must stay empty —
    # a genuine new divergence gets a fix or a reasoned entry, never silence.
    const EXPECTED_LOWERING_ERROR_FILES = Set{String}()

    root = pkgdir(JuliaWorkspaces)
    files = String[]
    for sub in ("src", "test")
        isdir(joinpath(root, sub)) || continue
        for (d, _, fs) in walkdir(joinpath(root, sub))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") && push!(files, joinpath(d, f))
            end
        end
    end
    @test length(files) > 50

    offenders = Dict{String,Vector{String}}()
    for f in files
        src = try
            read(f, String)
        catch
            continue
        end
        rel = relpath(f, root)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
            SourceText("[rules]\nlowering_errors = \"warning\"\n", "toml")))
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        JW.set_lowering_lint!(jw, true)
        msgs = [d.message for d in get_diagnostic(jw, uri) if d.code === :lowering_errors]
        isempty(msgs) || (offenders[rel] = msgs)
    end

    unexpected = setdiff(keys(offenders), EXPECTED_LOWERING_ERROR_FILES)
    isempty(unexpected) || println("Unexpected lowering_errors:\n  " *
        join(("$k: $(offenders[k])" for k in unexpected), "\n  "))
    @test isempty(unexpected)
    @test issubset(EXPECTED_LOWERING_ERROR_FILES, keys(offenders))   # ratchet
end
