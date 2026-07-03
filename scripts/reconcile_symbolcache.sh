#!/usr/bin/env bash
#
# Periodic full reconcile: treat the bucket's artifacts as source of truth —
# rebuild the index from the artifacts present, drop tombstones that now have an
# artifact. Never mutates artifacts. No lock (single-flight is the scheduler's job).
#
# Usage:
#   reconcile_symbolcache.sh --remote REMOTE [--work DIR]
#
#   --remote REMOTE   (required) rclone remote + bucket prefix, e.g.
#                     "r2:symbolcache" or ":local:/path/to/dir" for local testing.
#   --work DIR        scratch dir (default: fresh mktemp)
#
# Requires: rclone, gzip, tar, sort, awk, comm.
# Single-flight is the scheduler's responsibility (Actions concurrency: / flock).
# No lock object is stored or checked.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/symbolcache_common.sh"

usage() { cat <<'EOF'
Usage: reconcile_symbolcache.sh --remote REMOTE [--work DIR]
  --remote REMOTE   (required) rclone remote + bucket prefix (e.g. r2:symbolcache)
  --work DIR        scratch dir (default: fresh mktemp)
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
REMOTE=""; WORK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)  REMOTE="$2"; shift 2 ;;
        --work)    WORK="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "[reconcile] ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$REMOTE" ]] || { echo "[reconcile] ERROR: --remote is required" >&2; usage >&2; exit 2; }
WORK="${WORK:-$(mktemp -d /tmp/reconcile_symbolcache.XXXXXX)}"

PFX="${STORE_PREFIX}"
STATE="$PFX/_state"

mkdir -p "$WORK"

echo "[reconcile] REMOTE=$REMOTE WORK=$WORK"

# ---------------------------------------------------------------------------
# Step 1: List authoritative artifacts
# ---------------------------------------------------------------------------
# Layer 1 safety: separate rclone exit status from grep's.
# rclone lsf writes to raw_listing.txt with stderr captured separately.
# A genuinely absent packages/ prefix (first run, S3/R2 returns exit 0 with
# empty output; local backend returns exit 3 "directory not found") is treated
# as empty — that is an expected condition.  Any other rclone error (auth,
# network, wrong remote config) is a hard failure that aborts under
# set -euo pipefail to prevent rebuilding with a bogus empty list.
# grep on a valid-but-empty listing exits 1 — tolerated with || true on the
# filter-only step.
echo "[reconcile] listing artifacts under $REMOTE/$PFX/packages ..."
set +e
rclone lsf -R --files-only "${REMOTE}/${PFX}/packages" \
    > "$WORK/raw_listing.txt" \
    2> "$WORK/rclone_lsf_err.txt"
rclone_rc=$?
set -e
if [[ $rclone_rc -ne 0 ]]; then
    err_text=$(cat "$WORK/rclone_lsf_err.txt")
    # Tolerate "directory not found" / "object not found" listing errors — these
    # occur on the local backend when packages/ does not yet exist (first run).
    # Real object stores (S3/R2) return exit 0 with empty output for absent
    # prefixes, so this branch is mainly a local-backend / CI safety valve.
    # Do NOT match generic "not found" which also appears in config errors
    # ("didn't find section in config file").
    if echo "$err_text" | grep -qE "error listing:.*not found|error in ListJSON:.*not found|NoSuchKey|NoSuchBucket"; then
        echo "[reconcile] packages prefix absent (directory not found) — treating as empty"
        : > "$WORK/raw_listing.txt"
    else
        echo "[reconcile] ERROR: rclone lsf failed (exit $rclone_rc):" >&2
        echo "$err_text" >&2
        exit $rclone_rc
    fi
fi
grep '\.tar\.gz$' "$WORK/raw_listing.txt" \
    | awk -F/ '{s=$NF; sub(/\.tar\.gz$/, "", s); print $(NF-1) "/" s}' \
    | sort -u > "$WORK/artifacts.txt" || true

artifact_count=$(wc -l < "$WORK/artifacts.txt")
echo "[reconcile] found $artifact_count artifact(s)"

# Layer 2 safety: if derived artifact count is 0 but an existing index already
# has entries, abort rather than wipe.  Preserves the genuine first-run /
# truly-empty case: zero artifacts AND no/empty existing index → proceed.
if [[ "$artifact_count" -eq 0 ]]; then
    existing=$(rclone cat "${REMOTE}/${PFX}/index.tar.gz" 2>/dev/null \
        | gzip -dc 2>/dev/null | grep -c . || true)
    if [[ "${existing:-0}" -gt 0 ]]; then
        echo "[reconcile] ERROR: artifact list empty but existing index has $existing entries — aborting to avoid wiping the index" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Rebuild and publish the index from artifacts.txt
# ---------------------------------------------------------------------------
# The availability index is authoritative: it is exactly the set of keys
# for which an artifact exists in the bucket right now.
idxdir="$WORK/idx_staging"
mkdir -p "$idxdir"
cp "$WORK/artifacts.txt" "$idxdir/index.txt"

tar -czf "$WORK/index.tar.gz" -C "$idxdir" index.txt

echo "[reconcile] uploading rebuilt index.tar.gz ($artifact_count entries) ..."
rclone copyto "$WORK/index.tar.gz" "${REMOTE}/${PFX}/index.tar.gz" --header-upload "$CC_INDEX"
echo "[reconcile] index.tar.gz uploaded"

# ---------------------------------------------------------------------------
# Step 3: Reconcile tombstones
# ---------------------------------------------------------------------------
# Download current tombstones (tolerate absence).
touch "$WORK/tombstones.txt"
if rclone copyto "${REMOTE}/${STATE}/tombstones.txt.gz" "$WORK/tombstones_dl.txt.gz" 2>/dev/null; then
    gzip -dc "$WORK/tombstones_dl.txt.gz" > "$WORK/tombstones.txt" \
        || { echo "[reconcile] WARNING: tombstones decompress failed; treating as empty" >&2; }
else
    echo "[reconcile] no existing tombstones.txt.gz (first run or empty remote)"
fi

tombstone_count=$(wc -l < "$WORK/tombstones.txt")
echo "[reconcile] downloaded $tombstone_count tombstone(s)"

# Drop any tombstone key that now has an artifact (both files are sorted).
# comm -23: lines only in file1 (tombstones) that are NOT in file2 (artifacts).
comm -23 \
    <(sort "$WORK/tombstones.txt") \
    <(sort "$WORK/artifacts.txt") \
    > "$WORK/tombstones_new.txt"

new_tombstone_count=$(wc -l < "$WORK/tombstones_new.txt")
dropped=$(( tombstone_count - new_tombstone_count ))
echo "[reconcile] reconciled tombstones: $new_tombstone_count kept, $dropped dropped (had artifact)"

# Upload reconciled tombstones.
gzip -c "$WORK/tombstones_new.txt" | rclone rcat "${REMOTE}/${STATE}/tombstones.txt.gz" --header-upload "$CC_PRIVATE"
echo "[reconcile] tombstones.txt.gz uploaded"

echo "[reconcile] done"
