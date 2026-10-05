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
# The rules are read straight from the files git reads, without git or libgit2:
# `.gitignore` files at every level and the repository's `info/exclude`, with
# gitignore's pattern syntax (see `_parse_ignore_line`). The user's global
# excludes file (`core.excludesFile`) is not read: it is personal configuration
# that says nothing about which folders belong to a project.

# Path comparisons follow the file system: case-insensitive on Windows.
_path_key(path::AbstractString) = Sys.iswindows() ? lowercase(path) : String(path)

# Forward slashes, no trailing slash: the form ignore rules are matched in.
function _normalize_git_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    while length(p) > 1 && endswith(p, '/') && !endswith(p, ":/")
        p = chop(p)
    end
    return p
end

# `path` relative to the folder `base` (both normalized), or `nothing` when it
# is not strictly below it.
function _git_relpath(path::String, base::String)
    prefix = endswith(base, '/') ? base : base * "/"
    startswith(_path_key(path), _path_key(prefix)) || return nothing
    rel = path[nextind(path, lastindex(prefix)):end]
    return isempty(rel) ? nothing : rel
end

struct _IgnoreRule
    regex::Regex
    negated::Bool
end

"""
    _gitignore_body(pat) -> String

The regex for a gitignore pattern body. A backslash escapes the next character;
everything else is the glob syntax shared with the tool config files
([`_glob_body`](@ref)).
"""
function _gitignore_body(pat::AbstractString)
    io = IOBuffer()
    run = IOBuffer()
    escaped = false
    for c in pat
        if escaped
            print(io, _glob_body(String(take!(run))))
            print(io, _regex_escape_char(c))
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            print(run, c)
        end
    end
    print(io, _glob_body(String(take!(run))))
    return String(take!(io))
end

"""
    _parse_ignore_line(line, ignorecase) -> Union{_IgnoreRule,Nothing}

One line of a `.gitignore` (or `info/exclude`) file, as gitignore(5) reads it:
blank lines and `#` comments are skipped, trailing spaces are dropped unless
escaped, `!` negates, a leading `\\` makes `#`/`!` literal. A pattern with a
`/` at the start or in the middle is anchored to the file's folder; otherwise
it matches at any depth below it. A trailing `/` restricts a pattern to
folders, which is all this matcher is ever asked about.
"""
function _parse_ignore_line(line::AbstractString, ignorecase::Bool)
    line = chomp(line)
    endswith(line, '\r') && (line = chop(line))
    isempty(line) && return nothing
    startswith(line, '#') && return nothing

    # Trailing spaces go, unless the last one is escaped.
    while endswith(line, ' ') && !endswith(line, "\\ ")
        line = chop(line)
    end

    negated = false
    if startswith(line, '!')
        negated = true
        line = line[nextind(line, 1):end]
    end

    endswith(line, '/') && (line = chop(line))
    isempty(line) && return nothing

    anchored = occursin('/', line)
    startswith(line, '/') && (line = line[nextind(line, 1):end])
    isempty(line) && return nothing

    regex = Regex(string("^", anchored ? "" : "(?:.*/)?", _gitignore_body(line), "\$"),
        ignorecase ? "i" : "")
    return _IgnoreRule(regex, negated)
end

function _read_ignore_rules(path::AbstractString, ignorecase::Bool)
    content = try
        read(path, String)
    catch err
        is_walkdir_error(err) || rethrow()
        return _IgnoreRule[]
    end
    rules = _IgnoreRule[]
    for line in eachline(IOBuffer(content))
        rule = _parse_ignore_line(line, ignorecase)
        rule === nothing || push!(rules, rule)
    end
    return rules
end

struct _GitRepo
    root::String           # normalized work tree folder
    ignorecase::Bool       # `core.ignorecase`
    exclude::Vector{_IgnoreRule}   # `info/exclude`, relative to `root`
end

# The rules that judge the entries of one folder: those of the repository's
# `info/exclude` and of every `.gitignore` from the work tree root down to
# that folder, outermost (lowest precedence) first.
struct _IgnoreContext
    repo::_GitRepo
    levels::Vector{Tuple{String,Vector{_IgnoreRule}}}
end

