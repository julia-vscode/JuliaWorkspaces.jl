@testitem "remove_file! evicts derived values for the removed URI" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces: Salsa

    n_entries_for(jw, uri) =
        Salsa.evict_derived!(key -> any(arg -> isequal(arg, uri), key.args), jw.runtime)

    uri1 = URI("file:///evicttest/src/a.jl")
    uri2 = URI("file:///evicttest/src/b.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri1, SourceText("f(x) = x + 1", "julia")))
    add_file!(jw, TextFile(uri2, SourceText("g(x) = x - 1", "julia")))

    # Populate the derived caches.
    get_diagnostic(jw, uri1)
    get_diagnostic(jw, uri2)

    remove_file!(jw, uri1)

    # No derived entry may still be keyed by the removed URI. (The probe uses
    # evict_derived! itself: it returns the number of matching entries.)
    @test n_entries_for(jw, uri1) == 0

    # The surviving file is untouched and still queryable.
    @test get_diagnostic(jw, uri2) isa Vector
    @test has_file(jw, uri2)
end

@testitem "remove_all_children! evicts derived values for all removed URIs" begin
    using JuliaWorkspaces.URIs2: URI
    using JuliaWorkspaces: Salsa

    n_entries_for(jw, uri) =
        Salsa.evict_derived!(key -> any(arg -> isequal(arg, uri), key.args), jw.runtime)

    uris = [URI("file:///evictfolder/src/f$i.jl") for i in 1:5]
    outside = URI("file:///other/src/g.jl")

    jw = JuliaWorkspace()
    for uri in uris
        add_file!(jw, TextFile(uri, SourceText("h(x) = x", "julia")))
    end
    add_file!(jw, TextFile(outside, SourceText("h(x) = x", "julia")))

    get_diagnostics(jw)

    remove_all_children!(jw, URI("file:///evictfolder"))

    for uri in uris
        @test n_entries_for(jw, uri) == 0
    end
    @test has_file(jw, outside)
    @test get_diagnostic(jw, outside) isa Vector
end
