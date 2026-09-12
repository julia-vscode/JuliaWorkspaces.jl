# Reconcile the vendored trees on disc with the list in `vendored_packages.jl`.
#
#     julia scripts/update_vendored_packages.jl                    # report, change nothing
#     julia scripts/update_vendored_packages.jl --apply            # add what is missing,
#                                                                  # update what is behind
#     julia scripts/update_vendored_packages.jl --apply packages/JSON@v0.20.2
#     julia scripts/update_vendored_packages.jl --verify           # audit what is on disc
#
# Naming a prefix limits the run to it, and `@vX.Y.Z` pulls that exact release — the way to
# move a tree that is frozen, or to put one back at a version that is not the newest.
#
# `--verify` checks that every tree really is the release its Project.toml claims, by
# comparing the commit `git subtree` recorded with the one the upstream tag points at.

include("vendored_packages.jl")

const APPLY = "--apply" in ARGS
const VERIFY = "--verify" in ARGS

"""
    parse_targets(args) -> Dict{String,Union{String,Nothing}}

The prefixes named on the command line, mapped to the tag each was pinned to with
`prefix@tag`, or `nothing` where no tag was given. Empty when the run covers everything.
"""
function parse_targets(args)
    targets = Dict{String,Union{String,Nothing}}()
    for arg in args
        startswith(arg, "--") && continue
        prefix, tag = split_target(arg)
        haskey(LOCATIONS, prefix) ||
            error("$prefix is not in VENDORED; add it to scripts/vendored_packages.jl first")
        targets[prefix] = tag
    end
    return targets
end

"""
    split_target(arg) -> (prefix, tag)

`"packages/JSON@v0.20.2"` as its two parts; `tag` is `nothing` when none was given.
"""
function split_target(arg)
    i = findlast('@', arg)
    i === nothing && return (arg, nothing)
    return (arg[1:prevind(arg, i)], arg[nextind(arg, i):end])
end

const LOCATIONS = Dict(VENDORED)
const TARGETS = parse_targets(ARGS)

"""
    plan(prefix, location) -> NamedTuple

What reconciling one tree would take: `:add`, `:pull`, `:frozen`, `:blocked` or `:current`,
the ref to fetch, and what to say about it.
"""
function plan(prefix, location)
    current = vendored_version(prefix)
    pinned = get(TARGETS, prefix, nothing)
    frozen = frozen_reason(prefix)
    latest = latest_release(location)

    if pinned !== nothing
        action = current === nothing ? :add : :pull
        return (; action, ref=pinned, current, latest, note="explicitly requested")
    end

    if current === nothing
        # A tree that is missing and frozen cannot be fetched at "the newest release" — but
        # if this repository ever had it, git recorded which commit it held.
        if frozen !== nothing
            split = recorded_split(prefix)
            split === nothing && return (; action=:blocked, ref=nothing, current, latest,
                note="frozen ($frozen) and never vendored here; name a release to add it")
            return (; action=:add, ref=split, current, latest,
                note="frozen ($frozen); restoring the commit git recorded")
        end
        latest === nothing && return (; action=:blocked, ref=nothing, current, latest,
            note="no vX.Y.Z release upstream")
        return (; action=:add, ref="v$latest", current, latest, note="not vendored yet")
    end

    frozen !== nothing && return (; action=:frozen, ref=nothing, current, latest, note=frozen)
    latest === nothing && return (; action=:current, ref=nothing, current, latest,
        note="no vX.Y.Z release upstream")
    latest > current && return (; action=:pull, ref="v$latest", current, latest, note="")
    return (; action=:current, ref=nothing, current, latest, note="")
end

describe(p) =
    p.action === :add ? "add $(p.ref)" :
    p.action === :pull ? "update to $(p.ref)" :
    p.action === :frozen ? "frozen: $(p.note)" :
    p.action === :blocked ? "cannot add: $(p.note)" :
    "up to date"

