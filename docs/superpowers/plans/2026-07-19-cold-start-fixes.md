# Cold Start Beyond the DJP Herd — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement item #3 of `docs/superpowers/2026-07-18-performance-future-work.md`: remove the five ranked cold-start costs that block the first interactive LS response (redundant package-cache deserialization, synchronous initial lint, per-progress-bar full republish, triple workspace walk, missing precompile workload).

**Architecture:** JuliaWorkspaces (JW) gains idempotent package-cache loading (a loaded-set + draining `missing_pkg_metadata`) and a single-walk, yielding `read_path_into_textdocuments` with a file-count cap. LanguageServer (LS) gains a coalesced, changed-files-only `:jw_indexing_complete` handler, an off-dispatch-loop initial diagnostics sweep, a single-walk folder loader, and a background-task-free `@compile_workload`.

**Tech Stack:** Julia; Salsa-based JW runtime; TestItemRunner `@testitem` tests in both packages; run all Julia code via the julia-mcp session (env `/home/pfitzseb/git/julia-vscode/scripts/environments/development`) — never spawn `julia` or `Pkg.test` directly.

## Global Constraints

- JW work happens on the current `sp/inventories` branch of the JuliaWorkspaces repo (run git inside `scripts/packages/JuliaWorkspaces` — it is a submodule).
- LS work happens in the LanguageServer repo (`scripts/packages/LanguageServer`), which sits on `main`: create branch `sp/cold-start` first, commit LS changes there.
- `@testitem` bodies need explicit `using JuliaWorkspaces: ...` / `using LanguageServer: ...` imports.
- Code comments: terse, never reference this plan or the perf doc.
- Commit messages for JW must not contain LS/consumer-specific context.
- Do not touch the real `~/.julia`; tests use `mktempdir()` stores only.

---

### Task 1: JW — dedup package symbol-cache loading (drain + skip)

`_load_missing_package_metadata!` re-reads the entire never-drained `missing_pkg_metadata` set once per `EnvironmentReadyResult` (up to 39×), and `_load_package_caches_for_project!` re-reads shared deps once per project. Fix: a `loaded_pkg_metadata` set makes every cache read happen at most once; successful loads drain `missing_pkg_metadata`.

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (~line 327: `DynamicFeature` struct + constructor)
- Modify: `src/types.jl:410-468` (`_load_package_caches_for_project!`, `_load_missing_package_metadata!`, new `_ensure_package_cache_loaded!`)
- Modify: `src/inputs.jl:68-104` (lazy `input_package_metadata` default records loads)
- Test: `test/test_package_cache_loading.jl` (new)

**Interfaces:**
- Produces: `_ensure_package_cache_loaded!(jw::JuliaWorkspace, name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing})::Bool` — true iff the metadata input is populated after the call; `const PkgCacheKey = @NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}`; new `DynamicFeature.loaded_pkg_metadata::Set{PkgCacheKey}` field.

- [x] **Step 1: Write the failing tests**

Create `test/test_package_cache_loading.jl`. Helper note: cache path layout is `<store>/<first letter uppercased>/<name>/<uuid>/<tree-sha-or-version>.jstore` (see `_try_load_package_cache`).

