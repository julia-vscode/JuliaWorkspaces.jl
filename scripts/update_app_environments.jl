# Regenerate the private environments the worker processes activate, one per supported
# Julia version. Requires juliaup with every listed version installed
# (see `install_julia_versions.jl`).
#
#     julia scripts/update_app_environments.jl                 # every version, plus fallback
#     julia scripts/update_app_environments.jl 1.12 1.13       # only those
#     julia scripts/update_app_environments.jl fallback        # only the nightly fallback

include("repo_common.jl")

const DEVELOP = "using Pkg; Pkg.develop(PackageSpec(path=\"../../$SERVER_PACKAGE\"))"

"""
    normalize_manifest_separators(path)

Julia 1.0 and 1.1 write Windows path separators into the manifest, which then fails to
resolve on other platforms. Rewrite them to forward slashes.
"""
function normalize_manifest_separators(path::AbstractString)
    filename = joinpath(path, "Manifest.toml")
    isfile(filename) || return
    write(filename, replace(read(filename, String), "\\\\" => '/'))
end

function build_environment(version::AbstractString)
    fallback = version == "fallback"
    path = joinpath(ENVIRONMENTS_DIR, fallback ? "fallback" : "v$version")
    mkpath(path)

    @info "Building environment" version path
    run(Cmd(`julia +$(fallback ? FALLBACK_JULIA : version) --project=. -e $DEVELOP`, dir=path))

    version in ("1.0", "1.1") && normalize_manifest_separators(path)
    return nothing
end

for version in (isempty(ARGS) ? JULIA_VERSIONS : ARGS)
    build_environment(version)
end

# The fallback environment covers Julia versions newer than anything listed above.
isempty(ARGS) && build_environment("fallback")
