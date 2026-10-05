@testsnippet GitIgnoreRepos begin
    using JuliaWorkspaces: collect_workspace_paths, GitIgnoreFilter, is_in_ignored_folder

    write_file(p, c="") = (mkpath(dirname(p)); write(p, c))
    rel(root, paths) = sort([replace(relpath(p, root), '\\' => '/') for p in paths])

    # All the reader needs to know a folder is a work tree.
    init_repo(dir) = mkpath(joinpath(dir, ".git"))

    # The InteractiveGMT shape behind the c54 report: a package whose CPack
    # staging folder holds a verbatim copy of its `Project.toml`, with the
    # build output and the manifest gitignored.
    function make_package_repo(root)
        init_repo(root)
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

@testitem "gitignore: pattern syntax" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        init_repo(root)
        write_file(joinpath(root, ".gitignore"), join([
            "# a comment, then a blank line", "",
            "/anchored", "any_depth", "mid/dle", "out*/", "**/deep", "gen/**",
            "keep*", "!keep_me", "\\#hash", "trailing   ",
        ], "\n"))
        dirs = ["anchored", "sub/anchored", "any_depth", "sub/any_depth", "mid/dle", "sub/mid/dle",
            "out1", "sub/output", "a/b/deep", "gen/x", "keepa", "keep_me", "#hash", "trailing",
            "plain", "# a comment, then a blank line"]
        for d in dirs
            write_file(joinpath(root, d, "f.jl"), "")
        end
        f = GitIgnoreFilter([root])
        ignored(d) = is_in_ignored_folder(f, joinpath(root, d))

        @test ignored("anchored")
        @test !ignored("sub/anchored")          # `/x` only at the .gitignore's folder
        @test ignored("any_depth") && ignored("sub/any_depth")
        @test ignored("mid/dle")
        @test !ignored("sub/mid/dle")           # a middle slash anchors too
        @test ignored("out1") && ignored("sub/output")
        @test ignored("a/b/deep")
        @test ignored("gen/x") && !ignored("gen")   # `x/**` is what is inside x
        @test ignored("keepa") && !ignored("keep_me")   # the last matching rule wins
        @test ignored("#hash")
        @test ignored("trailing")               # trailing spaces are not part of it
        @test !ignored("plain")
        @test !ignored("# a comment, then a blank line")
    end
end

@testitem "gitignore: deeper .gitignore files, negation and info/exclude" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        init_repo(root)
        write_file(joinpath(root, ".git", "info", "exclude"), "scratch/\nlocal_only/\n")
        write_file(joinpath(root, ".gitignore"), "build/\n!local_only/\n")
        write_file(joinpath(root, "pkg", ".gitignore"), "!build/\ntmp/\n")
        for d in ("build", "scratch", "local_only", "pkg/build", "pkg/tmp", "tmp")
            write_file(joinpath(root, d, "f.jl"), "")
        end
        f = GitIgnoreFilter([root])
        ignored(d) = is_in_ignored_folder(f, joinpath(root, d))

        @test ignored("build")
        @test ignored("scratch")                # info/exclude
        @test !ignored("local_only")            # .gitignore outranks info/exclude
        @test !ignored("pkg/build")             # a deeper .gitignore outranks the root one
        @test ignored("pkg/tmp")
        @test !ignored("tmp")                   # pkg/.gitignore says nothing about the root
        @test rel(root, collect_workspace_paths(root)) == ["local_only/f.jl", "pkg/build/f.jl", "tmp/f.jl"]
    end
end

@testitem "gitignore: core.ignorecase and worktree checkouts" setup=[GitIgnoreRepos] begin
    mktempdir() do dir
        main = joinpath(dir, "main")
        write_file(joinpath(main, ".git", "config"), "[core]\n\tbare = false\n\tignorecase = true\n")
        write_file(joinpath(main, ".git", "info", "exclude"), "Shared/\n")
        write_file(joinpath(main, ".gitignore"), "build/\n")
        write_file(joinpath(main, "BUILD", "f.jl"), "")
        @test is_in_ignored_folder(GitIgnoreFilter([main]), joinpath(main, "BUILD"))

        # A linked worktree: its `.git` is a file naming a git dir, whose
        # `commondir` leads back to the main repository's config and excludes.
        wt = joinpath(dir, "wt")
        gitdir = joinpath(main, ".git", "worktrees", "wt")
        write_file(joinpath(gitdir, "commondir"), "../..\n")
        write_file(joinpath(wt, ".git"), "gitdir: $(gitdir)\n")
        write_file(joinpath(wt, ".gitignore"), "build/\n")
        write_file(joinpath(wt, "shared", "f.jl"), "")
        write_file(joinpath(wt, "Build", "f.jl"), "")
        f = GitIgnoreFilter([wt])
        @test is_in_ignored_folder(f, joinpath(wt, "shared"))
        @test is_in_ignored_folder(f, joinpath(wt, "Build"))

        # Without `ignorecase` the case must match.
        other = joinpath(dir, "other")
        init_repo(other)
        write_file(joinpath(other, ".gitignore"), "build/\n")
        write_file(joinpath(other, "BUILD", "f.jl"), "")
        @test !is_in_ignored_folder(GitIgnoreFilter([other]), joinpath(other, "BUILD"))
    end
