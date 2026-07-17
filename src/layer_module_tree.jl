# Layer 2 of the inventory architecture: the module tree computed from a file
# inventory and its include structure.
#
# This layer contains plain-data types (Symbols, Strings, URIs, Vectors, Dicts,
# and NamedTuples thereof) — no EXPR references, objectids, or docstrings.
# This is essential for structural equality: two separately-built trees over
# the same files must be `isequal`, so that Salsa's early-exit stops
# invalidation here.
#
# CRITICAL: values in this layer must NEVER depend on `derived_environment`
# (ExternalEnv's isequal is identity, not structural). Using it would
# permanently break the tree's backdating, introducing incorrect cache hits
# across sessions.

"""
    ItemRef

Reference to a top-level item (in a file inventory) by file URI and item ID.
"""
const ItemRef = @NamedTuple{file::URI, id::Int}

"""
    ImportTarget

Resolution information for an import statement's target module.

- `sort`: `:tree` (module within this root), `:workspace_package` (package in
  the workspace), `:external` (external package), or `:unresolved` (unresolvable)
- `path`: For `:tree`, the absolute module path within this root; for
  `:workspace_package`, the full segments as written — `path[1]` is the
  workspace package name; any further segments are a sub-module path for
  layer 3 to resolve against that package's own tree; for `:external` or
  `:unresolved`, the original path segments as written.
"""
@auto_hash_equals struct ImportTarget
    sort::Symbol            # :tree | :workspace_package | :external | :unresolved
    path::Vector{String}    # see docstring
end

"""
    ResolvedImport

A resolved `using` or `import` statement within a module.

- `kind`: `:using` or `:import`
- `target`: resolution information (where the import points to)
- `symbols`: explicit symbol list from `using X: a, b` (empty for whole-module imports)
- `alias`: statement-level `as` alias, or `nothing`
- `from`: reference to the InventoryImport this came from
"""
@auto_hash_equals struct ResolvedImport
    kind::Symbol                       # :using | :import
    target::ImportTarget
    symbols::Vector{ImportSymbol}      # per-symbol (name, alias); empty = whole-module
    alias::Union{Nothing,String}       # statement-level `as` alias
    from::ItemRef                      # the InventoryImport this came from
end

"""
    ModuleNode

A module within the tree (including the synthetic root).

- `path`: absolute module path in this root; `String[]` for the root file's top level
- `bare`: whether this is a `baremodule` (false for the synthetic root node)
- `declared_at`: where this module was declared (`nothing` for the synthetic root node)
- `files`: files whose top level splices here, in include order
- `declared`: module-level bindings (name → defining ItemRef; later declaration wins)
- `exports`: names in `export` statements
- `publics`: names in `public` statements
- `imports`: resolved import statements
"""
@auto_hash_equals struct ModuleNode
    path::Vector{String}               # absolute path in this root; String[] = the root file's own top level
    bare::Bool                         # baremodule (false for the synthetic root node)
    declared_at::Union{Nothing,ItemRef}   # nothing for the synthetic root node
    files::Vector{URI}                 # files whose top level splices here, in include order
    declared::Dict{String,ItemRef}     # module-level name → defining item (later declaration wins)
    exports::Vector{String}
    publics::Vector{String}
    imports::Vector{ResolvedImport}
end

"""
    ModuleTree

The complete module structure of a root file (with its includes).

- `root`: the root file's URI
- `modules`: all modules (sorted by path for deterministic equality)
- `file_modules`: for each file, the absolute module path its top level splices into
"""
@auto_hash_equals struct ModuleTree
    root::URI
    modules::Vector{ModuleNode}            # sorted by path for deterministic equality
    file_modules::Dict{URI,Vector{String}} # file → absolute path its top level splices into
end

