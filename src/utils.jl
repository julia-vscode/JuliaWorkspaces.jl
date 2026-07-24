@inline function safe_getproperty(x, s::Symbol)
    if isnothing(x)
        return nothing
    else
        return getproperty(x, s)
    end
end

# The version a stdlib UUID's `.jstore` is keyed by — matching the indexer child,
# whose live `Pkg.Types.Context()` resolves any stdlib to its bundled identity
# regardless of what the manifest pins. `nothing` when `uuid` is not a stdlib (or
# `Pkg.Types` cannot classify it), so callers fall through to the manifest's own
# key. Callers must gate on the entry having a `version` — a versionless-in-manifest
# stdlib still gets a concrete version here. Shares the cross-Julia stdlib-version
# lookup with the child's `get_cache_path`, so the two always agree on the key.
function _stdlib_cache_version(uuid::UUID)
    isdefined(Pkg.Types, :is_stdlib) || return nothing
    Pkg.Types.is_stdlib(uuid) || return nothing
    return something(SymbolServer._stdlib_bundled_version(uuid), VERSION)
end
