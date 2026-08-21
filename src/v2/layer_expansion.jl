# DJP-side macro expansion: the Salsa half.
#
# Opaque macrocalls in v2 lowering are expanded out-of-process by the
# persistent env child (the process that indexed the environment and therefore
# has its packages loaded). This file computes WHAT needs expanding and
# consumes the settled results; the transport lives in the dynamic-feature
# reactor (`ExpansionBatchMsg` and friends), and the splice into lowering lives
# in `layer_lowering.jl` (`_materialize`'s union guard).
#
# Everything here is position-free: expansion sites are preorder addresses and
# content hashes; source text is reattached at the last mile by the HOST-side
# `_reconcile_expansions!` (public.jl), which — like the other emission joins —
# may read the volatile `derived_v2_file_maps`.
#
# Behind `input_macro_expansion` (lazily false), and only meaningful under
# `DynamicPersistent`.

"One opaque macrocall in an item: its preorder address and its `BodyTree.hash`."
const V2ExpansionSite = @NamedTuple{addr::Int, mac_hash::UInt64}

# Walk an item's `BodyTree` with the exact address accounting `_materialize`
# uses (transparent unwrap, test-block descent, quote depth), collecting the
# opaque macrocalls that would be stripped — the expansion candidates.
function _collect_expansion_sites!(out::Vector{V2ExpansionSite}, bt::BodyTree{V2Kind},
                                   addr::Base.RefValue{Int}, qdepth::Int)
    myaddr = (addr[] += 1)
    if qdepth == 0
        target = _transparent_macro_target(bt)
        if target !== nothing
            for c in bt.children[1:end-1]
                addr[] += bt_node_count(c)
            end
            return _collect_expansion_sites!(out, target, addr, qdepth)
        end
        test_block = _test_block_target(bt)
        if test_block !== nothing
            for c in bt.children[1:end-1]
                addr[] += bt_node_count(c)
            end
            return _collect_expansion_sites!(out, test_block, addr, qdepth)
        end
        if _is_opaque_macrocall(bt)
            push!(out, (addr=myaddr, mac_hash=bt.hash))
            addr[] += bt_node_count(bt) - 1
            return nothing
        end
    end
    bt.children === nothing && return nothing
    child_depth = _quote_depth(bt.kind, qdepth)
    for c in bt.children
        _collect_expansion_sites!(out, c, addr, child_depth)
    end
    return nothing
end

"""
    derived_v2_item_expansion_sites(rt, ref) -> Vector{V2ExpansionSite}

The opaque macrocalls of one item, position-free. Backdates with the body.
"""
Salsa.@derived function derived_v2_item_expansion_sites(rt, ref::V2ItemRef)
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return V2ExpansionSite[]
    out = V2ExpansionSite[]
    _collect_expansion_sites!(out, body, Ref(0), 0)
    return out
end

# ── the module context ──────────────────────────────────────────────────────

# Canonical reprint of a resolved import as one loadable statement, or
# `nothing` when it cannot mean anything in a scratch module (relative paths,
# intra-tree module references).
function _expansion_import_statement(imp::V2ResolvedImport)
    imp.target.sort in (:external, :workspace_package, :unresolved) || return nothing
    path = imp.target.path
    (isempty(path) || path[1] == ".") && return nothing
    stmt = (imp.kind == :using ? "using " : "import ") * join(path, ".")
    if !isempty(imp.symbols)
        stmt *= ": " * join((s.alias === nothing ? s.name : string(s.name, " as ", s.alias)
                             for s in imp.symbols), ", ")
    elseif imp.alias !== nothing
        stmt *= " as " * imp.alias
    end
    return stmt
end

"""
    derived_v2_package_macro_defs_hash(rt, package_uri) -> UInt64

Combined body hash of every `macro` item across the package's files. This is
the re-expansion trigger for deved packages (design decision D2b): editing a
macro definition changes this hash — and with it every `ctx_hash` that can see
the package — so exactly the affected expansion sites re-key and re-request,
while non-macro edits change nothing. (Known gap, M2: a macro whose output
depends on a non-macro helper function does not re-key.)
"""
Salsa.@derived function derived_v2_package_macro_defs_hash(rt, package_uri)
    h = UInt64(0x6d6163646566735f)   # "macdefs_"
    for f in sort!(collect(derived_julia_files(rt)); by=string)
        derived_package_for_file(rt, f) == package_uri || continue
        for row in derived_v2_file_skeleton(rt, f).items
            row.kind === :macro || continue
            h = hash(derived_v2_item_body_hash(rt, V2ItemRef(f, row.id)), h)
        end
    end
    return h
