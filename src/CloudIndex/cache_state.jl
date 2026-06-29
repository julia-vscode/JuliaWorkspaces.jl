# Cache-existence predicate shared by the driver's resume and the missing audit.

# Mirror of SymbolServer.get_cache_path's filename rule (tree-hash, '+' -> '_').
function cache_relpath(name::AbstractString, uuid::Base.UUID, tree_hash::AbstractString)
    fname = replace(string(tree_hash), '+' => '_')
    return String[
        string(uppercase(string(name)[1])),
        string(name),
        string(uuid),
        string(fname, ".jstore"),
    ]
end

# Tombstone for a version that failed to index (failed/unsatisfiable): same
# location as the cache but with a `.unavailable` extension. Resume treats it as
# done so a deterministic failure isn't retried every run. (Timeouts are NOT
# tombstoned — they may be transient.)
function tombstone_relpath(name::AbstractString, uuid::Base.UUID, tree_hash::AbstractString)
    rp = cache_relpath(name, uuid, tree_hash)
    rp[end] = string(first(splitext(rp[end])), ".unavailable")
    return rp
end

"""
    is_cached(pv, store_path) -> Bool

True when `pv` is already accounted for under `store_path` — either a successful
`.jstore` cache or a `.unavailable` failure tombstone exists for it.
"""
function is_cached(pv::PkgVersion, store_path)
    isfile(joinpath(store_path, cache_relpath(pv.name, pv.uuid, pv.tree_hash)...)) && return true
    isfile(joinpath(store_path, tombstone_relpath(pv.name, pv.uuid, pv.tree_hash)...)) && return true
    return false
end

"""
    find_missing(rows, store_path) -> Vector{PkgVersion}

The subset of `rows` not yet accounted for (no `.jstore` and no `.unavailable`).
Used both as the post-resume worklist and by `--report-missing`.
"""
find_missing(rows::Vector{PkgVersion}, store_path) =
    filter(pv -> !is_cached(pv, store_path), rows)
