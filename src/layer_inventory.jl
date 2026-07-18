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
`qualifier` is the leading module-path of a qualified method extension
(`Base.foo` → `["Base"]`, `Base.Iterators.bar` → `["Base", "Iterators"]`);
`String[]` means the name is bound locally (a plain definition, not a method
extension of an already-existing name elsewhere). `signature` is a normalized
(re-printed) signature string for functions and macros, `nothing` otherwise.
`field_names` is populated for structs.
"""
@auto_hash_equals struct InventoryItem
    id::Int
    name::String
    qualifier::Vector{String}
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
Non-isolating macrocalls (everything except the testitem/testset families and
`@enum`, see `_is_isolated_scope_macrocall`) are transparent the same way:
StaticLint traverses a macrocall's arguments in the enclosing scope, so
`Salsa.@derived function f() end`, `@auto_hash_equals struct S end`,
`@static if …`-wrapped imports/includes, etc. all bind at the module level —
the inventory must be exactly as sighted (spec: "no blinder" than
`mark_bindings!`/the traversal that consumes it).
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
        _walk_one!(f, a, parent_module, offset, next_id)
        offset += a.fullspan
    end
    return offset
end

function _walk_one!(f, a, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    item = a
    item_offset = offset
    wrapped = _doc_wrapped_item(a)
    if wrapped !== nothing
        for j in 1:3
            item_offset += a.args[j].fullspan
        end
        item = wrapped
    end

    # A ternary (`cond ? a : b`) also parses with head `:if`, so the
    # container check alone isn't enough to tell it apart from a real
    # `if`/`elseif`/`else` chain — and checking whether `args[2]` (the
    # "then" branch) is `:block`-shaped is NOT a reliable discriminator
    # either: `cond ? begin ... end : b` gives a ternary an `args[2]` with
    # head `:block` too (confirmed via CST exploration). What's reliable
    # is the node's own leading keyword trivia: a real `if`/`elseif` node
    # has `trivia[1]` headed `:IF`/`:ELSEIF`; a ternary's `trivia[1]` is
    # its `?` operator token. So only descend when `trivia[1]` is the
    # real keyword; a ternary falls through to the `else` branch below and
    # is treated as a single opaque item (no descent into its arms).
    if CSTParser.headof(item) === :if && CSTParser.headof(item.trivia[1]) === :IF
        _walk_if_chain!(f, item, parent_module, item_offset, next_id)
    elseif CSTParser.headof(item) === :block
        _walk_transparent_block!(f, item, parent_module, item_offset, next_id)
    elseif CSTParser.ismacrocall(item) && !_is_enum_macro(item) && !_is_isolated_scope_macrocall(item)
        _walk_macrocall!(f, item, parent_module, item_offset, next_id)
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
    return nothing
end

# Macros whose bodies are ISOLATED from the enclosing module scope in the
# analysis — StaticLint's `is_scope_introducing_macrocall` (`@testitem`,
# `@testset`, `@safetestset`; scope.jl:144-154) plus the prebuilt-scope
# testsetup macros (`@testmodule`/`@testsnippet`; macros.jl:97-106). Nothing
# declared inside them binds at the enclosing level, so the walker keeps the
# macrocall opaque (one `:opaque_macrocall` item, no descent). Every OTHER
# macrocall is walked transparently — matching StaticLint's traversal, which
# processes macro arguments in the enclosing scope.
#
# Qualified forms match STATICLINT'S OWN matchers exactly:
# `is_scope_introducing_macrocall` unwraps `Module.@testset`-style getfields,
# so the `@testset` family isolates qualified or bare — but
# `_is_testmodule_macro`/`_is_testsnippet_macro` (macros.jl:335-336) are
# bare-identifier-only, so a qualified `X.@testmodule` gets no prebuilt
# scope there, the old traversal descends into it, and the inventory must
# descend identically.
function _is_isolated_scope_macrocall(x::CSTParser.EXPR)
    mname = _macro_name_string(x.args[1])
    (mname == "@testitem" || mname == "@testset" || mname == "@safetestset") && return true
    bare = x.args[1] isa CSTParser.EXPR && CSTParser.isidentifier(x.args[1]) ?
        StaticLint.valofid(x.args[1]) : nothing
    return bare == "@testmodule" || bare == "@testsnippet"
end

# Walks a non-isolating macrocall's macro ARGUMENTS as top-level items: the
# macro-name component (`args[1]`) and the parameters placeholder (`args[2]`,
# a zero-span `:NOTHING` node) are skipped; every remaining arg goes through
# the same per-item dispatch as a direct file-level statement (so nested
# `@static if` chains, blocks, and even macrocall-wrapped modules all work).
# Offsets come from CSTParser's source-order child iteration (`for c in x`
# interleaves args and trivia in source order), which stays correct for the
# call form `@foo(a, b)` where paren/comma TRIVIA sit between the args —
# summing arg fullspans alone would drift there.
function _walk_macrocall!(f, mc::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, next_id::Ref{Int})
    margs = mc.args
    (margs === nothing || length(margs) < 3) && return nothing
    child_offset = offset
    for c in mc
        if any(j -> margs[j] === c, 3:length(margs))
            _walk_one!(f, c, parent_module, child_offset, next_id)
        end
        child_offset += c.fullspan
    end
    return nothing
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

    include_records = derived_file_include_records(rt, uri)
    include_targets_by_offset = Dict{Int,Union{Nothing,URI}}(
        offset => target for (offset, _, target) in include_records)

    acc = (items=InventoryItem[], imports=InventoryImport[], exports=InventoryExport[],
           includes=InventoryInclude[], modules=InventoryModule[])
    _foreach_toplevel_item(cst) do x, id, parent_module, offset
        _classify_item!(acc, x, id, copy(parent_module), offset, include_targets_by_offset, include_records)
    end
    return FileInventory(acc.items, acc.imports, acc.exports, acc.includes, acc.modules)
end

_render_sig(x) = try
    sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
    sig === nothing ? nothing : string(CSTParser.to_codeobject(sig))
catch err
    err isa InterruptException && rethrow()
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

# Split a getfield chain `A.B.c` (parsed as nested binary "." operators, each
# level's rhs a `quotenode`-wrapped identifier; see `is_getfield_w_quotenode`)
# into its leading qualifier path `["A", "B"]`, peeling one level at a time —
# the same shape StaticLint's `resolve_getfield`/`rhs_of_getfield`/
# `lhs_of_getfield` (references.jl) peel during resolution, but collecting
# strings instead of resolving. `x` is the FULL chain (i.e. what `get_name`
# would reduce down to the final identifier); returns `String[]` if the chain
# doesn't bottom out in a plain identifier.
function _getfield_qualifier(x)
    CSTParser.is_getfield_w_quotenode(x) || return String[]
    parts = String[]
    while CSTParser.is_getfield_w_quotenode(x)
        # `_symbol_name`, not `_item_name`: the innermost level peeled is the
        # defined name itself (discarded below via `parts[1:end - 1]`), which
        # may be an operator for a quoted-operator method extension
        # (`Base.:+` — confirmed via CST exploration: `rhs_getfield` here is a
        # quotenode wrapping an OPERATOR node, not an identifier).
        nm = _symbol_name(CSTParser.unquotenode(CSTParser.rhs_getfield(x)))
        nm === nothing && return String[]
        pushfirst!(parts, nm)
        x = x.args[1]
    end
    lhs_name = _item_name(x)
    lhs_name === nothing && return String[]
    pushfirst!(parts, lhs_name)
    return parts[1:end - 1]
end

"""
    _item_qualifier(name_expr)

