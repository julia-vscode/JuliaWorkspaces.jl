#!/usr/bin/env bash
#
# Stateless symbol-cache regeneration driver.
#
# Usage:
#   regen_symbolcache.sh --remote REMOTE [--mode incremental|full] [--work DIR]
#                        [--sweep-cmd CMD] [-- SWEEP_ARGS...]
#
#   --remote REMOTE   (required) rclone remote + bucket prefix, e.g.
#                     "r2:symbolcache" or ":local:/path/to/dir" for local testing.
#   --mode MODE       incremental (default) | full
#   --work DIR        scratch dir (default: fresh mktemp)
#   --sweep-cmd CMD   sweep orchestrator (default: bash <scriptdir>/run_cloudindex_docker.sh)
#
# Anything after `--` is forwarded verbatim to the sweep command
# (e.g. -- --newest 3 --per-break --shard 0/100).
#
# Requires: rclone, jwcloudindex (via julia --project), gzip, tar.
# Single-flight is the scheduler's responsibility (Actions concurrency: / flock).
# No lock object is stored or checked.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/symbolcache_common.sh"

usage() { cat <<'EOF'
Usage: regen_symbolcache.sh --remote REMOTE [--mode incremental|full] [--work DIR]
                            [--sweep-cmd CMD] [-- SWEEP_ARGS...]
  --remote REMOTE   (required) rclone remote + bucket prefix (e.g. r2:symbolcache)
  --mode MODE       incremental (default) | full
  --work DIR        scratch dir (default: fresh mktemp)
  --sweep-cmd CMD   sweep orchestrator (default: run_cloudindex_docker.sh)
  args after --     forwarded verbatim to the sweep command
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
REMOTE=""; MODE="incremental"; WORK=""; SWEEP_CMD=""
sweep_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)    REMOTE="$2"; shift 2 ;;
        --mode)      MODE="$2"; shift 2 ;;
        --work)      WORK="$2"; shift 2 ;;
        --sweep-cmd) SWEEP_CMD="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; sweep_args=("$@"); break ;;
        *)           echo "[regen] ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$REMOTE" ]] || { echo "[regen] ERROR: --remote is required" >&2; usage >&2; exit 2; }
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/regen_symbolcache.XXXXXX")}"
SWEEP_CMD="${SWEEP_CMD:-bash ${SCRIPT_DIR}/run_cloudindex_docker.sh}"
PKG="$(dirname "$SCRIPT_DIR")"  # package root == scripts/..

PFX="${STORE_PREFIX}"
STATE="$PFX/_state"

mkdir -p "$WORK"

echo "[regen] REMOTE=$REMOTE MODE=$MODE WORK=$WORK"

# ---------------------------------------------------------------------------
# Step 1: Download key-sets (small files; tolerate absence)
# ---------------------------------------------------------------------------

# Successes: index.tar.gz → index.txt
touch "$WORK/successes.txt"
if rclone copyto "${REMOTE}/${PFX}/index.tar.gz" "$WORK/index.tar.gz" 2>/dev/null; then
    tar -xzO -f "$WORK/index.tar.gz" index.txt > "$WORK/successes.txt" || true
else
    echo "[regen] no existing index.tar.gz (first run or empty remote)"
fi

# Tombstones: tombstones.txt.gz → tombstones.txt
touch "$WORK/tombstones.txt"
if rclone copyto "${REMOTE}/${STATE}/tombstones.txt.gz" "$WORK/tombstones.txt.gz" 2>/dev/null; then
    gzip -dc "$WORK/tombstones.txt.gz" > "$WORK/tombstones.txt" || true
else
    echo "[regen] no existing tombstones.txt.gz (first run or empty remote)"
fi

# ---------------------------------------------------------------------------
# Step 2: Build done.txt (keys to skip)
# ---------------------------------------------------------------------------

if [[ "$MODE" == "incremental" ]]; then
    # Skip both successes and tombstones
    sort -u "$WORK/successes.txt" "$WORK/tombstones.txt" > "$WORK/done.txt"
elif [[ "$MODE" == "full" ]]; then
    # Only skip successes; retry tombstoned versions
    sort -u "$WORK/successes.txt" > "$WORK/done.txt"
else
    echo "[regen] ERROR: MODE must be 'incremental' or 'full', got '$MODE'" >&2
    exit 1
fi

echo "[regen] done.txt has $(wc -l < "$WORK/done.txt") entries (mode=$MODE)"

# ---------------------------------------------------------------------------
# Step 3: Run the sweep
# ---------------------------------------------------------------------------

sweepwork="$WORK/sweep"
mkdir -p "$sweepwork"

echo "[regen] running sweep: $SWEEP_CMD --work $sweepwork ..."
sweep_status=0
$SWEEP_CMD \
    --work "$sweepwork" \
    --done-set "$WORK/done.txt" \
    --out "$sweepwork/results.jsonl" \
    ${sweep_args[@]+"${sweep_args[@]}"} || sweep_status=$?

# The driver exits 1 when any version ended failed/timeout. Those are
# expected outcomes -- step 4d tombstones them -- so continue and publish the
# results we do have; aborting here used to throw away every successful
# result in the run over a single flaky version. Anything else nonzero
# (interrupt=130, usage errors, crashes) still aborts before touching the
# bucket, since results.jsonl may be partial or missing.
if (( sweep_status == 1 )); then
    echo "[regen] sweep reported failed/timeout versions (exit 1); continuing -- they are tombstoned below"
elif (( sweep_status != 0 )); then
    echo "[regen] ERROR: sweep exited with status $sweep_status; aborting without uploading" >&2
    exit "$sweep_status"
