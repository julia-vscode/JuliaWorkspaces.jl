# ── Git-ignored folders ─────────────────────────────────────────────────────
#
# Folders that git ignores (build output such as `deps/build/`, `docs/build/`,
# coverage trees) are not part of a workspace: they are never walked, and a
# host should not add files from them when its file watcher reports changes.
# Indexing them is not just wasted work. A CPack staging folder, for example,
# holds a verbatim copy of the package's `Project.toml`, which made it a second
# package with its own standalone environment, and every `cpack` run re-created
# it and started another indexing child.
#
# Only *folders* are ignored, never single files: `Manifest.toml` is gitignored
# in many Julia packages, and dropping it would break environment detection.
#
# The rules are git's own, evaluated by libgit2: `.gitignore` files at every
# level, `.git/info/exclude`, `core.excludesFile` and negations. Anything that
# stops us from asking git (no repository, a bare one, one libgit2 refuses to
# open) means "nothing is ignored".

# libgit2 has an `ignore` API, but the LibGit2 stdlib does not wrap it.
const _libgit2 = LibGit2.LibGit2_jll.libgit2

# Path comparisons follow the file system: case-insensitive on Windows.
_path_key(path::AbstractString) = Sys.iswindows() ? lowercase(path) : String(path)

struct _GitRepoInfo
    repo::LibGit2.GitRepo
    # Forward slashes, no trailing slash.
    workdir::String
    # Asked whether anything beneath an ignored folder is tracked.
    index::LibGit2.GitIndex
end

"""
    GitIgnoreFilter(roots)

Decides which folders below the workspace folders `roots` git ignores. Used by
[`collect_workspace_paths`](@ref) to prune the walk, and by hosts through
[`is_in_ignored_folder`](@ref) to drop file watcher events.

A folder is ignored when git's ignore rules match it and no file beneath it is
tracked, so a fixture force-added under an ignored path stays visible. A
workspace folder is never ignored because of rules above it: opening a folder
that git ignores (a dotfiles repository in the home folder that ignores `/*`,
say) must not hide all of it. Below a folder that contains a `.git`, that
nested repository's rules apply.

The filter caches repositories and their index, so it does not notice later
changes to ignore rules or to what is tracked. Build a new one when that
matters (a language server does when a `.gitignore` changes).
"""
mutable struct GitIgnoreFilter
    roots::Vector{String}
    # Repository governing each folder it was asked about, `nothing` when none.
    repos_by_dir::Dict{String,Union{Nothing,_GitRepoInfo}}
    # Shared by every folder of one repository, so the index is read once.
    repos_by_workdir::Dict{String,_GitRepoInfo}
    # Repository whose rules govern a root, `nothing` when the root is not in
    # a repository or the repository ignores the root itself.
    root_repos::Dict{String,Union{Nothing,_GitRepoInfo}}

    GitIgnoreFilter(roots) = new(String[abspath(String(r)) for r in roots],
        Dict{String,Union{Nothing,_GitRepoInfo}}(),
        Dict{String,_GitRepoInfo}(),
        Dict{String,Union{Nothing,_GitRepoInfo}}())
end

function _normalize_git_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    while length(p) > 1 && endswith(p, '/') && !endswith(p, ":/")
        p = chop(p)
    end
    return p
end

# `path` relative to the work tree, with forward slashes; `""` for the work
# tree itself and `nothing` outside it.
function _workdir_relpath(info::_GitRepoInfo, path::AbstractString)
    p = _normalize_git_path(abspath(path))
    w = info.workdir
    _path_key(p) == _path_key(w) && return ""
    prefix = endswith(w, '/') ? w : w * "/"
    startswith(_path_key(p), _path_key(prefix)) || return nothing
    return p[nextind(p, lastindex(prefix)):end]
end

# Whether the index tracks any file beneath the folder `rel`. Asks libgit2 by
# prefix rather than walking entries: the stdlib's `LibGit2.IndexEntry` does
# not match libgit2's `git_index_entry` layout, so reading entries through it
# yields garbage paths. The index compares case-insensitively when the
# repository does (`core.ignorecase`).
function _tracks_anything_beneath(info::_GitRepoInfo, rel::AbstractString)
    pos = Ref{Csize_t}(0)
    err = ccall((:git_index_find_prefix, _libgit2), Cint,
        (Ptr{Csize_t}, Ptr{Cvoid}, Cstring), pos, info.index.ptr, rel * "/")
    return err == 0
end

