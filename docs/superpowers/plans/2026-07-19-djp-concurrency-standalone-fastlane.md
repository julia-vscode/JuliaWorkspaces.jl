# DJP Concurrency Cap + Standalone Fast Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound concurrent dynamic-indexing child processes behind a setting (priority-ordered launches), and make standalone-project environments restart-free via persistent dirs with serve-stale + background refresh.

**Architecture:** All orchestration lives in the `DynamicFeature` reactor (`src/dynamic_feature/dynamic_feature.jl`); launches go through a capped, priority-ordered queue with an injectable `launcher` seam for tests. Standalone projects move from child tempdirs to parent-chosen persistent dirs keyed by content hash, enabling a WatchEnvironment-style prep fast lane; a strictly-lower-priority refresh queue re-resolves served-stale envs in the background. Settings thread VS Code → LanguageServer → `JuliaWorkspace` kwargs → `DynamicFeature` fields / Salsa input.

**Tech Stack:** Julia; Salsa-style incremental engine; JSONRPC parent↔child protocol; TestItemRunner testitems.

**Spec:** `docs/superpowers/specs/2026-07-19-djp-concurrency-standalone-fastlane-design.md`

## Global Constraints

- Repo root for all paths below: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces` (git commands run HERE, it is its own repo). LanguageServer tasks state their own root.
- `@testitem` bodies MUST import every name explicitly (`using JuliaWorkspaces: X, Y`) — TestItemRunner default usings do not apply under the REPL runner.
- Run tests through the julia-mcp session (dev env active), from the JuliaWorkspaces dir:
  `using TestItemRunner; @run_package_tests filter=ti->occursin("Dynamic reconcile", ti.name)`
  — referred to below as **RUN-TESTS**. Expected output is a `Test Summary` with all listed testitems passing.
- Never spawn real child Julia processes in tests: always construct `DynamicFeature` with an injected `launcher` and drive `handle!` synchronously. Never touch `~/.julia`.
- Settings are constructor-time only (match `symbolcache_download` precedent). Setting names: `julia.maxConcurrentIndexingProcesses` (int, default 4, 0 = unlimited), `julia.enableWorkspaceEnvironmentResolution` (bool, default true).
- Commit after every task with the exact message given; end every commit message with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

---

### Task 1: Launch priority function

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (add helpers right after the `DynamicJuliaProcess` struct block, which ends near line 50)
- Test: `test/test_dynamic_reconcile.jl` (create)

**Interfaces:**
- Produces: `_key_path(::DJPKey)::String`, `_kind_rank(::DJPKey)::Int`, `_launch_priority(::DJPKey)::Tuple{Int,Int}` — later tasks sort launches by `_launch_priority` (lower launches first).
- Key fields (defined in `src/dynamic_feature/dynamic_messages.jl`): `WatchEnvironmentKey(project_path::String, content_hash::UInt64)`, `WatchTestEnvironmentKey(project_path::String, package_name::String, content_hash::UInt64)`, `CreateStandaloneProjectKey(package_path::String, content_hash::UInt64)`.

- [ ] **Step 1: Write the failing test** — create `test/test_dynamic_reconcile.jl` with:

```julia
@testitem "Dynamic reconcile: launch priority orders by depth then kind" begin
    using JuliaWorkspaces: _launch_priority, WatchEnvironmentKey, WatchTestEnvironmentKey,
        CreateStandaloneProjectKey

    root_env   = WatchEnvironmentKey("/ws/Pkg", UInt64(1))
    testenv    = WatchTestEnvironmentKey("/ws/Pkg", "Pkg", UInt64(2))
    standalone = CreateStandaloneProjectKey("/ws/Pkg", UInt64(3))
    fixture    = CreateStandaloneProjectKey("/ws/Pkg/test/testdata/Fixture", UInt64(4))
    nested_env = WatchEnvironmentKey("/ws/Pkg/docs", UInt64(5))

    # shallower paths first
    @test _launch_priority(root_env) < _launch_priority(nested_env)
    @test _launch_priority(nested_env) < _launch_priority(fixture)
    # kind rank breaks ties at equal depth: env < standalone < test env
    @test _launch_priority(root_env) < _launch_priority(standalone)
    @test _launch_priority(standalone) < _launch_priority(testenv)
end
```

Add `include("test_dynamic_reconcile.jl")` to `test/runtests.jl` only if that file lists includes explicitly (check first — if tests are discovered by directory scan, no edit needed).

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (`_launch_priority` not defined).

- [ ] **Step 3: Implement** — in `src/dynamic_feature/dynamic_feature.jl`, after the `DynamicProcessCrashException` struct (below the `DynamicJuliaProcess` helpers):

```julia
# ─── Launch prioritization ───────────────────────────────────────────────────
#
# Environments higher up the directory tree resolve first, so a package's main
# environment is ready before its test environment, testdata fixtures, nested
# docs/benchmark projects, etc. At equal depth the main env beats a standalone
# project beats a test env (a package's test-env key carries the same path as
# its main-env key).

_key_path(key::WatchEnvironmentKey) = key.project_path
_key_path(key::WatchTestEnvironmentKey) = key.project_path
_key_path(key::CreateStandaloneProjectKey) = key.package_path

_kind_rank(::WatchEnvironmentKey) = 0
_kind_rank(::CreateStandaloneProjectKey) = 1
_kind_rank(::WatchTestEnvironmentKey) = 2

function _launch_priority(key::DJPKey)
    depth = count(c -> c == '/' || c == '\\', normpath(_key_path(key)))
    return (depth, _kind_rank(key))
