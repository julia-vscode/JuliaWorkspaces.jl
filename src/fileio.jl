function our_isvalid(s)
    return isvalid(s) && !occursin('\0', s)
end

function is_path_project_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="project.toml" || basename_lower_case=="juliaproject.toml"
end

function is_path_manifest_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    # Manifest.toml, Manifest-v1.11.toml, JuliaManifest.toml, etc.
    return occursin(r"^(julia)?manifest(\-v\d+(\.\d+)*)?\.toml$", basename_lower_case)
end

function is_path_lintconfig_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == "julialint.toml"
end

function is_path_formatconfig_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == "juliaformat.toml"
end

function is_path_testitemsconfig_file(path)
    isvalid(path) || return false
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case == "juliatestitems.toml"
end

is_path_toolconfig_file(path) =
    is_path_lintconfig_file(path) || is_path_formatconfig_file(path) || is_path_testitemsconfig_file(path)

function is_path_julia_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".jl"
end

function is_path_markdown_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".md"
end

function is_path_juliamarkdown_file(path)
    _, ext = splitext(path)

    return isvalid(ext) && lowercase(ext) == ".jmd"
end

is_walkdir_error(_) = false
is_walkdir_error(::Base.IOError) = true
is_walkdir_error(::Base.SystemError) = true
is_walkdir_error(err::Base.TaskFailedException) = is_walkdir_error(err.task.exception)

function read_text_file_from_uri(uri::URI; return_nothing_on_io_error=false)
    if uri.scheme !== "file"
        if return_nothing_on_io_error
            return nothing
        else
            error("Trying to read non-file content from $uri.")
        end
    end
    path = uri2filepath(uri)

    language_id = if is_path_julia_file(path)
        "julia"
    elseif is_path_project_file(path)
        "toml"
    elseif is_path_manifest_file(path)
        "toml"
    elseif is_path_toolconfig_file(path)
        "toml"
    elseif is_path_markdown_file(path)
        "markdown"
    elseif is_path_juliamarkdown_file(path)
        "juliamarkdown"
    else
        if return_nothing_on_io_error
            return nothing
        else
            throw(JWUnknownFileType("Unknown file type for $uri"))
        end
    end

    content = try
        read(path, String)
    catch err
        if return_nothing_on_io_error && is_walkdir_error(err)
            return nothing
        else
            rethrow(err)
        end
    end

    if !our_isvalid(content)
        if return_nothing_on_io_error
            return nothing
        else
            throw(JWInvalidFileContent("Invalid content in file $uri."))
        end
    end

    return TextFile(uri, SourceText(content, language_id))
end

# Directory names that are never worth descending into. See issue #1415 for details.
const SKIPPED_DIRNAMES = Set([".git", ".svn", ".hg", "node_modules"])

# ── Scoped walking ──────────────────────────────────────────────────────────
#
# The `include`/`exclude` globs of the three tool config files are normally
# applied per file, far downstream of the walk, by the Salsa queries in
# `layer_testitems.jl` / `layer_diagnostics.jl` / `layer_formatting.jl`. That is
# the right thing for a language server, which must see files no config selected
# in order to answer go-to-definition across them.
#
# For a batch tool it is the wrong thing: `juliati` in a repository that keeps a
# few hundred thousand `.jl` files of test data under an excluded directory
# should never `readdir` that directory at all. Passing `scope` makes the walk
# itself honour one named config kind, so the excluded subtree is never touched.

"""
The config kinds a walk can be scoped to, each mapped to the predicate that
recognises that kind's config file.
"""
const SCOPE_CONFIG_PREDICATES = (
    testitems = is_path_testitemsconfig_file,
    lint = is_path_lintconfig_file,
    format = is_path_formatconfig_file,
)

# The `(config directory, filter)` pairs of one config kind that govern a
# directory, outermost first.
const ConfigChain = Vector{Tuple{String,PathFilter}}

_normalize_scope(::Nothing) = Symbol[]
_normalize_scope(kind::Symbol) = _normalize_scope((kind,))

function _normalize_scope(kinds)
    res = Symbol[]
    for k in kinds
        s = Symbol(k)
        haskey(SCOPE_CONFIG_PREDICATES, s) || throw(ArgumentError(
            "Unknown scope $(repr(s)), expected one of " *
            join((repr(k) for k in keys(SCOPE_CONFIG_PREDICATES)), ", ") * "."))
        s in res || push!(res, s)
    end
    return res
