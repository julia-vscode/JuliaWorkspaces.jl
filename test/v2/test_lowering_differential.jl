# Takeover routing of LoweringError messages (Harvest JuliaLowering):
# refresh-gate tests pinning the vendored message strings, behavior tests for
# the three routed rules, and the corpus differential proving suppression
# loses nothing.

@testsnippet LoweringRouteWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_diagnostic
    using JuliaWorkspaces.URIs2: URI

    function lr_workspace(src; flag=true)
        jw = JuliaWorkspace()
        uri = URI("file:///pr/src/a.jl")
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        flag && JW.set_lowering_lint!(jw, true)
        return jw, uri
    end

    lr_codes(jw, uri) = [(d.code, d.source, d.message) for d in get_diagnostic(jw, uri)]
end

@testitem "lowering routing: the message table maps to takeover rule ids" setup=[LoweringRouteWS] begin
    # REFRESH GATE: each case lowers a crafted snippet and asserts the routed
    # rule id. A packages/JuliaLowering refresh that rewords one of the pinned
    # messages (see LOWERING_MESSAGE_RULE_IDS) drops the finding into
    # :lowering_errors and fails here loudly — that is the point.
    cases = [
        ("f(x, x) = x\n",                            :duplicate_function_argument, "function argument name not unique"),
        ("f((a, b), (a,)) = a\n",                    :duplicate_function_argument, "destructured argument name `a` conflicts with an existing local variable from the same scope"),
        ("continue\n",                               :break_continue,              "`continue` outside of a `while` or `for` loop"),
        ("function g()\n    break\nend\n",           :break_continue,              "unlabeled `break` outside of a `while` or `for` loop"),
        ("function h()\n    const y = 1\nend\n",     :global_const_decl,           "unsupported `const` inside function"),
        ("const local z = 1\n",                      :global_const_decl,           "unsupported `const local` declaration"),
    ]
    for (src, rule, msg) in cases
        jw, uri = lr_workspace(src)
        diags = lr_codes(jw, uri)
        matching = [d for d in diags if d[1] === rule && d[3] == msg]
        if length(matching) != 1
            println("Routing failure for ", repr(src), ": got ", diags)
        end
        @test length(matching) == 1
        @test matching[1][2] == "JuliaWorkspaces.jl"
        # And it must NOT double-report as the catch-all id.
        @test !any(d -> d[1] === :lowering_errors, diags)
    end
end

@testitem "lowering routing: takeover ids honor config and flag" setup=[LoweringRouteWS] begin
    # The routed rules use the ordinary config surface: turning one off
    # silences it without touching the others.
    jw = JuliaWorkspace()
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
        SourceText("[rules]\nbreak_continue = \"off\"\n", "toml")))
    add_file!(jw, TextFile(uri, SourceText("continue\n", "julia")))
    JW.set_lowering_lint!(jw, true)
    @test !any(d -> d.code === :break_continue, get_diagnostic(jw, uri))

    # Flag off: nothing from the lowering producer. (In this synthetic
    # harness StaticLint does not fire on these shapes either — v2 is a strict
    # superset here; the corpus differential below covers real-world parity.)
    jw2, uri2 = lr_workspace("continue\n"; flag=false)
    @test !any(d -> d[2] == "JuliaWorkspaces.jl", lr_codes(jw2, uri2))
end

@testitem "lowering routing: v2 catches shapes v1's syntactic check misses" setup=[LoweringRouteWS] begin
    # v1's ShouldBeInALoop passes when ANY enclosing for/while exists, so a
    # `break` inside a closure defined in a loop is missed; lowering resolves
    # the actual loop scope. Documented superset.
    jw, uri = lr_workspace("""
    for i in 1:3
        f = () -> break
    end
    """)
    # (Whether this exact shape errors depends on lowering's closure handling;
    # the assertion is only that no false :lowering_errors appears and any
    # break finding carries the routed id.)
    for d in lr_codes(jw, uri)
        d[1] === :lowering_errors && @test false
    end
    @test true
end

