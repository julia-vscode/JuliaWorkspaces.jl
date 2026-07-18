# References layer
#
# Provides go-to-definition, find-references, rename, document highlight,
# and prepare-rename. All position parameters use 0-based byte offsets
# internally; result types expose Position values.

# ============================================================================
# Result types
# ============================================================================

"""
    struct DefinitionResult

The location a go-to-definition request resolves to.

- `uri::URI`: File containing the definition.
- `start::Position`: Start of the definition's name range.
- `stop::Position`: End of the definition's name range.
"""
struct DefinitionResult
    uri::URI
    start::Position
    stop::Position
end

"""
    struct ReferenceResult

A single location where a symbol is referenced (used by find-references).

- `uri::URI`: File containing the reference.
- `start::Position`: Start of the reference range.
- `stop::Position`: End of the reference range.
"""
struct ReferenceResult
    uri::URI
    start::Position
    stop::Position
end

"""
    struct RenameEdit

A single text edit that renames an occurrence of a symbol.

- `uri::URI`: File the edit applies to.
- `start::Position`: Start of the range to replace.
- `stop::Position`: End of the range to replace.
- `new_text::String`: Replacement text.
"""
struct RenameEdit
    uri::URI
    start::Position
    stop::Position
    new_text::String
end

"""
    struct HighlightResult

A document-highlight range for an occurrence of a symbol.

- `start::Position`: Start of the occurrence.
- `stop::Position`: End of the occurrence.
- `kind::Symbol`: `:read` or `:write`, indicating whether the occurrence reads
  or writes the symbol.
"""
struct HighlightResult
    start::Position
    stop::Position
    kind::Symbol      # :read or :write
end

# ============================================================================
# Shared helpers (used by multiple layers)
# ============================================================================

"""
    _get_identifier(x, offset, pos=0)

Walk a CSTParser EXPR tree and return the IDENTIFIER leaf whose span
covers `offset` (0-based byte offset). Returns `nothing` if no identifier
is found at that position.
"""
function _get_identifier(x, offset, pos=0)
    if pos > offset
        return nothing
    end
    if length(x) > 0
        for a in x
            if pos <= offset <= (pos + a.span)
                return _get_identifier(a, offset, pos)
            end
            pos += a.fullspan
        end
    elseif CSTParser.headof(x) === :IDENTIFIER && (pos <= offset <= (pos + x.span)) || pos == 0
        return x
    end
    return nothing
end

"""
    _get_expr_or_parent(x, offset, pos=0)

Like `_get_expr`, but only returns an expr if offset is strictly within its
span (not on the edge). If offset falls in trailing whitespace, returns the
parent instead.
"""
function _get_expr_or_parent(x, offset, pos=0)
    if pos > offset
        return nothing, pos
    end
    ppos = pos
    if length(x) > 0 && CSTParser.headof(x) !== :NONSTDIDENTIFIER
        for a in x
            if pos < offset <= (pos + a.fullspan)
                if pos < offset < (pos + a.span)
                    return _get_expr_or_parent(a, offset, pos)
                else
                    return x, ppos
                end
            end
            pos += a.fullspan
        end
    elseif pos == 0
        return x, pos
    elseif (pos < offset <= (pos + x.fullspan))
        if pos + x.span < offset
            return x.parent, ppos
        end
        return x, pos
    end
    return nothing, pos
end

"""
    _resolve_shadow_binding(b)

Follow shadow binding chains (where `b.val` is another `Binding`) with loop
detection.
"""
_resolve_shadow_binding(b) = b
function _resolve_shadow_binding(b::StaticLint.Binding, visited=StaticLint.Binding[])
    if b in visited
        return b  # break loop
    else
        push!(visited, b)
    end
    if b.val isa StaticLint.Binding
        return _resolve_shadow_binding(b.val, visited)
    else
        return b
    end
end

