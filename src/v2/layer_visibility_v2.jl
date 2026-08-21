# Layer 2½ of the v2 stack: per-module visible names — which names are
# reachable inside a module, and where each comes from. A port of v1's
# layer_visibility.jl algorithm onto the v2 module tree.
#
#   THE ENVIRONMENT EDGE. `:external` import targets resolve through the
#   plain-data queries in src/layer_v2_env_seam.jl (outside src/v2 — see its
#   header for why) at exactly four places: `_v2_external_bring_ins`, the
#   `:external` arm of `_v2_member_lookup`, the `:external` arm of
#   `_v2_extend_target`, and the `:external` rules in
#   `_v2_wildcard_using_unresolved`. A MISSING store keeps v1's store-missing
#   behavior at each: bind only the module name, members `:unknown`,
#   extensions fail, wildcard counts as unresolved. Two deliberate absences
#   remain vs v1: the implicit `using Base`/`Core` MEMBER fallback inside the
#   `:tree`/`:workspace_package` member-lookup arms, and macro-declared
#   names — both answer `:unknown` here, which still BINDS the name, so
#   consumers that look names up by name (missing_reference) stay safe.
#
# Everything that leaves this layer is plain data (names, kinds, `V2ItemRef`s)
# — the same purity contract the rest of v2 keeps. The invalidation design is
# v1's, ported intact:
#   - the full `derived_v2_module_visible_names` carries item ids and changes
#     whenever ids shift;
#   - its ID-FREE FACE (`derived_v2_module_visible_names_idfree`) drops the
#     ids, so reordering two same-kind declarations backdates it and
#     hit-testing consumers never re-execute;
#   - the per-name `derived_v2_visible_item` confines id-shift re-execution to
#     the names a consumer actually referenced.

"""
    V2VisibleName(kind, origin, item, origin_module)

One name visible in a module. `kind` is the declaring item's kind, `:module`,
`:external_symbol` (bound through an external import — the module name, an
expanded export, or a colon-list member resolved against the store), or
`:unknown` (bound lexically but unverifiable). `origin`:
`:declared` | `:using_tree` | `:using_workspace_package` | `:using_external` |
`:import_binding`. `item` is the declaring `V2ItemRef` when the name traces to
a tree declaration, else `nothing`. `origin_module` is the declaring module's
path for `:declared`, the import target's path otherwise.
"""
@auto_hash_equals struct V2VisibleName
    kind::Symbol
    origin::Symbol
    item::Union{Nothing,V2ItemRef}
    origin_module::Vector{String}
end

"""
    derived_v2_module_self_and_parents(rt, root, path) -> Vector{Vector{String}}

The enclosing-module chain for `path`: itself, then each shorter prefix, down
to the synthetic root. Purely structural on `path`.
"""
Salsa.@derived function derived_v2_module_self_and_parents(rt, root, path)
    chain = Vector{String}[]
    p = copy(path)
    push!(chain, copy(p))
    while !isempty(p)
        pop!(p)
        push!(chain, copy(p))
    end
    return chain
end

_v2_tier(origin::Symbol) = origin === :declared ? 3 : origin === :import_binding ? 2 : 1

# One visibility entry: the bound name, its `V2VisibleName`, and — when the
# binding is module-valued — the `V2ImportTarget` the name DENOTES (full sort +
# path), `nothing` otherwise. The third slot feeds pass 1's module-target
# ledger, which the `:unresolved` re-attempt chases: recording the underlying
# target sort at binding time is what keeps an import-bound workspace package
# `:workspace_package` through a pass-2 extension, instead of guessing the
# sort from the binding's `origin`.
const _V2BringIn = Tuple{String,V2VisibleName,Union{Nothing,V2ImportTarget}}

"""
The name an import statement binds for the TARGET MODULE ITSELF, or `nothing`.
A whole-module `using`/`import X` binds `X` or its alias; a colon-list binds
the module only when it lists the module's own name (per-symbol alias wins).
"""
_v2_bound_module_name(target::V2ImportTarget, alias) =
    isempty(target.path) ? nothing : (alias === nothing ? last(target.path) : alias)

