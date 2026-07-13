# CloudIndex — `jwcloudindex`

Registry-wide symbol cache generation for JuliaWorkspaces.

## Purpose

`jwcloudindex` walks a Julia registry (default: the installed General registry),
filters package/version combinations according to a policy, and drives the
existing SymbolServer cache machinery to produce `.jstore` symbol caches for
every selected version.  The driver fans work out to short-lived **worker
subprocesses** (one per `package@version`) so each indexing run is fully
isolated.  Results are written to a configurable store root and optionally
packaged as server tarballs for CDN distribution.

This is single-machine scaffolding with hooks (deterministic sharding, external
launcher template) for an external CI matrix to fan out across machines.
Multi-machine coordination, a shared queue, and CDN upload are out of scope.

---

## The `jwcloudindex` app

The app is declared in `Project.toml` as:

```toml
[apps.jwcloudindex]
submodule = "CloudIndexApp"
```

Entry point: `src/CloudIndexApp.jl` → `CloudIndexApp.cli_main`.

---

## Flags

```
jwcloudindex — generate symbol caches across a Julia registry

  --registry PATH        registry to index (default: installed General)
  --store DIR            .jstore output root (default: ./symbolstore)
  --newest N             keep the newest N versions (default N=1)
  --per-break            apply --newest within each breaking line (major for
                         >=1.0, minor for 0.x) instead of overall
  --all-versions         keep every version
  --include REGEX        repeatable; keep only matching names
  --exclude REGEX        repeatable; drop matching names
  --include-yanked       keep yanked versions (default: drop)
  --include-jll          index _jll packages (default: skip)
  --julia-version V      compat target (default: running version)
  --jobs K               concurrent workers (default: CPU/2)
  --timeout SECONDS      per-worker wall clock (default: 600)
  --shard k/n            deterministic shard
  --launcher TEMPLATE    wrap each worker ({cmd}{depot}{store}{env}{jwroot})
  --depot DIR            shared depot (default: <workdir>/depot)
  --workdir DIR          temp envs + logs (default: mktempdir)
  --no-resume            reindex already-cached entries (default: skip cached)
  --no-progress          suppress per-completion progress lines (stderr)
  --dry-run              print the filtered worklist; don't index
  --report-missing       print only not-yet-indexed entries; don't index
  --out FILE             with --dry-run/--report-missing, write JSONL
  -h | --help            this message
```

**Defaults summary:**

| Flag | Default |
|------|---------|
| `--store` | `./symbolstore` |
| `--newest` | `1` (newest version; per breaking line when `--per-break` is set) |
| `--per-break` | off (selection is overall) |
| `--jobs` | `max(1, CPU_THREADS ÷ 2)` |
| `--timeout` | `600` seconds |
| resume | enabled (skip already-cached) |
| yanked versions | dropped |
| `_jll` packages | skipped |
| `--julia-version` | running Julia version |
| `--workdir` | `mktempdir()` (cleaned up by OS) |
| `--depot` | `<workdir>/depot` |

---

## Version selection

`--newest N` chooses how many versions to keep per package; `--per-break` changes
*what* the count applies to:

| Flags | Selects (per package) |
|-------|-----------------------|
| `--newest N` | the newest `N` versions overall |
| `--newest N --per-break` | the newest `N` versions **within each breaking line** |
| `--per-break` | newest 1 per breaking line (`N` defaults to 1) |
| `--all-versions` | every version (overrides `--newest`/`--per-break`) |

A *breaking line* is a SemVer-breaking bucket: the major version for `>= 1.0`
(`1.x.y` → line `1`, `2.x.y` → line `2`), and the minor version for `0.x`
(`0.1.z` → line `0.1`, `0.2.z` → line `0.2`).

Example — newest 2 patches of every breaking line of a package with versions
`0.1.0, 0.1.3, 0.1.5, 0.2.0, 1.0.0, 1.2.0`:

```
jwcloudindex --include '^Foo$' --newest 2 --per-break
# keeps 0.1.5, 0.1.3, 0.2.0, 1.2.0, 1.0.0
```

Selection runs **after** the row filters (yanked/jll/julia-compat/name), so it
picks the newest qualifying versions.

---

## Modes

### Index mode (default)

Indexes all selected versions that are not already cached.  Each worker runs in
an isolated pinned environment and writes `<hash>.jstore` into the store.  The
driver reports a per-status count on exit and writes a JSONL log to
`<workdir>/results.jsonl`.  Exit code is `0` on full success, `1` if any worker
failed or timed out, `2` if no registry was found.

