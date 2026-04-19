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