end

"""
    _read_path_filter(path) -> Union{PathFilter,Nothing}

The `include`/`exclude` globs of the config file at `path`, or `nothing` when it
cannot be read or parsed.

Deliberately fails open: a malformed config file must not silently hide a whole
subtree from the walk. Its `config_errors` diagnostic still comes from the
regular Salsa path once the file is part of the workspace.
"""
function _read_path_filter(path::AbstractString)
    content = try
        read(path, String)
    catch err
        is_walkdir_error(err) || rethrow()
        return nothing
    end
    our_isvalid(content) || return nothing

    table = Pkg.TOML.tryparse(content)
    table isa Pkg.TOML.ParserError && return nothing

    discard = Diagnostic[]
    return parse_path_filter!(discard, table)
end

"""
    _scope_admits(chains, path, is_dir) -> Bool

Whether `path` survives the walk, given one [`ConfigChain`](@ref) per requested
scope kind.

Within one kind the chain is an intersection, exactly as
[`scope_selected`](@ref) resolves it downstream: every enclosing config of that
kind must admit the path. Across kinds it is a **union** — a caller that asks
for several kinds is building one workspace to serve all of them, so a file any
one of them wants must be read. A kind with no config file anywhere above `path`
admits everything, which is why asking for several kinds prunes only what all of
them exclude.
"""
function _scope_admits(chains::Vector{ConfigChain}, path::AbstractString, is_dir::Bool)
    isempty(chains) && return true

    for chain in chains
        admitted = true
        for (config_dir, filter) in chain
            rel = config_relative_path(config_dir, path)
            rel === nothing && continue     # unreachable: the chain is prefix-matched
            if !(is_dir ? dir_selected(filter, rel) : path_selected(filter, rel))
                admitted = false
                break
            end
        end
        admitted && return true
    end

    return false
end

"""
    collect_workspace_paths(root; scope=nothing, file_limit=nothing)
        -> Union{Vector{String},Nothing}

Every workspace-relevant file under the local directory `root`: Julia sources,
`Project.toml`/`Manifest.toml`, the three tool config files, Markdown and Julia
Markdown.

`scope` restricts the walk to what one or more config kinds select — a
`Symbol` or a collection of them, drawn from `keys(SCOPE_CONFIG_PREDICATES)`
(`:testitems`, `:lint`, `:format`). Directories that provably cannot hold a
selected file are never descended into, so an excluded subtree costs nothing at
all. `nothing`, the default, walks everything.

`Project.toml`, `Manifest.toml` and config files are kept even when the globs do
not select them, as long as their directory survives: they carry package and
environment attribution, and the per-file queries downstream need the config
files themselves in order to agree with this walk.

When `file_limit` is set and more than that many Julia files are selected,
returns `nothing` — the tree is deemed too large to load. Callers passing a
`file_limit` must handle that.
"""
function collect_workspace_paths(root::AbstractString; scope=nothing, file_limit::Union{Nothing,Int}=nothing)
    kinds = _normalize_scope(scope)
    predicates = Any[SCOPE_CONFIG_PREDICATES[k] for k in kinds]

    result = String[]
    julia_file_count = 0

    # Each queued directory carries the config chains that govern it. Breadth
    # first, so a directory is only dequeued once every ancestor has contributed
    # its config files. Explicit walk instead of `walkdir` because it's hard to
    # stop it from recursing into the skipped directories.
    remaining_dirs = Tuple{String,Vector{ConfigChain}}[(String(root), ConfigChain[ConfigChain() for _ in kinds])]

    while !isempty(remaining_dirs)
        dir, chains = popfirst!(remaining_dirs)
        yield()

        entries = try
            readdir(dir, join=true)
        catch
            continue
        end

        # Stat once per entry: both the config scan and the dispatch below need
        # to know whether an entry is a directory.
        stated = Tuple{String,Bool}[]
        for filepath in entries
            is_dir = try
                !islink(filepath) && isdir(filepath)
            catch err
                # Foreign/broken reparse points (e.g. WSL-created symlinks) make
                # lstat throw on Julia 1.11+; skip entries we cannot stat.
                is_walkdir_error(err) || rethrow()
                continue
            end
            push!(stated, (filepath, is_dir))
        end

        # A config file governs the directory it lives in, so fold it into the
        # chain before deciding anything about this directory's entries.
        for (i, pred) in enumerate(predicates)
            for (filepath, is_dir) in stated
                (is_dir || !pred(filepath)) && continue
                filter = _read_path_filter(filepath)
                filter === nothing && break
                chains = copy(chains)   # shared with the queued sibling directories
                chains[i] = push!(copy(chains[i]), (_normalize_dir(dir), filter))
                break
            end
        end

        for (filepath, is_dir) in stated
            if is_dir
                basename(filepath) ∈ SKIPPED_DIRNAMES && continue
                _scope_admits(chains, filepath, true) || continue
                push!(remaining_dirs, (filepath, chains))
            elseif is_path_julia_file(filepath)
                _scope_admits(chains, filepath, false) || continue
                julia_file_count += 1
                if file_limit !== nothing && julia_file_count > file_limit
                    return nothing
                end
                push!(result, filepath)
            elseif is_path_project_file(filepath) ||
                        is_path_manifest_file(filepath) ||
                        is_path_toolconfig_file(filepath)
                push!(result, filepath)
            elseif is_path_markdown_file(filepath) || is_path_juliamarkdown_file(filepath)
                _scope_admits(chains, filepath, false) || continue
                push!(result, filepath)
            end
        end
    end

    return result
