# The v2 visibility differential: over this repo's own corpus, v1's and v2's
# visible-name faces must agree per (root, module path), up to three declared
# divergence classes — each a RATCHET (must keep firing; undeclared
# divergences fail):
#   :testitem_nodes — v1's tree gives @testitem bodies their own module
#       nodes; v2 deliberately has none.
#   :macro_declared — v1's macro-declared-names machinery (Salsa.@declare_input
#       et al.); not ported to v2.
#
# A third class, :external_names, existed while the layer was tree-only
# (Milestone B). With the env seam restored, external faces converged EXACTLY
# across this corpus — including v1's implicit-member fallback, which this
# repo's code never exercises through a colon list — so the class is gone and
# any external divergence now fails outright.

@testitem "v2 visibility agrees with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    const EXPECTED_CLASSES = Set([:testitem_nodes, :macro_declared])

    root_dir = pkgdir(JuliaWorkspaces)
    jw = JuliaWorkspace()
    for sub in ("src", "test")
        isdir(joinpath(root_dir, sub)) || continue
        for (d, _, fs) in walkdir(joinpath(root_dir, sub))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") || continue
                p = joinpath(d, f)
                add_file!(jw, TextFile(filepath2uri(p), SourceText(read(p, String), "julia")))
            end
        end
    end

    roots = intersect(JW.derived_roots(jw.runtime), JW.derived_v2_roots(jw.runtime))
    @test length(roots) > 20   # sanity floor

    saw = Set{Symbol}()
    problems = String[]
    modules_compared = Ref(0)

    for root in sort!(collect(roots); by=string)
        v1_tree = JW.derived_module_tree(jw.runtime, root)
        v2_tree = JW.derived_v2_module_tree(jw.runtime, root)

        v1_paths = Set{Vector{String}}()
        for n in v1_tree.modules
            if n.kind === :testitem
                push!(saw, :testitem_nodes)
                continue
            end
            push!(v1_paths, n.path)
        end
        v2_paths = Set(n.path for n in v2_tree.modules)
        # Any v1 non-testitem path missing in v2 (or vice versa) is a real
        # divergence — except paths UNDER a testitem node, which v2 cannot
        # represent either.
        under_testitem(p) = any(n -> n.kind === :testitem && length(n.path) <= length(p) &&
                                     p[1:length(n.path)] == n.path, v1_tree.modules)
        for p in setdiff(v1_paths, v2_paths)
            under_testitem(p) ? push!(saw, :testitem_nodes) :
                push!(problems, "$(root): v1-only module $(p)")
        end
        for p in setdiff(v2_paths, v1_paths)
            push!(problems, "$(root): v2-only module $(p)")
        end

        for path in sort!(collect(intersect(v1_paths, v2_paths)))
            f1 = JW.derived_module_visible_names_idfree(jw.runtime, root, path)
            f2 = JW.derived_v2_module_visible_names_idfree(jw.runtime, root, path)
            modules_compared[] += 1

            for (name, face1) in f1
                face2 = get(f2, name, nothing)
                if face1.kind === :macro_declared
                    face2 === nothing ? push!(saw, :macro_declared) :
                        push!(problems, "$(root) $(path): v2 binds macro-declared `$name` as $(face2)")
                    continue
                end
                if face2 === nothing
                    push!(problems, "$(root) $(path): v1-only `$name` $(face1)")
                elseif !isequal(face1, face2)
                    push!(problems, "$(root) $(path): `$name` v1=$(face1) v2=$(face2)")
                end
            end
            for (name, face2) in f2
                haskey(f1, name) && continue
                push!(problems, "$(root) $(path): v2-only `$name` $(face2)")
            end

            # Item presence must agree for tree-backed origins (id spaces
            # differ; presence only).
            v1_full = JW.derived_module_visible_names(jw.runtime, root, path)
            v2_full = JW.derived_v2_module_visible_names(jw.runtime, root, path)
            for (name, vn1) in v1_full
                vn1.origin in (:declared, :using_tree) || continue
                vn1.kind === :macro_declared && continue
                vn2 = get(v2_full, name, nothing)
                vn2 === nothing && continue   # already reported above
                (vn1.item === nothing) == (vn2.item === nothing) ||
                    push!(problems, "$(root) $(path): `$name` item presence differs")
            end
        end
    end

    @test modules_compared[] > 30
    isempty(problems) || println("Visibility divergences v1 vs v2:\n  " *
        join(first(problems, 40), "\n  "))
    @test problems == String[]

    # The ratchet: every declared class must still be real.
    @test saw == EXPECTED_CLASSES
end