As workers finish, the driver prints one plain line per completion to stderr
(CI-friendly — no spinners or carriage returns), with a running counter:

```
jwcloudindex: indexing 120 version(s) with 8 worker(s)
[  1/120] ok            Crayons@4.1.1  (23.2s)
[  2/120] unsatisfiable OldPkg@0.1.0   (1.4s)
[  3/120] ok            Glob@1.5.0     (22.8s)
```

Pass `--no-progress` to suppress these lines (the JSONL log still records every
result).

```
jwcloudindex --store ./symbolstore --newest 1
```

### `--dry-run`

Prints the filtered worklist (name, version, uuid, treehash, one per line) and
exits without indexing.  Use `--out FILE` to write JSONL instead of stdout.

```
jwcloudindex --store ./symbolstore --newest 1 --dry-run
```

### `--report-missing`

Like `--dry-run`, but the output is limited to versions that are **not** yet
present in the store (useful for auditing gaps or building a worklist for a
one-off backfill run).

```
jwcloudindex --per-break --store ./symbolstore --report-missing --out missing.jsonl
```

---

## Output layout

### `.jstore` files

Worker results land at:

```
<store>/<Initial>/<Name>/<uuid>/<treehash>.jstore
```

Example: `./symbolstore/E/Example/7876af07-990d-54b4-ab0e-23690620f79a/e1f0e1a832ccd8e97d6d0348dec33ee139a5aeaf.jstore`

Paths inside the `.jstore` are scrubbed to the literal string `PLACEHOLDER`
before writing (the SymbolServer download path rewrites `PLACEHOLDER` → the
real path at unpack time on the client side).

### Failure tombstones

A version that fails deterministically (status `failed` or `unsatisfiable`,
e.g. an old version that won't resolve on the running Julia) gets a tombstone
written next to where its cache would go:

```
<store>/<Initial>/<Name>/<uuid>/<treehash>.unavailable
```

`is_cached`/resume treat a `.unavailable` as "accounted for", so a deterministic
failure isn't retried on every run.  Timeouts are **not** tombstoned (they may
be transient and are worth retrying).  To force a re-attempt after, say, a Julia
upgrade, delete the `.unavailable` files (or run with `--no-resume`).

Building CDN-ready `.tar.gz` artifacts from the store (success caches +
`.unavailable` markers) is a separate, follow-up packaging step — not part of
the indexer.

### JSONL log

Every completed worker appends one JSON line to `<workdir>/results.jsonl`:

```json
{"name":"Example","uuid":"7876af07-...","version":"0.5.5","treehash":"e1f...","status":"ok","duration_s":79.3,"bytes":1519,"error":""}
```

Status values: `ok`, `failed`, `unsatisfiable`, `timeout`.

---

## Launcher / sandboxing

By default, each worker is launched as a plain subprocess (`julia ...`) sharing
the caller's environment.  The `--launcher TEMPLATE` flag lets you wrap the
worker in an arbitrary command (Docker, Singularity, firejail, etc.) by
providing a shell-style template with placeholders:

| Placeholder | Expanded to |
|-------------|-------------|
| `{cmd}` | the inner worker command (`julia … worker.jl …`), spliced verbatim |
| `{depot}` | absolute path to the shared depot |
| `{store}` | absolute path to the store root |
| `{env}` | absolute path to this worker's temp project (the `--project` dir) |
| `{jwroot}` | path to the JuliaWorkspaces `src/` root |

Example (Docker, CI matrix shard 3 of 16):

```
jwcloudindex --per-break --store ./symbolstore \
  --shard 3/16 --jobs 8 \
  --launcher 'docker run --rm --network=pkg --memory=8g -v {depot}:/depot {cmd}'
```

### Threat model

Indexing is **not** read-only: `Pkg.add` → `instantiate` → `import` executes each
package's `deps/build.jl`, `__init__`, and precompile top-level code. A
registry-wide run therefore executes arbitrary code from thousands of
third-party packages, and the resulting caches are intended to be served to
other users — so the threat model is real (malicious/buggy build scripts,
filesystem damage, depot poisoning, exfiltration, runaway resource use).

The scaffolding does **not** manage containers itself (that would tie the core
to a runtime, complicate the single-machine path, and fight the shared-depot
optimization). Instead it exposes the launcher seam (above) so sandboxing is an
opt-in orchestration layer:

- **Default (host)**: workers run directly. Isolation is limited to the
  per-version temp environment + the per-worker timeout. Fine for trusted/local
  runs.
