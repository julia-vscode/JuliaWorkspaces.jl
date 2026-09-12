@testitem "Documents add text file" begin
    using JuliaWorkspaces.URIs2
    jw = JuliaWorkspace()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    text_file = get_text_file(jw, uri)

    @test text_file.uri == uri
    @test text_file.content.content == content
    @test text_file.content.language_id == "julia"

    a = get_julia_syntax_tree(jw, uri)

    @test a !== nothing
end

# `add_files!` yields between files so a host's other tasks can run. A query
# that runs in one of those windows must see a consistent workspace: every
# URI reported by `has_file` has text, and no read throws.
@testitem "Documents add_files! never exposes membership without text" begin
    using JuliaWorkspaces: add_files!, has_file, get_text_file, get_files
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    files = [TextFile(URI("file:///batch/f$i.jl"), SourceText("f$i() = $i\n", "julia")) for i in 1:20]
    uris = [f.uri for f in files]

    errors = Any[]
    probes = Ref(0)
    done = Ref(false)
    probe = @async begin
        while !done[]
            try
                for u in uris
                    # Membership without text was the bug: `get_text_file`
                    # then threw `KeyError` out of the regular-file input.
                    has_file(jw, u) && get_text_file(jw, u)
                end
                probes[] += 1
            catch err
                push!(errors, err)
            end
            yield()
        end
    end

    add_files!(jw, files)
    done[] = true
    wait(probe)

    @test probes[] > 0
    @test isempty(errors)
    @test all(u -> has_file(jw, u), uris)
    @test all(u -> get_text_file(jw, u).uri == u, uris)
    @test Set(uris) ⊆ get_files(jw)
end

@testitem "Documents add duplicate file" begin
    using JuliaWorkspaces.URIs2
    jw = JuliaWorkspace()

    uri = URI("file://foo.jl")
    content = "using Pkg"

    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    @test_throws JuliaWorkspaces.JWDuplicateFile add_file!(jw, TextFile(uri, SourceText(content, "julia")))
end