# The repository whose work tree contains `dir` (git's own upward search).
function _repo_info(f::GitIgnoreFilter, dir::AbstractString)
    dir_key = _path_key(abspath(dir))
    haskey(f.repos_by_dir, dir_key) && return f.repos_by_dir[dir_key]

    info = try
        repo = LibGit2.GitRepoExt(String(dir))
        if LibGit2.isbare(repo)
            close(repo)
            nothing
        else
            workdir = _normalize_git_path(LibGit2.workdir(repo))
            existing = get(f.repos_by_workdir, _path_key(workdir), nothing)
            if existing !== nothing
                close(repo)
                existing
            else
                new_info = _GitRepoInfo(repo, workdir, LibGit2.GitIndex(repo))
                f.repos_by_workdir[_path_key(workdir)] = new_info
                new_info
            end
        end
    catch err
        # No repository, or one libgit2 will not open (an unsafe owner, a
        # corrupt index): nothing is ignored, as without git.
        err isa LibGit2.GitError || rethrow()
        @debug "No usable git repository for folder; not filtering ignored folders" dir exception=err
        nothing
    end

    f.repos_by_dir[dir_key] = info
    return info
end

function _git_ignores_dir(info::_GitRepoInfo, rel::AbstractString)
    ignored = Ref{Cint}(0)
    # A trailing slash makes directory-only patterns (`build/`) match.
    err = ccall((:git_ignore_path_is_ignored, _libgit2), Cint,
        (Ptr{Cint}, Ptr{Cvoid}, Cstring), ignored, info.repo.ptr, rel * "/")
    return err == 0 && ignored[] == 1
end

# Whether the walk must not enter `dir`, under the rules of `info`.
function _is_excluded_dir(info::Union{Nothing,_GitRepoInfo}, dir::AbstractString)
    info === nothing && return false
    rel = _workdir_relpath(info, dir)
    (rel === nothing || isempty(rel)) && return false
    _git_ignores_dir(info, rel) || return false
    return !_tracks_anything_beneath(info, rel)
end

# The rules that govern `dir`'s children, given those that govern `dir`: a
# folder holding a `.git` (a nested clone, submodule or worktree) brings its
# own repository.
function _child_repo_info(f::GitIgnoreFilter, info::Union{Nothing,_GitRepoInfo}, dir::AbstractString, has_git_entry::Bool)
    has_git_entry || return info
    return something(_repo_info(f, dir), Some(info))
end

function _root_repo_info(f::GitIgnoreFilter, root::String)
    key = _path_key(root)
    haskey(f.root_repos, key) && return f.root_repos[key]
    info = _repo_info(f, root)
    if info !== nothing
        rel = _workdir_relpath(info, root)
        # The root itself is ignored by its repository: the user opened an
        # ignored folder on purpose, so its repository's rules do not apply.
        if rel === nothing || (!isempty(rel) && _git_ignores_dir(info, rel))
            info = nothing
        end
    end
    f.root_repos[key] = info
    return info
end

function _is_within(path::AbstractString, root::AbstractString)
    p, r = _path_key(path), _path_key(root)
    p == r && return true
    return startswith(p, endswith(r, Base.Filesystem.path_separator) ? r : r * Base.Filesystem.path_separator)
end

"""
    _governing_repo_info(f, dir) -> (excluded::Bool, info)

Walk from the workspace folder containing `dir` down to `dir`. `excluded` says
whether `dir` is in an ignored folder; `info` is the repository whose rules
govern `dir`'s children (only meaningful when not excluded).
"""
function _governing_repo_info(f::GitIgnoreFilter, dir::AbstractString)
    dir = abspath(String(dir))
    root = nothing
    for r in f.roots
        if _is_within(dir, r) && (root === nothing || length(r) > length(root))
            root = r
        end
    end
    # Outside every workspace folder (or no folders given): `dir` is its own
    # root, so only what lies below it can be ignored.
    root === nothing && (root = dir)

    info = _root_repo_info(f, root)
    info = _child_repo_info(f, info, root, ispath(joinpath(root, ".git")))
    cur = root
    rest = dir[nextind(dir, lastindex(root)):end]
    for component in splitpath(rest)
        component in ("/", "\\", "") && continue
        cur = joinpath(cur, component)
        _is_excluded_dir(info, cur) && return (true, info)
        info = _child_repo_info(f, info, cur, ispath(joinpath(cur, ".git")))
    end
    return (false, info)
end

"""
    is_in_ignored_folder(f::GitIgnoreFilter, path) -> Bool

Whether the file or folder at `path` is in a folder that git ignores, by the
rules described at [`GitIgnoreFilter`](@ref). `path` itself counts when it is
a folder; a file is never ignored on its own, only through its folders.
"""
function is_in_ignored_folder(f::GitIgnoreFilter, path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    return _governing_repo_info(f, dir)[1]
end