- **Containerized (`--launcher`)**: wrap each worker in `docker`/`podman`/`nsjail`/
  `systemd-run`. Recommended pattern for registry-wide / CDN-bound runs:
  - pinned base image (exact Julia + system libs) for reproducibility;
  - cgroup limits (memory, pids, CPU) to contain OOM/fork-bombs the timeout can't;
  - restricted network (pkg server + registry only);
  - **depot mounting**: mount a pre-warmed registry/package cache **read-only**
    with a per-container writable overlay (or a fresh writable depot per shard).
    This preserves most download reuse while keeping isolation; a single shared
    *writable* depot across containers would reintroduce contention and defeat
    the isolation, so it is explicitly not the containerized default. When a
    shared writable depot *is* used (as `run_cloudindex_docker.sh` does), the
    worker serializes `Pkg` installs with an flock on the depot
    (`depot_lock.jl`) — Pkg deletes an existing version tree before replacing
    it, so unserialized concurrent installs of the same dependency corrupt
    each other. Precompilation stays unlocked: cache writes are rename-atomic.
- **Granularity** is the orchestrator's choice: per-package (max isolation, more
  setup) vs per-shard with a fresh depot (amortized setup, weaker inter-package
  isolation). `--shard` composes with either.

Building/publishing images and wiring a specific runtime are out of scope (left
to CI).

---

## Example invocations

```bash
# Newest version of every General package into ./symbolstore
jwcloudindex --store ./symbolstore --newest 1

# Audit what's missing for the newest-per-breaking-line policy, write a worklist
jwcloudindex --per-break --store ./symbolstore --report-missing --out missing.jsonl

# Sharded, sandboxed run (CI matrix shard 3 of 16)
jwcloudindex --per-break --store ./symbolstore \
  --shard 3/16 --jobs 8 \
  --launcher 'docker run --rm --network=pkg --memory=8g -v {depot}:/depot {cmd}'
```

---

## Verifying

**Always use a throwaway depot — never `~/.julia`.**

The manual smoke test indexes the `Example` package (tiny, dependency-light)
end-to-end:

```julia
# From the JuliaWorkspaces project root:
using JuliaWorkspaces
tmpdir = mktempdir(; prefix="jwci_")
JuliaWorkspaces.CloudIndexApp.cli_main([
    "--include", "^Example\$",
    "--newest", "1",
    "--jobs", "1",
    "--timeout", "900",
    "--depot", joinpath(tmpdir, "depot"),
    "--workdir", joinpath(tmpdir, "work"),
    "--store",   joinpath(tmpdir, "store"),
])
```

Or equivalently from the shell (substitute a real temp path):

```bash
JULIA_DEPOT_PATH=/tmp/jwci-depot julia --project=. -e '
  using JuliaWorkspaces
  JuliaWorkspaces.CloudIndexApp.cli_main(["--include","^Example\$","--newest","1",
      "--store","/tmp/jwci-store","--jobs","1","--timeout","900"])'
```

**Expected outcome:**

- Exit code `0`, output: `Done. 1 ok`
- `<store>/E/Example/7876af07-990d-54b4-ab0e-23690620f79a/<treehash>.jstore` exists
- File reads back via `JuliaWorkspaces.SymbolServer.CacheStore.read(open(path))`
  returning a `SymbolServer.Package` value
- The `.jstore` binary contains the literal string `PLACEHOLDER` (paths scrubbed)

**Observed result (run 2026-06-25 in this sandbox):**

The smoke test ran successfully end-to-end:

- `Example@0.5.5` (uuid `7876af07-990d-54b4-ab0e-23690620f79a`) was indexed in ~79 s.
- Store path produced: `E/Example/7876af07-990d-54b4-ab0e-23690620f79a/e1f0e1a832ccd8e97d6d0348dec33ee139a5aeaf.jstore` (1 519 bytes)
- `CacheStore.read(io)` returned a `JuliaWorkspaces.SymbolServer.Package` with fields `(:name, :val, :uuid, :sha)`.
- `PLACEHOLDER` scrubbing confirmed: `occursin("PLACEHOLDER", read(path, String))` → `true`.
- JSONL log entry: `{"name":"Example","uuid":"7876af07-990d-54b4-ab0e-23690620f79a","version":"0.5.5","treehash":"e1f0e1a832ccd8e97d6d0348dec33ee139a5aeaf","status":"ok","duration_s":79.334,"bytes":1519,"error":""}`