function _v2_bound_module_name(ri::V2ResolvedImport)
    isempty(ri.symbols) && return _v2_bound_module_name(ri.target, ri.alias)
    isempty(ri.target.path) && return nothing
    hit = findfirst(s -> s.name == last(ri.target.path), ri.symbols)
    hit === nothing && return nothing
    return ri.symbols[hit].alias === nothing ? ri.symbols[hit].name : ri.symbols[hit].alias
end

# ENV EDGE: the `:external` bring-in arm, resolved through the seam queries.
# Store MISSING (unindexed dependency or genuinely absent package) keeps v1's
# behavior: Julia binds the statement's name lexically whatever the store
# situation, and the import statement is where any failure is reported once —
# so the bound name must exist here or every use site would contradict that
# with a spurious missing-ref; exported names are unknowable without the
# store, so only the module name binds. Store PRESENT: a wildcard `using`
# additionally brings in each export as `:external_symbol`, with a ledger
# target when the export is module-valued (or names the module itself). The
# module-name ledger entry keeps the denoted target either way, so
# member/relative chains through the binding re-attempt at their own sites.
function _v2_external_bring_ins(rt, root, kind::Symbol, target::V2ImportTarget, alias)::Vector{_V2BringIn}
    entries = _V2BringIn[]
    tp = target.path
    origin = kind === :using ? :using_external : :import_binding
    exports = derived_v2_external_module_exports(rt, root, tp)
    if exports !== nothing && kind === :using
        modnames = derived_v2_external_exported_module_names(rt, root, tp)
        for name in exports
            mt = if name == tp[end]
                target   # a module's own name in its export list denotes the module itself
            elseif name in modnames
                V2ImportTarget(:external, vcat(tp, [name]))
            else
                nothing
            end
            push!(entries, (name, V2VisibleName(:external_symbol, :using_external, nothing, tp), mt))
        end
    end
    bound = _v2_bound_module_name(target, alias)
    bound === nothing ||
        push!(entries, (bound, V2VisibleName(:external_symbol, origin, nothing, tp), target))
    return entries
end

# Bring in the names for one fully-resolved (never `:unresolved`) target.
# `visited` guards cross-root recursion for `:workspace_package` targets and
# already contains every root on the current chain, INCLUDING this call's own.
function _v2_target_bring_ins(rt, root, kind::Symbol, target::V2ImportTarget, alias, visited::Set{URI})::Vector{_V2BringIn}
    entries = _V2BringIn[]
    tp = target.path
    isempty(tp) && return entries

    if target.sort === :tree
        origin = kind === :using ? :using_tree : :import_binding
        if kind === :using
            names = derived_v2_module_names(rt, root, tp)
            exports = derived_v2_module_exports(rt, root, tp)
            declared = derived_v2_module_declared(rt, root, tp)
            for name in exports
                if haskey(names, name)
                    mt = names[name] === :module ? V2ImportTarget(:tree, vcat(tp, [name])) : nothing
                    push!(entries, (name, V2VisibleName(names[name], :using_tree, declared[name], tp), mt))
                else
                    # A re-export of a name the submodule brought in through
                    # its OWN imports (`using ..Prov; export bar`): bind it so
                    # a use isn't a spurious missing-ref; kind/item unknowable
                    # without resolving the submodule's own imports, which a
                    # same-root `using` cycle could not do without re-entering
                    # an in-progress query.
                    push!(entries, (name, V2VisibleName(:unknown, :using_tree, nothing, tp), nothing))
                end
            end
        end
        bound = _v2_bound_module_name(target, alias)
        bound === nothing ||
            push!(entries, (bound, V2VisibleName(:module, origin, derived_v2_module_declared_at(rt, root, tp), tp), target))

    elseif target.sort === :workspace_package
        roots = derived_v2_workspace_package_roots(rt)
        pkg = tp[1]
        haskey(roots, pkg) || return entries   # missing package: contributes nothing
        entry = roots[pkg]
        origin = kind === :using ? :using_workspace_package : :import_binding
        if kind === :using
            # Recurse into the package's OWN visible names (cross-root), gated
            # by ITS OWN exports — what lets a workspace package re-export a
            # name it itself brought in via `using`, and exactly where a
            # dev-cycle would recurse forever without `visited`.
            sub_visible = _v2_cross_root_visible_names(rt, entry, tp, visited)
            exports = derived_v2_module_exports(rt, entry, tp)
            for name in exports
                haskey(sub_visible, name) || continue
                vn = sub_visible[name]
                # Optimistic ledger entry for an exported submodule —
                # `_v2_extend_target` re-validates against the package's tree
                # before any re-attempt uses it.
                mt = vn.kind === :module ? V2ImportTarget(:workspace_package, name == tp[end] ? tp : vcat(tp, [name])) : nothing
                push!(entries, (name, V2VisibleName(vn.kind, :using_workspace_package, vn.item, tp), mt))
            end
        end
        bound = _v2_bound_module_name(target, alias)
        bound === nothing ||
            push!(entries, (bound, V2VisibleName(:module, origin, derived_v2_module_declared_at(rt, entry, tp), tp), target))

    elseif target.sort === :external
        append!(entries, _v2_external_bring_ins(rt, root, kind, target, alias))
    end
    return entries
