# Shared symbol-cache layout constants, sourced by the *_symbolcache.sh scripts.
# STORE_VERSION is the "vN" path element under store/. Bump here when the hosted
# layout changes. Keep in sync with CACHE_STORE_VERSION in
# shared/symbolserver/utils.jl (the Julia copy).
STORE_VERSION="${SYMBOLCACHE_STORE_VERSION:-v2}"
STORE_PREFIX="store/${STORE_VERSION}"
