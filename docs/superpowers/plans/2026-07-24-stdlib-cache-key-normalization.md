# Stdlib symbol-cache key normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the parent language server key a stdlib package's `.jstore` cache the same way the DJP child's live `Pkg.Types.Context()` resolution does, so a stdlib recorded in a manifest with a stale registered identity (a `git-tree-sha1` or a stale bare version) is looked up — and loaded — at the key the child actually wrote, ending the per-start relaunch loop and making its symbols resolve.

**Architecture:** A now-stdlib package (e.g. `TOML`) pinned in the manifest with a `git-tree-sha1` is cached by the child under its bundled stdlib version (`1.0.3`), but the parent keys it by the tree-sha and never finds it. The parent runs the same Julia binary as the child, so it can compute the child's key locally via `Pkg.Types.stdlib_infos()`. We add one shared helper and apply it at the parent's two independent manifest classifiers; the cache-load path and the child need no change.

**Tech Stack:** Julia; `Pkg.Types.is_stdlib` / `stdlib_infos` (guarded `Pkg.Types` internals); TestItemRunner `@testitem` tests.

## Global Constraints

- Normalization rule: for a **non-deved** manifest entry that has a `version` (the condition under which the parent forms a cache key at all), if `is_stdlib(uuid)`, key by `something(stdlib_infos()[uuid].version, VERSION)` and set `git_tree_sha1 = nothing`.
- Gated on the entry having a `version`, NOT on whether a stdlib version exists: `stdlib_infos()` returns a concrete version even for versionless-in-manifest stdlibs (`Dates`/`Printf`/`Unicode` → `v"1.11.0"`). Versionless entries carry no `version`, form no key, and stay skipped — unchanged.
- `something(stdlib_infos()[uuid].version, VERSION)` mirrors `get_cache_path` exactly (bundled version, else running `VERSION`).
- `is_stdlib` / `stdlib_infos` are unexported `Pkg.Types`; access only through `isdefined(Pkg.Types, :is_stdlib)` / `isdefined(Pkg.Types, :stdlib_infos)` guards, exactly as `get_cache_path` does. Return `nothing` (→ no normalization) if unavailable.
- Non-stdlib packages, deved packages, and versionless stdlibs are untouched. No change to the child (`get_store`) or the on-disk cache layout.
- Comments terse; no references to this plan or the spec.

**Running tests:** via julia-mcp, `env_path` = `/home/pfitzseb/git/julia-vscode/scripts/environments/development`; restart the session after editing any JuliaWorkspaces source so it recompiles, then `withenv("JW_TEST_FILTER" => "<substr>") do include(".../JuliaWorkspaces/test/runtests.jl") end` (timeout 300+; the first run after a restart precompiles ~20s).

---

### Task 1: Shared `_stdlib_cache_version` helper

**Files:**
- Modify: `src/utils.jl` (append)
- Test: `test/test_stdlib_cache_key.jl` (create)

**Interfaces:**
- Produces: `_stdlib_cache_version(uuid::UUID) -> Union{Nothing, VersionNumber}` — the bundled stdlib version a stdlib UUID's cache is keyed by (`something(stdlib_infos version, VERSION)`), or `nothing` when the UUID is not a stdlib (or `Pkg.Types` lacks the internals). Consumed by Tasks 2 and 3.

- [ ] **Step 1: Write the failing test**

Create `test/test_stdlib_cache_key.jl`:

```julia
@testitem "Stdlib key: _stdlib_cache_version maps stdlibs to the bundled version" begin
    using JuliaWorkspaces: _stdlib_cache_version
    import Pkg
    using UUIDs: UUID

    toml  = UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")   # stdlib (was registered pre-1.6)
    prefs = UUID("21216c6a-2e73-6563-6e65-726566657250")   # registered package, not a stdlib

    infos = Pkg.Types.stdlib_infos()
    @test _stdlib_cache_version(toml) isa VersionNumber
    @test _stdlib_cache_version(toml) == something(infos[toml].version, VERSION)  # matches the child's key
    @test _stdlib_cache_version(prefs) === nothing                                 # non-stdlib → no normalization
end
```

- [ ] **Step 2: Run test to verify it fails**

Restart the dev-env mcp session, then run: `JW_TEST_FILTER="Stdlib key: _stdlib_cache_version"`
Expected: FAIL — `UndefVarError: _stdlib_cache_version`.

- [ ] **Step 3: Add the helper**

In `src/utils.jl`, append after `safe_getproperty`:

```julia

# Cache of `Pkg.Types.stdlib_infos()` (it rebuilds a dict per call); a benign race
# between the reactor prep task and the Salsa loop just recomputes the same table.
const _STDLIB_INFOS_CACHE = Ref{Any}(nothing)

# The version a stdlib UUID's `.jstore` is keyed by — matching the indexer child,
# whose live `Pkg.Types.Context()` resolves any stdlib to its bundled identity
# regardless of what the manifest pins. `nothing` when `uuid` is not a stdlib (or
# the `Pkg.Types` internals are unavailable), so callers fall through to the
# manifest's own key. Callers must gate on the entry having a `version` — a
# versionless-in-manifest stdlib still gets a concrete version here.
function _stdlib_cache_version(uuid::UUID)
    (isdefined(Pkg.Types, :is_stdlib) && isdefined(Pkg.Types, :stdlib_infos)) || return nothing
    Pkg.Types.is_stdlib(uuid) || return nothing
    infos = _STDLIB_INFOS_CACHE[]
    if infos === nothing
        infos = Pkg.Types.stdlib_infos()
        _STDLIB_INFOS_CACHE[] = infos
    end
    info = get(infos, uuid, nothing)
    info === nothing && return VERSION
    return something(info.version, VERSION)
end
```

(`Pkg` is `import`ed later in `packagedef.jl` than `utils.jl` is included, but the body only touches `Pkg` at call time, so this is fine. `UUID` and `VERSION` are already in scope.)

- [ ] **Step 4: Run test to verify it passes**

Restart the dev-env mcp session (recompiles JuliaWorkspaces), then run: `JW_TEST_FILTER="Stdlib key: _stdlib_cache_version"`
Expected: PASS (3 assertions).

- [ ] **Step 5: Commit**

```bash
git add src/utils.jl test/test_stdlib_cache_key.jl
git commit -m "$(cat <<'EOF'
feat(cache): helper mapping a stdlib UUID to its bundled cache-key version

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Normalize the launch gate (`_get_missing_packages`)

**Files:**
- Modify: `src/dynamic_feature/dynamic_feature.jl` (the `for (k_entry, v_entry) in pairs(manifest_deps)` loop in `_get_missing_packages`, ~lines 513-546)
- Test: `test/test_stdlib_cache_key.jl` (append)

**Interfaces:**
- Consumes: `_stdlib_cache_version` (Task 1); existing `MissingPackage = @NamedTuple{name::String, uuid::UUID, version::String, git_tree_sha1::Union{String,Nothing}}`.
- Produces: for a stdlib entry with a version, a `MissingPackage` keyed by the bundled version with `git_tree_sha1 = nothing` — so the launch gate (and `_drop_tombstoned`/`_jstore_path`) look it up at the same key the child wrote.

- [ ] **Step 1: Write the failing test**

Append to `test/test_stdlib_cache_key.jl`:

```julia
@testitem "Stdlib key: _get_missing_packages keys a tree-sha'd stdlib by the bundled version" begin
    using JuliaWorkspaces: _get_missing_packages, _stdlib_cache_version
    using UUIDs: UUID

    toml  = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    dates = "ade2ca70-3891-5945-98fb-dc099432e06a"     # versionless stdlib in the manifest
    sv = _stdlib_cache_version(UUID(toml))              # bundled TOML version, e.g. v"1.0.3"

    mktempdir() do root
        proj = joinpath(root, "proj"); store = joinpath(root, "store")
        mkpath(proj); mkpath(store)
        # v1 manifest: TOML recorded as a registered package (git-tree-sha1);
        # Dates recorded versionless.
        write(joinpath(proj, "Manifest.toml"), """
        [[Dates]]
        deps = ["Printf"]
        uuid = "$dates"

        [[TOML]]
        deps = ["Dates"]
        git-tree-sha1 = "d0ac7eaad0fb9f6ba023a1d743edca974ae637c4"
        uuid = "$toml"
        version = "1.0.0"
        """)

        # No cache: TOML is missing, but keyed by the bundled version with no tree-sha.
        missing = _get_missing_packages(proj, store)
        tomlmiss = only(filter(p -> p.name == "TOML", missing))
        @test tomlmiss.git_tree_sha1 === nothing
        @test tomlmiss.version == string(sv)
        @test !any(p -> p.name == "Dates", missing)     # versionless stdlib still skipped

        # A jstore at the bundled-version key (what the child writes) satisfies it.
        jdir = joinpath(store, "T", "TOML", toml); mkpath(jdir)
        touch(joinpath(jdir, "$(sv).jstore"))
        @test !any(p -> p.name == "TOML", _get_missing_packages(proj, store))
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Restart the dev-env mcp session, then run: `JW_TEST_FILTER="Stdlib key: _get_missing_packages"`
Expected: FAIL — without normalization TOML is keyed by the tree-sha, so `tomlmiss.git_tree_sha1` is the sha (not `nothing`) and the bundled-version jstore doesn't satisfy it.

- [ ] **Step 3: Add the normalization branch**

In `src/dynamic_feature/dynamic_feature.jl`, the current loop body is:

