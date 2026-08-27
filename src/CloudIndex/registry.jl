# Registry enumeration: read a registry into a flat list of PkgVersion rows.

struct PkgVersion
    name::String
    uuid::Base.UUID
    version::VersionNumber
    tree_hash::String
    yanked::Bool
    julia_compat::Union{Nothing,Pkg.Versions.VersionSpec}
end

"""
    general_registry_path() -> Union{String,Nothing}

Path of the installed General registry, or `nothing` if not found.
"""
function general_registry_path()
    for reg in Pkg.Registry.reachable_registries()
        reg.name == "General" && return reg.path
    end
    return nothing
end

# julia compat applicable to version `v`: intersection of every `julia` VersionSpec
# whose VersionRange key contains `v`. `nothing` when no julia compat is declared.
# Julia 1.13 rekeyed the inner `PkgInfo.compat` dicts from package *name* to package `UUID`.
# Dispatch on the key type rather than on a version number — the dict itself says which
# registry format we were handed.
_julia_compat_entry(entries::AbstractDict{String}) = get(entries, "julia", nothing)
_julia_compat_entry(entries::AbstractDict{Base.UUID}) =
    get(entries, Pkg.Registry.JULIA_UUID, nothing)

function _julia_compat_for(compat, v::VersionNumber)
    spec = nothing
    for (range, entries) in compat
        v in range || continue
        js = _julia_compat_entry(entries)
        js === nothing && continue
        spec = spec === nothing ? js : intersect(spec, js)
    end
    return spec
end

# Julia 1.13 changed `Pkg.Registry.registry_info` from `(::PkgEntry)` to
# `(::RegistryInstance, ::PkgEntry)`, and there is exactly one method either way, so calling
# the old form is a hard MethodError rather than a deprecation. Dispatch on what the running
# Pkg actually provides instead of on a version number: this is a non-public Pkg API and the
# signature has already moved once.
@static if hasmethod(Pkg.Registry.registry_info,
                     Tuple{Pkg.Registry.RegistryInstance,Pkg.Registry.PkgEntry})
    _registry_info(reg, entry) = Pkg.Registry.registry_info(reg, entry)
else
    _registry_info(_reg, entry) = Pkg.Registry.registry_info(entry)
end

"""
    enumerate_registry(registry_path) -> Vector{PkgVersion}

Read every package/version in the registry at `registry_path` into `PkgVersion`
rows (one per version). Pure read; does not touch the network or install anything.
"""
function enumerate_registry(registry_path::AbstractString)
    reg = Pkg.Registry.RegistryInstance(String(registry_path))
    out = PkgVersion[]
    for (uuid, entry) in reg.pkgs
        info = _registry_info(reg, entry)
        for (v, vinfo) in info.version_info
            push!(out, PkgVersion(
                entry.name,
                uuid,
                v,
                string(vinfo.git_tree_sha1),
                vinfo.yanked,
                _julia_compat_for(info.compat, v),
            ))
        end
    end
    return out
end
