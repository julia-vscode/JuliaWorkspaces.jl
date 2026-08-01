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
    marker = Dict{String,Tuple{Int,Int}}()   # root => (n_signature_keys, n_records)
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
                idx = JW.derived_method_signatures_index(rt, u)
                (length(idx), sum(length, values(idx); init=0))
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

# Per-root argument-slot tallies over the same aligned records. `PARAM_KNOWN` is
# the ARM PROOF: every other quantity here is invariant to the parameter-type
# resolver, so two arms that agree on it are not two arms. `BOTH_KNOWN` is the
# sensitive marker — it counts the slots where a verdict is even possible, and so
# moves when a change makes comparisons newly live without flipping any verdict.
const PARAM_KNOWN = Dict{String,Int}()
const BOTH_KNOWN = Dict{String,Int}()

note_compared!(x) = push!(get!(() -> Set{Tuple{String,UInt}}(), COMPARED, CURRENT_ROOT[]),
                         (string(CURRENT_FILE[]), objectid(x)))
note_rejected!(x) = push!(get!(() -> Set{Tuple{String,UInt}}(), REJECTED, CURRENT_ROOT[]),
                          (string(CURRENT_FILE[]), objectid(x)))

function note_slots!(types, args)
    r = CURRENT_ROOT[]
    pk = bk = 0
    for i in eachindex(args)
        SL._isany(types[i]) && continue
        pk += 1
        SL._isany(args[i]) || (bk += 1)
    end
    PARAM_KNOWN[r] = get(PARAM_KNOWN, r, 0) + pk
    BOTH_KNOWN[r] = get(BOTH_KNOWN, r, 0) + bk
    return nothing
end

"Drop every instrumentation tally. Call between arms run in one session."
function reset_instrumentation!()
    empty!(COMPARED); empty!(REJECTED); empty!(PARAM_KNOWN); empty!(BOTH_KNOWN)
    return nothing
end

"""
Replace `StaticLint._tree_types_match` with a copy that additionally records, per
root, every distinct call site at which the per-position type comparison actually
ran (`checked`), every site it rejected, and the slot tallies. Behaviour-identical:
the same returns in the same order, with bookkeeping added.

The tally pass is separate from — and runs before — the matching loop, so that it
sees every aligned record rather than the prefix the loop happens to visit before
an early `return true`. The loop's stopping point depends on the resolver; the
tally must not.
"""
function instrument!()
    M = @__MODULE__
    @eval SL function _tree_types_match(x, n, cc, env::ExternalEnv, meta_dict, tree_param_types)
        tree_param_types === nothing && return true
        recs = tree_param_types(n, x)
        isempty(recs) && return true
        all(r -> r.judgeable, recs) || return true
        args, kws = call_arg_types(x, false, meta_dict, getsymbols(env))
        isempty(kws) || return true
        all(_is_resolved_type, args) || return true
        for r in recs
            compare_f_call(r.arity, cc) && length(r.types) == length(args) &&
                $(M).note_slots!(r.types, args)
        end
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

"""
Resolver-level survey, independent of any call site: for every parameter of every
judgeable record under every root, whether the resolver reached a real type.
Returns `root => Vector{Bool}` in a deterministic order (roots, then signature
keys, then records, then parameters), so two arms' vectors align elementwise and a
`resolved -> Any` regression is visible per parameter rather than only in a total.
"""
function param_survey(jw)
    rt = jw.runtime
    out = Dict{String,Vector{Bool}}()
    unions = Dict{String,Int}()
    for (nm, u) in sort(collect(JW.derived_workspace_package_roots(rt)); by=x -> x[1])
        bits = Bool[]
        nu = 0
        env = try
            JW.derived_stdlib_only_env(rt)
        catch
            continue
        end
        idx = try
            JW.derived_method_signatures_index(rt, u)
        catch
            Dict()
        end
        for k in sort(collect(keys(idx)); by=string)
            for r in JW._resolve_param_types(rt, u, env, idx[k])
                r.judgeable || continue
                for t in r.types
                    push!(bits, !SL._isany(t))
                    t isa JW.SymbolServer.FakeUnion && (nu += 1)
                end
            end
        end
        out[nm] = bits
        unions[nm] = nu
    end
    return (; bits=out, unions)
end

# --- persistence --------------------------------------------------------------

