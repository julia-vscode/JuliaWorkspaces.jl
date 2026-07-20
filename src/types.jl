# Position-aware key for a range field. Empty UnitRanges compare `==`/`isequal`
# regardless of position (`24:23 == 23:22`), so a struct holding a bare
# UnitRange would treat a shifted zero-width span (e.g. a JuliaSyntax EOF
# marker after a trailing-trivia edit) as unchanged — letting Salsa backdating
# keep a stale range whose offset later exceeds the content.
_range_key(r::UnitRange) = (first(r), last(r))

"""
    struct TestItemDetail

Details of a test item.

- uri::URI
- id::String
- name::String
- code::String
- range::UnitRange{Int}
- code_range::UnitRange{Int}
- `option_default_imports`::Bool
- option_tags::Vector{Symbol}
- option_setup::Vector{Symbol}
"""
struct TestItemDetail
    uri::URI
    id::String
    name::String
    code::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
end
_key(x::TestItemDetail) = (x.uri, x.id, x.name, x.code, _range_key(x.range), _range_key(x.code_range), x.option_default_imports, x.option_tags, x.option_setup)
Base.:(==)(a::TestItemDetail, b::TestItemDetail) = _key(a) == _key(b)
Base.isequal(a::TestItemDetail, b::TestItemDetail) = isequal(_key(a), _key(b))
Base.hash(x::TestItemDetail, h::UInt) = hash(_key(x), hash(TestItemDetail, h))

"""
    struct TestSetupDetail

Details of a test setup.

- uri::URI
- name::Symbol
- kind::Symbol
- code::String
- range::UnitRange{Int}
- code_range::UnitRange{Int}
"""
struct TestSetupDetail
    uri::URI
    name::Symbol
    kind::Symbol
    code::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end
_key(x::TestSetupDetail) = (x.uri, x.name, x.kind, x.code, _range_key(x.range), _range_key(x.code_range))
Base.:(==)(a::TestSetupDetail, b::TestSetupDetail) = _key(a) == _key(b)
Base.isequal(a::TestSetupDetail, b::TestSetupDetail) = isequal(_key(a), _key(b))
Base.hash(x::TestSetupDetail, h::UInt) = hash(_key(x), hash(TestSetupDetail, h))

"""
    struct TestErrorDetail

Details of a test error.

- uri::URI
- id::String
- name::Union{Nothing,String}
- message::String
- range::UnitRange{Int}
"""
struct TestErrorDetail
    uri::URI
    id::String
    name::Union{Nothing,String}
    message::String
    range::UnitRange{Int}
end
_key(x::TestErrorDetail) = (x.uri, x.id, x.name, x.message, _range_key(x.range))
Base.:(==)(a::TestErrorDetail, b::TestErrorDetail) = _key(a) == _key(b)
Base.isequal(a::TestErrorDetail, b::TestErrorDetail) = isequal(_key(a), _key(b))
Base.hash(x::TestErrorDetail, h::UInt) = hash(_key(x), hash(TestErrorDetail, h))

"""
    struct TestDetails

Details of a test.

- testitems::Vector{TestItemDetail}
- testsetups::Vector{TestSetupDetail}
- testerrors::Vector{TestErrorDetail}
"""
@auto_hash_equals struct TestDetails
    testitems::Vector{TestItemDetail}
    testsetups::Vector{TestSetupDetail}
    testerrors::Vector{TestErrorDetail}
end

"""
    struct JuliaPackage

Details of a Julia package.

- `project_file_uri`::URI
- name::String
- uuid::UUID
- content_hash::UInt64
"""
@auto_hash_equals struct JuliaPackage
    project_file_uri::URI
    name::String
    uuid::UUID
    content_hash::UInt64
end

"""
    struct JuliaProjectEntryDevedPackage

Details of a Julia project entry for a developed package.

- name::String
- uuid::UUID
- uri::URI
- version::String
"""
@auto_hash_equals struct JuliaProjectEntryDevedPackage
    name::String
    uuid::UUID
    uri::URI
    version::String
end

"""
    struct JuliaProjectEntryRegularPackage

Details of a Julia project entry for a regular package.

- name::String
- uuid::UUID
- version::String
- `git_tree_sha1`::String
"""
@auto_hash_equals struct JuliaProjectEntryRegularPackage
    name::String
    uuid::UUID
    version::String
    git_tree_sha1::String
end

