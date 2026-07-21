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
# at `path`. ANY import form that names a module loads it, so its overloads of
# Base/other store functions are live dispatch candidates — hence all of:
# `:using_external` (whole-module `using Foo`), `:import_binding` (selective
# `using Foo: bar`, module-name `using Foo: Foo`, and bare `import Foo`), and
# `:using_workspace_package` (cross-root packages). `origin_module` is the target
# module's path in every case, so its head names the loaded module. Base/Core are
# implicit (the always-available rule in `iterate_over_ss_methods`), but including
# them here when explicitly imported is harmless.
const _IN_SCOPE_ORIGINS = (:using_external, :import_binding, :using_workspace_package)
function _in_scope_module_syms(rt, root, path::Vector{String})
    syms = Set{Symbol}()
    for (_, vn) in derived_module_visible_names(rt, root, path)
        vn.origin in _IN_SCOPE_ORIGINS && !isempty(vn.origin_module) &&
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