end
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_dynamic_reconcile.jl
git commit -m "feat: launch-priority ordering for dynamic-project keys

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Cap fields, launcher seam, and gated launching

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (struct `DynamicFeature` ~line 305, its constructor ~line 332, `handle!` for `EnvironmentPrepDoneMsg` ~line 703, `WatchTestEnvironmentMsg` ~line 727, `CreateStandaloneProjectMsg` ~line 746)
- Modify: `src/types.jl` (`JuliaWorkspace` constructor, lines 357–362)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Consumes: `_launch_priority` (Task 1); existing `_launch_process!(df, djp)`, `_report_progress`, `_progress_key`.
- Produces: `DynamicFeature` fields `max_concurrent_djps::Int`, `launch_queue::Vector{DJPKey}`, `launching::Set{DJPKey}`, `launcher::Function`; functions `_has_free_slot(df)::Bool`, `_launch_now!(df, key)`, `_request_launch!(df, key)`. Constructor kwargs `max_concurrent_djps::Int=4`, `launcher::Function=_launch_process!`; `JuliaWorkspace(; max_concurrent_djps::Int=4)`.

- [ ] **Step 1: Write the failing tests** — append to `test/test_dynamic_reconcile.jl`:

```julia
@testitem "Dynamic reconcile: cap limits concurrent launches" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=2, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))

    @test length(launches) == 2
    @test length(df.launch_queue) == 3
    @test length(df.launching) == 2
    @test df.pending_count[] == 5          # queued work still counts as pending
    @test isempty(intersect(Set(df.launch_queue), df.launching))
end

@testitem "Dynamic reconcile: cap 0 means unlimited" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=0, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:5]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))

    @test length(launches) == 5
    @test isempty(df.launch_queue)
end
```

- [ ] **Step 2: RUN-TESTS** — expected: the two new testitems FAIL (no `max_concurrent_djps` kwarg).

- [ ] **Step 3: Implement.**

3a. In `struct DynamicFeature`, after the `controller_fsm::FSM{DynamicControllerPhase}` field, add:

```julia
    # ── Launch concurrency cap ──
    # Maximum number of concurrently *working* child processes (<= 0: unlimited).
    max_concurrent_djps::Int
    # Keys ready to launch but over the cap; drained best-`_launch_priority`
    # first, insertion order as the final tiebreak.
    launch_queue::Vector{DJPKey}
    # Keys whose child has been launched and whose work item has not reached a
    # terminal message yet — the set the cap counts (NOT `procs`: persistent
    # children that finished indexing stay in `procs` without holding a slot).
    launching::Set{DJPKey}
    # Launch implementation; injectable so reactor tests observe launches
    # without spawning processes (same seam pattern as `progress_callback`).
    launcher::Function
```

3b. Extend the inner constructor signature with `max_concurrent_djps::Int=4, launcher::Function=_launch_process!` and append matching values to the `new(...)` call (order must match the field order):

```julia
    function DynamicFeature(djp_mode::DynamicMode, store_path::String;
            download_enabled::Bool=false, upstream_url::String=DEFAULT_SYMBOLCACHE_UPSTREAM,
            progress_callback::Union{Nothing,Function}=nothing,
            max_concurrent_djps::Int=4, launcher::Function=_launch_process!)
        return new(
            ..., # all existing arguments unchanged
            dynamic_controller_fsm("dynamic_controller"),
            max_concurrent_djps,
            Vector{DJPKey}(),
            Set{DJPKey}(),
            launcher,
        )
    end
```

3c. Below `_launch_process!`, add:

```julia
_has_free_slot(df::DynamicFeature) =
    df.max_concurrent_djps <= 0 || length(df.launching) < df.max_concurrent_djps

# Construct the DJP for `key` and launch it, occupying a slot. The DJP is
# derived from the key alone so queued keys carry no state that can go stale.
function _launch_now!(df::DynamicFeature, key::DJPKey)
    djp = if key isa WatchEnvironmentKey
        DynamicJuliaProcess(key, key.project_path, nothing, :watch_environment)
    elseif key isa WatchTestEnvironmentKey
        DynamicJuliaProcess(key, key.project_path, key.package_name, :watch_test_environment)
    else
        DynamicJuliaProcess(key, key.package_path, nothing, :create_standalone_project)
    end
    df.procs[key] = djp
    push!(df.launching, key)
    df.launcher(df, djp)
    return
end

# Launch `key` if a slot is free, otherwise queue it.
function _request_launch!(df::DynamicFeature, key::DJPKey)
    if _has_free_slot(df)
        _launch_now!(df, key)
    else
        _report_progress(df, _progress_key("index", key), "Queued for indexing...", 0)
        push!(df.launch_queue, key)
    end
    return
end
```

3d. Rewire the three launch sites to `_request_launch!(df, key)`:

- `handle!(df, ::EnvironmentPrepDoneMsg)`, the `elseif df.djp_mode != DynamicOff` branch — replace

```julia
        djp = DynamicJuliaProcess(key, key.project_path, nothing, :watch_environment)
        df.procs[key] = djp
        _launch_process!(df, djp)
```

with `        _request_launch!(df, key)`.

- `handle!(df, ::WatchTestEnvironmentMsg)` — replace

```julia
    djp = DynamicJuliaProcess(key, key.project_path, key.package_name, :watch_test_environment)
    df.procs[key] = djp
    _launch_process!(df, djp)
```

with `    _request_launch!(df, key)`.

- `handle!(df, ::CreateStandaloneProjectMsg)` — replace

```julia
    djp = DynamicJuliaProcess(key, key.package_path, nothing, :create_standalone_project)
    df.procs[key] = djp
    _launch_process!(df, djp)
```

with `    _request_launch!(df, key)`.

3e. In `src/types.jl`, thread the kwarg through `JuliaWorkspace`: add `max_concurrent_djps::Int=4` to the keyword list at line 357 and pass `max_concurrent_djps=max_concurrent_djps` in the `DynamicFeature(...)` call at line 362. Add one docstring line next to the `symbolcache_download` entry:

```julia
- `max_concurrent_djps::Int`: Maximum number of concurrently working dynamic
  child processes (`0` disables the limit). Defaults to 4.
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS (all three testitems so far).

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl src/types.jl test/test_dynamic_reconcile.jl
git commit -m "feat: cap concurrent dynamic-child launches behind a setting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Slot freeing and priority-ordered queue drain

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (`handle!` for `ProcessIndexedMsg` ~line 817, `ProcessIndexFailedMsg` ~line 853, `ProcessTerminatedMsg` ~line 875)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Consumes: `_launch_priority`, `_has_free_slot`, `_launch_now!` (Tasks 1–2).
- Produces: `_free_slot!(df, key)` (removes from `launching`, drains) and `_drain_launch_queue!(df)` — Task 4 and Task 7 call both.

- [ ] **Step 1: Write the failing tests** — append:

```julia
@testitem "Dynamic reconcile: finished work frees a slot for the best-priority queued key" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        ProcessIndexFailedMsg, WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    shallow_late = CreateStandaloneProjectKey("/ws/A", UInt64(1))          # standalone, depth 2
    deep         = CreateStandaloneProjectKey("/ws/A/test/data/B", UInt64(2))
    first_up     = WatchTestEnvironmentKey("/ws/C/sub", "C", UInt64(3))    # depth 3

    # Insertion order deliberately not priority order.
    handle!(df, ReconcileMsg(Set{DJPKey}([deep, first_up, shallow_late])))
    @test length(launches) == 1
    @test launches[1] == shallow_late          # dispatch is priority-sorted (Task 4 asserts too)

    handle!(df, ProcessIndexedMsg(launches[1], "/tmp/x"))
    @test length(launches) == 2
    @test launches[2] == first_up              # depth 3 beats depth 4

    handle!(df, ProcessIndexFailedMsg(launches[2], ErrorException("boom")))
    @test length(launches) == 3
    @test launches[3] == deep
    @test isempty(df.launch_queue)
    @test df.pending_count[] == 1              # only `deep` still pending
end
```

- [ ] **Step 2: RUN-TESTS** — expected: new testitem FAILS (only one launch ever happens; slots never free).

- [ ] **Step 3: Implement.** Add below `_request_launch!`:

```julia
# Launch queued keys, best `_launch_priority` first (stable: strict `<` keeps
# insertion order among equals), while slots are free. Skips keys whose work
# was cancelled while queued.
function _drain_launch_queue!(df::DynamicFeature)
    while _has_free_slot(df) && !isempty(df.launch_queue)
        best = 1
        for i in 2:length(df.launch_queue)
            if _launch_priority(df.launch_queue[i]) < _launch_priority(df.launch_queue[best])
                best = i
            end
        end
        key = df.launch_queue[best]
        deleteat!(df.launch_queue, best)
        key in df.inflight || continue
        _launch_now!(df, key)
    end
    return
end

# A launched child reached a terminal state: release its slot and refill.
function _free_slot!(df::DynamicFeature, key::DJPKey)
    delete!(df.launching, key)
    _drain_launch_queue!(df)
    return
end
```

Then add `_free_slot!(df, key)` in the three terminal handlers:

- `handle!(df, ::ProcessIndexedMsg)`: directly before `_complete_work_item!(df, key)` at the end.
- `handle!(df, ::ProcessIndexFailedMsg)`: directly before `_complete_work_item!(df, key)` at the end.
- `handle!(df, ::ProcessTerminatedMsg)`: after the `if key in df.inflight && ...` block (unconditionally before `return` — freeing a key that never launched is a no-op).

- [ ] **Step 4: RUN-TESTS** — expected: PASS. (If the `launches[1] == shallow_late` assertion fails because reconcile dispatch is still Set-ordered, that is Task 4 — temporarily assert `launches[1] in (shallow_late, deep, first_up)` is NOT acceptable; instead do Task 4's reconcile sort as part of this step if the test flakes: see Task 4 Step 3, it is a two-line change. Keep both commits separate only if the test passes deterministically.)

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_dynamic_reconcile.jl
git commit -m "feat: free launch slots on terminal messages; drain queue by priority

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Priority-sorted reconcile dispatch + queue purge

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (`handle!(df, ::ReconcileMsg)` ~line 928)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Consumes: `_launch_priority`, `_free_slot!`, `_drain_launch_queue!`, `_complete_work_item!`.

- [ ] **Step 1: Write the failing tests** — append:

```julia
@testitem "Dynamic reconcile: dropped keys are purged from queue and accounting balances" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg, ProcessIndexedMsg,
        WatchTestEnvironmentKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    keys = [WatchTestEnvironmentKey("/ws/p$i", "P$i", UInt64(i)) for i in 1:3]
    handle!(df, ReconcileMsg(Set{DJPKey}(keys)))
    @test length(launches) == 1
    @test length(df.launch_queue) == 2

    # Second reconcile keeps only the launched key: queued keys must vanish
    # without ever launching, and their pending work items must be balanced.
    handle!(df, ReconcileMsg(Set{DJPKey}([launches[1]])))
    @test isempty(df.launch_queue)
    @test df.pending_count[] == 1

    handle!(df, ProcessIndexedMsg(launches[1], "/tmp/x"))
    @test df.pending_count[] == 0
    @test length(launches) == 1
end

@testitem "Dynamic reconcile: initial dispatch launches shallowest keys first" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, ReconcileMsg,
        WatchTestEnvironmentKey, CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=2, launcher=(df, djp) -> push!(launches, djp.key))

    fixture  = CreateStandaloneProjectKey("/ws/Pkg/test/testdata/Fix", UInt64(1))
    root_sa  = CreateStandaloneProjectKey("/ws/Pkg", UInt64(2))
    testenv  = WatchTestEnvironmentKey("/ws/Pkg", "Pkg", UInt64(3))

    handle!(df, ReconcileMsg(Set{DJPKey}([fixture, root_sa, testenv])))
    @test launches == [root_sa, testenv]      # standalone(1) then testenv(2) at depth 2
    @test df.launch_queue == [fixture]