end

"""
    read_path_into_textdocuments(uri; ignore_io_errors=false, file_limit=nothing, scope=nothing)
        -> Union{Vector{TextFile}, Nothing}

Read every workspace-relevant file (Julia sources, Project/Manifest, lint/format
configs, Markdown) under the folder `uri` into `TextFile`s.

`scope` restricts the walk to what one or more config kinds select; see
[`collect_workspace_paths`](@ref), which does the walking. The default `nothing`
reads the whole tree.

When `file_limit` is set and the tree contains more than that many Julia files,
returns `nothing` (the tree is deemed too large to load) — the count is checked
before any content is read. Otherwise returns the collected `Vector{TextFile}`
(possibly empty). Callers that pass a `file_limit` must handle the `nothing`
return.

With `ignore_io_errors`, a non-`file` URI yields an empty vector and unreadable
files are skipped; otherwise both throw.
"""
function read_path_into_textdocuments(uri::URI; ignore_io_errors=false, file_limit::Union{Nothing,Int}=nothing, scope=nothing)
    result = TextFile[]

    if uri.scheme !== "file"
        if ignore_io_errors
            return result
        else
            error("Trying to read non-file content from $uri.")
        end
    end

    path = uri2filepath(uri)

    # Collect paths first so an over-limit tree aborts before any content is
    # read; contents are read afterwards with per-file yields.
    candidate_paths = collect_workspace_paths(path; scope=scope, file_limit=file_limit)
    candidate_paths === nothing && return nothing

    for filepath in candidate_paths
        text_file = read_text_file_from_uri(filepath2uri(filepath), return_nothing_on_io_error=ignore_io_errors)
        text_file === nothing && continue
        push!(result, text_file)
        yield()
    end

    return result
end

"""
    add_file_from_disc!(jw::JuliaWorkspace, path)

Read the file at the local `path` from disc and add it to the workspace `jw` as
a new file (see [`add_file!`](@ref)). The file content is read eagerly and the
file's language is inferred from its extension.

Throws if a file with the same URI is already part of the workspace.
"""
function add_file_from_disc!(jw::JuliaWorkspace, path)
    @debug "add_file_from_disc!" path=path

    process_from_dynamic(jw)

    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    add_file!(jw, text_file)
end

"""
    update_file_from_disc!(jw::JuliaWorkspace, path)

Re-read the file at the local `path` from disc and update its content in the
workspace `jw` (see [`update_file!`](@ref)). Use this to refresh a file whose
on-disc content changed outside of the workspace.

Throws if no file with the corresponding URI is part of the workspace.
"""
function update_file_from_disc!(jw::JuliaWorkspace, path)
    @debug "update_file_from_disc!" path=path

    process_from_dynamic(jw)

    uri = filepath2uri(path)
    text_file = read_text_file_from_uri(uri)

    update_file!(jw, text_file)
end

