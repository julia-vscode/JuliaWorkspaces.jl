# Layer 3 (env seam) of the inventory architecture: per-module visible
# names — the names reachable in a module through its classified imports
# (`derived_module_imports`, from layer_module_tree.jl), gated by the
# workspace's own packages (`derived_workspace_package_roots`) and, for
# `:external` targets, the SymbolServer-backed environment
# (`derived_environment`/`derived_stdlib_only_env`).
#
# This is the one place in the inventory architecture that reads the
# environment. `VisibleName` (and everything this layer returns) stays plain
# data regardless: `ModuleStore`/`ExternalEnv` are consulted at query time and
# only plain `Symbol`/`String` names, and `ItemRef`s already owned by the
# module tree, ever get carried into a returned value. Storing a
# `ModuleStore`/`ExternalEnv` in a derived value would break Salsa's
# structural-equality cutoff the same way storing one in the module tree
# would (see layer_module_tree.jl's own header) — `ExternalEnv` compares by
# identity, not structure.

"""
    VisibleName

One name visible inside a module, and where it comes from.

- `kind`: the item kind (`:function`, `:struct`, ...), `:module` for a
  (tree- or workspace-package-) module binding, or `:external_symbol` for
  anything reached through the environment.
- `origin`: `:declared` (the module's own binding), `:using_tree` /
  `:using_workspace_package` / `:using_external` (brought in by a whole-module
  `using`), or `:import_binding` (an explicit `import`/colon-list binding,
  including a whole-module `import`'s bare submodule name).
- `item`: for names traced back to a tree declaration (this module's own, or
  the ORIGIN module's, for `using`/`import` of a tree or workspace-package
  target) — the defining `ItemRef`. `nothing` for `:external_symbol` names
  (the environment has no `ItemRef`s) and for names that couldn't be
  cross-checked against the origin's own declarations.
- `origin_module`: the tree path (`:declared`/`:using_tree`), workspace
  package path (`["Pkg"]`/`["Pkg","Sub"]`, `:using_workspace_package`), or
  external path segments (`:using_external`) this name was reached through.
"""
@auto_hash_equals struct VisibleName
    kind::Symbol
    origin::Symbol
    item::Union{Nothing,ItemRef}
    origin_module::Vector{String}
end

"""
    derived_module_self_and_parents(rt, root, path::Vector{String}) -> Vector{Vector{String}}

The enclosing-module chain for `path`: `path` itself, then each shorter
enclosing prefix, down to the synthetic root (`String[]`). Purely structural
on `path` (every prefix is a candidate enclosing scope regardless of whether
it is actually populated in `root`'s tree) — used by the per-file analysis
context (M4) for its outward walk through enclosing scopes.
"""
Salsa.@derived function derived_module_self_and_parents(rt, root, path)
    @debug "derived_module_self_and_parents" root=root path=path

    chain = Vector{String}[]
    p = copy(path)
    push!(chain, copy(p))
    while !isempty(p)
        pop!(p)
        push!(chain, copy(p))
    end
    return chain
end

# --- internal helpers: tree/env plumbing ------------------------------------

# The module's own `declared_at` (where `path` itself was declared as a
# submodule) — `nothing` if `path` names no module in `root`'s tree. This is
# the ItemRef for a whole-module `using`/`import`'s bound submodule name
# (rule 2's "plus the target module's own name"): a module's own name enters
# its *parent's* `declared` dict with exactly this same ItemRef (module-tree
# splicing rule 3/5), so reading it off the module's own node is equivalent
# and doesn't require the caller to know which parent path to look in.
function _module_declared_at(rt, root, path::Vector{String})
    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    return node === nothing ? nothing : node.declared_at
end

# The effective `ExternalEnv` for `root`, per the task-3 brief's binding: the
# guard for a `nothing` project URI is inline here (not inside
# `derived_environment`) so this layer never calls `derived_environment` with
# a `nothing` project.
function _resolve_env(rt, root)
    project_uri = derived_project_uri_for_root(rt, root)
    return project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
end

