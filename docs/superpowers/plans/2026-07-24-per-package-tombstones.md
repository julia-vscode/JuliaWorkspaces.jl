# Per-package symbol-cache tombstones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record, per package version, that local symbol-cache indexing was attempted and produced no `.jstore`, so the language server stops re-launching a DJP for permanently-uncacheable pins — while still retrying when the indexer code changes, Julia changes, a cloud cache appears, or a staleness window elapses.

**Architecture:** A `.tombstone` file sits beside the `.jstore` it shadows (same path, swapped extension). The DJP child (`get_store`) writes one for any non-deved package it tried to cache but couldn't, and skips packages that already carry a current tombstone. The parent language server (`_get_missing_packages` launch gate) drops still-missing packages that carry a current tombstone, so their env fast-lanes with no child. Shared read/write/currency helpers live in `shared/symbolserver/` and are used identically by both processes — no protocol passing.

**Tech Stack:** Julia; `Pkg.TOML` for tombstone read/write; TestItemRunner `@testitem` tests; DJP subprocess integration tests modeled on `test/test_symbolserver.jl`.

## Global Constraints

- Tombstone lives at the `.jstore` path with the extension swapped to `.tombstone` (`replace(cache_path, r"\.jstore$" => ".tombstone")`). The `.jstore` check ALWAYS precedes the tombstone check so a real cache wins.
- "Current" (skip/drop) requires ALL of: `indexer_version == INDEXER_VERSION`, `julia_version == string(VERSION)`, and `time() - timestamp < TOMBSTONE_TTL_SECONDS`. Any miss (or a missing/malformed tombstone) → retry.
- `INDEXER_VERSION` starts at `1`; `TOMBSTONE_TTL_SECONDS = 7 * 24 * 60 * 60` (7 days).
- Tombstone TOML fields: `indexer_version` (int), `julia_version` (string), `timestamp` (int, unix seconds).
- Deved (path-dep) packages are NEVER tombstoned and NEVER skipped-by-tombstone — the parent already skips them (they are handled by StaticLint) and never reads their `.jstore`. Tombstone *deletion* is unconditional (harmless no-op for deved).
- Shared helpers go in `shared/symbolserver/utils.jl` (module `SymbolServer`), reachable as `SymbolServer.<name>` from both `src/` and the DJP child. Writes use `Pkg.TOML.print` (both `SymbolServer` modules already `using Pkg`); reads use the existing `parsed_toml` helper.
- New tests go in `test/test_tombstones.jl`; TestItemRunner auto-discovers `@testitem`s (no registration needed). All `@testitem` names are prefixed `Tombstones:` so they can be run with `filter="Tombstones"`.
- Comments: terse, no references to this plan or the spec.

**Running tests:** via julia-mcp, `env_path` = `/home/pfitzseb/git/julia-vscode/scripts/environments/development`, `run_tests("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces"; filter="<substr>")`. The child integration tests spawn a Julia subprocess and precompile — allow a generous timeout (300s+).

---

### Task 1: Shared tombstone helpers + version constants

**Files:**
- Modify: `shared/symbolserver/utils.jl` (add constants after line 11; add helpers after the `parsed_toml` block, line 23)
- Test: `test/test_tombstones.jl` (create)

**Interfaces:**
- Consumes: existing `parsed_toml(file)` and `using Pkg` (both already in `utils.jl`).
- Produces (all in module `SymbolServer`):
  - `const INDEXER_VERSION::Int = 1`
  - `const TOMBSTONE_TTL_SECONDS::Int = 604800`
  - `tombstone_path(cache_path::AbstractString) -> String`
  - `read_tombstone(path::AbstractString) -> Union{Nothing, @NamedTuple{indexer_version::Int, julia_version::String, timestamp::Int}}`
  - `tombstone_is_current(t) -> Bool` (accepts the `read_tombstone` result or `nothing`)
  - `write_tombstone(path::AbstractString) -> String` (atomic; stamps current versions; `mkpath`s parent)
  - `delete_tombstone(path::AbstractString) -> Nothing` (no-op if absent)

