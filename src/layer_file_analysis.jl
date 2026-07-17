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

    # exact-key lookup only: macros are stored WITH the `@` prefix throughout
    # the inventory layers, so a macro reference ("@mymac") hits directly and
    # a bare "mymac" against a macro-only name correctly misses.
    visible = derived_module_visible_names(ctx.rt, ctx.root, ctx.path)
    vn = get(visible, name, nothing)
    vn === nothing && return false
    StaticLint.setref!(x1, StaticLint.TreeRef(name, vn.kind, vn.item, vn.origin_module), meta_dict)
    return true
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
    vn = get(visible, name, nothing)
    vn === nothing && return nothing
    if vn.kind === :module
        child = _denoted_tree_module_path(par, name, vn)
        child !== nothing && return TreeModuleContext(par.rt, par.root, child)
    end
    return StaticLint.TreeRef(name, vn.kind, vn.item, vn.origin_module)
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

# --- The frozen per-file analysis value --------------------------------------

"""
    OutboundRef

One aggregated outbound reference of an analyzed file: a name the per-file
pass resolved THROUGH the module tree (a `StaticLint.TreeRef`-valued ref),
aggregated by `(name, origin_module)`. Plain data (`@auto_hash_equals`):
`target` is the declaring `ItemRef` when the name traces back to a tree
declaration, `nothing` for external/env-backed targets; `count` is the
number of reference sites in this file. Positions are request-time work —
nothing here (or anywhere in this layer) depends on `derived_item_positions`.
"""
@auto_hash_equals struct OutboundRef
    name::String
    target::Union{Nothing,ItemRef}
    origin_module::Vector{String}
    count::Int
end

"""
    FileAnalysis

The frozen result of one per-file semantic analysis (`derived_file_analysis`).

- `meta`: StaticLint meta (local scopes/bindings/refs), for THIS file's
  EXPRs only — the per-file pass follows no includes and merges no other
  file's meta, so no foreign `EXPR`/`Binding` is reachable from it.
- `outbound`: the plain-data outbound-reference table, sorted by
  `(name, origin_module)`.
- `diagnostics`: the file's lint diagnostics (`check_all` + `collect_hints`).

Deliberately NOT `@auto_hash_equals` (unlike `OutboundRef`): `meta` is keyed
by `objectid` of this file's EXPRs, so identity equality is intended — the
value is effectively keyed on this file's content (an unchanged file keeps
the memoized value; a changed file re-runs the pass and produces fresh keys
wholesale), and there is nothing meaningful for a structural comparison to
early-exit on.

Purity: no `TreeModuleContext`/runtime handle survives in `meta`
(`semantic_pass` ends its per-file mode with `strip_module_contexts!`), and
no `ModuleStore`/`ExternalEnv` does either (`_strip_module_stores!` removes
the seeded Base/Core scope entries and rewrites module-store-valued
refs/vals into plain-data `TreeRef` stand-ins). Leaf symbol stores (e.g. a
`FunctionStore` ref for a Base function) are kept: they are small per-symbol
values, not the identity-compared env containers, and the query depends on
`derived_environment` anyway, so an env change recomputes them.
"""
struct FileAnalysis
    meta::Dict{UInt64,StaticLint.Meta}
    outbound::Vector{OutboundRef}
    diagnostics::Vector{Diagnostic}
end

_empty_file_analysis() = FileAnalysis(Dict{UInt64,StaticLint.Meta}(), OutboundRef[], Diagnostic[])

# The full path of a `SymbolServer.VarRef` chain, root-first.
function _var_ref_path(vr::SymbolServer.VarRef)
    segs = String[]
    while vr !== nothing
        pushfirst!(segs, String(vr.name))
        vr = vr.parent
    end
    return segs
end

# The plain-data stand-in for a `ModuleStore` that must not survive in a
# frozen meta: a module-kinded `TreeRef` with the store's own path (no
# `ItemRef` — the environment has none), mirroring the shape
# `_context_tree_ref` produces for tree modules.
function _module_store_tree_ref(m::SymbolServer.ModuleStore)
    segs = _var_ref_path(m.name)
    return StaticLint.TreeRef(segs[end], :module, nothing, segs[1:end - 1])
end