# Walk `path` through the environment's `EnvStore` (top-level module, then
# nested `ModuleStore`s for each further segment). Returns the final
# `ModuleStore`, or `nothing` if any segment is missing or not itself a
# module (a missing external module "contributes nothing", per the brief —
# NOT an error). The returned `ModuleStore` must never escape into a derived
# VALUE; every caller here only reads plain data off it before returning.
function _resolve_external_module(rt, root, path::Vector{String})
    isempty(path) && return nothing
    env = _resolve_env(rt, root)
    haskey(env.symbols, Symbol(path[1])) || return nothing
    store = env.symbols[Symbol(path[1])]
    for seg in path[2:end]
        haskey(store, Symbol(seg)) || return nothing
        nxt = store[Symbol(seg)]
        nxt isa SymbolServer.ModuleStore || return nothing
        store = nxt
    end
    return store
end

_tier(origin::Symbol) = origin === :declared ? 3 : origin === :import_binding ? 2 : 1

# --- internal helpers: bringing in a resolved import's names ----------------

# One visibility entry: the bound name, its `VisibleName`, and — when the
# binding is module-valued — the `ImportTarget` the name DENOTES (full sort +
# full path of the denoted module), `nothing` otherwise. The third slot feeds
# pass 1's module-target ledger (`_visible_names_pass1`), which is what the
# `:unresolved` re-attempt chases: recording the underlying target sort at
# binding time is what keeps an import-bound workspace package
# `:workspace_package` (and an import-bound external module `:external`)
# through a pass-2 extension, instead of guessing the sort from the binding's
# `origin` (which is `:import_binding` for all of them).
const _BringIn = Tuple{String,VisibleName,Union{Nothing,ImportTarget}}

# Bring in the names for one fully-resolved (never `:unresolved`)
# `ImportTarget` — rule 2's `:tree`/`:workspace_package`/`:external` bullets.
# `kind` (`:using`/`:import`) and `alias` come from the owning `ResolvedImport`
# (or, for the ledger re-attempt, are copied through from the original
# unresolved one). `visited` guards cross-root recursion for
# `:workspace_package` targets (workspace packages can circularly dev each
# other) — it already contains every root on the current resolution chain,
# INCLUDING this call's own `root`.
function _target_bring_ins(rt, root, kind::Symbol, target::ImportTarget, alias, visited::Set{URI})::Vector{_BringIn}
    entries = _BringIn[]
    tp = target.path
    isempty(tp) && return entries

    if target.sort === :tree
        origin = kind === :using ? :using_tree : :import_binding
        if kind === :using
            names = derived_module_names(rt, root, tp)
            exports = derived_module_exports(rt, root, tp).exports
            declared = derived_module_declared(rt, root, tp)
            for name in exports
                haskey(names, name) || continue
                mt = names[name] === :module ? ImportTarget(:tree, vcat(tp, [name])) : nothing
                push!(entries, (name, VisibleName(names[name], :using_tree, declared[name], tp), mt))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, (bound, VisibleName(:module, origin, _module_declared_at(rt, root, tp), tp), target))

    elseif target.sort === :workspace_package
        roots = derived_workspace_package_roots(rt)
        pkg = tp[1]
        haskey(roots, pkg) || return entries   # missing package: contributes nothing
        entry = roots[pkg]
        origin = kind === :using ? :using_workspace_package : :import_binding
        if kind === :using
            # Recurse into the package's OWN visible names (cross-root),
            # gated by ITS OWN exports — this is what lets a workspace
            # package re-export a name it itself brought in via `using`, and
            # is exactly where a dev-cycle between two workspace packages
            # would recurse forever without `visited`'s guard (the
            # recursive call below self-guards on `entry in visited`).
            sub_visible = _visible_names_impl(rt, entry, tp, visited)
            exports = derived_module_exports(rt, entry, tp).exports
            for name in exports
                haskey(sub_visible, name) || continue
                vn = sub_visible[name]
                # Optimistic ledger entry for an exported submodule —
                # `_extend_target` re-validates against the package's tree
                # before any re-attempt actually uses it.
                mt = vn.kind === :module ? ImportTarget(:workspace_package, name == tp[end] ? tp : vcat(tp, [name])) : nothing
                push!(entries, (name, VisibleName(vn.kind, :using_workspace_package, vn.item, tp), mt))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, (bound, VisibleName(:module, origin, _module_declared_at(rt, entry, tp), tp), target))

    elseif target.sort === :external
        store = _resolve_external_module(rt, root, tp)
        store === nothing && return entries   # missing external module: contributes nothing
        origin = kind === :using ? :using_external : :import_binding
        if kind === :using
            for en in store.exportednames
                name = String(en)
                mt = if name == tp[end]
                    target   # a module's own name in its export list denotes the module itself
                elseif haskey(store, en) && store[en] isa SymbolServer.ModuleStore
                    ImportTarget(:external, vcat(tp, [name]))
                else
                    nothing
                end
                push!(entries, (name, VisibleName(:external_symbol, :using_external, nothing, tp), mt))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, (bound, VisibleName(:external_symbol, origin, nothing, tp), target))
    end
    return entries
