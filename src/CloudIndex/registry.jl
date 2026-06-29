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
function _julia_compat_for(compat, v::VersionNumber)
    spec = nothing
    for (range, entries) in compat
        v in range || continue
        js = get(entries, "julia", nothing)
        js === nothing && continue
        spec = spec === nothing ? js : intersect(spec, js)
    end
    return spec
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
        info = Pkg.Registry.registry_info(entry)
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
