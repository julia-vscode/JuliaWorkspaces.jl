# Shared "which modules are in scope here" helpers, built on top of the
# visibility layer (layer_visibility.jl). Reused by hover/signatures/references
# to widen their method search past Base/Core to whatever the file's `using`s
# actually bring into scope.

# External-package `using`/`import` origin paths (env modules, e.g. ["LibGit2"])
# visible in `visible`. Shared by completions and the in-scope-module set so both
# read one definition. Excludes workspace-package and in-tree origins.
_using_external_origins(visible) =
    Set{Vector{String}}(vn.origin_module for (_, vn) in visible
                         if vn.origin === :using_external && !isempty(vn.origin_module))

# Top-level symbol of every external/workspace-package module brought into scope
# at `path` (their exported names can carry overloads of Base/other store
# functions). Base/Core are implicit — handled by the always-available rule in
# `iterate_over_ss_methods` — so they are intentionally NOT collected here.
function _in_scope_module_syms(rt, root, path::Vector{String})
    visible = derived_module_visible_names(rt, root, path)
    syms = Set{Symbol}(Symbol(p[1]) for p in _using_external_origins(visible))
    for (_, vn) in visible
        vn.origin === :using_workspace_package && !isempty(vn.origin_module) &&
            push!(syms, Symbol(vn.origin_module[1]))
    end
    return syms
end

# The enclosing `:file` root EXPR of `x` (walk parents); `nothing` if `x` is
# detached or not under a file.
function _file_root(x)
    root = x
    while CSTParser.parentof(root) !== nothing
        root = CSTParser.parentof(root)
    end
    return CSTParser.headof(root) === :file ? root : nothing
end

# The URI of the file `x` lives in: look the `:file` root up in the expr→uri
# map. `nothing` if `x` is detached or the map has no entry.
function _uri_for_expr(rt, x)
    root = _file_root(x)
    root === nothing && return nothing
    return get(derived_expr_uri_map(rt), objectid(root), nothing)
end

# The in-scope external/workspace module set at `x`'s position: the file's splice
# path extended by any in-file modules enclosing `x`. `nothing` when it can't be
# resolved (no runtime/root/uri) — the caller then uses the scope.modules fallback.
function _in_scope_syms_at(rt, root, x, meta_dict)
    (rt === nothing || root === nothing) && return nothing
    uri = _uri_for_expr(rt, x)
    uri === nothing && return nothing
    base = derived_file_module_path(rt, root, uri)
    base === nothing && return nothing
    return _in_scope_module_syms(rt, root, vcat(base, _in_file_module_names(x, meta_dict)))
end
