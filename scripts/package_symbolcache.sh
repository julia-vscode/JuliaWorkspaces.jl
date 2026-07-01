#!/usr/bin/env bash
# Package a jwcloudindex store into the v2 hosting layout: one tar.gz per .jstore
# under OUT/store/v2/packages/. Packaging only — index generation is done by the
# caller via `jwcloudindex --emit-index` (regen builds a union index; the seed
# builds a full one), so this script does not build or upload an index.
# Usage: package_symbolcache.sh STORE OUT
set -euo pipefail
STORE=${1:?store dir}; STORE=${STORE%/}; OUT=${2:?out dir}
JOBS=$(nproc)
PKGS_OUT="$OUT/store/v2/packages"; mkdir -p "$PKGS_OUT"

# One tar.gz per .jstore (tarball contains just the .jstore, gzip).
export STORE PKGS_OUT
find "$STORE" -name '*.jstore' -print0 | xargs -0 -P"$JOBS" -n1 bash -c '
    set -euo pipefail
    f=$1; rel=${f#"$STORE"/}; dir=$(dirname "$rel"); base=$(basename "$f")
    dest="$PKGS_OUT/$dir"; mkdir -p "$dest"
    tar -czf "$dest/${base%.jstore}.tar.gz" -C "$STORE/$dir" "$base"
' _

echo "packaged $(find "$PKGS_OUT" -name '*.tar.gz' | wc -l) artifacts to $OUT/store/v2/packages"
