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

# Bring in the names for one fully-resolved (never `:unresolved`)
# `ImportTarget` — rule 2's `:tree`/`:workspace_package`/`:external` bullets.
# `kind` (`:using`/`:import`) and `alias` come from the owning `ResolvedImport`
# (or, for the ledger re-attempt, are copied through from the original
# unresolved one). `visited` guards cross-root recursion for
# `:workspace_package` targets (workspace packages can circularly dev each
# other) — it already contains every root on the current resolution chain,
# INCLUDING this call's own `root`.
function _target_bring_ins(rt, root, kind::Symbol, target::ImportTarget, alias, visited::Set{URI})::Vector{Pair{String,VisibleName}}
    entries = Pair{String,VisibleName}[]
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
                push!(entries, name => VisibleName(names[name], :using_tree, declared[name], tp))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, bound => VisibleName(:module, origin, _module_declared_at(rt, root, tp), tp))

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
                push!(entries, name => VisibleName(vn.kind, :using_workspace_package, vn.item, tp))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, bound => VisibleName(:module, origin, _module_declared_at(rt, entry, tp), tp))

    elseif target.sort === :external
        store = _resolve_external_module(rt, root, tp)
        store === nothing && return entries   # missing external module: contributes nothing
        origin = kind === :using ? :using_external : :import_binding
        if kind === :using
            for en in store.exportednames
                push!(entries, String(en) => VisibleName(:external_symbol, :using_external, nothing, tp))
            end
        end
        bound = alias !== nothing ? alias : tp[end]
        push!(entries, bound => VisibleName(:external_symbol, origin, nothing, tp))
    end
    return entries
end

# One member's kind/item/origin_module, for an explicit symbol list
# (`using`/`import X: a, b`) against a fully-resolved (never `:unresolved`)
# target. A member not found in the target's own local names (regardless of
# sort) still gets bound — real Julia binds the name lexically even when it
# turns out to be wrong — but with `kind = :unknown, item = nothing`.
function _member_lookup(rt, root, target::ImportTarget, member_name::String, visited::Set{URI})
    tp = target.path
    if target.sort === :tree
        names = derived_module_names(rt, root, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp)
        return (names[member_name], derived_module_declared(rt, root, tp)[member_name], tp)
    elseif target.sort === :workspace_package
        roots = derived_workspace_package_roots(rt)
        pkg = tp[1]
        haskey(roots, pkg) || return (:unknown, nothing, tp)
        entry = roots[pkg]
        entry in visited && return (:unknown, nothing, tp)
        names = derived_module_names(rt, entry, tp)
        haskey(names, member_name) || return (:unknown, nothing, tp)
        return (names[member_name], derived_module_declared(rt, entry, tp)[member_name], tp)
    elseif target.sort === :external
        store = _resolve_external_module(rt, root, tp)
        store === nothing && return (:unknown, nothing, tp)
        haskey(store, Symbol(member_name)) || return (:unknown, nothing, tp)
        return (:external_symbol, nothing, tp)
    else
        return (:unknown, nothing, tp)
    end
end

