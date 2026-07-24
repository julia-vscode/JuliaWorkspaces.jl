# Stdlib symbol-cache key normalization — design

Date: 2026-07-24

## Problem

Some workspace environments re-launch a dynamic indexer (DJP) on **every**
language-server start even though indexing "succeeds," because the parent and
the child disagree on a package's `.jstore` cache key.

Concretely (reproduced against `packages/Preferences/test/UsesPreferences`): its
`Manifest.toml` records `TOML` as a **registered** package —
`git-tree-sha1 = "d0ac7ea…"`, `version = "1.0.0"`. But `TOML` is a bundled
**stdlib** in the running Julia. The two readers key it differently:

- **Parent** (`_get_missing_packages`, and the `derived_project` classifier that
  feeds cache loading) reads the static on-disk manifest and keys by
  `something(git_tree_sha1, version)` → the tree-sha `d0ac7ea…` → looks for
  `store/T/TOML/<uuid>/d0ac7ea….jstore`.
- **Child** (`get_store`) loads a live `Pkg.Types.Context()`, which resolves any
  stdlib UUID to the Julia-bundled stdlib regardless of the manifest — `TOML` →
  version `1.0.3`, no tree-sha — so `get_cache_path` writes
  `store/T/TOML/<uuid>/1.0.3.jstore`.

The tree-sha-keyed file is never written, so the parent sees `TOML` "missing" on
every start and launches a DJP. The per-package tombstone cannot help: from the
child's view `TOML` **succeeds** (it caches under `1.0.3`), so the outcome loop
deletes rather than writes a tombstone — and it never computes the tree-sha key
the parent checks.

This is the cache-key mismatch the tombstone design listed as a separate
follow-up ("a package cached under a tree-sha but looked up by version"),
mirrored (cached under version, looked up by tree-sha).

## Goal

Make the parent key a stdlib package's cache the same way the child's live
resolution does, so a stdlib recorded with a stale identity (a `git-tree-sha1`
or a stale bare version) is looked up — and loaded — at the key the child
actually wrote. The env then fast-lanes after one index **and** the package's
symbols load.

## Non-goals

- JLLs (and any non-stdlib package) pinned at a version not installable under the
  current Julia. The child genuinely fails to cache those, so the per-package
  tombstone already covers them.
- Loading versionless stdlibs (`Dates`, `Printf`, `Unicode`) that the parent
  skips today. They never enter the missing set and never trigger a relaunch;
  their handling is unchanged.
- Any change to the child (`get_store`) or the on-disk cache layout. The child's
  re-resolution is already the source of truth we match.

## Decision (from design workshop)

**Parent-side stdlib normalization.** The divergence is specific to stdlibs:
`Pkg.Types.Context()` always overrides a stdlib manifest entry with the bundled
stdlib identity, while the parent trusts the static manifest. The LS runs the
same Julia binary as the child, so the parent can compute the child's key
locally via `Pkg.Types.stdlib_infos()` — no re-resolution and no child needed.

