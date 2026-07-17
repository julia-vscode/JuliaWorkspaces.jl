# Layer 3 of the inventory architecture: the per-file analysis bridge. This
# file supplies the RESOLUTION CONTEXT that StaticLint's per-file traversal
# mode (`semantic_pass(...; module_context=...)`) uses to resolve non-local
# names through the module tree (`derived_module_visible_names`,
# layer_visibility.jl) instead of the cross-file scope graph.
#
# `TreeModuleContext` is a handle, deliberately NOT plain data: it holds the
# Salsa runtime and lives only inside a running analysis (like
# `Toplevel.runtime` does). It must never be stored in a derived value —
# everything that ends up in refs is the plain-data `StaticLint.TreeRef`.

"""
    TreeModuleContext(rt, root::URI, path::Vector{String})

The module-tree resolution handle for one per-file analysis: names that are
not local to the analyzed file resolve through
`derived_module_visible_names(rt, root, path)`. `path` is the module the
file's code lives in (`derived_file_module_path` for the file's top level; a
CHILD context — path extended by the module name — for each `module`
declared inside the analyzed file, see
`StaticLint.seed_module_scope_context!`).
"""
struct TreeModuleContext{RT} <: StaticLint.AbstractModuleContext
    rt::RT
    root::URI
    path::Vector{String}
end

StaticLint.child_module_context(ctx::TreeModuleContext, name::String) =
    TreeModuleContext(ctx.rt, ctx.root, vcat(ctx.path, [name]))

# The plain-data stand-in for the module `ctx` denotes — what a reference to
# the module itself (e.g. an import-path component) gets as its ref.
function _context_tree_ref(ctx::TreeModuleContext)
    isempty(ctx.path) && return StaticLint.TreeRef("", :module, nothing, String[])
    return StaticLint.TreeRef(ctx.path[end], :module, _module_declared_at(ctx.rt, ctx.root, ctx.path), ctx.path[1:end - 1])
end

# A module context is never stored in meta: setting it as a ref stores the
# plain-data TreeRef it denotes instead (reached from `resolve_import_block`,
# which setref!s whatever `_get_field` resolved an import-path component to).
StaticLint.setref!(x::CSTParser.EXPR, ctx::TreeModuleContext, meta_dict) =
    StaticLint.setref!(x, _context_tree_ref(ctx), meta_dict)

"""
    StaticLint.resolve_ref_from_module(x, ctx::TreeModuleContext, state) -> Bool

Resolve the identifier `x` through the module tree: look its name up in
`derived_module_visible_names(ctx.rt, ctx.root, ctx.path)` and, on a hit,
set a plain-data `TreeRef`. Reached with ZERO changes to `resolve_ref`'s
scope walk: the per-file pass seeds `:__tree__ => ctx` into the root scope's
(and each in-file module scope's) `.modules` Dict, whose values `resolve_ref`
already tries via `resolve_ref_from_module` after file-local names miss.
"""
function StaticLint.resolve_ref_from_module(x1::CSTParser.EXPR, ctx::TreeModuleContext, state::StaticLint.TraverseState)::Bool
    meta_dict = state.meta_dict
    StaticLint.hasref(x1, meta_dict) && return true
    CSTParser.isidentifier(x1) || return false
    name = StaticLint.valofid(x1)
    name === nothing && return false

    visible = derived_module_visible_names(ctx.rt, ctx.root, ctx.path)
    hit = _visible_lookup(visible, name)
    hit === nothing && return false
    key, vn = hit
    StaticLint.setref!(x1, StaticLint.TreeRef(key, vn.kind, vn.item, vn.origin_module), meta_dict)
    return true
end

# Visible-names lookup bridging the macro-name mismatch: inventory items
# store macros WITHOUT the `@` ("mymac", kind `:macro`) while a reference
# site's identifier carries it ("@mymac"); external stores keep the `@`, so
# the exact key is tried first. Returns `(matched_key, VisibleName)` or
# `nothing`.
function _visible_lookup(visible::Dict{String,VisibleName}, name::String)
    haskey(visible, name) && return (name, visible[name])
    if startswith(name, "@")
        stripped = name[2:end]
        vn = get(visible, stripped, nothing)
        vn !== nothing && vn.kind === :macro && return (stripped, vn)
    end
    return nothing