end
```

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (queued keys re-launch / dispatch order is Set order).

- [ ] **Step 3: Implement.** In `handle!(df, ::ReconcileMsg)`:

3a. After the existing `filter!(k -> k in required, df.failed_projects)` line, purge the queue (queued keys are inflight bookkeeping-wise, so balance them like the kill path does):

```julia
    # Queued-but-not-launched keys that are no longer required never launch;
    # balance their pending work items like the kill path above.
    filter!(df.launch_queue) do k
        k in required && return true
        _complete_work_item!(df, k)
        return false
    end
```

3b. Also handle killed *launched* keys: inside the existing kill loop (`if key ∉ required`), after `_complete_work_item!(df, key)`, add `delete!(df.launching, key)`.

3c. Make dispatch priority-ordered — replace `for key in required` with:

```julia
    for key in sort!(collect(required); by=_launch_priority)
```

3d. At the very end of the handler (before `return false`), refill slots freed by the kill loop:

```julia
    _drain_launch_queue!(df)
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS (all six testitems).

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_dynamic_reconcile.jl
git commit -m "feat: priority-sorted reconcile dispatch; purge dropped keys from launch queue

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Setting to disable dynamic workspace resolution

**Files:**
- Modify: `src/inputs.jl` (next to `input_env_ready`, line 9)
- Modify: `src/types.jl` (`JuliaWorkspace` kwarg + input init, lines 357–369)
- Modify: `src/layer_environment.jl` (`derived_required_dynamic_projects`, ~line 297)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Produces: `input_resolve_workspace_environments(rt)::Bool` (+ `set_input_resolve_workspace_environments!`); `JuliaWorkspace(; resolve_workspace_environments::Bool=true)`.

- [ ] **Step 1: Write the failing test** — append:

```julia
@testitem "Dynamic reconcile: resolve_workspace_environments=false keeps only real envs" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        derived_required_dynamic_projects, WatchEnvironmentKey
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "P"
    uuid = "11111111-1111-1111-1111-111111111111"
    version = "0.1.0"
    """
    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc"

    [deps]
    """
    # A workspace project (watch-env key) plus a manifest-less package
    # (standalone key) with a runtests.jl (test-env key).
    files = [
        TextFile(URI("file:///ws/Proj/Project.toml"), SourceText(project_toml, "toml")),
        TextFile(URI("file:///ws/Proj/Manifest.toml"), SourceText(manifest_toml, "toml")),
        TextFile(URI("file:///ws/Proj/src/P.jl"), SourceText("module P end", "julia")),
        TextFile(URI("file:///ws/Bare/Project.toml"), SourceText(replace(project_toml, "\"P\"" => "\"Bare\"", "1111\"" => "2222\""), "toml")),
        TextFile(URI("file:///ws/Bare/src/Bare.jl"), SourceText("module Bare end", "julia")),
        TextFile(URI("file:///ws/Bare/test/runtests.jl"), SourceText("using Test", "julia")),
    ]

    jw_on = JuliaWorkspace()
    foreach(f -> add_file!(jw_on, f), files)
    req_on = derived_required_dynamic_projects(jw_on.runtime)

    jw_off = JuliaWorkspace(resolve_workspace_environments=false)
    foreach(f -> add_file!(jw_off, f), files)
    req_off = derived_required_dynamic_projects(jw_off.runtime)

    @test any(k -> !(k isa WatchEnvironmentKey), req_on)      # sanity: fabrication happens
    @test all(k -> k isa WatchEnvironmentKey, req_off)        # ...and is fully disabled
    @test !isempty(req_off)                                   # real projects still watched
end
```

(Note: `derived_required_dynamic_projects`'s test-env branch checks `isfile(runtests_path)` on the real filesystem, so the `/ws/Bare/test/runtests.jl` in-memory file may not produce a test-env key — the assertion only requires that *some* non-watch key exists in `req_on`, which the standalone key for `Bare` provides only if `Bare` has no Manifest. That is why `Bare` gets no Manifest.toml above. If `req_on` contains only watch keys, drop the `runtests.jl` file and re-check: the `Bare` package folder without a manifest must yield a `CreateStandaloneProjectKey`.)

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (`resolve_workspace_environments` kwarg unknown).

- [ ] **Step 3: Implement.**

3a. `src/inputs.jl`, next to `input_env_ready`:

```julia
# Whether the workspace fabricates environments (standalone projects for
# manifest-less packages, merged test environments). When false only real
# project environments are watched.
Salsa.@declare_input input_resolve_workspace_environments(rt)::Bool
```

3b. `src/types.jl`: add `resolve_workspace_environments::Bool=true` to the `JuliaWorkspace` kwargs; next to `set_input_env_ready!(rt, false)` add `set_input_resolve_workspace_environments!(rt, resolve_workspace_environments)`. Docstring line:

```julia
- `resolve_workspace_environments::Bool`: When `false`, no standalone package
  projects or test environments are created; only real project environments
  are watched. Defaults to `true`.
```

3c. `src/layer_environment.jl`, in `derived_required_dynamic_projects`, right after the WatchEnvironment loop (before the package-folders loop), add:

```julia
    # Standalone projects and test environments are fabricated only when
    # workspace-environment resolution is enabled.
    input_resolve_workspace_environments(rt) || return required
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/inputs.jl src/types.jl src/layer_environment.jl test/test_dynamic_reconcile.jl
git commit -m "feat: setting to disable dynamic workspace-environment resolution

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Persistent standalone-project dirs + protocol `projectDir`

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (`create_standalone_project` client fn ~line 65; new `_standalone_project_dir` helper near `_launch_priority`)
- Modify: `shared/julia_dynamic_analysis_process_protocol.jl` (`CreateStandaloneProjectParams`)
- Modify: `juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/JuliaDynamicAnalysisProcess.jl` (`create_standalone_project_request`)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Produces: `_standalone_project_dir(df, key::CreateStandaloneProjectKey)::String` — deterministic, hash-keyed, parent-created; used by Task 7's prep and by `create_standalone_project` (which gains a `project_dir::String` argument). Protocol `CreateStandaloneProjectParams(packagePath, storePath, projectDir)`.

- [ ] **Step 1: Write the failing test** — append:

```julia
@testitem "Dynamic reconcile: standalone project dirs are hash-keyed and cleaned up" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, CreateStandaloneProjectKey,
        _standalone_project_dir

    store = mktempdir()
    df = DynamicFeature(DynamicPersistent, store; launcher=(df, djp) -> nothing)

    key1 = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0x1234))
    key2 = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0x5678))

    dir1 = _standalone_project_dir(df, key1)
    @test startswith(dir1, joinpath(dirname(store), "standalone-projects"))
    @test occursin("Pkg-", basename(dir1))
    @test _standalone_project_dir(df, key1) == dir1      # deterministic
    @test isdir(dir1)                                    # parent-created

    dir2 = _standalone_project_dir(df, key2)
    @test dir2 != dir1
    @test !isdir(dir1)      # old hash dir for the same package cleaned up
