# If cross-file method matching went past argument counts to parameter TYPES, how
# many distinct (defining module, type name) pairs would one file's analysis have to
# resolve, and how many new dependency edges would that cost?
#
# Produced the numbers in `2026-07-31-type-resolution-budget.md`; kept verbatim so
# they and the code that made them stay in step. Usage:
#
#   include("docs/perf/typebudget.jl")
#   jw, _ = TypeBudget.load_folder("/path/to/repo"; project="/path/to/Project.toml")
#   idx, _ = TypeBudget.build_records(jw.runtime, root)
#   TypeBudget.report(first(TypeBudget.measure(jw.runtime, root; index=idx)))
#   TypeBudget.report_edges(jw.runtime, root, idx)
#
# Discard the first measurement after any edit: it is JIT (the recompute path cost
# 101 ms on its first run and 3 ms thereafter).
#
# Two hazards, both of which produced wrong numbers here before being caught:
#   * `string(::SourceText)` returns the REPR, not the content. Round-tripping a file
#     through it writes `SourceText("…")` into the workspace, the file stops parsing,
#     its inventory silently becomes 0 items, and everything downstream is wrong.
#     Use `.content`, and assert the item count after every `update_file!`.
#   * A "body-only" edit applied on top of a declaration-changing one is itself a
#     declaration change. Time a chain of consecutive same-kind edits, not alternating
#     ones.
module TypeBudget

using JuliaWorkspaces
const JW = JuliaWorkspaces
const SL = JuliaWorkspaces.StaticLint
const CP = JuliaWorkspaces.CSTParser
using JuliaWorkspaces: URI, TextFile, SourceText, JuliaWorkspace

# ---------------------------------------------------------------- workspace setup

function load_folder(folder::String; project::Union{Nothing,String}=nothing,
                    resolve_envs::Bool=false)
    files = TextFile[]
    for (dir, _, names) in walkdir(folder)
        occursin(r"(^|/)(\.git|node_modules|dist|\.vscode-test)(/|$)", dir) && continue
        for n in names
            p = joinpath(dir, n)
            lang = endswith(n, ".jl") ? "julia" :
                   (n == "Project.toml" || n == "Manifest.toml" || n == "JuliaProject.toml") ? "toml" : nothing
            lang === nothing && continue
            content = try
                read(p, String)
            catch
                continue
            end
            isvalid(content) || continue
            push!(files, TextFile(JW.filepath2uri(p), SourceText(content, lang)))
        end
    end
    jw = JuliaWorkspace(; resolve_workspace_environments=resolve_envs)
    JW.add_files!(jw, files)
    project !== nothing && JW.set_active_project!(jw, JW.filepath2uri(project))
    return jw, files
end

# ------------------------------------------------- syntactic parameter type names

# The `where`-bound type variable names of a signature, which are LOCAL to the
# method and must never be resolved against the defining module.
function where_vars(sig::CP.EXPR)
    tvars = Set{String}()
    s = sig
    while s isa CP.EXPR && CP.iswhere(s)
        for i in 2:length(s.args)
            a = s.args[i]
            # `T`, `T<:Bound`, `Lo<:T<:Hi`
            if CP.isidentifier(a)
                push!(tvars, CP.str_value(a))
            elseif a isa CP.EXPR && a.args !== nothing
                for c in a.args
                    CP.isidentifier(c) && push!(tvars, CP.str_value(c))
                end
            end
        end
        s = s.args[1]
    end
    return tvars
end

# A dotted access chain (`Base.Iterators.Zip`) as a qualified name, or `nothing`.
function dotted_path(x::CP.EXPR)
    if CP.isidentifier(x)
        return [CP.str_value(x)]
    elseif CP.is_getfield_w_quotenode(x)
        lhs = dotted_path(x.args[1])
        lhs === nothing && return nothing
        q = x.args[2]
        (q isa CP.EXPR && q.args !== nothing && length(q.args) >= 1 && CP.isidentifier(q.args[1])) || return nothing
        return vcat(lhs, CP.str_value(q.args[1]))
    end
    return nothing
end