```julia
@testitem "Package cache loading: loads once, skips disc thereafter" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _ensure_package_cache_loaded!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    name = :TestCachePkg
    uuid = Base.UUID("11111111-2222-3333-4444-555555555555")
    version = v"1.2.3"
    tree = "abcdef0123456789abcd"

    cache_dir = joinpath(store, "T", string(name), string(uuid))
    mkpath(cache_dir)
    pkg = Package(string(name),
        ModuleStore(VarRef(nothing, name), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        uuid, nothing)
    cache_file = joinpath(cache_dir, string(tree, ".jstore"))
    open(io -> CacheStore.write(io, pkg), cache_file, "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)

    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)
    @test input_package_metadata(jw.runtime, name, uuid, version, tree) !== nothing

    # Once loaded, the helper must not touch the disc again: with the cache
    # file gone, a re-read would fail, so returning true proves the skip.
    rm(cache_file)
    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)

    # A package with no cache on disc reports false.
    @test !_ensure_package_cache_loaded!(jw, :NoCachePkg,
        Base.UUID("99999999-2222-3333-4444-555555555555"), v"1.0.0", nothing)
end

@testitem "Package cache loading: lazy input loads are recorded" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _ensure_package_cache_loaded!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    name = :LazyCachePkg
    uuid = Base.UUID("22222222-2222-3333-4444-555555555555")
    version = v"0.1.0"
    tree = "0123456789abcdef0123"

    cache_dir = joinpath(store, "L", string(name), string(uuid))
    mkpath(cache_dir)
    pkg = Package(string(name),
        ModuleStore(VarRef(nothing, name), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        uuid, nothing)
    cache_file = joinpath(cache_dir, string(tree, ".jstore"))
    open(io -> CacheStore.write(io, pkg), cache_file, "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)

    # Probing the input triggers the lazy default, which reads the cache.
    @test input_package_metadata(jw.runtime, name, uuid, version, tree) !== nothing

    # That lazy load must be recorded: with the file gone the helper can only
    # return true if it skips the disc read.
    rm(cache_file)
    @test _ensure_package_cache_loaded!(jw, name, uuid, version, tree)
end

@testitem "Package cache loading: missing set drains on success, keeps unavailable" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, DynamicIndexingOnly,
        _load_missing_package_metadata!, input_package_metadata
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore

    store = mktempdir()
    cached_uuid = Base.UUID("33333333-2222-3333-4444-555555555555")
    uncached_uuid = Base.UUID("44444444-2222-3333-4444-555555555555")
    tree = "fedcba9876543210fedc"

    cache_dir = joinpath(store, "C", "CachedPkg", string(cached_uuid))
    mkpath(cache_dir)
    pkg = Package("CachedPkg",
        ModuleStore(VarRef(nothing, :CachedPkg), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]),
        cached_uuid, nothing)
    open(io -> CacheStore.write(io, pkg), joinpath(cache_dir, string(tree, ".jstore")), "w")

    jw = JuliaWorkspace(dynamic=DynamicIndexingOnly, store_path=store)
    df = jw.dynamic_feature

    cached_key = (name=:CachedPkg, uuid=cached_uuid, version=v"1.0.0", git_tree_sha1=tree)
    uncached_key = (name=:UncachedPkg, uuid=uncached_uuid, version=v"1.0.0", git_tree_sha1=nothing)
    push!(df.missing_pkg_metadata, cached_key)
    push!(df.missing_pkg_metadata, uncached_key)

    _load_missing_package_metadata!(jw)

    # The loadable entry is drained; the unavailable one stays for retry.
    @test collect(df.missing_pkg_metadata) == [uncached_key]
    @test input_package_metadata(jw.runtime, :CachedPkg, cached_uuid, v"1.0.0", tree) !== nothing
end
```

- [x] **Step 2: Run the tests to verify they fail**

