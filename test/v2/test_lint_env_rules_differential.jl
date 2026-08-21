# The env-rules differential: over this repo's own corpus, v1's and v2's
# `missing_reference` / `unresolved_import` findings, compared per file as
# (rule, name) multisets. Both producers are read PRE-materialization
# (`derived_new_static_lint_diagnostics` vs `derived_semantic_lint_findings`),
# so env readiness plays no role, and both see the same core-only env (no
# project is loaded).
#
# The acceptance gate is asymmetric on purpose:
#   - v2-only findings are FALSE-POSITIVE CANDIDATES and fail the test, hard.
#     There are no declared exception classes.
#   - v1-only findings are expected residue of v2's deliberately-wider gates
#     (item-level existence guards, whole-file test-helper suppression, quoted
#     getfield marks under scope "all", colon-member import reporting, names
#     v1's macro modeling resolves) — they are printed per rule for review,
#     never asserted away. The deps-less harness env inflates the
#     missing_reference number specifically: v1 analyzes @testitem bodies
#     against injected `using Test`/package imports that cannot index here, so
#     much of that count is a harness artifact rather than production signal.

@testitem "v2 env rules agree with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri

    const RULES = (:missing_reference, :unresolved_import, :nothing_comparison)

    root_dir = pkgdir(JuliaWorkspaces)
    jw = JuliaWorkspace()
    # v1's per-file analysis contributes nothing for project-less roots, and a
    # package folder only counts as a PROJECT with both TOMLs present — a
    # worktree checkout has no Manifest.toml, so a synthetic empty one rides
    # along with the real Project.toml. Both engines then resolve against the
    # same (deps-less, effectively core-only) environment.
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
    JW.set_lowering_lint!(jw, true)

    # The compared key: (rule, referenced name), extracted from the message.
    # `nothing_comparison` messages carry no name — count-only per file.
    name_of(rule, msg) = rule === :missing_reference ?
        String(chopprefix(msg, "Missing reference: ")) :
        rule === :nothing_comparison ? "" :
        (m = match(r"`([^`]+)`", msg); m === nothing ? msg : String(m.captures[1]))

    counts(pairs) = begin
        c = Dict{Tuple{Symbol,String},Int}()
        for p in pairs
            c[p] = get(c, p, 0) + 1
        end
        c
    end

    v2_only = String[]
    v1_only = Dict{Symbol,Int}()
    agreement = Dict{Symbol,Int}()

    for uri in uris
        v1 = counts([(f.rule_id, name_of(f.rule_id, f.message))
                     for f in JW.derived_new_static_lint_diagnostics(jw.runtime, uri)
                     if f.rule_id in RULES])
        v2 = counts([(f.rule_id, name_of(f.rule_id, f.message))
                     for f in JW.derived_semantic_lint_findings(jw.runtime, uri)
                     if f.rule_id in RULES])
        for (k, n2) in v2
            n1 = get(v1, k, 0)
            agreement[k[1]] = get(agreement, k[1], 0) + min(n1, n2)
            n2 > n1 && push!(v2_only, "$(uri): $(k[1]) `$(k[2])` v2=$(n2) v1=$(n1)")
        end
        for (k, n1) in v1
            extra = n1 - get(v2, k, 0)
            extra > 0 && (v1_only[k[1]] = get(v1_only, k[1], 0) + extra)
        end
    end

    println("env-rules differential: agreement=$(agreement) v1_only=$(v1_only)")
    isempty(v2_only) || println("v2-only findings (false-positive candidates):\n  " *
        join(first(v2_only, 40), "\n  "))

    # The hard gate: nothing v2 reports that v1 does not.
    @test v2_only == String[]
    # Sanity floor: the rules genuinely fire and agree somewhere (this repo's
    # imports of unindexed packages are unresolved in BOTH engines).
    @test get(agreement, :unresolved_import, 0) > 20
end
