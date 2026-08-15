# The vendored-parser refresh gate.
#
# The v1 (CSTParser) and v2 (JuliaSyntax EST) inventories must agree about what
# this package's own source declares. A `packages/JuliaSyntax` refresh that
# changes the EST shape shows up here as a red test rather than as silently
# reclassified items across the workspace.
#
# Ids are deliberately NOT compared: the two walkers mint from different keys
# over different trees, and forcing them to agree would recreate the coupling
# this whole layer exists to remove. Projections are compared instead.

@testitem "v2 inventory agrees with v1 across the package corpus" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    # Divergences we accept, each with a reason. This list is a RATCHET: the test
    # fails both when an undeclared divergence appears AND when a declared one
    # stops firing, so entries cannot rot into a silent amnesty.
    #
    # 1. `:macro_declared` — v1's macro-declared-names subsystem
    #    (MACRO_DECLARATION_RULES) synthesises names a macro will define, e.g.
    #    `Salsa.@declare_input input_x` ⇒ `set_input_x!`/`delete_input_x!`.
    #    Not yet ported to v2; tracked as follow-up work.
    # 2. Operators written `Base.:(==)` — v1 extracts NO name from the
    #    parenthesized-operator form, v2 extracts `==` qualified by `Base`.
    #    Here v2 is the more correct of the two.
    const EXPECTED_V1_ONLY_KINDS = Set([:macro_declared])
    const EXPECTED_V2_ONLY_KINDS = Set([:function])   # only the `Base.:(==)` shape

    root = pkgdir(JuliaWorkspaces)
    files = String[]
    for sub in ("src", "test")
        isdir(joinpath(root, sub)) || continue
        for (d, _, fs) in walkdir(joinpath(root, sub))
            # StaticLint and SymbolServer are vendored subsystems with their own
            # conventions; `packages/` is vendored upstream code.
            any(occursin(x, lowercase(d)) for x in ("staticlint", "symbolserver", "packages")) && continue
            for f in fs
                endswith(f, ".jl") && push!(files, joinpath(d, f))
            end
        end
    end
    @test length(files) > 50   # the corpus is actually there

    proj(items) = sort([(i.name, i.kind, join(i.parent_module, "."), join(i.qualifier, "."))
                        for i in items])

    saw_v1_only = Set{Symbol}()
    saw_v2_only = Set{Symbol}()
    problems = String[]

    for f in files
        src = try
            read(f, String)
        catch
            continue
        end
        rel = relpath(f, root)
        uri = URI("file:///corpus/" * replace(rel, "\\" => "/"))
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        v1 = JW.derived_file_inventory(jw.runtime, uri)
        v2 = JW.derived_v2_file_inventory(jw.runtime, uri)

        p1, p2 = proj(v1.items), proj(v2.items)
        for x in setdiff(p1, p2)
            push!(saw_v1_only, x[2])
            x[2] in EXPECTED_V1_ONLY_KINDS || push!(problems, "$rel: v1-only $(x)")
        end
        for x in setdiff(p2, p1)
            push!(saw_v2_only, x[2])
            (x[2] in EXPECTED_V2_ONLY_KINDS && x[1] == "==") ||
                push!(problems, "$rel: v2-only $(x)")
        end

        m1 = sort([(m.name, m.bare, join(m.parent_module, ".")) for m in v1.modules])
        m2 = sort([(m.name, m.bare, join(m.parent_module, ".")) for m in v2.modules])
        m1 == m2 || push!(problems, "$rel: modules differ: $(symdiff(m1, m2))")

        e1 = sort([(e.kind, sort(e.names), join(e.parent_module, ".")) for e in v1.exports])
        e2 = sort([(e.kind, sort(e.names), join(e.parent_module, ".")) for e in v2.exports])
        e1 == e2 || push!(problems, "$rel: exports differ: $(symdiff(e1, e2))")

        i1 = sort([(i.kind, i.path, i.symbols, i.alias, join(i.parent_module, ".")) for i in v1.imports])
        i2 = sort([(i.kind, i.path, i.symbols, i.alias, join(i.parent_module, ".")) for i in v2.imports])
        i1 == i2 || push!(problems, "$rel: imports differ: $(symdiff(i1, i2))")

        # v2 defers resolving an include to a URI (that is the module tree's
        # job), so only the edge COUNT is comparable here.
        length(v1.includes) == length(v2.includes) ||
            push!(problems, "$rel: include count v1=$(length(v1.includes)) v2=$(length(v2.includes))")
    end

    isempty(problems) || println("Unexpected v1/v2 divergences:\n  " *
                                 join(first(problems, 40), "\n  "))
    @test problems == String[]

    # The ratchet: every declared divergence must still be real. If one stops
    # firing, it has been fixed and belongs out of the allowlist.
    @test saw_v1_only == EXPECTED_V1_ONLY_KINDS
    @test saw_v2_only == EXPECTED_V2_ONLY_KINDS
end
