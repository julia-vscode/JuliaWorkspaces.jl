# Per-package symbol-cache tombstones — design

Date: 2026-07-24

## Problem

A subset of workspace environments re-index on every fresh language-server start
even though a full index previously "succeeded." Their manifests pin package
versions whose `.jstore` symbol cache does not (and cannot) exist in the store —
e.g. stale test/example fixtures pinning `Compat 2.2.0`, `MacroTools 0.5.5`,
`Preferences 1.3.0`, or JLLs at versions not installed under the current Julia.
`_get_missing_packages` correctly reports these missing, so the env launches a
DJP; the DJP can't produce a matching cache (the pinned version isn't
installable/loadable), so nothing is written; the next session repeats. Nothing
records "we already tried and can't cache this," so the loop is permanent.

## Goal

Record, per package version, that local caching was attempted and failed, so
the language server stops re-launching indexing for it — while still retrying
when the situation may have changed (indexing code updated, Julia updated, or a
cloud-indexed cache became available).

## Non-goals

- Fixing the JLL cache-key mismatch (a package cached under a tree-sha but
  looked up by version). Tracked separately; a tombstone will suppress the
  re-launch in the meantime.
- Any change to deved-package handling (`_get_missing_packages` already skips
  packages with a manifest `path`).
- The reactor watchdog / env-level tombstones (separate work, not on `main`).

## Decisions (from design workshop)

1. **Shared tombstone files, read by both processes.** Tombstone files live under
   `store_path`; the child (`get_store`) reads them to skip known-uncacheable
   packages and writes them on failure; the parent (JuliaWorkspaces) reads them
   in its launch gate and deletes them when it downloads that package.
2. **Version stamp = a shared indexer-code version constant + `VERSION`.** Not the
   JuliaWorkspaces package version.
3. **Failure is outcome-based:** after an indexing run, any package the run was
   meant to cache that still has no `.jstore` is tombstoned.

## 1. Indexer-code version constant

Add to the shared symbol-server code (`shared/symbolserver/`, included by both
`src/` and `juliadynamicanalysisprocess/`):

```julia
const INDEXER_VERSION = 1   # bump when caching/indexing logic changes
```

Both processes read the identical value with no protocol passing. Bumping it
invalidates all existing tombstones (they become version-mismatched → retried).
The relevant Julia version is `Base.VERSION`; the LS and the child run the same
binary (`start(djp)` uses `Sys.BINDIR`), so their `VERSION`s agree.

## 2. Tombstone file — co-located with the cache

A package's tombstone sits at the **same path as its `.jstore` with a
`.tombstone` extension**:

- cache: `store/<U>/<name>/<uuid>/<filename>.jstore`
- tombstone: `store/<U>/<name>/<uuid>/<filename>.tombstone`

where `<filename>` uses the **exact same** derivation as the cache filename
(`get_cache_path`: `replace(string(something(tree_hash, version)), '+' => '_')`).
Consequences:

