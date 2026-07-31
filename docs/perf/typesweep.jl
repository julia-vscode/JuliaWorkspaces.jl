# Both-direction diagnostic sweep over every workspace package root of the
# julia-vscode repo: which diagnostics one revision of the linter emits that
# another does not. The merge gate for cross-file type-aware method matching — a
# diagnostic present on a feature branch and absent on its base is a false
# positive until proven otherwise, and a diagnostic that DISAPPEARS has to be
# explained too (withholding is silent by construction).
#
# Loads ONE fixed snapshot of file content (read from disk by
# `TypeBudget.load_folder`, never round-tripped through `string(::SourceText)`),
# so between two arms only the loaded linter code differs.
#
# Running the two arms. Each arm is a separate julia session, because each loads a
# different copy of this package:
#
#   1. Feature arm: the working tree, via the development environment.
#        include("docs/perf/typesweep.jl")
#        jw, _ = Sweep.load()
#        Sweep.instrument!()                      # only needed for the `cmp` column
#        arm = Sweep.run_arm(jw); Sweep.save(arm, "/tmp/arm-branch.tsv")
#   2. Base arm: `git worktree add <scratch>/base <ref>`, then a COPY of the
#      development environment whose Manifest repoints JuliaWorkspaces at that
#      worktree and absolutises the other relative `path =` entries. Copy this file
#      and `typebudget.jl` into a scratch dir and include from there — the base ref
#      may predate either of them.
#        arm = Sweep.run_arm(jw; want_index_stats=false)
#        Sweep.save(arm, "/tmp/arm-base.tsv")
#   3. Sweep.report(Sweep.compare("/tmp/arm-branch.tsv", "/tmp/arm-base.tsv"))
#
# `resolve_envs=false` keeps the env the bundled stdlib-only fallback, so no julia
# child is spawned; both arms then see the same env and the store leg is the
# fallback's Base/Core.
module Sweep

include(joinpath(@__DIR__, "typebudget.jl"))

using JuliaWorkspaces
const JW = JuliaWorkspaces
const SL = JuliaWorkspaces.StaticLint
const CP = JuliaWorkspaces.CSTParser
using JuliaWorkspaces: URI

const REPO = "/home/pfitzseb/git/julia-vscode"
const PROJECT = "/home/pfitzseb/git/julia-vscode/scripts/environments/development/Project.toml"

function load()
    jw, files = TypeBudget.load_folder(REPO; project=PROJECT, resolve_envs=false)
    return jw, files
end

# A diagnostic's identity, independent of object identity and of root: the file, the
# range endpoints, severity, source and message.
dkey(d::JW.Diagnostic, file::URI) =
    string(JW.uri2filepath(file), "\t", first(d.range), ":", last(d.range), "\t",
           d.severity, "\t", d.source, "\t", d.message)

"""
One arm of the sweep. Returns
`(diags::Dict{String,Set{String}}, counts::Dict{String,Int}, marker::Dict{String,Tuple{Int,Int}})`
keyed by root NAME (stable across arms; the URI is too).
"""
function run_arm(jw; want_index_stats::Bool=true)
    rt = jw.runtime
    roots = JW.derived_workspace_package_roots(rt)
    diags = Dict{String,Set{String}}()
    counts = Dict{String,Int}()
    marker = Dict{String,Tuple{Int,Int}}()   # root => (n_param_type_keys, n_arity_keys)
    errors = Dict{String,Vector{String}}()
    for (nm, u) in sort(collect(roots); by=x -> x[1])
        s = Set{String}()
        n = 0
        fs = try
            JW.derived_tree_files(rt, u)
        catch err
            push!(get!(() -> String[], errors, nm), "derived_tree_files: $(sprint(showerror, err))")
            URI[]
        end
        for f in fs
            CURRENT_ROOT[] = nm
            CURRENT_FILE[] = f
            fa = try
                JW.derived_file_analysis(rt, u, f)
            catch err
                push!(get!(() -> String[], errors, nm), "$(JW.uri2filepath(f)): $(sprint(showerror, err))")
                continue
            end
            for d in fa.diagnostics
                push!(s, dkey(d, f))
                n += 1
            end
        end
        diags[nm] = s
        counts[nm] = n
        if want_index_stats
            marker[nm] = try
                (length(JW.derived_method_param_types_index(rt, u)),
                 length(JW.derived_method_arities_index(rt, u)))
            catch
                (-1, -1)
            end
        end
    end
    return (; diags, counts, marker, errors, roots=sort(collect(keys(diags))))
end

# --- instrumentation state (also set on the `main` arm; harmless there) --------
const CURRENT_ROOT = Ref{String}("")
const CURRENT_FILE = Ref{Any}(nothing)

# Per-root sets of distinct call sites that reached a full store-vs-store
# comparison, filled by the instrumented `_tree_types_match` (see `instrument!`).
const COMPARED = Dict{String,Set{Tuple{String,UInt}}}()
const REJECTED = Dict{String,Set{Tuple{String,UInt}}}()

note_compared!(x) = push!(get!(() -> Set{Tuple{String,UInt}}(), COMPARED, CURRENT_ROOT[]),
                         (string(CURRENT_FILE[]), objectid(x)))
note_rejected!(x) = push!(get!(() -> Set{Tuple{String,UInt}}(), REJECTED, CURRENT_ROOT[]),
                          (string(CURRENT_FILE[]), objectid(x)))