end

# One member's (kind, item, origin_module, ledger-target) for an explicit
# colon-list against a fully-resolved target. A member naming the target
# module ITSELF (`using Compiler: Compiler as CC`) resolves to the module's
# self-binding — checked FIRST (a precedence choice; a same-named inner
# declaration loses this tiebreak). A member not found still gets bound — Julia
# binds the name lexically even when it turns out to be wrong — as `:unknown`.
function _v2_member_lookup(rt, root, target::V2ImportTarget, member_name::String, visited::Set{URI})
    tp = target.path
    if target.sort === :tree
        if member_name == tp[end] && v2_module_node(derived_v2_module_tree(rt, root), tp) !== nothing
            return (:module, derived_v2_module_declared_at(rt, root, tp), tp, target)
        end
        names = derived_v2_module_names(rt, root, tp)
        # No macro-declared or implicit-Base fallback here (both env-side).
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
        mt = names[member_name] === :module ? V2ImportTarget(:tree, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_v2_module_declared(rt, root, tp)[member_name], tp, mt)
    elseif target.sort === :workspace_package
        roots = derived_v2_workspace_package_roots(rt)
        haskey(roots, tp[1]) || return (:unknown, nothing, tp, nothing)
        entry = roots[tp[1]]
        entry in visited && return (:unknown, nothing, tp, nothing)
        if member_name == tp[end] && v2_module_node(derived_v2_module_tree(rt, entry), tp) !== nothing
            return (:module, derived_v2_module_declared_at(rt, entry, tp), tp, target)
        end
        names = derived_v2_module_names(rt, entry, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
        mt = names[member_name] === :module ? V2ImportTarget(:workspace_package, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_v2_module_declared(rt, entry, tp)[member_name], tp, mt)
    elseif target.sort === :external
        # ENV EDGE: the member gate is the store's `haskey` (NOT export-gated —
        # `import Base: Filesystem` works); a missing store keeps `:unknown`.
        member_name == tp[end] &&
            derived_v2_external_module_exports(rt, root, tp) !== nothing &&
            return (:external_symbol, nothing, tp, target)
        mk = derived_v2_external_module_member_kind(rt, root, tp, member_name)
        (mk === :missing_store || mk === :absent) && return (:unknown, nothing, tp, nothing)
        mt = mk === :module ? V2ImportTarget(:external, vcat(tp, [member_name])) : nothing
        return (:external_symbol, nothing, tp, mt)
    else
        return (:unknown, nothing, tp, nothing)
    end
end

# `kind == :import` OR `kind == :using` with an explicit colon-list: both bind
# EXACTLY the listed names (per-symbol alias wins), origin `:import_binding`
# either way — the using/import distinction only affects method-extension
# permissions, not what's visible.
function _v2_explicit_symbol_bring_ins(rt, root, target::V2ImportTarget, symbols, visited::Set{URI})::Vector{_V2BringIn}
    entries = _V2BringIn[]
    for sym in symbols
        bound = sym.alias !== nothing ? sym.alias : sym.name
        kind, item, origin_module, mt = _v2_member_lookup(rt, root, target, sym.name, visited)
        push!(entries, (bound, V2VisibleName(kind, :import_binding, item, origin_module), mt))
    end
    return entries
end

# ── the `:unresolved` ledger re-attempt ─────────────────────────────────────

# Recompute (anchor, remaining-segments) for an `:unresolved` import's raw
# path (`V2ImportTarget.path` keeps the ORIGINAL written segments, dots
# included, for `:unresolved`), mirroring `_v2_classify_import`'s anchor logic
# exactly. `nothing` when the import is fundamentally invalid (relative pop
# past the root).
function _v2_unresolved_anchor_and_segs(rt, root, AP::Vector{String}, raw::Vector{String})
    isempty(raw) && return nothing

    ndots = 0
    while ndots < length(raw) && raw[ndots + 1] == "."
        ndots += 1
    end

    if ndots > 0
        pops = ndots - 1
        pops > length(AP) && return nothing
        anchor = AP[1:end - pops]
        segs = raw[ndots + 1:end]
        isempty(segs) && return nothing
        return (anchor, segs)
    end

    # ndots == 0: the "anchor found, mid-path miss" case — rediscover the
    # anchor via the identical outward walk.
    tree = derived_v2_module_tree(rt, root)
    M = copy(AP)
    while true
        v2_module_node(tree, vcat(M, [raw[1]])) !== nothing && return (M, raw)
        isempty(M) && return nothing
        pop!(M)
    end
end

# How many of `segs`, taken in order from `anchor`, resolve as nested tree
# modules — locating the first miss is the point.
function _v2_deepest_tree_prefix(rt, root, anchor::Vector{String}, segs::Vector{String})
    tree = derived_v2_module_tree(rt, root)
    resolved = copy(anchor)
    k = 0
    for seg in segs
        candidate = vcat(resolved, [seg])
        v2_module_node(tree, candidate) === nothing && break
        resolved = candidate
        k += 1
    end
    return k
end

# Continue resolving `rest` from a ledgered module-valued binding's target,
# producing a synthesized target — or `nothing` when the extension doesn't
# validate. The sort is `base`'s RECORDED sort, never guessed from an origin.
# A tree walk stuck mid-`rest` continues through ONE ledgered binding at the
# stuck module (`_v2_extend_through_binding`) — the `import ..JSONRPC.JSON`
# pattern; bounded because `rest` strictly shrinks and `visited` blocks
# package cycles.
function _v2_extend_target(rt, root, base::V2ImportTarget, rest::Vector{String}, visited::Set{URI})
    full = vcat(base.path, rest)
    if base.sort === :external
        # ENV EDGE: the extension validates iff the full path resolves as
        # nested module stores; a missing store fails as before.
        return derived_v2_external_module_exports(rt, root, full) === nothing ?
            nothing : V2ImportTarget(:external, full)
    elseif base.sort === :workspace_package
        roots = derived_v2_workspace_package_roots(rt)
        haskey(roots, full[1]) || return nothing
        entry = roots[full[1]]
        entry in visited && return nothing
        v2_module_node(derived_v2_module_tree(rt, entry), full) === nothing || return V2ImportTarget(:workspace_package, full)
        cont = _v2_extend_through_binding(rt, entry, base.path, rest, union(visited, Set([entry])))
        cont === nothing && return nothing
        if cont.sort === :tree
            # A tree target in the PACKAGE's root is a workspace-package
            # target from the caller's perspective.
            (isempty(cont.path) || cont.path[1] != full[1]) && return nothing
            return V2ImportTarget(:workspace_package, cont.path)
        end
        return cont
    elseif base.sort === :tree
        v2_module_node(derived_v2_module_tree(rt, root), full) === nothing || return V2ImportTarget(:tree, full)
        return _v2_extend_through_binding(rt, root, base.path, rest, visited)
    end
    return nothing
end

function _v2_extend_through_binding(rt, croot, base_path::Vector{String}, rest::Vector{String}, visited::Set{URI})
    isempty(rest) && return nothing
    k = _v2_deepest_tree_prefix(rt, croot, base_path, rest)
    k >= length(rest) && return nothing
    stuck_at = vcat(base_path, rest[1:k])
    v2_module_node(derived_v2_module_tree(rt, croot), stuck_at) === nothing && return nothing
    _, modtargets = _v2_visible_names_pass1(rt, croot, stuck_at, visited)
    haskey(modtargets, rest[k + 1]) || return nothing
    return _v2_extend_target(rt, croot, modtargets[rest[k + 1]], rest[k + 2:end], visited)
end

# The ledger case: a relative (or absolute-mid-path-miss) import whose
# post-anchor first segment doesn't name a tree submodule, but names a
# PASS-1-visible module-valued binding in the anchor module (the
# `using ..SymbolServer` pattern).
#
# Bounded to a single re-attempt (2 passes total, not a fixpoint): the anchor
# lookup is deliberately `_v2_visible_names_pass1` — NEVER the fully
# re-attempted result, which would recurse into the SAME unresolved-import
# resolution when `stuck_at == path` (a single-dot `using .X` failing at
# depth 0, whose anchor IS the module being resolved).
function _v2_reattempt_unresolved(rt, root, path::Vector{String}, ri::V2ResolvedImport, visited::Set{URI})
    split = _v2_unresolved_anchor_and_segs(rt, root, path, ri.target.path)
    split === nothing && return nothing
    anchor, segs = split

    k = _v2_deepest_tree_prefix(rt, root, anchor, segs)
    k >= length(segs) && return nothing

    stuck_at = vcat(anchor, segs[1:k])
    cand_name = segs[k + 1]
    rest = segs[k + 2:end]

    _, modtargets = _v2_visible_names_pass1(rt, root, stuck_at, visited)
    haskey(modtargets, cand_name) || return nothing

    return _v2_extend_target(rt, root, modtargets[cand_name], rest, visited)
end

# ── pass 1 + pass 2 assembly ────────────────────────────────────────────────

# One lockstep write to pass 1's two dicts. A non-module binding overwriting a
# module-valued one must DROP the stale ledger entry, so both dicts are only
# written through here.
function _v2_record!(result, modtargets, name::String, vn::V2VisibleName, mt::Union{Nothing,V2ImportTarget})
    result[name] = vn
    if mt === nothing
        delete!(modtargets, name)
    else
        modtargets[name] = mt
    end
    return nothing
end

# Pass 1, tiers in precedence order (using bring-ins < import bindings <
# declared; within a tier, last wins). `:unresolved` targets contribute
# nothing here — that's pass 2. Returns `(result, modtargets)`.
function _v2_visible_names_pass1(rt, root, path::Vector{String}, visited::Set{URI})
    result = Dict{String,V2VisibleName}()
    modtargets = Dict{String,V2ImportTarget}()

    # Tier 1: whole-module `using` (colon-lists are tier 2 regardless of kind).
    for ri in derived_v2_module_imports(rt, root, path)
        (ri.kind === :using && isempty(ri.symbols) && ri.target.sort !== :unresolved) || continue
        for (name, vn, mt) in _v2_target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
            _v2_record!(result, modtargets, name, vn, mt)
        end
    end

    # Tier 2: import bindings.
    for ri in derived_v2_module_imports(rt, root, path)
        ri.target.sort === :unresolved && continue
        if !isempty(ri.symbols)
            for (name, vn, mt) in _v2_explicit_symbol_bring_ins(rt, root, ri.target, ri.symbols, visited)
                _v2_record!(result, modtargets, name, vn, mt)
            end
        elseif ri.kind === :import
            for (name, vn, mt) in _v2_target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
                _v2_record!(result, modtargets, name, vn, mt)
            end
        end
    end

    # Tier 3: declared. First the module's SELF-binding (`Foo.Foo === Foo`) —
    # its `origin_module` is the DECLARING module's path (the parent), which is
    # exactly why the ledger records the denoted module's FULL path separately.
    # (v2 has no `:testitem` module nodes, so v1's exclusion for them is moot.)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    if node !== nothing && !isempty(path)
        _v2_record!(result, modtargets, path[end],
            V2VisibleName(:module, :declared, node.declared_at, path[1:end - 1]),
            V2ImportTarget(:tree, path))
    end
    declared = derived_v2_module_declared(rt, root, path)
    for (name, kind) in derived_v2_module_names(rt, root, path)
        mt = kind === :module ? V2ImportTarget(:tree, vcat(path, [name])) : nothing
        _v2_record!(result, modtargets, name, V2VisibleName(kind, :declared, declared[name], path), mt)
    end

    return (result, modtargets)
end

# The workspace-package entry roots reachable from `root` by following
# whole-module using/import edges of workspace packages. A SUPERSET of what
# `_v2_cross_root_visible_names` would actually recurse into — which is what
# makes the acyclicity check conservative: an over-counted edge can only turn
# a `false` (memoize) into a `true` (stay on the cycle-safe path), never the
# unsafe reverse.
function _v2_wp_out_roots(rt, root::URI, wp_roots::Dict{String,URI})
    tree = derived_v2_module_tree(rt, root)
    outs = Set{URI}()
    for node in tree.modules
        for ri in derived_v2_module_imports(rt, root, node.path)
            ri.target.sort === :workspace_package || continue
            isempty(ri.target.path) && continue
            dep = get(wp_roots, ri.target.path[1], nothing)
            dep === nothing || push!(outs, dep)
        end
    end
    return outs
end

# Whether the workspace-package using-subgraph reachable from `entry` contains
# a cycle (grey/black DFS). This decides whether a cross-root recursion may
# route through the memoized `derived_v2_module_visible_names` (which
# necessarily re-enters with an EMPTY visited set): on a cycle, memoizing
# would either Salsa-re-enter an in-progress key (infinite recursion — Salsa
# has no in-progress guard) or cache a cycle-truncated, entry-dependent value
# (poisoning). Deliberately NOT memoized as a whole — it runs in the
# consumer's frame; the wp graph is tiny.
function _v2_wp_subgraph_has_cycle(rt, entry::URI)
    wp_roots = derived_v2_workspace_package_roots(rt)
    onstack = Set{URI}()
    done = Set{URI}()
    function visit(u::URI)
        push!(onstack, u)
        for v in _v2_wp_out_roots(rt, u, wp_roots)
            v in done && continue
            v in onstack && return true          # back-edge: cycle
            visit(v) && return true
        end
        delete!(onstack, u)
        push!(done, u)
        return false
    end
    return visit(entry)
end

# One cross-root workspace-package recursion, memoized when it is safe to be:
# an acyclic `entry`'s visible names are caller-independent, so two consumers
# of the same package share ONE computation. Guard order is load-bearing.
function _v2_cross_root_visible_names(rt, entry::URI, tp::Vector{String}, visited::Set{URI})
    (entry in visited || _v2_wp_subgraph_has_cycle(rt, entry)) &&
        return _v2_visible_names_impl(rt, entry, tp, visited)
    return derived_v2_module_visible_names(rt, entry, tp)
end

# The full (pass 1 + pass 2) computation, threaded with the cross-root
# `visited` set. `visited` already containing `root` means this root is on the
# current resolution chain — a cycle, so it contributes nothing further.
function _v2_visible_names_impl(rt, root, path::Vector{String}, visited::Set{URI})::Dict{String,V2VisibleName}
    return Salsa.TraceLogging.@trace(
        "v2_visible_names_recurse",
        (; root=string(root), path=path),
        _v2_visible_names_impl_body(rt, root, path, visited))
end

function _v2_visible_names_impl_body(rt, root, path::Vector{String}, visited::Set{URI})::Dict{String,V2VisibleName}
    root in visited && return Dict{String,V2VisibleName}()
    visited = union(visited, Set([root]))

    result, _ = _v2_visible_names_pass1(rt, root, path, visited)

    # Pass 2: the ledger re-attempt — single bounded pass; see
    # `_v2_reattempt_unresolved`. Both statement forms are re-attempted.
    for ri in derived_v2_module_imports(rt, root, path)
        ri.target.sort === :unresolved || continue
        target = _v2_reattempt_unresolved(rt, root, path, ri, visited)
        target === nothing && continue

        if !isempty(ri.symbols)
            entries = _v2_explicit_symbol_bring_ins(rt, root, target, ri.symbols, visited)
            tier = 2   # colon-lists are import_binding-tier regardless of kind
        else
            entries = _v2_target_bring_ins(rt, root, ri.kind, target, ri.alias, visited)
            tier = ri.kind === :using ? 1 : 2
        end
        for (name, vn, _) in entries
            existing = get(result, name, nothing)
            # On an EQUAL tier the existing binding wins (first-wins), unlike
            # pass 1's within-tier last-wins — a re-attempted resolution never
            # displaces an equally-ranked binding that resolved without one.
            existing !== nothing && _v2_tier(existing.origin) >= tier && continue
            result[name] = vn
        end
    end

    return result
end

"""
    derived_v2_module_visible_names(rt, root, path) -> Dict{String,V2VisibleName}

The names reachable inside the module at `path` in `root`'s v2 tree, through
its own declarations and its classified imports. Empty when `path` names no
module (every underlying selector degrades to empty).
"""
Salsa.@derived function derived_v2_module_visible_names(rt, root, path)
    return _v2_visible_names_impl(rt, root, path, Set{URI}())
end

"The id-free per-name face: everything except the id-carrying `item`."
const V2VisibleNameFace = @NamedTuple{kind::Symbol, origin::Symbol, origin_module::Vector{String}}

"""
    derived_v2_module_visible_names_idfree(rt, root, path) -> Dict{String,V2VisibleNameFace}

The id-free face of `derived_v2_module_visible_names`: an item-id shift
(reordering two same-kind declarations) changes the full dict but leaves this
projection untouched, so hit-testing consumers backdate. Consumers that need
the declaring ref for a name they actually reference use the per-name
`derived_v2_visible_item`.
"""
Salsa.@derived function derived_v2_module_visible_names_idfree(rt, root, path)
    visible = derived_v2_module_visible_names(rt, root, path)
    return Dict{String,V2VisibleNameFace}(
        name => (kind=vn.kind, origin=vn.origin, origin_module=vn.origin_module)
        for (name, vn) in visible)
end

"""
    derived_v2_visible_item(rt, root, path, name) -> Union{Nothing,V2ItemRef}

The declaring ref of one visible name; `nothing` when absent or item-less.
Per-name so an id shift re-executes only the names consumers actually asked
about.
"""
Salsa.@derived function derived_v2_visible_item(rt, root, path, name)
    visible = derived_v2_module_visible_names(rt, root, path)
    vn = get(visible, name, nothing)
    return vn === nothing ? nothing : vn.item
end

# ENV EDGE in the `:external` rules: an external wildcard resolves iff its
# store exists (mirrors v1's `_wildcard_using_unresolved` — presence only, not
# export-emptiness; an indexed-but-exportless store resolves there too, and
# matching v1 exactly is what the corpus differential holds us to).
function _v2_wildcard_using_unresolved(rt, root, path::Vector{String}, ri::V2ResolvedImport)
    t = ri.target
    if t.sort === :tree
        return false
    elseif t.sort === :external
        return derived_v2_external_module_exports(rt, root, t.path) === nothing
    elseif t.sort === :workspace_package
        # v1's deliberate conservatism: the package's source-analyzed export
        # view is incomplete under computed includes and macro re-exports.
        return true
    else # :unresolved
        re = _v2_reattempt_unresolved(rt, root, path, ri, Set{URI}())
        re === nothing && return true
        re.sort === :external &&
            return derived_v2_external_module_exports(rt, root, re.path) === nothing
        re.sort === :workspace_package && return true
        return false
    end
end

"""
    derived_v2_module_unresolved_wildcard_using(rt, root, path) -> Bool

Whether the module contains a wildcard `using` (non-colon form) whose target
cannot be resolved — in which case it may bring in ANY name, and bare
missing-reference reporting in the module is meaningless noise. Bool-valued
and id-free, so sibling edits backdate.
"""
Salsa.@derived function derived_v2_module_unresolved_wildcard_using(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    node === nothing && return false
    for ri in node.imports
        ri.kind === :using || continue
        isempty(ri.symbols) || continue   # colon form binds only the listed names
        _v2_wildcard_using_unresolved(rt, root, path, ri) && return true
    end
    return false
end
