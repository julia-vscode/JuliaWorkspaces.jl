# Layer 2 of the v2 stack: the module tree spliced from per-file inventories and
# include edges.
#
# Plain data only (Symbols, Strings, URIs, Vectors, Dicts) — no syntax nodes, no
# objectids, no byte offsets. Structural equality is what lets Salsa stop
# invalidation here: two separately-built trees over the same files must be
# `isequal`.
#
# CRITICAL, inherited from v1: values in this layer must NEVER depend on
# `derived_environment`. The tree stays env-independent so that a project
# resolve or package update cannot invalidate it.
#
# Body insensitivity comes from the layer below, not from avoiding it: this
# consumes `derived_v2_file_inventory`, whose skeleton half is body-free and
# whose per-item classifications backdate individually. An edit inside a
# function body therefore leaves this tree untouched.

"""
    V2ImportTarget

Where an import statement points.

- `sort`: `:tree` (a module within this root), `:workspace_package` (a package in
  the workspace), `:external` (an external package), or `:unresolved`.
- `path`: for `:tree`, the absolute module path within this root; for
  `:workspace_package`, the full segments as written — `path[1]` is the package
  name and any further segments are a sub-module path to resolve against that
  package's own tree; for `:external`/`:unresolved`, the segments as written.

v2's own type rather than v1's identically-shaped `ImportTarget`: that one lives
in `layer_module_tree.jl`, the file this layer replaces.
"""
@auto_hash_equals struct V2ImportTarget
    sort::Symbol            # :tree | :workspace_package | :external | :unresolved
    path::Vector{String}    # see docstring
end

"""
    V2ResolvedImport

A resolved `using`/`import` statement within a module; `from` is the v2 item that
produced it.
"""
@auto_hash_equals struct V2ResolvedImport
    kind::Symbol                    # :using | :import
    target::V2ImportTarget
    symbols::Vector{V2ImportSymbol}
    alias::Union{Nothing,String}
    from::V2ItemRef
end

"""
    V2ModuleNode

A module within the tree, including the synthetic root (`path == String[]`,
`declared_at === nothing`).

`declared` maps a module-level name to the item that defines it (later
declaration wins); `declared_kinds` carries the matching item kind, kept
alongside rather than inside so `declared` stays a plain name→ref map.
"""
@auto_hash_equals struct V2ModuleNode
    path::Vector{String}
    bare::Bool
    declared_at::Union{Nothing,V2ItemRef}
    files::Vector{URI}
    declared::Dict{String,V2ItemRef}
    declared_kinds::Dict{String,Symbol}
    exports::Vector{String}
    publics::Vector{String}
    imports::Vector{V2ResolvedImport}
    # The RAW ordered declaration stream `(name, kind, ref)` in true textual
    # splice order, duplicates kept — the winner-only `declared`/
    # `declared_kinds` maps discard exactly the signal declaration-conflict
    # rules need (`const x = 1` then `const x = 2` leaves one entry there,
    # two here).
    decl_events::Vector{Tuple{String,Symbol,V2ItemRef}}
end

"""
    V2ModuleTree

The complete module structure of a root file and everything it includes.
`modules` is sorted by path so equality is deterministic.
"""
@auto_hash_equals struct V2ModuleTree
    root::URI
    modules::Vector{V2ModuleNode}
    file_modules::Dict{URI,Vector{String}}
    # Files spliced through a CONDITIONAL include (an `include` inside an
    # `if`/`@static if` branch, transitively): only one gate's files run, so
    # declaration-conflict rules must not pair declarations across them.
    conditional_files::Set{URI}
end

"Look up a module by absolute path; `nothing` when absent."
function v2_module_node(tree::V2ModuleTree, path::Vector{String})
    for node in tree.modules
        node.path == path && return node
    end
    return nothing
end

# Item kinds that bind a name at their `parent_module` scope. `:opaque_macrocall`
# is deliberately excluded — it names nothing.
const _V2_BINDING_ITEM_KINDS = (
    :function, :macro, :struct, :mutable_struct, :abstract, :primitive,
    :const, :global, :assignment, :enum, :enum_member,
)

# ── workspace package roots ─────────────────────────────────────────────────