# Every type NAME mentioned in a type-annotation expression, as written:
# `Vector{Foo}` → ["Vector", "Foo"]; `Union{A,Base.B}` → ["Union","A","Base.B"].
# These are exactly the names §17's resolution step would have to look up.
function type_names!(acc::Vector{Vector{String}}, x)
    x isa CP.EXPR || return acc
    # A quoted symbol is a VALUE, not a type: `NamedTuple{(:envPath,),Tuple{String}}`
    # and `Val{:x}` must not contribute `envPath`/`x` as type names. Descending here
    # is how a value position becomes a bogus record — and a name that happened to
    # collide with a real type (`Val{:String}`) would be worse than bogus.
    (x.head === :quotenode || x.head === :quote) && return acc
    p = dotted_path(x)
    if p !== nothing
        push!(acc, p)
        return acc
    end
    if x.args !== nothing
        for a in x.args
            type_names!(acc, a)
        end
    end
    return acc
end

# The type annotations of one method-defining EXPR's positional and keyword
# parameters, as name paths, minus `where`-bound type variables. Mirrors
# `func_nargs`'s traversal of the signature.
function param_type_names(x::CP.EXPR)
    sig = CP.get_sig(x)
    sig isa CP.EXPR || return Vector{String}[]
    tvars = where_vars(sig)
    sig = CP.rem_wheres_decls(sig)
    (sig isa CP.EXPR && sig.args !== nothing) || return Vector{String}[]

    acc = Vector{Vector{String}}()
    for i in 2:length(sig.args)
        arg = sig.args[i]
        collect_arg_types!(acc, arg)
    end
    # A `where` BOUND is resolvable and load-bounding too (`f(x::T) where T<:Real`
    # can only be compared once `Real` is known), so it counts; the tvar itself
    # does not.
    where_bounds!(acc, CP.get_sig(x))
    return [p for p in acc if !(length(p) == 1 && p[1] in tvars)]
end

function where_bounds!(acc, sig)
    s = sig
    while s isa CP.EXPR && CP.iswhere(s)
        for i in 2:length(s.args)
            a = s.args[i]
            CP.isidentifier(a) && continue          # a bare tvar, no bound
            type_names!(acc, a)
        end
        s = s.args[1]
    end
    return acc
end

function collect_arg_types!(acc, arg)
    arg isa CP.EXPR || return
    if CP.isdeclaration(arg)
        length(arg.args) >= 2 && type_names!(acc, arg.args[2])
    elseif CP.iskwarg(arg) || CP.issplat(arg)
        length(arg.args) >= 1 && collect_arg_types!(acc, arg.args[1])
    elseif arg.head === :parameters && arg.args !== nothing
        for a in arg.args
            collect_arg_types!(acc, a)
        end
    end
    return
end

# ------------------------------------------------------------- the record side

"One method's would-be §17 record: where its text lives, and the type names it mentions."
struct MethodRecord
    defmod::Vector{String}          # the module the method's TEXT sits in — where its type names resolve
    keypath::Vector{String}         # the module its NAME lands in (qualifier-resolved)
    name::String
    types::Vector{Vector{String}}
    nparams_annotated::Int
end

# Mirrors `derived_method_arities_index`'s walk, but records syntactic parameter
# types instead of argument counts, and keeps the DEFINING module (`loc`)
# alongside the qualifier-resolved key path — the two differ for `Base.foo(x::T)`,
# and it is `loc` that `T` resolves against.
function build_records(rt, root)
    tree = JW.derived_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    index = Dict{Tuple{Vector{String},String},Vector{MethodRecord}}()
    positions = Dict{URI,Any}()
    nitems = Ref(0)

    JW._walk_spliced_binding_items!(rt, root, String[], nothing, Set{URI}([root])) do F, item, loc
        item.arity === nothing && return
        resolved = isempty(item.qualifier) ? loc :
            JW._resolve_extension_qualifier(modpaths, loc, item.qualifier)
        (resolved === nothing || resolved ∉ modpaths) && return
        pos = get!(() -> JW.derived_item_positions(rt, F), positions, F)
        entry = get(pos, item.id, nothing)
        entry === nothing && return
        nitems[] += 1
        ts = param_type_names(entry.expr)
        rec = MethodRecord(loc, resolved, item.name, ts, count_annotated(entry.expr))
        push!(get!(() -> MethodRecord[], index, (resolved, item.name)), rec)
    end
    return index, nitems[]
