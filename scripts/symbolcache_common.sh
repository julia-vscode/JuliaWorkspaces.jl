# Shared symbol-cache layout constants, sourced by the *_symbolcache.sh scripts.
# STORE_VERSION is the "vN" path element under store/. This is the shell copy of
# the Julia CACHE_FORMAT_VERSION (shared/symbolserver/utils.jl) — the one place
# that must be bumped by hand to match "v<CACHE_FORMAT_VERSION>".
STORE_VERSION="${SYMBOLCACHE_STORE_VERSION:-v3}"
STORE_PREFIX="store/${STORE_VERSION}"

# Cache-Control headers for uploads (rclone --header-upload). Immutable artifacts
# are content-addressed (tree-hash filenames) so they can cache forever; the index
# is mutable → short TTL; _state is private.
CC_IMMUTABLE="Cache-Control: public, max-age=31536000, immutable"
CC_INDEX="Cache-Control: public, max-age=300"
CC_PRIVATE="Cache-Control: no-store"