Via julia-mcp (dev env session), e.g.:
```julia
using TestItemRunner
TestItemRunner.run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter=ti->occursin("Package cache loading", ti.name))
```
(or the session's established `@run_package_tests` flow). Expected: all three testitems FAIL with `UndefVarError: _ensure_package_cache_loaded!` (the drain test errors because `_load_missing_package_metadata!` leaves both keys / the existing signature works but the drain assertion fails).

- [x] **Step 3: Implement**

In `src/dynamic_feature/dynamic_feature.jl`, above `struct DynamicFeature`:

```julia
# Identity of one package's symbol cache on disc.
const PkgCacheKey = @NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}
```

Replace the `missing_pkg_metadata` field type with `Set{PkgCacheKey}` and add directly below it:

```julia
    # Package caches whose metadata input is already populated; guards against
    # re-reading (and re-`set_input`ing) multi-MB cache files.
    loaded_pkg_metadata::Set{PkgCacheKey}
```

In the constructor's `new(...)` replace `Set{@NamedTuple{...}}()` with `Set{PkgCacheKey}(), Set{PkgCacheKey}(),` (keeping positional order in sync with the struct).

In `src/types.jl` add above `_load_package_caches_for_project!`:

```julia
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
```

Rewrite the two loaders to use it (drain semantics in the second):

```julia
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
```

```julia
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
```

Update its docstring to mention that successfully loaded entries are removed from `missing_pkg_metadata` while unavailable ones stay for retry.

In `src/inputs.jl`, in the lazy default's success branch (before `return package_data`) add:

```julia
            push!(ctx.dynamic_feature.loaded_pkg_metadata, PkgCacheKey((name, uuid, version, git_tree_sha1)))
```

and change the existing `push!` in the miss branch to use `PkgCacheKey((name, uuid, version, git_tree_sha1))`.

- [x] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 3/3 PASS.

- [x] **Step 5: Run the full JW suite; commit**

Full suite via julia-mcp. Expected: green (pre-existing Runic dev-env error is known-benign). Then, inside the JW directory:

```bash
git add src/dynamic_feature/dynamic_feature.jl src/types.jl src/inputs.jl test/test_package_cache_loading.jl
git commit -m "perf: load each package symbol cache at most once"
```

---

### Task 2: LS — coalesce indexing-complete refreshes, publish only changed files

Every finished progress bar enqueues `:jw_indexing_complete` (~80+ events per cold start); for non-refresh-support clients each event re-publishes diagnostics for all files. Coalesce the events and diff against the last published state.

**Files:**
- Create branch first: `git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer switch -c sp/cold-start`
- Modify: `src/languageserverinstance.jl` (struct fields ~line 78, constructor ~line 110, run-loop `:jw_indexing_complete` branch at 400-408, new functions above `run`)
- Modify: `src/progress.jl:58` (enqueue via the coalescing helper)
- Test: `test/test_indexing_complete.jl` (new)

**Interfaces:**
- Produces: `request_indexing_refresh(server::LanguageServerInstance)` (enqueues at most one pending `:jw_indexing_complete`), `handle_indexing_complete!(server::LanguageServerInstance)` (the queue-message handler), fields `_indexing_complete_queued::Threads.Atomic{Bool}`, `_indexing_publish_marks::Union{Nothing,@NamedTuple{testitems::Dict{URI,UInt},diagnostics::Dict{URI,UInt}}}`.
- Consumes: `mark_current_diagnostics_testitems`, `get_files_with_updated_diagnostics_testitems`, `publish_diagnostics`, `publish_tests` (all existing, `src/testitem_diagnostic_marking.jl`).

- [x] **Step 1: Write the failing tests**

Create `test/test_indexing_complete.jl`:

```julia
@testitem "indexing-complete: repeated requests coalesce to one queued message" begin
    import Pkg
    using LanguageServer: LanguageServerInstance, request_indexing_refresh

    server = LanguageServerInstance(IOBuffer(), IOBuffer(), dirname(Pkg.Types.Context().env.project_file))

    request_indexing_refresh(server)
    request_indexing_refresh(server)
    request_indexing_refresh(server)

    n = 0
    while isready(server.combined_msg_queue)
        take!(server.combined_msg_queue)
        n += 1
    end
    @test n == 1

    # Once handled (flag reset), a new request queues again.
    server._indexing_complete_queued[] = false
    request_indexing_refresh(server)
    @test isready(server.combined_msg_queue)
end

@testitem "indexing-complete: second refresh with unchanged state publishes nothing" setup=[TestSetup] begin
    import Pkg, JSONRPC
    using LanguageServer
    using LanguageServer: LanguageServerInstance, handle_indexing_complete!
    using LanguageServer.URIs2

    sent = []
    JSONRPC.send(::Nothing, typ, params) = push!(sent, (typ, params))

    server = LanguageServerInstance(IOBuffer(), IOBuffer(), dirname(Pkg.Types.Context().env.project_file))
    server.jr_endpoint = nothing
    server.enable_dynamic_indexing = false
    LanguageServer.initialize_request(TestSetup.init_request, server, nothing)
    LanguageServer.initialized_notification(LanguageServer.InitializedParams(), server, nothing)

    LanguageServer.textDocument_didOpen_notification(
        LanguageServer.DidOpenTextDocumentParams(
            LanguageServer.TextDocumentItem(uri"untitled:testdoc", "julia", 0, "f(x) = x\n")),
        server, nothing)

    # First refresh: no baseline yet, publishes the full state.
    empty!(sent)
    handle_indexing_complete!(server)
    first_count = length(sent)
    @test first_count >= 1
    @test server._indexing_publish_marks !== nothing

    # Nothing changed since: a second refresh publishes nothing.
    empty!(sent)
    handle_indexing_complete!(server)
    @test isempty(sent)
end
```

- [x] **Step 2: Run tests to verify they fail**

Run the LS testitems via julia-mcp (activate/point TestItemRunner at the LanguageServer package, filter on "indexing-complete"). Expected: FAIL with `UndefVarError: request_indexing_refresh` / `handle_indexing_complete!`.

- [x] **Step 3: Implement**

In `src/languageserverinstance.jl`, after the `_watched_indirect_files` field add:

```julia
    # True while a `:jw_indexing_complete` message is queued and unprocessed;
    # bursts of finishing progress bars collapse into one refresh.
    _indexing_complete_queued::Threads.Atomic{Bool}
    # Diagnostics/testitems state as of the last indexing-complete publish
    # (`nothing` before the first one); later refreshes publish only files
    # that changed since.
    _indexing_publish_marks::Union{Nothing,@NamedTuple{testitems::Dict{URI,UInt},diagnostics::Dict{URI,UInt}}}
```

In the constructor's `new(...)`, add `Threads.Atomic{Bool}(false), nothing,` in the matching position (before the `trace_value` argument).

Above `function Base.run(server::LanguageServerInstance; ...)` (or near the other helpers at top level) add:

```julia
function request_indexing_refresh(server::LanguageServerInstance)
    if !Threads.atomic_xchg!(server._indexing_complete_queued, true)
        put!(server.combined_msg_queue, (type=:jw_indexing_complete,))
    end
    return
end

function handle_indexing_complete!(server::LanguageServerInstance)
    server._indexing_complete_queued[] = false

    if server.clientcapability_workspace_diagnostic_refreshsupport
        JSONRPC.send(server.jr_endpoint, workspace_diagnosticRefresh_request_type, nothing)
        return
    end

    if server._indexing_publish_marks === nothing
        # No baseline yet: publish the full current state once.
        all_diag_uris = URI[uri for (uri, _) in JuliaWorkspaces.get_diagnostics(server.workspace)]
        all_open_uris = URI[uri for uri in keys(server._open_file_versions)]
        all_uris = unique(vcat(all_diag_uris, all_open_uris))
        publish_diagnostics(server, all_uris, URI[], all_uris)
    else
        updated = get_files_with_updated_diagnostics_testitems(server.workspace, server._indexing_publish_marks)
        publish_diagnostics(server, collect(updated.updated_files_diag), collect(updated.deleted_files_diag), URI[])
        publish_tests(server, updated.updated_files_ti, updated.deleted_files_ti)
    end

    server._indexing_publish_marks = mark_current_diagnostics_testitems(server.workspace)
    return
end
```

Replace the run-loop branch body (`languageserverinstance.jl:400-408`) with:

```julia
            elseif message.type == :jw_indexing_complete
                handle_indexing_complete!(server)
```

In `src/progress.jl:58` replace `put!(server.combined_msg_queue, (type=:jw_indexing_complete,))` with `request_indexing_refresh(server)`.

- [x] **Step 4: Run tests to verify they pass**

Same as Step 2. Expected: 2/2 PASS.

- [x] **Step 5: Run the LS suite; commit**

Full LS testitem suite via julia-mcp. Then:

```bash
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer add src/languageserverinstance.jl src/progress.jl test/test_indexing_complete.jl
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer commit -m "perf: coalesce indexing-complete refreshes and publish only changed files"
```

---

### Task 3: LS — initial workspace sweep off the dispatch loop

`initialized_notification` currently ends with a synchronous `publish_diagnostics_testitems` — a cold full-workspace lint (~5 s on the repro workspace) inside one `dispatch_msg`, blocking every queued client message. Move the sweep+publish onto a worker task; the per-file `yield()`s inside the sweep keep it cooperative, and JSONRPC sends are task-safe.

**Files:**
- Modify: `src/languageserverinstance.jl` (one new field + constructor arg)
- Modify: `src/requests/init.jl:322` (async publish)
- Test: `test/test_initialized_publish.jl` (new)

**Interfaces:**
- Produces: field `_initial_publish_task::Union{Nothing,Task}` (tests and later tasks may `wait` on it).
- Consumes: `_indexing_publish_marks` from Task 2 (the initial sweep records the baseline so the first indexing-complete refresh doesn't publish-all).

- [x] **Step 1: Write the failing test**

Create `test/test_initialized_publish.jl`:

```julia
@testitem "initialized: initial sweep runs on a worker task and records the publish baseline" setup=[TestSetup] begin
    import Pkg, JSONRPC
    using LanguageServer
    using LanguageServer: LanguageServerInstance
    using LanguageServer.URIs2
    import JuliaWorkspaces

    sent = []
    JSONRPC.send(::Nothing, typ, params) = push!(sent, (typ, params))

    dir = mktempdir()
    file = joinpath(dir, "src.jl")
    write(file, "function f(x)\n    return x\nend\n")

    server = LanguageServerInstance(IOBuffer(), IOBuffer(), dirname(Pkg.Types.Context().env.project_file))
    server.jr_endpoint = nothing
    server.enable_dynamic_indexing = false
    push!(server.workspaceFolders, dir)
    LanguageServer.initialize_request(TestSetup.init_request, server, nothing)
    LanguageServer.initialized_notification(LanguageServer.InitializedParams(), server, nothing)

    # The notification returns with the sweep still owned by a worker task.
    @test server._initial_publish_task isa Task
    wait(server._initial_publish_task)

    # The worker published the workspace file and recorded the baseline.
    @test server._indexing_publish_marks !== nothing
    file_uri = filepath2uri(file)
    @test any(sent) do (typ, params)
        params isa LanguageServer.PublishDiagnosticsParams && params.uri == file_uri
    end
    @test JuliaWorkspaces.has_file(server.workspace, file_uri)
end
```

- [x] **Step 2: Run test to verify it fails**

Expected: FAIL — `LanguageServerInstance` has no field `_initial_publish_task`.

- [x] **Step 3: Implement**

Add to the struct (below the Task-2 fields):

```julia
    # Worker task computing the initial full-workspace sweep + publish, so
    # `initialized` returns before the cold lint instead of blocking the
    # dispatch loop.
    _initial_publish_task::Union{Nothing,Task}
```

Constructor: add `nothing,` in the matching position.

In `src/requests/init.jl` replace line 322 (`TraceLogging.@trace publish_diagnostics_testitems(server, marked_versions, added_uris)`) with:

```julia
    # The cold sweep takes seconds; per-file yields inside it keep this task
    # cooperative and JSONRPC sends are queue-based, so publishing from a
    # worker is safe. Recording the marks afterwards gives indexing-complete
    # refreshes their baseline without another publish-all.
    server._initial_publish_task = @async try
        publish_diagnostics_testitems(server, marked_versions, added_uris)
        server._indexing_publish_marks = mark_current_diagnostics_testitems(server.workspace)
    catch err
        @error "Initial diagnostics publish failed" exception = (err, catch_backtrace())
    end
```

- [x] **Step 4: Run test to verify it passes**

Expected: PASS. Also re-run `test_indexing_complete.jl` (unchanged behavior: its server has no workspace folders, so the async task is a near-no-op — but it may now set `_indexing_publish_marks`; if the "no baseline yet" branch of that test becomes flaky because the init task already recorded marks, make the test deterministic by adding `wait(server._initial_publish_task)` right after `initialized_notification` and asserting from the post-baseline state instead: first `handle_indexing_complete!` after the didOpen publishes ≥ 1 message for the changed doc, second publishes nothing).

- [x] **Step 5: Run the LS suite; commit**

```bash
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer add src/languageserverinstance.jl src/requests/init.jl test/test_initialized_publish.jl test/test_indexing_complete.jl
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer commit -m "perf: run the initial workspace sweep off the dispatch loop"
```

> **Deviation (committed `09057fe`):** implemented as a fire-and-forget `@async` in `initialized_notification` — no `_initial_publish_task` field was added. The test polls with `timedwait` instead of `wait(server._initial_publish_task)`. Task 4's Step-5 test must use the same `timedwait` pattern, not `wait(...)`.

---

### Task 4: single workspace walk at init (JW `file_limit` + LS one-walk loader)

Init currently walks each folder tree 3× (`read_path_into_textdocuments`, `has_too_many_files`, `load_folder`), and the content-read walk never yields. Give JW's reader a julia-file cap (subsuming `has_too_many_files`) and yields; make LS consume one walk for everything.

**Files:**
- Modify (JW): `src/fileio.jl:109-142` (`read_path_into_textdocuments`)
- Test (JW): `test/test_fileio.jl` (append testitem)
- Modify (LS): `src/requests/init.jl` (delete `has_too_many_files`, adjust `load_rootpath`, replace `load_folder` with `collect_folder_files!`, rewrite the init load block)
- Modify (LS): `src/requests/workspace.jl:135-146` (didChangeWorkspaceFolders added-branch uses the new helper)
- Test (LS): `test/test_initialized_publish.jl` (append testitem)

**Interfaces:**
- Produces (JW): `read_path_into_textdocuments(uri; ignore_io_errors=false, file_limit::Union{Nothing,Int}=nothing)` — returns `nothing` when the tree contains more than `file_limit` Julia files (only when a limit is given; existing callers unaffected).
- Produces (LS): `collect_folder_files!(server, path::String, added_uris::Vector{URI})::Vector{JuliaWorkspaces.TextFile}` — single-walk read that updates `server._files_from_disc` and `server._workspace_files`, appends newly-visible julia URIs to `added_uris`, and returns the files the caller must `add_files!`; `const MAX_WORKSPACE_JULIA_FILES = 5000`.
- Consumes: Task 3's init structure (the publish stays async, after the load block).

- [x] **Step 1 (JW): Write the failing test**

Append to `test/test_fileio.jl`:

```julia
@testitem "read_path_into_textdocuments honors file_limit" begin
    using JuliaWorkspaces: read_path_into_textdocuments
    using JuliaWorkspaces.URIs2: filepath2uri

    dir = mktempdir()
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
```

- [x] **Step 2 (JW): Run test to verify it fails**

Expected: FAIL — `MethodError` / unsupported keyword `file_limit`.

- [x] **Step 3 (JW): Implement**

Rewrite `read_path_into_textdocuments` as one `walkdir` pass that collects candidate paths (counting Julia files with early abort) and then reads contents, yielding as it goes:

```julia
function read_path_into_textdocuments(uri::URI; ignore_io_errors=false, file_limit::Union{Nothing,Int}=nothing)
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
    candidate_paths = String[]
    julia_file_count = 0
    for (root, _, files) in walkdir(path, onerror=x -> x)
        yield()
        for file in files
            filepath = joinpath(root, file)
            if is_path_julia_file(filepath)
                julia_file_count += 1
                if file_limit !== nothing && julia_file_count > file_limit
                    return nothing
                end
                push!(candidate_paths, filepath)
            elseif is_path_project_file(filepath) ||
                        is_path_manifest_file(filepath) ||
                        is_path_lintconfig_file(filepath) ||
                        is_path_formatconfig_file(filepath) ||
                        is_path_markdown_file(filepath) ||
                        is_path_juliamarkdown_file(filepath)
                push!(candidate_paths, filepath)
            end
        end
    end

    for filepath in candidate_paths
        text_file = read_text_file_from_uri(filepath2uri(filepath), return_nothing_on_io_error=ignore_io_errors)
        text_file === nothing && continue
        push!(result, text_file)
        yield()
    end

    return result
end
```

- [x] **Step 4 (JW): Run test to verify it passes; run JW suite; commit**

```bash
git add src/fileio.jl test/test_fileio.jl
git commit -m "perf: single-pass folder read with optional file cap and yields"
```

- [x] **Step 5 (LS): Write the failing test**

Append to `test/test_initialized_publish.jl`:

```julia
@testitem "initialized: one walk feeds workspace files, disc cache, and JW" setup=[TestSetup] begin
    import Pkg, JSONRPC
    using LanguageServer
    using LanguageServer: LanguageServerInstance
    using LanguageServer.URIs2
    import JuliaWorkspaces

    JSONRPC.send(::Nothing, typ, params) = nothing

    dir = mktempdir()
    file = joinpath(dir, "code.jl")
    write(file, "g() = 1\n")
    write(joinpath(dir, "notes.md"), "# notes\n")

    server = LanguageServerInstance(IOBuffer(), IOBuffer(), dirname(Pkg.Types.Context().env.project_file))
    server.jr_endpoint = nothing
    server.enable_dynamic_indexing = false
    push!(server.workspaceFolders, dir)
    LanguageServer.initialize_request(TestSetup.init_request, server, nothing)
    LanguageServer.initialized_notification(LanguageServer.InitializedParams(), server, nothing)
    wait(server._initial_publish_task)

    file_uri = filepath2uri(file)
    md_uri = filepath2uri(joinpath(dir, "notes.md"))

    # julia files land in the workspace-file set; everything read lands in
    # the disc cache and the JW workspace.
    @test file_uri in server._workspace_files
    @test !(md_uri in server._workspace_files)
    @test haskey(server._files_from_disc, file_uri)
    @test haskey(server._files_from_disc, md_uri)
    @test JuliaWorkspaces.has_file(server.workspace, file_uri)

    # The former guard helpers are gone: one walk serves all consumers.
    @test !isdefined(LanguageServer, :has_too_many_files)
    @test !isdefined(LanguageServer, :load_folder)
end
```

- [x] **Step 6 (LS): Run test to verify it fails**

Expected: FAIL on `!isdefined(LanguageServer, :has_too_many_files)` (helpers still defined).

- [x] **Step 7 (LS): Implement**

In `src/requests/init.jl`:

1. Delete `has_too_many_files` (lines 62-83) and both `load_folder` methods (lines 99-127). Add:

```julia
const MAX_WORKSPACE_JULIA_FILES = 5000

# One walk per folder: reads all workspace files, tracks julia files in
# `server._workspace_files`, appends newly-visible julia URIs to `added_uris`,
# and returns the new files for the caller to `add_files!` in one batch.
function collect_folder_files!(server, path::String, added_uris::Vector{URI})
    files_to_add = JuliaWorkspaces.TextFile[]
    load_rootpath(path) || return files_to_add

    files = JuliaWorkspaces.read_path_into_textdocuments(filepath2uri(path); ignore_io_errors=true, file_limit=MAX_WORKSPACE_JULIA_FILES)
    if files === nothing
        @info "Your workspace folder has > $MAX_WORKSPACE_JULIA_FILES Julia files, server will not try to load them."
        return files_to_add
    end

    for tf in files
        will_add = false
        # A subfolder of an already-watched folder yields duplicates; first
        # read wins.
        if !haskey(server._files_from_disc, tf.uri)
            server._files_from_disc[tf.uri] = tf
            if !haskey(server._open_file_versions, tf.uri)
                push!(files_to_add, tf)
                will_add = true
            end
        end

        filepath = uri2filepath(tf.uri)
        if filepath !== nothing && isvalidjlfile(filepath)
            already_tracked = tf.uri in server._workspace_files
            push!(server._workspace_files, tf.uri)
            if !already_tracked && (will_add || JuliaWorkspaces.has_file(server.workspace, tf.uri))
                push!(added_uris, tf.uri)
            end
        end
    end

    return files_to_add
end
```

2. In `load_rootpath`, drop the `!has_too_many_files(path)` conjunct (keep the rest).

3. Replace the whole `TraceLogging.@trace "initial_workspace_load" begin ... end` block in `initialized_notification` with:

```julia
    TraceLogging.@trace "initial_workspace_load" begin
        if server.workspaceFolders !== nothing
            files_to_add = JuliaWorkspaces.TextFile[]
            TraceLogging.@trace "workspace folder walk" for folder in server.workspaceFolders
                append!(files_to_add, collect_folder_files!(server, folder, added_uris))
            end

            # Add the whole batch at once: this reconciles the required dynamic
            # processes a single time instead of once per file, so downloading/
            # indexing can start right after this call rather than after the
            # whole initial load.
            TraceLogging.@trace JuliaWorkspaces.add_files!(server.workspace, files_to_add)

            TraceLogging.@trace JuliaWorkspaces.set_active_project!(server.workspace, isempty(server.env_path) ? nothing : filepath2uri(server.env_path))
        end
    end
```

4. In `src/requests/workspace.jl`, rewrite the `params.event.added` loop of `workspace_didChangeWorkspaceFolders_notification` to:

```julia
    for wksp in params.event.added
        path = uri2filepath(wksp.uri)
        push!(server.workspaceFolders, path)
        files_to_add = collect_folder_files!(server, path, added_uris)
        JuliaWorkspaces.add_files!(server.workspace, files_to_add)
    end
```

5. `grep -rn "load_folder\|has_too_many_files" src/` must come back empty; fix any remaining call sites the same way.

- [x] **Step 8 (LS): Run tests to verify they pass; run the LS suite; commit**

```bash
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer add src/requests/init.jl src/requests/workspace.jl test/test_initialized_publish.jl
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer commit -m "perf: walk each workspace folder once at init"
```

Note: LS's Project.toml `[compat]` may need a JuliaWorkspaces bump if `file_limit` rides a JW version bump — record in the final task, don't release here.

---

### Task 5: LS — precompile workload without background tasks

`precompile.jl`'s `@compile_workload` is commented out because `runserver` starts non-terminating tasks. Replace it with a workload that drives the hot request paths against a `DynamicOff` in-memory workspace: no child processes, no reactor, no progress worker, no editor-pid monitor.

**Files:**
- Modify: `src/languageserverinstance.jl` (widen `jr_endpoint` field to `Any`; add `NullEndpoint`)
- Modify: `src/precompile.jl` (the workload)
- Test: verification is `Base.compilecache` (a `@testitem` cannot observe precompile) + suite stays green

**Interfaces:**
- Produces: `struct NullEndpoint end` with `JSONRPC.send(::NullEndpoint, ::Any, ::Any) = nothing`; `jr_endpoint::Any`.

- [x] **Step 1: Establish the failing baseline**

Via julia-mcp: `success(Base.compilecache(Base.identify_package("LanguageServer")))` — confirm current state compiles (baseline), then apply Step 2 and re-run to confirm the workload actually executes (a deliberate `error("boom")` temporarily placed in the workload must fail compilecache — this is the RED check that the workload runs at precompile time; remove it once observed).

- [x] **Step 2: Implement**

In `src/languageserverinstance.jl`: change the field `jr_endpoint::Union{JSONRPC.JSONRPCEndpoint,Nothing}` to `jr_endpoint::Any` and add above the struct:

```julia
# Endpoint that swallows all messages; used where no client is connected
# (precompile workload, tests).
struct NullEndpoint end
JSONRPC.send(::NullEndpoint, @nospecialize(_), @nospecialize(_)) = nothing
```

Replace `src/precompile.jl` with:

```julia
@setup_workload begin
    workload_text = """
    module PrecompileWorkload

    const GREETING = "hello"

    struct Point
        x::Float64
        y::Float64
    end

    function distance(a::Point, b::Point)
        dx = a.x - b.x
        dy = a.y - b.y
        return sqrt(dx^2 + dy^2)
    end

    end
    """

    @compile_workload begin
        # Drive the hot request paths against an in-memory DynamicOff
        # workspace: no child processes and no background tasks (which are
        # not allowed during precompile).
        mktempdir() do store_path
            server = LanguageServerInstance(IOBuffer(), IOBuffer(), "")
            server.jr_endpoint = NullEndpoint()
            server.status = :running
            server.workspace = JuliaWorkspaces.JuliaWorkspace(
                dynamic=JuliaWorkspaces.DynamicOff, store_path=store_path)

            uri = URIs2.URI("untitled:precompile_workload.jl")
            textDocument_didOpen_notification(
                DidOpenTextDocumentParams(TextDocumentItem(uri, "julia", 0, workload_text)),
                server, nothing)

            textDocument_didChange_notification(
                DidChangeTextDocumentParams(
                    VersionedTextDocumentIdentifier(uri, 1),
                    [TextDocumentContentChangeEvent(missing, missing, workload_text)]),
                server, nothing)

            doc_id = TextDocumentIdentifier(uri)
            textDocument_completion_request(CompletionParams(doc_id, Position(11, 20), missing), server, nothing)
            textDocument_hover_request(TextDocumentPositionParams(doc_id, Position(11, 24)), server, nothing)
            textDocument_definition_request(TextDocumentPositionParams(doc_id, Position(11, 24)), server, nothing)
            textDocument_documentSymbol_request(DocumentSymbolParams(doc_id), server, nothing)

            JuliaWorkspaces.get_diagnostics(server.workspace)
            JuliaWorkspaces.get_test_items(server.workspace)

            textDocument_didClose_notification(
                DidCloseTextDocumentParams(doc_id), server, nothing)
        end
    end
end
precompile(runserver, ())
```

Exact request-constructor signatures and Position coordinates must be checked against the handlers/tests at implementation time (`test_shared_server.jl` shows working invocations); adjust while keeping the covered surface (didOpen/didChange/completion/hover/definition/documentSymbol/didClose + the two JW sweeps).

- [x] **Step 3: Verify**

- `Base.compilecache(Base.identify_package("LanguageServer"))` via julia-mcp succeeds, with the workload confirmed to execute (Step 1's RED check) and no hang (bound the wait; a hang means a background task leaked — find and remove the offender, e.g. anything calling `@async` on the driven paths).
- Full LS suite green (the `jr_endpoint::Any` widening is used by tests already setting it to `nothing`).

- [x] **Step 4: Commit**

```bash
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer add src/languageserverinstance.jl src/precompile.jl
git -C /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer commit -m "perf: precompile the hot request paths via a DynamicOff workload"
```

---

### Task 6: Final verification and docs

- [x] **Step 1: Run both full suites via julia-mcp** (JW `@run_package_tests`, LS testitems). Expected: green apart from the known-benign Runic dev-env error (JW).

- [x] **Step 2: Update the perf doc**

In `docs/superpowers/2026-07-18-performance-future-work.md`, retitle item #3's heading with *(IMPLEMENTED — see plan 2026-07-19-cold-start-fixes)* and add a short "Implemented" note per bullet (what changed, where), moving genuinely-still-open residuals (e.g. cache reads still happen on the consumer task, only now at most once each; pull-diagnostics preference) into a follow-ups line. Model the wording on item #2's block.

- [x] **Step 3: Commit (JW repo)**

```bash
git add docs/superpowers/2026-07-18-performance-future-work.md docs/superpowers/plans/2026-07-19-cold-start-fixes.md
git commit -m "docs: record cold-start fixes (item #3) outcome"
```
