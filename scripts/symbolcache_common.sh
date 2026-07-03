# Shared symbol-cache layout constants, sourced by the *_symbolcache.sh scripts.
# STORE_VERSION is the "vN" path element under store/. Bump here when the hosted
# layout changes. Keep in sync with CACHE_STORE_VERSION in
# shared/symbolserver/utils.jl (the Julia copy).
STORE_VERSION="${SYMBOLCACHE_STORE_VERSION:-v2}"
STORE_PREFIX="store/${STORE_VERSION}"

# Cache-Control headers for uploads (rclone --header-upload). Immutable artifacts
# are content-addressed (tree-hash filenames) so they can cache forever; the index
# is mutable → short TTL; _state is private.
CC_IMMUTABLE="Cache-Control: public, max-age=31536000, immutable"
CC_INDEX="Cache-Control: public, max-age=300"
CC_PRIVATE="Cache-Control: no-store"
