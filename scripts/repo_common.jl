# Constants and helpers shared by the scripts in this folder.
#
# Every script here runs as a plain `julia scripts/<name>.jl`: stdlib only, no environment
# to instantiate and no credentials to configure.

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

# The Julia versions a dynamic analysis process supports, one shipped environment each.
# Anything newer uses the `fallback` environment, which is built on nightly.
const JULIA_VERSIONS = [
    "1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7",
    "1.8", "1.9", "1.10", "1.11", "1.12", "1.13",
]

const FALLBACK_JULIA = "nightly"

# What `update_app_environments.jl` regenerates: the per-version environments, and the
# package they develop. The package sits next to the environments folder.
const ENVIRONMENTS_DIR = joinpath(REPO_ROOT, "juliadynamicanalysisprocess", "environments")
const SERVER_PACKAGE = "JuliaDynamicAnalysisProcess"

"""
    git(args...; dir=REPO_ROOT)

Run git in the repository, throwing if it fails. `GIT_MERGE_AUTOEDIT` is off so that the
merges `git subtree` makes do not stop for an editor.
"""
git(args...; dir=REPO_ROOT) =
    run(addenv(Cmd(`git $(collect(args))`, dir=dir), "GIT_MERGE_AUTOEDIT" => "no"))

"""
    git_output(args...; dir=REPO_ROOT)

Run git and return its stdout.
"""
git_output(args...; dir=REPO_ROOT) = read(Cmd(`git $(collect(args))`, dir=dir), String)