"""
    module_node(tree::ModuleTree, path::Vector{String})::Union{Nothing,ModuleNode}

Look up a module in the tree by its absolute path. Returns `nothing` if not found.
"""
function module_node(tree::ModuleTree, path::Vector{String})::Union{Nothing,ModuleNode}
    for node in tree.modules
        if node.path == path
            return node
        end
    end
    return nothing
end

"""
    derived_workspace_package_roots(rt) -> Dict{String,URI}

Map each workspace package's name to its entry-file URI (`src/<Name>.jl`),
for packages whose entry file actually exists.

The two determinism rules compose in this order: folders are first filtered
to those whose entry file exists (a folder without a valid entry file never
claims its name, so it cannot shadow another folder that does), and only then
does the lexicographically smaller URI (by `string(uri)`) win among the
survivors that share a name. Folders are iterated in sorted order so a name
already recorded (necessarily from a smaller URI with a valid entry) is left
alone.
"""
Salsa.@derived function derived_workspace_package_roots(rt)
    @debug "derived_workspace_package_roots"

    folders = sort(derived_package_folders(rt); by=string)

    result = Dict{String,URI}()
    for folder in folders
        package = derived_package(rt, folder)
        package === nothing && continue

        # A smaller-URI folder that already recorded this name won the
        # tie-break; skip this (larger-URI) duplicate.
        haskey(result, package.name) && continue

        entry_uri = filepath2uri(joinpath(uri2filepath(folder), "src", "$(package.name).jl"))
        if derived_has_file(rt, entry_uri)
            result[package.name] = entry_uri
        end
    end
    return result
end

# Binding-kind item kinds per the splicing spec's rule 5: these enter a
# node's `declared` dict (later declaration wins). `:opaque_macrocall` and any
# other item kind are deliberately excluded — they never bind a name at their
# `parent_module` scope in the tree sense.
const _BINDING_ITEM_KINDS = (
    :function, :macro, :struct, :mutable_struct, :abstract, :primitive,
    :const, :global, :assignment, :enum, :enum_member,
)

# Mutable node builder used only while assembling a tree in
# `_build_tree_structure`; frozen into the plain-data `ModuleNode` once pass 1
# and pass 2 are complete. Field meanings mirror `ModuleNode` exactly (see its
# docstring) minus `path`, which is the builder's key in the owning `Dict` —
# except `raw_imports`, which is pass-1-only scratch space: `imports`
# (verbatim `InventoryImport`s at this node's absolute path, tagged with their
# declaring file) collected during pass 1, consumed by `_classify_imports!`
# (pass 2) to populate `imports` with real `ResolvedImport`s. `imports` is
# empty until pass 2 runs.
mutable struct _ModuleNodeBuilder
    bare::Bool
    declared_at::Union{Nothing,ItemRef}
    files::Vector{URI}
    declared::Dict{String,ItemRef}
    exports::Vector{String}
    publics::Vector{String}
    raw_imports::Vector{Tuple{URI,InventoryImport}}
    imports::Vector{ResolvedImport}
end

_ModuleNodeBuilder() = _ModuleNodeBuilder(
    false, nothing, URI[], Dict{String,ItemRef}(), String[], String[],
    Tuple{URI,InventoryImport}[], ResolvedImport[])