"""
    _canonical_local_definition(b, meta_dict)

For a plain reassignable local, StaticLint creates a distinct `Binding` at every
assignment (issue #101), so `refof` on a use points at the nearest assignment
rather than the variable's original declaration. Remap such a binding to the
earliest same-named binding in its scope so go-to-definition lands on the
original declaration. Anything that isn't an assignment-introduced named local
(functions, types, modules, parameters, iteration variables, …) is returned
unchanged.
"""
_canonical_local_definition(b, meta_dict) = b
function _canonical_local_definition(b::StaticLint.Binding, meta_dict)
    (b.val isa CSTParser.EXPR && b.type === nothing &&
        StaticLint.isidentifier(b.name) && CSTParser.isassignment(b.val)) || return b
    bindings = StaticLint.loose_bindings(b, meta_dict)
    # `loose_bindings` collects in source order, so the first entry is the
    # earliest (original) binding site.
    isempty(bindings) ? b : first(bindings)
end

"""
    _get_file_loc(x::CSTParser.EXPR, runtime)

Return `(uri, offset)` for the given EXPR node by walking parents to the file
root and looking up the owning URI from the Salsa-memoized expr→URI mapping.
Returns `nothing` if the EXPR cannot be mapped to a file.
"""
function _get_file_loc(x::CSTParser.EXPR, runtime)
    root = x
    while CSTParser.parentof(root) !== nothing
        root = CSTParser.parentof(root)
    end
    CSTParser.headof(root) === :file || return nothing
    expr_uri_map = derived_expr_uri_map(runtime)
    uri = get(expr_uri_map, objectid(root), nothing)
    uri === nothing && return nothing
    _, offset = _descend(root, x)
    return (uri, offset)
end

"""
    _for_each_ref(f, identifier::CSTParser.EXPR, meta_dict, runtime)

For each loose reference of the binding that `identifier` refers to, call
`f(ref_expr, ref_uri, ref_offset)`. This is the core iteration backbone
shared by references, rename, and highlight.
"""
function _for_each_ref(f, identifier::CSTParser.EXPR, meta_dict::MetaDict, runtime)
    if StaticLint.hasref(identifier, meta_dict) && StaticLint.refof(identifier, meta_dict) isa StaticLint.Binding
        # StaticLint can register the same EXPR node more than once (e.g. a macro
        # definition's name ends up in the binding's `refs` twice), so dedupe by
        # node identity to avoid emitting duplicate results. Identity
        # (not structural) equality is required: distinct occurrences such as two
        # `@add_2` invocations are structurally equal and must be kept separate.
        seen = Base.IdSet{CSTParser.EXPR}()
        for r in StaticLint.loose_refs(StaticLint.refof(identifier, meta_dict), meta_dict)
            if r isa CSTParser.EXPR && !(r in seen)
                push!(seen, r)
                loc = _get_file_loc(r, runtime)
                if loc !== nothing
                    uri, o = loc
                    f(r, uri, o)
                end
            end
        end
    end
end

# The scope that OWNS binding `b` (`b` is registered in its `.names`), found by
# walking outward from `x`'s scope. Membership is by object identity — matching
# `b.name`'s string would break for macros, whose binding is filed under the
# `@`-prefixed key while `b.name` is bare.
function _home_scope(x::CSTParser.EXPR, b::StaticLint.Binding, meta_dict)
    s = StaticLint.retrieve_scope(x, meta_dict)
    while s isa StaticLint.Scope
        for v in values(s.names)
            v === b && return s
        end
        s = CSTParser.parentof(s)
    end
    return nothing
end

