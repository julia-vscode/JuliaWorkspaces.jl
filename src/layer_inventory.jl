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

"An explicit symbol in a `using`/`import` colon-form list (`using X: a as b`);
`alias` is the bound name when the symbol is `as`-renamed, `nothing` otherwise —
`name` is always the *source* name, never the bound one."
const ImportSymbol = @NamedTuple{name::String, alias::Union{Nothing,String}}

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
    symbols::Vector{ImportSymbol}
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
`if`/`elseif`/`else` and bare `begin...end` blocks are ALSO transparent (they
introduce no scope — StaticLint's `introduces_scope`, scope.jl:78-107, has no
arm for `:if`/`:block`, so definitions inside them bind at the enclosing
level): their statement lists are walked as if they were direct siblings of
the container, at the same `parent_module` and continuing the same id
sequence; the container node itself gets no id and is never passed to `f`.
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

        if CSTParser.headof(item) === :if
            _walk_if_chain!(f, item, parent_module, item_offset, next_id)
        elseif CSTParser.headof(item) === :block
            _walk_transparent_block!(f, item, parent_module, item_offset, next_id)
        else
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
        end

        offset += a.fullspan
    end
    return offset
end

# A `:block` node is CSTParser's uniform wrapper for a statement list. As a
# bare `if`/`elseif`/`else` branch body it carries no keyword trivia of its
# own (the branch's statements start exactly at the block's own offset); as an
# explicit top-level `begin...end` it carries `BEGIN`/`END` keyword trivia, so
# its statements start after the `begin` keyword's fullspan. Both shapes were
# confirmed via `CSTParser.parse` exploration (see the task report).
function _walk_transparent_block!(f, block::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    if block.trivia !== nothing && !isempty(block.trivia) && CSTParser.headof(block.trivia[1]) === :BEGIN
        offset += block.trivia[1].fullspan
    end
    _walk_toplevel!(f, block.args, parent_module, offset, next_id)
    return nothing
end

# Walks an `:if`/`:elseif` chain transparently. Node shape (confirmed via CST
# exploration): `trivia[1]` is the node's own `IF`/`ELSEIF` keyword; `args` is
# `[cond, then-block]` or `[cond, then-block, tail]`, where `tail` is either
# another `:elseif` node (continuing the chain — its own `ELSEIF` keyword is
# in ITS `trivia[1]`, not this node's) or a plain `:block` (a trailing `else`,
# whose `ELSE` keyword sits at this node's `trivia[2]`, right after the own
# keyword).
function _walk_if_chain!(f, node::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    offset += node.trivia[1].fullspan  # IF or ELSEIF keyword
    offset += node.args[1].fullspan    # condition
    _walk_transparent_block!(f, node.args[2], parent_module, offset, next_id)
    offset += node.args[2].fullspan

    if length(node.args) >= 3
        tail = node.args[3]
        if CSTParser.headof(tail) === :elseif
            _walk_if_chain!(f, tail, parent_module, offset, next_id)
        else
            offset += node.trivia[2].fullspan  # ELSE keyword
            _walk_transparent_block!(f, tail, parent_module, offset, next_id)
        end
    end
    return nothing
end

"""
    derived_file_inventory(rt, uri) -> FileInventory

Layer 1 of the inventory architecture: the per-file, position-free API summary
of `uri`'s top-level items. `EMPTY_FILE_INVENTORY` when the file has no
content or doesn't parse to a `:file` CST.
"""
Salsa.@derived function derived_file_inventory(rt, uri)
    @debug "derived_file_inventory" uri=uri

    derived_has_content(rt, uri) || return EMPTY_FILE_INVENTORY
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return EMPTY_FILE_INVENTORY

    include_targets_by_offset = Dict{Int,Union{Nothing,URI}}(
        offset => target for (offset, _, target) in derived_file_include_records(rt, uri))

    acc = (items=InventoryItem[], imports=InventoryImport[], exports=InventoryExport[],
           includes=InventoryInclude[], modules=InventoryModule[])
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        _classify_item!(acc, x, id, copy(parent_module), offset, include_targets_by_offset)
    end
    return FileInventory(acc.items, acc.imports, acc.exports, acc.includes, acc.modules)
end

_render_sig(x) = try
    sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
    sig === nothing ? nothing : string(CSTParser.to_codeobject(sig))
catch
    nothing
end

# Unwrap an identifier (or `var"..."` name) to its String value; `nothing` for
# anything else. Never uses `CSTParser.valof` directly on an identifier —
# `var"..."` (NONSTDIDENTIFIER) nodes return `nothing` from `valof`, so we go
# through `StaticLint.valofid`, which already handles that unwrap (and is used
# elsewhere in this file for the same purpose, e.g. module names).
_item_name(x) = x isa CSTParser.EXPR && CSTParser.isidentifier(x) ? StaticLint.valofid(x) : nothing

# A symbol usable in a colon-form import list (`using X: a, +`) or an
# `export`/`public` statement (`export +, f`): a plain identifier OR an
# *operator* name. `_item_name` alone only accepts identifiers, silently
# dropping operator names at both call sites — this is Finding 2's fix.
function _symbol_name(x)
    nm = _item_name(x)
    nm !== nothing && return nm
    return x isa CSTParser.EXPR && CSTParser.isoperator(x) ? CSTParser.valof(x) : nothing
end

# A struct field's bound name, mirroring the final branch of `mark_binding!`
# (bindings.jl:161-165) for the two shapes struct fields actually take:
# `name` (bare) and `name::T` (declared). `rem_decl` is CSTParser's own
# declaration-unwrapping helper (interface.jl:135), so this needn't reimplement it.
_field_name(x) = _item_name(CSTParser.rem_decl(x))

# The macro name as a plain string, handling the `Mod.@macro` qualified form.
# Mirrors the structure of `layer_hover.jl`'s `_is_doc_macro_name`, returning
# the name string instead of a boolean match.
_macro_name_string(x) = nothing
function _macro_name_string(x::CSTParser.EXPR)
    if CSTParser.isidentifier(x)
        return CSTParser.str_value(x)
    elseif CSTParser.is_getfield_w_quotenode(x)
        return _macro_name_string(CSTParser.unquotenode(CSTParser.rhs_getfield(x)))
    else
        return nothing
    end
end

# Match by macro *name* rather than `StaticLint._points_to_Base_macro`, which
# needs resolution state (a `Binding` ref pointing at the real `Base.@enum`)
# that the inventory must not depend on — see the module docstring's firewall
# note. A user shadowing `@enum` with an unrelated macro of the same name will
# misclassify identically to how `mark_bindings!`'s conservatism already
# accepts false positives elsewhere; this is a deliberate, spec-directed
# deviation from macros.jl:55, not an oversight.
_is_enum_macro(x::CSTParser.EXPR) = _macro_name_string(x.args[1]) == "@enum"

# An `@enum` member/type-name argument may be wrapped in an explicit-value
# assignment (`red = 1`) or a `::T` base-type declaration (only valid on the
# type-name argument, `@enum Color::UInt8 ...`); mirrors
# `mark_enum_member_binding!` (macros.jl:147-153) plus the declaration-unwrap
# that `mark_binding!` itself performs via `get_name` for the non-assignment
# case.
function _enum_item_name(x)
    x isa CSTParser.EXPR || return nothing
    if CSTParser.isassignment(x)
        x = x.args[1]
    end
    return _field_name(x)
end

# Mirrors `resolve_import_block` (imports.jl:1-87)'s structure walk of one
# import path/symbol node, without any resolution: leading `.` tokens become
# `"."` path entries, identifiers accumulate into `path`, and an `:as` wrapper
# yields the alias name (recursing into the wrapped path first, exactly as
# `resolve_import_block`'s `x.head == :as` branch does).
function _walk_import_block(block::CSTParser.EXPR)
    if CSTParser.headof(block) === :as
        (block.args === nothing || length(block.args) != 2) && return (String[], nothing)
        inner_path, _ = _walk_import_block(block.args[1])
        return (inner_path, _item_name(block.args[2]))
    end
    path = String[]
    block.args === nothing && return (path, nothing)
    for arg in block.args
        if CSTParser.isoperator(arg) && CSTParser.valof(arg) == "."
            push!(path, ".")
        else
            nm = _symbol_name(arg)
            nm === nothing || push!(path, nm)
        end
    end
    return (path, nothing)
end

_is_include_call(x) = CSTParser.iscall(x) && CSTParser.fcall_name(x) == "include" && length(x.args) == 2

# Classify one assignment EXPR (bindings.jl:57-66's `isassignment` branches),
# emitting the appropriate `InventoryItem`. `kind_override` lets `:const`/
# `:global` wrappers reclassify the same shapes without duplicating this logic.
function _classify_assignment!(acc, x, id, parent_module, kind_override=nothing)
    if CSTParser.is_func_call(x.args[1])
        name = _item_name(CSTParser.get_name(x))
        name === nothing && return
        push!(acc.items, InventoryItem(id, name, something(kind_override, :function), _render_sig(x), String[], parent_module))
    elseif CSTParser.iscurly(x.args[1])
        # Typealias: `Vector{T} = ...` — name comes from the curly's base
        # identifier, mirroring `mark_typealias_bindings!` (bindings.jl:288-301).
        name = _item_name(CSTParser.get_name(x.args[1]))
        name === nothing && return
        push!(acc.items, InventoryItem(id, name, something(kind_override, :assignment), nothing, String[], parent_module))
    elseif !CSTParser.is_getfield(x.args[1])
        # Plain identifier lhs. (Tuple-destructuring/other lhs shapes that
        # `mark_binding!` further unwraps are out of scope for this milestone —
        # `_item_name` returns `nothing` for them and no item is emitted.)
        name = _item_name(x.args[1])
        name === nothing && return
        push!(acc.items, InventoryItem(id, name, something(kind_override, :assignment), nothing, String[], parent_module))
    end
    return
end

function _classify_item!(acc, x, id, parent_module, offset, include_targets_by_offset)
    if CSTParser.defines_module(x)
        # name/bare per bindings.jl:90-92 and scope.jl:172-181
        name = CSTParser.isidentifier(x.args[2]) ? StaticLint.valofid(x.args[2]) : nothing
        name === nothing && return
        push!(acc.modules, InventoryModule(id, name, CSTParser.headof(x.args[1]) === :FALSE, parent_module))
    elseif CSTParser.headof(x) === :function || CSTParser.headof(x) === :macro
        # bindings.jl:83-89
        name = _item_name(CSTParser.get_name(x))
        name === nothing && return
        kind = CSTParser.headof(x) === :function ? :function : :macro
        push!(acc.items, InventoryItem(id, name, kind, _render_sig(x), String[], parent_module))
    elseif CSTParser.defines_datatype(x)
        # bindings.jl:96-115
        name = _item_name(CSTParser.get_name(x))
        name === nothing && return
        if CSTParser.defines_struct(x)
            kind = CSTParser.defines_mutable(x) ? :mutable_struct : :struct
            field_names = String[]
            for arg in x.args[3].args
                CSTParser.defines_function(arg) && continue
                if CSTParser.headof(arg) === :const
                    arg = arg.args[1]
                end
                # Unconditional kwdef-style unwrap: recording a defaulted
                # field's name is correct regardless of whether the struct is
                # actually `@kwdef`-decorated, and the inventory must not
                # depend on macro-resolution state to tell — a deliberate
                # deviation from bindings.jl:110's `kwdef &&` guard.
                if CSTParser.isassignment(arg)
                    arg = arg.args[1]
                end
                fname = _field_name(arg)
                fname === nothing || push!(field_names, fname)
            end
        else
            kind = CSTParser.defines_abstract(x) ? :abstract : :primitive
            field_names = String[]
        end
        push!(acc.items, InventoryItem(id, name, kind, nothing, field_names, parent_module))
    elseif CSTParser.isassignment(x)
        # bindings.jl:57-66: function-call form → :function with signature;
        # curly lhs → :assignment (typealias); plain identifier lhs → :assignment
        _classify_assignment!(acc, x, id, parent_module)
    elseif CSTParser.headof(x) === :const || CSTParser.headof(x) === :global
        # unwrap and recurse into the inner assignment with kind override
        kind_override = CSTParser.headof(x) === :const ? :const : :global
        for inner in something(x.args, CSTParser.EXPR[])
            if CSTParser.isassignment(inner)
                _classify_assignment!(acc, inner, id, parent_module, kind_override)
            elseif CSTParser.isidentifier(inner)
                name = _item_name(inner)
                name === nothing || push!(acc.items, InventoryItem(id, name, kind_override, nothing, String[], parent_module))
            end
        end
    elseif CSTParser.headof(x) === :export || CSTParser.headof(x) === :public
        names = String[]
        for a in x.args
            nm = _symbol_name(a)
            nm === nothing || push!(names, nm)
        end
        isempty(names) || push!(acc.exports, InventoryExport(id, CSTParser.headof(x) === :export ? :export : :public, names, parent_module))
    elseif CSTParser.headof(x) === :using || CSTParser.headof(x) === :import
        # mirror imports.jl's structure walking; emit InventoryImport entries
        kind = CSTParser.headof(x) === :using ? :using : :import
        args = x.args
        if args !== nothing && length(args) > 0 && CSTParser.isoperator(CSTParser.headof(args[1])) &&
           CSTParser.valof(CSTParser.headof(args[1])) == ":"
            # Colon form (`using A: b, c`): one entry per statement, symbols
            # collected from the remaining colon-node children. Each symbol's
            # OWN alias (`a as b`) is recorded alongside its source name — the
            # bound name is `alias` when present, never `name` (Finding 3).
            cargs = args[1].args
            if cargs !== nothing && length(cargs) > 0
                path, alias = _walk_import_block(cargs[1])
                symbols = ImportSymbol[]
                for i in 2:length(cargs)
                    spath, salias = _walk_import_block(cargs[i])
                    isempty(spath) || push!(symbols, (name=last(spath), alias=salias))
                end
                isempty(path) || push!(acc.imports, InventoryImport(id, kind, path, symbols, alias, parent_module))
            end
        else
            # Non-colon form: each top-level arg (`using A, B`) is its own target.
            for block in something(args, CSTParser.EXPR[])
                path, alias = _walk_import_block(block)
                isempty(path) || push!(acc.imports, InventoryImport(id, kind, path, ImportSymbol[], alias, parent_module))
            end
        end
    elseif _is_include_call(x)  # call named "include" with one argument
        push!(acc.includes, InventoryInclude(id, get(include_targets_by_offset, offset, nothing), parent_module))
    elseif CSTParser.ismacrocall(x)
        if _is_enum_macro(x)   # per macros.jl:55-67: name via _points_to_Base_macro-style check on x.args[1]
            # x.args[3] is always the enum type name (args[1]=macro name,
            # args[2]=the macrocall's parameters placeholder, always `nothing`
            # for `@enum`'s bare/space-separated call syntax); args[4:end] (or
            # args[4].args when args[4] is a `begin...end` block) are members.
            margs = x.args
            if margs !== nothing && length(margs) >= 3
                tname = _enum_item_name(margs[3])
                tname === nothing || push!(acc.items, InventoryItem(id, tname, :enum, nothing, String[], parent_module))
                members = if length(margs) == 4 && CSTParser.headof(margs[4]) === :block
                    margs[4].args
                else
                    margs[4:end]
                end
                for member in something(members, CSTParser.EXPR[])
                    mname = _enum_item_name(member)
                    mname === nothing || push!(acc.items, InventoryItem(id, mname, :enum_member, nothing, String[], parent_module))
                end
            end
        else
            mname = _macro_name_string(x.args[1])
            push!(acc.items, InventoryItem(id, something(mname, ""), :opaque_macrocall, nothing, String[], parent_module))
        end
    end
    return
end

"""
    derived_item_positions(rt, uri)

Map each inventory item id to its current syntax node and 0-based byte offset.
Volatile: recomputes on every reparse (EXPR identities and offsets change),
which is fine because it is a leaf — semantic layers depend on
`derived_file_inventory` (position-free) only; this query exists solely for
request handlers to reattach locations, docstrings, and defining EXPRs at the
last mile. Depending on this query from any layer-1/2/3 computation is a bug.
"""
Salsa.@derived function derived_item_positions(rt, uri)
    result = Dict{Int,@NamedTuple{expr::CSTParser.EXPR, offset::Int}}()

    derived_has_content(rt, uri) || return result
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return result

    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        result[id] = (expr=x, offset=offset)
    end
    return result
end