"""
    derived_v2_workspace_package_roots(rt) -> Dict{String,URI}

Map each workspace package's name to its entry-file URI (`src/<Name>.jl`),
for packages whose entry file actually exists. A verbatim semantic copy of
v1's `derived_workspace_package_roots` — the underlying queries
(`derived_package_folders`, `derived_package`, `derived_has_file`) are
engine-neutral project-layer reads (TOML + the file store), so v2 owning its
copy removes the last v1 edge without new machinery.

Determinism rules compose in this order: folders without a valid entry file
never claim their name (so they cannot shadow one that does), and among the
survivors sharing a name the lexicographically smaller URI wins (folders are
iterated in sorted order, and a name already recorded is left alone).
"""
Salsa.@derived function derived_v2_workspace_package_roots(rt)
    folders = sort(derived_package_folders(rt); by=string)

    result = Dict{String,URI}()
    for folder in folders
        package = derived_package(rt, folder)
        package === nothing && continue
        haskey(result, package.name) && continue

        entry_uri = filepath2uri(joinpath(uri2filepath(folder), "src", "$(package.name).jl"))
        if derived_has_file(rt, entry_uri)
            result[package.name] = entry_uri
        end
    end
    return result
end

# ── include resolution ──────────────────────────────────────────────────────

"""
    derived_v2_include_target(rt, uri, path) -> Union{Nothing,URI}

Resolve a literal `include("…")` argument relative to the including file's
directory. `nothing` for a computed argument (`path === nothing`) or a path that
cannot be turned into a URI — which is exactly what
`derived_v2_module_has_computed_include` reports on.

This replaces v1's route through `StaticLint.collect_include_analysis`: v2
carries the literal string in the skeleton and resolves it here, so no part of
the v2 stack needs StaticLint.

Deliberately a plain function, NOT a Salsa query, despite the `derived_` name
(kept for its call sites): it is pure in `(uri, path)` and reads no inputs, so
memoization bought nothing — and its Salsa-wrapper instantiation reliably
crashes LLVM (misched/regalloc segfault, LLVM 18 and 20) when JIT-compiled
under `--code-coverage` instrumentation, taking every coverage CI leg down
with it. The runtime argument is accepted and ignored so callers read like the
neighboring queries.
"""
function derived_v2_include_target(_, uri, path)
    path === nothing && return nothing
    isempty(path) && return nothing
    return try
        base = uri2filepath(uri)
        base === nothing && return nothing
        target = normpath(joinpath(dirname(base), path))
        filepath2uri(target)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
end

# ── tree construction ───────────────────────────────────────────────────────

mutable struct _V2ModuleNodeBuilder
    bare::Bool
    declared_at::Union{Nothing,V2ItemRef}
    files::Vector{URI}
    declared::Dict{String,V2ItemRef}
    declared_kinds::Dict{String,Symbol}
    exports::Vector{String}
    publics::Vector{String}
    raw_imports::Vector{Tuple{URI,V2Import}}
    decl_events::Vector{Tuple{String,Symbol,V2ItemRef}}
end
_V2ModuleNodeBuilder() = _V2ModuleNodeBuilder(
    false, nothing, URI[], Dict{String,V2ItemRef}(), Dict{String,Symbol}(),
    String[], String[], Tuple{URI,V2Import}[], Tuple{String,Symbol,V2ItemRef}[])

_v2_is_datatype_kind(k::Symbol) =
    k === :struct || k === :mutable_struct || k === :abstract || k === :primitive || k === :enum

# One declared-name write, with v1's method-extension rule: a later same-named
# `:function` (or function-form `:assignment`) over a DATATYPE binding is a
# method extension — the datatype stays the declared winner (`struct Thing` +
# `Thing(m) = …` reports `Thing ↦ :struct` with the struct's ref). Every other
# combination keeps last-splice-wins.
function _v2_declare!(node::_V2ModuleNodeBuilder, name::String, ref::V2ItemRef, kind::Symbol)
    isempty(name) && return
    # The raw event, recorded BEFORE the method-extension early return: the
    # events stream keeps every declaration in splice order, winner or not.
    push!(node.decl_events, (name, kind, ref))
    prev = get(node.declared_kinds, name, nothing)
    if prev !== nothing && _v2_is_datatype_kind(prev) && (kind === :function || kind === :assignment)
        return
    end
    node.declared[name] = ref
    node.declared_kinds[name] = kind
    return
