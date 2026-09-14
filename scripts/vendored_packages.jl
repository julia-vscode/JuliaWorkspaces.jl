# The vendored package trees: what is vendored, where it comes from, and what must not move.
#
# That is the whole of the state here. Which version is vendored right now is read from the
# tree's own Project.toml, and which upstream commit it came from is recorded by
# `git subtree` in the commit that pulled it — writing either down again is how such a
# list goes stale. `update_vendored_packages.jl` reconciles the trees on disc with this one.

include("repo_common.jl")

"""
Every vendored tree: repository-relative prefix => GitHub location.

`packages/` holds the versions used on modern Julia; `packages-old/v1.5` and
`packages-old/v1.9` hold the last releases supporting those older Julia versions, which
`juliadynamicanalysisprocess/JuliaDynamicAnalysisProcess/src/pkg_imports.jl` picks
between. Adding an entry here and running `update_vendored_packages.jl --apply` vendors
it.
"""
const VENDORED = [
    "packages/CancellationTokens"            => "davidanthoff/CancellationTokens.jl",
    "packages/CodeTracking"                  => "timholy/CodeTracking.jl",
    "packages/Compiler"                      => "JuliaLang/BaseCompiler.jl",
    "packages/JSON"                          => "JuliaIO/JSON.jl",
    "packages/JSONRPC"                       => "julia-vscode/JSONRPC.jl",
    "packages/JuliaInterpreter"              => "JuliaDebug/JuliaInterpreter.jl",
    "packages/LoweredCodeUtils"              => "JuliaDebug/LoweredCodeUtils.jl",
    "packages/OrderedCollections"            => "JuliaCollections/OrderedCollections.jl",
    "packages/Preferences"                   => "JuliaPackaging/Preferences.jl",
    "packages/Revise"                        => "timholy/Revise.jl",
    "packages/TestEnv"                       => "JuliaTesting/TestEnv.jl",

    "packages-old/v1.9/CodeTracking"         => "timholy/CodeTracking.jl",
    "packages-old/v1.9/JuliaInterpreter"     => "JuliaDebug/JuliaInterpreter.jl",
    "packages-old/v1.9/LoweredCodeUtils"     => "JuliaDebug/LoweredCodeUtils.jl",
    "packages-old/v1.9/Revise"               => "timholy/Revise.jl",

    "packages-old/v1.5/CodeTracking"         => "timholy/CodeTracking.jl",
    "packages-old/v1.5/JuliaInterpreter"     => "JuliaDebug/JuliaInterpreter.jl",
    "packages-old/v1.5/LoweredCodeUtils"     => "JuliaDebug/LoweredCodeUtils.jl",
    "packages-old/v1.5/OrderedCollections"   => "JuliaCollections/OrderedCollections.jl",
    "packages-old/v1.5/Revise"               => "timholy/Revise.jl",
]

"""
Trees that must not follow upstream, and why. A key covers itself and everything below it,
so a whole `packages-old` tier takes one entry.

Frozen only means "not swept along with the rest": a frozen tree still moves when it is
named, as in `update_vendored_packages.jl --apply packages/JSON@v0.20.2`.
"""
const FROZEN = Dict(
    "packages/JSON" =>
        "newer versions add dependencies we would have to vendor too",
    "packages/Compiler" =>
        "upstream tags v12.x releases that vendor the whole compiler pinned to one " *
        "Julia version; v0.1 is the standalone stdlib",
    "packages-old/v1.9" =>
        "the last releases supporting Julia 1.9",
    "packages-old/v1.5" =>
        "the last releases supporting Julia 1.5",
)

"""
    frozen_reason(prefix)

Why `prefix` must not follow upstream, or `nothing` if it tracks it.
"""
function frozen_reason(prefix::AbstractString)
    haskey(FROZEN, prefix) && return FROZEN[prefix]
    for (key, reason) in FROZEN
        startswith(prefix, key * "/") && return reason
    end
    return nothing
end

"""
    vendored_version(prefix)

The version in the vendored tree's Project.toml, or `nothing` when the tree is not on disc.
"""
function vendored_version(prefix::AbstractString)
    filename = joinpath(REPO_ROOT, prefix, "Project.toml")
    isfile(filename) || return nothing
    m = match(r"(?m)^version\s*=\s*\"([^\"]+)\"", read(filename, String))
    m === nothing && error("No version found in $prefix/Project.toml")
    return VersionNumber(m[1])
end

"""
    remote_tags(location)

The `vX.Y.Z` tags of a GitHub repository, as `VersionNumber`s. Uses `git ls-remote`, so no
API token is needed and prereleases are ignored.
"""
function remote_tags(location::AbstractString)
    out = read(`git ls-remote --tags --refs https://github.com/$location`, String)
    versions = VersionNumber[]
    for line in eachsplit(out, '\n')
        m = match(r"refs/tags/v(\d+\.\d+\.\d+)$", strip(line))
        m === nothing || push!(versions, VersionNumber(m[1]))
    end
    return versions
end

"""
    latest_release(location)

The newest release of a GitHub repository, or `nothing` if it has no `vX.Y.Z` tag.
"""
function latest_release(location::AbstractString)
    tags = remote_tags(location)
    return isempty(tags) ? nothing : maximum(tags)
end

"""
    recorded_split(prefix)

The upstream commit the vendored tree was last taken from, as `git subtree` recorded it in
the commit that added or pulled it, or `nothing` when no such commit exists — a tree put
there by hand, or one this repository's history does not reach.
"""
function recorded_split(prefix::AbstractString)
    out = git_output("log", "-1", "--grep", "^git-subtree-dir: $prefix\$", "--format=%b")
    m = match(r"(?m)^git-subtree-split:\s*([0-9a-f]{40})", out)
    return m === nothing ? nothing : m[1]
end

"""
    tag_commit(location, tag)

The commit a tag points at, following annotated tags through to the commit, or `nothing` if
the tag does not exist upstream.
"""
function tag_commit(location::AbstractString, tag::AbstractString)
    # The peeled ref has to be built as a string: `^{}` is not something a command literal
    # will parse.
    peeled = "refs/tags/$tag^{}"
    out = read(`git ls-remote https://github.com/$location refs/tags/$tag $peeled`, String)
    sha = nothing
    for line in eachsplit(out, '\n')
        isempty(strip(line)) && continue
        fields = split(strip(line))
        length(fields) == 2 || continue
        # The peeled entry is what an annotated tag actually points at; prefer it.
        endswith(fields[2], "^{}") && return String(fields[1])
        sha = String(fields[1])
    end
    return sha
end