"""
    _strip_module_stores!(meta_dict)

Remove every `SymbolServer.ModuleStore` reachable from `meta_dict` before it
is frozen into a `FileAnalysis`: the Base/Core stores `semantic_pass` seeds
into the root scope's (and each in-file module scope's) `.modules`, plus any
store a `using`/`import` of an external module added, are deleted; a
`Meta.ref`/`Binding.val` that IS a module store (an identifier naming the
module, e.g. the `Base` in `Base.sqrt`) is rewritten to its plain-data
`TreeRef` stand-in so the name stays resolved. Runs AFTER `check_all` /
`collect_hints` (which still read the seeded scopes) and AFTER the outbound
extraction (so env-resolved module names never masquerade as tree-resolved
outbound references). The `:__tree__` context handles are already gone at
this point — `semantic_pass` strips them itself in per-file mode.
"""
function _strip_module_stores!(meta_dict::Dict{UInt64,StaticLint.Meta})
    for m in values(meta_dict)
        s = m.scope
        if s isa StaticLint.Scope && s.modules isa Dict
            for (k, v) in collect(s.modules)
                v isa SymbolServer.ModuleStore && delete!(s.modules, k)
            end
        end
        if m.ref isa SymbolServer.ModuleStore
            m.ref = _module_store_tree_ref(m.ref)
        end
        b = m.binding
        if b isa StaticLint.Binding && b.val isa SymbolServer.ModuleStore
            b.val = _module_store_tree_ref(b.val)
        end
    end
    return
end

# Aggregate every TreeRef-valued ref in `meta_dict` by (name, origin_module).
# Only `Meta.ref` entries count as reference SITES: an import-statement leaf
# binds a `Binding` whose `.val` is a TreeRef, and body uses of that name
# resolve to the (file-local) import binding — neither is a tree-resolved
# ref site itself. The nameless root-context stand-in
# (`TreeRef("", :module, ...)`, produced for import components denoting the
# synthetic tree root) is skipped as noise.
function _collect_outbound(meta_dict::Dict{UInt64,StaticLint.Meta})
    acc = Dict{Tuple{String,Vector{String}},Tuple{Union{Nothing,ItemRef},Int}}()
    for m in values(meta_dict)
        r = m.ref
        r isa StaticLint.TreeRef || continue
        isempty(r.name) && continue
        key = (r.name, r.origin_module)
        prev = get(acc, key, nothing)
        if prev === nothing
            acc[key] = (r.item, 1)
        else
            # same-key TreeRefs agree on the item by construction (one tree
            # snapshot); keep the first non-nothing one defensively
            acc[key] = (prev[1] === nothing ? r.item : prev[1], prev[2] + 1)
        end
    end
    outbound = OutboundRef[OutboundRef(k[1], v[1], k[2], v[2]) for (k, v) in acc]
    sort!(outbound; by=o -> (o.name, o.origin_module))
    return outbound
end

# The per-file slice of `derived_static_lint_diagnostics_for_root`'s
# hint-translation loop (layer_static_lint.jl), over an already-linted meta:
# `collect_hints` with the file's configured missing-ref mode, then the same
# errortoken / missing-ref / UnresolvedImport / LintCodes translation. A
# `Vector` (not the old per-root `Set`): a single file analyzed once cannot
# produce the cross-root duplicates the Set deduplicated, and the CST
# traversal order keeps the result deterministic.
function _file_analysis_diagnostics(rt, cst, env, meta_dict, lint_config, project_uri)
    diagnostics = Diagnostic[]

    # Names the project declares as dependencies, for the UnresolvedImport
    # message split (same computation as the whole-closure pass; empty
    # without a project).
    project = project_uri === nothing ? nothing : derived_project(rt, project_uri)
    declared_deps = project === nothing ? Set{String}() :
        Set{String}(Iterators.flatten((
            keys(project.regular_packages),
            keys(project.stdlib_packages),
            keys(project.deved_packages),
        )))

    missingrefs = _missingrefs_from_config(lint_config)
    # per-file mode: no merged workspace-package meta, cross-file names come
    # from the tree
    workspace_packages = Dict{String,Any}()
    errs = StaticLint.collect_hints(cst, env, workspace_packages, meta_dict, missingrefs)

    for err in errs
        rng = err[1]+1:err[1]+err[2].span+1
        if StaticLint.headof(err[2]) === :errortoken
            # parse errors are the syntax layer's job (matching the
            # whole-closure pass)
        elseif CSTParser.isidentifier(err[2]) && !StaticLint.haserror(err[2], meta_dict)
            push!(diagnostics, Diagnostic(rng, :warning, "Missing reference: $(err[2].val)", nothing, Symbol[], "StaticLint.jl"))
        elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) === StaticLint.UnresolvedImport
            name = CSTParser.str_value(err[2])
            cause = name in declared_deps ?
                "`$name` is a declared dependency but its symbols could not be indexed." :
                "Failed to resolve `$name`."
            consequence = StaticLint.is_in_wildcard_import(err[2]) ?
                "Missing-reference checks are disabled in this scope and all nested scopes." :
                "Anything imported through this statement is assumed to exist and will not be checked."
            push!(diagnostics, Diagnostic(rng, :warning, "$cause $consequence", nothing, Symbol[], "StaticLint.jl"))
        elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) isa StaticLint.LintCodes
            code = StaticLint.errorof(err[2], meta_dict)
            description = get(StaticLint.LintCodeDescriptions, code, "")
            severity, tags = if code in (StaticLint.UnusedFunctionArgument, StaticLint.UnusedBinding, StaticLint.UnusedTypeParameter)
                :hint, Symbol[:unnecessary]
            else
                :information, Symbol[]
            end
            code_details = code === StaticLint.IndexFromLength ? URI("https://docs.julialang.org/en/v1/base/arrays/#Base.eachindex") : nothing
            push!(diagnostics, Diagnostic(rng, severity, description, code_details, tags, "StaticLint.jl"))
        end
    end

    return diagnostics
