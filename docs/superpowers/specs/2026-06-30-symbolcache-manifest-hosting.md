# Symbol-cache manifest hosting & regeneration — Spec

## Problem

`jwcloudindex` now generates SymbolServer `.jstore` caches for ~the whole General
registry (last run: 59,582 caches, 12,137 packages, 12.5 GiB raw). We need to (a)
host them so the VS Code / SymbolServer client can fetch per-package caches, and
(b) keep them fresh with a periodic, incremental, **stateless** regeneration job.

The current client (`src/SymbolServer/SymbolServer.jl`) already downloads
per-package `tar.gz` caches from `https://www.julia-vscode.org/symbolcache` (it
requests `store/v2/packages/...`), but with **no availability index**: it attempts
a download for every General package in the project manifest and silently eats
failures. With registry-wide coverage that's wasteful (404 round-trips for
everything not cached) and gives the client no cheap way to know what exists.

**Current/legacy hosting:** the live cache is **v1**, backed by a git repo at
`https://github.com/julia-vscode/symbolcache`. The **v2** layout the client code
already references is **not yet live**. This work hosts the new index-based design
on object storage **at v2** (no version bump needed — there's nothing live to
disturb, and the client already uses the v2 path), superseding the v1 git repo.
The git-repo approach is exactly the GitHub-hosting model whose bandwidth/ToS
limits motivate the move to R2.

## Goals

1. **Client:** consult a small published availability **index** so it only fetches
   caches that exist — one index download instead of N per-package 404s. Degrade
   gracefully to current behavior if the index is unavailable.
2. **Hosting:** static, content-addressed, immutable artifacts on object storage +
   CDN. No server, no database.
3. **Regeneration:** a scheduled, stateless, idempotent job that indexes only what
   is missing, uploads additively, and republishes the index.

## Non-goals

- Changing the `.jstore` binary format or the extraction logic.
- Per-Julia-version cache variants (one cache per package version, newest wins).
- Shipping tombstones to clients (they are private generation state).

## Decisions (converged)

- **Artifact format: `tar.gz` per package version** (unchanged from today's v2).
  The client already unpacks `tar.gz` via `Pkg.PlatformEngines.download_verify_unpack`;
  keeping it means the only client change is the index lookup. gzip (not zstd):
  no new client dependency (native `CodecZlib`/`download_verify_unpack`), ~19×
  compression (12.5 GiB → ~0.66 GiB), which is plenty behind an immutable CDN.
- **Host at the existing `v2` layout** — no version bump. v2 isn't live yet, so
  there's nothing to disturb, and the client already requests `store/v2/...`, which
  makes the client change purely additive (just add the index). Clients that
  predate the index simply ignore it and fetch per-package as before.
- **Content-addressed + immutable:** the cache filename is the package's git
  tree-hash, so artifacts are immutable. Serve with
  `Cache-Control: public, max-age=31536000, immutable`.
- **Storage: Cloudflare R2 + CDN** (zero egress fees; S3/GCS equivalent if you
  prefer to pay egress).
- **Two lists, kept separate:**
  - **Availability index** (public): the set of `(uuid, treehash)` caches that
    exist. Client-facing. Derived from the store's `.jstore` set.
  - **Tombstones** (private generation state): the set of `(uuid, treehash)` that
    failed / were unsatisfiable / timed out. Plain markers, **no fingerprinting**.
- **Run modes (the entire retry policy):**
  - **incremental** (frequent): skip = successes ∪ tombstones; index only new
    versions; tombstones accumulate.
  - **full** (periodic / on Julia bump / registry growth): skip = successes only;
    retry every non-cached version including tombstoned ones; tombstones rebuilt
    from this run's failures.
- **Stateless runner:** the only carried-forward state is the tombstone set; it
  lives in the bucket. Successes are re-derived from the published index (or a
  bucket LIST). The runner downloads only the small key-sets, never the GBs of
  artifacts, to compute what's missing.

## Layout (R2 bucket)

```
store/v2/packages/<I>/<Name>/<uuid>/<treehash>.tar.gz   # immutable artifacts (public)
store/v2/index.txt.gz                                   # availability index (public, short TTL)
store/v2/_state/tombstones.txt.gz                       # generation state (private)
store/v2/_state/lock                                    # cron mutex (conditional PUT)
store/v2/_state/runs/<ts>.jsonl.gz                      # optional: per-run results, audit/stats
```

- **Index format** (`index.txt.gz`): gzip of newline-delimited `<uuid>/<stem>`
  lines, where `<stem>` is the cache filename without `.jstore` (the tree-hash,
  with `+`→`_` per `get_cache_path`). ~59k lines → a few hundred KB gzipped.
- **Tombstone format** (`tombstones.txt.gz`): same `<uuid>/<stem>` line format
  (status not needed for skip decisions; keep per-run detail in `runs/<ts>`).

## Client behavior (the priority)

In `download_cache_files`:

1. Resolve project manifest → candidate packages (existing
   `validate_disc_store` = manifest packages with no local `.jstore`, then
   `remove_non_general_pkgs!` for privacy).
2. **New:** fetch `store/v2/index.txt.gz` once, parse into a `Set{String}` of
   `<uuid>/<stem>` keys. On any failure, log and skip the filtering step (fall
   back to current per-file behavior).
3. **New:** keep only candidates whose `<uuid>/<stem>` key is in the index.
4. Fetch the remaining (existing `get_file_from_cloud` tar.gz path), pointed at
   the `v2` upstream.

The index key for a manifest package is derived from the existing
`get_cache_path(manifest, uuid)` → `[I, Name, uuid, "<stem>.jstore"]`, i.e.
`key = paths[3] * "/" * splitext(paths[4])[1]`. This guarantees client and server
agree on keys by construction.

## Server: index generation

A pure function over a store directory: walk `store/<I>/<Name>/<uuid>/<th>.jstore`
and emit sorted unique `<uuid>/<th>` lines. Exposed via a `jwcloudindex` flag so
the regeneration job can produce `index.txt` from the local/synced store, then
gzip + upload it.

## Server: regeneration job (stateless cron)

1. Acquire `store/v2/_state/lock` (conditional `PUT If-None-Match: *`). Because a
   **full** run can take ~36 h, the lock is **heartbeat-renewed** (rewrite with a
   fresh timestamp every ~5 min) and considered **stale after ~15 min** without a
   beat, rather than given a fixed TTL that would have to exceed the longest run.
   Prefer the scheduler's native mutex (GitHub Actions `concurrency:` group, or
   `flock` on a single runner) as the primary guard; the bucket lock is the
   cross-runner backstop.
