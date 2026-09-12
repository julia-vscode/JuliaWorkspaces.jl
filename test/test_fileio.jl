@testitem "Read folder into workspace" begin
    using JuliaWorkspaces: filepath2uri, get_text_files

    pkg_root = abspath(joinpath(@__DIR__, "..", "testdata", "TestPackage1"))

    if Sys.islinux()

        mktempdir() do temp_dir
            invalid_file = joinpath(temp_dir, "\x9999.invalid.jl")
            touch(invalid_file)

            jw = workspace_from_folders([temp_dir])
            @test length(get_text_files(jw)) == 1
        end
    end
end

@testitem "read_path_into_textdocuments honors file_limit" begin
    using JuliaWorkspaces: read_path_into_textdocuments
    using JuliaWorkspaces.URIs2: filepath2uri

    mktempdir() do dir
        for i in 1:5
            write(joinpath(dir, "f$i.jl"), "f$i() = $i\n")
        end
        write(joinpath(dir, "Project.toml"), "name = \"X\"\n")

        unlimited = read_path_into_textdocuments(filepath2uri(dir))
        @test length(unlimited) == 6

        # Only Julia files count against the limit.
        at_limit = read_path_into_textdocuments(filepath2uri(dir), file_limit=5)
        @test length(at_limit) == 6

        @test read_path_into_textdocuments(filepath2uri(dir), file_limit=4) === nothing
    end
end

@testitem "read_path_into_textdocuments skips entries it cannot stat" begin
    using JuliaWorkspaces: read_path_into_textdocuments
    using JuliaWorkspaces.URIs2: filepath2uri

    if Sys.islinux()
        mktempdir() do dir
            write(joinpath(dir, "a.jl"), "a() = 1\n")

            noexec = joinpath(dir, "noexec")
            mkdir(noexec)
            write(joinpath(noexec, "hidden.jl"), "h() = 1\n")
            # Readable but not searchable: `readdir` succeeds, but `lstat` on
            # the entries throws EACCES — the same shape as a broken reparse
            # point on Windows.
            chmod(noexec, 0o400)
            try
                files = read_path_into_textdocuments(filepath2uri(dir), ignore_io_errors=true)
                @test length(files) == 1
                @test only(files).uri == filepath2uri(joinpath(dir, "a.jl"))
            finally
                chmod(noexec, 0o700)
            end
        end
    end
end

@testitem "collect_workspace_paths skips non-regular files" begin
    using JuliaWorkspaces: collect_workspace_paths

    if Sys.isunix()
        mktempdir() do dir
            write(joinpath(dir, "a.jl"), "a() = 1\n")
            Libc.mkfifo(joinpath(dir, "pipe.jl"), 0o600)

            @test basename.(collect_workspace_paths(dir)) == ["a.jl"]
        end
    end
end

@testitem "read_path_into_textdocuments skips .git and other VCS/dependency dirs" begin
    using JuliaWorkspaces: read_path_into_textdocuments
    using JuliaWorkspaces.URIs2: filepath2uri

    mktempdir() do dir
        write(joinpath(dir, "a.jl"), "a() = 1\n")

        for skipped in (".git", ".svn", ".hg", "node_modules")
            skipped_dir = joinpath(dir, skipped, "nested")
            mkpath(skipped_dir)
            write(joinpath(skipped_dir, "b.jl"), "b() = 2\n")
        end

        files = read_path_into_textdocuments(filepath2uri(dir))
        @test length(files) == 1
        @test only(files).uri == filepath2uri(joinpath(dir, "a.jl"))
    end
end

@testitem "collect_workspace_paths: scope prunes the walk per config kind" begin
    using JuliaWorkspaces: collect_workspace_paths

    write_file(p, c) = (mkpath(dirname(p)); write(p, c))
    rel(root, paths) = sort([replace(relpath(p, root), '\\' => '/') for p in paths])

    mktempdir() do root
        write_file(joinpath(root, "Project.toml"), "name = \"Demo\"\n")
        write_file(joinpath(root, "JuliaTestItems.toml"), "exclude = [\"bigdata/**\"]\n")
        write_file(joinpath(root, "JuliaFormat.toml"), "include = [\"src/**\"]\n")
        write_file(joinpath(root, "src", "Demo.jl"), "module Demo end\n")
        write_file(joinpath(root, "test", "runtests.jl"), "# tests\n")
        write_file(joinpath(root, "bigdata", "a.jl"), "# excluded\n")
        write_file(joinpath(root, "bigdata", "deep", "b.jl"), "# excluded\n")
        write_file(joinpath(root, "bigdata", "Project.toml"), "name = \"Excluded\"\n")

        configs = ["JuliaFormat.toml", "JuliaTestItems.toml", "Project.toml"]

        @test rel(root, collect_workspace_paths(root)) == sort(vcat(configs, [
            "src/Demo.jl", "test/runtests.jl",
            "bigdata/a.jl", "bigdata/deep/b.jl", "bigdata/Project.toml",
        ]))

        # Only `JuliaTestItems.toml` has a say here: the format config's
        # narrower `include` must not reach a test-item walk. The excluded
        # subtree is not descended into, so its `Project.toml` is gone too.
        @test rel(root, collect_workspace_paths(root; scope=:testitems)) ==
            sort(vcat(configs, ["src/Demo.jl", "test/runtests.jl"]))

        @test rel(root, collect_workspace_paths(root; scope=:format)) ==
            sort(vcat(configs, ["src/Demo.jl"]))

        # Several kinds compose as a union: a file either of them wants is read.
        @test rel(root, collect_workspace_paths(root; scope=(:format, :testitems))) ==
            sort(vcat(configs, ["src/Demo.jl", "test/runtests.jl"]))

        # A kind with no config file of its own admits everything.
        @test rel(root, collect_workspace_paths(root; scope=:lint)) ==
            rel(root, collect_workspace_paths(root))

        @test_throws ArgumentError collect_workspace_paths(root; scope=:nope)
    end