"""
    add_folder_from_disc!(jw::JuliaWorkspace, path; ignore_io_errors=false, scope=nothing)

Recursively read all relevant files under the local folder `path` from disc and
add them to the workspace `jw`. Julia sources, `Project.toml`/`Manifest.toml`,
and configuration files are picked up. The whole batch is added before a single
reconciliation step runs, so this is more efficient than calling
[`add_file!`](@ref) per file.

If `ignore_io_errors` is `true`, files that cannot be read are skipped instead
of raising an error. `scope` restricts the walk to what one or more config kinds
select; see [`collect_workspace_paths`](@ref).
"""
function add_folder_from_disc!(jw::JuliaWorkspace, path; ignore_io_errors=false, scope=nothing)
    @debug "add_folder_from_disc!" path=path

    process_from_dynamic(jw)

    path_uri = filepath2uri(path)

    files = read_path_into_textdocuments(path_uri, ignore_io_errors=ignore_io_errors, scope=scope)

    for i in files
        _add_file!(jw, i)
    end

    # Reconcile once after the whole batch rather than after every file.
    _reconcile!(jw)
end

"""
    workspace_from_folders(workspace_folders::Vector{String}; dynamic=DynamicOff, symbolcache_download=false, symbolcache_upstream=DEFAULT_SYMBOLCACHE_UPSTREAM, store_path=nothing, max_concurrent_djps=4, max_alive_djps=DEFAULT_MAX_ALIVE_DJPS, max_failure_attempts=DEFAULT_MAX_FAILURE_ATTEMPTS, djp_request_timeout_seconds=DEFAULT_DJP_REQUEST_TIMEOUT_SECONDS, scope=nothing)

Create a new [`JuliaWorkspace`](@ref) and populate it by recursively reading
every folder in `workspace_folders` from disc. This is the most convenient entry
point for analysing a project that lives on the local file system.

# Keyword arguments
- `dynamic::DynamicMode`: Whether and how to run the out-of-process dynamic
  feature. See [`DynamicMode`](@ref). Defaults to `DynamicOff`.
- `symbolcache_download::Bool`: If `true`, allow downloading precomputed package
  symbol caches from `symbolcache_upstream` instead of indexing locally.
- `symbolcache_upstream::String`: Upstream URL for symbol-cache downloads.
  Defaults to [`DEFAULT_SYMBOLCACHE_UPSTREAM`](@ref).
- `scope`: Restricts the walk to what one or more config kinds select, so an
  excluded subtree is never read from disc. See
  [`collect_workspace_paths`](@ref). Defaults to `nothing`, which reads
  everything.
- `store_path`, `max_concurrent_djps`, `max_alive_djps`, `max_failure_attempts`,
  `djp_request_timeout_seconds`, `progress_callback`: forwarded verbatim to
  [`JuliaWorkspace`](@ref), which documents them.

# Returns
- A [`JuliaWorkspace`](@ref) containing all files found under the given folders.
"""
function workspace_from_folders(workspace_folders::Vector{String}; dynamic::DynamicMode=DynamicOff, symbolcache_download::Bool=false, symbolcache_upstream::String=DEFAULT_SYMBOLCACHE_UPSTREAM, store_path::Union{Nothing,String}=nothing, max_concurrent_djps::Int=4, max_alive_djps::Int=DEFAULT_MAX_ALIVE_DJPS, max_failure_attempts::Int=DEFAULT_MAX_FAILURE_ATTEMPTS, djp_request_timeout_seconds::Int=DEFAULT_DJP_REQUEST_TIMEOUT_SECONDS, progress_callback::Union{Nothing,Function}=nothing, scope=nothing)
    @debug "workspace_from_folders" folders=workspace_folders dynamic=dynamic symbolcache_download=symbolcache_download

    jw = JuliaWorkspace(;dynamic=dynamic, symbolcache_download=symbolcache_download, symbolcache_upstream=symbolcache_upstream, store_path=store_path, max_concurrent_djps=max_concurrent_djps, max_alive_djps=max_alive_djps, max_failure_attempts=max_failure_attempts, djp_request_timeout_seconds=djp_request_timeout_seconds, progress_callback=progress_callback)

    for folder in workspace_folders
        add_folder_from_disc!(jw, folder; scope=scope)
    end
    return jw
end