"""
Replace `StaticLint._tree_types_match` with a copy that additionally records, per
root, every distinct call site at which the per-position type comparison actually
ran (`checked`), and every site it rejected. Behaviour-identical: the same
returns in the same order, with `push!`es added.
"""
function instrument!()
    M = @__MODULE__
    @eval SL function _tree_types_match(x, n, cc, arities, env::ExternalEnv, meta_dict, tree_param_types)
        tree_param_types === nothing && return true
        recs = tree_param_types(n, x)
        isempty(recs) && return true
        length(recs) == length(arities) || return true
        args, kws = call_arg_types(x, false, meta_dict, getsymbols(env))
        isempty(kws) || return true
        all(_is_resolved_type, args) || return true
        checked = false
        for r in recs
            compare_f_call(r.arity, cc) || continue
            length(r.types) == length(args) || return true
            checked = true
            $(M).note_compared!(x)
            all(i -> _has_type_intersection(args[i], r.types[i], getsymbols(env), meta_dict),
                1:length(args)) && return true
        end
        checked && $(M).note_rejected!(x)
        return !checked
    end
    return nothing
end

# --- persistence --------------------------------------------------------------

function save(arm, path::String)
    open(path, "w") do io
        for r in arm.roots
            println(io, "#ROOT\t", r, "\t", arm.counts[r], "\t",
                    get(arm.marker, r, (-1, -1))[1], "\t", get(arm.marker, r, (-1, -1))[2], "\t",
                    length(get(() -> Set{Tuple{String,UInt}}(), COMPARED, r)), "\t",
                    length(get(() -> Set{Tuple{String,UInt}}(), REJECTED, r)))
            for d in sort(collect(arm.diags[r]))
                println(io, "#D\t", r, "\t", d)
            end
            for e in get(arm.errors, r, String[])
                println(io, "#E\t", r, "\t", e)
            end
        end
    end
    return path
end

function load_saved(path::String)
    diags = Dict{String,Set{String}}()
    counts = Dict{String,Int}()
    marker = Dict{String,Tuple{Int,Int}}()
    compared = Dict{String,Int}()
    rejected = Dict{String,Int}()
    errors = Dict{String,Vector{String}}()
    order = String[]
    for line in eachline(path)
        parts = split(line, '\t')
        if parts[1] == "#ROOT"
            r = parts[2]
            push!(order, r)
            counts[r] = parse(Int, parts[3])
            marker[r] = (parse(Int, parts[4]), parse(Int, parts[5]))
            compared[r] = parse(Int, parts[6])
            rejected[r] = parse(Int, parts[7])
            diags[r] = Set{String}()
        elseif parts[1] == "#D"
            push!(diags[parts[2]], join(parts[3:end], '\t'))
        elseif parts[1] == "#E"
            push!(get!(() -> String[], errors, parts[2]), join(parts[3:end], '\t'))
        end
    end
    return (; diags, counts, marker, compared, rejected, errors, roots=order)
end

"Compare two saved arms: per root, |branch \\ main| (the blocker) and |main \\ branch|."
function compare(branch_path::String, main_path::String)
    b = load_saved(branch_path)
    m = load_saved(main_path)
    rows = NamedTuple[]
    for r in sort(union(b.roots, m.roots))
        bs = get(() -> Set{String}(), b.diags, r)
        ms = get(() -> Set{String}(), m.diags, r)
        push!(rows, (root=r, new=length(setdiff(bs, ms)), gone=length(setdiff(ms, bs)),
                     nb=length(bs), nm=length(ms),
                     ptkeys=get(b.marker, r, (-1, -1))[1], arkeys=get(b.marker, r, (-1, -1))[2],
                     compared=get(b.compared, r, 0), rejected=get(b.rejected, r, 0),
                     newset=sort(collect(setdiff(bs, ms))), goneset=sort(collect(setdiff(ms, bs)))))
    end
    return rows
end

function report(rows)
    tot_new = sum(r.new for r in rows; init=0)
    tot_gone = sum(r.gone for r in rows; init=0)
    println("roots: ", length(rows))
    println("TOTAL new-on-branch (BLOCKER if >0): ", tot_new)
    println("TOTAL gone-on-branch: ", tot_gone)
    println("roots with marker fired (param-types empty, arities non-empty): ",
            count(r -> r.ptkeys == 0 && r.arkeys > 0, rows))
    println("total distinct compared call sites: ", sum(r.compared for r in rows; init=0))
    println()
    println(rpad("root", 26), lpad("new", 5), lpad("gone", 6), lpad("branch", 8), lpad("main", 7),
            lpad("ptkeys", 8), lpad("arkeys", 8), lpad("cmp", 7), lpad("rej", 6))
    for r in rows
        println(rpad(r.root, 26), lpad(r.new, 5), lpad(r.gone, 6), lpad(r.nb, 8), lpad(r.nm, 7),
                lpad(r.ptkeys, 8), lpad(r.arkeys, 8), lpad(r.compared, 7), lpad(r.rejected, 6))
    end
    for r in rows
        isempty(r.newset) && continue
        println("\n!! NEW ON BRANCH in ", r.root)
        for d in r.newset
            println("   ", d)
        end
    end
    for r in rows
        isempty(r.goneset) && continue
        println("\n?? GONE ON BRANCH in ", r.root)
        for d in r.goneset
            println("   ", d)
        end
    end
    return nothing
end

end # module
