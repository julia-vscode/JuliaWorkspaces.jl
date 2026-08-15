# Runs once on each GitHub worker before tests, via the `github_job_prep_script`
# input of the reusable testitem workflow.
#
# The cache-infra items in test/test_cache_infra_scripts.jl drive scripts/*.sh
# through rclone; without it on PATH they self-skip and assert nothing. Windows
# is deliberately not covered — those scripts are bash and also need tar/gzip.
#
# Base only: this runs under the default environment, with nothing instantiated.

if Sys.islinux()
    run(`sudo apt-get update`)
    run(`sudo apt-get install -y rclone`)
    run(`rclone version`)
elseif Sys.isapple()
    run(`brew install rclone`)
    run(`rclone version`)
else
    @info "ci_prep: no rclone install for this platform, cache-infra items will skip" Sys.KERNEL
end