- [ ] **Step 1: Write the failing tests**

Create `test/test_tombstones.jl` with:

```julia
@testitem "Tombstones: path swap, round-trip, currency" begin
    using JuliaWorkspaces.SymbolServer: tombstone_path, read_tombstone,
        tombstone_is_current, write_tombstone, delete_tombstone, INDEXER_VERSION

    cp = joinpath("store", "F", "Foo", "uuid", "abcdef.jstore")
    @test tombstone_path(cp) == joinpath("store", "F", "Foo", "uuid", "abcdef.tombstone")
    # only the trailing extension is swapped
    @test tombstone_path(joinpath("a", "b.jstore.jstore")) == joinpath("a", "b.jstore.tombstone")

    mktempdir() do d
        p = joinpath(d, "sub", "x.tombstone")   # nested dir: write must mkpath
        @test read_tombstone(p) === nothing      # absent → nothing

        @test write_tombstone(p) == p
        t = read_tombstone(p)
        @test t !== nothing
        @test t.indexer_version == INDEXER_VERSION
        @test t.julia_version == string(VERSION)
        @test tombstone_is_current(t)                       # fresh + matching
        @test tombstone_is_current(read_tombstone(p))

        write(p, "this is not = valid = toml = [[")         # malformed → nothing
        @test read_tombstone(p) === nothing

        delete_tombstone(p)
        @test !isfile(p)
        delete_tombstone(p)                                  # idempotent on absent
    end
end

@testitem "Tombstones: mismatch and staleness are not current" begin
    using JuliaWorkspaces.SymbolServer: tombstone_is_current, INDEXER_VERSION,
        TOMBSTONE_TTL_SECONDS

    now = round(Int, time())
    @test !tombstone_is_current(nothing)
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION + 1, julia_version=string(VERSION), timestamp=now))
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version="0.0.0", timestamp=now))
    @test !tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version=string(VERSION), timestamp=now - TOMBSTONE_TTL_SECONDS - 1))
    @test  tombstone_is_current((indexer_version=INDEXER_VERSION, julia_version=string(VERSION), timestamp=now))
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run via julia-mcp: `run_tests(".../JuliaWorkspaces"; filter="Tombstones")`
Expected: FAIL — `UndefVarError: tombstone_path not defined` (helpers don't exist yet).

- [ ] **Step 3: Add the constants**

In `shared/symbolserver/utils.jl`, immediately after line 11 (`const CACHE_STORE_VERSION = "v$(CACHE_FORMAT_VERSION)"`), insert:

```julia

# Bump when caching/indexing logic changes: invalidates all existing tombstones
# (they become version-mismatched and are retried). Read identically by the
# language server and the DJP child — no protocol passing.
const INDEXER_VERSION = 1
# A tombstone older than this is retried even if versions still match, so a
# genuinely-transient failure self-heals without an INDEXER_VERSION bump.
const TOMBSTONE_TTL_SECONDS = 7 * 24 * 60 * 60
```

- [ ] **Step 4: Add the helpers**

In `shared/symbolserver/utils.jl`, immediately after the `parsed_toml` block (the `@static if isdefined(Base, :parsed_toml) ... end`, ending at line 23), insert:

```julia

# ─── Per-package cache tombstones ────────────────────────────────────────────
# A `.tombstone` sits beside the `.jstore` it would shadow and records that local
# caching was attempted for that exact package version and produced nothing. The
# `.jstore` check always precedes the tombstone check, so a real cache wins.

tombstone_path(cache_path::AbstractString) = replace(cache_path, r"\.jstore$" => ".tombstone")

function read_tombstone(path::AbstractString)
    isfile(path) || return nothing
    data = try
        parsed_toml(path)
    catch
        return nothing
    end
    iv = get(data, "indexer_version", nothing)
    jv = get(data, "julia_version", nothing)
    ts = get(data, "timestamp", nothing)
    (iv isa Integer && jv isa AbstractString && ts isa Integer) || return nothing
    return (indexer_version=Int(iv), julia_version=String(jv), timestamp=Int(ts))
