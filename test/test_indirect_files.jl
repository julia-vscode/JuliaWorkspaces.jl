@testitem "Indirect file: lazy disc read + callback fires once" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\nfoo() = 1\n""")
        write(b_path, "bar() = 2\n")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        callback_calls = URI[]
        jw = JuliaWorkspace(indirect_file_watch_callback = uri -> push!(callback_calls, uri))

        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        # Force the include graph to materialize.
        all_files = JuliaWorkspaces.get_julia_files(jw)
        @test a_uri in all_files

        indirect = get_indirect_files(jw)
        @test b_uri in indirect
        @test !(b_uri in JuliaWorkspaces.get_files(jw))
        @test is_indirect_file(jw, b_uri)
        @test !is_indirect_file(jw, a_uri)

        @test callback_calls == [b_uri]

        # Querying again must not refire the callback.
        get_indirect_files(jw)
        JuliaWorkspaces.get_julia_files(jw)
        @test callback_calls == [b_uri]
    end
end

@testitem "Indirect file: no diagnostics emitted" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        # Syntax error in the indirect file.
        write(b_path, "function foo() end begin")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        # Trigger include graph.
        JuliaWorkspaces.get_julia_files(jw)

        @test is_indirect_file(jw, b_uri)
        @test isempty(get_diagnostic(jw, b_uri))
    end
end

@testitem "Indirect file: missing file on disc is skipped" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        write(a_path, """include("Missing.jl")\n""")

        a_uri = filepath2uri(a_path)
        missing_uri = filepath2uri(joinpath(dir, "Missing.jl"))

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        all_files = JuliaWorkspaces.get_julia_files(jw)
        @test a_uri in all_files
        # File doesn't exist on disc — lazy read returns nothing — must not be added.
        @test !(missing_uri in all_files)
        @test !(missing_uri in get_indirect_files(jw))
    end
end

@testitem "Indirect file: multi-level include chain" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        c_path = joinpath(dir, "C.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, """include("C.jl")\n""")
        write(c_path, "x = 1\n")

        a_uri, b_uri, c_uri = filepath2uri.((a_path, b_path, c_path))

        callback_calls = URI[]
        jw = JuliaWorkspace(indirect_file_watch_callback = uri -> push!(callback_calls, uri))
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        all_files = JuliaWorkspaces.get_julia_files(jw)
        @test a_uri in all_files
        @test b_uri in all_files
        @test c_uri in all_files

        indirect = get_indirect_files(jw)
        @test b_uri in indirect && c_uri in indirect
        @test sort(string.(callback_calls)) == sort(string.([b_uri, c_uri]))
    end
end

@testitem "Indirect file: cycle is finite" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, """include("A.jl")\n""")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        all_files = JuliaWorkspaces.get_julia_files(jw)
        @test all_files == Set([a_uri, b_uri])
    end
end

@testitem "Indirect file: promotion via add_file!" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, "function foo() end begin")  # syntax error

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        # Trigger include graph and confirm indirect status.
        JuliaWorkspaces.get_julia_files(jw)
        @test is_indirect_file(jw, b_uri)
        @test isempty(get_diagnostic(jw, b_uri))

        # Promote: add_file! must not throw JWDuplicateFile.
        JuliaWorkspaces.add_file!(jw, TextFile(b_uri, SourceText(read(b_path, String), "julia")))

        @test b_uri in JuliaWorkspaces.get_files(jw)
        @test !is_indirect_file(jw, b_uri)
        @test !(b_uri in get_indirect_files(jw))

        # Now diagnostics must flow.
        diags = get_diagnostic(jw, b_uri)
        @test !isempty(diags)
    end
end

@testitem "Indirect file: set_indirect_file_content! updates derived results" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, "x = 1\n")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))
        JuliaWorkspaces.get_julia_files(jw)
        @test is_indirect_file(jw, b_uri)

        # Simulate a watcher delivering updated disc content.
        new_text = TextFile(b_uri, SourceText("y = 2\n", "julia"))
        set_indirect_file_content!(jw, b_uri, new_text)

        # Still indirect, still part of the graph.
        @test is_indirect_file(jw, b_uri)
        @test b_uri in JuliaWorkspaces.get_julia_files(jw)

        # Simulate disc deletion.
        set_indirect_file_content!(jw, b_uri, nothing)

        all_files = JuliaWorkspaces.get_julia_files(jw)
        @test !(b_uri in all_files)
    end
end

@testitem "Indirect file: works without watcher callback" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, "x = 1\n")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()  # no callback
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        @test b_uri in JuliaWorkspaces.get_julia_files(jw)
        @test is_indirect_file(jw, b_uri)
    end
end

@testitem "Indirect file: appears in roots when not included from elsewhere" begin
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        write(a_path, """include("B.jl")\n""")
        write(b_path, "x = 1\n")

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(read(a_path, String), "julia")))

        roots_for_b = get_roots_for_uri(jw, b_uri)
        @test a_uri in roots_for_b
    end
end

# Cross-file results routinely land in indirect files: a regular root includes
# a sibling that was never `add_file!`d (single-file mode, a package outside
# the workspace folders, a workspace over the file cap). Every position that
# is materialized for such a location must be served from the indirect content,
# not the regular-file input (which throws `KeyError` for these URIs).
@testitem "Indirect file: cross-file navigation lands in an indirect file" begin
    using JuliaWorkspaces: get_references, get_definitions, get_rename_edits,
        get_hover_text, get_document_symbols
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        a_src = "include(\"B.jl\")\ncaller() = greet(1)\nfmt(x, p::P) = relpath(x, p)\n"
        b_src = "greet(name) = 1\nstruct P end\nBase.relpath(x::AbstractString, p::P) = x\n"
        write(a_path, a_src)
        write(b_path, b_src)

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(a_src, "julia")))
        @test is_indirect_file(jw, b_uri)

        loc(r) = (r.uri, r.start.line, r.start.column)
        idx = findfirst("greet", a_src).start

        refs = loc.(get_references(jw, a_uri, idx))
        @test (a_uri, 2, 12) in refs
        @test (b_uri, 1, 1) in refs

        @test loc.(get_definitions(jw, a_uri, idx)) == [(b_uri, 1, 1)]

        edits = get_rename_edits(jw, a_uri, idx, "hello")
        @test (b_uri, 1, 1) in loc.(edits)
        @test all(e -> e.new_text == "hello", edits)

        # Hover on a Base function lists the workspace overload declared in the
        # indirect file, linked to its line there.
        h = get_hover_text(jw, a_uri, findfirst("relpath", a_src).start)
        @test h !== nothing
        @test occursin("relpath(x::AbstractString, p::P)", h)
        @test occursin("[B.jl:3]", h)

        # The outline of the indirect file itself.
        names = [s.name for s in get_document_symbols(jw, b_uri)]
        @test "greet" in names
        @test "P" in names
    end
end

# `remove_file!` of a file that still exists on disc does not drop it from the
# include graph: the including file still names it, so it is demoted from a
# regular file to an indirect one. Cross-file navigation keeps landing in it.
@testitem "Indirect file: demotion via remove_file! keeps navigation working" begin
    using JuliaWorkspaces: get_references, get_definitions, remove_file!
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    mktempdir() do dir
        a_path = joinpath(dir, "A.jl")
        b_path = joinpath(dir, "B.jl")
        a_src = "include(\"B.jl\")\ncaller() = greet(1)\n"
        b_src = "greet(name) = 1\n"
        write(a_path, a_src)
        write(b_path, b_src)

        a_uri = filepath2uri(a_path)
        b_uri = filepath2uri(b_path)

        jw = JuliaWorkspace()
        JuliaWorkspaces.add_file!(jw, TextFile(a_uri, SourceText(a_src, "julia")))
        JuliaWorkspaces.add_file!(jw, TextFile(b_uri, SourceText(b_src, "julia")))
        @test !is_indirect_file(jw, b_uri)

        loc(r) = (r.uri, r.start.line, r.start.column)
        idx = findfirst("greet", a_src).start
        @test (b_uri, 1, 1) in loc.(get_references(jw, a_uri, idx))

        remove_file!(jw, b_uri)
        @test !JuliaWorkspaces.has_file(jw, b_uri)
        @test is_indirect_file(jw, b_uri)

        @test (b_uri, 1, 1) in loc.(get_references(jw, a_uri, idx))
        @test loc.(get_definitions(jw, a_uri, idx)) == [(b_uri, 1, 1)]
    end
end

# `input_text_file` only knows regular files. Everything that renders a
# position or reads a file's text must go through `derived_text_file_content`,
# which also serves indirect files; the input itself is an implementation
# detail of that accessor and of the mutators in `public.jl`.
@testitem "Indirect file: feature layers never read input_text_file directly" begin
    src_dir = normpath(joinpath(@__DIR__, "..", "src"))
    allowed = Set(["inputs.jl", "layer_files.jl", "public.jl"])

    offenders = String[]
    for (root, _, files) in walkdir(src_dir), f in files
        endswith(f, ".jl") || continue
        f in allowed && continue
        path = joinpath(root, f)
        for (i, line) in enumerate(eachline(path))
            occursin("input_text_file(", line) || continue
            push!(offenders, string(relpath(path, src_dir), ":", i))
        end
    end

    @test isempty(offenders)
end