"""
    _build_tree_structure(rt, root::URI) -> (builders, file_modules)

Pass 1 of `derived_module_tree`: splices `root`'s (transitive) include closure
into a per-root module structure, per the normative splicing semantics (see
the milestone design doc / task brief). Returns the raw mutable builders
(keyed by absolute module path) and the `file → absolute splice path` map;
`derived_module_tree` freezes the builders into plain-data `ModuleNode`s.

Traversal is depth-first, matching Julia's `include`: it is an in-place
textual splice, not a deferred/breadth-first step, so a file's records and its
`include(...)` calls are processed as ONE interleaved, id-ordered event
stream — when an `include` event is reached, the target's entire subtree is
fully spliced (recursively) before the includer's later events run. This is
what makes `x = 1; include("a.jl"); x = 2` and "two siblings, the second of
which includes something deep" resolve exactly like running the code would:
the deepest, textually-last declaration of a name always wins, and a node's
`files` list is true depth-first pre-order, not level-order.

Also collects `using`/`import` statements verbatim, as `(file, InventoryImport)`
pairs on the declaring node's `raw_imports`, at their absolute module path —
this pass never inspects import targets, it only records where each one was
written; `_classify_imports!` (pass 2) resolves them into real `ResolvedImport`s
once the whole tree structure (every module in every included file) is known.
"""
function _build_tree_structure(rt, root::URI)
    builders = Dict{Vector{String},_ModuleNodeBuilder}()
    ensure_node!(path::Vector{String}) = get!(_ModuleNodeBuilder, builders, path)

    # Rule 8: the synthetic root node always exists, even for a root file with
    # no content or no includes.
    ensure_node!(String[])

    file_modules = Dict{URI,Vector{String}}()

    # Rule 1: visited-set guarded exactly like `derived_include_closure` —
    # first include wins in true source order (see below), later includes of
    # an already-visited file are skipped, and cycles terminate. Seeded with
    # `root` up front so a file including itself is also caught.
    visited = Set{URI}([root])

    # Recursive DFS splice of one file F at absolute path P. Rules 3 & 5
    # write into the very same `declared` dict (a module's own name enters
    # its *parent's* declared entries, rule 3, exactly like a binding item
    # does, rule 5), and rule 4's include-target recursion can itself mutate
    # that same dict at the same path — so every record kind is merged into
    # one event stream ordered by the walker's globally-sequential per-file
    # `id` and processed in that single pass, `include` events recursing
    # in-place, to reproduce true textual splice order exactly.
    function splice_file!(F::URI, P::Vector{String})
        # Rule 7.
        file_modules[F] = P

        # The file's own top level splices at P; recording F here handles
        # both the root file (no includer) and included files uniformly —
        # rule 4's "T appended to that node's files" falls out of this same
        # bookkeeping, in true depth-first pre-order, once T is actually
        # recursed into.
        push!(ensure_node!(P).files, F)

        inv = derived_file_inventory(rt, F)

        events = Tuple{Int,Symbol,Any}[]
        for item in inv.items
            if isempty(item.qualifier) && item.kind in _BINDING_ITEM_KINDS
                push!(events, (item.id, :item, item))
            end
        end
        for m in inv.modules
            push!(events, (m.id, :module, m))
        end
        for e in inv.exports
            push!(events, (e.id, :export, e))
        end
        for imp in inv.imports
            push!(events, (imp.id, :import, imp))
        end
        for inc in inv.includes
            push!(events, (inc.id, :include, inc))
        end
        # Secondary key: for an assignment-wrapped include (`const DATA =
        # include("data.jl")`), the item and the include share the SAME id —
        # both come from the one top-level statement. Real Julia evaluates
        # the include's spliced content before the outer assignment
        # completes, so on a tie the `:include` event must be processed
        # BEFORE the `:item` event, or the wrapper's own (textually later)
        # declaration would lose to whatever the included file declares.
        sort!(events; by=e -> (e[1], e[2] === :include ? 0 : 1), alg=Base.Sort.MergeSort)

        for (_, kind, payload) in events
            if kind === :item
                item = payload
                ensure_node!(vcat(P, item.parent_module)).declared[item.name] = (file=F, id=item.id)
            elseif kind === :module
                # Rule 3: create/extend the module's own node...
                m = payload
                mod_path = vcat(P, m.parent_module, [m.name])
                node = ensure_node!(mod_path)
                node.bare = m.bare
                # ...last splice wins (deterministic under DFS) when the same
                # module path is declared across more than one file.
                node.declared_at = (file=F, id=m.id)
                # ...and the module's own name also enters the *parent*
                # node's `declared`, exactly like a binding item (rule 5).
                ensure_node!(vcat(P, m.parent_module)).declared[m.name] = (file=F, id=m.id)
            elseif kind === :export
                # Rule 6.
                e = payload
                node = ensure_node!(vcat(P, e.parent_module))
                append!(e.kind === :export ? node.exports : node.publics, e.names)
            elseif kind === :import
                # Collected verbatim; `_classify_imports!` (pass 2) resolves
                # `target.sort` once the whole tree structure is final.
                imp = payload
                node = ensure_node!(vcat(P, imp.parent_module))
                push!(node.raw_imports, (F, imp))
            else # :include
                # Rule 4: recurse into the include target (skipping
                # `nothing`/content-less targets and — via `visited` —
                # duplicates) BEFORE processing F's later events, splicing at
                # vcat(P, RP). Recursing here (rather than enqueueing) is
                # what makes this a true depth-first, in-place splice.
                inc = payload
                inc.target === nothing && continue
                newP = vcat(P, inc.parent_module)
                # The node at newP must exist regardless of whether this
                # particular include resolves (other items may share RP).
                ensure_node!(newP)
                inc.target in visited && continue
                derived_has_content(rt, inc.target) || continue
                push!(visited, inc.target)
                splice_file!(inc.target, newP)
            end
        end
    end

    splice_file!(root, String[])

    return builders, file_modules