2. Download `index.txt.gz` (successes) + `tombstones.txt.gz` → in-memory key-sets.
3. Refresh General registry; enumerate + filter (newest-N per breaking, etc.).
4. `missing = candidates − skip-set` where skip-set is:
   - incremental: successes ∪ tombstones
   - full: successes only
5. Run `jwcloudindex` over `missing`.
6. Upload new `.tar.gz` artifacts first (additive, immutable).
7. Update lists: successes ∪= new; tombstones ∪= new failures (incremental) or
   tombstones := this-run failures (full). Rebuild `index.txt.gz` from the
   success set. Upload both (short TTL).
8. Optionally archive the run's `results.jsonl` to `_state/runs/<ts>`.
9. Release lock.

Periodic **full reconcile** (monthly / on demand): bucket `LIST` of the
`.tar.gz` prefix is authoritative; rebuild the index from it and drop any
tombstone that now has an artifact. Catches drift from partial uploads.

## Consistency invariants

- Upload order: artifacts → lists → (pointer if used). The index must never
  reference a key whose artifact isn't already live.
- Immutable artifacts; the index has a short TTL (it is the only mutable public
  object).
- The bucket is the single source of truth; successes derive from it, tombstones
  are the only carried-forward state.
- Integrity: the CacheStore format self-validates (magic/version/length) and the
  client raises `CacheCorruptedError` on bad data — no extra checksums.

## Rollout / phasing

- **Phase 1 — client (first):** add index fetch + filtering, default upstream
  bumped to `v2`, graceful fallback. Ship-able independently: against a `v2`
  bucket that has an index it filters; against one without, it degrades to current
  behavior.
- **Phase 2 — server index generation:** `jwcloudindex` can emit `index.txt`
  from a store.
- **Phase 3 — hosting + regeneration:** R2 upload of `tar.gz` artifacts + index,
  stateless incremental/full regen job with tombstone state in the bucket.

## Acceptance

- Client: given an index listing a subset, only that subset is fetched; missing
  packages incur no network request; an unreachable index falls back cleanly.
- Server: `build_index(store)` emits exactly one `<uuid>/<stem>` line per
  `.jstore`, sorted and unique.
- Regen: a second run with no registry change does zero indexing work
  (incremental) and the index/tombstone sets are unchanged.