- No separate keying/hashing scheme — anywhere `cache_path` is computed, the
  tombstone path is `replace(cache_path, r"\.jstore$" => ".tombstone")` (or the
  same path list with the last element's extension swapped).
- The `.jstore` check always precedes the `.tombstone` check, so a stale
  tombstone can never shadow a real cache.

Content is TOML:

```toml
indexer_version = 1
julia_version = "1.12.6"
timestamp = "1721800000"
```

**"Same versions"** = `indexer_version == INDEXER_VERSION && julia_version == string(VERSION)`.
Same → skip (uncacheable here). Either differs → retry.

Shared helpers (in `shared/symbolserver/`, so both processes use one
implementation):
- `tombstone_path(cache_path_parts) -> String`
- `read_tombstone(path) -> Union{Nothing, NamedTuple}` (parsed versions; `nothing` if absent/malformed)
- `tombstone_is_current(t) -> Bool` (both versions match)
- `write_tombstone(path)` (atomic temp + `mv`; stamps current versions)
- `delete_tombstone(path)`

## 3. Per-package classification pipeline

For each **regular** package a manifest needs (deved packages skipped as today),
evaluate in this order — **cached → download → skip-tombstoned → attempt**:

1. `.jstore` present → cached.
2. In cloud index (and `symbolcache_download` enabled) → download; on success
   **delete any sibling `.tombstone`**.
3. `.tombstone` present and `tombstone_is_current` → skip (known-uncacheable).
4. otherwise (no tombstone, or version-mismatched) → **needs local caching**.

This same order is applied in two places against the same files:

### 3a. Parent launch gate (`src/dynamic_feature/dynamic_feature.jl`)

`_get_missing_packages` computes the raw missing set (no `.jstore`) as today.
The prep step (`WatchEnvironmentMsg`/`CreateStandaloneProjectMsg` async task →
`_download_missing_caches`) then, per raw-missing package:

- if downloaded from the index → also `delete_tombstone` for it;
- else if `tombstone_is_current` → drop it from the "still needs a DJP" set.

`EnvironmentPrepDoneMsg.still_missing` is true only if the post-download,
post-tombstone-filter set is non-empty. So **an env whose only-missing packages
are all tombstoned-current fast-lanes with no child** — this is what stops the
re-launch loop. When `symbolcache_download` is off, step 2 is skipped and the
tombstone filter alone decides.

Concretely, factor the per-package classification so `_get_missing_packages`
(or a thin wrapper it calls) can return only the packages that still "need local
caching" after the tombstone filter, keeping deved-skip behavior intact.

### 3b. Child (`get_store`)

Before the load loop, drop from `packages_to_load` any package whose sibling
`.tombstone` `tombstone_is_current` (don't attempt it). Attempt the rest.

## 4. Attempt + record (child, `get_store`)

- Wrap each `load_package` in `try/catch` so one failure doesn't abort the run
  (log the failure; continue).
- After `write_depot`, do the **outcome check** over the packages the run
  intended to cache (i.e. the post-tombstone-filter `packages_to_load`):
  - `.jstore` now exists → success → `delete_tombstone` (clears any stale one);
  - `.jstore` still absent → `write_tombstone` stamped with current versions.

`get_cache_path(manifest(ctx), uuid)` already yields the exact path parts, so the
outcome check and tombstone path reuse it directly.

## 5. Lifecycle summary

- **Written** by the child when an attempted package yields no `.jstore`.
- **Deleted** when the package becomes cached — a successful local attempt
  (child) or a download (parent).
- **Superseded/retried** without deletion when `INDEXER_VERSION` or `VERSION`
  changes (mismatch → re-attempt), or when the cloud index gains the package
  (download path deletes it).
- Works identically with `symbolcache_download` on or off (the download branch
  is simply inert when off).

## 6. Testing

**Shared helpers (pure, temp store dir):**
- `tombstone_path` swaps only the extension and matches the `.jstore` sibling for
  the same manifest entry.
- write → read round-trip; `tombstone_is_current` true only when both versions
  match; malformed/absent → `read_tombstone` returns `nothing` (treated as retry).

**Parent (`_get_missing_packages` / classifier, injectable/no real process):**
- a regular package with a current-version tombstone and no `.jstore` is **not**
  returned as needing local caching;
- a version-mismatched tombstone **is** returned (retry);
- with download enabled, a package present in a (stubbed) index is downloaded and
  its tombstone deleted;
- deved packages are still skipped.

**Child (`get_store`, integration modeled on `test/test_symbolserver.jl`):**
- a package that fails to load leaves the others cached and gets a `.tombstone`;
- a second run skips the tombstoned package (no re-attempt) and its env no longer
  reports it missing;
- a tombstone written under a different `INDEXER_VERSION` is retried;
- a package that caches successfully has any sibling `.tombstone` deleted.

## Risks / notes

- Outcome-based tombstoning will also tombstone stdlib JLLs whose version-keyed
  `.jstore` is never written (the separate key-mismatch case). That is the
  intended stop-gap: it halts the re-launch loop; the key normalization is a
  follow-up.
- A genuinely-transient failure (e.g. a one-off precompile error) tombstones the
  package until `INDEXER_VERSION`/`VERSION` changes or the cloud index gains it.
  Acceptable: bumping `INDEXER_VERSION` is the escape hatch, and a correct cache
  from the index always supersedes.