# Classify what the identifier `x` refers to, for the references/rename/highlight
# entry points. Returns:
#   (:tree, ItemRef)      — a MODULE-LEVEL name: resolved through the module tree
#                           (a `TreeRef`, or an import binding whose `.val` is
#                           one), OR a module-level binding declared in THIS file
#                           (its item recovered from `derived_module_declared` of
#                           the file's module path). References of these aggregate
#                           cross-file via `each_reference`.
#   (:local, Binding)     — a non-module-level binding (function-local, argument,
#                           comprehension var, …), OR an external import binding
#                           with no tree item: references stay CURRENT-FILE
#                           (`_for_each_ref` on the per-file meta).
#   nothing               — no ref, or a store-backed leaf with no binding.
function _reference_target(runtime, root::URI, uri::URI, x::CSTParser.EXPR, meta_dict)
    StaticLint.hasref(x, meta_dict) || return nothing
    r = StaticLint.refof(x, meta_dict)

    if r isa StaticLint.TreeRef
        return r.item === nothing ? nothing : (:tree, r.item)
    elseif r isa StaticLint.Binding && r.val isa StaticLint.TreeRef
        return r.val.item === nothing ? (:local, r) : (:tree, r.val.item)
    elseif r isa StaticLint.Binding
        cst = derived_julia_legacy_syntax_tree(runtime, uri)
        fscope = cst isa CSTParser.EXPR ? StaticLint.scopeof(cst, meta_dict) : nothing
        hs = _home_scope(x, r, meta_dict)
        is_module_level = hs !== nothing &&
            (hs === fscope || (hs.expr isa CSTParser.EXPR && CSTParser.defines_module(hs.expr)))
        if is_module_level
            path = derived_file_module_path(runtime, root, uri)
            if path !== nothing
                p = vcat(path, _in_file_module_names(x, meta_dict))
                declared = derived_module_declared(runtime, root, p)
                sv = CSTParser.str_value(x)
                cand = get(declared, sv, nothing)
                if cand === nothing && !startswith(sv, "@")
                    cand = get(declared, "@" * sv, nothing)
                end
                cand !== nothing && cand.file == uri && return (:tree, cand)
            end
        end
        return (:local, r)
    end
    return nothing
end

# Current-file-only reference sites of the tree-declared `target`: the declaring
# file's `loose_refs` (when `uri` owns the item) plus every `TreeRef`-target
# match within `uri`'s own meta. Used by document highlight, which stays
# current-file (no cross-root walk). `f(ref_expr, offset)` per site.
function _each_current_file_ref(f, runtime, uri::URI, target::ItemRef, meta_dict)
    seen_offsets = Set{Int}()
    emit = function (x::CSTParser.EXPR)
        loc = _get_file_loc(x, runtime)
        loc === nothing && return
        ref_uri, o = loc
        ref_uri == uri || return
        o in seen_offsets && return
        push!(seen_offsets, o)
        f(x, o)
        return
    end

    if uri == target.file
        b = _item_declaring_binding(runtime, target, meta_dict)
        if b isa StaticLint.Binding
            seen = Base.IdSet{CSTParser.EXPR}()
            for r in StaticLint.loose_refs(b, meta_dict)
                if r isa CSTParser.EXPR && !(r in seen)
                    push!(seen, r)
                    emit(r)
                end
            end
        end
    end

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    cst isa CSTParser.EXPR || return
    _walk_exprs(cst) do x
        CSTParser.is_id_or_macroname(x) || return
        StaticLint.hasref(x, meta_dict) || return
        r = StaticLint.refof(x, meta_dict)
        tr = r isa StaticLint.TreeRef ? r :
            (r isa StaticLint.Binding && r.val isa StaticLint.TreeRef) ? r.val : nothing
        (tr !== nothing && tr.item == target) && emit(x)
        return
    end
    return
end

"""
    safe_isfile(s)

Safe version of `isfile` that handles invalid paths, null bytes, and IO errors.
"""
safe_isfile(s::Symbol) = safe_isfile(string(s))
safe_isfile(::Nothing) = false
function safe_isfile(s::AbstractString)
    try
        !occursin("\0", s) && isfile(s)
    catch err
        isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
        false
    end
end

# ============================================================================
# Go-to-definition
# ============================================================================

function _get_definitions_from_val(x, tls, env, results, runtime, root=nothing) end # fallback

function _get_definitions_from_val(x::SymbolServer.ModuleStore, tls, env, results, runtime, root=nothing)
    if haskey(x.vals, :eval) && x[:eval] isa SymbolServer.FunctionStore
        _get_definitions_from_val(x[:eval], tls, env, results, runtime, root)
    end
end