end

# `inventory(rt, uri)` is the per-file inventory query the structure is built
# from: the static `derived_v2_file_inventory`, or
# `derived_v2_file_inventory_expanded` with settled macro expansions folded in.
function _v2_build_tree_structure(rt, root::URI, inventory::Function)
    builders = Dict{Vector{String},_V2ModuleNodeBuilder}()
    ensure_node!(path::Vector{String}) = get!(_V2ModuleNodeBuilder, builders, path)

    # The synthetic root node always exists, even for an empty root file.
    ensure_node!(String[])

    file_modules = Dict{URI,Vector{String}}()
    conditional_files = Set{URI}()
    # First include wins in true source order; later includes of an already
    # visited file are skipped, and cycles terminate. Seeded with `root` so a
    # file including itself is caught too.
    visited = Set{URI}([root])

    function splice_file!(F::URI, P::Vector{String}, cond::Bool)
        file_modules[F] = P
        cond && push!(conditional_files, F)
        push!(ensure_node!(P).files, F)

        inv = inventory(rt, F)

        # Every record kind is merged into ONE event stream ordered by the
        # walker's per-file `order`, and processed in a single pass with
        # `include` events recursing in place — that is what reproduces true
        # textual splice order.
        events = Tuple{Int,Symbol,Any}[]
        for item in inv.items
            if isempty(item.qualifier) && item.kind in _V2_BINDING_ITEM_KINDS
                push!(events, (item.order, :item, item))
            end
        end
        for m in inv.modules
            push!(events, (m.order, :module, m))
        end
        for e in inv.exports
            push!(events, (e.order, :export, e))
        end
        for imp in inv.imports
            push!(events, (imp.order, :import, imp))
        end
        for inc in inv.includes
            push!(events, (inc.order, :include, inc))
        end
        # Secondary key: for an assignment-wrapped include (`const DATA =
        # include("data.jl")`) the item and the include share one `order`. Julia
        # evaluates the included content before the outer assignment completes,
        # so on a tie `:include` must be processed BEFORE `:item`.
        sort!(events; by=e -> (e[1], e[2] === :include ? 0 : 1), alg=Base.Sort.MergeSort)

        for (_, kind, payload) in events
            if kind === :item
                item = payload
                _v2_declare!(ensure_node!(vcat(P, item.parent_module)), item.name,
                             V2ItemRef(F, item.id), item.kind)
            elseif kind === :module
                m = payload
                mod_path = vcat(P, m.parent_module, [m.name])
                node = ensure_node!(mod_path)
                node.bare = m.bare
                node.declared_at = V2ItemRef(F, m.id)
                # A module's own name enters its PARENT's declared entries,
                # exactly like a binding item does.
                _v2_declare!(ensure_node!(vcat(P, m.parent_module)), m.name,
                             V2ItemRef(F, m.id), :module)
            elseif kind === :export
                e = payload
                node = ensure_node!(vcat(P, e.parent_module))
                append!(e.kind === :export ? node.exports : node.publics, e.names)
            elseif kind === :import
                imp = payload
                push!(ensure_node!(vcat(P, imp.parent_module)).raw_imports, (F, imp))
            else # :include
                inc = payload
                newP = vcat(P, inc.parent_module)
                # The node at newP exists regardless of whether this particular
                # include resolves — other items may splice there.
                ensure_node!(newP)
                target = derived_v2_include_target(rt, F, inc.path)
                target === nothing && continue
                target in visited && continue
                derived_has_content(rt, target) || continue
                push!(visited, target)
                splice_file!(target, newP, cond || inc.conditional)
            end
        end
    end

    splice_file!(root, String[], false)
    return builders, file_modules, conditional_files
end

# Resolve `segs` as a chain of nested tree-module children starting at `anchor`.
function _v2_resolve_tree_segments(builders, anchor::Vector{String}, segs::Vector{String},
                                   original_path::Vector{String})::V2ImportTarget
    resolved = copy(anchor)
    for seg in segs
        push!(resolved, seg)
        haskey(builders, resolved) || return V2ImportTarget(:unresolved, original_path)
    end
    return V2ImportTarget(:tree, resolved)