end

"""
    _resolve_tree_segments(builders, anchor::Vector{String}, segs::Vector{String},
                            original_path::Vector{String}) -> ImportTarget

Resolve `segs` as a chain of nested tree-module children starting at `anchor`
— i.e. `vcat(anchor, segs[1])`, then `vcat(anchor, segs[1:2])`, and so on —
each of which must already exist as a module path in `builders`
(`modules_by_path`). Returns `ImportTarget(:tree, vcat(anchor, segs))` if
every segment resolves; `ImportTarget(:unresolved, original_path)` (rules 1 &
2's mid-path miss — including a segment that names a declared item which
isn't itself a module) the moment one doesn't.
"""
function _resolve_tree_segments(builders, anchor::Vector{String}, segs::Vector{String},
                                 original_path::Vector{String})::ImportTarget
    resolved = copy(anchor)
    for seg in segs
        push!(resolved, seg)
        haskey(builders, resolved) || return ImportTarget(:unresolved, original_path)
    end
    return ImportTarget(:tree, resolved)
end

"""
    _classify_import(builders, workspace_roots, AP::Vector{String}, imp::InventoryImport) -> ImportTarget

Classify one `InventoryImport` declared in the module at absolute path `AP`,
per the module-tree import resolution rules (milestone 2, task 5):

1. Relative (`using .X` / `using ..X` / ...): leading `"."` entries in
   `imp.path` count the relative level — one dot anchors at `AP` itself (0
   pops), each additional dot pops one enclosing level. Popping past the
   root (`String[]`) is `:unresolved`. The remaining segments are then
   resolved from the anchor exactly like rule 2 (`_resolve_tree_segments`);
   a miss anywhere is `:unresolved`.
2. Absolute paths anchor like Julia's own module lookup: walk outward from
   `AP` (AP itself, then each shorter enclosing prefix, down to `String[]`),
   anchoring at the FIRST enclosing path `M` for which `vcat(M,
   [imp.path[1]])` is a tree module. Once anchored, every segment (including
   the first) must resolve as a nested tree module from `M`
   (`_resolve_tree_segments`) — a mid-path miss is `:unresolved`, NOT
   `:external`: the anchor already committed this import to the tree.
3. If no anchor is found (the walk reaches `String[]` with no match) and the
   first segment names a workspace package (`workspace_roots`), classify as
   `:workspace_package` with `path` = the full segments as written (e.g.
   `using DevedPkg.Sub` → `path=["DevedPkg", "Sub"]`) — the "Sub" segment must
   be kept here, since it survives nowhere else: the `from=(file,id)` escape
   hatch is ambiguous for multi-target statements (`using A.X, B.Y` emits
   multiple `InventoryImport`s sharing one id). `path[1]` is the workspace
   package name; resolving any further segments into the package's own tree
   is layer 3's job, starting from that package's own entry point.
4. Otherwise (Base, a stdlib, or a registry package): `:external`, with
   `path` = the segments exactly as written.

`symbols`/`alias`/`kind` are not this function's concern — the caller copies
those through from `imp` verbatim.
"""
function _classify_import(builders, workspace_roots, AP::Vector{String}, imp::InventoryImport)::ImportTarget
    path = imp.path
    isempty(path) && return ImportTarget(:unresolved, path)

    ndots = 0
    while ndots < length(path) && path[ndots + 1] == "."
        ndots += 1
    end

    if ndots > 0
        # Rule 1: one dot = 0 pops (anchor at AP itself); each further dot
        # pops one more enclosing level.
        pops = ndots - 1
        pops > length(AP) && return ImportTarget(:unresolved, path)
        anchor = AP[1:end - pops]
        segs = path[ndots + 1:end]
        isempty(segs) && return ImportTarget(:unresolved, path)
        return _resolve_tree_segments(builders, anchor, segs, path)
    end

    # Rule 2: walk outward from AP to String[], anchoring at the first
    # enclosing module that declares `path[1]` as a child.
    #
    # NOTE: this is deliberately MORE PERMISSIVE than real Julia — an
    # absolute (non-relative) `using`/`import` in real Julia never consults
    # enclosing modules, only loaded top-level module names. This walk
    # intentionally matches StaticLint's current scope-walk behavior instead,
    # which does consult enclosing scopes for absolute imports. Do not "fix"
    # this to real Julia semantics without also updating StaticLint, or the
    # two will disagree and the compat contract between them regresses.
    M = copy(AP)
    while true
        haskey(builders, vcat(M, [path[1]])) && return _resolve_tree_segments(builders, M, path, path)
        isempty(M) && break
        pop!(M)
    end

    # Rule 3, then rule 4: no tree anchor at all.
    haskey(workspace_roots, path[1]) && return ImportTarget(:workspace_package, path)
    return ImportTarget(:external, path)