function _get_definitions_from_val(x::Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}, tls, env, results, runtime, root=nothing)
    StaticLint.iterate_over_ss_methods(x, tls, env, function (m)
        if safe_isfile(m.file)
            pos = Position(m.line, 1)
            push!(results, DefinitionResult(
                URIs2.filepath2uri(string(m.file)),
                pos,
                pos
            ))
        end
        return false
    end)
    # Workspace method extensions of the store callee (`Base.relpath(::T)` in a
    # sibling) are not in the env store's method set — offer them too.
    if root !== nothing
        for e in _matching_workspace_extensions(runtime, root, env, x)
            _push_item_definition(e.ref, results, runtime)
        end
    end
end

function _get_definitions_from_val(b::StaticLint.Binding, tls, env, results, runtime, root=nothing)
    if !(b.val isa CSTParser.EXPR)
        _get_definitions_from_val(b.val, tls, env, results, runtime, root)
    end
    if b.type === StaticLint.CoreTypes.Function || b.type === StaticLint.CoreTypes.DataType
        for ref in b.refs
            method = StaticLint.get_method(ref)
            if method !== nothing
                _get_definitions_from_val(method, tls, env, results, runtime, root)
            end
        end
    elseif b.val isa CSTParser.EXPR
        _get_definitions_from_val(b.val, tls, env, results, runtime, root)
    end
end

function _get_definitions_from_val(x::CSTParser.EXPR, tls::StaticLint.Scope, env, results, runtime, root=nothing)
    loc = _get_file_loc(x, runtime)
    if loc !== nothing
        uri, o = loc
        push!(results, DefinitionResult(uri, _offset_to_position(runtime, uri, o), _offset_to_position(runtime, uri, o + x.span)))
    end
end

# Kinds whose go-to-definition offers ALL method items (`derived_method_items`),
# not just the single declaring item: multi-definition callables. Functions and
# macros offer every method; a struct/datatype offers its declaration AND its
# outer constructors (F12 on a struct call offers its constructors exactly as
# F12 on a function offers its methods — old whole-closure parity, where
# `_get_definitions_from_val(::Binding)` walked a DataType binding's refs the
# same as a Function's). The datatype kinds are those `derived_file_inventory`
# emits (layer_inventory.jl:617/636). Everything else with an ItemRef
# (const/global/assignment/enum/enum member/module) resolves to its one
# declaring item.
const _DEF_METHOD_ITEM_KINDS = (:function, :macro, :struct, :mutable_struct, :abstract, :primitive)

# Push the definition location of a single inventory item, materialized
# request-time from its own file (`derived_item_positions` — the volatile leaf,
# allowed in a request handler). The range spans the whole defining EXPR,
# matching the old `get_method`-based rendering.
function _push_item_definition(ref::ItemRef, results, runtime)
    entry = get(derived_item_positions(runtime, ref.file), ref.id, nothing)
    entry === nothing && return
    o = entry.offset
    push!(results, DefinitionResult(
        ref.file,
        _offset_to_position(runtime, ref.file, o),
        _offset_to_position(runtime, ref.file, o + entry.expr.span),
    ))
    return
end

# Go-to-definition for a name resolved THROUGH the module tree (a plain-data
# `TreeRef`): materialize its declaring item(s)' positions at the last mile.
# A function/macro offers every method item of its origin module
# (`derived_method_items` — go-to-def on a 2-method function lands on both);
# any other tree-declared kind resolves to its single declaring item. Env
# stand-ins (`item === nothing`) resolve their store leaf and reuse the
# store-backed path.
function _get_definitions_from_tree_ref(tr::StaticLint.TreeRef, tls, env, results, runtime, root::URI)
    if tr.item === nothing
        if tr.kind === :external_symbol && !isempty(tr.origin_module)
            store = _resolve_external_module(runtime, root, tr.origin_module)
            if store isa SymbolServer.ModuleStore
                val = get(store.vals, Symbol(tr.name), nothing)
                val isa SymbolServer.VarRef && (val = StaticLint.maybe_lookup(val, env))
                val isa SymbolServer.SymStore && tls isa StaticLint.Scope &&
                    _get_definitions_from_val(val, tls, env, results, runtime, root)
            end
        elseif tr.kind === :external_module
            # A `using`/`import`ed external module name (`using CodeTracking`,
            # `using Base`): the strip rewrote its store ref to this stand-in.
            # Resolve the module store and route through the ModuleStore path
            # (jumps to the module's source via its `eval`), mirroring hover.
            store = _resolve_external_module(runtime, root, vcat(tr.origin_module, [tr.name]))
            store isa SymbolServer.ModuleStore && tls isa StaticLint.Scope &&
                _get_definitions_from_val(store, tls, env, results, runtime, root)
        end
        return
    end
    if tr.kind in _DEF_METHOD_ITEM_KINDS
        qroot = _method_items_root(runtime, root, tr.origin_module)
        rendered = false
        for ref in derived_method_items(runtime, qroot, tr.origin_module, tr.name)
            before = length(results)
            _push_item_definition(ref, results, runtime)
            rendered |= length(results) > before
        end
        # Fall back to the single declaring item when the selector yields
        # nothing (e.g. the name is not a tree method of its origin path).
        rendered || _push_item_definition(tr.item, results, runtime)
    else
        _push_item_definition(tr.item, results, runtime)
    end
    return