end

"""
    derived_v2_expansion_context(rt, uri) -> Union{Nothing,NamedTuple}

`(ctx_hash, imports)` for `uri`'s module: the sorted canonical import
statements the child evals into a scratch module before expanding, plus a
`using <OwnPackage>` line so package-level macros resolve via the compiled
package. The hash additionally folds in the own package's macro-defs hash, so
deved macro edits re-key (D2b). `nothing` when the file has no module context.
"""
Salsa.@derived function derived_v2_expansion_context(rt, uri)
    root = derived_v2_best_root_for_uri(rt, uri)   # v2's own root discovery
    root === nothing && return nothing
    path = derived_v2_file_module_path(rt, root, uri)
    path === nothing && return nothing

    stmts = String[]
    for imp in derived_v2_module_imports(rt, root, path)
        s = _expansion_import_statement(imp)
        s === nothing || push!(stmts, s)
    end

    pkg_uri = derived_package_for_file(rt, uri)
    macro_defs_hash = UInt64(0)
    if pkg_uri !== nothing
        pkg = derived_package(rt, pkg_uri)
        if pkg !== nothing
            push!(stmts, "using " * pkg.name)
            macro_defs_hash = derived_v2_package_macro_defs_hash(rt, pkg_uri)
        end
    end

    sort!(unique!(stmts))
    return (ctx_hash=hash(macro_defs_hash, hash(stmts, UInt64(0x7632657870437478))),   # "v2expCtx"
            imports=stmts)
end

"""
    derived_v2_expansion_env(rt, uri) -> Union{Nothing,NamedTuple}

`(key, env_hash)`: the env work-item `DJPKey` whose persistent child serves
`uri`'s expansion batches, and the env content hash for the cache key. M1
covers files with a real project environment; everything else keeps the
identifier fallback.
"""
Salsa.@derived function derived_v2_expansion_env(rt, uri)
    project_uri = derived_project_for_file(rt, uri)
    project_uri === nothing && return nothing
    project = derived_project(rt, project_uri)
    project === nothing && return nothing
    project_path = uri2filepath(project_uri)
    project_path === nothing && return nothing
    return (key=WatchEnvironmentKey(project_path, project.content_hash),
            env_hash=project.content_hash)
end

# ── consuming settled results ───────────────────────────────────────────────

"Per-key read of `input_macro_expansions`, so the collection input invalidates fine-grained."
Salsa.@derived function derived_macro_expansion(rt, key::ExpansionKey)
    return get(input_macro_expansions(rt), key, nothing)
end

"""
    derived_parsed_expansion(rt, key) -> Union{Nothing,BodyTree{V2Kind}}

The settled `:ok` expansion parsed with the vendored JuliaSyntax and distilled
to a position-free `BodyTree`. `nothing` while pending, on `:failed`, and when
the expansion text does not parse (spliced runtime objects that `string(expr)`
cannot round-trip) — every `nothing` means "keep today's identifier fallback".
"""
Salsa.@derived function derived_parsed_expansion(rt, key::ExpansionKey)
    outcome = derived_macro_expansion(rt, key)
    (outcome === nothing || outcome.status !== :ok) && return nothing
    st = try
        JS2.parseall(JS2.SyntaxTree, outcome.text; filename="macro expansion")
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
    cs = JS2.is_leaf(st) ? nothing : JS2.children(st)
    (cs === nothing || isempty(cs)) && return nothing
    bts = BodyTree{V2Kind}[_build_body_tree_v2!(nothing, c) for c in cs]
    return length(bts) == 1 ? bts[1] : BodyTree(JS2.K"block", nothing, bts)
end