"""
    struct JuliaProjectEntryStdlibPackage

Details of a Julia project entry for a standard library package.

- name::String
- uuid::UUID
- version::Union{Nothing,String}
"""
@auto_hash_equals struct JuliaProjectEntryStdlibPackage
    name::String
    uuid::UUID
    version::Union{Nothing,String}
end

"""
    struct JuliaProject

Details of a Julia project.

- `project_file_uri`::URI
- `manifest_file_uri`::URI
- `julia_version`::Union{Nothing,VersionNumber}
- content_hash::UInt64
- deved_packages::Dict{String,JuliaProjectEntryDevedPackage}
- regular_packages::Dict{String,JuliaProjectEntryRegularPackage}
- stdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}
"""
@auto_hash_equals struct JuliaProject
    project_file_uri::URI
    manifest_file_uri::URI
    julia_version::Union{Nothing,VersionNumber}
    content_hash::UInt64
    deved_packages::Dict{String,JuliaProjectEntryDevedPackage}
    regular_packages::Dict{String,JuliaProjectEntryRegularPackage}
    stdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}
end

"""
    struct JuliaTestEnv

Details of a Julia test environment.

- package_name::String
- package_uri::Union{URI,Nothing}
- project_uri::Union{URI,Nothing}
- `env_content_hash`::Union{UInt,Nothing}
"""
@auto_hash_equals struct JuliaTestEnv
    package_name::Union{String,Nothing}
    package_uri::Union{URI,Nothing}
    project_uri::Union{URI,Nothing}
    env_content_hash::Union{String,Nothing}
end

"""
    struct SourceText

A source text, consisting of its content, line indices, and language ID.

- content::String
- line_indices::Vector{Int}
- language_id::String
"""
@auto_hash_equals struct SourceText
    content::String
    line_indices::Vector{Int}
    language_id::String

    function SourceText(content, language_id)
        line_indices = _compute_line_indices(content)

        return new(content, line_indices, language_id)
    end
end

"""
    struct Position

A position in a source file expressed as a 1-based line number and a 1-based
UTF-8 byte column within that line.

- `line::Int`: 1-based line number.
- `column::Int`: 1-based UTF-8 byte offset from the start of the line.
"""
struct Position
    line::Int    # 1-based
    column::Int  # 1-based, UTF-8 byte offset within the line
end

"""
    position_at(source_text::SourceText, x::Int) -> Position

Convert the 1-based byte offset `x` within `source_text` into a [`Position`](@ref)
(a 1-based line number and a 1-based UTF-8 byte column).
"""
function position_at(source_text::SourceText, x)
    line_indices = source_text.line_indices

    # TODO Implement a more efficient algorithm
    for line in length(line_indices):-1:1
        if x >= line_indices[line]
            return Position(line, x - line_indices[line] + 1)
        end
    end

    error("This should never happen")
end

"""
    _offset_to_position(runtime, uri, offset)

Convert a 0-based byte offset in the file identified by `uri` to a `Position`.
"""
function _offset_to_position(runtime, uri::URI, offset::Int)
    st = input_text_file(runtime, uri).content
    return position_at(st, offset + 1)
end

"""
    struct TextFile

A text file, consisting of its URI and content.

- `uri::URI`: The [`URI`](@ref) of the file.
- `content::SourceText`: The content of the file as [`SourceText`](@ref).
"""
@auto_hash_equals struct TextFile
    uri::URI
    content::SourceText
end

"""
    struct NotebookFile

A notebook file, consisting of its URI and cells.

- `uri::URI`: The [`URI`](@ref) of the file.
- `cells::Vector{SourceText}`: The cells of the notebook as a vector of [`SourceText`](@ref).
"""
@auto_hash_equals struct NotebookFile
    uri::URI
    cells::Vector{SourceText}
end

"""
    struct Diagnostic

A diagnostic struct, consisting of range, severity, message, and source.

- range::UnitRange{Int64}
- severity::Symbol
- message::String
- uri::Union{Nothing,URI}
- tags::Vector{Symbol}
- source::String
"""
struct Diagnostic
    range::UnitRange{Int64}
    severity::Symbol
    message::String
    uri::Union{Nothing,URI}
    tags::Vector{Symbol}
    source::String
end

# Compare ranges by their endpoints, not as `UnitRange`s: all empty ranges are
# `==` regardless of position (`24:23 == 23:22`), which would let Salsa backdate
# a shifted zero-width diagnostic (e.g. an EOF marker after a trailing-trivia
# edit) and keep a stale, now-out-of-bounds range.
function _diag_fields_equal(a::Diagnostic, b::Diagnostic, eq)
    eq(first(a.range), first(b.range)) && eq(last(a.range), last(b.range)) &&
        eq(a.severity, b.severity) && eq(a.message, b.message) &&
        eq(a.uri, b.uri) && eq(a.tags, b.tags) && eq(a.source, b.source)