end

"""
    _classify_imports!(rt, builders)

Pass 2 of `derived_module_tree`: consumes each builder's `raw_imports`
(collected verbatim by pass 1, `_build_tree_structure`) and fills in its
`imports` with real, classified `ResolvedImport`s (see `_classify_import`).
Must run only after pass 1 has fully completed — resolving a `:tree` target,
or an absolute import's anchor, may depend on a module declared by a file
spliced in a part of the DFS that hadn't run yet when the import itself was
collected.

`symbols`/`alias`/`kind` copy through from the `InventoryImport` verbatim;
`from` is the `ItemRef` of the `InventoryImport` this came from.
"""
function _classify_imports!(rt, builders)
    workspace_roots = derived_workspace_package_roots(rt)
    for (path, b) in builders
        for (F, imp) in b.raw_imports
            target = _classify_import(builders, workspace_roots, path, imp)
            push!(b.imports, ResolvedImport(imp.kind, target, imp.symbols, imp.alias, (file=F, id=imp.id)))
        end
    end
end

"""
    derived_module_tree(rt, root::URI) -> ModuleTree

The module structure of `root`'s (transitive) include closure: pass 1 splices
every reachable file's top-level items into the module tree they belong to
(see `_build_tree_structure`); pass 2 (`_classify_imports!`) resolves every
`using`/`import` statement's target against the now-complete tree, the
workspace's packages, and (failing both) the external world. `modules` is
sorted by path for deterministic structural equality.
"""
Salsa.@derived function derived_module_tree(rt, root)
    @debug "derived_module_tree" root=root

    builders, file_modules = _build_tree_structure(rt, root)
    _classify_imports!(rt, builders)

    modules = ModuleNode[
        ModuleNode(path, b.bare, b.declared_at, b.files, b.declared, b.exports, b.publics, b.imports)
        for (path, b) in builders]
    sort!(modules; by=n -> n.path, alg=Base.Sort.MergeSort)

    return ModuleTree(root, modules, file_modules)
