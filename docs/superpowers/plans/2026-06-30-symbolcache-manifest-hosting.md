# Symbol-cache Manifest Hosting & Regeneration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the SymbolServer client fetch only caches that exist via a published availability index, host the caches as immutable gzip `tar.gz` artifacts on R2+CDN, and keep them fresh with a stateless incremental/full regeneration job.

**Architecture:** Three phases. (1) Client: download a small availability index and intersect it with the project's missing caches before fetching — additive change to the existing `tar.gz` download path. (2) Server: `jwcloudindex` emits the index from a store directory. (3) Hosting/regen: a stateless cron job indexes only what's missing, uploads additively to R2, and republishes the index; tombstones (plain `(uuid,treehash)` markers) are the only carried-forward state and live in the bucket.

**Tech Stack:** Julia (JuliaWorkspaces package + its `SymbolServer` submodule + `CloudIndexApp`), `Pkg.PlatformEngines.download_verify_unpack` for fetch/unpack, TestItemRunner `@testitem` tests, Docker orchestration (`scripts/run_cloudindex_docker.sh`), `rclone` for R2.

## Global Constraints

- Julia floor **1.11**; default toolchain 1.12.x (juliaup always available).
- Artifacts are **gzip `tar.gz`** (not zstd) — no new client dependency; reuse `download_verify_unpack`.
- Host at the existing **`v2`** layout (`store/v2/...`) — v2 isn't live yet, so no version bump; the client change is purely additive. (v1, the git repo at `github.com/julia-vscode/symbolcache`, is the legacy system being superseded.)
- Cache key everywhere is **`<uuid>/<stem>`** where `<stem>` is the cache filename minus `.jstore` (the tree-hash, `+`→`_`), i.e. `get_cache_path(manifest,uuid)` → `[I,Name,uuid,"<stem>.jstore"]` ⇒ `key = paths[3]*"/"*first(splitext(paths[4]))`.
- Tombstones are **plain `<uuid>/<stem>` markers — no fingerprinting**.
- Run modes are the whole retry policy: **incremental** (skip successes ∪ tombstones) and **full** (skip successes only; rebuild tombstones).
- **Environment (`$JLENV`):** all Julia invocations and the MCP `julia_eval`
  `env_path` use `/home/pfitzseb/git/julia-vscode/scripts/environments/development`
  (it has `JuliaWorkspaces` dev'd in and `TestItemRunner` added). Wherever a step
  says `julia --project ...`, read it as `julia --project=$JLENV ...`.
- **Tests:** fast inner loop — via `julia_eval` (env_path `$JLENV`), from the
  JuliaWorkspaces package root, run
  `using TestItemRunner; @run_package_tests filter=ti->occursin("<substr>", ti.name)`
  (the dev env now provides `TestItemRunner`, so focused item runs work without a
  full `Pkg.test` setup; if discovery comes up empty, fall back). Authoritative
  full run: `import Pkg; Pkg.test("JuliaWorkspaces")`.
- **Git:** create and work on a new branch **`sp/cache-infra`**, branched from
  `main` (the `jwcloudindex`/`CloudIndexApp` and SymbolServer changes this plan
  builds on are already merged): `git switch -c sp/cache-infra main`. Commit
  messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- `src/SymbolServer/availability.jl` — **new.** Pure helpers + index fetch for the client: `cache_key`, `cache_key_from_path`, `parse_availability_index`, `fetch_availability_index`. One responsibility: availability-index handling.
- `src/SymbolServer/SymbolServer.jl` — **modify.** `include("availability.jl")`; wire the index into `download_cache_files`. (No URL change — `get_file_from_cloud` already requests `store/v2/packages`.)
- `src/CloudIndex/index.jl` — **new.** `build_index(store_path)`, `write_index(store_path, io)`.
- `src/CloudIndexApp.jl` — **modify.** `include("CloudIndex/index.jl")`.
- `src/CloudIndex/cli.jl` — **modify.** Add `--emit-index PATH` and `--done-set FILE`.
- `src/CloudIndex/cache_state.jl` — **modify.** `done_key` + `find_missing(rows, ::AbstractSet)` (stateless resume predicate).
- `test/test_symbolcache_client.jl` — **new.** Phase 1 tests.
- `test/test_cloudindex.jl` — **modify.** Phase 2 index tests + done-set tests.
- `test/test_cache_infra_scripts.jl` — **new.** rclone-gated integration tests for the seed + regen + reconcile scripts (`:local:` remote, stub sweep; skip when rclone absent).
- `scripts/package_symbolcache.sh` — **new.** Packaging: store → v2 per-package tar.gz (index built by the caller).
- `scripts/seed_symbolcache.sh` — **new.** One-shot seed of a fresh remote from an existing store: package + derive index from artifacts + upload with Cache-Control.
- `scripts/regen_symbolcache.sh` — **new.** Stateless incremental/full regeneration driver.
- `scripts/reconcile_symbolcache.sh` — **new.** Periodic full-reconcile safety net (rebuild index from artifacts; drop stale tombstones; abort rather than wipe on a failed/empty list).

## Implementation status (2026-07-01, branch `sp/cache-infra`)

**Done + tested:** Phase 1 (client manifest lookup), Phase 2 (index generation + `--emit-index`), and the Phase-3 *code* — `package_symbolcache.sh`, `regen_symbolcache.sh`, `reconcile_symbolcache.sh`, the `--done-set` flag + `find_missing` done-set predicate, and committed rclone-gated integration tests (`test/test_cache_infra_scripts.jl`). The bucket lock was dropped (scheduler single-flight + reconcile). Design deviations from the original plan text below: the marker-file resume hack was replaced by `--done-set`; reconcile was added as its own script.

**Not done (infra/ops — need R2 credentials + deployment):** provisioning the bucket + CDN, seeding the initial corpus, scheduling the regen/reconcile jobs (Actions `concurrency:` for single-flight), and end-to-end client verification against the live host. The task steps below that invoke `rclone`/Docker against a real remote are superseded by the committed integration tests for logic coverage; the remaining work is deployment.

---

## Phase 1 — Client: manifest-based availability lookup

### Task 0: Create the working branch

- [ ] **Step 1: Branch from `main`**

```bash
git switch -c sp/cache-infra main
```

Expected: now on `sp/cache-infra`, with the (already-merged) `jwcloudindex`/
`CloudIndexApp` and SymbolServer code present. All subsequent tasks commit here.

### Task 1: Availability key + index parsing (pure helpers)

**Files:**
- Create: `src/SymbolServer/availability.jl`
- Modify: `src/SymbolServer/SymbolServer.jl` (add `include("availability.jl")` after the existing `include`s, before `end # module`)
- Test: `test/test_symbolcache_client.jl`

**Interfaces:**
- Produces:
  - `cache_key(uuid, stem)::String` → `"<uuid>/<stem>"`
  - `cache_key_from_path(paths::AbstractVector)::String` → key from a `get_cache_path` result
  - `parse_availability_index(io::IO)::Set{String}` and `parse_availability_index(s::AbstractString)::Set{String}`

- [ ] **Step 1: Write the failing tests**

Create `test/test_symbolcache_client.jl`:

```julia
@testitem "SymbolCache client: cache_key / cache_key_from_path" begin
    using JuliaWorkspaces.SymbolServer: cache_key, cache_key_from_path
    @test cache_key("abc-uuid", "deadbeef") == "abc-uuid/deadbeef"
    # get_cache_path shape: [Initial, Name, uuid, "<stem>.jstore"]
    @test cache_key_from_path(["E", "Example", "abc-uuid", "deadbeef.jstore"]) == "abc-uuid/deadbeef"
end

@testitem "SymbolCache client: parse_availability_index" begin
    using JuliaWorkspaces.SymbolServer: parse_availability_index
    text = "u1/h1\nu2/h2\n\n  u3/h3  \n"
    s = parse_availability_index(text)
    @test s == Set(["u1/h1", "u2/h2", "u3/h3"])      # trims, drops blank lines
    @test parse_availability_index(IOBuffer(text)) == s
    @test isempty(parse_availability_index(""))
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `julia --project -e 'import Pkg; Pkg.test("JuliaWorkspaces")'` (or the focused `@run_package_tests filter=ti->occursin("SymbolCache client", ti.name)` from the test env).
Expected: FAIL — `cache_key`/`parse_availability_index` not defined.

- [ ] **Step 3: Write the implementation**

Create `src/SymbolServer/availability.jl`:

```julia
# Client-side availability index: a published set of "<uuid>/<stem>" keys naming
# the caches that exist on the server, so we only fetch what's available.

cache_key(uuid, stem) = string(uuid, '/', stem)

# `paths` is a get_cache_path result: [Initial, Name, uuid, "<stem>.jstore"].
cache_key_from_path(paths::AbstractVector) = cache_key(paths[3], first(splitext(paths[4])))

function parse_availability_index(io::IO)
    keys = Set{String}()
    for line in eachline(io)
        line = strip(line)
        isempty(line) && continue
        push!(keys, String(line))
    end
    return keys
end
parse_availability_index(s::AbstractString) = parse_availability_index(IOBuffer(s))
```

Add to `src/SymbolServer/SymbolServer.jl` (after `using .CacheStore`, line ~17):

```julia
include("availability.jl")
```

- [ ] **Step 4: Run to verify it passes**

Run: `julia --project -e 'import Pkg; Pkg.test("JuliaWorkspaces")'`
Expected: PASS (both new items green; suite otherwise unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/SymbolServer/availability.jl src/SymbolServer/SymbolServer.jl test/test_symbolcache_client.jl
git commit -m "feat(symbolserver): availability-index key + parsing helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: Fetch the availability index (network wrapper) + filter helper

**Files:**
- Modify: `src/SymbolServer/availability.jl`
- Test: `test/test_symbolcache_client.jl`

**Interfaces:**
- Consumes: `parse_availability_index`, `cache_key_from_path` (Task 1); `get_cache_path`, `packageuuid` (existing in the module).
- Produces:
  - `fetch_availability_index(upstream::AbstractString)::Union{Set{String},Nothing}` — fetch+unpack `<upstream>/store/v2/index.tar.gz` (contains `index.txt`); `nothing` on any failure.
  - `keep_available!(to_download, manifest, index::Set{String})` — `filter!` `to_download` (manifest entries) to those whose `cache_key_from_path(get_cache_path(manifest, packageuuid(pkg)))` is in `index`; returns `to_download`.

- [ ] **Step 1: Write the failing test** (filter logic is the unit-testable part; the network fetch is exercised in Phase 3 integration)

Add to `test/test_symbolcache_client.jl`:

```julia
@testitem "SymbolCache client: keep_available! intersects with the index" begin
    using JuliaWorkspaces.SymbolServer: keep_available!, cache_key
    using Base: UUID

    # Minimal manifest stub: keep_available! only needs get_cache_path(manifest, uuid),
    # which uses packagename/frommanifest/version/tree_hash. Use a tiny fake manifest type.
    struct FakeEntry; name::String; tree_hash::String; end
    fakeman = Dict(UUID("11111111-1111-1111-1111-111111111111") => FakeEntry("A", "h1"),
                   UUID("22222222-2222-2222-2222-222222222222") => FakeEntry("B", "h2"))

    # Provide the accessors get_cache_path needs for FakeEntry-based manifests.
    @eval JuliaWorkspaces.SymbolServer begin
        packagename(m::Dict{Base.UUID,Main.var"##FakeEntry"}, u::Base.UUID) = m[u].name
        frommanifest(m::Dict{Base.UUID,Main.var"##FakeEntry"}, u) = m[u]
        version(::Main.var"##FakeEntry") = nothing
        tree_hash(e::Main.var"##FakeEntry") = e.tree_hash
    end

    u1 = UUID("11111111-1111-1111-1111-111111111111")
    u2 = UUID("22222222-2222-2222-2222-222222222222")
    to_download = Any[u1 => fakeman[u1], u2 => fakeman[u2]]
    index = Set([cache_key(string(u1), "h1")])     # only A is available
    keep_available!(to_download, fakeman, index)
    @test length(to_download) == 1
    @test first(to_download)[1] == u1
end
```

> Note: if extending `packagename`/`tree_hash` for a fake type proves brittle across Julia versions, replace the stub with a real two-package `Manifest.toml` written to a tempdir and read via `read_manifest` — assert the same intersection. Keep whichever compiles cleanly.

- [ ] **Step 2: Run to verify it fails**

Run: focused `@run_package_tests filter=ti->occursin("keep_available", ti.name)` (test env) or full `Pkg.test`.
Expected: FAIL — `keep_available!` not defined.

- [ ] **Step 3: Write the implementation**

Append to `src/SymbolServer/availability.jl`:

```julia
function keep_available!(to_download, manifest, index::Set{String})
    filter!(to_download) do pkg
        cache_key_from_path(get_cache_path(manifest, packageuuid(pkg))) in index
    end
    return to_download
end

# Network: fetch <upstream>/store/v2/index.tar.gz (a tarball containing index.txt)
# and parse it. Returns `nothing` on any failure so callers can fall back to the
# legacy per-file attempt. Uses the same unpack path as the cache tarballs, so no
# new dependency is needed.
function fetch_availability_index(upstream::AbstractString)
    url = join([upstream, "store", "v2", "index.tar.gz"], '/')
    try
        return mktempdir() do dir
            Pkg.PlatformEngines.download_verify_unpack(url, nothing, dir) || return nothing
            idx = joinpath(dir, "index.txt")
            isfile(idx) ? open(parse_availability_index, idx) : nothing
        end
    catch err
        @debug "Could not fetch availability index" exception = (err, catch_backtrace())
        return nothing
    end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: full `Pkg.test("JuliaWorkspaces")`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/SymbolServer/availability.jl test/test_symbolcache_client.jl
git commit -m "feat(symbolserver): fetch availability index and filter download set

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3: Wire the index into `download_cache_files`

No artifact-URL change: the client already requests `store/v2/packages/...` and we
host the new design at v2, so this task only adds the index fetch + filtering.

**Files:**
- Modify: `src/SymbolServer/SymbolServer.jl:96-148` (`download_cache_files`)
- (no change to `shared/symbolserver/utils.jl` — the v2 URL already matches)

**Interfaces:**
- Consumes: `fetch_availability_index`, `keep_available!` (Task 2).

> **Testing note:** the filtering logic is already unit-tested via `keep_available!`
> (Task 2). `download_cache_files` itself is network- and manifest-bound, so it has
> no isolated unit test here; its behavior is covered by Task 2's test, by the full
> suite still passing (compile/load), and by the Phase 3 integration smoke test
> (Task 8 Step 4). This task is therefore a wiring change verified by the suite.

- [ ] **Step 1: Make the change**

In `src/SymbolServer/SymbolServer.jl`, inside `download_cache_files`, replace the body of the `for manifest_filename in candidates` loop's download-list construction so it fetches and applies the index (full replacement of lines ~106-145):

```julia
        for manifest_filename in candidates
            !isfile(manifest_filename) && continue

            manifest = read_manifest(manifest_filename)
            manifest === nothing && continue

            @debug "Downloading cache files for manifest at $(manifest_filename)."
            to_download = collect(validate_disc_store(ssi.store_path, manifest))
            try
                remove_non_general_pkgs!(to_download)
            catch err
                @error """
                Symbol cache downloading: Failed to identify which packages to omit based on the General registry.
                All packages will be processsed locally""" err
                empty!(to_download)
            end
            isempty(to_download) && continue

            # Consult the published availability index: fetch it once, then keep
            # only packages known to exist on the server (skipping a 404 per missing
            # package). If the index can't be fetched, fall back to attempting each.
            index = fetch_availability_index(ssi.symbolcache_upstream)
            if index !== nothing
                keep_available!(to_download, manifest, index)
                isempty(to_download) && continue
            else
                @debug "Availability index unavailable; attempting per-package downloads."
            end

            n_done = 0
            n_total = length(to_download)
            progress_callback("Downloading cache files...", 0)
            t0 = time()
            for batch in Iterators.partition(to_download, 100) # 100 connections at a time
                @sync for pkg in batch
                    @async begin
                        yield()
                        uuid = packageuuid(pkg)
                        get_file_from_cloud(manifest, uuid, environment_path, ssi.depot_path, ssi.store_path, download_dir, ssi.symbolcache_upstream)
                        yield()
                        n_done += 1
                        percentage = round(Int, 100*(n_done/n_total))
                        if percentage < 100
                            progress_callback("Downloading cache files...", percentage)
                        end
                    end
                end
            end
            took = round(time() - t0, sigdigits = 2)
            progress_callback("All cache files downloaded (took $(took)s).", 100)
        end
```

- [ ] **Step 2: Run to verify it passes**

Run: full `Pkg.test("JuliaWorkspaces")`.
Expected: PASS (full suite still green; `download_cache_files` compiles with the index wiring).

- [ ] **Step 3: Commit**

```bash
git add src/SymbolServer/SymbolServer.jl
git commit -m "feat(symbolserver): use availability index in download_cache_files

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> **Rollout note (not a code step):** v2 hosting is not yet live, so until Phase 3
> seeds `store/v2/`, `fetch_availability_index` returns `nothing` and per-package
> fetches 404 → the client falls back to local indexing (no crash, no cloud
> benefit). This is the same behavior as today. The index-aware client can be
> merged/tested anytime; the cloud benefit appears once v2 hosting is seeded.

---

## Phase 2 — Server: emit the availability index

### Task 4: `build_index` / `write_index` over a store directory

**Files:**
- Create: `src/CloudIndex/index.jl`
- Modify: `src/CloudIndexApp.jl` (add `include("CloudIndex/index.jl")` alongside the other CloudIndex includes)
- Test: `test/test_cloudindex.jl`

**Interfaces:**
- Produces:
  - `build_index(store_path::AbstractString)::Vector{String}` — sorted, unique `"<uuid>/<stem>"`, one per `.jstore` under `store_path`.
  - `write_index(store_path::AbstractString, out::IO)` — writes those lines.

- [ ] **Step 1: Write the failing test**

Add to `test/test_cloudindex.jl`:

```julia
@testitem "CloudIndex: build_index lists one <uuid>/<stem> per .jstore" begin
    using JuliaWorkspaces.CloudIndexApp: build_index, write_index
    mktempdir() do store
        mk(p) = (mkpath(dirname(p)); write(p, "x"))
        mk(joinpath(store, "E", "Example", "uuid-a", "h1.jstore"))
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h2.jstore"))
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h2.unavailable"))  # tombstone: ignored
        mk(joinpath(store, "C", "Crayons", "uuid-b", "h3.jstore.tmp"))   # not a .jstore: ignored

        idx = build_index(store)
        @test idx == ["uuid-a/h1", "uuid-b/h2"]      # sorted, unique, .jstore only

        io = IOBuffer(); write_index(store, io)
        @test String(take!(io)) == "uuid-a/h1\nuuid-b/h2\n"
    end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: focused `@run_package_tests filter=ti->occursin("build_index", ti.name)` or full `Pkg.test`.
Expected: FAIL — `build_index` not defined.

- [ ] **Step 3: Write the implementation**

Create `src/CloudIndex/index.jl`:

```julia
# Build the availability index from a store: one "<uuid>/<stem>" key per .jstore,
# where the store layout is <store>/<Initial>/<Name>/<uuid>/<stem>.jstore.
function build_index(store_path::AbstractString)
    keys = String[]
    isdir(store_path) || return keys
    for (root, _, files) in walkdir(store_path)
        for f in files
            endswith(f, ".jstore") || continue
            push!(keys, string(basename(root), '/', first(splitext(f))))
        end
    end
    return sort!(unique!(keys))
end

function write_index(store_path::AbstractString, out::IO)
    for k in build_index(store_path)
        println(out, k)
    end
    return nothing
end
```

Add to `src/CloudIndexApp.jl` (with the other `include("CloudIndex/...")` lines):

```julia
include("CloudIndex/index.jl")
```

- [ ] **Step 4: Run to verify it passes**

Run: full `Pkg.test("JuliaWorkspaces")`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/CloudIndex/index.jl src/CloudIndexApp.jl test/test_cloudindex.jl
git commit -m "feat(cloudindex): build availability index from a store

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5: `--emit-index PATH` CLI flag

**Files:**
- Modify: `src/CloudIndex/cli.jl`
- Test: `test/test_cloudindex.jl`

**Interfaces:**
- Consumes: `write_index` (Task 4), the existing CLI arg parser and `--store` option in `cli.jl`.
- Produces: running `cli_main(["--store", S, "--emit-index", P, ...])` writes the index for store `S` to file `P` and returns `0` without launching workers.

- [ ] **Step 1: Read the current CLI structure**

Run: `julia --project -e 'print(read("src/CloudIndex/cli.jl", String))'` and locate (a) where flags are parsed into the options struct, (b) where `--store` is read, (c) the early-return modes (`--dry-run` / `--report-missing`) — the new flag mirrors those.

- [ ] **Step 2: Write the failing test**

Add to `test/test_cloudindex.jl`:

```julia
@testitem "CloudIndex: --emit-index writes the index and exits 0" begin
    using JuliaWorkspaces.CloudIndexApp: cli_main
    mktempdir() do root
        store = joinpath(root, "store")
        mk(p) = (mkpath(dirname(p)); write(p, "x"))
        mk(joinpath(store, "E", "Example", "uuid-a", "h1.jstore"))
        out = joinpath(root, "index.txt")
        rc = cli_main(["--store", store, "--emit-index", out])
        @test rc == 0
        @test read(out, String) == "uuid-a/h1\n"
    end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: focused `@run_package_tests filter=ti->occursin("emit-index", ti.name)` or full `Pkg.test`.
Expected: FAIL — flag unrecognized / no file written.

- [ ] **Step 4: Implement the flag**

In `src/CloudIndex/cli.jl`: add `--emit-index` to the argument parser (string option, default `nothing`), and **before** the worklist/`run_index` path, add an early-return branch (mirroring `--dry-run`):

```julia
    if opts_emit_index !== nothing          # name per the parser's local variable convention
        open(opts_emit_index, "w") do io
            write_index(store, io)           # `store` = the resolved --store path
        end
        return 0
    end
```

(Use the file's existing names for the parsed flag and the store path; match the surrounding style of the other early-return modes.)

- [ ] **Step 5: Run to verify it passes**

Run: full `Pkg.test("JuliaWorkspaces")`.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/CloudIndex/cli.jl test/test_cloudindex.jl
git commit -m "feat(cloudindex): --emit-index flag to write the availability index

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — Hosting & stateless regeneration (R2)

> These tasks are orchestration, not unit-testable code. Each ends with an integration smoke test against a **local rclone remote** (`rclone` with a `local` backend pointed at a temp dir) so the scripts are exercised without touching real R2. Swap the remote name for the real R2 remote in production.

### Task 6: Package the store into per-package `tar.gz` (packaging only)

**Files:**
- Create: `scripts/package_symbolcache.sh`

**Interfaces:**
- Produces: given `STORE` and `OUT`, writes `OUT/store/v2/packages/<I>/<Name>/<uuid>/<stem>.tar.gz` (each a tarball containing the one `<stem>.jstore`). Index generation is the caller's responsibility.
- Packaging only — does not build or emit an index.

- [ ] **Step 1: Write the script**

Create `scripts/package_symbolcache.sh`:

```bash
#!/usr/bin/env bash
# Package a jwcloudindex store into the v2 hosting layout: one tar.gz per .jstore
# under OUT/store/v2/packages/. Packaging only — index generation is done by the
# caller via `jwcloudindex --emit-index` (regen builds a union index; the seed
# builds a full one), so this script does not build or upload an index.
# Usage: package_symbolcache.sh STORE OUT
set -euo pipefail
STORE=${1:?store dir}; STORE=${STORE%/}; OUT=${2:?out dir}
JOBS=$(nproc)
PKGS_OUT="$OUT/store/v2/packages"; mkdir -p "$PKGS_OUT"

# One tar.gz per .jstore (tarball contains just the .jstore, gzip).
export STORE PKGS_OUT
find "$STORE" -name '*.jstore' -print0 | xargs -0 -P"$JOBS" -n1 bash -c '
    set -euo pipefail
    f=$1; rel=${f#"$STORE"/}; dir=$(dirname "$rel"); base=$(basename "$f")
    dest="$PKGS_OUT/$dir"; mkdir -p "$dest"
    tar -czf "$dest/${base%.jstore}.tar.gz" -C "$STORE/$dir" "$base"
' _

echo "packaged $(find "$PKGS_OUT" -name '*.tar.gz' | wc -l) artifacts to $OUT/store/v2/packages"
```

- [ ] **Step 2: Smoke-test it**

```bash
mkdir -p /tmp/pubtest/store/E/Example/uuid-a && echo data > /tmp/pubtest/store/E/Example/uuid-a/h1.jstore
bash scripts/package_symbolcache.sh /tmp/pubtest/store /tmp/pubout
test -f /tmp/pubout/store/v2/packages/E/Example/uuid-a/h1.tar.gz && echo "artifact OK"
```

Expected: `artifact OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/package_symbolcache.sh
git commit -m "feat(cloudindex): packaging script — store to v2 tar.gz layout (packaging only)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 7: Stateless incremental/full regeneration driver

**Files:**
- Create: `scripts/regen_symbolcache.sh`

**Interfaces:**
- Consumes: `scripts/run_cloudindex_docker.sh` (existing sweep), `scripts/package_symbolcache.sh` (Task 6), `rclone` configured with a remote (env `RCLONE_REMOTE`, e.g. `r2:symbolcache` or a local test remote).
- Produces: an end-to-end run that downloads state, computes missing, indexes, uploads artifacts + index + tombstones. Single-flight is the scheduler's responsibility (no bucket lock).

- [ ] **Step 1: Write the script**

Create `scripts/regen_symbolcache.sh`:

```bash
#!/usr/bin/env bash
# Stateless symbol-cache regeneration. State (tombstones) lives in the bucket;
# successes are re-derived from the published index. Two modes: incremental
# (skip successes + tombstones) and full (skip successes only).
# Args: --remote (e.g. r2:symbolcache), --mode incremental|full, --work (scratch).
set -euo pipefail
REMOTE=${RCLONE_REMOTE:?set RCLONE_REMOTE}; MODE=${MODE:-incremental}
WORK=${WORK:-$(mktemp -d)}; PFX="store/v2"; STATE="$PFX/_state"
mkdir -p "$WORK"

# 1. No bucket lock. Single-flight is the scheduler's job (run this under a GitHub
#    Actions `concurrency:` group, or `flock` on a single runner). Concurrent
#    overlap is not a correctness risk — artifacts are immutable/additive, and a
#    lost-update on the index/tombstone lists is self-healed by the periodic full
#    reconcile (worst case: duplicated work + a transiently-stale index). See the
#    spec's "Why no lock".

# 2. Download key-sets (small): index (successes) + tombstones.
: > "$WORK/successes.txt"; : > "$WORK/tombstones.txt"
rclone copyto "$REMOTE/$PFX/index.tar.gz" "$WORK/index.tar.gz" 2>/dev/null && \
    tar -xzOf "$WORK/index.tar.gz" index.txt > "$WORK/successes.txt" || true
rclone copyto "$REMOTE/$STATE/tombstones.txt.gz" "$WORK/tomb.gz" 2>/dev/null && \
    gzip -dc "$WORK/tomb.gz" > "$WORK/tombstones.txt" || true

# 3. Reconstruct a local store skeleton so jwcloudindex's resume sees what's "done":
#    empty marker files for each success (.jstore) and, for incremental, each tombstone (.unavailable).
STORE="$WORK/store"
python3 - "$STORE" "$WORK/successes.txt" "$WORK/tombstones.txt" "$MODE" <<'PY'
import os,sys
store,succ,tomb,mode=sys.argv[1:5]
def touch(uuidstem,ext):
    uuid,stem=uuidstem.split('/',1)
    d=os.path.join(store,"_",uuid)            # initial dir irrelevant for resume's path check? keep real:
    # real layout needs <I>/<Name>/<uuid>/<stem>; resume keys on uuid+stem+name. Use uuid-only marker dir
    os.makedirs(os.path.join(store,uuid),exist_ok=True)
    open(os.path.join(store,uuid,stem+ext),'w').close()
for l in open(succ):
    l=l.strip()
    if l: touch(l,".jstore")
if mode=="incremental":
    for l in open(tomb):
        l=l.strip()
        if l: touch(l,".unavailable")
PY
```

> **Step 1 note — required code change before this works:** the marker-file skeleton above does **not** reproduce the real `<I>/<Name>/<uuid>/<stem>` layout, and the driver's `find_missing`/`is_cached` currently stat that exact path. This task depends on the spec's planned change: teach `find_missing`/`is_cached` (in `src/CloudIndex/cache_state.jl`) to accept a **precomputed done-set** of `"<uuid>/<stem>"` keys instead of scanning the store filesystem. Implement that as Task 7a (TDD, in `cache_state.jl` + `test/test_cloudindex.jl`) before finishing this script; then the script passes the two key-sets directly and skips the marker-file hack.

- [ ] **Step 2: (Task 7a) Add a done-set predicate to the driver** — TDD in `src/CloudIndex/cache_state.jl`:

```julia
# A run's "already done" set, as "<uuid>/<stem>" keys. Successes always count;
# tombstones count only on incremental runs.
done_key(pv) = string(pv.uuid, '/', replace(pv.tree_hash, '+' => '_'))
find_missing(rows, done::AbstractSet) = filter(pv -> !(done_key(pv) in done), rows)
```

Test (`test/test_cloudindex.jl`):

```julia
@testitem "CloudIndex: find_missing(rows, done-set) filters by uuid/treehash key" begin
    using JuliaWorkspaces.CloudIndexApp: PkgVersion, find_missing
    u = Base.UUID("22222222-2222-2222-2222-222222222222")
    rows = [PkgVersion("A", u, v"1.0.0", "h1", false, nothing),
            PkgVersion("B", u, v"1.0.0", "h2", false, nothing)]
    done = Set(["$(u)/h1"])
    left = find_missing(rows, done)
    @test length(left) == 1 && left[1].tree_hash == "h2"
end
```

Wire `run_index`/the CLI to accept a done-set (e.g. `--done-set FILE` reading `"<uuid>/<stem>"` lines) and pass it to `find_missing`. Commit this sub-task on its own.

- [ ] **Step 3: Finish the regen script** (using `--done-set` from Task 7a):

```bash
# 3'. Build the done-set file the CLI consumes (incremental: successes+tombstones; full: successes only).
cat "$WORK/successes.txt" > "$WORK/done.txt"
[ "$MODE" = incremental ] && cat "$WORK/tombstones.txt" >> "$WORK/done.txt"

# 4. Sweep only the missing versions (the docker orchestrator, pointed at a fresh real store).
REAL_STORE="$WORK/realstore"; mkdir -p "$REAL_STORE"
bash "$(dirname "$0")/run_cloudindex_docker.sh" --work "$WORK/sweep" \
    --jobs 70 --newest 3 --per-break --done-set "$WORK/done.txt" --store "$REAL_STORE"

# 5. Merge new tombstones from the run's results.jsonl, rebuild lists.
python3 - "$WORK/sweep/results.jsonl" "$WORK/tombstones.txt" "$MODE" "$WORK/tombstones.new" <<'PY'
import json,sys
results,old,mode,out=sys.argv[1:5]
def key(r): return f"{r['uuid']}/{r['treehash'].replace('+','_')}"
new=set()
for l in open(results):
    r=json.loads(l)
    if r["status"] in ("failed","unsatisfiable","timeout"): new.add(key(r))
if mode=="incremental":
    new |= {l.strip() for l in open(old) if l.strip()}
# drop any that this run actually cached
ok={key(json.loads(l)) for l in open(results) if json.loads(l)["status"]=="ok"}
open(out,"w").write("\n".join(sorted(new-ok))+"\n")
PY

# 6. Publish: package the new artifacts, upload additively, refresh index + tombstones.
bash "$(dirname "$0")/package_symbolcache.sh" "$REAL_STORE" "$WORK/pub"
rclone copy "$WORK/pub/store/v2/packages" "$REMOTE/$PFX/packages" --immutable --transfers=32
rclone copyto "$WORK/pub/store/v2/index.tar.gz" "$REMOTE/$PFX/index.tar.gz"     # short TTL set on the bucket
gzip -c "$WORK/tombstones.new" | rclone rcat "$REMOTE/$STATE/tombstones.txt.gz"
echo "regen ($MODE) done"
```

- [ ] **Step 4: Smoke-test against a local rclone remote**

```bash
mkdir -p /tmp/r2local
rclone --config /dev/null lsf ":local:/tmp/r2local" >/dev/null 2>&1 || true   # ':local:' backend needs no config
# First run (empty remote → everything missing). Use a 1-shard, name-filtered tiny sweep:
bash scripts/regen_symbolcache.sh --remote :local:/tmp/r2local --mode full --work /tmp/regenwork \
  -- --include '^(Example|Crayons)$' --shard 0/1   # args after -- go to the docker sweep for a fast test
test -f /tmp/r2local/store/v2/index.tar.gz && echo "index published"
# Second run (incremental) should index nothing new:
bash scripts/regen_symbolcache.sh --remote :local:/tmp/r2local --mode incremental --work /tmp/regenwork2
```

Expected: first run publishes artifacts + index; second run's `results.jsonl` is empty (nothing missing) and the index is unchanged. Acceptance criterion from the spec: a no-change incremental run does zero indexing work.

- [ ] **Step 5: Commit**

```bash
git add scripts/regen_symbolcache.sh src/CloudIndex/cache_state.jl test/test_cloudindex.jl
git commit -m "feat(cloudindex): stateless R2 regeneration driver (incremental/full)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 8: One-time R2 provisioning + initial upload (runbook, not code)

**Files:** none (operational).

- [ ] **Step 1:** Create the R2 bucket; put a CDN in front; set `Cache-Control: public, max-age=31536000, immutable` on `store/v2/packages/**` and a short TTL (e.g. 300s) on `store/v2/index.tar.gz`.
- [ ] **Step 2:** Configure `rclone` with an `r2:` remote (account id + token).
- [ ] **Step 3:** Seed the bucket from the existing full store (packages + derived index, uploaded with Cache-Control):
  ```bash
  bash scripts/seed_symbolcache.sh --remote r2:symbolcache --store ~/jwci-work/store
  ```
- [ ] **Step 4:** Verify the client end-to-end against the seeded bucket: point a `SymbolServerInstance(symbolcache_upstream="https://<cdn-host>/symbolcache")` at a test project with a couple of General deps, call `getstore(...; download=true)`, and confirm it fetches only indexed packages (watch `@debug`), unpacks, and loads.
- [ ] **Step 5:** Schedule `regen_symbolcache.sh` (GitHub Actions `schedule` or cron): `--mode incremental` daily; `--mode full` monthly or on a Julia-version bump.

---

## Self-Review

**Spec coverage:**
- Client manifest lookup → Tasks 1–3 ✓ (key/parse, fetch/filter, wiring + v2).
- Server index generation → Tasks 4–5 ✓ (`build_index`, `--emit-index`).
- tar.gz artifacts + v2 layout → Tasks 3, 6 ✓.
- R2 hosting + immutable headers → Task 8 ✓.
- Stateless incremental/full regen + tombstones-in-bucket → Task 7 (+7a done-set) ✓.
- Plain tombstones, no fingerprinting → Task 7 merge logic uses `status ∈ {failed,unsatisfiable,timeout}` only ✓.
- Periodic full reconcile → covered operationally by `MODE=full` (Task 7/8); a dedicated LIST-based reconcile is a follow-up if drift appears (noted, not yet a task — **gap**, acceptable for v1 since `full` re-derives correctly).
- Graceful fallback when index missing → Task 3 ✓.

**Placeholder scan:** code steps carry real code; Task 5's flag name and Task 7's done-set wiring reference the file's existing local-variable names (the implementer reads the file in the first step of each) — these are concrete instructions, not deferred work. Task 8 is explicitly a runbook.

**Type consistency:** key form `"<uuid>/<stem>"` is identical across `cache_key`, `cache_key_from_path`, `build_index`, `done_key`, and the regen Python (`treehash.replace('+','_')`). `find_missing` has two methods (rows×store_path existing; rows×done-set new in 7a) — disambiguated by argument type. `get_cache_path` shape `[I,Name,uuid,"<stem>.jstore"]` is used consistently.

---

**Known follow-ups (out of scope here):** signature-size cap in the extractor for the multi-hundred-MB outliers; a dedicated LIST-based reconcile job; optional `latest`-pointer indirection if the short-TTL index proves insufficient for CDN hit-rate.