end

function tombstone_is_current(t)
    t === nothing && return false
    t.indexer_version == INDEXER_VERSION || return false
    t.julia_version == string(VERSION) || return false
    (time() - t.timestamp) < TOMBSTONE_TTL_SECONDS || return false
    return true
end

function write_tombstone(path::AbstractString)
    mkpath(dirname(path))
    data = Dict{String,Any}(
        "indexer_version" => INDEXER_VERSION,
        "julia_version" => string(VERSION),
        "timestamp" => round(Int, time()),
    )
    tmp, io = mktemp(dirname(path))
    try
        Pkg.TOML.print(io, data)
        close(io)
        mv(tmp, path; force=true)
    catch
        close(io)
        rm(tmp; force=true)
        rethrow()
    end
    return path
end

delete_tombstone(path::AbstractString) = (isfile(path) && rm(path; force=true); nothing)
```

- [ ] **Step 5: Run tests to verify they pass**

Run via julia-mcp: `run_tests(".../JuliaWorkspaces"; filter="Tombstones")`
Expected: PASS — both `@testitem`s green. (Restart the mcp session first if `utils.jl` was already loaded, since these are module-level defs.)

- [ ] **Step 6: Commit**

```bash
git add shared/symbolserver/utils.jl test/test_tombstones.jl
git commit -m "$(cat <<'EOF'
feat(symbolcache): shared per-package tombstone helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Child (`get_store`) — skip, guarded load, outcome record

**Files:**
- Modify: `juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/symbolserver.jl` (missing-check loop ~line 84; load loop ~line 110; after `write_depot` ~line 146)
- Test: `test/test_tombstones.jl` (append)

**Interfaces:**
- Consumes (from Task 1, same `SymbolServer` module): `tombstone_path`, `read_tombstone`, `tombstone_is_current`, `write_tombstone`, `delete_tombstone`, `INDEXER_VERSION`.
- Consumes (existing in child scope): `get_cache_path`, `manifest`, `is_package_deved`, `load_package`, `server.storedir`, `packages_to_load`, per-package `cache_path` and `uuid`.
- Produces: no new public API — behavior only. A `.tombstone` appears beside a non-deved package's would-be `.jstore` when a caching attempt yields nothing; it is deleted when the cache appears; a current tombstone makes the child skip re-attempting the package.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tombstones.jl`:

```julia
@testitem "Tombstones: child writes, skips, and retries an uncacheable package" begin
    using JuliaWorkspaces.SymbolServer: read_tombstone, tombstone_is_current, INDEXER_VERSION

    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))
    @test isfile(symbolserver_jl)

    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    tree = "abcdef0123456789abcdef0123456789abcdef01"

    function run_get_store(proj, store)
        runner = tempname() * ".jl"
        write(runner, """
        include(raw"$symbolserver_jl")
        using Pkg
        Pkg.activate(raw"$proj"; io=devnull)
        SymbolServer.get_store(raw"$store", nothing)
        """)
        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        out = IOBuffer()
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(pipeline(ignorestatus(`$jl --startup-file=no --project=$proj $runner`), stdout=out, stderr=out))
        end
        (exitcode=proc.exitcode, log=String(take!(out)))
    end

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        write(joinpath(proj, "Project.toml"), "[deps]\nFakeRegPkg = \"$uuid\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.FakeRegPkg]]
        git-tree-sha1 = "$tree"
        uuid = "$uuid"
        version = "1.2.3"
        """)

        jstore = joinpath(store, "F", "FakeRegPkg", uuid, "$tree.jstore")
        tomb   = joinpath(store, "F", "FakeRegPkg", uuid, "$tree.tombstone")

        # First run: the package can't load → no jstore, a current tombstone appears.
        r1 = run_get_store(proj, store)
        @test r1.exitcode == 0
        @test !isfile(jstore)
        @test isfile(tomb)
        @test tombstone_is_current(read_tombstone(tomb))

        # Second run: the current tombstone makes the child skip the package.
        r2 = run_get_store(proj, store)
        @test r2.exitcode == 0
        @test occursin("tombstoned as uncacheable, skipping", r2.log)
        @test isfile(tomb)
        @test !isfile(jstore)

        # A version-mismatched tombstone is retried (re-attempted) and re-stamped.
        write(tomb, "indexer_version = 999\njulia_version = \"$(VERSION)\"\ntimestamp = $(round(Int, time()))\n")
        r3 = run_get_store(proj, store)
        @test r3.exitcode == 0
        @test occursin("Will cache package", r3.log)
        @test read_tombstone(tomb).indexer_version == INDEXER_VERSION
    end
end

@testitem "Tombstones: child clears a stale tombstone when a package caches" begin
    b_uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    mktempdir() do root
        proj = joinpath(root, "proj"); bdir = joinpath(root, "B"); store = joinpath(root, "store")
        mkpath(joinpath(bdir, "src")); mkpath(proj); mkpath(store)
        write(joinpath(bdir, "Project.toml"), "name = \"B\"\nuuid = \"$b_uuid\"\nversion = \"0.1.0\"\n")
        write(joinpath(bdir, "src", "B.jl"), "module B\nf(x) = x\nend\n")
        write(joinpath(proj, "Project.toml"), "[deps]\nB = \"$b_uuid\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.B]]
        path = "../B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)

        cache_dir = joinpath(store, "B", "B", b_uuid); mkpath(cache_dir)
        jstore = joinpath(cache_dir, "0.1.0.jstore")
        tomb   = joinpath(cache_dir, "0.1.0.tombstone")
        write(tomb, "indexer_version = 1\njulia_version = \"stale\"\ntimestamp = 1\n")  # pre-seed
        @test isfile(tomb)

        runner = joinpath(root, "run.jl")
        write(runner, """
        include(raw"$symbolserver_jl")
        using Pkg
        Pkg.activate(raw"$proj"; io=devnull)
        SymbolServer.get_store(raw"$store", nothing)
        """)
        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(ignorestatus(`$jl --startup-file=no --project=$proj $runner`))
        end
        @test proc.exitcode == 0
        @test isfile(jstore)     # deved B cached successfully
        @test !isfile(tomb)      # its stale tombstone was cleared
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run via julia-mcp (timeout 300+): `run_tests(".../JuliaWorkspaces"; filter="Tombstones: child")`
Expected: FAIL — first item: `tomb` never appears (no write path yet); it will `!isfile(tomb)`.

- [ ] **Step 3: Add the tombstone skip to the missing-check loop**

In `juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/symbolserver.jl`, replace the trailing `else` branch of the missing-check loop (lines 84-87):

```julia
        else
            @info "Will cache package $pk_name ($uuid)"
            push!(packages_to_load, uuid)
        end
```

with:

```julia
        elseif !is_package_deved(manifest(ctx), uuid) &&
               tombstone_is_current(read_tombstone(tombstone_path(cache_path)))
            @info "Package $pk_name ($uuid) tombstoned as uncacheable, skipping."
        else
            @info "Will cache package $pk_name ($uuid)"
            push!(packages_to_load, uuid)
        end
```

- [ ] **Step 4: Guard the load attempt**

In the same file, replace the load body inside the `for (i, uuid) in enumerate(packages_to_load)` loop (lines 109-111):

```julia
        t_load = time()
        load_package(ctx, uuid, nothing, loading_bay)
        @info "Loaded package $pe_name in $(round(time() - t_load, digits=1)) seconds."
```

with:

```julia
        t_load = time()
        try
            load_package(ctx, uuid, nothing, loading_bay)
            @info "Loaded package $pe_name in $(round(time() - t_load, digits=1)) seconds."
        catch err
            @warn "Failed to load package $pe_name; it will be tombstoned if it produces no cache." exception=(err, catch_backtrace())
        end