end
```

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (`_standalone_project_dir` not defined).

- [ ] **Step 3: Implement.**

3a. In `src/dynamic_feature/dynamic_feature.jl` (near `_launch_priority`):

```julia
# Persistent, deterministic project dir for a standalone package: reused
# across sessions while the package's Project.toml (content hash) is
# unchanged. Sibling dirs for the same package under an *old* hash are
# removed — a changed package gets a fresh resolve, and growth stays bounded.
function _standalone_project_dir(df::DynamicFeature, key::CreateStandaloneProjectKey)
    parent = joinpath(dirname(df.store_path), "standalone-projects")
    name = basename(key.package_path)
    dir = joinpath(parent, string(name, "-", string(key.content_hash, base=16, pad=16)))
    if isdir(parent)
        for other in readdir(parent; join=true)
            if startswith(basename(other), string(name, "-")) && other != dir
                try rm(other; recursive=true) catch; end
            end
        end
    end
    mkpath(dir)
    return dir
end
```

3b. `shared/julia_dynamic_analysis_process_protocol.jl`:

```julia
@dict_readable struct CreateStandaloneProjectParams <: JSONRPC.Outbound
    packagePath::String
    storePath::String
    projectDir::String
end
```

3c. `create_standalone_project` in `dynamic_feature.jl` gains the dir:

```julia
function create_standalone_project(djp::DynamicJuliaProcess, store_path::String, project_dir::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.create_standalone_project_request_type,
        JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams(
            djp.project_path,
            store_path,
            project_dir
        )
    )
end
```

and its call site in `handle!(df, ::ProcessLaunchedMsg)` becomes:

```julia
        result_dir = if key isa CreateStandaloneProjectKey
            create_standalone_project(djp, df.store_path, _standalone_project_dir(df, key))
        else
            index_project(djp, df.store_path)
        end
```

3d. Child side, `juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/JuliaDynamicAnalysisProcess.jl`:

```julia
function create_standalone_project_request(params::JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams, state::JuliaDynamicAnalysisProcessState, token)
    mkpath(params.projectDir)
    Pkg.activate(params.projectDir)

    try
        Pkg.develop(path=params.packagePath)
        Pkg.resolve()
    catch err
        @warn "Failed to resolve standalone package project" params.packagePath exception=(err, catch_backtrace())
    end

    SymbolServer.get_store(params.storePath, progress_reporter(state))

    return dirname(Base.active_project())
end
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl shared/julia_dynamic_analysis_process_protocol.jl juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/JuliaDynamicAnalysisProcess.jl test/test_dynamic_reconcile.jl
git commit -m "feat: persistent hash-keyed standalone-project dirs via protocol projectDir

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Standalone prep fast lane (serve stale)