end
Base.:(==)(a::Diagnostic, b::Diagnostic) = _diag_fields_equal(a, b, ==)
Base.isequal(a::Diagnostic, b::Diagnostic) = _diag_fields_equal(a, b, isequal)
function Base.hash(d::Diagnostic, h::UInt)
    h = hash(first(d.range), h)
    h = hash(last(d.range), h)
    h = hash(d.severity, h)
    h = hash(d.message, h)
    h = hash(d.uri, h)
    h = hash(d.tags, h)
    h = hash(d.source, h)
    return hash(Diagnostic, h)
end

struct SContext
    dynamic_feature::Union{Nothing,DynamicFeature}
    # Optional callback invoked once when an indirect file URI is first
    # requested via the lazy input. Receives the URI; intended for the LS to
    # register an LSP file watcher for future updates. The lazy input itself
    # already loads initial content synchronously from disc.
    indirect_file_watch_callback::Union{Nothing,Function}
end

SContext(dynamic_feature) = SContext(dynamic_feature, nothing)

"""
    struct JuliaWorkspace

The central handle representing a Julia workspace. It wraps a
[`Salsa`](https://github.com/julia-vscode/Salsa.jl) runtime that holds all
mutable inputs (the set of files, the active project, and dynamic-feature
results) and memoizes every derived query computed from them. A workspace is
manipulated through the mutation functions ([`add_file!`](@ref),
[`update_file!`](@ref), [`remove_file!`](@ref), …) and inspected through the
query functions ([`get_diagnostics`](@ref), [`get_julia_syntax_tree`](@ref), …).

# Constructor

    JuliaWorkspace(; dynamic=DynamicOff, store_path=nothing,
                     symbolcache_download=false,
                     symbolcache_upstream=DEFAULT_SYMBOLCACHE_UPSTREAM,
                     indirect_file_watch_callback=nothing,
                     progress_callback=nothing)

Create an empty workspace. To build one directly from folders on disc, use
[`workspace_from_folders`](@ref) instead.

## Keyword arguments
- `dynamic::DynamicMode`: Whether and how to run the out-of-process dynamic
  feature that indexes environments. See [`DynamicMode`](@ref).
- `store_path::Union{Nothing,String}`: Directory used to cache package symbol
  data (`.jstore` files). Defaults to a managed scratch space.
- `symbolcache_download::Bool`: If `true`, allow downloading precomputed symbol
  caches from `symbolcache_upstream` rather than indexing locally.
- `symbolcache_upstream::String`: Upstream URL for symbol-cache downloads.
  Defaults to [`DEFAULT_SYMBOLCACHE_UPSTREAM`](@ref).
- `indirect_file_watch_callback::Union{Nothing,Function}`: Invoked once with a
  `URI` the first time an *indirect* file (a file pulled in via `include` but
  not explicitly added) is requested. Intended for a host to register a file
  watcher.
- `progress_callback::Union{Nothing,Function}`: Invoked as
  `(key::String, message::String, percentage::Int)` with progress updates while
  the dynamic feature indexes environments. `key` identifies the operation
  (each concurrently running operation — downloading caches for a project,
  indexing a project, loading caches — is its own progress bar with the full
  0–100 range); a report with `percentage >= 100` ends that operation's bar.
- `max_concurrent_djps::Int`: Maximum number of concurrently working dynamic
  child processes (`0` disables the limit). Defaults to 4.
- `resolve_workspace_environments::Bool`: When `false`, no standalone package
  projects or test environments are created; only real project environments
  are watched. Defaults to `true`.
"""
struct JuliaWorkspace
    runtime::Salsa.Runtime{SContext,Salsa.DefaultStorage}
    dynamic_feature::Union{Nothing,DynamicFeature}

    function JuliaWorkspace(;dynamic::DynamicMode=DynamicOff, store_path::Union{Nothing,String}=nothing, symbolcache_download::Bool=false, symbolcache_upstream::String=DEFAULT_SYMBOLCACHE_UPSTREAM, indirect_file_watch_callback::Union{Nothing,Function}=nothing, progress_callback::Union{Nothing,Function}=nothing, max_concurrent_djps::Int=4, resolve_workspace_environments::Bool=true)
        if store_path === nothing
            # Tie the local scratch store to the cache format version so a format
            # bump starts fresh instead of reading stale-format caches.
            scratch_key = "store_path_$(SymbolServer.CACHE_STORE_VERSION)"
            store_path = Scratch.@get_scratch!(scratch_key)
        end
        need_dynamic_feature = dynamic != DynamicOff || symbolcache_download
        dynamic_feature = need_dynamic_feature ? DynamicFeature(dynamic, store_path; download_enabled=symbolcache_download, upstream_url=symbolcache_upstream, progress_callback=progress_callback, max_concurrent_djps=max_concurrent_djps) : nothing
        dynamic_feature === nothing || start(dynamic_feature)

        rt = Salsa.Runtime{SContext}(SContext(dynamic_feature, indirect_file_watch_callback))

        set_input_files!(rt, Set{URI}())
        set_input_active_project!(rt, nothing)
        set_input_env_ready!(rt, false)
        set_input_resolve_workspace_environments!(rt, resolve_workspace_environments)
        set_input_ready_project_environments!(rt, Set{WatchEnvironmentKey}())
        set_input_ready_test_environments!(rt, Dict{WatchTestEnvironmentKey,URI}())
        set_input_standalone_projects!(rt, Dict{CreateStandaloneProjectKey,URI}())

        new(rt, dynamic_feature)
    end