end

# One member's kind/item/origin_module (plus module-target ledger entry, see
# `_BringIn`), for an explicit symbol list (`using`/`import X: a, b`) against
# a fully-resolved (never `:unresolved`) target. A member naming the target
# module ITSELF (`using Compiler: Compiler as CC`) resolves to the module's
# self-binding — checked FIRST, since Julia's self-binding precludes any
# same-named declared member. A member not found in the target's own local
# names (regardless of sort) still gets bound — real Julia binds the name
# lexically even when it turns out to be wrong — but with `kind = :unknown,
# item = nothing`.
function _member_lookup(rt, root, target::ImportTarget, member_name::String, visited::Set{URI})
    tp = target.path
    if target.sort === :tree
        if member_name == tp[end] && module_node(derived_module_tree(rt, root), tp) !== nothing
            return (:module, _module_declared_at(rt, root, tp), tp, target)
        end
        names = derived_module_names(rt, root, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
        mt = names[member_name] === :module ? ImportTarget(:tree, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_module_declared(rt, root, tp)[member_name], tp, mt)
    elseif target.sort === :workspace_package
        roots = derived_workspace_package_roots(rt)
        pkg = tp[1]
        haskey(roots, pkg) || return (:unknown, nothing, tp, nothing)
        entry = roots[pkg]
        entry in visited && return (:unknown, nothing, tp, nothing)
        if member_name == tp[end] && module_node(derived_module_tree(rt, entry), tp) !== nothing
            return (:module, _module_declared_at(rt, entry, tp), tp, target)
        end
        names = derived_module_names(rt, entry, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp, nothing)
        mt = names[member_name] === :module ? ImportTarget(:workspace_package, vcat(tp, [member_name])) : nothing
        return (names[member_name], derived_module_declared(rt, entry, tp)[member_name], tp, mt)
    elseif target.sort === :external
        store = _resolve_external_module(rt, root, tp)
        store === nothing && return (:unknown, nothing, tp, nothing)
        member_name == tp[end] && return (:external_symbol, nothing, tp, target)
        haskey(store, Symbol(member_name)) || return (:unknown, nothing, tp, nothing)
        mt = store[Symbol(member_name)] isa SymbolServer.ModuleStore ? ImportTarget(:external, vcat(tp, [member_name])) : nothing
        return (:external_symbol, nothing, tp, mt)
    else
        return (:unknown, nothing, tp, nothing)
    end
end

# `kind == :import` OR `kind == :using` with an explicit colon-list: both bind
# EXACTLY the listed names (per-symbol alias wins over its own name) — the
# brief's rule 2 states this for `:import`; a colon-form `using X: a, b` binds
# identically for name-resolution purposes (the using/import distinction only
# affects method-extension permissions, not what's visible), so this
# deliberately covers both — a documented generalization of the literal
# bullet, folded into the same `:import_binding` origin either way. `target`
# is passed separately from the symbol list so the pass-2 re-attempt can
# route a colon-list against a formerly-`:unresolved` target through the same
# member lookup.
function _explicit_symbol_bring_ins(rt, root, target::ImportTarget, symbols, visited::Set{URI})::Vector{_BringIn}
    entries = _BringIn[]
    for sym in symbols
        bound = sym.alias !== nothing ? sym.alias : sym.name
        kind, item, origin_module, mt = _member_lookup(rt, root, target, sym.name, visited)
        push!(entries, (bound, VisibleName(kind, :import_binding, item, origin_module), mt))
    end
    return entries
end

# --- internal helpers: the `:unresolved` ledger re-attempt -------------------

# Recompute (anchor, remaining-segments) for an `:unresolved` import's raw
# `target.path` (`ImportTarget.path` keeps the ORIGINAL written segments,
# dots included, for `:unresolved` — see its docstring), mirroring
# `_classify_import`'s own anchor logic exactly (both branches), since that
# information isn't retained on `ImportTarget` itself. `AP` is the module the
# import was declared in (always equal to the `path` `derived_module_imports`
# was queried with). Returns `nothing` when the import is fundamentally
# invalid (relative pop past the root) — no re-attempt possible.
function _unresolved_anchor_and_segs(rt, root, AP::Vector{String}, raw::Vector{String})
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

    # ndots == 0: this is rule 2's "anchor found, mid-path miss" case (the
    # only other way `_classify_import` produces `:unresolved`) — rediscover
    # the anchor via the identical outward walk.
    tree = derived_module_tree(rt, root)
    M = copy(AP)
    while true
        module_node(tree, vcat(M, [raw[1]])) !== nothing && return (M, raw)
        isempty(M) && return nothing
        pop!(M)
    end
end

# How many of `segs`, taken in order from `anchor`, resolve as nested tree
# modules (mirrors `_resolve_tree_segments`'s walk without erroring on the
# first miss — locating that miss is the point). `k == length(segs)` means
# `segs` fully resolves as tree after all (shouldn't happen for a genuinely
# `:unresolved` import, but callers guard for it defensively).
function _deepest_tree_prefix(rt, root, anchor::Vector{String}, segs::Vector{String})
    tree = derived_module_tree(rt, root)
    resolved = copy(anchor)
    k = 0
    for seg in segs
        candidate = vcat(resolved, [seg])
        module_node(tree, candidate) === nothing && break
        resolved = candidate
        k += 1
    end
    return k
end

# Continue resolving `rest` (possibly empty) starting from a module-valued
# binding's ledgered target (`base`, from pass 1's module-target ledger — see
# `_BringIn`), producing a synthesized `ImportTarget` — or `nothing` if the
# extension doesn't validate. With `rest` empty this just re-validates `base`
# itself (the whole ledger match WAS the target). The sort is `base`'s
# RECORDED sort, never guessed from a `VisibleName`'s `origin` (an
# `:import_binding` origin says nothing about whether the bound module was a
# tree, workspace-package, or external target). Every sort validates the full
# extended path — `:workspace_package` against the PACKAGE's own tree
# (`path[1]` is the package name and its top module path in that tree, per
# `ImportTarget`'s docstring), `:tree` against `root`'s tree (a `:tree`
# target's path is only meaningful in the root it was ledgered in — the
# workspace-package branch re-expresses any tree result from ITS root as
# `:workspace_package` before returning, see below).
#
# When the tree walk gets stuck mid-`rest`, the extension continues through
# ONE ledgered binding at the stuck module (`_extend_through_binding`) — the
# `import ..JSONRPC.JSON` pattern, where JSON is not a tree module inside the
# JSONRPC package but is BOUND there by JSONRPC's own `import JSON`. This
# recursion is bounded: every step strictly shrinks `rest`, and `visited`
# blocks package cycles.
function _extend_target(rt, root, base::ImportTarget, rest::Vector{String}, visited::Set{URI})
    full = vcat(base.path, rest)
    if base.sort === :external
        _resolve_external_module(rt, root, full) === nothing && return nothing
        return ImportTarget(:external, full)
    elseif base.sort === :workspace_package
        roots = derived_workspace_package_roots(rt)
        haskey(roots, full[1]) || return nothing
        entry = roots[full[1]]
        entry in visited && return nothing
        module_node(derived_module_tree(rt, entry), full) === nothing || return ImportTarget(:workspace_package, full)
        cont = _extend_through_binding(rt, entry, base.path, rest, union(visited, Set([entry])))
        cont === nothing && return nothing
        if cont.sort === :tree
            # A tree target in the PACKAGE's root is a workspace-package
            # target from the caller's perspective (the package's tree paths
            # start with the package's own name).
            (isempty(cont.path) || cont.path[1] != full[1]) && return nothing
            return ImportTarget(:workspace_package, cont.path)
        end
        return cont
    elseif base.sort === :tree
        module_node(derived_module_tree(rt, root), full) === nothing || return ImportTarget(:tree, full)
        return _extend_through_binding(rt, root, base.path, rest, visited)
    end
    return nothing
end

# The stuck-mid-`rest` continuation for `_extend_target`: walk the deepest
# tree prefix of `rest` below `base_path` in `croot`'s tree, look the next
# segment up in the stuck module's pass-1 module-target ledger, and continue
# extending from THAT target with whatever remains. `rest` strictly shrinks
# on every hop (at least the chased segment is consumed), so this terminates
# even through chains of bindings.
function _extend_through_binding(rt, croot, base_path::Vector{String}, rest::Vector{String}, visited::Set{URI})
    isempty(rest) && return nothing
    k = _deepest_tree_prefix(rt, croot, base_path, rest)
    k >= length(rest) && return nothing
    stuck_at = vcat(base_path, rest[1:k])
    module_node(derived_module_tree(rt, croot), stuck_at) === nothing && return nothing
    _, modtargets = _visible_names_pass1(rt, croot, stuck_at, visited)
    haskey(modtargets, rest[k + 1]) || return nothing
    return _extend_target(rt, croot, modtargets[rest[k + 1]], rest[k + 2:end], visited)
end

# The task-3 brief's rule 2 `:unresolved` bullet — the M2 ledger case: a
# relative (or absolute-mid-path-miss) import whose post-anchor first segment
# doesn't name a tree submodule, but names a PASS-1-visible module-valued
# binding in the anchor module instead (the `using ..SymbolServer` pattern:
# an ENCLOSING module did `using SymbolServer`, binding the name
# "SymbolServer" to that external module; a nested module's relative
# `using ..SymbolServer` can't see it as a tree module, but CAN see it as a
# visible name one level up).
#
# Bounded to a single re-attempt (2 passes total, not a fixpoint): the anchor
# lookup below is deliberately `_visible_names_pass1` (never the fully
# re-attempted result) — using the full result would recurse into the SAME
# unresolved-import resolution when `stuck_at == path` (e.g. a single-dot
# `using .X` failing at depth 0, whose anchor IS the module currently being
# resolved), and even where `stuck_at` differs, chasing an anchor whose own
# ledger case is ALSO unresolved is out of scope here by design.
function _reattempt_unresolved(rt, root, path::Vector{String}, ri::ResolvedImport, visited::Set{URI})
    split = _unresolved_anchor_and_segs(rt, root, path, ri.target.path)
    split === nothing && return nothing
    anchor, segs = split

    k = _deepest_tree_prefix(rt, root, anchor, segs)
    k >= length(segs) && return nothing

    stuck_at = vcat(anchor, segs[1:k])
    cand_name = segs[k + 1]
    rest = segs[k + 2:end]

    _, modtargets = _visible_names_pass1(rt, root, stuck_at, visited)
    haskey(modtargets, cand_name) || return nothing

    return _extend_target(rt, root, modtargets[cand_name], rest, visited)
end

# --- pass 1 + pass 2 assembly ------------------------------------------------

# One lockstep write to pass 1's two dicts: `result` (the visibility result)
# and `modtargets` (the module-target ledger: bound name → the `ImportTarget`
# the name denotes, for module-valued bindings only — see `_BringIn`). A
# non-module binding overwriting a module-valued one must DROP the stale
# ledger entry, so the two dicts are only ever written through here.
function _record!(result, modtargets, name::String, vn::VisibleName, mt::Union{Nothing,ImportTarget})
    result[name] = vn
    if mt === nothing
        delete!(modtargets, name)
    else
        modtargets[name] = mt
    end
    return nothing
end

# Pass 1: rules 1-2 for every `ResolvedImport` whose target already resolved
# at the module-tree layer (`:tree`/`:workspace_package`/`:external`) —
# `:unresolved` targets contribute nothing here (that's pass 2's job, in
# `_visible_names_impl`). Tiers applied in precedence order (rule 3): using
# 'bring-ins (whole-module `using`) < import_binding (whole-module `import`,
# and any explicit colon-list, either `kind`) < declared. Returns
# `(result, modtargets)` — the module-target ledger is what pass 2's
# re-attempt chases through an anchor module.
function _visible_names_pass1(rt, root, path::Vector{String}, visited::Set{URI})
    result = Dict{String,VisibleName}()
    modtargets = Dict{String,ImportTarget}()

    # Tier 1: using-derived (whole-module `using` — explicit colon-lists are
    # tier 2 regardless of `kind`, see `_explicit_symbol_bring_ins`).
    for ri in derived_module_imports(rt, root, path)
        (ri.kind === :using && isempty(ri.symbols) && ri.target.sort !== :unresolved) || continue
        for (name, vn, mt) in _target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
            _record!(result, modtargets, name, vn, mt)
        end
    end

    # Tier 2: import_binding.
    for ri in derived_module_imports(rt, root, path)
        ri.target.sort === :unresolved && continue
        if !isempty(ri.symbols)
            for (name, vn, mt) in _explicit_symbol_bring_ins(rt, root, ri.target, ri.symbols, visited)
                _record!(result, modtargets, name, vn, mt)
            end
        elseif ri.kind === :import
            for (name, vn, mt) in _target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
                _record!(result, modtargets, name, vn, mt)
            end
        end
    end

    # Tier 3: declared — explicit bindings shadow everything `using` brings
    # in. First the module's SELF-binding (Julia binds a module's own name
    # inside that module: `Foo.Foo === Foo`) — this is what a nested module's
    # relative `using ..Foo: x` resolves through in pass 2. Its
    # `origin_module` is the DECLARING module's path (the parent), consistent
    # with every other `:declared` binding, which is exactly why the ledger
    # entry records the denoted module's FULL path separately.
    node = module_node(derived_module_tree(rt, root), path)
    if node !== nothing && !isempty(path)
        _record!(result, modtargets, path[end],
            VisibleName(:module, :declared, node.declared_at, path[1:end - 1]),
            ImportTarget(:tree, path))
    end
    declared = derived_module_declared(rt, root, path)
    for (name, kind) in derived_module_names(rt, root, path)
        # A `:declared` submodule binding's `origin_module` is `path` (the
        # declaring module), NOT the submodule's own path — the ledger entry
        # carries the denoted module's full path instead.
        mt = kind === :module ? ImportTarget(:tree, vcat(path, [name])) : nothing
        _record!(result, modtargets, name, VisibleName(kind, :declared, declared[name], path), mt)
    end

    return (result, modtargets)
end

# The full (pass 1 + pass 2) computation, threaded with the cross-root
# `visited` set so a workspace-package chain (rule 2's `:workspace_package`
# bullet, and the ledger re-attempt's own `:workspace_package` continuation)
# terminates even when packages circularly dev each other. `visited` already
# containing `root` on entry means this root is somewhere on the current
# resolution chain — a cycle, so it contributes nothing further (its
# `using`-derived exports are skipped; a caller resolving a name TO this root
# still gets the plain module binding, since that doesn't require expanding
# this root's own visible names).
function _visible_names_impl(rt, root, path::Vector{String}, visited::Set{URI})::Dict{String,VisibleName}
    root in visited && return Dict{String,VisibleName}()
    visited = union(visited, Set([root]))

    result, _ = _visible_names_pass1(rt, root, path, visited)

    # Pass 2: the ledger re-attempt — see `_reattempt_unresolved`'s docstring
    # for why this stays a single bounded pass. Both statement forms are
    # re-attempted: whole-module bring-ins go through `_target_bring_ins`,
    # explicit colon-lists through `_explicit_symbol_bring_ins` (the target
    # re-resolution is identical; only what gets bound differs).
    for ri in derived_module_imports(rt, root, path)
        ri.target.sort === :unresolved || continue
        target = _reattempt_unresolved(rt, root, path, ri, visited)
        target === nothing && continue

        if !isempty(ri.symbols)
            entries = _explicit_symbol_bring_ins(rt, root, target, ri.symbols, visited)
            tier = 2   # colon-lists are `:import_binding`-tier regardless of `kind`, matching pass 1
        else
            entries = _target_bring_ins(rt, root, ri.kind, target, ri.alias, visited)
            tier = ri.kind === :using ? 1 : 2
        end
        for (name, vn, _) in entries
            existing = get(result, name, nothing)
            # On an EQUAL tier the existing binding wins (first-wins), unlike
            # pass 1's within-tier last-wins — deliberate: a re-attempted
            # resolution never displaces an equally-ranked binding that
            # resolved without a re-attempt (nor an earlier re-attempt's).
            existing !== nothing && _tier(existing.origin) >= tier && continue
            result[name] = vn
        end
    end

    return result
end

"""
    derived_module_visible_names(rt, root, path::Vector{String}) -> Dict{String,VisibleName}

The names reachable inside the module at `path` in `root`'s module tree,
through its own declarations and its classified imports (rules 1-3, see this
file's header and `_visible_names_pass1`/`_visible_names_impl`'s docstrings).
Empty `Dict` when `path` names no module in the tree (every underlying
selector already degrades to empty/`nothing` in that case).
"""
Salsa.@derived function derived_module_visible_names(rt, root, path)
    @debug "derived_module_visible_names" root=root path=path
    return _visible_names_impl(rt, root, path, Set{URI}())
end