```

- [ ] **Step 5: Add the outcome record after `write_depot`**

In the same file, immediately after the `write_depot(server, server.context, written_caches)` call (line 146) and before the final `@info "Symbol server indexing took ..."` (line 148), insert:

```julia

    # Record the outcome for every package this run tried to cache: clear a stale
    # tombstone when a cache now exists, write one when a non-deved package
    # produced none, so the launch gate stops re-attempting it.
    for uuid in packages_to_load
        cache_path = joinpath(server.storedir, SymbolServer.get_cache_path(manifest(ctx), uuid)...)
        tomb = SymbolServer.tombstone_path(cache_path)
        if isfile(cache_path)
            SymbolServer.delete_tombstone(tomb)
        elseif !is_package_deved(manifest(ctx), uuid)
            SymbolServer.write_tombstone(tomb)
        end
    end
```

- [ ] **Step 6: Run tests to verify they pass**

Run via julia-mcp (timeout 400+): `run_tests(".../JuliaWorkspaces"; filter="Tombstones: child")`
Expected: PASS — both child `@testitem`s green.

- [ ] **Step 7: Commit**

```bash
git add juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/symbolserver.jl test/test_tombstones.jl
git commit -m "$(cat <<'EOF'
feat(dynamic): tombstone uncacheable packages in the indexer child

Skip packages with a current tombstone, guard each load so one failure
doesn't abort the run, and after writing caches record the outcome:
delete a tombstone when a cache exists, write one when a non-deved
package produced none.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Parent launch gate — drop tombstoned packages; delete on download

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (add `_jstore_path` + `_drop_tombstoned` near `MissingPackage`, ~line 480; delete-on-download in `_download_single_cache`, ~line 618; wire into `WatchEnvironmentMsg` handler ~line 862 and `CreateStandaloneProjectMsg` handler ~line 968)
- Test: `test/test_tombstones.jl` (append)

