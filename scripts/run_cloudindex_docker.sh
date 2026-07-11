#!/usr/bin/env bash
#
# Containerized registry-wide symbol-cache generation (jwcloudindex).
#
# Each per-(package@version) worker runs inside a Docker container with cgroup
# limits and its own writable depot, while one pre-downloaded General registry
# is shared read-only across all workers. Workers use the image's own Julia
# (the driver's worker command runs the bare name `julia`, resolved on the
# container's PATH), so nothing from the host is mounted except the repo
# (read-only) and the work dirs.
#
# Requirements:
#   - Docker access (be in the `docker` group, or invoke via sudo)
#   - `julia` (e.g. juliaup) on PATH
# First run pulls the base image and downloads the General registry.
#
# Usage:
#   scripts/run_cloudindex_docker.sh [--image IMG] [--work DIR] [jwcloudindex flags...]
#
# Two options are handled by this script (orchestration concerns):
#   --image IMG   base image providing Julia's runtime libs (default: julia:1.12)
#   --work  DIR   work root for store/depot/registry/logs   (default: fresh mktemp)
#
# Everything else is forwarded verbatim to jwcloudindex — e.g. --include,
# --newest, --per-break, --all-versions, --jobs, --timeout, --exclude,
# --julia-version, --include-yanked/--include-jll, --shard, --report-missing,
# --dry-run, --out. (--store/--depot/--workdir/--registry/--launcher are
# managed by this script; use --work to relocate them.)
#
# Defaults injected only when you don't pass them:
#   - a bare run (no jwcloudindex flags) indexes a small demo set
#     (Example, Crayons, Glob) rather than all of General;
#   - --jobs 2 and --timeout 1200 (container-friendly) if unspecified.
#
# Examples:
#   scripts/run_cloudindex_docker.sh
#   scripts/run_cloudindex_docker.sh --include '^DataFrames$' --newest 3 --per-break
#   scripts/run_cloudindex_docker.sh --jobs 8 --shard 0/16
#   scripts/run_cloudindex_docker.sh --work /scratch/jwci --include '^Plots$'
#
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=$(dirname "$SCRIPT_DIR")          # package root == scripts/..
REPO="$PKG"

IMAGE=julia:1.12
WORK=
PASS=()                               # forwarded to jwcloudindex
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --work)  WORK="$2";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) PASS+=("$1"); shift ;;
    esac
done

command -v julia  >/dev/null || { echo "julia not found on PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found on PATH" >&2; exit 1; }

WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/jwci.XXXXXX")}
mkdir -p "$WORK/store" "$WORK/depot"