"""
    unregistered() -> Vector{String}

Vendored-looking trees on disc that no entry claims. Reported, never removed.
"""
function unregistered()
    known = Set(first.(VENDORED))
    found = String[]
    for (root, depth) in ("packages" => 1, "packages-old" => 2)
        isdir(joinpath(REPO_ROOT, root)) || continue
        prefixes = [root]
        for _ in 1:depth
            # Prefixes are written with forward slashes everywhere, including in VENDORED.
            prefixes = ["$p/$e" for p in prefixes
                        for e in readdir(joinpath(REPO_ROOT, p))
                        if isdir(joinpath(REPO_ROOT, p, e))]
        end
        append!(found, prefixes)
    end
    return sort(filter(p -> !(p in known), found))
end

function working_tree_is_clean()
    return isempty(strip(git_output("status", "--porcelain")))
end

"""
    verify(selected)

Check each tree against the release its Project.toml claims: the commit `git subtree`
recorded for it must be the one the upstream tag points at. Returns how many did not add up.
"""
function verify(selected)
    println("Checking that each tree is the release its Project.toml claims\n")
    problems = 0

    for (prefix, location) in selected
        current = vendored_version(prefix)
        if current === nothing
            println(rpad(prefix, 40), rpad("-", 12), "not on disc")
            continue
        end

        split = recorded_split(prefix)
        tagged = tag_commit(location, "v$current")

        status = if split === nothing
            problems += 1
            "no subtree commit for it in this repository's history"
        elseif tagged === nothing
            problems += 1
            "upstream has no v$current tag"
        elseif split == tagged
            "ok"
        else
            problems += 1
            "holds $(split[1:8]), but v$current is $(tagged[1:8]) upstream"
        end

        println(rpad(prefix, 40), rpad("v$current", 12), status)
    end

    println()
    println(problems == 0 ? "Every tree is the release it claims." : "$problems tree(s) need a look.")
    return problems
end

"""
    report(plans)

Print what each tree is, what upstream has, and what reconciling it would do. Trees on disc
that no entry claims are listed too — this script never removes anything.
"""
function report(plans)
    println(rpad("TREE", 40), rpad("VENDORED", 12), rpad("UPSTREAM", 12), "ACTION")

    for (prefix, _, p) in plans
        vendored = p.current === nothing ? "-" : "v$(p.current)"
        upstream = p.latest === nothing ? "-" : "v$(p.latest)"
        println(rpad(prefix, 40), rpad(vendored, 12), rpad(upstream, 12), describe(p))
    end

    extra = unregistered()
    if !isempty(extra)
        println("\nOn disc but not in VENDORED — add them to scripts/vendored_packages.jl:")
        foreach(prefix -> println("    ", prefix), extra)
    end

    return nothing
end

"""
    reconcile(todo)

Add or pull each tree, as `git subtree` does it everywhere else in these repositories:
squashed, so the vendored history stays one commit per update.
"""
function reconcile(todo)
    isempty(strip(git_output("status", "--porcelain"))) ||
        error("The working tree has changes; git subtree needs a clean one.")

    for (prefix, location, p) in todo
        @info "Reconciling" prefix action=p.action ref=p.ref
        git("subtree", String(p.action), "--prefix", prefix,
            "https://github.com/$location", p.ref, "--squash")
    end

    println("\nReconciled $(length(todo)) tree(s).")
    return nothing
end

const SELECTED = isempty(TARGETS) ? VENDORED :
    [prefix => LOCATIONS[prefix] for prefix in sort(collect(keys(TARGETS)))]

VERIFY && verify(SELECTED)

if !VERIFY || APPLY
    VERIFY && println()

    plans = [(prefix, location, plan(prefix, location)) for (prefix, location) in SELECTED]
    report(plans)

    todo = [entry for entry in plans if entry[3].action in (:add, :pull)]
    blocked = [prefix for (prefix, _, p) in plans if p.action === :blocked]

    if !APPLY
        println()
        println(isempty(todo) ? "Everything is up to date." :
            "$(length(todo)) tree(s) to reconcile. Re-run with --apply.")
    elseif isempty(todo)
        println("\nNothing to do.")
    else
        reconcile(todo)
    end

    isempty(blocked) || @warn "Left alone" prefixes=blocked
end
