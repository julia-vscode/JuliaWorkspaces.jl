# v2 root discovery (layer_includes_v2.jl): unit tests and the corpus
# differential against v1's CSTParser-based include collector.

@testsnippet IncludesV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, update_file!
    using JuliaWorkspaces.URIs2: URI

    function iw(files::Pair{String,String}...)
        jw = JuliaWorkspace()
        for (path, src) in files
            add_file!(jw, TextFile(URI("file:///pr/" * path), SourceText(src, "julia")))
        end
        return jw
    end

    u(path) = URI("file:///pr/" * path)
end

@testitem "v2 roots: chains, diamonds and cycles" setup=[IncludesV2WS] begin
    # A chain: root -> a -> b.
    jw = iw("root.jl" => "include(\"a.jl\")\n",
            "a.jl" => "include(\"b.jl\")\n",
            "b.jl" => "f() = 1\n")
    @test JW.derived_v2_roots(jw.runtime) == Set([u("root.jl")])
    @test JW.derived_v2_roots_for_uri(jw.runtime, u("b.jl")) == Set([u("root.jl")])
    @test JW.derived_v2_roots_for_uri(jw.runtime, u("root.jl")) == Set([u("root.jl")])

    # A diamond: two roots share a file.
    jw = iw("r1.jl" => "include(\"shared.jl\")\n",
            "r2.jl" => "include(\"shared.jl\")\n",
            "shared.jl" => "g() = 2\n")
    @test JW.derived_v2_roots(jw.runtime) == Set([u("r1.jl"), u("r2.jl")])
    @test JW.derived_v2_roots_for_uri(jw.runtime, u("shared.jl")) == Set([u("r1.jl"), u("r2.jl")])

    # A cycle terminates; neither cycle member is a root, the entry file is.
    jw = iw("entry.jl" => "include(\"x.jl\")\n",
            "x.jl" => "include(\"y.jl\")\n",
            "y.jl" => "include(\"x.jl\")\n")
    @test JW.derived_v2_roots(jw.runtime) == Set([u("entry.jl")])
    @test JW.derived_v2_roots_for_uri(jw.runtime, u("y.jl")) == Set([u("entry.jl")])

    # A genuinely computed include contributes no edge: the target stays its
    # own root.
    jw = iw("r.jl" => "include(joinpath(dir, \"dyn.jl\"))\n",
            "dyn.jl" => "h() = 3\n")
    @test u("dyn.jl") in JW.derived_v2_roots(jw.runtime)

    # The `joinpath(@__DIR__, …)` idiom resolves statically and DOES edge.
    jw = iw("r.jl" => "include(joinpath(@__DIR__, \"dyn.jl\"))\n",
            "dyn.jl" => "h() = 3\n")
    @test JW.derived_v2_roots(jw.runtime) == Set([u("r.jl")])
end

@testitem "v2 roots: best root prefers non-test, deterministically" setup=[IncludesV2WS] begin
    jw = iw("src/Pkg.jl" => "include(\"util.jl\")\n",
            "src/util.jl" => "f() = 1\n",
            "test/runtests.jl" => "include(\"../src/util.jl\")\n")
    @test JW.derived_v2_roots_for_uri(jw.runtime, u("src/util.jl")) ==
        Set([u("src/Pkg.jl"), u("test/runtests.jl")])
    @test JW.derived_v2_best_root_for_uri(jw.runtime, u("src/util.jl")) == u("src/Pkg.jl")
    @test JW.derived_v2_best_root_for_uri(jw.runtime, u("nowhere.jl")) === nothing
end

@testitem "v2 roots: content-only edits backdate the reverse map" setup=[IncludesV2WS] begin
    jw = iw("root.jl" => "include(\"a.jl\")\nf() = 1\n",
            "a.jl" => "g() = 2\n")
    m1 = JW.derived_v2_reverse_include_map(jw.runtime)
    r1 = JW.derived_v2_roots(jw.runtime)

    # An edit that does not change the include list leaves both values isequal.
    update_file!(jw, TextFile(u("root.jl"), SourceText("include(\"a.jl\")\nf() = 42\n", "julia")))
    @test isequal(JW.derived_v2_reverse_include_map(jw.runtime), m1)
    @test isequal(JW.derived_v2_roots(jw.runtime), r1)

    # Removing the include changes roots: `a.jl` becomes its own root.
    update_file!(jw, TextFile(u("root.jl"), SourceText("f() = 42\n", "julia")))
    @test JW.derived_v2_roots(jw.runtime) == Set([u("root.jl"), u("a.jl")])
end

@testitem "v2 roots agree with v1 across the package corpus" setup=[IncludesV2WS] begin
    # The differential ratchet: per corpus file (loaded as a one-file workspace
    # plus its on-disk include closure via indirect loading is NOT exercised
    # here — instead the whole repo's real files are loaded as one workspace)
    # v1 and v2 must agree on the root set and per-file root membership.
    # Divergences would be computed includes v1's CSTParser collector resolves
    # that v2's literal-only resolution cannot; the allowlist must stay empty
    # or carry reasons.
    const EXPECTED_ROOT_DIVERGENCES = Set{String}()

    root_dir = pkgdir(JuliaWorkspaces)
    jw = JuliaWorkspace()
    # Load the real src/ tree (with its genuine include structure).
    for (d, _, fs) in walkdir(joinpath(root_dir, "src"))
        any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver")) && continue
        for f in fs
            endswith(f, ".jl") || continue
            p = joinpath(d, f)
            add_file!(jw, TextFile(JuliaWorkspaces.URIs2.filepath2uri(p),
                SourceText(read(p, String), "julia")))
        end
    end

    v1_roots = JW.derived_roots(jw.runtime)
    v2_roots = JW.derived_v2_roots(jw.runtime)

    v1_only = setdiff(v1_roots, v2_roots)
    v2_only = setdiff(v2_roots, v1_roots)
    rels = Set{String}()
    for uri in Iterators.flatten((v1_only, v2_only))
        p = JuliaWorkspaces.URIs2.uri2filepath(uri)
        push!(rels, p === nothing ? string(uri) : relpath(p, root_dir))
    end

    unexpected = setdiff(rels, EXPECTED_ROOT_DIVERGENCES)
    isempty(unexpected) || println("Root divergences v1 vs v2:\n  " * join(sort!(collect(unexpected)), "\n  "))
    @test isempty(unexpected)
    @test issubset(EXPECTED_ROOT_DIVERGENCES, rels)

    # Per-file root membership for every file both agree is in the graph.
    mismatches = String[]
    for uri in intersect(JW.derived_all_julia_files(jw.runtime), JW.derived_v2_all_julia_files(jw.runtime))
        r1 = JW.derived_roots_for_uri(jw.runtime, uri)
        r2 = JW.derived_v2_roots_for_uri(jw.runtime, uri)
        r1 == r2 && continue
        p = JuliaWorkspaces.URIs2.uri2filepath(uri)
        push!(mismatches, p === nothing ? string(uri) : relpath(p, root_dir))
    end
    isempty(mismatches) || println("roots_for_uri mismatches:\n  " * join(sort!(mismatches), "\n  "))
    @test mismatches == String[]
end
