# Install every Julia version the worker processes support, via juliaup, and leave the
# General registry in the form all of them can read.
#
#     julia scripts/install_julia_versions.jl              # every supported version
#     julia scripts/install_julia_versions.jl --fallback   # those, plus the nightly fallback
#
# CI runs this as the `github_job_prep_script` of the reusable testitem workflow.

using Pkg

include("repo_common.jl")

versions = copy(JULIA_VERSIONS)
"--fallback" in ARGS && push!(versions, FALLBACK_JULIA)

for version in versions
    println("Installing Julia $version...")
    run(ignorestatus(`juliaup add $version`))
end

# Every version installed above shares this depot, and Julia 1.7's bundled 7z cannot
# decompress zstd — 7z only learned that in v17.6. Pkg asks the package server for a zstd
# compressed registry from Julia 1.13 on, everywhere except Windows, where it skips zstd
# for exactly this reason (`Pkg/src/PlatformEngines.jl`). That carve-out is by platform
# rather than by what else lives in the depot, so on Linux and macOS a `General.tar.zst`
# lands here and `check_julia_version("1.7")` fails on it, while the same test passes on
# Windows. An unpacked registry is a plain folder that every version reads.
registries = joinpath(first(DEPOT_PATH), "registries")
entries = isdir(registries) ? readdir(registries) : String[]
packed = any(i -> startswith(i, "General.tar"), entries)
unpacked = isdir(joinpath(registries, "General"))

if !Sys.iswindows()
    if packed || !unpacked
        println("Installing the General registry unpacked, so that Julia 1.7 can read it...")

        # Removing the packed registry has to happen outside the `withenv` below: with
        # `JULIA_PKG_UNPACK_REGISTRY` set, Pkg looks for unpacked registries only and
        # reports the packed one it is standing on as not installed.
        packed && Pkg.Registry.rm("General")

        withenv("JULIA_PKG_UNPACK_REGISTRY" => "true") do
            Pkg.Registry.add("General")
        end
    end

    # Converting what is here now is not enough: anything later in this job that installs
    # or refreshes the registry — the run itself, or a test process resolving an
    # environment — would put a packed one back. Setting the variable for the rest of the
    # job keeps every such download unpacked too.
    github_env = get(ENV, "GITHUB_ENV", nothing)

    if github_env !== nothing
        open(github_env, "a") do io
            println(io, "JULIA_PKG_UNPACK_REGISTRY=true")
        end
    end
elseif unpacked && !packed
    # Windows never had the zstd problem — Pkg refuses zstd for registries there, for the
    # same 7z reason — and an unpacked registry actively hurts: Pkg replaces it on the next
    # registry operation, and its replace-on-write leaves `$XXXX.pid.deleted` entries that
    # the concurrent test processes then trip over with `stat: permission denied`. The
    # depot is cached between runs, so one unpacked registry would keep breaking every
    # later Windows run. Put a packed one back, and sweep up what was left behind.
    println("Restoring a packed General registry, which is what Windows wants...")

    Pkg.Registry.rm("General")
    Pkg.Registry.add("General")

    for i in readdir(registries)
        endswith(i, ".pid.deleted") || continue
        try
            rm(joinpath(registries, i); recursive=true, force=true)
        catch err
            @warn "Could not remove a leftover registry entry" entry = i err
        end
    end
end