end

@testitem "collect_workspace_paths: a nested config may narrow scope, never widen it" begin
    using JuliaWorkspaces: collect_workspace_paths

    write_file(p, c) = (mkpath(dirname(p)); write(p, c))
    rel(root, paths) = sort([replace(relpath(p, root), '\\' => '/') for p in paths])

    mktempdir() do root
        write_file(joinpath(root, "JuliaTestItems.toml"), "exclude = [\"packages/**\"]\n")
        write_file(joinpath(root, "a.jl"), "#\n")
        write_file(joinpath(root, "packages", "Foo", "JuliaTestItems.toml"), "include = [\"**/*.jl\"]\n")
        write_file(joinpath(root, "packages", "Foo", "src", "Foo.jl"), "#\n")

        @test rel(root, collect_workspace_paths(root; scope=:testitems)) ==
            ["JuliaTestItems.toml", "a.jl"]
    end

    mktempdir() do root
        write_file(joinpath(root, "JuliaTestItems.toml"), "include = [\"pkgs/**\"]\n")
        write_file(joinpath(root, "pkgs", "keep.jl"), "#\n")
        write_file(joinpath(root, "pkgs", "vendor", "JuliaTestItems.toml"), "exclude = [\"**\"]\n")
        write_file(joinpath(root, "pkgs", "vendor", "drop.jl"), "#\n")

        # The vendored subtree is narrowed away, but its own config file is
        # still read so that it can report diagnostics about itself.
        @test rel(root, collect_workspace_paths(root; scope=:testitems)) ==
            ["JuliaTestItems.toml", "pkgs/keep.jl", "pkgs/vendor/JuliaTestItems.toml"]
    end
end

@testitem "collect_workspace_paths: a malformed config fails open" begin
    using JuliaWorkspaces: collect_workspace_paths

    write_file(p, c) = (mkpath(dirname(p)); write(p, c))
    rel(root, paths) = sort([replace(relpath(p, root), '\\' => '/') for p in paths])

    mktempdir() do root
        write_file(joinpath(root, "JuliaTestItems.toml"), "this is not = = toml\n")
        write_file(joinpath(root, "sub", "a.jl"), "#\n")

        @test rel(root, collect_workspace_paths(root; scope=:testitems)) ==
            ["JuliaTestItems.toml", "sub/a.jl"]
    end
end

@testitem "collect_workspace_paths: file_limit counts only selected files" begin
    using JuliaWorkspaces: collect_workspace_paths

    write_file(p, c) = (mkpath(dirname(p)); write(p, c))

    mktempdir() do root
        write_file(joinpath(root, "JuliaTestItems.toml"), "exclude = [\"bigdata/**\"]\n")
        write_file(joinpath(root, "a.jl"), "#\n")
        write_file(joinpath(root, "b.jl"), "#\n")
        for i in 1:5
            write_file(joinpath(root, "bigdata", "f$i.jl"), "#\n")
        end

        @test collect_workspace_paths(root; file_limit=3) === nothing
        @test collect_workspace_paths(root; scope=:testitems, file_limit=3) !== nothing
        @test collect_workspace_paths(root; scope=:testitems, file_limit=1) === nothing
    end
end

@testitem "Scoped walk keeps excluded test items out of the workspace" begin
    using JuliaWorkspaces: workspace_from_folders, get_test_items

    write_file(p, c) = (mkpath(dirname(p)); write(p, c))

    mktempdir() do root
        write_file(joinpath(root, "Project.toml"),
            "name = \"Demo\"\nuuid = \"11111111-1111-1111-1111-111111111111\"\nversion = \"0.1.0\"\n")
        write_file(joinpath(root, "JuliaTestItems.toml"), "exclude = [\"bigdata/**\"]\n")
        write_file(joinpath(root, "src", "Demo.jl"), "module Demo end\n")
        write_file(joinpath(root, "test", "t.jl"), "@testitem \"kept\" begin\nend\n")
        write_file(joinpath(root, "bigdata", "t.jl"), "@testitem \"dropped\" begin\nend\n")

        names(jw) = sort([i.name for (_, td) in get_test_items(jw) for i in td.testitems])

        # The per-file query already excluded it; the scoped walk additionally
        # never reads it.
        @test names(workspace_from_folders([root])) == ["kept"]
        @test names(workspace_from_folders([root]; scope=:testitems)) == ["kept"]
    end
end