# `kind == :import` OR `kind == :using` with an explicit colon-list: both bind
# EXACTLY the listed names (per-symbol alias wins over its own name) — the
# brief's rule 2 states this for `:import`; a colon-form `using X: a, b` binds
# identically for name-resolution purposes (the using/import distinction only
# affects method-extension permissions, not what's visible), so this
# deliberately covers both — a documented generalization of the literal
# bullet, folded into the same `:import_binding` origin either way.
function _explicit_symbol_bring_ins(rt, root, ri::ResolvedImport, visited::Set{URI})::Vector{Pair{String,VisibleName}}
    entries = Pair{String,VisibleName}[]
    for sym in ri.symbols
        bound = sym.alias !== nothing ? sym.alias : sym.name
        kind, item, origin_module = _member_lookup(rt, root, ri.target, sym.name, visited)
        push!(entries, bound => VisibleName(kind, :import_binding, item, origin_module))
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
# `VisibleName` (`vn.kind in (:module, :external_symbol)`), producing a
# synthesized `ImportTarget` — or `nothing` if `rest` doesn't resolve any
# further. With `rest` empty this just re-expresses `vn`'s own origin as a
# target (the whole ledger match WAS the target); the branches are written to
# handle both uniformly.
function _extend_target(rt, root, vn::VisibleName, rest::Vector{String})
    if vn.origin === :using_external
        full = vcat(vn.origin_module, rest)
        _resolve_external_module(rt, root, full) === nothing && return nothing
        return ImportTarget(:external, full)
    elseif vn.origin === :using_workspace_package
        return ImportTarget(:workspace_package, vcat(vn.origin_module, rest))
    else
        # A tree-valued origin (`:declared` or `:using_tree`/`:import_binding`
        # binding a tree submodule) — `rest` must resolve as nested tree
        # modules from `vn.origin_module`, in the SAME root (tree targets
        # never cross roots).
        k = _deepest_tree_prefix(rt, root, vn.origin_module, rest)
        k < length(rest) && return nothing
        return ImportTarget(:tree, vcat(vn.origin_module, rest))
    end
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

    visible_stuck = _visible_names_pass1(rt, root, stuck_at, visited)
    haskey(visible_stuck, cand_name) || return nothing
    vn = visible_stuck[cand_name]
    vn.kind in (:module, :external_symbol) || return nothing

    return _extend_target(rt, root, vn, rest)
end

# --- pass 1 + pass 2 assembly ------------------------------------------------

# Pass 1: rules 1-2 for every `ResolvedImport` whose target already resolved
# at the module-tree layer (`:tree`/`:workspace_package`/`:external`) —
# `:unresolved` targets contribute nothing here (that's pass 2's job, in
# `_visible_names_impl`). Tiers applied in precedence order (rule 3): using
# 'bring-ins (whole-module `using`) < import_binding (whole-module `import`,
# and any explicit colon-list, either `kind`) < declared.
function _visible_names_pass1(rt, root, path::Vector{String}, visited::Set{URI})::Dict{String,VisibleName}
    result = Dict{String,VisibleName}()

    # Tier 1: using-derived (whole-module `using` — explicit colon-lists are
    # tier 2 regardless of `kind`, see `_explicit_symbol_bring_ins`).
    for ri in derived_module_imports(rt, root, path)
        (ri.kind === :using && isempty(ri.symbols) && ri.target.sort !== :unresolved) || continue
        for (name, vn) in _target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
            result[name] = vn
        end
    end

    # Tier 2: import_binding.
    for ri in derived_module_imports(rt, root, path)
        ri.target.sort === :unresolved && continue
        if !isempty(ri.symbols)
            for (name, vn) in _explicit_symbol_bring_ins(rt, root, ri, visited)
                result[name] = vn
            end
        elseif ri.kind === :import
            for (name, vn) in _target_bring_ins(rt, root, ri.kind, ri.target, ri.alias, visited)
                result[name] = vn
            end
        end
    end

    # Tier 3: declared — explicit bindings shadow everything `using` brings in.
    declared = derived_module_declared(rt, root, path)
    for (name, kind) in derived_module_names(rt, root, path)
        result[name] = VisibleName(kind, :declared, declared[name], path)
    end

    return result
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

    result = _visible_names_pass1(rt, root, path, visited)

    # Pass 2: the ledger re-attempt, scoped to whole-module bring-ins
    # (`isempty(ri.symbols)`) — see `_reattempt_unresolved`'s docstring for
    # why this stays a single bounded pass. An explicit colon-list against an
    # `:unresolved` target is left unresolved (no visibility contribution);
    # this is a documented scope limit, not covered by any required fixture.
    for ri in derived_module_imports(rt, root, path)
        ri.target.sort === :unresolved || continue
        isempty(ri.symbols) || continue
        target = _reattempt_unresolved(rt, root, path, ri, visited)
        target === nothing && continue

        tier = ri.kind === :using ? 1 : 2
        for (name, vn) in _target_bring_ins(rt, root, ri.kind, target, ri.alias, visited)
            existing = get(result, name, nothing)
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