# Inject defaults only when the user didn't supply them.
has() { local f; for f in ${PASS[@]+"${PASS[@]}"}; do [[ "$f" == "$1" ]] && return 0; done; return 1; }
(( ${#PASS[@]} )) || PASS=(--include '^(Example|Crayons|Glob)$')
has --jobs    || PASS+=(--jobs 2)
has --timeout || PASS+=(--timeout 1200)

# 1. Pre-download General ONCE into a read-only-able registry depot (unpacked, so
#    both the driver's RegistryInstance and the containers' Pkg can read it).
REGDEPOT="$WORK/regdepot"
mkdir -p "$REGDEPOT"
# Trailing ':' appends the default depots, so this pre-warm reuses the host's
# precompiled Pkg/artifacts instead of recompiling Pkg from scratch in the empty
# registry depot. General is still added to REGDEPOT (the first, writable entry).
JULIA_DEPOT_PATH="$REGDEPOT:" JULIA_PKG_UNPACK_REGISTRY=true \
  julia --startup-file=no -e 'using Pkg; Pkg.Registry.add("General")'
REG="$REGDEPOT/registries/General"
test -f "$REG/Registry.toml" || { echo "registry download failed" >&2; exit 1; }

# 2. Preflight: one throwaway container with the same mounts, checking the
#    things every worker depends on. Each failure mode here otherwise surfaces
#    as a uniform per-version failure (usually "unsatisfiable") with the real
#    error buried in results.jsonl:
#      - -v sources must be visible to the DOCKER DAEMON, not just this shell.
#        With docker-in-docker (e.g. Kubernetes-based CI runners) a host path
#        like /tmp/... silently mounts empty unless it lives on a volume shared
#        with the daemon — put --work / TMPDIR on such a volume.
#      - writes to the depot mount must round-trip back to the host, or every
#        cache the sweep produces is silently lost.
#      - DNS + package-server egress, or Pkg.add can download nothing.
echo "[preflight] verifying worker-container mounts and network ..."
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME="$WORK/depot" \
  -v "$REPO:$REPO:ro" \
  -v "$REGDEPOT:$REGDEPOT:ro" \
  -v "$WORK/depot:$WORK/depot" \
  "$IMAGE" julia --startup-file=no -e '
    using Sockets
    import Downloads
    reg, repo, depot = ARGS
    fail = false
    function check(ok::Bool, what, hint)
        println(stderr, "[preflight] ", ok ? "ok   " : "FAIL ", what, ok ? "" : string(" — ", hint))
        ok || (global fail = true)
        return ok
    end
    check(isfile(joinpath(reg, "registries", "General", "Registry.toml")),
          "registry mount ($reg)",
          "empty inside the container; the -v source is not visible to the docker daemon")
    check(isfile(joinpath(repo, "src", "CloudIndex", "worker.jl")),
          "repo mount ($repo)",
          "worker.jl is not visible inside the container")
    write(joinpath(depot, "preflight-roundtrip"), "1")
    dns = check((try; getaddrinfo("pkg.julialang.org"); true; catch; false; end),
          "DNS lookup of pkg.julialang.org",
          "name resolution fails inside worker containers; Pkg.add cannot download anything")
    dns && check((try; Downloads.download("https://pkg.julialang.org/registries", devnull; timeout = 30); true; catch; false; end),
          "HTTPS fetch from pkg.julialang.org",
          "DNS works but HTTPS egress from worker containers fails")
    exit(fail ? 1 : 0)
' "$REGDEPOT" "$REPO" "$WORK/depot" \
  || { echo "[preflight] worker-container environment is broken — aborting before the sweep (it would fail and tombstone every version)" >&2; exit 1; }
if [[ -f "$WORK/depot/preflight-roundtrip" ]]; then
    rm -f "$WORK/depot/preflight-roundtrip"
    echo "[preflight] ok    depot mount round-trip ($WORK/depot)"
else
    echo "[preflight] FAIL  depot mount round-trip ($WORK/depot) — files written in the container do not appear on the host, so caches would be silently lost (docker-in-docker with an unshared --work path?)" >&2
    exit 1
fi

# 3. Per-worker container launcher. Workers run the image's own Julia (the
#    driver's worker command is the bare name `julia`, resolved on PATH), so
#    only the repo (read-only) and the work dirs are mounted. JULIA_DEPOT_PATH is
#    {depot} (writable: installs land here) : the read-only registry depot : and a
#    trailing ':' that appends the image's default depots — so workers reuse the
#    image's *built-in* precompiled Pkg/stdlib cache files instead of recompiling
#    Pkg from scratch every container (~20s/worker otherwise).
#    Placeholders {cmd}/{depot}/{store}/{env} are filled per worker by the driver.
#    JULIA_HEAP_SIZE_HINT is forwarded name-only: docker sets it in the worker
#    only when the caller's environment defines it. Without it, workers whose
#    --memory cap doesn't bind (rootless / DinD without cgroup delegation) size
#    their GC against the whole host and balloon until something OOMs; a hint
#    below the 4g cap (e.g. 3G) keeps them self-limiting either way.
LAUNCHER="docker run --rm \
  --memory=4g --pids-limit=512 --cpus=2 \
  --user $(id -u):$(id -g) \
  -e JULIA_DEPOT_PATH={depot}:$REGDEPOT: \
  -e HOME={depot} \
  -e JULIA_HEAP_SIZE_HINT \
  -v $REPO:$REPO:ro \
  -v $REGDEPOT:$REGDEPOT:ro \
  -v {depot}:{depot} -v {store}:{store} -v {env}:{env} \
  $IMAGE {cmd}"

# 4. Drive the indexer. ARGS[1..3] = work, registry, launcher; ARGS[4:] = the
#    forwarded jwcloudindex flags. Script-managed flags are appended last so they
#    win over any duplicates in the forwarded set (parse_args is last-wins).
#    Workers use the image's Julia: the driver's default julia_exe is the bare
#    name `julia`, which resolves to the only julia on PATH inside the container.
julia --project="$PKG" -e '
    using JuliaWorkspaces
    work, reg, launcher = ARGS[1], ARGS[2], ARGS[3]
    args = String[ARGS[4:end]...,
        "--registry", reg,
        "--store",    joinpath(work, "store"),
        "--depot",    joinpath(work, "depot"),
        "--workdir",  work,
        "--launcher", launcher,
    ]
    exit(JuliaWorkspaces.CloudIndexApp.cli_main(args))
' "$WORK" "$REG" "$LAUNCHER" ${PASS[@]+"${PASS[@]}"}

echo "--- caches ---"; find "$WORK/store" -name '*.jstore'
echo "--- log ---";    cat "$WORK/results.jsonl" 2>/dev/null || true
echo "WORK=$WORK"
