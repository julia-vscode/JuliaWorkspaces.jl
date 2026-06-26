# Filtering of the enumerated PkgVersion rows.

struct FilterSpec
    include::Vector{Regex}
    exclude::Vector{Regex}
    skip_yanked::Bool
    skip_jll::Bool
    julia_version::Union{Nothing,VersionNumber}
    n::Int                # keep the newest n versions (per package, or per breaking line)
    per_break::Bool       # apply `n` within each breaking line instead of overall
    all_versions::Bool    # keep every version (overrides n / per_break)
end

function FilterSpec(; include::Vector{Regex}=Regex[], exclude::Vector{Regex}=Regex[],
                    skip_yanked::Bool=true, skip_jll::Bool=true,
                    julia_version::Union{Nothing,VersionNumber}=nothing,
                    n::Int=1, per_break::Bool=false, all_versions::Bool=false)
    n >= 1 || throw(ArgumentError("n must be >= 1, got $n"))
    return FilterSpec(include, exclude, skip_yanked, skip_jll, julia_version,
                      n, per_break, all_versions)
end

# Breaking "line": major for >=1.0, (0, minor) for 0.x. Two versions share a line
# iff a change between them would be non-breaking under SemVer.
breaking_key(v::VersionNumber) = v.major == 0 ? (0, Int(v.minor)) : (Int(v.major), 0)

function _name_ok(name::AbstractString, spec::FilterSpec)
    spec.skip_jll && endswith(name, "_jll") && return false
    if !isempty(spec.include) && !any(r -> occursin(r, name), spec.include)
        return false
    end
    any(r -> occursin(r, name), spec.exclude) && return false
    return true
end

function _select(versions::Vector{PkgVersion}, spec::FilterSpec)
    # `versions` are all rows for ONE package, already row-filtered. Highest first.
    sorted = sort(versions; by = r -> r.version, rev = true)
    spec.all_versions && return sorted
    if spec.per_break
        # newest `n` versions within each breaking line.
        out = PkgVersion[]
        counts = Dict{Tuple{Int,Int},Int}()
        for r in sorted
            k = breaking_key(r.version)
            c = get(counts, k, 0)
            if c < spec.n
                push!(out, r)
                counts[k] = c + 1
            end
        end
        return out
    end
    # newest `n` versions overall.
    return sorted[1:min(spec.n, length(sorted))]
end

"""
    apply_filters(rows, spec) -> Vector{PkgVersion}

Apply name/yanked/jll/julia-compat row filters, then per-package version selection.
"""
function apply_filters(rows::Vector{PkgVersion}, spec::FilterSpec)
    kept = filter(rows) do r
        _name_ok(r.name, spec) || return false
        spec.skip_yanked && r.yanked && return false
        if spec.julia_version !== nothing && r.julia_compat !== nothing &&
           !(spec.julia_version in r.julia_compat)
            return false
        end
        return true
    end
    bypkg = Dict{Base.UUID,Vector{PkgVersion}}()
    for r in kept
        push!(get!(bypkg, r.uuid, PkgVersion[]), r)
    end
    out = PkgVersion[]
    for (_, vs) in bypkg
        append!(out, _select(vs, spec))
    end
    return out
end