end

"""
    _get_definitions(runtime, uri, offset)

Core definition logic: find all definition locations for the expression at
`offset` (0-based) in the file identified by `uri`.
"""
function _get_definitions(runtime, uri::URI, offset::Int)
    results = DefinitionResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    # Per-file analysis meta (the inventory architecture's per-file pass), not
    # the whole-closure static-lint meta: a name declared in a SIBLING file
    # resolves here as a plain-data `TreeRef`, which is reattached to its
    # declaring item's position at the last mile. Same env selection as
    # `derived_file_analysis`.
    project_uri = derived_project_uri_for_root(runtime, root)
    meta_dict = derived_file_analysis(runtime, root, uri).meta
    env = project_uri !== nothing ? derived_environment(runtime, project_uri) : derived_stdlib_only_env(runtime)

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)

    if x isa CSTParser.EXPR && StaticLint.hasref(x, meta_dict)
        b = StaticLint.refof(x, meta_dict)
        tls = _retrieve_toplevel_scope(x, meta_dict)
        # A tree-resolved target (directly, or a file-local import binding whose
        # `.val` is a `TreeRef`) reattaches through the inventory; everything
        # else — a file-local `Binding`, or a store-backed `FunctionStore`/… —
        # keeps the old per-file/env path unchanged.
        tr = b isa StaticLint.TreeRef ? b :
            (b isa StaticLint.Binding && b.val isa StaticLint.TreeRef) ? b.val : nothing
        if tr !== nothing
            _get_definitions_from_tree_ref(tr, tls, env, results, runtime, root)
        else
            b = _resolve_shadow_binding(b)
            b = _canonical_local_definition(b, meta_dict)
            tls === nothing && return results
            _get_definitions_from_val(b, tls, env, results, runtime, root)
        end
    end

    return unique!(results)
end

# ============================================================================
# Find references
# ============================================================================

"""
    _get_references(runtime, uri, offset)

Find all references to the symbol at `offset` (0-based) in the file `uri`.
"""
function _get_references(runtime, uri::URI, offset::Int)
    results = ReferenceResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    # Per-file analysis meta (the inventory architecture's per-file pass): a
    # module-level name resolves to its `ItemRef` and its references are
    # aggregated cross-file over the outbound tables (`each_reference`); a
    # file-local binding keeps the old within-file `loose_refs` walk.
    meta_dict = derived_file_analysis(runtime, root, uri).meta
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x === nothing && return results

    tgt = _reference_target(runtime, root, uri, x, meta_dict)
    if tgt !== nothing && tgt[1] === :tree
        each_reference(runtime, tgt[2]) do ref, ref_uri, o
            push!(results, ReferenceResult(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span)))
        end
    elseif tgt !== nothing && tgt[1] === :local
        _for_each_ref(x, meta_dict, runtime) do ref, ref_uri, o
            push!(results, ReferenceResult(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span)))
        end
    end

    return results
end

# ============================================================================
# Rename
# ============================================================================

