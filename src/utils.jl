@inline function safe_getproperty(x, s::Symbol)
    if isnothing(x)
        return nothing
    else
        return getproperty(x, s)
    end
end

# Cache of `Pkg.Types.stdlib_infos()` (it rebuilds a dict per call); a benign race
# between the reactor prep task and the Salsa loop just recomputes the same table.
const _STDLIB_INFOS_CACHE = Ref{Any}(nothing)

# The version a stdlib UUID's `.jstore` is keyed by — matching the indexer child,
# whose live `Pkg.Types.Context()` resolves any stdlib to its bundled identity
# regardless of what the manifest pins. `nothing` when `uuid` is not a stdlib (or
# the `Pkg.Types` internals are unavailable), so callers fall through to the
# manifest's own key. Callers must gate on the entry having a `version` — a
# versionless-in-manifest stdlib still gets a concrete version here.
function _stdlib_cache_version(uuid::UUID)
    (isdefined(Pkg.Types, :is_stdlib) && isdefined(Pkg.Types, :stdlib_infos)) || return nothing
    Pkg.Types.is_stdlib(uuid) || return nothing
    infos = _STDLIB_INFOS_CACHE[]
    if infos === nothing
        infos = Pkg.Types.stdlib_infos()
        _STDLIB_INFOS_CACHE[] = infos
    end
    info = get(infos, uuid, nothing)
    # is_stdlib ⊆ keys(stdlib_infos) on supported Julias, so this fallback is
    # effectively unreachable; VERSION keeps it consistent with get_cache_path.
    info === nothing && return VERSION
    return something(info.version, VERSION)
end
