# Runs once on each GitHub worker before tests, via the `github_job_prep_script`
# input of the reusable testitem workflow.
#
# The cache-infra items in test/test_cache_infra_scripts.jl drive scripts/*.sh
# through rclone; without it on PATH they self-skip and assert nothing. Only
# linux is covered: the scripts are bash, so Windows is out, and they assume a
# GNU userland (`nproc`, for one), so macOS is out too.
#
# Those same scripts spawn `julia --project=<repo root>` children, and since the
# workflow dropped julia-buildpkg nothing else resolves the checkout in place --
# the test processes instantiate a sandbox, not this tree -- so a child finds a
# Project.toml with no Manifest.toml and dies with "Package X is required but
# does not seem to be installed". Instantiating here restores exactly what
# buildpkg provided, on the one platform where the children actually run.

if Sys.islinux()
    run(`sudo apt-get update`)
    run(`sudo apt-get install -y rclone`)
    run(`rclone version`)
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))
    Pkg.instantiate()
else
    @info "ci_prep: no rclone install for this platform, cache-infra items will skip" Sys.KERNEL
end