end

function _try_load_package_cache(store_path, name, uuid, version, git_tree_sha1)
    filename = replace(string(something(git_tree_sha1, version)), '+'=>'_')
    cache_path = joinpath(store_path, uppercase(string(name)[1:1]), string(name), string(uuid), string(filename, ".jstore"))

    if isfile(cache_path)
        # A stale/corrupt cache (e.g. an older serialization format left in the
        # scratch store) is a miss, not a fatal error — the environment reindexes.
        package_data = try
            open(cache_path) do io
                SymbolServer.CacheStore.read(io)
            end
        catch err
            err isa SymbolServer.CacheStore.CacheCorruptedError || rethrow()
            return nothing
        end

        pkg_path = Base.locate_package(Base.PkgId(uuid, string(name)))

        # TODO Reenable this
        # if pkg_path === nothing || !isfile(pkg_path)
        #     pkg_path = SymbolServer.get_pkg_path(Base.PkgId(uuid, pe_name), environment_path, ctx.dynamic_feature.depot_path)
        # end

        if pkg_path !== nothing
            SymbolServer.modify_dirs(package_data.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", joinpath(pkg_path, "src")))
        end

        return package_data
    end

    return nothing
end

"""
    _ensure_package_cache_loaded!(jw, name, uuid, version, git_tree_sha1) -> Bool

Populate the `input_package_metadata` input for one package from its on-disc
symbol cache, unless it is already populated. Returns `true` when the input
holds data after the call, `false` when no cache exists on disc.
"""
function _ensure_package_cache_loaded!(jw::JuliaWorkspace, name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing})
    df = jw.dynamic_feature
    key = PkgCacheKey((name, uuid, version, git_tree_sha1))
    key in df.loaded_pkg_metadata && return true

    package_data = _try_load_package_cache(df.store_path, name, uuid, version, git_tree_sha1)
    package_data === nothing && return false

    set_input_package_metadata!(jw.runtime, name, uuid, version, git_tree_sha1, package_data)
    push!(df.loaded_pkg_metadata, key)
    return true
end

function _load_package_caches_for_project!(jw, project_uri)
    project = derived_project(jw.runtime, project_uri)
    project === nothing && return

    for (_, v) in project.regular_packages
        _ensure_package_cache_loaded!(jw, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1)
        # Reading caches can take a while; keep other tasks responsive.
        yield()
    end

    for (_, v) in project.stdlib_packages
        v.version === nothing && continue
        _ensure_package_cache_loaded!(jw, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), nothing)
        yield()
    end
end

"""
    _load_missing_package_metadata!(jw::JuliaWorkspace)

Load the on-disc symbol caches for every package recorded in
`missing_pkg_metadata` into the Salsa runtime. Successfully loaded entries are
removed from the set; entries with no cache on disc yet stay for a later
retry. Reading dozens of caches (some tens of MB) takes seconds, and this runs
on the consumer task — typically a host's main dispatch loop — so it yields
between packages to keep other tasks responsive and reports per-package
progress on its own progress bar.
"""
function _load_missing_package_metadata!(jw::JuliaWorkspace)
    df = jw.dynamic_feature
    pending = collect(df.missing_pkg_metadata)
    n_meta = length(pending)
    n_meta == 0 && return

    for (idx, m) in enumerate(pending)
        if _ensure_package_cache_loaded!(jw, m.name, m.uuid, m.version, m.git_tree_sha1)
            delete!(df.missing_pkg_metadata, m)
        end

        # Cap below 100: the final report closes the progress bar.
        pct = min(floor(Int, 100 * idx / n_meta), 99)
        _report_progress(df, "package-caches", "Loading package caches ($idx/$n_meta)...", pct)

        yield()
    end

    _report_progress(df, "package-caches", "Package caches loaded", 100)

    return
