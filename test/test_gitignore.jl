@testsnippet GitIgnoreRepos begin
    import LibGit2
    using JuliaWorkspaces: collect_workspace_paths, GitIgnoreFilter, is_in_ignored_folder

    write_file(p, c="") = (mkpath(dirname(p)); write(p, c))
    rel(root, paths) = sort([replace(relpath(p, root), '\\' => '/') for p in paths])

    # The InteractiveGMT shape behind the c54 report: a package whose CPack
    # staging folder holds a verbatim copy of its `Project.toml`, with the
    # build output and the manifest gitignored.
    function make_package_repo(root)
        repo = LibGit2.init(root)
        close(repo)
        write_file(joinpath(root, ".gitignore"), "Manifest.toml\ndeps/build/\ndocs/build/\n")
        project = "name = \"Pkg1\"\nuuid = \"3c546f1b-5575-514c-865e-7c2fc24caa84\"\nversion = \"0.1.0\"\n"
        write_file(joinpath(root, "Project.toml"), project)
        write_file(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        write_file(joinpath(root, "src", "Pkg1.jl"), "module Pkg1 end\n")
        write_file(joinpath(root, "test", "runtests.jl"), "using Pkg1\n")
        write_file(joinpath(root, "docs", "make.jl"), "using Pkg1\n")
        write_file(joinpath(root, "docs", "build", "index.md"), "# generated\n")
        full = joinpath(root, "deps", "build", "_CPack_Packages", "win64", "ZIP", "Pkg1-0.1.0-win64", "full")
        write_file(joinpath(full, "Project.toml"), project)
        write_file(joinpath(full, "src", "Pkg1.jl"), "module Pkg1 end\n")
        write_file(joinpath(root, "deps", "build.jl"), "# build script\n")
        return full
    end
end

@testitem "gitignore: the walk skips ignored folders but keeps ignored files" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        make_package_repo(root)

        # `Manifest.toml` is ignored too, but files are never dropped on their
        # own: without it the package would lose its environment.
        @test rel(root, collect_workspace_paths(root)) ==
            ["Manifest.toml", "Project.toml", "deps/build.jl", "docs/make.jl", "src/Pkg1.jl", "test/runtests.jl"]

        # A relative root is resolved before it is compared with the work tree.
        cd(root) do
            @test rel(".", collect_workspace_paths(".")) == rel(root, collect_workspace_paths(root))
        end

        # `gitignore=nothing` walks everything.
        all_paths = rel(root, collect_workspace_paths(root; gitignore=nothing))
        @test "deps/build/_CPack_Packages/win64/ZIP/Pkg1-0.1.0-win64/full/Project.toml" in all_paths
        @test "docs/build/index.md" in all_paths
    end
end

@testitem "gitignore: walking a folder inside an ignored folder" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        full = make_package_repo(root)

        # A host walking a folder its watcher reported as created passes the
        # filter of its workspace folders, so the rules above it apply.
        @test isempty(collect_workspace_paths(full; gitignore=GitIgnoreFilter([root])))

        # Walked as a workspace folder of its own, the folder is the user's
        # explicit choice and is read.
        @test rel(full, collect_workspace_paths(full)) == ["Project.toml", "src/Pkg1.jl"]
    end
end

@testitem "gitignore: is_in_ignored_folder agrees with the walk" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        full = make_package_repo(root)
        f = GitIgnoreFilter([root])

        @test is_in_ignored_folder(f, joinpath(full, "Project.toml"))
        @test is_in_ignored_folder(f, full)
        @test is_in_ignored_folder(f, joinpath(root, "deps", "build"))
        @test is_in_ignored_folder(f, joinpath(root, "docs", "build", "index.md"))
        # A file that does not exist yet (or any more) is judged by its folder.
        @test is_in_ignored_folder(f, joinpath(root, "docs", "build", "new.jl"))

        @test !is_in_ignored_folder(f, joinpath(root, "Manifest.toml"))
        @test !is_in_ignored_folder(f, joinpath(root, "src", "Pkg1.jl"))
        @test !is_in_ignored_folder(f, joinpath(root, "deps", "build.jl"))
        @test !is_in_ignored_folder(f, root)

        if Sys.iswindows()
            # Paths from a language client carry a lowercase drive letter.
            lc = lowercasefirst(root)
            @test is_in_ignored_folder(GitIgnoreFilter([lc]), joinpath(lowercasefirst(full), "Project.toml"))
            @test !is_in_ignored_folder(GitIgnoreFilter([lc]), joinpath(lc, "src", "Pkg1.jl"))
        end
    end
end

@testitem "gitignore: an ignored folder with tracked files stays visible" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        make_package_repo(root)
        write_file(joinpath(root, "docs", "build", "fixture", "keep.jl"), "# tracked\n")
        write_file(joinpath(root, "docs", "build", "scratch", "drop.jl"), "# not tracked\n")
        LibGit2.with(LibGit2.GitRepo(root)) do repo
            LibGit2.add!(repo, "docs/build/fixture/keep.jl"; flags=LibGit2.Consts.INDEX_ADD_FORCE)
        end

        paths = rel(root, collect_workspace_paths(root))
        @test "docs/build/fixture/keep.jl" in paths
        @test !("docs/build/scratch/drop.jl" in paths)

        f = GitIgnoreFilter([root])
        @test !is_in_ignored_folder(f, joinpath(root, "docs", "build", "fixture", "keep.jl"))
        @test is_in_ignored_folder(f, joinpath(root, "docs", "build", "scratch", "drop.jl"))
    end
end

@testitem "gitignore: nested repositories bring their own rules" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        make_package_repo(root)

        # A clone inside the workspace ignores its own `out/`, which the outer
        # repository knows nothing about.
        inner = joinpath(root, "vendor", "Inner")
        close(LibGit2.init(inner))
        write_file(joinpath(inner, ".gitignore"), "out/\n")
        write_file(joinpath(inner, "src", "Inner.jl"), "module Inner end\n")
        write_file(joinpath(inner, "out", "gen.jl"), "# generated\n")

        # A clone inside an ignored folder is never reached.
        hidden = joinpath(root, "deps", "build", "Hidden")
        close(LibGit2.init(hidden))
        write_file(joinpath(hidden, "src", "Hidden.jl"), "module Hidden end\n")

        paths = rel(root, collect_workspace_paths(root))
        @test "vendor/Inner/src/Inner.jl" in paths
        @test !("vendor/Inner/out/gen.jl" in paths)
        @test !any(startswith("deps/build/"), paths)

        f = GitIgnoreFilter([root])
        @test is_in_ignored_folder(f, joinpath(inner, "out", "gen.jl"))
        @test !is_in_ignored_folder(f, joinpath(inner, "src", "Inner.jl"))
        @test is_in_ignored_folder(f, joinpath(hidden, "src", "Hidden.jl"))
    end
end

@testitem "gitignore: a workspace folder that git ignores is not filtered by those rules" setup=[GitIgnoreRepos] begin
    mktempdir() do outer
        # Like a dotfiles repository in the home folder that ignores everything.
        close(LibGit2.init(outer))
        write_file(joinpath(outer, ".gitignore"), "/*\n!/.gitignore\nbuild/\n")
        ws = joinpath(outer, "Project1")
        write_file(joinpath(ws, "src", "a.jl"), "a() = 1\n")
        write_file(joinpath(ws, "build", "b.jl"), "b() = 1\n")

        @test rel(ws, collect_workspace_paths(ws)) == ["build/b.jl", "src/a.jl"]
        @test !is_in_ignored_folder(GitIgnoreFilter([ws]), joinpath(ws, "build", "b.jl"))
    end
end

@testitem "gitignore: folders outside any repository are walked as before" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        write_file(joinpath(root, ".gitignore"), "build/\n")   # no repository: no rules
        write_file(joinpath(root, "build", "b.jl"), "b() = 1\n")
        @test rel(root, collect_workspace_paths(root)) == ["build/b.jl"]
        @test !is_in_ignored_folder(GitIgnoreFilter([root]), joinpath(root, "build", "b.jl"))
    end
end

@testitem "gitignore: a CPack copy in an ignored folder is not a standalone package (c54)" setup=[GitIgnoreRepos] begin
    using JuliaWorkspaces: JuliaWorkspace, add_folder_from_disc!, derived_required_dynamic_projects,
        CreateStandaloneProjectKey

    mktempdir() do root
        full = make_package_repo(root)
        is_staged_copy(k) = k isa CreateStandaloneProjectKey && lowercase(k.package_path) == lowercase(full)

        # The control: walked without the filter, the staged copy is a package
        # of its own that needs a standalone project (and an indexing child).
        unfiltered = JuliaWorkspace()
        add_folder_from_disc!(unfiltered, root; gitignore=nothing)
        @test any(is_staged_copy, derived_required_dynamic_projects(unfiltered.runtime))

        jw = JuliaWorkspace()
        add_folder_from_disc!(jw, root)
        @test !any(is_staged_copy, derived_required_dynamic_projects(jw.runtime))
    end
end
