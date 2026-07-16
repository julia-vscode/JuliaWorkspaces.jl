# Layer 1 of the inventory architecture (see
# docs/superpowers/specs/2026-07-16-inventory-architecture-design.md):
# a per-file, position-free, plain-data summary of top-level items. Values in
# this file are the firewall: they must contain only plain data (Symbols,
# Strings, Ints, vectors/structs of those) — never an EXPR reference, an
# objectid, a byte offset, or a docstring — so that body edits produce
# `isequal` inventories and Salsa's early-exit stops invalidation here.
# Position/EXPR reattachment lives exclusively in `derived_item_positions`.

"""
    InventoryItem

One top-level (module-level) item of a file. `parent_module` is the module
path within this file, outermost→innermost; `String[]` means the file's own
top level (whatever module the file is spliced into by its includer).
`signature` is a normalized (re-printed) signature string for functions and
macros, `nothing` otherwise. `field_names` is populated for structs.
"""
@auto_hash_equals struct InventoryItem
    id::Int
    name::String
    kind::Symbol
    signature::Union{Nothing,String}
    field_names::Vector{String}
    parent_module::Vector{String}
end

"""
    InventoryImport

A `using`/`import` statement. `path` is the module path with leading "."
entries encoding relative levels (`using ..Sibling` → `[".", ".", "Sibling"]`);
`symbols` is the explicit symbol list of `using X: a, b` (empty for whole-module
imports); `alias` is the `as` name if present.
"""
@auto_hash_equals struct InventoryImport
    id::Int
    kind::Symbol
    path::Vector{String}
    symbols::Vector{String}
    alias::Union{Nothing,String}
    parent_module::Vector{String}
end

"An `export` or `public` statement and the names it lists."
@auto_hash_equals struct InventoryExport
    id::Int
    kind::Symbol
    names::Vector{String}
    parent_module::Vector{String}
end

"An `include(...)` call with its resolved target (or `nothing` if unresolvable)."
@auto_hash_equals struct InventoryInclude
    id::Int
    target::Union{Nothing,URI}
    parent_module::Vector{String}
end

"A `module`/`baremodule` declared in this file."
@auto_hash_equals struct InventoryModule
    id::Int
    name::String
    bare::Bool
    parent_module::Vector{String}
end

"""
    FileInventory

The complete top-level API summary of one file. Structural equality (via
`@auto_hash_equals`) is the early-cutoff contract: two inventories are equal
iff the file's top-level API is identical, regardless of body edits,
whitespace, comments, or docstrings.
"""
@auto_hash_equals struct FileInventory
    items::Vector{InventoryItem}
    imports::Vector{InventoryImport}
    exports::Vector{InventoryExport}
    includes::Vector{InventoryInclude}
    modules::Vector{InventoryModule}
end

const EMPTY_FILE_INVENTORY = FileInventory(
    InventoryItem[], InventoryImport[], InventoryExport[], InventoryInclude[], InventoryModule[])

# Detect a doc-macro wrapper: a 4-arg :macrocall whose first arg is the
# implicit `globalrefdoc` or an explicit `@doc` / `Mod.@doc`. The wrapped item
# sits at args[4]. Mirrors layer_hover.jl's `_is_doc_expr` shape and
# layer_navigation.jl:105-109's offset handling.
function _doc_wrapped_item(x::CSTParser.EXPR)
    CSTParser.ismacrocall(x) || return nothing
    x.args !== nothing && length(x.args) == 4 || return nothing
    _is_doc_macro_name(x.args[1]) || return nothing
    return x.args[4]
end

"""
    _foreach_toplevel_item(f, cst)

Call `f(x, id, parent_module, offset)` for every top-level item-like node of a
`:file` CST in pre-order: the file's direct children, plus — for
`module`/`baremodule` declarations — the module node itself and then the
children of its body block (never the bodies of functions, structs, etc.).
Ids are sequential in visit order; doc-macro wrappers are transparent (the
wrapped item is visited, with `offset` pointing at it, not the docstring).
This walker is the single source of truth for item ids: the inventory
extractor and the position map both use it, so ids always agree.
"""
function _foreach_toplevel_item(f, cst::CSTParser.EXPR)
    next_id = Ref(0)
    _walk_toplevel!(f, cst.args, String[], 0, next_id)
    return nothing
end

function _walk_toplevel!(f, args, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    args === nothing && return offset
    for a in args
        item = a
        item_offset = offset
        wrapped = _doc_wrapped_item(a)
        if wrapped !== nothing
            for j in 1:3
                item_offset += a.args[j].fullspan
            end
            item = wrapped
        end

        next_id[] += 1
        f(item, next_id[], parent_module, item_offset)

        if CSTParser.defines_module(item) && item.args !== nothing && length(item.args) >= 3
            mod_name = CSTParser.isidentifier(item.args[2]) ? StaticLint.valofid(item.args[2]) : nothing
            if mod_name !== nothing
                inner_parent = vcat(parent_module, [mod_name])
                # Offset of the module block's first child: the module node's
                # offset plus the fullspans of the `module`/`baremodule`
                # keyword token (held in `.trivia[1]`, NOT `.args[1]` — the
                # latter is a synthetic bare/non-bare flag with span 0; see
                # layer_navigation.jl:122) and the name.
                block_offset = item_offset + item.trivia[1].fullspan + item.args[2].fullspan
                _walk_toplevel!(f, item.args[3].args, inner_parent, block_offset, next_id)
            end
        end

        offset += a.fullspan
    end
    return offset
end