**Interfaces:**
- Consumes (from Task 1): `SymbolServer.tombstone_path`, `SymbolServer.read_tombstone`, `SymbolServer.tombstone_is_current`, `SymbolServer.delete_tombstone`.
- Consumes (existing): `MissingPackage` (`@NamedTuple{name::String, uuid::UUID, version::String, git_tree_sha1::Union{String,Nothing}}`), `_get_missing_packages`, `_download_single_cache`, `_download_missing_caches`, `df.store_path`, `df.download_enabled`.
- Produces:
  - `_jstore_path(pkg::MissingPackage, store_path::String) -> String`
  - `_drop_tombstoned(pkgs::Vector{MissingPackage}, store_path::String) -> Vector{MissingPackage}`
  - Behavior: `EnvironmentPrepDoneMsg.still_missing` and the standalone `fast_lane` are false once every still-missing package carries a current tombstone; a successful download clears the sibling tombstone.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tombstones.jl`:

```julia
@testitem "Tombstones: parent classifier drops current-tombstoned packages" begin
    using JuliaWorkspaces: _get_missing_packages, _drop_tombstoned
    using JuliaWorkspaces.SymbolServer: tombstone_path, write_tombstone

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        reg_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        dev_uuid = "cccccccc-dddd-eeee-ffff-000000000000"
        tree = "abcdef0123456789abcdef0123456789abcdef01"
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.RegPkg]]
        git-tree-sha1 = "$tree"
        uuid = "$reg_uuid"
        version = "1.2.3"

        [[deps.DevPkg]]
        path = "../DevPkg"
        uuid = "$dev_uuid"
        version = "0.1.0"
        """)

        missing = _get_missing_packages(proj, store)
        @test any(p -> p.name == "RegPkg", missing)   # regular, no jstore → missing
        @test !any(p -> p.name == "DevPkg", missing)  # deved → skipped entirely

        # No tombstone yet: RegPkg still needs caching.
        @test any(p -> p.name == "RegPkg", _drop_tombstoned(missing, store))

        # Current tombstone for RegPkg → dropped (env can fast-lane, no DJP).
        cp = joinpath(store, "R", "RegPkg", reg_uuid, "$tree.jstore")
        write_tombstone(tombstone_path(cp))
        @test isempty(_drop_tombstoned(missing, store))

        # A version-mismatched tombstone does NOT drop it (retry).
        write(tombstone_path(cp), "indexer_version = 999\njulia_version = \"$(VERSION)\"\ntimestamp = $(round(Int, time()))\n")
        @test any(p -> p.name == "RegPkg", _drop_tombstoned(missing, store))
    end
end

@testitem "Tombstones: successful download clears the sibling tombstone" begin
    using JuliaWorkspaces: _download_single_cache, MissingPackage
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef, CacheStore,
        CACHE_STORE_VERSION, tombstone_path, write_tombstone

    # `return` does not skip a @testitem body (module-scope eval); gate with if.
    if !Sys.iswindows()   # file:// download pattern is exercised on POSIX
        mktempdir() do root
            store = joinpath(root, "store"); mkpath(store)
            up = joinpath(root, "upstream")
            name = "DownPkg"; uuid = "dddddddd-eeee-ffff-0000-111111111111"
            tree = "0123456789abcdef0123456789abcdef01234567"

            pkg = Package(name, ModuleStore(VarRef(nothing, Symbol(name)), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[]), Base.UUID(uuid), nothing)
            srcdir = joinpath(root, "src_$tree"); mkpath(srcdir)
            jname = "$tree.jstore"
            open(io -> CacheStore.write(io, pkg), joinpath(srcdir, jname), "w")
            updir = joinpath(up, "store", CACHE_STORE_VERSION, "packages", "D", name, uuid); mkpath(updir)
            run(`tar -czf $(joinpath(updir, "$tree.tar.gz")) -C $srcdir $jname`)

            dest = joinpath(store, "D", name, uuid, "$tree.jstore")
            tomb = tombstone_path(dest)
            mkpath(dirname(dest)); write_tombstone(tomb)
            @test isfile(tomb)

            mp = MissingPackage((name, Base.UUID(uuid), "1.0.0", tree))
            @test _download_single_cache(mp, store, "file://" * up, mktempdir())
            @test isfile(dest)     # downloaded
            @test !isfile(tomb)    # tombstone cleared
        end
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run via julia-mcp: `run_tests(".../JuliaWorkspaces"; filter="Tombstones: parent")` then `filter="Tombstones: successful download"`
Expected: FAIL — `UndefVarError: _drop_tombstoned not defined`; and the download item's `!isfile(tomb)` fails (nothing deletes it yet).

- [ ] **Step 3: Add the parent helpers**

In `src/dynamic_feature/dynamic_feature.jl`, immediately after the `_get_missing_packages` function (ends at line 549), insert:

```julia

# Store-relative `.jstore` path for a missing package, matching the layout
# `_get_missing_packages` and `_download_single_cache` build inline.
function _jstore_path(pkg::MissingPackage, store_path::String)
    filename = replace(string(something(pkg.git_tree_sha1, pkg.version)), '+'=>'_')
    joinpath(store_path, uppercase(pkg.name[1:1]), pkg.name, string(pkg.uuid), string(filename, ".jstore"))
end

# Drop packages whose sibling tombstone says local caching was already tried and
# failed for this exact version under the current indexer/Julia and hasn't
# expired. A missing/mismatched/expired tombstone keeps the package (retry).
function _drop_tombstoned(pkgs::Vector{MissingPackage}, store_path::String)
    filter(pkgs) do pkg
        tomb = SymbolServer.tombstone_path(_jstore_path(pkg, store_path))
        !SymbolServer.tombstone_is_current(SymbolServer.read_tombstone(tomb))
    end
end
```

- [ ] **Step 4: Delete the tombstone on a successful download**

In `_download_single_cache`, after the success `@info` (line 618) and before `return true` (line 619), insert the delete so a freshly-downloaded cache clears any stale sibling tombstone:

```julia
        @info "Successfully downloaded cache" name=name version=version
        SymbolServer.delete_tombstone(SymbolServer.tombstone_path(dest_filepath))
        return true
```

- [ ] **Step 5: Wire the filter into the WatchEnvironment prep task**

In `handle!(df::DynamicFeature, msg::WatchEnvironmentMsg)`, replace the post-download line (line 862):

```julia
        put!(df.in_channel, EnvironmentPrepDoneMsg(key, !isempty(missing_pkgs)))
```

with:

```julia
        # A package we can neither cache nor download is dropped if it carries a
        # current tombstone, so a permanently-uncacheable pin stops re-launching a DJP.
        missing_pkgs = _drop_tombstoned(missing_pkgs, df.store_path)
        put!(df.in_channel, EnvironmentPrepDoneMsg(key, !isempty(missing_pkgs)))
```

- [ ] **Step 6: Wire the filter into the standalone prep task**

In `handle!(df::DynamicFeature, msg::CreateStandaloneProjectMsg)`, replace the fast-lane line (line 968):

```julia
        fast_lane = usable && isempty(_get_missing_packages(dir, store_path))
```

with:

```julia
        fast_lane = usable && isempty(_drop_tombstoned(_get_missing_packages(dir, store_path), store_path))
```

- [ ] **Step 7: Run tests to verify they pass**

Run via julia-mcp: `run_tests(".../JuliaWorkspaces"; filter="Tombstones")`
Expected: PASS — all Tombstones `@testitem`s green (restart the mcp session first so the edited `src/` reloads).

- [ ] **Step 8: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_tombstones.jl
git commit -m "$(cat <<'EOF'
feat(dynamic): drop tombstoned packages in the launch gate

_get_missing_packages results are filtered through _drop_tombstoned in
the watch-env and standalone prep tasks, so an env whose only-missing
packages all carry a current tombstone fast-lanes with no DJP. A
successful cloud download clears the sibling tombstone.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage**

- §1 Indexer-code version constant → Task 1 Step 3 (`INDEXER_VERSION`). Staleness (added during review) → Task 1 Steps 3-4 (`TOMBSTONE_TTL_SECONDS`, checked in `tombstone_is_current`).
- §2 Tombstone file co-located, extension swap, TOML content, shared helpers → Task 1 Steps 3-4; helper names match the spec's list (`tombstone_path`, `read_tombstone`, `tombstone_is_current`, `write_tombstone`, `delete_tombstone`).
- §3 Classification pipeline (cached → download → skip-tombstoned → attempt):
  - §3a parent launch gate → Task 3 Steps 3, 5, 6 (`_drop_tombstoned` after download; standalone gate). Download-deletes-tombstone → Task 3 Step 4. Works with `symbolcache_download` off because the filter runs regardless of the (skipped) download branch.
  - §3b child skip → Task 2 Step 3.
- §4 Attempt + record (try/catch per load; outcome check delete/write) → Task 2 Steps 4-5.
- §5 Lifecycle (written by child, deleted on cache/download, superseded on version/TTL change) → covered across Tasks 1-3.
- §6 Testing (shared pure helpers; parent classifier incl. deved-skip + mismatch + download-delete; child write/skip/retry/delete) → Task 1 tests, Task 3 tests, Task 2 tests respectively.
- Deviation from spec, resolved during review: the child tombstones/skips ONLY non-deved packages (the parent never reads a deved `.jstore` and its gate already skips deved, so a deved tombstone can neither help nor be seen; excluding them preserves the deved retry-on-edit path). Documented in Global Constraints.

**Placeholder scan:** none — every code step carries complete code; every run step names the command and expected result.

**Type consistency:** `MissingPackage` fields (`name`, `uuid`, `version`, `git_tree_sha1`) used consistently in `_jstore_path`/`_drop_tombstoned`/tests. `read_tombstone` returns the `(indexer_version::Int, julia_version::String, timestamp::Int)` NamedTuple consumed by `tombstone_is_current` in both processes. `tombstone_path` takes/returns `String` at every call site (parent `_jstore_path` result, child `cache_path`, `_download_single_cache` `dest_filepath`).