"""
    derived_item_expansions(rt, ref) -> Dict{UInt64,BodyTree{V2Kind}}

The available expansions of one item, keyed by macrocall hash — what
`_materialize` splices. Flag checked first: with `input_macro_expansion` off
this adds exactly one Salsa edge (the flag) to `derived_item_lowering`.
"""
Salsa.@derived function derived_item_expansions(rt, ref::V2ItemRef)
    input_macro_expansion(rt) || return _EMPTY_EXPANSIONS
    sites = derived_v2_item_expansion_sites(rt, ref)
    isempty(sites) && return _EMPTY_EXPANSIONS
    env = derived_v2_expansion_env(rt, ref.file)
    env === nothing && return _EMPTY_EXPANSIONS
    ctx = derived_v2_expansion_context(rt, ref.file)
    ctx === nothing && return _EMPTY_EXPANSIONS

    out = Dict{UInt64,BodyTree{V2Kind}}()
    for s in sites
        key = ExpansionKey((env.env_hash, ctx.ctx_hash, s.mac_hash))
        bt = derived_parsed_expansion(rt, key)
        bt === nothing || (out[s.mac_hash] = bt)
    end
    return isempty(out) ? _EMPTY_EXPANSIONS : out
end

# ── readiness gating ────────────────────────────────────────────────────────

"""
    derived_file_expansion_ready(rt, uri) -> Bool

Whether every expansion the file's lowering could use has SETTLED — `:ok` or
`:failed`, either counts (the `derived_file_env_ready` doctrine: gate only
while a result can still arrive; failure is terminal readiness). `true` when
the flag is off, when the file is outside the v2 lint, or when it has no
expansion sites.

The shipping rules stay best-effort and do not consult this; it exists for
future rules of the use-before-definition class, which must not run against
the identifier-read fallback (a synthesized read may precede the real
assignment). Under a non-persistent mode the reactor settles every batch
entry `:failed` immediately, so this cannot gate forever wherever a dynamic
feature exists. (Flag on with NO dynamic feature is a misconfiguration and
gates macro-bearing files indefinitely — which today gates nothing.)
"""
Salsa.@derived function derived_file_expansion_ready(rt, uri)
    input_macro_expansion(rt) || return true
    derived_lowering_lint_active(rt, uri) || return true
    env = derived_v2_expansion_env(rt, uri)
    env === nothing && return true          # no env: expansion impossible, settled
    ctx = derived_v2_expansion_context(rt, uri)
    ctx === nothing && return true

    settled = input_macro_expansions(rt)
    for row in derived_v2_file_skeleton(rt, uri).items
        for s in derived_v2_item_expansion_sites(rt, V2ItemRef(uri, row.id))
            key = ExpansionKey((env.env_hash, ctx.ctx_hash, s.mac_hash))
            haskey(settled, key) || return false
        end
    end
    return true
end

# ── the harvest ─────────────────────────────────────────────────────────────

"One expansion the workspace still needs, with everything the host must know to request it."
const V2RequiredExpansion = @NamedTuple{key::ExpansionKey, env_key::DJPKey, ctx_id::String,
                                        imports::Vector{String}, file::URI, item_id::Int64, addr::Int}

"""
    derived_required_macro_expansions(rt) -> Vector{V2RequiredExpansion}

Every expansion site of every lowering-active file whose key has not settled
yet. The host-side `_reconcile_expansions!` (public.jl) diffs this against its
requested set, reattaches source text via the volatile maps, and sends batches.
"""
Salsa.@derived function derived_required_macro_expansions(rt)
    input_macro_expansion(rt) || return V2RequiredExpansion[]

    out = V2RequiredExpansion[]
    settled = input_macro_expansions(rt)
    for uri in sort!(collect(derived_julia_files(rt)); by=string)
        derived_lowering_lint_active(rt, uri) || continue
        env = derived_v2_expansion_env(rt, uri)
        env === nothing && continue
        ctx = derived_v2_expansion_context(rt, uri)
        ctx === nothing && continue
        ctx_id = string(ctx.ctx_hash, base=16)
        for row in derived_v2_file_skeleton(rt, uri).items
            ref = V2ItemRef(uri, row.id)
            for s in derived_v2_item_expansion_sites(rt, ref)
                key = ExpansionKey((env.env_hash, ctx.ctx_hash, s.mac_hash))
                haskey(settled, key) && continue
                push!(out, (key=key, env_key=env.key, ctx_id=ctx_id, imports=ctx.imports,
                            file=uri, item_id=row.id, addr=s.addr))
            end
        end
    end
    return out
end