fi

echo "[regen] sweep complete"

# Surface systemic failures directly in the CI log: per-status counts plus the
# terse per-worker error line for a few samples (full stderr per version stays
# in results.jsonl).
if [[ -f "$sweepwork/results.jsonl" ]]; then
    echo "[regen] sweep status counts:"
    jq -r '.status' "$sweepwork/results.jsonl" | sort | uniq -c | sort -rn | sed 's/^/[regen]   /'
    # Best-effort: tolerate records without name/version/error and the SIGPIPE
    # jq takes when head stops reading (exit 141 would otherwise kill the script).
    samples=$(jq -r 'select(.status != "ok" and .status != "cancelled")
        | "\(.name // "?")@\(.version // "?") [\(.status)]: " +
          (((.error // "") | split("\n") | (map(select(startswith("jwcloudindex-worker:"))) + map(select(. != "")))[0]) // "")' \
        "$sweepwork/results.jsonl" 2>/dev/null | head -5 | cut -c1-300 || true)
    if [[ -n "$samples" ]]; then
        echo "[regen] sample failures (first 5, see results.jsonl for full errors):"
        sed 's/^/[regen]   /' <<< "$samples"
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Compute new lists
# ---------------------------------------------------------------------------

# 4a. Index of THIS run's store (every .jstore in the new store).
#     Even if the store is empty this should produce an empty file.
touch "$WORK/new_index.txt"
if find "$sweepwork/store" -name '*.jstore' -print -quit 2>/dev/null | grep -q .; then
    julia --project="$PKG" \
        -e 'using JuliaWorkspaces; exit(JuliaWorkspaces.CloudIndexApp.cli_main(ARGS))' \
        -- --store "$sweepwork/store" --emit-index "$WORK/new_index.txt"
fi

# 4b. Published index = union of previous successes + this run's store (never shrinks).
sort -u "$WORK/successes.txt" "$WORK/new_index.txt" > "$WORK/index_new.txt"
echo "[regen] published index will have $(wc -l < "$WORK/index_new.txt") entries"

# 4c. New tombstone keys from this run's results.jsonl.
#     Key = <uuid>/<treehash with + → _>
#     Status in {failed, unsatisfiable, timeout} → tombstone; cancelled is retryable → excluded.
touch "$WORK/new_tombstones.txt"
if [[ -f "$sweepwork/results.jsonl" ]]; then
    # Parse the JSONL with jq. failed/unsatisfiable/timeout → tombstone (cancelled
    # is retryable → excluded); key = <uuid>/<treehash with + → _>.
    jq -r 'select(.status == "failed" or .status == "unsatisfiable" or .status == "timeout")
           | .uuid + "/" + (.treehash | gsub("\\+"; "_"))' \
        "$sweepwork/results.jsonl" | sort -u > "$WORK/new_tombstones.txt"
fi
echo "[regen] this run produced $(wc -l < "$WORK/new_tombstones.txt") tombstone candidates"

# 4d. tombstones' = (MODE=incremental ? old ∪ new : new) minus any key in index'.
#     A version that now has an artifact is no longer a tombstone.
if [[ "$MODE" == "incremental" ]]; then
    sort -u "$WORK/tombstones.txt" "$WORK/new_tombstones.txt" > "$WORK/tombstones_combined.txt"
else
    cp "$WORK/new_tombstones.txt" "$WORK/tombstones_combined.txt"
fi

# Subtract keys present in index_new.txt (graduated from tombstone to artifact).
comm -23 \
    <(sort "$WORK/tombstones_combined.txt") \
    <(sort "$WORK/index_new.txt") \
    > "$WORK/tombstones_new.txt"
echo "[regen] final tombstone count: $(wc -l < "$WORK/tombstones_new.txt")"

# ---------------------------------------------------------------------------
# Step 5: Upload artifacts FIRST (additive, immutable)
# ---------------------------------------------------------------------------

if find "$sweepwork/store" -name '*.jstore' -print -quit 2>/dev/null | grep -q .; then
    echo "[regen] packaging and uploading artifacts..."
    mkdir -p "$WORK/pub"
    bash "$SCRIPT_DIR/package_symbolcache.sh" "$sweepwork/store" "$WORK/pub"
    rclone copy "$WORK/pub/${STORE_PREFIX}/packages" "${REMOTE}/${PFX}/packages" --header-upload "$CC_IMMUTABLE"
    echo "[regen] artifacts uploaded"
else
    echo "[regen] no new artifacts to upload"
fi

# ---------------------------------------------------------------------------
# Step 6: Publish index' (after artifacts)
# ---------------------------------------------------------------------------

# Build index.tar.gz containing index.txt (the union list).
idxdir="$WORK/idx_staging"
mkdir -p "$idxdir"
cp "$WORK/index_new.txt" "$idxdir/index.txt"
tar -czf "$WORK/index_upload.tar.gz" -C "$idxdir" index.txt
rclone copyto "$WORK/index_upload.tar.gz" "${REMOTE}/${PFX}/index.tar.gz" --header-upload "$CC_INDEX"
echo "[regen] index.tar.gz uploaded ($(wc -l < "$WORK/index_new.txt") entries)"

# ---------------------------------------------------------------------------
# Step 7: Publish tombstones'
# ---------------------------------------------------------------------------

gzip -c "$WORK/tombstones_new.txt" | rclone rcat "${REMOTE}/${STATE}/tombstones.txt.gz" --header-upload "$CC_PRIVATE"
echo "[regen] tombstones.txt.gz uploaded ($(wc -l < "$WORK/tombstones_new.txt") entries)"

echo "[regen] done"
