#!/usr/bin/env bash
#
# Seed a fresh remote from an existing, fully-computed store: package every
# .jstore into a v2 tar.gz artifact, derive the availability index from those
# artifacts and the failure tombstones from the store's .unavailable markers,
# then upload all three with Cache-Control. Carrying the tombstones forward
# stops the first incremental regen from re-attempting known failures.
#
# Env vars:
#   RCLONE_REMOTE  (required) rclone remote + bucket prefix, e.g. "r2:symbolcache"
#                  or ":local:/path/to/dir" for local testing.
#   WORK           scratch dir for the packaged tree (default: fresh mktemp).
#
# Usage: RCLONE_REMOTE=r2:symbolcache bash scripts/seed_symbolcache.sh STORE
#
# Requires: rclone, gzip, tar, find, sort, awk, comm.
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
source "$here/symbolcache_common.sh"

STORE="${1:?usage: seed_symbolcache.sh STORE}"; STORE="${STORE%/}"
REMOTE="${RCLONE_REMOTE:?RCLONE_REMOTE must be set}"
WORK="${WORK:-$(mktemp -d /tmp/seed_symbolcache.XXXXXX)}"
PFX="${STORE_PREFIX}"
STATE="$PFX/_state"

mkdir -p "$WORK"
echo "[seed] STORE=$STORE REMOTE=$REMOTE WORK=$WORK"

# Step 1: package the store into WORK/<PFX>/packages/**.tar.gz (one per .jstore).
bash "$here/package_symbolcache.sh" "$STORE" "$WORK"
PKGS="$WORK/${PFX}/packages"

# Step 2: derive the availability index from the packaged artifacts, and the
# tombstones from the store's .unavailable markers. Key = <uuid>/<stem> (the
# last two path components, extension stripped) in both cases. Same index
# derivation as reconcile, so the index and artifacts agree by construction.
idxdir="$WORK/idx_staging"; mkdir -p "$idxdir"
find "$PKGS" -name '*.tar.gz' \
    | awk -F/ '{s=$NF; sub(/\.tar\.gz$/, "", s); print $(NF-1) "/" s}' \
    | sort -u > "$idxdir/index.txt"
echo "[seed] index will have $(wc -l < "$idxdir/index.txt") entries"
tar -czf "$WORK/index.tar.gz" -C "$idxdir" index.txt

# Tombstones come from the store's .unavailable markers (failed + unsatisfiable).
# Timeouts leave no marker, so they aren't seeded here; regen re-tombstones them
# from its results.jsonl, so the first incremental run re-attempts them once.
find "$STORE" -name '*.unavailable' \
    | awk -F/ '{s=$NF; sub(/\.unavailable$/, "", s); print $(NF-1) "/" s}' \
    | sort -u > "$WORK/tombstones_all.txt"
# A version can't be both cached and tombstoned; drop any key that has an
# artifact so the index and tombstones stay disjoint.
comm -23 "$WORK/tombstones_all.txt" "$idxdir/index.txt" > "$WORK/tombstones.txt"
echo "[seed] tombstones: $(wc -l < "$WORK/tombstones.txt") entries"

# Step 3: upload artifacts first (immutable) so the index never advertises a key
# whose artifact is not up yet, then the index (short TTL) and tombstones (private).
echo "[seed] uploading artifacts ..."
rclone copy "$PKGS" "${REMOTE}/${PFX}/packages" --transfers=32 --header-upload "$CC_IMMUTABLE"
echo "[seed] uploading index.tar.gz ..."
rclone copyto "$WORK/index.tar.gz" "${REMOTE}/${PFX}/index.tar.gz" --header-upload "$CC_INDEX"
echo "[seed] uploading tombstones.txt.gz ..."
gzip -c "$WORK/tombstones.txt" | rclone rcat "${REMOTE}/${STATE}/tombstones.txt.gz" --header-upload "$CC_PRIVATE"
echo "[seed] done"