function save(arm, path::String)
    open(path, "w") do io
        for r in arm.roots
            println(io, "#ROOT\t", r, "\t", arm.counts[r], "\t",
                    get(arm.marker, r, (-1, -1))[1], "\t", get(arm.marker, r, (-1, -1))[2], "\t",
                    length(get(() -> Set{Tuple{String,UInt}}(), COMPARED, r)), "\t",
                    length(get(() -> Set{Tuple{String,UInt}}(), REJECTED, r)), "\t",
                    get(PARAM_KNOWN, r, 0), "\t", get(BOTH_KNOWN, r, 0))
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
    pknown = Dict{String,Int}()
    bknown = Dict{String,Int}()
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
            pknown[r] = length(parts) >= 8 ? parse(Int, parts[8]) : 0
            bknown[r] = length(parts) >= 9 ? parse(Int, parts[9]) : 0
            diags[r] = Set{String}()
        elseif parts[1] == "#D"
            push!(diags[parts[2]], join(parts[3:end], '\t'))
        elseif parts[1] == "#E"
            push!(get!(() -> String[], errors, parts[2]), join(parts[3:end], '\t'))
        end
    end
    return (; diags, counts, marker, compared, rejected, pknown, bknown, errors, roots=order)
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
                     sigkeys=get(b.marker, r, (-1, -1))[1], sigrecs=get(b.marker, r, (-1, -1))[2],
                     compared=get(b.compared, r, 0), rejected=get(b.rejected, r, 0),
                     pknown=get(b.pknown, r, 0), pknown_m=get(m.pknown, r, 0),
                     bknown=get(b.bknown, r, 0), bknown_m=get(m.bknown, r, 0),
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
    println("total signature-index keys / records on branch: ",
            sum(r -> max(r.sigkeys, 0), rows), " / ", sum(r -> max(r.sigrecs, 0), rows))
    println("total distinct compared call sites: ", sum(r.compared for r in rows; init=0))
    pk, pkm = sum(r.pknown for r in rows; init=0), sum(r.pknown_m for r in rows; init=0)
    bk, bkm = sum(r.bknown for r in rows; init=0), sum(r.bknown_m for r in rows; init=0)
    println("known-parameter slots, branch vs main: ", pk, " vs ", pkm,
            pk == pkm ? "   <-- ARM PROOF FAILED: the arms resolve identically" : "")
    println("both-sides-known slots, branch vs main: ", bk, " vs ", bkm)
    println()
    println(rpad("root", 26), lpad("new", 5), lpad("gone", 6), lpad("branch", 8), lpad("main", 7),
            lpad("sigkeys", 9), lpad("sigrecs", 9), lpad("cmp", 7), lpad("rej", 6),
            lpad("pknown", 14), lpad("bknown", 12))
    for r in rows
        println(rpad(r.root, 26), lpad(r.new, 5), lpad(r.gone, 6), lpad(r.nb, 8), lpad(r.nm, 7),
                lpad(r.sigkeys, 9), lpad(r.sigrecs, 9), lpad(r.compared, 7), lpad(r.rejected, 6),
                lpad("$(r.pknown)/$(r.pknown_m)", 14), lpad("$(r.bknown)/$(r.bknown_m)", 12))
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

# --- the incremental arm ------------------------------------------------------
#
# Every other measurement in this file is a COLD build: it exercises the
# computation and never the invalidation. A cached value that fails to update
# after an edit is invisible to all of them. This arm edits files in a live
# workspace and requires the whole root's diagnostics to equal a from-cold
# rebuild of the same content.
#
# The probe is a callee and a cross-file caller appended to two files of a real
# root, so an edit travels the same signature-index path a real one does while
# what should change stays known. A synthetic name cannot collide with the root.

const P_CALLEE = "__sweep_probe_callee"
const P_CALLER = "__sweep_probe_caller"

# The probe's states. Each is (label, callee text, caller text, does the caller
# expect a diagnostic). The caller passes a String throughout, so only the
# callee's signature decides.
const PROBE_STATES = [
    (:base,     "$(P_CALLEE)(x::Int) = 1",           true),   # String vs Int
    (:type,     "$(P_CALLEE)(x::String) = 1",        false),  # type-only edit: now matches
    (:count,    "$(P_CALLEE)(x::String, y) = 1",     true),   # count-changing edit
    (:body,     "$(P_CALLEE)(x::String, y) = 22222", true),   # body-only: nothing may move
]

probe_caller_text() = "\n$(P_CALLER)() = $(P_CALLEE)(\"s\")\n"

# The diagnostics of one root, keyed as everywhere else in this file.
function root_diags(rt, u)
    s = Set{String}()
    for f in JW.derived_tree_files(rt, u)
        fa = JW.derived_file_analysis(rt, u, f)
        for d in fa.diagnostics
            push!(s, dkey(d, f))
        end
    end
    return s