Alternatives considered and rejected: the child writing the cache at the on-disk
key too (duplicate caches; leaves the parent's model wrong), and the child
tombstoning the on-disk key (stops the relaunch but drops the stdlib's symbols).

## 1. Normalization rule

The parent forms a cache key for a non-deved entry **iff the entry has a
`version`** (a `git-tree-sha1` alone is never keyed). The normalization targets
exactly those key-forming entries:

```
# for a non-deved entry that has a manifest `version`:
if is_stdlib(uuid):
    version       = something(stdlib_infos()[uuid].version, VERSION)  # TOML → v"1.0.3"
    git_tree_sha1 = nothing
```

- Applies whether the manifest pinned a `git-tree-sha1`, a stale bare version, or
  both — all become the canonical stdlib key.
- **Gated on the entry having a `version`, not on whether a stdlib version
  exists.** `stdlib_infos()` returns a concrete version even for stdlibs recorded
  versionless in the manifest (`Dates`/`Printf`/`Unicode` → `v"1.11.0"`). Those
  entries carry no `version`, so the parent forms no key for them and skips them
  today; the rule never runs for them, and that behavior is unchanged. Only a
  stdlib the manifest *does* version (like `TOML`) is normalized.
- `something(stdlib_infos()[uuid].version, VERSION)` mirrors `get_cache_path`
  exactly: a stdlib with a bundled version keys by it; one with no bundled version
  falls back to the running Julia `VERSION`.
- `is_stdlib` / `stdlib_infos` are `Pkg.Types` internals already used by
  `get_cache_path` (`shared/symbolserver/utils.jl`); guard access with
  `isdefined(Pkg.Types, …)` exactly as `get_cache_path` does. They depend only on
  the (session-constant) Julia binary, so they are safe to call inside the
  Salsa-derived `derived_project`.

**Why the resulting key matches the child.** The child's re-resolved manifest
carries a stdlib's bundled version (`stdlib_infos` version, filled in by Pkg) and
no tree-sha; `get_cache_path` then keys by `something(nothing, version, …)` = that
version. Normalizing the parent to the same `(version, nothing)` makes the two
keys identical by construction (same Julia binary → same stdlib table).

## 2. Shared helper

```julia
# The version to key a stdlib UUID's cache by (`something(stdlib_infos version,
# VERSION)`), or `nothing` when the UUID is not a stdlib. Callers invoke it only
# for entries that have a manifest `version`, so a versionless-in-manifest stdlib
# is never reached.
_stdlib_cache_version(uuid) -> Union{Nothing, VersionNumber}
```

Memoized (a cached `stdlib_infos()` result / `Dict{UUID,…}`), since
`stdlib_infos()` rebuilds a dict per call and the classifiers run per package.
Lives in a parent file included by both call sites (e.g. `src/utils.jl`).

## 3. Application sites

The parent keys caches in four structurally-identical spots, but only **two**
are independent classification sources; the other two consume their output.

### 3a. `derived_project` (`src/layer_projects.jl`)

The Salsa classifier that sorts manifest entries into `deved` / `regular` /
`stdlib` packages. It feeds both the ExternalEnv store and the cache-load path
(`_try_load_package_cache` via `_load_package_caches_for_project!`). In the
branches that produce a keyed package (the `git-tree-sha1`+`version` "regular"
branch and the versioned "stdlib" branch — i.e. entries with a `version`), if
`_stdlib_cache_version(uuid)` is non-nothing, classify the entry as a **stdlib**
package keyed by that version with the tree-sha dropped. The versionless-stdlib
branch is left as-is. `TOML` then lands in `stdlib_packages` at `1.0.3`, so
`derived_environment` loads `1.0.3.jstore` and its symbols resolve.

### 3b. `_get_missing_packages` (`src/dynamic_feature/dynamic_feature.jl`)

The raw-manifest reader in the launch gate (not Salsa-derived). Apply the same
normalization inside the two key-forming branches: for an entry that has a
`version`, if `_stdlib_cache_version(uuid)` is non-nothing, produce a
`MissingPackage` keyed by that version with `git_tree_sha1 = nothing`. The
versionless-stdlib path (`ver_str === nothing && continue`) is untouched. `TOML`
is then looked up at `1.0.3.jstore`, found, and the env fast-lanes.

### Consumers that need no change

- `_try_load_package_cache` / `_ensure_package_cache_loaded!` (`src/types.jl`) —
  key from the `(version, git_tree_sha1)` the classifier passes.
- `derived_environment` (`src/layer_environment.jl`) — consumes
  `regular_packages` / `stdlib_packages`.
- `inputs.jl` metadata bookkeeping — fed the classified values.
- The child (`get_store`) — already keys by the resolved stdlib version.

## 4. Testing

**Helper (pure):**
- `_stdlib_cache_version(TOML_uuid) == v"1.0.3"`.
- `_stdlib_cache_version(Dates_uuid) == v"1.11.0"` (a concrete version — the guard
  against pulling `Dates` in is the caller's "entry has a version" gate, not the
  helper).
- `=== nothing` for a registered package (Preferences UUID).

**`_get_missing_packages` (fixture manifest, temp store):**
- A manifest pinning `TOML` with `git-tree-sha1` + version `1.0.0`, with a
  `store/T/TOML/<uuid>/1.0.3.jstore` present → `TOML` is **not** returned missing.
- With no jstore present → `TOML` is returned as a stdlib entry whose
  `git_tree_sha1` is `nothing` and version is `1.0.3` (so the launch gate and the
  tombstone path both key it at `1.0.3`).
- A versionless stdlib entry (`Dates`, no manifest `version`) is **not** returned
  as missing — versionless stdlibs stay skipped, unchanged.

**Classifier / load path:**
- `derived_project` for the fixture puts `TOML` in `stdlib_packages` keyed by
  `1.0.3` (not `regular_packages` keyed by the tree-sha); `derived_environment`
  loads it from `1.0.3.jstore`.

**Integration (mirrors the reproduction):**
- Index `UsesPreferences` once (child writes `1.0.3.jstore`); a second
  `_get_missing_packages` over the same store returns empty after
  `_drop_tombstoned`, i.e. the env fast-lanes with no DJP.

## Risks / notes

- `is_stdlib` / `stdlib_infos` are unexported `Pkg.Types` internals. Mitigated by
  the existing precedent in `get_cache_path` and the `isdefined` guard.
- Correctness depends on the LS and the child running the same Julia binary — an
  existing invariant (`start(djp)` uses `Sys.BINDIR`). If violated, the stdlib
  versions could differ; out of scope, same as the tombstone design's `VERSION`
  assumption.
- The two classifiers (`derived_project`, `_get_missing_packages`) must apply the
  normalization identically; the shared helper is the single source of truth to
  keep them from drifting.