end

# --- Layer 2 selector queries: the analysis cutoff seam ---
#
# The four `derived_module_*` queries below and `derived_file_module_path`
# are thin `Salsa.@derived` projections of `derived_module_tree` — the same
# pattern as `derived_includes`/`derived_include_dict`/`derived_file_include_records`
# projecting `derived_file_include_data` (layer_includes.jl:1-40): keeping each
# projection as its own memoized query, rather than having every caller
# destructure the fused `ModuleTree`/`ModuleNode` directly, is what lets Salsa
# early-exit independently at EACH projection's own granularity. A tree-level
# change (e.g. an item's id shifting) can leave one projection's value
# unchanged while another's changes — see `derived_module_names`'s docstring
# for why that distinction is the whole point of this layer.

"""
    _declared_item_kind(rt, name::String, ref::ItemRef) -> Symbol

Look up the item kind for one declared name, at query time, from the
defining file's inventory (`ref.file`) — matching BOTH `ref.id` AND `name`.
Id alone is not enough: some inventory items deliberately share one id with
sibling items (`@enum Color red green blue` — the enum type and every member
all carry the one `@enum` statement's id, see layer_inventory.jl's
`_classify_item!`), so an id-only lookup could return a sibling's kind
instead of the requested name's.

A hit in `inv.modules` means `name` was a submodule declaration — per the
module-tree splicing rule that a module's own name enters its *parent's*
`declared` dict exactly like a binding item (rule 3/5 in
`_build_tree_structure`'s docstring) — so it is reported as kind `:module`
directly, without ever consulting `inv.items`. Otherwise `name` is a regular
binding, and its kind comes from the matching `inv.items` entry.

This is the one place `derived_module_names`'s computation touches an id: it
reads an id-keyed inventory, but the VALUE it hands back (a bare `Symbol`)
never carries that id forward, which is what keeps the selector's own value
id-free (see `derived_module_names`).
"""
function _declared_item_kind(rt, name::String, ref::ItemRef)::Symbol
    inv = derived_file_inventory(rt, ref.file)

    for m in inv.modules
        m.id == ref.id && m.name == name && return :module
    end
    for item in inv.items
        item.id == ref.id && item.name == name && return item.kind
    end

    # Unreachable in practice: every ItemRef in a ModuleNode.declared dict was
    # produced (by `_build_tree_structure`) from an item/module that — by
    # construction — still exists in its defining file's current inventory.
    return :unknown
end

"""
    derived_module_names(rt, root, path::Vector{String}) -> Dict{String,Symbol}

Name → kind for every name declared at `path` in `root`'s module tree.
Empty `Dict` when `path` names no module in the tree.

**Id-free by construction — this is the cutoff seam the inventories
milestone rests on.** Downstream analysis resolves names against THIS
selector, not against `ModuleNode.declared` directly, specifically so that an
id shift which leaves the name→kind SET unchanged (e.g. reordering two
adjacent same-kind declarations, which swaps their item ids and so changes
`derived_module_tree`'s — and `derived_module_declared`'s — own value)
backdates here: Salsa's `isequal` early-exit sees an unchanged `Dict` and
never propagates the change to this selector's own consumers, even though
`derived_module_tree` itself did re-execute.

The computation is NOT id-free — `_declared_item_kind` reads the defining
file's inventory keyed by `ref.id` — but that id-dependence never escapes
into the returned value, and the value is all Salsa's cutoff ever compares.
"""
Salsa.@derived function derived_module_names(rt, root, path)
    @debug "derived_module_names" root=root path=path

    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    node === nothing && return Dict{String,Symbol}()

    return Dict{String,Symbol}(
        name => _declared_item_kind(rt, name, ref) for (name, ref) in node.declared)