end

@testitem "gitignore: nested repositories bring their own rules" setup=[GitIgnoreRepos] begin
    mktempdir() do root
        make_package_repo(root)

        # A clone inside the workspace ignores its own `out/`, which the outer
        # repository knows nothing about.
        inner = joinpath(root, "vendor", "Inner")
        init_repo(inner)
        write_file(joinpath(inner, ".gitignore"), "out/\n")
        write_file(joinpath(inner, "src", "Inner.jl"), "module Inner end\n")
        write_file(joinpath(inner, "out", "gen.jl"), "# generated\n")

        # A clone inside an ignored folder is never reached.
        hidden = joinpath(root, "deps", "build", "Hidden")
        init_repo(hidden)
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
        init_repo(outer)
        write_file(joinpath(outer, ".gitignore"), "/*\n!/.gitignore\nbuild/\n")
        ws = joinpath(outer, "Project1")
        write_file(joinpath(ws, "src", "a.jl"), "a() = 1\n")
        write_file(joinpath(ws, "build", "b.jl"), "b() = 1\n")

        @test rel(ws, collect_workspace_paths(ws)) == ["build/b.jl", "src/a.jl"]
        @test !is_in_ignored_folder(GitIgnoreFilter([ws]), joinpath(ws, "build", "b.jl"))

        # A workspace folder below the repository root that is not ignored
        # gets the rules above it.
        write_file(joinpath(outer, ".gitignore"), "build/\n")
        @test rel(ws, collect_workspace_paths(ws)) == ["src/a.jl"]
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

@testitem "gitignore: agrees with git check-ignore" setup=[GitIgnoreRepos] begin
    git = Sys.which("git")
    if git === nothing
        @info "git not found; skipping the comparison with git check-ignore"
    else
        mktempdir() do root
            run(pipeline(`$git init -q $root`; stdout=devnull, stderr=devnull))
            write_file(joinpath(root, ".gitignore"), """
                /deps/build/
                docs/build
                *.out/
                **/cache
                tmp*
                !tmpkeep
                a/**/z
                [Bb]in/
                """)
            write_file(joinpath(root, "pkg", ".gitignore"), "!cache\nlocal/\n")
            dirs = ["deps", "deps/build", "deps/build/x", "x/deps/build", "docs/build", "sub/docs/build",
                "r.out", "sub/r.out", "cache", "p/q/cache", "pkg/cache", "pkg/local", "local",
                "tmp1", "tmpkeep", "a/z", "a/b/c/z", "bin", "Bin", "src"]
            for d in dirs
                mkpath(joinpath(root, d))
            end
            f = GitIgnoreFilter([root])
            for d in dirs
                # The global excludes file is personal configuration and not
                # read by the filter, so keep it out of git's answer too.
                cmd = Cmd(`$git -c core.excludesFile= check-ignore -q --no-index $(d * "/")`; dir=root)
                git_says = success(pipeline(cmd; stdout=devnull, stderr=devnull))
                @test is_in_ignored_folder(f, joinpath(root, d)) == git_says
            end
        end
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

@testitem "gitignore: the CPack copy stays out of the v2 engine too (c54)" setup=[GitIgnoreRepos] begin
    using JuliaWorkspaces: JuliaWorkspace, add_folder_from_disc!, derived_required_dynamic_projects,
        derived_package_folders, derived_v2_workspace_package_roots, set_v2_enabled!
    using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

    mktempdir() do root
        full = make_package_repo(root)
        under_copy(path) = startswith(lowercase(path), lowercase(full))

        jw = JuliaWorkspace()
        add_folder_from_disc!(jw, root)
        set_v2_enabled!(jw, true)
        rt = jw.runtime
        @test !any(f -> under_copy(uri2filepath(f)), derived_package_folders(rt))
        @test !any(k -> under_copy(JuliaWorkspaces._key_folder_path(k)), derived_required_dynamic_projects(rt))
        @test lowercase(uri2filepath(derived_v2_workspace_package_roots(rt)["Pkg1"])) ==
            lowercase(joinpath(root, "src", "Pkg1.jl"))
    end
end