end

# The tree path of the module a module-kinded VisibleName DENOTES, or
# `nothing` when it isn't a module of this root's tree (external and
# workspace-package modules chain no further in-file). `VisibleName` doesn't
# carry the denoted path directly — `origin_module` is the declaring module
# for `:declared` names but the target module itself for whole-module
# bindings — so both candidates are validated against the tree, extended
# path first (the only ambiguous case, an alias colliding with an equally
# named submodule of the target, is resolved in the submodule's favor).
function _denoted_tree_module_path(ctx::TreeModuleContext, name::String, vn::VisibleName)
    tree = derived_module_tree(ctx.rt, ctx.root)
    extended = vcat(vn.origin_module, [name])
    module_node(tree, extended) === nothing || return extended
    if !isempty(vn.origin_module) && module_node(tree, vn.origin_module) !== nothing
        return vn.origin_module
    end
    return nothing
end

"""
    StaticLint._get_field(par::TreeModuleContext, arg, state, visited)

Import-path resolution through the tree (the per-file counterpart of the
`Scope`/`ModuleStore` methods): the analyzed file's own `using`/`import`
statements re-resolve their path components through the module context
rather than cross-file scope walks. A component naming a module of this
root's tree resolves to a CHILD `TreeModuleContext` (so the walk can
continue into it); anything else visible resolves to its plain-data
`TreeRef`; a miss returns `nothing` (the standard unresolved-import path).
"""
function StaticLint._get_field(par::TreeModuleContext, arg, state, visited=Base.IdSet{Any}())
    name = CSTParser.str_value(arg)
    (name isa String && !isempty(name)) || return nothing
    visible = derived_module_visible_names(par.rt, par.root, par.path)
    hit = _visible_lookup(visible, name)
    hit === nothing && return nothing
    key, vn = hit
    if vn.kind === :module
        child = _denoted_tree_module_path(par, key, vn)
        child !== nothing && return TreeModuleContext(par.rt, par.root, child)
    end
    return StaticLint.TreeRef(key, vn.kind, vn.item, vn.origin_module)
end

# Import-arg marking for a component that resolved to a module context:
# mirrors the whole-closure `_mark_import_arg`, minus everything that would
# leak the handle or another file's objects into meta. The binding's val is
# the context's plain-data `TreeRef` (leaf components that resolve directly
# to a TreeRef take the GENERIC `_mark_import_arg`, which stores them the
# same way — `Binding.val` admits `TreeRef`). No `scope.modules` entry is
# added for `using`: a `using` statement is necessarily module-toplevel, so
# its bring-ins are already part of this module's
# `derived_module_visible_names` — the seeded context covers them.
function StaticLint._mark_import_arg(arg, par::TreeModuleContext, state, usinged, meta_dict)
    CSTParser.is_id_or_macroname(arg) || return
    if StaticLint.bindingof(arg, meta_dict) === nothing
        StaticLint.ensuremeta(arg, meta_dict)
        StaticLint.getmeta(arg, meta_dict).binding = StaticLint.Binding(arg, _context_tree_ref(par), StaticLint.CoreTypes.Module, [])
        StaticLint.setref!(arg, StaticLint.bindingof(arg, meta_dict), meta_dict)
    end
    if !usinged
        # import binds the name in the current scope — except under `as`,
        # where only the alias is bound (matching `_mark_import_arg`)
        if !(CSTParser.parentof(arg) isa CSTParser.EXPR && CSTParser.parentof(CSTParser.parentof(arg)) isa CSTParser.EXPR && CSTParser.headof(CSTParser.parentof(CSTParser.parentof(arg))) === :as)
            state.scope.names[StaticLint.valofid(arg)] = StaticLint.bindingof(arg, meta_dict)
        end
    end
    return
end