end

"""
    derived_module_declared(rt, root, path::Vector{String}) -> Dict{String,ItemRef}

The `name → ItemRef` map for the module at `path` — a straight projection of
`derived_module_tree`'s `ModuleNode.declared`. Id-carrying (unlike
`derived_module_names`), for request-time materialization (M4): resolving an
`ItemRef` back to a position/EXPR in its defining file. Empty `Dict` when
`path` names no module in the tree.
"""
Salsa.@derived function derived_module_declared(rt, root, path)
    @debug "derived_module_declared" root=root path=path

    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    node === nothing && return Dict{String,ItemRef}()

    return node.declared
end

"""
    derived_module_exports(rt, root, path::Vector{String}) -> @NamedTuple{exports::Vector{String}, publics::Vector{String}}

The `export`/`public` names of the module at `path` — a straight projection of
`derived_module_tree`. Empty vectors when `path` names no module in the tree.
"""
Salsa.@derived function derived_module_exports(rt, root, path)
    @debug "derived_module_exports" root=root path=path

    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    node === nothing && return (exports=String[], publics=String[])

    return (exports=node.exports, publics=node.publics)
end

"""
    derived_module_imports(rt, root, path::Vector{String}) -> Vector{ResolvedImport}

The resolved `using`/`import` statements declared at `path` — a straight
projection of `derived_module_tree`. Empty `Vector` when `path` names no
module in the tree.
"""
Salsa.@derived function derived_module_imports(rt, root, path)
    @debug "derived_module_imports" root=root path=path

    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    node === nothing && return ResolvedImport[]

    return node.imports
end

"""
    derived_module_exists(rt, root, path::Vector{String}) -> Bool

Whether `path` names a module in `root`'s tree — the id-free existence
probe. Deliberately NOT expressible as `!isempty(derived_module_names(...))`:
an EMPTY declared module (`module Sub end`) still exists. Exists so that
per-file analysis code can test module existence without depending on the
whole `derived_module_tree` value (a `Bool` backdates on every tree change
that doesn't create/remove this one module).
"""
Salsa.@derived function derived_module_exists(rt, root, path)
    @debug "derived_module_exists" root=root path=path

    tree = derived_module_tree(rt, root)
    return module_node(tree, path) !== nothing
end

"""
    derived_module_declared_at(rt, root, path::Vector{String}) -> Union{Nothing,ItemRef}

The `ItemRef` of the `module` declaration for the module at `path` — a
straight projection of `derived_module_tree`'s `ModuleNode.declared_at`.
`nothing` when `path` names no module in the tree (and for tree modules
without a recorded declaration, e.g. the synthetic root). Id-carrying, but
per-module: a tree-value change elsewhere in the root re-executes only this
cheap projection, whose unchanged value then backdates — this is what lets
the per-file analysis reference a module's declaration site without
depending on the whole tree value.
"""
Salsa.@derived function derived_module_declared_at(rt, root, path)
    @debug "derived_module_declared_at" root=root path=path

    tree = derived_module_tree(rt, root)
    node = module_node(tree, path)
    return node === nothing ? nothing : node.declared_at
end

"""
    derived_file_module_path(rt, root, file::URI) -> Union{Nothing,Vector{String}}

The absolute module path `file`'s top level splices into within `root`'s
module tree — a straight projection of `derived_module_tree`'s
`file_modules`. `nothing` when `file` is not part of `root`'s module tree.
"""
Salsa.@derived function derived_file_module_path(rt, root, file)
    @debug "derived_file_module_path" root=root file=file

    tree = derived_module_tree(rt, root)
    return get(tree.file_modules, file, nothing)
end