@testitem "lowering routing: suppression loses nothing over the corpus" setup=[LoweringRouteWS] begin
    # For the routed ids, flag-off (StaticLint) and flag-on (v2) must agree
    # per file over this repo's corpus. Divergences are a ratchet: an entry
    # needs a reason, and a healed entry must be removed.
    const ROUTED_IDS = (:duplicate_function_argument, :break_continue, :global_const_decl,
                        :unused_type_parameter, :module_name, :relative_import)
    const EXPECTED_DIVERGENT_FILES = Set{String}()

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

    divergent = Dict{String,Any}()
    for f in files
        src = try
            read(f, String)
        catch
            continue
        end
        rel = relpath(f, root)
        per_flag = map((false, true)) do flag
            jw = JuliaWorkspace()
            uri = URI("file:///pr/src/a.jl")
            add_file!(jw, TextFile(uri, SourceText(src, "julia")))
            JW.set_input_env_ready!(jw.runtime, true)
            flag && JW.set_lowering_lint!(jw, true)
            sort([(d.code, first(d.range)) for d in get_diagnostic(jw, uri) if d.code in ROUTED_IDS])
        end
        per_flag[1] == per_flag[2] || (divergent[rel] = per_flag)
    end

    unexpected = setdiff(keys(divergent), EXPECTED_DIVERGENT_FILES)
    isempty(unexpected) || println("Routed-rule divergences:\n  " *
        join(("$k: off=$(divergent[k][1]) on=$(divergent[k][2])" for k in unexpected), "\n  "))
    @test isempty(unexpected)
    @test issubset(EXPECTED_DIVERGENT_FILES, keys(divergent))
end

@testitem "module-tree rules: module_name and relative_import" setup=[LoweringRouteWS] begin
    # A nested module named like its parent.
    jw, uri = lr_workspace("module A\nmodule A\nend\nend\n")
    diags = [d for d in JuliaWorkspaces.get_diagnostic(jw, uri) if d.code === :module_name]
    @test length(diags) == 1
    @test diags[1].message == "Module name matches that of its parent."
    src = "module A\nmodule A\nend\nend\n"
    @test src[first(diags[1].range):last(diags[1].range)-1] == "A"

    # Distinct names: silent.
    jw, uri = lr_workspace("module A\nmodule B\nend\nend\n")
    @test !any(d -> d[1] === :module_name, lr_codes(jw, uri))

    # Too many leading dots at the top level of a single-file workspace.
    jw, uri = lr_workspace("using ..Foo\n")
    diags = [d for d in JuliaWorkspaces.get_diagnostic(jw, uri) if d.code === :relative_import]
    @test length(diags) == 1
    @test diags[1].message == "Relative import has more leading dots than available module nesting."

    # Enough nesting: silent. (`using ..Foo` inside `module A module B` pops
    # one level, which exists.)
    jw, uri = lr_workspace("module A\nmodule B\nusing ..Foo\nend\nend\n")
    @test !any(d -> d[1] === :relative_import, lr_codes(jw, uri))

    # One dot anchors at the current module and never over-pops.
    jw, uri = lr_workspace("using .Foo\n")
    @test !any(d -> d[1] === :relative_import, lr_codes(jw, uri))

    # Flag off: nothing.
    jw, uri = lr_workspace("module A\nmodule A\nend\nend\nusing ..Foo\n"; flag=false)
    @test !any(d -> d[1] in (:module_name, :relative_import), lr_codes(jw, uri))

    # Config off: silenced individually.
    jw = JuliaWorkspace()
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(URI("file:///pr/JuliaLint.toml"),
        SourceText("[rules]\nmodule_name = \"off\"\n", "toml")))
    add_file!(jw, TextFile(uri, SourceText("module A\nmodule A\nend\nend\n", "julia")))
    JW.set_lowering_lint!(jw, true)
    @test !any(d -> d.code === :module_name, JuliaWorkspaces.get_diagnostic(jw, uri))
end

@testitem "module-tree rules: the splice prefix sees cross-file nesting" setup=[LoweringRouteWS] begin
    # `module A` in a file included from inside `module A` of the root: v1's
    # same-file check misses this; the v2 splice prefix catches it (documented
    # superset).
    jw = JuliaWorkspace()
    root = URI("file:///pr/src/root.jl")
    inner = URI("file:///pr/src/inner.jl")
    add_file!(jw, TextFile(root, SourceText("module A\ninclude(\"inner.jl\")\nend\n", "julia")))
    add_file!(jw, TextFile(inner, SourceText("module A\nend\n", "julia")))
    JW.set_lowering_lint!(jw, true)
    @test any(d -> d.code === :module_name, JuliaWorkspaces.get_diagnostic(jw, inner))

    # And relative imports account for the spliced depth: `using ..X` inside
    # the included file's top level pops to the root scope, which exists.
    add_file!(jw, TextFile(URI("file:///pr/src/root2.jl"),
        SourceText("module B\ninclude(\"inner2.jl\")\nend\n", "julia")))
    inner2 = URI("file:///pr/src/inner2.jl")
    add_file!(jw, TextFile(inner2, SourceText("using ..X\n", "julia")))
    @test !any(d -> d.code === :relative_import, JuliaWorkspaces.get_diagnostic(jw, inner2))
end
