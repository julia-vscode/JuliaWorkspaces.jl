#!/usr/bin/env bash
# Package a jwcloudindex store into the v2 hosting layout:
#   per-package tar.gz artifacts + an index.tar.gz, under OUT/store/v2/.
# Usage: publish_symbolcache.sh STORE OUT [PKG_DIR]
set -euo pipefail
STORE=${1:?store dir}; OUT=${2:?out dir}; PKG=${3:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}
JOBS=$(nproc)
PKGS_OUT="$OUT/store/v2/packages"; mkdir -p "$PKGS_OUT"

# 1. One tar.gz per .jstore (tarball contains just the .jstore, gzip).
export STORE PKGS_OUT
find "$STORE" -name '*.jstore' -print0 | xargs -0 -P"$JOBS" -n1 bash -c '
    set -euo pipefail
    f=$1; rel=${f#"$STORE"/}; dir=$(dirname "$rel"); base=$(basename "$f")
    dest="$PKGS_OUT/$dir"; mkdir -p "$dest"
    tar -czf "$dest/${base%.jstore}.tar.gz" -C "$STORE/$dir" "$base"
' _

# 2. index.tar.gz (contains index.txt) via the jwcloudindex CLI.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
julia --project="$PKG" -e 'using JuliaWorkspaces; exit(JuliaWorkspaces.CloudIndexApp.cli_main(ARGS))' \
    -- --store "$STORE" --emit-index "$tmp/index.txt"
tar -czf "$OUT/store/v2/index.tar.gz" -C "$tmp" index.txt
echo "published $(find "$PKGS_OUT" -name '*.tar.gz' | wc -l) artifacts + index to $OUT/store/v2"