"""
    GitIgnoreFilter(roots)

Decides which folders below the workspace folders `roots` git ignores. Used by
[`collect_workspace_paths`](@ref) to prune the walk, and by hosts through
[`is_in_ignored_folder`](@ref) to drop file watcher events.

The rules are those of the `.gitignore` files and of the repository's
`info/exclude`; git itself is not needed. A workspace folder is never ignored
because of rules above it: opening a folder that git ignores (a dotfiles
repository in the home folder that ignores `/*`, say) must not hide all of it.
Below a folder that contains a `.git`, that nested repository's rules apply.

The filter caches the rules it has read, so it does not notice later edits to
them. Build a new one when that matters (a language server does when a
`.gitignore` changes).
"""
mutable struct GitIgnoreFilter
    roots::Vector{String}
    repos::Dict{String,_GitRepo}
    gitignores::Dict{Tuple{String,Bool},Vector{_IgnoreRule}}
    root_contexts::Dict{String,Union{Nothing,_IgnoreContext}}

    GitIgnoreFilter(roots) = new(String[abspath(String(r)) for r in roots],
        Dict{String,_GitRepo}(),
        Dict{Tuple{String,Bool},Vector{_IgnoreRule}}(),
        Dict{String,Union{Nothing,_IgnoreContext}}())
end

# A `.git` file (a worktree or submodule checkout) names the real git dir.
function _git_dir(work_tree::AbstractString)
    dotgit = joinpath(work_tree, ".git")
    isdir(dotgit) && return dotgit
    isfile(dotgit) || return nothing
    line = try
        readline(dotgit)
    catch err
        is_walkdir_error(err) || rethrow()
        return nothing
    end
    m = match(r"^gitdir:\s*(.*?)\s*$", line)
    m === nothing && return nothing
    return normpath(isabspath(m[1]) ? m[1] : joinpath(work_tree, m[1]))
end

# Where `info/exclude` and the shared `config` live: a linked worktree's git
# dir points at the main one through `commondir`.
function _git_common_dir(git_dir::AbstractString)
    commondir = joinpath(git_dir, "commondir")
    isfile(commondir) || return git_dir
    rel = try
        strip(read(commondir, String))
    catch err
        is_walkdir_error(err) || rethrow()
        return git_dir
    end
    return normpath(isabspath(rel) ? rel : joinpath(git_dir, rel))
end

# `core.ignorecase` from a git config file. `git init` sets it on file systems
# that ignore case (Windows, macOS by default).
function _git_config_ignorecase(config_path::AbstractString)
    lines = try
        readlines(config_path)
    catch err
        is_walkdir_error(err) || rethrow()
        return false
    end
    section = ""
    for line in lines
        s = strip(line)
        (isempty(s) || startswith(s, '#') || startswith(s, ';')) && continue
        m = match(r"^\[\s*([^\]\s\"]+)", s)
        if m !== nothing
            section = lowercase(m[1])
            continue
        end
        section == "core" || continue
        kv = match(r"^([A-Za-z0-9-]+)\s*(?:=\s*(.*?))?\s*$", s)
        kv === nothing && continue
        lowercase(kv[1]) == "ignorecase" || continue
        value = kv[2] === nothing ? "true" : lowercase(kv[2])
        return value in ("true", "yes", "on", "1")
    end
    return false
end

# The repository whose work tree is `work_tree` (a folder holding a `.git`).
function _git_repo(f::GitIgnoreFilter, work_tree::AbstractString)
    key = _path_key(abspath(work_tree))
    haskey(f.repos, key) && return f.repos[key]

    git_dir = _git_dir(work_tree)
    ignorecase = false
    exclude = _IgnoreRule[]
    if git_dir !== nothing
        common = _git_common_dir(git_dir)
        ignorecase = _git_config_ignorecase(joinpath(common, "config"))
        exclude = _read_ignore_rules(joinpath(common, "info", "exclude"), ignorecase)
    end
    repo = _GitRepo(_normalize_git_path(abspath(work_tree)), ignorecase, exclude)
    f.repos[key] = repo
    return repo
end

function _gitignore_rules(f::GitIgnoreFilter, dir::AbstractString, ignorecase::Bool)
    key = (_path_key(abspath(dir)), ignorecase)
    get!(f.gitignores, key) do
        path = joinpath(dir, ".gitignore")
        isfile(path) ? _read_ignore_rules(path, ignorecase) : _IgnoreRule[]
    end
end