The qualifier of a defined name: `String[]` for a local binding, or the
leading module-path components for a qualified method extension (`Base.foo`
→ `["Base"]`, `Base.Iterators.bar` → `["Base", "Iterators"]`). `name_expr` is
`CSTParser.get_name(x)`'s return value — `get_name` already resolves through a
getfield chain down to the final identifier and discards the qualifier
(mirrors `name_is_getfield`'s check of the same shape, bindings.jl:473); this
climbs back up from that identifier via its parent pointers (set because
inventory parsing always calls `CSTParser.parse(src, true)`, confirmed via CST
exploration — see the task report) to recover it.
"""
function _item_qualifier(name_expr)
    name_expr === nothing && return String[]
    p1 = CSTParser.parentof(name_expr)
    p1 === nothing && return String[]
    p2 = CSTParser.parentof(p1)
    (p2 isa CSTParser.EXPR && CSTParser.is_getfield_w_quotenode(p2)) || return String[]
    return _getfield_qualifier(p2)
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

# `includet` (Revise-style hot-reload include) is in the include closure
# exactly like `include` — `derived_file_include_records`/
# `_walk_include_calls` (StaticLint/includes.jl:62) already records it, so the
# inventory must recognize the same call name.
_is_include_call(x) = CSTParser.iscall(x) &&
    (CSTParser.fcall_name(x) == "include" || CSTParser.fcall_name(x) == "includet") &&
    length(x.args) == 2

# Find the resolved target of an include/includet call known to sit inside
# `[lo, hi)` (an enclosing top-level statement's byte range). Matching by
# span-containment against the already-computed include records — rather than
# by replicating CSTParser's trivia arithmetic to compute the rhs's exact
# offset — is the simpler-but-correct option Finding 6b calls for: a top-level
# statement's rhs contains at most one include call, so containment is
# unambiguous.
function _wrapped_include_target(records, lo, hi)
    for (off, _, target) in records
        lo <= off < hi && return target
    end
    return nothing
end

# Collect every bound name from a tuple-destructuring lhs (`a, b = ...`, or a
# nested/splatted/property/typed variant of it), mirroring StaticLint's
# `mark_binding!` recursion (bindings.jl:131-151) restricted to the shapes a
# destructuring lhs can actually take: `:tuple`/`:parameters` nodes recurse
# into their children (a nested tuple `(y, z)` and a property-destructuring
# `(; f1, f2)`'s `:parameters` child are both `:tuple`/`:parameters`-headed,
# confirmed via CST exploration — neither wraps in `:brackets`); a
# `(...)`-bracketed sub-tuple (`((x, y)) = w`) unwraps via `rem_invis`; a
# splat (`b...`) unwraps to its wrapped name via `x.args[1]`, exactly like
# `mark_binding!`'s own `issplat` arm; a `::`-typed name (`b::T` in
# `(; a, b::T) = cfg`, or `a::T` in `(a::T, b) = w`) unwraps via `rem_decl`
# to its lhs (an identifier, or — for the rarer `(a, b)::T` shape — a tuple
# that recurses again), mirroring `mark_binding!`'s terminal case, which
# binds via `get_name` (itself `rem_decl`-equivalent for a plain declared
# identifier). Anything else that isn't a plain identifier is silently
# skipped, same as `_item_name` elsewhere in this file.
function _destructure_names!(names::Vector{String}, x)
    if CSTParser.istuple(x) || CSTParser.isparameters(x)
        for child in something(x.args, CSTParser.EXPR[])
            _destructure_names!(names, child)
        end
    elseif CSTParser.isbracketed(x)
        _destructure_names!(names, CSTParser.rem_invis(x))
    elseif CSTParser.issplat(x)
        _destructure_names!(names, x.args[1])
    elseif CSTParser.isdeclaration(x)
        _destructure_names!(names, CSTParser.rem_decl(x))
    else
        name = _item_name(x)
        name === nothing || push!(names, name)
    end
    return names
end

# Whether `x` is a tuple-destructuring lhs, possibly wrapped in one or more
# interleaved layers of `:brackets` and/or a whole-tuple `::` type
# declaration: `((x, y)) = w` has an OUTER lhs headed `:brackets`, not
# `:tuple`; `(a, b)::T = w` has an OUTER lhs headed `::` (isdeclaration) —
# mark_binding!'s own `isdeclaration(x) && istuple(x.args[1])` case
# (bindings.jl:132); and the two nest either way (`((a, b))::T = w`: `::`
# wraps `:brackets` wraps `:tuple`) — all confirmed via CST exploration.
# `_destructure_names!` already unwraps both `:brackets` and `::` layers as
# part of its own recursion, but the classifier dispatch below needs to look
# past them too, or such a lhs never reaches the tuple-destructuring arm at
# all: it would fall through to the plain-identifier catch-all, which
# silently drops it (neither a `:brackets` nor a `::` node is an identifier).
function _is_tuple_destructure_lhs(x)
    while CSTParser.isbracketed(x) || CSTParser.isdeclaration(x)
        x = CSTParser.isbracketed(x) ? CSTParser.rem_invis(x) : CSTParser.rem_decl(x)
    end
    return CSTParser.istuple(x)
end

# Classify one assignment EXPR (bindings.jl:57-66's `isassignment` branches),
# emitting the appropriate `InventoryItem`. `kind_override` lets `:const`/
# `:global` wrappers reclassify the same shapes without duplicating this logic.
# `container_offset`/`container_fullspan` bound the enclosing top-level
# statement (the assignment itself for a direct `isassignment(x)` item, or the
# outer `:const`/`:global` node for a wrapped one) and, together with
# `records`, support detecting an assignment-wrapped include (`const DATA =
# include("data.jl")`, Finding 6b) regardless of which arm below fires.
function _classify_assignment!(acc, x, id, parent_module, kind_override, container_offset, container_fullspan, records)
    if CSTParser.is_func_call(x.args[1])
        # `_symbol_name`, not `_item_name`: a function-definition name may be
        # an operator (`+(a, b) = 1`, or the quoted-operator getfield form
        # `Base.:+(a, b) = 2` — `get_name` already resolves through the
        # getfield down to the bare OPERATOR node; confirmed via CST
        # exploration), which `_item_name` alone silently drops.
        name = _symbol_name(CSTParser.get_name(x))
        if name !== nothing
            qualifier = _item_qualifier(CSTParser.get_name(x))
            push!(acc.items, InventoryItem(id, name, qualifier, something(kind_override, :function), _render_sig(x), String[], parent_module))
        end
    elseif CSTParser.iscurly(x.args[1])
        # Typealias: `Vector{T} = ...` — name comes from the curly's base
        # identifier, mirroring `mark_typealias_bindings!` (bindings.jl:288-301).
        name = _item_name(CSTParser.get_name(x.args[1]))
        if name !== nothing
            push!(acc.items, InventoryItem(id, name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
        end
    elseif _is_tuple_destructure_lhs(x.args[1])
        # Tuple-destructuring lhs (`a, b = 1, 2`, splats, nested tuples, or
        # property destructuring `(; a, b) = cfg`; any of these `const`/
        # `global`-wrapped via `kind_override`): one item per bound identifier
        # (`_destructure_names!` mirrors `mark_binding!`'s recursion, ALL
        # sharing this statement's single walker `id` — deliberate, not a
        # bug. Ids are the position-map key and come only from the walker
        # (one per top-level statement), so minting extra ids here would
        # desync `derived_item_positions` from the walker's id sequence; the
        # shared id instead resolves (via the position map) to the whole
        # destructuring statement, which is exactly what a future goto-def
        # would want to target anyway.
        for name in _destructure_names!(String[], x.args[1])
            push!(acc.items, InventoryItem(id, name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
        end
    elseif !CSTParser.is_getfield(x.args[1])
        # Plain identifier lhs, possibly behind a `::` type declaration
        # (`x::Int = 1`) and/or brackets (`(x) = 1`) — `mark_binding!`
        # unwraps both, so the inventory must too (spec rule: no blinder
        # than `mark_bindings!`). A lhs that unwraps to anything other than
        # an identifier (e.g. a bracketed getfield) still emits nothing.
        lhs = x.args[1]
        while lhs isa CSTParser.EXPR && (CSTParser.isbracketed(lhs) || CSTParser.isdeclaration(lhs))
            lhs = CSTParser.isbracketed(lhs) ? CSTParser.rem_invis(lhs) : CSTParser.rem_decl(lhs)
        end
        name = _item_name(lhs)
        if name !== nothing
            push!(acc.items, InventoryItem(id, name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
        end
    end

    if _is_include_call(x.args[2])
        target = _wrapped_include_target(records, container_offset, container_offset + container_fullspan)
        push!(acc.includes, InventoryInclude(id, target, parent_module))
    end
    return
end

function _classify_item!(acc, x, id, parent_module, offset, include_targets_by_offset, include_records)
    if CSTParser.defines_module(x)
        # name/bare per bindings.jl:90-92 and scope.jl:172-181
        name = CSTParser.isidentifier(x.args[2]) ? StaticLint.valofid(x.args[2]) : nothing
        name === nothing && return
        push!(acc.modules, InventoryModule(id, name, CSTParser.headof(x.args[1]) === :FALSE, parent_module))
    elseif CSTParser.headof(x) === :function || CSTParser.headof(x) === :macro
        # bindings.jl:83-89. `_symbol_name`, not `_item_name`: covers
        # `function Base.:*(a, b) end`-style operator definitions, whose name
        # (after `get_name` resolves through the getfield) is an OPERATOR node.
        name = _symbol_name(CSTParser.get_name(x))
        name === nothing && return
        kind = CSTParser.headof(x) === :function ? :function : :macro
        if kind === :macro && !startswith(name, "@")
            # macros are named WITH the `@` prefix throughout the inventory
            # layers: `@foo` and `foo` can legitimately coexist in one scope,
            # and this matches both StaticLint's binding names and the
            # `export @foo` / `using X: @foo` spellings.
            name = "@" * name
        end
        qualifier = _item_qualifier(CSTParser.get_name(x))
        push!(acc.items, InventoryItem(id, name, qualifier, kind, _render_sig(x), String[], parent_module))
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
        push!(acc.items, InventoryItem(id, name, String[], kind, nothing, field_names, parent_module))
    elseif CSTParser.isassignment(x)
        # bindings.jl:57-66: function-call form → :function with signature;
        # curly lhs → :assignment (typealias); plain identifier lhs → :assignment
        _classify_assignment!(acc, x, id, parent_module, nothing, offset, x.fullspan, include_records)
    elseif CSTParser.headof(x) === :const || CSTParser.headof(x) === :global
        # unwrap and recurse into the inner assignment with kind override
        kind_override = CSTParser.headof(x) === :const ? :const : :global
        for inner in something(x.args, CSTParser.EXPR[])
            if CSTParser.isassignment(inner)
                _classify_assignment!(acc, inner, id, parent_module, kind_override, offset, x.fullspan, include_records)
            elseif CSTParser.isidentifier(inner)
                name = _item_name(inner)
                name === nothing || push!(acc.items, InventoryItem(id, name, String[], kind_override, nothing, String[], parent_module))
            elseif CSTParser.isdeclaration(inner) && CSTParser.isidentifier(inner.args[1])
                # `global x::T` (typed declaration, no assignment): the inner is a
                # `::` declaration node, not an identifier or assignment. Unwrap to
                # the declared name so it still enters the module's declared names —
                # mirrors the `:global`/`:local` typed-declaration handling in
                # `mark_bindings!` (bindings.jl). Without this, e.g. Revise's
                # module-wide `global juliadir::String` is invisible cross-file.
                name = _item_name(inner.args[1])
                name === nothing || push!(acc.items, InventoryItem(id, name, String[], kind_override, nothing, String[], parent_module))
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
    elseif _is_include_call(x)  # call named "include"/"includet" with one argument
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
                tname === nothing || push!(acc.items, InventoryItem(id, tname, String[], :enum, nothing, String[], parent_module))
                members = if length(margs) == 4 && CSTParser.headof(margs[4]) === :block
                    margs[4].args
                else
                    margs[4:end]
                end
                for member in something(members, CSTParser.EXPR[])
                    mname = _enum_item_name(member)
                    mname === nothing || push!(acc.items, InventoryItem(id, mname, String[], :enum_member, nothing, String[], parent_module))
                end
            end
        else
            # Only the isolated-scope macros (`_is_isolated_scope_macrocall`)
            # still reach this arm — the walker descends into every other
            # macrocall transparently, so their contents were classified as
            # ordinary items and no opaque row is emitted for them.
            mname = _macro_name_string(x.args[1])
            push!(acc.items, InventoryItem(id, something(mname, ""), String[], :opaque_macrocall, nothing, String[], parent_module))
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