end

function process_from_dynamic(jw::JuliaWorkspace)
    jw.dynamic_feature === nothing && return
    df = jw.dynamic_feature
    isready(df.out_channel) || return

    # Accumulate all drained results into local copies of the collection inputs
    # and write each input back at most once, so a burst of results causes a
    # single invalidation per collection rather than one per message.
    ready_envs = copy(input_ready_project_environments(jw.runtime))
    ready_test_envs = copy(input_ready_test_environments(jw.runtime))
    standalone_projects = copy(input_standalone_projects(jw.runtime))
    envs_dirty = false
    test_envs_dirty = false
    standalone_dirty = false
    any_env_ready = false

    while isready(df.out_channel)
        msg = take!(df.out_channel)

        if msg isa FailedResult
            @warn "DJP reported failure" msg.key
            # `failed_projects` was already populated in the reactor. A failure
            # is treated as a terminal state for readiness (best-effort, with
            # whatever symbol caches exist) so `is_ready` doesn't stay false
            # forever and per-project gating doesn't suppress diagnostics
            # indefinitely. A failed watched environment is recorded like a
            # successful one; failed test environments and standalone projects
            # have nothing to record — the artifacts their success paths
            # register (a test/standalone project URI) don't exist on failure —
            # so they only contribute to the global readiness flag.
            if msg.key isa WatchEnvironmentKey
                push!(ready_envs, msg.key)
                envs_dirty = true
            end
            any_env_ready = true

        elseif msg isa EnvironmentReadyResult
            @info "Processing new env"
            _load_missing_package_metadata!(jw)

            # Mark THIS specific project's environment as ready. Per-project
            # gating (in derived_file_env_ready) prevents env-dependent
            # diagnostics for other projects from being flushed prematurely
            # while their own DJPs are still pending.
            push!(ready_envs, WatchEnvironmentKey(msg.project_path, msg.content_hash))
            envs_dirty = true
            any_env_ready = true

        elseif msg isa TestEnvironmentReadyResult
            @info "Processing new test env" msg.project_uri msg.package msg.test_project_uri

            ready_test_envs[WatchTestEnvironmentKey(uri2filepath(msg.project_uri), msg.package, msg.content_hash)] = msg.test_project_uri
            test_envs_dirty = true

            # Preload package caches and mark the test project's own environment
            # ready, so the next get_diagnostics won't trigger another round.
            _load_package_caches_for_project!(jw, msg.test_project_uri)
            test_proj = derived_project(jw.runtime, msg.test_project_uri)
            test_proj_hash = test_proj === nothing ? UInt64(0) : test_proj.content_hash
            push!(ready_envs, WatchEnvironmentKey(uri2filepath(msg.test_project_uri), test_proj_hash))
            envs_dirty = true
            any_env_ready = true

        elseif msg isa StandaloneProjectReadyResult
            @info "Processing new standalone package project" msg.package_folder_uri msg.project_uri

            standalone_projects[CreateStandaloneProjectKey(uri2filepath(msg.package_folder_uri), msg.content_hash)] = msg.project_uri
            standalone_dirty = true

            _load_package_caches_for_project!(jw, msg.project_uri)
            standalone_proj = derived_project(jw.runtime, msg.project_uri)
            standalone_proj_hash = standalone_proj === nothing ? UInt64(0) : standalone_proj.content_hash
            push!(ready_envs, WatchEnvironmentKey(uri2filepath(msg.project_uri), standalone_proj_hash))
            envs_dirty = true
            any_env_ready = true
        else
            error("Unknown message: $msg")
        end
    end

    envs_dirty && set_input_ready_project_environments!(jw.runtime, ready_envs)
    test_envs_dirty && set_input_ready_test_environments!(jw.runtime, ready_test_envs)
    standalone_dirty && set_input_standalone_projects!(jw.runtime, standalone_projects)
    any_env_ready && set_input_env_ready!(jw.runtime, true)

    return
end