# Whether the rules of `ctx` ignore the folder `path`.
function _is_ignored(ctx::_IgnoreContext, path::AbstractString)
    p = _normalize_git_path(abspath(path))
    ignored = false
    for (base, rules) in Iterators.flatten((((ctx.repo.root, ctx.repo.exclude),), ctx.levels))
        isempty(rules) && continue
        rel = _git_relpath(p, base)
        rel === nothing && continue
        for rule in rules
            occursin(rule.regex, rel) && (ignored = !rule.negated)
        end
    end
    return ignored
end

_is_excluded_dir(ctx::Union{Nothing,_IgnoreContext}, dir::AbstractString) =
    ctx !== nothing && _is_ignored(ctx, dir)

"""
    _child_context(f, ctx, dir, has_git_entry) -> Union{Nothing,_IgnoreContext}

The rules that judge the entries of `dir`, given `ctx`, the rules that judged
`dir` itself: `dir`'s own `.gitignore` joins them, and a folder holding a
`.git` (a nested clone, submodule or worktree) starts over with its own
repository.
"""
function _child_context(f::GitIgnoreFilter, ctx::Union{Nothing,_IgnoreContext}, dir::AbstractString, has_git_entry::Bool)
    if has_git_entry
        repo = _git_repo(f, dir)
        return _IgnoreContext(repo, [(repo.root, _gitignore_rules(f, dir, repo.ignorecase))])
    end
    ctx === nothing && return nothing
    rules = _gitignore_rules(f, dir, ctx.repo.ignorecase)
    isempty(rules) && return ctx
    return _IgnoreContext(ctx.repo, vcat(ctx.levels, [(_normalize_git_path(abspath(dir)), rules)]))
end

_has_git_entry(dir::AbstractString) = ispath(joinpath(dir, ".git"))

function _path_components(path::AbstractString, base::AbstractString)
    rest = path[nextind(path, lastindex(base)):end]
    return [c for c in splitpath(rest) if !(c in ("/", "\\", ""))]
end

# The rules that judge the workspace folder `root` itself: those of the
# repository around it, from its work tree root down to `root`'s parent.
# `nothing` when `root` is in no repository, is a work tree root itself (no
# rules judge it), or is ignored by its repository: the user opened that
# folder on purpose, so those rules do not apply below it.
function _root_context(f::GitIgnoreFilter, root::String)
    key = _path_key(root)
    haskey(f.root_contexts, key) && return f.root_contexts[key]

    work_tree = nothing
    dir = root
    while true
        if _has_git_entry(dir)
            work_tree = dir
            break
        end
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end

    ctx = nothing
    if work_tree !== nothing && _path_key(work_tree) != _path_key(root)
        cur = work_tree
        ctx = _child_context(f, nothing, cur, true)
        for component in _path_components(root, work_tree)
            next = joinpath(cur, component)
            if _is_excluded_dir(ctx, next)
                ctx = nothing
                break
            end
            next == root || (ctx = _child_context(f, ctx, next, _has_git_entry(next)))
            cur = next
        end
    end

    f.root_contexts[key] = ctx
    return ctx
end

function _is_within(path::AbstractString, root::AbstractString)
    p, r = _path_key(path), _path_key(root)
    p == r && return true
    return startswith(p, endswith(r, Base.Filesystem.path_separator) ? r : r * Base.Filesystem.path_separator)
end

"""
    _governing_context(f, dir) -> (excluded::Bool, ctx)

Walk from the workspace folder containing `dir` down to `dir`. `excluded` says
whether `dir` is in an ignored folder; `ctx` holds the rules that judged `dir`
itself (only meaningful when it is not excluded).
"""
function _governing_context(f::GitIgnoreFilter, dir::AbstractString)
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

    ctx = _root_context(f, root)
    cur = root
    for component in _path_components(dir, root)
        ctx = _child_context(f, ctx, cur, _has_git_entry(cur))
        cur = joinpath(cur, component)
        _is_excluded_dir(ctx, cur) && return (true, ctx)
    end
    return (false, ctx)
end

"""
    is_in_ignored_folder(f::GitIgnoreFilter, path) -> Bool

Whether the file or folder at `path` is in a folder that git ignores, by the
rules described at [`GitIgnoreFilter`](@ref). `path` itself counts when it is
a folder; a file is never ignored on its own, only through its folders.
"""
function is_in_ignored_folder(f::GitIgnoreFilter, path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    return _governing_context(f, dir)[1]
end