**Files:**
- Modify: `src/dynamic_feature/dynamic_messages.jl` (new message next to `EnvironmentPrepDoneMsg`)
- Modify: `src/dynamic_feature/dynamic_feature.jl` (`handle!(df, ::CreateStandaloneProjectMsg)`; new `handle!` for the prep-done message)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Consumes: `_standalone_project_dir` (Task 6), `_get_missing_packages(project_path, store_path)` (existing, returns a Vector; empty = all caches present), `_request_launch!`, `_complete_work_item!`, `StandaloneProjectReadyResult` (existing result type: `StandaloneProjectReadyResult(package_folder_uri::URI, project_uri::URI, content_hash::UInt64)` — check the constructor argument order at its definition in `dynamic_messages.jl` before use; the reactor's existing `ProcessIndexedMsg` handler shows the exact call shape).
- Produces: `StandaloneProjectPrepDoneMsg(key, fast_lane::Bool)`; `refresh_queue::Vector{DJPKey}` and `refreshing::Set{DJPKey}` fields (declared here, drained in Task 8).

- [ ] **Step 1: Write the failing tests** — append:

```julia
@testitem "Dynamic reconcile: standalone fast lane serves existing project without a child" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, CreateStandaloneProjectMsg,
        StandaloneProjectPrepDoneMsg, CreateStandaloneProjectKey, StandaloneProjectReadyResult,
        DJPKey, handle!, _standalone_project_dir

    launches = DJPKey[]
    store = mktempdir()
    df = DynamicFeature(DynamicPersistent, store; launcher=(df, djp) -> push!(launches, djp.key))

    key = CreateStandaloneProjectKey("/ws/Pkg", UInt64(0xabc))
    dir = _standalone_project_dir(df, key)
    write(joinpath(dir, "Project.toml"), "name = \"scratch\"\n")
    write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"x\"\n\n[deps]\n")

    # Drive the prep decision synchronously (the async prep task is exercised
    # end-to-end by the suites; reactor logic is what we test here).
    push!(df.inflight, key)
    handle!(df, StandaloneProjectPrepDoneMsg(key, true))

    @test isempty(launches)                       # no child
    @test key in df.done
    @test df.refresh_queue == [key]               # background refresh queued
    result = take!(df.out_channel)
    @test result isa StandaloneProjectReadyResult
end

@testitem "Dynamic reconcile: standalone prep miss launches through the cap" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        CreateStandaloneProjectKey, DJPKey, handle!

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    k1 = CreateStandaloneProjectKey("/ws/A", UInt64(1))
    k2 = CreateStandaloneProjectKey("/ws/B", UInt64(2))
    push!(df.inflight, k1); push!(df.inflight, k2)

    handle!(df, StandaloneProjectPrepDoneMsg(k1, false))
    handle!(df, StandaloneProjectPrepDoneMsg(k2, false))

    @test launches == [k1]
    @test df.launch_queue == [k2]
    @test isempty(df.refresh_queue)
end
```

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (`StandaloneProjectPrepDoneMsg` not defined).

- [ ] **Step 3: Implement.**

3a. `src/dynamic_feature/dynamic_messages.jl`, next to `EnvironmentPrepDoneMsg`:

```julia
"""
Posted by the async standalone-prep task spawned from
`CreateStandaloneProjectMsg`. `fast_lane` is true when the persistent project
dir already exists and all of its manifest's packages have symbol caches — the
stale environment is served immediately and refreshed in the background.
"""
struct StandaloneProjectPrepDoneMsg <: DynamicReactorMessage
    key::CreateStandaloneProjectKey
    fast_lane::Bool
end
```

3b. `DynamicFeature` struct gains (after `launcher`), with matching `new(...)` entries `Vector{DJPKey}(), Set{DJPKey}()`:

```julia
    # ── Background refresh of served-stale standalone envs ──
    # Strictly lower priority than `launch_queue`; never counts as a pending
    # work item (readiness must not wait on refreshes).
    refresh_queue::Vector{DJPKey}
    refreshing::Set{DJPKey}
```

3c. Rewrite `handle!(df, ::CreateStandaloneProjectMsg)` — keep the `failed_projects` early-out, then prep on a task (WatchEnvironment pattern):

```julia
function handle!(df::DynamicFeature, msg::CreateStandaloneProjectMsg)
    key = msg.key
    push!(df.inflight, key)

    if key in df.failed_projects
        @warn "Skipping previously failed standalone project" key
        put!(df.out_channel, FailedResult(key))
        _complete_work_item!(df, key)
        return false
    end

    _report_progress(df, _progress_key("index", key), "Checking standalone project for $(basename(key.package_path))...", 0)

    # Offload the (IO-bound) dir + missing-package check to a task so the
    # reactor stays responsive; the decision comes back as a
    # `StandaloneProjectPrepDoneMsg` so all state mutation stays on the reactor.
    dir = _standalone_project_dir(df, key)
    store_path = df.store_path
    Threads.@async try
        usable = isfile(joinpath(dir, "Project.toml")) && isfile(joinpath(dir, "Manifest.toml"))
        fast_lane = usable && isempty(_get_missing_packages(dir, store_path))
        put!(df.in_channel, StandaloneProjectPrepDoneMsg(key, fast_lane))
    catch err
        @error "Standalone project prep failed" key exception=(err, catch_backtrace())
        put!(df.in_channel, ProcessIndexFailedMsg(key, err))
    end

    return false
end
```

3d. New handler (next to `EnvironmentPrepDoneMsg`'s):

```julia
function handle!(df::DynamicFeature, msg::StandaloneProjectPrepDoneMsg)
    key = msg.key

    if msg.fast_lane
        @info "Serving existing standalone project; refreshing in background" package_path=key.package_path
        dir = _standalone_project_dir(df, key)
        put!(df.out_channel, StandaloneProjectReadyResult(filepath2uri(key.package_path), filepath2uri(dir), key.content_hash))
        push!(df.done, key)
        _complete_work_item!(df, key)
        push!(df.refresh_queue, key)
        _drain_launch_queue!(df)
    else
        _report_progress(df, _progress_key("index", key), "Creating standalone project for $(basename(key.package_path))...", 0)
        _request_launch!(df, key)
    end

    return false
end
```

(Verify `StandaloneProjectReadyResult`'s field order against its definition in `dynamic_messages.jl` — mirror the existing construction in `handle!(df, ::ProcessIndexedMsg)`, which passes `(filepath2uri(key.package_path), standalone_project_uri, key.content_hash)`.)

- [ ] **Step 4: RUN-TESTS** — expected: PASS. (Task 8 makes the refresh queue actually drain; here it only accumulates.)

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_messages.jl src/dynamic_feature/dynamic_feature.jl test/test_dynamic_reconcile.jl
git commit -m "feat: standalone-project prep fast lane serves the persistent env

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Background refresh (strict low priority, not a work item)

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (`_drain_launch_queue!`; terminal handlers; `handle!(df, ::ReconcileMsg)` purge)
- Test: `test/test_dynamic_reconcile.jl`

**Interfaces:**
- Consumes: everything above.
- Produces: refresh launches through `df.launcher` with the key additionally in `df.refreshing`; terminal messages for refreshing keys re-emit the ready result without touching `pending_count`/`failed_projects`.

- [ ] **Step 1: Write the failing tests** — append:

```julia
@testitem "Dynamic reconcile: refresh runs at strict low priority and is not a work item" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ProcessIndexedMsg, ProcessIndexFailedMsg, CreateStandaloneProjectKey,
        WatchTestEnvironmentKey, StandaloneProjectReadyResult, DJPKey, handle!,
        _standalone_project_dir

    launches = DJPKey[]
    df = DynamicFeature(DynamicPersistent, mktempdir();
        max_concurrent_djps=1, launcher=(df, djp) -> push!(launches, djp.key))

    fast = CreateStandaloneProjectKey("/ws/Fast", UInt64(1))
    slow = WatchTestEnvironmentKey("/ws/Slow", "Slow", UInt64(2))

    # Fast-lane hit queues a refresh...
    push!(df.inflight, fast)
    handle!(df, StandaloneProjectPrepDoneMsg(fast, true))
    take!(df.out_channel)               # the served-stale ready result
    pending_after_serve = df.pending_count[]

    # ...but first-time work still wins the only slot.
    push!(df.inflight, slow)
    handle!(df, JuliaWorkspaces.WatchTestEnvironmentMsg(slow))
    @test launches == [slow]

    # Slot frees with nothing left in the primary queue -> refresh launches.
    handle!(df, ProcessIndexedMsg(slow, "/tmp/x"))
    take!(df.out_channel)               # slow's ready result
    @test launches == [slow, fast]
    @test fast in df.refreshing
    @test df.pending_count[] == pending_after_serve   # refresh never counted

    # Refresh completion re-emits the ready result and frees the slot.
    handle!(df, ProcessIndexedMsg(fast, _standalone_project_dir(df, fast)))
    @test take!(df.out_channel) isa StandaloneProjectReadyResult
    @test !(fast in df.refreshing)

    # A refresh failure must not poison failed_projects.
    push!(df.inflight, fast)
    handle!(df, StandaloneProjectPrepDoneMsg(fast, true))
    take!(df.out_channel)
    handle!(df, ProcessIndexedMsg(WatchTestEnvironmentKey("/dummy", "D", UInt64(9)), "/tmp"))  # no-op drain trigger
    # drain directly: the queue drains on any slot release; fast is queued
    @test fast in df.refresh_queue || fast in df.refreshing
    if fast in df.refreshing
        handle!(df, ProcessIndexFailedMsg(fast, ErrorException("refresh boom")))
        @test !(fast in df.failed_projects)
        @test fast in df.done
    end
end

@testitem "Dynamic reconcile: reconcile purges dropped refresh entries" begin
    using JuliaWorkspaces: DynamicFeature, DynamicPersistent, StandaloneProjectPrepDoneMsg,
        ReconcileMsg, CreateStandaloneProjectKey, DJPKey, handle!

    df = DynamicFeature(DynamicPersistent, mktempdir(); launcher=(df, djp) -> nothing)
    key = CreateStandaloneProjectKey("/ws/Gone", UInt64(7))
    push!(df.inflight, key)
    handle!(df, StandaloneProjectPrepDoneMsg(key, true))
    take!(df.out_channel)
    @test key in df.refresh_queue

    handle!(df, ReconcileMsg(Set{DJPKey}()))
    @test isempty(df.refresh_queue)
    @test isempty(df.refreshing)
end
```

- [ ] **Step 2: RUN-TESTS** — expected: FAIL (refresh queue never drains; refreshing never populated).

- [ ] **Step 3: Implement.**

3a. Extend `_drain_launch_queue!` — after the existing primary-queue `while` loop, add a refresh loop (strict priority: only entered when the primary queue is empty):

```julia
    # Refreshes fill remaining slots only when no first-time work wants them.
    while _has_free_slot(df) && isempty(df.launch_queue) && !isempty(df.refresh_queue)
        best = 1
        for i in 2:length(df.refresh_queue)
            if _launch_priority(df.refresh_queue[i]) < _launch_priority(df.refresh_queue[best])
                best = i
            end
        end
        key = df.refresh_queue[best]
        deleteat!(df.refresh_queue, best)
        push!(df.refreshing, key)
        _report_progress(df, _progress_key("refresh", key), "Refreshing environment...", 0)
        _launch_now!(df, key)
    end
```

3b. Terminal handlers — refreshing keys take a separate path *before* the `key ∉ df.inflight` guards:

In `handle!(df, ::ProcessIndexedMsg)`, insert at the very top:

```julia
    if key in df.refreshing
        # Background refresh finished: re-emit the (idempotent) ready result —
        # freshness lands via the rewritten Manifest and the result path's
        # package-cache loading. Never touches pending_count.
        delete!(df.refreshing, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing && state(djp.fsm) == DynamicProcessIndexing
            transition!(djp.fsm, DynamicProcessDone; reason="refreshed")
        end
        put!(df.out_channel, StandaloneProjectReadyResult(filepath2uri(key.package_path), filepath2uri(msg.result_dir), key.content_hash))
        if df.djp_mode == DynamicIndexingOnly && djp !== nothing
            kill(djp)
            delete!(df.procs, key)
        end
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end
```

In `handle!(df, ::ProcessIndexFailedMsg)`, insert at the very top:

```julia
    if key in df.refreshing
        # The served stale environment keeps working; do not poison
        # failed_projects over a refresh.
        @warn "Background environment refresh failed" key exception=(msg.err,)
        delete!(df.refreshing, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing
            try kill(djp) catch; end
            delete!(df.procs, key)
        end
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end
```

In `handle!(df, ::ProcessTerminatedMsg)`, insert after the `djp === nothing && return false` line:

```julia
    if key in df.refreshing && state(djp.fsm) in (DynamicProcessStarting, DynamicProcessConnected, DynamicProcessIndexing)
        @warn "Background refresh process terminated unexpectedly" key
        delete!(df.refreshing, key)
        try kill(djp) catch; end
        delete!(df.procs, key)
        _report_progress(df, _progress_key("refresh", key), "Done", 100)
        _free_slot!(df, key)
        return false
    end
```

3c. `handle!(df, ::ReconcileMsg)` — next to the launch-queue purge from Task 4, add:

```julia
    # Refresh bookkeeping for keys that are no longer required: queued entries
    # just vanish (they are not work items); launched ones are killed.
    filter!(k -> k in required, df.refresh_queue)
    for key in collect(df.refreshing)
        key in required && continue
        delete!(df.refreshing, key)
        djp = get(df.procs, key, nothing)
        if djp !== nothing
            try kill(djp) catch; end
            delete!(df.procs, key)
        end
        delete!(df.launching, key)
    end
```

- [ ] **Step 4: RUN-TESTS** — expected: PASS (all testitems in the file).

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_dynamic_reconcile.jl
git commit -m "feat: background refresh of served-stale standalone envs at low priority

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: LanguageServer settings plumbing

**Files (root: `/home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer` — separate git repo, commit there):**
- Modify: `src/languageserverinstance.jl` (struct fields ~line 59, constructor positional values ~line 100–112)
- Modify: `src/requests/init.jl` (~line 255: `ConfigurationItem` list + response handling ~line 268; `JuliaWorkspace(...)` call ~line 277)
- Modify: `src/requests/workspace.jl` (~line 93: `ConfigurationItem` list + response handling ~line 117)

No new unit tests (config fetch has no existing test seam); validated by the full LS suite in Task 10.

- [ ] **Step 1: Add server fields.** In `src/languageserverinstance.jl` after `enable_dynamic_indexing::Bool` (line 59):

```julia
    max_concurrent_indexing_processes::Int
    enable_workspace_environment_resolution::Bool
```

In the inner constructor's `new(...)` call, the values `false, "", true,` initialize `symbolcache_download`, `symbolcache_upstream`, `enable_dynamic_indexing` (count fields from the struct to locate them). Insert directly after the `true,` for `enable_dynamic_indexing`:

```julia
            4,
            true,
```

- [ ] **Step 2: Fetch the settings.** In BOTH `src/requests/init.jl` (~line 255) and `src/requests/workspace.jl` (~line 93), append to the `ConfigurationParams([...])` list:

```julia
        ConfigurationItem(missing, "julia.maxConcurrentIndexingProcesses"),
        ConfigurationItem(missing, "julia.enableWorkspaceEnvironmentResolution"),
```

and after the existing `server.enable_dynamic_indexing = something(response[8], true)` line in each file:

```julia
    server.max_concurrent_indexing_processes = something(response[9], 4)
    server.enable_workspace_environment_resolution = something(response[10], true)
```

(In `workspace.jl` the assignments sit under the "Store new settings on server; JW is not reconfigured at runtime" comment — same caveat applies to both new settings.)

- [ ] **Step 3: Thread into the workspace.** In `src/requests/init.jl`, the `JuliaWorkspace(;...)` construction (~line 277) gains:

```julia
        max_concurrent_djps=server.max_concurrent_indexing_processes,
        resolve_workspace_environments=server.enable_workspace_environment_resolution,
```

- [ ] **Step 4: Syntax check.** In the julia-mcp session: `using LanguageServer` after a session restart (precompilation is the check). Expected: no errors.

- [ ] **Step 5: Commit (in the LanguageServer repo!)**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/LanguageServer
git add src/languageserverinstance.jl src/requests/init.jl src/requests/workspace.jl
git commit -m "feat: settings for indexing concurrency and workspace-env resolution

julia.maxConcurrentIndexingProcesses caps concurrent dynamic indexing
child processes (0 = unlimited); julia.enableWorkspaceEnvironmentResolution
= false disables standalone-project/test-environment fabrication.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Validation + docs

**Files:**
- Modify: `docs/superpowers/2026-07-18-performance-future-work.md` (item "2. DJP reconcile concurrency")

- [ ] **Step 1: Full JuliaWorkspaces suite** (background Bash, new process — explicitly sanctioned for full-suite runs):

```bash
julia --project=/home/pfitzseb/git/julia-vscode/scripts/environments/development -e 'using Pkg; Pkg.test("JuliaWorkspaces")'
```

Expected: `Testing JuliaWorkspaces tests passed` (5318+ pass, 7 broken — plus the new testitems).

- [ ] **Step 2: Full LanguageServer suite** (same pattern):

```bash
julia --project=/home/pfitzseb/git/julia-vscode/scripts/environments/development -e 'using Pkg; Pkg.test("LanguageServer")'
```

Expected: `Testing LanguageServer tests passed` (162552 pass, 1 broken).

- [ ] **Step 3: Update the perf doc.** Rewrite backlog item "## 2. DJP reconcile concurrency" to record: implemented (cap + priority + standalone fast lane with serve-stale/background refresh + both settings), commits, and the follow-ups (test-env fast lane C; extension package.json declarations for both settings).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/2026-07-18-performance-future-work.md
git commit -m "docs: record DJP concurrency cap + standalone fast lane outcome

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: cap+setting (T2), priority incl. reconcile dispatch (T1/T3/T4), queue purge/accounting (T4), resolution setting (T5), persistent dirs + protocol (T6), fast lane serve-stale (T7), refresh semantics incl. failure/purge (T8), LS plumbing (T9), suites + doc (T10). Spec test list 1–12 → testitems: 1→T2, 2/2a→T3/T4, 3→T3, 4→T4, 5→T2, 6 (watch-env fast lane holds no slot) is implicit — `EnvironmentPrepDoneMsg(key, false)` never calls `_request_launch!`; covered by T2's cap test using only test-env keys plus T7's miss test; 7/8→T7, 9/10→T8, 11→T5, 12→T6.
- Extension `package.json` (julia-vscode repo) deliberately deferred (spec follow-up); LS defaults make missing client config safe.
- Type consistency: `_launch_priority`/`_request_launch!`/`_free_slot!`/`_drain_launch_queue!`/`_standalone_project_dir` names used identically across tasks; `StandaloneProjectPrepDoneMsg(key, fast_lane)` shape fixed in T7 and used nowhere else.