end

"""
    derived_file_analysis(rt, root::URI, file::URI) -> FileAnalysis

Run StaticLint's per-file traversal (`semantic_pass(...; module_context)`)
over `file` as spliced into `root`'s module tree, and freeze the result:
the file's own meta, the plain-data outbound-reference table, and the
file's lint diagnostics — the per-file counterpart of
`derived_static_lint_meta_for_root` + `derived_static_lint_diagnostics_for_root`'s
whole-closure tail. Returns an empty `FileAnalysis` when `file` is not
spliced under `root` (`derived_file_module_path` returns `nothing`).

Late passes: `check_all`, `resolve_remaining_getfields!`, and
`mark_unresolved_imports!` run in the old tail's order, AFTER
`semantic_pass` — which, in per-file mode, has already stripped the seeded
`:__tree__` context handles from the meta's scopes. That placement is
correct because none of the three needs tree resolution: they dispatch on
`Binding`s / stored errors (late getfield resolution guards on
`lhsref isa Binding`, so a `TreeRef` LHS is skipped; import marking only
reads refs and sets errors). Any FUTURE post-pass step that DOES need tree
resolution must re-seed a fresh `TreeModuleContext` first (see the comment
at `semantic_pass`'s strip call site).

## Cutoff analysis

The query depends on this file's CST (`derived_julia_legacy_syntax_tree`),
the id-free path selector (`derived_file_module_path` — deliberately NOT
`derived_module_tree(rt, root).file_modules[file]`, whose whole-tree value
changes on every tree-table change anywhere in the root), the visible names
of the modules the file's names resolve through
(`derived_module_visible_names`, reached via the `TreeModuleContext`), the
file's lint configuration, and the environment. Consequences:

- A body edit in a SIBLING file: that file's inventory backdates → the
  module tree backdates → the selectors backdate → this analysis is
  untouched.
- A top-level edit in a sibling that doesn't change the name/kind sets:
  `derived_module_names`/visible-names backdate → this analysis is
  untouched (the id-shift survival of the Task-2 selector layer pays off
  here).

Caveat: a file whose own text contains `using`/`import` of tree modules
additionally reaches `derived_module_tree` directly (through the context's
import-path helpers `_denoted_tree_module_path`/`_module_declared_at`), so
for exactly those files a tree-VALUE change re-runs the analysis even when
their module's visible names are unaffected; files without such imports
keep the selector-level cutoff described above.
"""
Salsa.@derived function derived_file_analysis(rt, root, file)
    @debug "derived_file_analysis" root=root file=file

    path = derived_file_module_path(rt, root, file)
    path === nothing && return _empty_file_analysis()

    # TODO Same provisional project lookup as the whole-closure pass.
    project_uri = derived_project_uri_for_root(rt, root)
    # No project yet (e.g. a standalone package whose DJP is still computing):
    # the memoized stdlib-only env keeps locally-defined and stdlib names
    # resolving — same fallback (and same identity-sharing rationale) as
    # `derived_static_lint_meta_for_root`.
    env = project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)

    cst = derived_julia_legacy_syntax_tree(rt, file)
    meta_dict = Dict{UInt64,StaticLint.Meta}()

    ctx = TreeModuleContext(rt, root, path)
    StaticLint.semantic_pass(file, cst, env, meta_dict, rt; module_context=ctx)

    # The per-file slice of the whole-closure pass's tail
    # (`derived_static_lint_meta_for_root`, layer_static_lint.jl), in the
    # same order, minus the closure loop: this file is the only file.
    lint_config = derived_lint_configuration(rt, file)
    StaticLint.check_all(cst, _lint_options_from_config(lint_config), env, meta_dict)

    # Late getfield reference resolution — mutates meta_dict, so it must run
    # here, while we still own it (no workspace-package meta in per-file
    # mode, hence the empty dict).
    StaticLint.resolve_remaining_getfields!(cst, env, Dict{String,Any}(), meta_dict)

    # Late import-failure marking (in-pass failures may be retried via
    # `state.resolveonly`, so this can only run after the pass).
    StaticLint.mark_unresolved_imports!(cst, meta_dict)

    diagnostics = _file_analysis_diagnostics(rt, cst, env, meta_dict, lint_config, project_uri)

    # Extract outbound BEFORE the store strip: the strip rewrites env-store
    # module refs into TreeRef stand-ins, which must not be counted as
    # tree-resolved outbound references.
    outbound = _collect_outbound(meta_dict)

    _strip_module_stores!(meta_dict)

    return FileAnalysis(meta_dict, outbound, diagnostics)
end
