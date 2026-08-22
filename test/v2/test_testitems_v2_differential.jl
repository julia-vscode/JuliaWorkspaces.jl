# The v2 test-item switchover gate, modeled on test_inventory_v2_differential.jl:
# every file of this package's own corpus (src/, test/, testdata/) goes through
# BOTH detection engines — legacy TestItemDetection and the v2 skeleton +
# emission join — and the resulting `TestDetails` must agree item for item:
# ids, names, code slices, ranges, options, setups, and errors.
#
# Divergences are a RATCHET: a declared divergence class must keep firing, and
# an undeclared one fails the test, so the allowlist cannot rot.

@testitem "v2 test items agree with TestItemDetection across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_test_items
    using JuliaWorkspaces.URIs2: URI

    # Divergences we accept, each with a reason. Symbols name a CLASS; the sets
    # below assert each class actually fired somewhere in the corpus.
    #
    # (currently none)
    const EXPECTED_DIVERGENCE_CLASSES = Set{Symbol}()

    root = pkgdir(JuliaWorkspaces)
    files = String[]
    for sub in ("src", "test", "testdata")
        isdir(joinpath(root, sub)) || continue
        for (d, _, fs) in walkdir(joinpath(root, sub))
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") && push!(files, joinpath(d, f))
            end
        end
    end
    @test length(files) > 50

    const PROJECT_TOML = """
    name = "CorpusPkg"
    uuid = "d70e9a55-2b48-4bb6-8f36-b32e2f3b8b31"
    version = "1.0.0"
    """

    saw = Set{Symbol}()
    problems = String[]

    key(ti) = (ti.id, ti.name, ti.code, ti.range, ti.code_range,
               ti.option_default_imports, ti.option_tags, ti.option_setup, ti.option_skip)
    skey(ts) = (ts.name, ts.kind, ts.code, ts.range, ts.code_range)
    ekey(te) = (te.id, te.name, te.message, te.range)

    for f in files
        src = try
            read(f, String)
        catch
            continue
        end
        rel = relpath(f, root)
        uri = URI("file:///corpus/" * replace(rel, "\\" => "/"))

        results = map((false, true)) do v2
            jw = JuliaWorkspace()
            add_file!(jw, TextFile(URI("file:///corpus/Project.toml"), SourceText(PROJECT_TOML, "toml")))
            add_file!(jw, TextFile(uri, SourceText(src, "julia")))
            v2 && JW.set_v2_enabled!(jw, true)
            get_test_items(jw, uri)
        end
        legacy, v2r = results

        for (label, a, b, k) in (("items", legacy.testitems, v2r.testitems, key),
                                 ("setups", legacy.testsetups, v2r.testsetups, skey),
                                 ("errors", legacy.testerrors, v2r.testerrors, ekey))
            ka, kb = map(k, a), map(k, b)
            isequal(ka, kb) && continue
            push!(problems, "$rel: $label differ:\n    legacy-only: $(setdiff(ka, kb))\n    v2-only: $(setdiff(kb, ka))")
        end
    end

    isempty(problems) || println("Test item divergences legacy vs v2:\n  " *
                                 join(first(problems, 20), "\n  "))
    @test problems == String[]

    # The ratchet: every declared divergence class must still be real.
    @test saw == EXPECTED_DIVERGENCE_CLASSES
end
