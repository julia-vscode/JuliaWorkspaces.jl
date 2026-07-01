#!/usr/bin/env bash
#
# Stateless symbol-cache regeneration driver.
#
# Env vars:
#   RCLONE_REMOTE  (required) rclone remote + bucket prefix, e.g. "r2:symbolcache"
#                  or ":local:/path/to/dir" for local testing.
#   MODE           incremental (default) | full
#   WORK           scratch dir (default: fresh mktemp)
#   SWEEP_CMD      override the sweep orchestrator (default: bash <scriptdir>/run_cloudindex_docker.sh)
#
# Any positional args ($@) are forwarded verbatim to the sweep command
# (e.g. --newest 3 --per-break --shard 0/100).
#
# Requires: rclone, jwcloudindex (via julia --project), gzip, tar.
# Single-flight is the scheduler's responsibility (Actions concurrency: / flock).
# No lock object is stored or checked.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REMOTE="${RCLONE_REMOTE:?RCLONE_REMOTE must be set}"
MODE="${MODE:-incremental}"
WORK="${WORK:-$(mktemp -d /tmp/regen_symbolcache.XXXXXX)}"
SWEEP_CMD="${SWEEP_CMD:-bash ${SCRIPT_DIR}/run_cloudindex_docker.sh}"
PKG="$(dirname "$SCRIPT_DIR")"  # package root == scripts/..

PFX="store/v2"
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
$SWEEP_CMD \
    --work "$sweepwork" \
    --done-set "$WORK/done.txt" \
    --out "$sweepwork/results.jsonl" \
    "$@"

echo "[regen] sweep complete"

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
    # Use awk to parse JSONL: extract status, uuid, treehash fields.
    # Fields are simple JSON strings with no nesting — safe to parse with awk/sed.
    awk '
        function extract(line, key,    pat, val) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*\"([^\"]+)\""
            if (match(line, pat)) {
                val = substr(line, RSTART, RLENGTH)
                sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", val)
                sub("\".*", "", val)
                return val
            }
            return ""
        }
        {
            status = extract($0, "status")
            if (status == "failed" || status == "unsatisfiable" || status == "timeout") {
                uuid = extract($0, "uuid")
                treehash = extract($0, "treehash")
                if (uuid != "" && treehash != "") {
                    # replace + with _ in treehash (per get_cache_path convention)
                    gsub(/\+/, "_", treehash)
                    print uuid "/" treehash
                }
            }
        }
    ' "$sweepwork/results.jsonl" | sort -u > "$WORK/new_tombstones.txt"
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
    bash "$SCRIPT_DIR/publish_symbolcache.sh" "$sweepwork/store" "$WORK/pub"
    rclone copy "$WORK/pub/store/v2/packages" "${REMOTE}/${PFX}/packages"
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
rclone copyto "$WORK/index_upload.tar.gz" "${REMOTE}/${PFX}/index.tar.gz"
echo "[regen] index.tar.gz uploaded ($(wc -l < "$WORK/index_new.txt") entries)"

# ---------------------------------------------------------------------------
# Step 7: Publish tombstones'
# ---------------------------------------------------------------------------

gzip -c "$WORK/tombstones_new.txt" | rclone rcat "${REMOTE}/${STATE}/tombstones.txt.gz"
echo "[regen] tombstones.txt.gz uploaded ($(wc -l < "$WORK/tombstones_new.txt") entries)"

echo "[regen] done"