end

# How many parameters carry an annotation at all (for the §17 collapse ratio).
function count_annotated(x::CP.EXPR)
    sig = CP.get_sig(x)
    sig isa CP.EXPR || return 0
    sig = CP.rem_wheres_decls(sig)
    (sig isa CP.EXPR && sig.args !== nothing) || return 0
    n = 0
    for i in 2:length(sig.args)
        acc = Vector{Vector{String}}()
        collect_arg_types!(acc, sig.args[i])
        isempty(acc) || (n += 1)
    end
    return n
end

# --------------------------------------------------------------- the call side

"What one file's analysis would have to resolve."
struct FileBudget
    file::URI
    ncalls::Int              # calls reaching the cross-file gate
    gated::Int               # of those, ones with a workspace method set
    pairs::Int               # DISTINCT (defining module, type name) — the number that matters
    mentions::Int            # non-distinct, for the collapse ratio
    names::Int               # distinct type names ignoring the defining module
    modules::Int             # distinct defining modules asked
end

# Every `:call` EXPR in a tree, outermost-first.
function each_call(f, x)
    x isa CP.EXPR || return
    CP.iscall(x) && f(x)
    x.args === nothing && return
    for a in x.args
        each_call(f, a)
    end
end

# The gate `tree_arities`/`_call_cross_file_arities` applies: a callee that
# resolves to a workspace binding/tree ref, is not shadowed by a local, and is
# tree-visible at the CALL SITE's module path. Returns the (path, name) key whose
# method set the check would consult, or `nothing`.
function gate_key(rt, root, path, call, meta)
    func_ref = SL.refof_call_func(call, meta)
    (func_ref isa SL.Binding || func_ref isa SL.TreeRef) || return nothing
    func_ref isa SL.Binding && SL._is_local_callee_binding(func_ref, meta) && return nothing
    nm = CP.get_name(call)
    (nm isa CP.EXPR && SL.isidentifier(nm)) || return nothing
    name = SL.valofid(nm)
    name === nothing && return nothing
    p = vcat(path, JW._in_file_module_names(call, meta))
    haskey(JW.derived_module_visible_names_idfree(rt, root, p), name) || return nothing
    return (p, name)
end

function file_budget(rt, root, index, file::URI)
    path = JW.derived_file_module_path(rt, root, file)
    path === nothing && return nothing
    cst = JW.derived_julia_legacy_syntax_tree(rt, file)
    cst isa CP.EXPR || return nothing
    meta = JW.derived_file_analysis(rt, root, file).meta

    ncalls = Ref(0); gated = Ref(0); mentions = Ref(0)
    pairs = Set{Tuple{Vector{String},String}}()
    names = Set{String}()
    mods = Set{Vector{String}}()

    each_call(cst) do call
        ncalls[] += 1
        key = gate_key(rt, root, path, call, meta)
        key === nothing && return
        recs = get(index, key, nothing)
        recs === nothing && return
        gated[] += 1
        for r in recs, p in r.types
            mentions[] += 1
            n = join(p, ".")
            push!(pairs, (r.defmod, n))
            push!(names, n)
            push!(mods, r.defmod)
        end
    end
    return FileBudget(file, ncalls[], gated[], length(pairs), mentions[], length(names), length(mods))
end

function measure(rt, root; index=nothing)
    index === nothing && ((index, _) = build_records(rt, root))
    out = FileBudget[]
    for f in JW.derived_tree_files(rt, root)
        b = file_budget(rt, root, index, f)
        b === nothing || push!(out, b)
    end
    return out, index
end