end

# Classify one import declared at absolute path `AP`. Mirrors v1's
# `_classify_import` rule for rule: relative paths count leading "." entries;
# absolute paths anchor at the first enclosing module that has the first segment
# as a child; otherwise a workspace package, else external.
function _v2_classify_import(builders, workspace_roots, AP::Vector{String}, imp::V2Import)::V2ImportTarget
    path = imp.path
    isempty(path) && return V2ImportTarget(:unresolved, path)

    ndots = 0
    while ndots < length(path) && path[ndots + 1] == "."
        ndots += 1
    end

    if ndots > 0
        # One dot anchors at AP itself; each additional dot pops one level.
        pops = ndots - 1
        pops > length(AP) && return V2ImportTarget(:unresolved, path)
        anchor = AP[1:(length(AP) - pops)]
        segs = path[(ndots + 1):end]
        isempty(segs) && return V2ImportTarget(:tree, anchor)
        return _v2_resolve_tree_segments(builders, anchor, segs, path)
    end

    # Absolute: walk outward from AP looking for an enclosing module that has
    # `path[1]` as a child.
    for n in length(AP):-1:0
        anchor = AP[1:n]
        haskey(builders, vcat(anchor, [path[1]])) || continue
        return _v2_resolve_tree_segments(builders, anchor, path, path)
    end

    haskey(workspace_roots, path[1]) && return V2ImportTarget(:workspace_package, path)
    return V2ImportTarget(:external, path)
end

"""
    derived_v2_module_tree_static(rt, root) -> V2ModuleTree

The module structure of `root` and its include closure, built from the static
v2 inventories only — nothing a macro expansion adds. This is the tree the
expansion CONTEXT is computed from (`derived_v2_expansion_context`), which is
why it must not see expansions: the expanded tree depends on them. Every
other consumer wants `derived_v2_module_tree`.
"""
Salsa.@derived function derived_v2_module_tree_static(rt, root)
    @debug "derived_v2_module_tree_static" root=root
    return _v2_finish_tree(rt, root, _v2_build_tree_structure(rt, root, derived_v2_file_inventory)...)
end

"""
    derived_v2_module_tree(rt, root) -> V2ModuleTree

The module structure of `root` and its include closure: the static tree plus
whatever settled macro expansions declare (`derived_v2_file_inventory_expanded`).
With the expansion flag off this is the static tree itself.
"""
Salsa.@derived function derived_v2_module_tree(rt, root)
    input_macro_expansion(rt) || return derived_v2_module_tree_static(rt, root)
    @debug "derived_v2_module_tree" root=root
    return _v2_finish_tree(rt, root, _v2_build_tree_structure(rt, root, derived_v2_file_inventory_expanded)...)
end

function _v2_finish_tree(rt, root, builders, file_modules, conditional_files)
    workspace_roots = derived_v2_workspace_package_roots(rt)

    nodes = V2ModuleNode[]
    for path in sort(collect(keys(builders)))
        b = builders[path]
        imports = V2ResolvedImport[]
        for (F, imp) in b.raw_imports
            push!(imports, V2ResolvedImport(
                imp.kind, _v2_classify_import(builders, workspace_roots, path, imp),
                imp.symbols, imp.alias, V2ItemRef(F, imp.id)))
        end
        push!(nodes, V2ModuleNode(path, b.bare, b.declared_at, b.files,
                                  b.declared, b.declared_kinds,
                                  b.exports, b.publics, imports, b.decl_events))
    end
    return V2ModuleTree(root, nodes, file_modules, conditional_files)
end

# ── selectors ───────────────────────────────────────────────────────────────

"The absolute module path `uri`'s top level splices into within `root`, or `nothing`."
Salsa.@derived function derived_v2_file_module_path(rt, root, uri)
    return get(derived_v2_module_tree(rt, root).file_modules, uri, nothing)
end

