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
  `:workspace_package`, `[package_name]`; for `:external` or `:unresolved`,
  the original path segments as written.
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
    empty_module_tree(root::URI)

Construct an empty module tree with just a synthetic root node.
"""
function empty_module_tree(root::URI)
    ModuleTree(root,
        [ModuleNode(String[], false, nothing, URI[], Dict{String,ItemRef}(), String[], String[], ResolvedImport[])],
        Dict{URI,Vector{String}}())
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
# (and, eventually, pass 2) is complete. Field meanings mirror `ModuleNode`
# exactly (see its docstring) minus `path`, which is the builder's key in the
# owning `Dict`.
mutable struct _ModuleNodeBuilder
    bare::Bool
    declared_at::Union{Nothing,ItemRef}
    files::Vector{URI}
    declared::Dict{String,ItemRef}
    exports::Vector{String}
    publics::Vector{String}
    imports::Vector{ResolvedImport}
end

_ModuleNodeBuilder() = _ModuleNodeBuilder(
    false, nothing, URI[], Dict{String,ItemRef}(), String[], String[], ResolvedImport[])

"""
    _build_tree_structure(rt, root::URI) -> (builders, file_modules)

Pass 1 of `derived_module_tree`: splices `root`'s (transitive) include closure
into a per-root module structure, per the normative splicing semantics (see
the milestone design doc / task brief). Returns the raw mutable builders
(keyed by absolute module path) and the `file → absolute splice path` map;
`derived_module_tree` freezes the builders into plain-data `ModuleNode`s.

Also collects `using`/`import` statements as `ResolvedImport`s whose target is
`ImportTarget(:unresolved, path-as-written)` — pass 2 (a later task) replaces
this classification with real resolution; this pass never inspects import
targets beyond recording them verbatim.
"""
function _build_tree_structure(rt, root::URI)
    builders = Dict{Vector{String},_ModuleNodeBuilder}()
    ensure_node!(path::Vector{String}) = get!(_ModuleNodeBuilder, builders, path)

    # Rule 8: the synthetic root node always exists, even for a root file with
    # no content or no includes.
    ensure_node!(String[])

    file_modules = Dict{URI,Vector{String}}()

    # Rule 1: BFS worklist, visited-set guarded exactly like
    # `derived_include_closure` — first include wins, later includes of an
    # already-visited file are skipped, and cycles terminate.
    visited = Set{URI}([root])
    queue = Tuple{URI,Vector{String}}[(root, String[])]

    while !isempty(queue)
        (F, P) = popfirst!(queue)

        # Rule 7.
        file_modules[F] = P

        # The file's own top level splices at P; recording F here handles
        # both the root file (no includer) and included files uniformly —
        # rule 4's "T appended to that node's files" falls out of this same
        # bookkeeping once T is actually dequeued and processed.
        push!(ensure_node!(P).files, F)

        inv = derived_file_inventory(rt, F)

        # Rules 3 & 5 interact on the same `declared` dict (a module's own
        # name enters its *parent's* declared entries, rule 3, exactly like a
        # binding item does, rule 5) so within-file overwrite order must
        # follow true source order, not category order. Ids are globally
        # sequential within one file's walk (`_foreach_toplevel_item`), so
        # merging by id and applying in that order reproduces it.
        declared_events = Tuple{Int,Vector{String},String,ItemRef}[]
        for item in inv.items
            if isempty(item.qualifier) && item.kind in _BINDING_ITEM_KINDS
                push!(declared_events, (item.id, vcat(P, item.parent_module), item.name, (file=F, id=item.id)))
            end
        end
        for m in inv.modules
            push!(declared_events, (m.id, vcat(P, m.parent_module), m.name, (file=F, id=m.id)))
        end
        sort!(declared_events; by=first, alg=Base.Sort.MergeSort)
        for (_, abs_path, name, ref) in declared_events
            ensure_node!(abs_path).declared[name] = ref
        end

        # Rule 3: create/extend each declared module's own node.
        for m in inv.modules
            mod_path = vcat(P, m.parent_module, [m.name])
            node = ensure_node!(mod_path)
            node.bare = m.bare
            node.declared_at = (file=F, id=m.id)
        end

        # Rule 6.
        for e in inv.exports
            node = ensure_node!(vcat(P, e.parent_module))
            append!(e.kind === :export ? node.exports : node.publics, e.names)
        end

        # Rule 4: enqueue include targets (skipping `nothing`/content-less
        # targets and — via `visited` — duplicates), splicing at vcat(P, RP).
        for inc in inv.includes
            inc.target === nothing && continue
            newP = vcat(P, inc.parent_module)
            # The node at newP must exist regardless of whether this
            # particular include resolves (other items may share RP).
            ensure_node!(newP)
            inc.target in visited && continue
            derived_has_content(rt, inc.target) || continue
            push!(visited, inc.target)
            push!(queue, (inc.target, newP))
        end

        # Pass 2 stub: collect imports unresolved; a later task classifies
        # `target.sort` for real.
        for imp in inv.imports
            node = ensure_node!(vcat(P, imp.parent_module))
            push!(node.imports, ResolvedImport(
                imp.kind, ImportTarget(:unresolved, imp.path), imp.symbols, imp.alias, (file=F, id=imp.id)))
        end
    end

    return builders, file_modules
end

"""
    derived_module_tree(rt, root::URI) -> ModuleTree

The module structure of `root`'s (transitive) include closure: pass 1 splices
every reachable file's top-level items into the module tree they belong to
(see `_build_tree_structure`); pass 2 (a later task) resolves `using`/`import`
targets. `modules` is sorted by path for deterministic structural equality.
"""
Salsa.@derived function derived_module_tree(rt, root)
    @debug "derived_module_tree" root=root

    builders, file_modules = _build_tree_structure(rt, root)

    modules = ModuleNode[
        ModuleNode(path, b.bare, b.declared_at, b.files, b.declared, b.exports, b.publics, b.imports)
        for (path, b) in builders]
    sort!(modules; by=n -> n.path, alg=Base.Sort.MergeSort)

    return ModuleTree(root, modules, file_modules)
end
