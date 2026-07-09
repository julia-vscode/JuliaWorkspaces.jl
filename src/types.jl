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
@auto_hash_equals struct TestItemDetail
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
@auto_hash_equals struct TestSetupDetail
    uri::URI
    name::Symbol
    kind::Symbol
    code::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end

"""
    struct TestErrorDetail

Details of a test error.

- uri::URI
- id::String
- name::Union{Nothing,String}
- message::String
- range::UnitRange{Int}
"""
@auto_hash_equals struct TestErrorDetail
    uri::URI
    id::String
    name::Union{Nothing,String}
    message::String
    range::UnitRange{Int}
end

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
@auto_hash_equals struct Diagnostic
    range::UnitRange{Int64}
    severity::Symbol
    message::String
    uri::Union{Nothing,URI}
    tags::Vector{Symbol}
    source::String
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
"""
struct JuliaWorkspace
    runtime::Salsa.Runtime{SContext,Salsa.DefaultStorage}
    dynamic_feature::Union{Nothing,DynamicFeature}

    function JuliaWorkspace(;dynamic::DynamicMode=DynamicOff, store_path::Union{Nothing,String}=nothing, symbolcache_download::Bool=false, symbolcache_upstream::String=DEFAULT_SYMBOLCACHE_UPSTREAM, indirect_file_watch_callback::Union{Nothing,Function}=nothing, progress_callback::Union{Nothing,Function}=nothing)
        if store_path === nothing
            store_path = Scratch.@get_scratch!("store_path_v1")
        end
        need_dynamic_feature = dynamic != DynamicOff || symbolcache_download
        dynamic_feature = need_dynamic_feature ? DynamicFeature(dynamic, store_path; download_enabled=symbolcache_download, upstream_url=symbolcache_upstream, progress_callback=progress_callback) : nothing
        dynamic_feature === nothing || start(dynamic_feature)

        rt = Salsa.Runtime{SContext}(SContext(dynamic_feature, indirect_file_watch_callback))

        set_input_files!(rt, Set{URI}())
        set_input_active_project!(rt, nothing)
        set_input_env_ready!(rt, false)
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
        package_data = open(cache_path) do io
            SymbolServer.CacheStore.read(io)
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

function _load_package_caches_for_project!(jw, project_uri)
    project = derived_project(jw.runtime, project_uri)
    project === nothing && return

    store_path = jw.dynamic_feature.store_path

    for (_, v) in project.regular_packages
        package_data = _try_load_package_cache(store_path, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1)
        if package_data !== nothing
            # @info "Now package data is ready" v.name v.uuid v.version v.git_tree_sha1
            set_input_package_metadata!(jw.runtime, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1, package_data)
        end
        # Reading caches can take a while; keep other tasks responsive.
        yield()
    end

    for (_, v) in project.stdlib_packages
        v.version === nothing && continue
        ver = parse(VersionNumber, v.version)
        package_data = _try_load_package_cache(store_path, Symbol(v.name), v.uuid, ver, nothing)
        if package_data !== nothing
            # @info "Now package data is ready (stdlib)" v.name v.uuid v.version
            set_input_package_metadata!(jw.runtime, Symbol(v.name), v.uuid, ver, nothing, package_data)
        end
        yield()
    end
end

"""
    _load_missing_package_metadata!(jw::JuliaWorkspace)

Load the on-disc symbol caches for every package recorded in
`missing_pkg_metadata` into the Salsa runtime. Reading dozens of caches (some
tens of MB) takes seconds, and this runs on the consumer task — typically a
host's main dispatch loop — so it yields between packages to keep other tasks
responsive and reports per-package progress on its own progress bar.
"""
function _load_missing_package_metadata!(jw::JuliaWorkspace)
    df = jw.dynamic_feature
    n_meta = length(df.missing_pkg_metadata)
    n_meta == 0 && return

    for (idx, m) in enumerate(df.missing_pkg_metadata)
        package_data = _try_load_package_cache(df.store_path, m.name, m.uuid, m.version, m.git_tree_sha1)
        if package_data !== nothing
            set_input_package_metadata!(jw.runtime, m.name, m.uuid, m.version, m.git_tree_sha1, package_data)
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