# The static-tree twins of `derived_v2_file_module_path` / `derived_v2_module_imports`,
# for the expansion context only (see `derived_v2_module_tree_static`).
Salsa.@derived function derived_v2_file_module_path_static(rt, root, uri)
    return get(derived_v2_module_tree_static(rt, root).file_modules, uri, nothing)
end

Salsa.@derived function derived_v2_module_imports_static(rt, root, path)
    node = v2_module_node(derived_v2_module_tree_static(rt, root), path)
    return node === nothing ? V2ResolvedImport[] : node.imports
end

"Whether a module exists at `path` in `root`'s tree."
Salsa.@derived function derived_v2_module_exists(rt, root, path)
    return v2_module_node(derived_v2_module_tree(rt, root), path) !== nothing
end

"Whether the module at `path` is a `baremodule`."
Salsa.@derived function derived_v2_module_is_bare(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? false : node.bare
end

"The raw ordered declaration stream at `path` (see `V2ModuleNode.decl_events`)."
Salsa.@derived function derived_v2_module_decl_events(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? Tuple{String,Symbol,V2ItemRef}[] : node.decl_events
end

"Module-level bindings at `path`: name → the item that declares it."
Salsa.@derived function derived_v2_module_declared(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? Dict{String,V2ItemRef}() : node.declared
end

"The names `export`ed from the module at `path`."
Salsa.@derived function derived_v2_module_exports(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? String[] : node.exports
end

"The item declaring the module at `path`, or `nothing` (missing module / the synthetic root)."
Salsa.@derived function derived_v2_module_declared_at(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? nothing : node.declared_at
end

"The resolved `using`/`import` statements of the module at `path`."
Salsa.@derived function derived_v2_module_imports(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? V2ResolvedImport[] : node.imports
end

"""
    derived_v2_module_names(rt, root, path) -> Dict{String,Symbol}

Every name declared directly in the module at `path`, mapped to its item kind.
"""
Salsa.@derived function derived_v2_module_names(rt, root, path)
    node = v2_module_node(derived_v2_module_tree(rt, root), path)
    return node === nothing ? Dict{String,Symbol}() : node.declared_kinds
end

# ── blindness flags ─────────────────────────────────────────────────────────
#
# Both report "this module may contain names the walk cannot see", which callers
# use to suppress missing-reference reporting rather than emit false positives.

# Both flags key on the record's ABSOLUTE module path — the path its file
# splices at, plus the record's own in-file module path. Filtering on the file's
# splice path alone would miss everything inside a nested `module` block, which
# is exactly where an unresolvable include or an opaque macro hides.

# ── body markers (analysis boundaries inside item bodies) ───────────────────
#
# The walker never descends into `function`/`for`/`while`/`let`/`try` bodies
# for item enumeration — but an `include` or `@eval` in there still splices or
# defines names at module level when the item runs (ColorSchemes loads its 37
# data files from inside a function, then `@eval`s a const per scheme). This
# per-item scan finds them so the blindness flags below can see through the
# walker's structural horizon. Markers live in a DERIVED per-item query, not
# the skeleton — the skeleton's equality contract is body-independent, and
# these are body facts. Addresses are BodyTree preorder, reattachable through
# `derived_v2_file_maps`.
const V2BodyMarker = @NamedTuple{addr::Int32, kind::Symbol}  # :computed_include | :opaque_eval | :guarded_import

function _v2_scan_body_markers!(out::Vector{V2BodyMarker}, bt::BodyTree{V2Kind},
                                addr::Base.RefValue{Int}, qdepth::Int)
    myaddr = (addr[] += 1)
    if qdepth == 0
        if bt.kind == JS2.K"using" || bt.kind == JS2.K"import"
            # A `using`/`import` inside an item body (`try; import GR_jll;
            # catch; end`, an `if` branch of a build script) brings names the
            # walk cannot see — the import row machinery only sees top-level
            # statements. Unlike the other markers this blinds missing_reference
            # only: an import cannot add methods to a name already visible.
            push!(out, (addr=Int32(myaddr), kind=:guarded_import))
        elseif _v2_is_includeish_call(bt)
            push!(out, (addr=Int32(myaddr), kind=:computed_include))
        elseif (bt.kind == JS2.K"macrocall" && bt.children !== nothing &&
                !isempty(bt.children) && _macro_name_string(bt.children[1]) == "eval") ||
               (bt.kind == JS2.K"call" && bt.children !== nothing &&
                !isempty(bt.children) && _v2_leaf_string(bt.children[1]) == "eval")
            push!(out, (addr=Int32(myaddr), kind=:opaque_eval))
        end
    end
    bt.children === nothing && return nothing
    cd = _quote_depth(bt.kind, qdepth)
    for c in bt.children
        _v2_scan_body_markers!(out, c, addr, cd)
    end
    return nothing
end

"Analysis-boundary constructs inside one item's body (quote contents excluded)."
Salsa.@derived function derived_v2_item_body_markers(rt, ref::V2ItemRef)
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return V2BodyMarker[]
    out = V2BodyMarker[]
    _v2_scan_body_markers!(out, body, Ref(0), 0)
    # A statically-extractable @eval loop is NOT a boundary: its generated
    # names are declared by classification, so neither blindness nor a notice
    # applies. (Extraction requires the body to be @eval statements only, so
    # include markers cannot coexist with it.)
    if any(m -> m.kind === :opaque_eval, out) && _v2_extract_eval_loop(body) !== nothing
        filter!(m -> m.kind !== :opaque_eval, out)
    end
    return out
end

# Whether any item spliced into the module at `path` carries a marker of `kind`.
function _v2_module_has_body_marker(rt, root, path, kind::Symbol)
    tree = derived_v2_module_tree(rt, root)
    for (uri, p) in tree.file_modules
        for r in derived_v2_file_skeleton(rt, uri).items
            vcat(p, r.parent_module) == path || continue
            any(m -> m.kind === kind, derived_v2_item_body_markers(rt, V2ItemRef(uri, r.id))) &&
                return true
        end
    end
    return false
end

"Whether the module at `path` contains an `include` whose target cannot be resolved."
Salsa.@derived function derived_v2_module_has_computed_include(rt, root, path)
    tree = derived_v2_module_tree(rt, root)
    for (uri, p) in tree.file_modules
        for inc in derived_v2_file_skeleton(rt, uri).includes
            vcat(p, inc.parent_module) == path || continue
            inc.path === nothing && return true
            derived_v2_include_target(rt, uri, inc.path) === nothing && return true
        end
    end
    # Includes inside item bodies (function/loop/let/try) splice at runtime —
    # always beyond static resolution, exactly like a computed path.
    return _v2_module_has_body_marker(rt, root, path, :computed_include)
end

"Whether the module at `path` has a `using`/`import` inside an item body (try/if/…)."
Salsa.@derived function derived_v2_module_has_guarded_import(rt, root, path)
    return _v2_module_has_body_marker(rt, root, path, :guarded_import)
end

"""
Whether the module at `path` contains a top-level macrocall with unmodelled
effects. Expansion-aware: a macrocall the DJP expanded cleanly has left the
expanded inventory's `opaque_macros` (its definitions are ordinary rows), so
only macros that genuinely resist analysis — expansion failed, unavailable,
or still pending — keep the module blind.
"""
Salsa.@derived function derived_v2_module_has_opaque_macrocall(rt, root, path)
    derived_v2_module_has_toplevel_opaque_macrocall(rt, root, path) && return true
    # `@eval`/`eval` inside item bodies defines names the walk cannot see —
    # the same unmodelled-effects class as an opaque top-level macrocall.
    return _v2_module_has_body_marker(rt, root, path, :opaque_eval)
end

"""
Whether the module at `path` contains a TOP-LEVEL opaque macrocall — the
part of `derived_v2_module_has_opaque_macrocall` that can leave the module's
`export` list incomplete (a `@reexport` computed at expansion time). A
runtime `@eval` inside a function body defines names, but `using M` brings
only what `M` exports, so it does not blind the modules that `using` it.
"""
Salsa.@derived function derived_v2_module_has_toplevel_opaque_macrocall(rt, root, path)
    tree = derived_v2_module_tree(rt, root)
    for (uri, p) in tree.file_modules
        for om in derived_v2_file_inventory_expanded(rt, uri).opaque_macros
            vcat(p, om.parent_module) == path && return true
        end
    end
    return false
end