function report(bs::Vector{FileBudget}; label="")
    isempty(bs) && (println("no files"); return)
    ps = sort([b.pairs for b in bs])
    q(v, p) = v[clamp(ceil(Int, p * length(v)), 1, length(v))]
    println("== ", label, "  (", length(bs), " files)")
    println("  distinct (defmod, type name) pairs per file:")
    println("    min ", ps[1], "  p50 ", q(ps,0.5), "  p90 ", q(ps,0.9), "  p99 ", q(ps,0.99), "  MAX ", ps[end])
    println("    mean ", round(sum(ps)/length(ps), digits=1), "   files at 0: ", count(==(0), ps))
    println("  gated calls per file: p50 ", q(sort([b.gated for b in bs]),0.5),
            "  max ", maximum(b.gated for b in bs),
            "   (of ", sum(b.ncalls for b in bs), " calls total, ", sum(b.gated for b in bs), " gated)")
    println("  collapse: ", sum(b.mentions for b in bs), " mentions -> ", sum(b.pairs for b in bs),
            " pairs (", round(sum(b.mentions for b in bs)/max(1,sum(b.pairs for b in bs)), digits=1), "x)")
    println("  tail files:")
    for b in sort(bs; by=x->-x.pairs)[1:min(8,end)]
        println("    ", lpad(b.pairs, 5), " pairs  ", lpad(b.names, 4), " names  ", lpad(b.modules, 3), " mods  ",
                lpad(b.gated, 4), " gated  ", basename(JW.uri2filepath(b.file)))
    end
end

# ------------------------------------------------------- edges, not just pairs

"""
Per file: how many NEW Salsa dependency edges §17 resolution would add, under the
two candidate resolution shapes.

- `mod_edges_new`: resolution is a lookup into the defining module's
  `derived_module_visible_names_idfree` — one edge per distinct DEFINING module,
  minus the modules the analysis ALREADY depends on (it calls that same query at
  every call site's own path, via `tree_visible`).
- `pair_edges`: resolution is a per-name node — one edge per distinct
  (defining module, type name).

Also counts how many calls reach the gate under visibility ONLY (no meta ref
requirement) — an env-independent upper bound on the gated count.
"""
struct EdgeBudget
    file::URI
    already::Int
    mod_edges_all::Int
    mod_edges_new::Int
    pair_edges::Int
    gated::Int
    gated_upper::Int
end

function edge_budget(rt, root, index, file::URI)
    path = JW.derived_file_module_path(rt, root, file)
    path === nothing && return nothing
    cst = JW.derived_julia_legacy_syntax_tree(rt, file)
    cst isa CP.EXPR || return nothing
    meta = JW.derived_file_analysis(rt, root, file).meta

    already = Set{Vector{String}}()     # paths the analysis already queries
    defmods = Set{Vector{String}}()
    pairs = Set{Tuple{Vector{String},String}}()
    gated = Ref(0); upper = Ref(0)

    each_call(cst) do call
        p = vcat(path, JW._in_file_module_names(call, meta))
        push!(already, p)               # `tree_visible` is consulted for every call
        nm = CP.get_name(call)
        (nm isa CP.EXPR && SL.isidentifier(nm)) || return
        name = SL.valofid(nm)
        name === nothing && return
        vis = haskey(JW.derived_module_visible_names_idfree(rt, root, p), name)
        vis || return
        haskey(index, (p, name)) && (upper[] += 1)
        gate_key(rt, root, path, call, meta) === nothing && return
        recs = get(index, (p, name), nothing)
        recs === nothing && return
        gated[] += 1
        for r in recs, tp in r.types
            push!(defmods, r.defmod)
            push!(pairs, (r.defmod, join(tp, ".")))
        end
    end
    return EdgeBudget(file, length(already), length(defmods),
                      length(setdiff(defmods, already)), length(pairs), gated[], upper[])
end

function report_edges(rt, root, index; label="")
    bs = EdgeBudget[]
    for f in JW.derived_tree_files(rt, root)
        b = edge_budget(rt, root, index, f)
        b === nothing || push!(bs, b)
    end
    isempty(bs) && (println("no files"); return bs)
    q(v, p) = (s = sort(v); s[clamp(ceil(Int, p*length(s)), 1, length(s))])
    println("== ", label, " (", length(bs), " files)")
    for (nm, v) in (("NEW module-map edges", [b.mod_edges_new for b in bs]),
                    ("all defining modules", [b.mod_edges_all for b in bs]),
                    ("per-name edges (pairs)", [b.pair_edges for b in bs]))
        println("  ", rpad(nm, 24), " p50 ", q(v,0.5), "  p90 ", q(v,0.9), "  MAX ", maximum(v),
                "   mean ", round(sum(v)/length(v), digits=1))
    end
    println("  gated calls: ", sum(b.gated for b in bs), "   visibility-only upper bound: ",
            sum(b.gated_upper for b in bs))
    return bs