```julia
        uuid = tryparse(UUID, uuid_str)
        uuid === nothing && continue

        if haskey(entry, "git-tree-sha1") && haskey(entry, "version")
            # Regular package
            ver = entry["version"]
            tree_sha = entry["git-tree-sha1"]
            filename = replace(string(something(tree_sha, ver)), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver, tree_sha)))
            end
        elseif !haskey(entry, "git-tree-sha1")
```

Insert a stdlib-normalization branch between the `uuid === nothing` guard and the `if haskey(entry, "git-tree-sha1")` branch, and change that `if` to an `elseif`:

```julia
        uuid = tryparse(UUID, uuid_str)
        uuid === nothing && continue

        stdlib_ver = haskey(entry, "version") ? _stdlib_cache_version(uuid) : nothing
        if stdlib_ver !== nothing
            # A stdlib recorded as registered (git-tree-sha1) or with a stale
            # version is resolved to the bundled stdlib by the child; key it there.
            filename = replace(string(stdlib_ver), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, string(stdlib_ver), nothing)))
            end
        elseif haskey(entry, "git-tree-sha1") && haskey(entry, "version")
            # Regular package
            ver = entry["version"]
            tree_sha = entry["git-tree-sha1"]
            filename = replace(string(something(tree_sha, ver)), '+'=>'_')
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), k_entry, string(uuid), string(filename, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver, tree_sha)))
            end
        elseif !haskey(entry, "git-tree-sha1")
```

Leave the existing `elseif !haskey(entry, "git-tree-sha1")` stdlib branch and everything below it unchanged.

- [ ] **Step 4: Run test to verify it passes**

Restart the dev-env mcp session, then run: `JW_TEST_FILTER="Stdlib key: _get_missing_packages"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/dynamic_feature/dynamic_feature.jl test/test_stdlib_cache_key.jl
git commit -m "$(cat <<'EOF'
fix(dynamic): key stdlib caches by the bundled version in the launch gate

A now-stdlib package pinned in the manifest with a git-tree-sha1 (or a stale
version) is cached by the indexer child under its bundled stdlib version.
Normalize the same key in _get_missing_packages so the env stops relaunching a
DJP every start. Versionless stdlibs are unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Normalize the classifier (`derived_project`)

**Files:**
- Modify: `src/layer_projects.jl` (the regular and stdlib branches of the classification loop in `derived_project`, ~lines 204-219)
- Test: `test/test_stdlib_cache_key.jl` (append)

**Interfaces:**
- Consumes: `_stdlib_cache_version` (Task 1); existing `JuliaProjectEntryStdlibPackage(name::String, uuid::UUID, version::Union{Nothing,String})` and `JuliaProjectEntryRegularPackage(name, uuid, version::String, git_tree_sha1::String)`.
- Produces: a tree-sha'd (or stale-versioned) stdlib entry classified into `stdlib_packages` keyed by the bundled version — which flows unchanged into `derived_environment` and the cache-load path, so the parent loads the package's symbols from the key the child wrote.

- [ ] **Step 1: Write the failing test**

Append to `test/test_stdlib_cache_key.jl`:

```julia
@testitem "Stdlib key: derived_project classifies a tree-sha'd stdlib as stdlib" begin
    using JuliaWorkspaces: workspace_from_folders, derived_project, get_projects,
        filepath2uri, _stdlib_cache_version
    using UUIDs: UUID

    toml = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    sv = _stdlib_cache_version(UUID(toml))

    mktempdir() do root
        proj = joinpath(root, "proj"); mkpath(proj)
        write(joinpath(proj, "Project.toml"), "[deps]\nTOML = \"$toml\"\n")
        write(joinpath(proj, "Manifest.toml"), """
        [[TOML]]
        git-tree-sha1 = "d0ac7eaad0fb9f6ba023a1d743edca974ae637c4"
        uuid = "$toml"
        version = "1.0.0"
        """)

        jw = workspace_from_folders([proj])
        p = derived_project(jw.runtime, first(get_projects(jw)))
        @test p !== nothing
        @test haskey(p.stdlib_packages, "TOML")             # reclassified as stdlib
        @test p.stdlib_packages["TOML"].version == string(sv)
        @test !haskey(p.regular_packages, "TOML")           # not keyed by the tree-sha
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Restart the dev-env mcp session, then run: `JW_TEST_FILTER="Stdlib key: derived_project"`
Expected: FAIL — without normalization TOML lands in `regular_packages` (has a git-tree-sha1), so `haskey(p.stdlib_packages, "TOML")` is false.

- [ ] **Step 3: Add the normalization**

In `src/layer_projects.jl`, the current branches are:

```julia
        elseif haskey(v_entry[1], "git-tree-sha1") && haskey(v_entry[1], "uuid") && haskey(v_entry[1], "version")
            uuid_of_regular_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_regular_package !== nothing || continue

            git_tree_sha1_of_regular_package = v_entry[1]["git-tree-sha1"]

            version_of_regular_package = v_entry[1]["version"]

            regular_packages[k_entry] = JuliaProjectEntryRegularPackage(k_entry, uuid_of_regular_package, version_of_regular_package, git_tree_sha1_of_regular_package)
        elseif haskey(v_entry[1], "uuid")
            uuid_of_stdlib_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_stdlib_package !== nothing || continue

            version_of_stdlib_package = get(v_entry[1], "version", nothing)

            stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, uuid_of_stdlib_package, version_of_stdlib_package)
```

Replace them with (regular branch reclassifies a stdlib; stdlib branch normalizes a stale version):

```julia
        elseif haskey(v_entry[1], "git-tree-sha1") && haskey(v_entry[1], "uuid") && haskey(v_entry[1], "version")
            uuid_of_regular_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_regular_package !== nothing || continue

            # A now-stdlib package recorded as registered (git-tree-sha1) is
            # resolved to the bundled stdlib by the indexer child; classify it as
            # a stdlib keyed by the bundled version to match.
            stdlib_ver = _stdlib_cache_version(uuid_of_regular_package)
            if stdlib_ver !== nothing
                stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, uuid_of_regular_package, string(stdlib_ver))
            else
                git_tree_sha1_of_regular_package = v_entry[1]["git-tree-sha1"]
                version_of_regular_package = v_entry[1]["version"]
                regular_packages[k_entry] = JuliaProjectEntryRegularPackage(k_entry, uuid_of_regular_package, version_of_regular_package, git_tree_sha1_of_regular_package)
            end
        elseif haskey(v_entry[1], "uuid")
            uuid_of_stdlib_package = tryparse(UUID, v_entry[1]["uuid"])
            uuid_of_stdlib_package !== nothing || continue

            version_of_stdlib_package = get(v_entry[1], "version", nothing)
            # A stdlib recorded with a stale version is keyed by the bundled one.
            if version_of_stdlib_package !== nothing
                stdlib_ver = _stdlib_cache_version(uuid_of_stdlib_package)
                stdlib_ver !== nothing && (version_of_stdlib_package = string(stdlib_ver))
            end

            stdlib_packages[k_entry] = JuliaProjectEntryStdlibPackage(k_entry, uuid_of_stdlib_package, version_of_stdlib_package)
```

Leave the `if haskey(v_entry[1], "path") ...` deved branch and the trailing `else error(...)` unchanged.

- [ ] **Step 4: Run test to verify it passes**

Restart the dev-env mcp session, then run: `JW_TEST_FILTER="Stdlib key: derived_project"`
Expected: PASS.

- [ ] **Step 5: Run the whole feature suite + related regressions**

Restart, then run: `JW_TEST_FILTER="Stdlib key"` (all three new items), then `JW_TEST_FILTER="Manifest"` and `JW_TEST_FILTER="Test project"` (existing `test_projects.jl` classifier tests) to confirm no regression.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/layer_projects.jl test/test_stdlib_cache_key.jl
git commit -m "$(cat <<'EOF'
fix(projects): classify a tree-sha'd stdlib as stdlib in derived_project

Reclassify a now-stdlib manifest entry (recorded with a git-tree-sha1 or a
stale version) into stdlib_packages keyed by the bundled version, so the parent
loads its symbols from the key the indexer child wrote instead of a tree-sha
path that never exists.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage**
- §1 rule (gate on "entry has a version"; `something(stdlib_infos version, VERSION)`) → Task 1 helper + Task 2/3 callers gating on `haskey(entry,"version")` / the version-bearing branches.
- §2 helper → Task 1.
- §3a `derived_project` → Task 3. §3b `_get_missing_packages` → Task 2. Consumers unchanged → no tasks (correct).
- §4 testing: helper (Task 1), `_get_missing_packages` incl. versionless-Dates-skipped (Task 2), classifier (Task 3), integration mirrored by the "jstore at bundled version satisfies it" assertion in Task 2 (a full DJP integration run is covered by the manual reproduction already performed; not re-automated here to keep the suite fast).
- Non-goals (JLLs via tombstone; versionless stdlibs unchanged; no child change) respected: Task 2's Dates assertion and the version-gate guard the versionless case; nothing touches the child.

**Placeholder scan:** none — every step carries complete code and a concrete run + expected result.

**Type consistency:** `_stdlib_cache_version` returns `Union{Nothing,VersionNumber}` in Task 1 and is consumed identically in Tasks 2/3; `string(stdlib_ver)` feeds `MissingPackage.version::String` (Task 2) and `JuliaProjectEntryStdlibPackage.version::Union{Nothing,String}` (Task 3). `MissingPackage`'s `git_tree_sha1` is set to `nothing` (allowed by its `Union{String,Nothing}`).