"""
    _get_rename_edits(runtime, uri, offset, new_name)

Compute rename edits for the symbol at `offset` (0-based) in `uri`.
"""
function _get_rename_edits(runtime, uri::URI, offset::Int, new_name::String)
    results = RenameEdit[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    meta_dict = derived_file_analysis(runtime, root, uri).meta
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x === nothing && return results

    # A macro's definition uses the bare name (`add_2`) while every invocation
    # carries a leading `@` (`@add_2`). The client may send the new name with or
    # without the `@`; normalize to the bare form and re-add the `@` only for the
    # occurrences that had one, so the definition and invocations stay consistent
    bare_name = startswith(new_name, "@") ? new_name[nextind(new_name, 1):end] : new_name

    tgt = _reference_target(runtime, root, uri, x, meta_dict)
    if tgt !== nothing && tgt[1] === :tree
        # References aggregate every target-matching site, INCLUDING alias
        # occurrences (`g` for `using .Sib: f as g`). Rename must NOT touch the
        # alias sites — renaming `f` leaves `g` bound to it — so edits are
        # confined to occurrences spelled with the item's own (bare) name; the
        # `as`-alias statement's source component still renames, the `g` uses do
        # not. This preserves the old rename's source-name-only behavior.
        item_name = _inventory_item_name(runtime, tgt[2])
        target_bare = item_name === nothing ? nothing : _bare_macro_name(item_name)
        each_reference(runtime, tgt[2]) do ref, ref_uri, o
            sv = CSTParser.str_value(ref)
            (target_bare === nothing || _bare_macro_name(sv) == target_bare) || return
            text = startswith(sv, "@") ? "@" * bare_name : bare_name
            push!(results, RenameEdit(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span), text))
        end
    elseif tgt !== nothing && tgt[1] === :local
        _for_each_ref(x, meta_dict, runtime) do ref, ref_uri, o
            text = startswith(CSTParser.str_value(ref), "@") ? "@" * bare_name : bare_name
            push!(results, RenameEdit(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span), text))
        end
    end

    return results
end

# ============================================================================
# Prepare rename
# ============================================================================

"""
    _can_rename(runtime, uri, offset)

Check if the symbol at `offset` (0-based) can be renamed. Returns a named
tuple with `start::Position` and `stop::Position`, or `nothing`.
"""
function _can_rename(runtime, uri::URI, offset::Int)
    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return nothing

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x isa CSTParser.EXPR || return nothing

    loc = _get_file_loc(x, runtime)
    loc === nothing && return nothing
    _, x_start = loc

    return (start=_offset_to_position(runtime, uri, x_start), stop=_offset_to_position(runtime, uri, x_start + x.span))
end

# ============================================================================
# Document highlight
# ============================================================================

"""
    _get_highlights(runtime, uri, offset)

Get all highlights (read/write) for the symbol at `offset` (0-based) in `uri`.
Only returns highlights within the same file.
"""
function _get_highlights(runtime, uri::URI, offset::Int)
    results = HighlightResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    meta_dict = derived_file_analysis(runtime, root, uri).meta
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    identifier = _get_identifier(cst, offset)
    identifier === nothing && return results

    # Highlights stay CURRENT-FILE: a module-level name uses the same per-file
    # meta `loose_refs` + outbound-target matches, but confined to this file
    # (`_each_current_file_ref`), never the cross-root `each_reference` walk; a
    # file-local binding uses the old within-file `loose_refs`.
    tgt = _reference_target(runtime, root, uri, identifier, meta_dict)
    if tgt !== nothing && tgt[1] === :tree
        _each_current_file_ref(runtime, uri, tgt[2], meta_dict) do ref, o
            kind = StaticLint.hasbinding(ref, meta_dict) ? :write : :read
            push!(results, HighlightResult(_offset_to_position(runtime, uri, o), _offset_to_position(runtime, uri, o + ref.span), kind))
        end
    elseif tgt !== nothing && tgt[1] === :local
        _for_each_ref(identifier, meta_dict, runtime) do ref, ref_uri, o
            if ref_uri == uri
                kind = StaticLint.hasbinding(ref, meta_dict) ? :write : :read
                push!(results, HighlightResult(_offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span), kind))
            end
        end
    end

    return results
end
