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

If two package folders in the workspace claim the same package name, the
folder with the lexicographically smaller URI (by `string(uri)`) wins; folders
are iterated in sorted order so later (larger) duplicates are simply skipped.
"""
Salsa.@derived function derived_workspace_package_roots(rt)
    @debug "derived_workspace_package_roots"

    folders = sort(derived_package_folders(rt); by=string)

    claimed = Set{String}()
    result = Dict{String,URI}()
    for folder in folders
        package = derived_package(rt, folder)
        package === nothing && continue

        # Deterministic tie-break: folders are sorted by URI, so the first
        # (lexicographically smallest) folder to claim a package name wins;
        # skip any later folder claiming the same name, even if this folder's
        # entry file turns out to be missing.
        package.name in claimed && continue
        push!(claimed, package.name)

        entry_uri = filepath2uri(joinpath(uri2filepath(folder), "src", "$(package.name).jl"))
        if derived_has_file(rt, entry_uri)
            result[package.name] = entry_uri
        end
    end
    return result
end