end

# Two distinct INCLUDED `.jl` files of `u`'s tree, callee first. The entry file is
# excluded: appending to it lands after the module's own `end`, where the probe
# would be invisible to the module and prove nothing.
function probe_files(rt, u)
    fs = [f for f in JW.derived_tree_files(rt, u) if f != u && endswith(string(f), ".jl")]
    length(fs) >= 2 || return nothing
    return (fs[1], fs[2])
end

# Raw text of a file as the workspace holds it. NOT `string(::SourceText)`, which
# returns the repr and silently corrupts the file.
file_text(jw, uri) = JW.get_text_file(jw, uri).content.content

"""
Edit a root's files in place and require the result to match a cold rebuild.

For each probe state: apply it to the live workspace, collect the root's whole
diagnostic set, then build a FRESH workspace over the same content and collect
again. Any difference is a stale cached value. Returns a row per (root, state).
"""
function run_incremental(; roots=nothing, verbose=true)
    jw, files = load()
    rt = jw.runtime
    all_roots = JW.derived_workspace_package_roots(rt)
    names = roots === nothing ? sort(collect(keys(all_roots))) : roots
    rows = NamedTuple[]

    for nm in names
        u = get(all_roots, nm, nothing)
        u === nothing && continue
        pf = probe_files(rt, u)
        pf === nothing && continue
        callee_uri, caller_uri = pf
        base_callee = file_text(jw, callee_uri)
        base_caller = file_text(jw, caller_uri)

        for (label, callee_src, expect_diag) in PROBE_STATES
            callee_text = base_callee * "\n" * callee_src * "\n"
            caller_text = base_caller * probe_caller_text()
            JW.update_file!(jw, JW.TextFile(callee_uri, JW.SourceText(callee_text, "julia")))
            JW.update_file!(jw, JW.TextFile(caller_uri, JW.SourceText(caller_text, "julia")))
            incr = root_diags(rt, u)

            cold_jw = JuliaWorkspace(; resolve_workspace_environments=false)
            JW.add_files!(cold_jw, [tf.uri == callee_uri ? JW.TextFile(callee_uri, JW.SourceText(callee_text, "julia")) :
                                    tf.uri == caller_uri ? JW.TextFile(caller_uri, JW.SourceText(caller_text, "julia")) :
                                    tf for tf in files])
            JW.set_active_project!(cold_jw, JW.filepath2uri(PROJECT))
            cold_u = get(JW.derived_workspace_package_roots(cold_jw.runtime), nm, nothing)
            cold = cold_u === nothing ? Set{String}() : root_diags(cold_jw.runtime, cold_u)

            # Only a method-matching verdict counts. The probe also draws an
            # unused-argument hint in every state, which says nothing about the edit.
            probe_hits = count(d -> occursin(P_CALLEE, d) &&
                                    (occursin("No method matching", d) || occursin("method call error", d)), incr)
            push!(rows, (root=nm, state=label,
                         stale=length(setdiff(incr, cold)), missing_=length(setdiff(cold, incr)),
                         n=length(incr), probe_hits, expect_diag))
            verbose && println(rpad(nm, 26), rpad(string(label), 8),
                               " incremental=", lpad(length(incr), 5),
                               " cold=", lpad(length(cold), 5),
                               " stale=", lpad(length(setdiff(incr, cold)), 3),
                               " missing=", lpad(length(setdiff(cold, incr)), 3),
                               " probe=", probe_hits, expect_diag ? " (expected)" : " (expected none)")
        end

        JW.update_file!(jw, JW.TextFile(callee_uri, JW.SourceText(base_callee, "julia")))
        JW.update_file!(jw, JW.TextFile(caller_uri, JW.SourceText(base_caller, "julia")))
    end
    return rows
end

function report_incremental(rows)
    bad = [r for r in rows if r.stale != 0 || r.missing_ != 0]
    wrong = [r for r in rows if (r.probe_hits > 0) != r.expect_diag]
    println("\nstates checked: ", length(rows))
    println("DISAGREE with a cold rebuild (BLOCKER if >0): ", length(bad))
    for r in bad
        println("   ", r.root, " ", r.state, "  stale=", r.stale, " missing=", r.missing_)
    end
    println("probe verdict wrong (the edit did not take effect): ", length(wrong))
    for r in wrong
        println("   ", r.root, " ", r.state, "  hits=", r.probe_hits, " expected=", r.expect_diag)
    end
    return isempty(bad) && isempty(wrong)
end

end # module