end

# ------------------------------------------------------------------- censuses

# Every annotated parameter's type expression, classified by SHAPE — the split that
# decides how the implementation is sliced.
function classify_shapes(x::CP.EXPR)
    sig = CP.get_sig(x); sig isa CP.EXPR || return Symbol[]
    tv = where_vars(sig)
    sig = CP.rem_wheres_decls(sig)
    (sig isa CP.EXPR && sig.args !== nothing) || return Symbol[]
    out = Symbol[]
    for i in 2:length(sig.args)
        a = sig.args[i]
        a isa CP.EXPR || continue
        te = CP.isdeclaration(a) && length(a.args) >= 2 ? a.args[2] :
             ((CP.iskwarg(a) || CP.issplat(a)) && length(a.args) >= 1 && a.args[1] isa CP.EXPR &&
               CP.isdeclaration(a.args[1]) && length(a.args[1].args) >= 2 ? a.args[1].args[2] : nothing)
        te === nothing && continue
        push!(out, CP.isidentifier(te) ? (CP.str_value(te) in tv ? :tvar : :bare) :
                   CP.iscurly(te) ? :parametric :
                   CP.is_getfield_w_quotenode(te) ? :qualified : :other)
    end
    return out
end

function shape_census(rt, roots)
    tot = Dict{Symbol,Int}()
    for (_, u) in sort(collect(roots); by=x -> x[1])
        for f in JW.derived_tree_files(rt, u)
            pos = JW.derived_item_positions(rt, f)
            for it in JW.derived_file_inventory(rt, f).items
                it.arity === nothing && continue
                e = get(pos, it.id, nothing)
                e === nothing && continue
                for s in classify_shapes(e.expr)
                    tot[s] = get(tot, s, 0) + 1
                end
            end
        end
    end
    return tot
end

# Where each recorded name would actually resolve: the defining module's own map, the
# Base/Core store, or neither (the permissive-unknown case). `env` may be the
# stdlib-only env — Base/Core ship bundled, so no warm store is needed.
function leg_census(rt, roots, env)
    tally = Dict(:modmap => 0, :basecore => 0, :neither => 0)
    unresolved = Set{String}()
    syms = SL.getsymbols(env)
    for (_, u) in sort(collect(roots); by=x -> x[1])
        local ix
        try
            ix, _ = build_records(rt, u)
        catch
            continue
        end
        prs = Set{Tuple{Vector{String},String}}()
        for f in JW.derived_tree_files(rt, u)
            path = JW.derived_file_module_path(rt, u, f)
            path === nothing && continue
            cst = JW.derived_julia_legacy_syntax_tree(rt, f)
            cst isa CP.EXPR || continue
            meta = try
                JW.derived_file_analysis(rt, u, f).meta
            catch
                continue
            end
            each_call(cst) do call
                k = gate_key(rt, u, path, call, meta)
                k === nothing && return
                recs = get(ix, k, nothing)
                recs === nothing && return
                for rr in recs, q in rr.types
                    push!(prs, (rr.defmod, join(q, ".")))
                end
            end
        end
        for (dm, n) in prs
            head = occursin('.', n) ? String(split(n, '.')[1]) : n
            if haskey(JW.derived_module_visible_names_idfree(rt, u, dm), head)
                tally[:modmap] += 1
            elseif any(m -> (st = get(syms, m, nothing)) !== nothing && haskey(st.vals, Symbol(head)),
                       (:Base, :Core))
                tally[:basecore] += 1
            else
                tally[:neither] += 1
                push!(unresolved, n)
            end
        end
    end
    return tally, unresolved
end

# One store-leg resolution, as the Resolve step would do it. The hops matter: `String`
# is a constructor `FunctionStore` and `AbstractString` a `VarRef`, so testing for
# `DataTypeStore` without following them concludes that `String` is not a type.
function resolve_store(name::String, env)
    syms = SL.getsymbols(env)
    for m in (:Base, :Core)
        st = get(syms, m, nothing)
        st === nothing && continue
        v = get(st.vals, Symbol(name), nothing)
        v === nothing && continue
        return SL.get_eventual_datatype(SL.maybe_lookup(v, env), env)
    end
    return nothing
end

end # module
