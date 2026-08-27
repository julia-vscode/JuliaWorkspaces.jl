# Layer 1 of the inventory architecture:
# a per-file, position-free, plain-data summary of top-level items. Values in
# this file are the firewall: they must contain only plain data (Symbols,
# Strings, Ints, vectors/structs of those) — never an EXPR reference, an
# objectid, a byte offset, or a docstring — so that body edits produce
# `isequal` inventories and Salsa's early-exit stops invalidation here.
# Position/EXPR reattachment lives exclusively in `derived_item_positions` and
# `derived_testitem_segments`.

"""
    MethodArity(minargs, maxargs, kws, kwsplat)

The argument-count shape of a callable: the positional count range
`minargs..maxargs` (`maxargs == typemax(Int)` for an unbounded `x...`/`Vararg`),
the accepted keyword names `kws`, and `kwsplat` (a `; kwargs...` accepts any
keyword). Produced by `StaticLint.func_nargs`/`struct_nargs` (via the splatting
constructor `MethodArity(func_nargs(x)...)`) and compared against a call's
`call_nargs` by `StaticLint.compare_f_call`. Plain data, so it backdates when
carried in the inventory for the cross-file argument-count check. Defined here
(the parent module) and imported into StaticLint, mirroring `ItemRef`.
"""
@auto_hash_equals struct MethodArity
    minargs::Int
    maxargs::Int
    kws::Vector{Symbol}
    kwsplat::Bool
end

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
`field_names` is populated for structs. `arity`, when non-`nothing`, is the
callable's `MethodArity` (argument-count shape) computed from the defining EXPR —
plain data (so it backdates), used by the cross-file argument-count check for
methods whose full set spans files.

`order` is dense and monotone in source order, and exists so the module tree can
recover Julia's textual-splice semantics; `id` identifies the declaring statement
and is what `ItemRef` carries. Both are minted by
[`_foreach_toplevel_item`](@ref).
"""
const MacroSpelling = @NamedTuple{qualifier::Vector{String}, name::String}

@auto_hash_equals struct InventoryItem
    order::Int
    id::Int64
    name::String
    qualifier::Vector{String}
    kind::Symbol
    signature::Union{Nothing,String}
    field_names::Vector{String}
    parent_module::Vector{String}
    arity::Union{Nothing,MethodArity}
    # Set only on `:macro_declared` rows: the macro that declares this name, as
    # written at the call site. Identity is confirmed later, in
    # layer_visibility.jl, which needs the spelling to know what to confirm.
    declared_by::Union{Nothing,MacroSpelling}
end

# Back-compat constructors: non-callable items (assignments, consts, enums, …)
# carry no arity, and only `:macro_declared` rows carry a spelling.
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, nothing, nothing)
InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity) =
    InventoryItem(order, id, name, qualifier, kind, signature, field_names, parent_module, arity, nothing)

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
    order::Int
    id::Int64
    kind::Symbol
    path::Vector{String}
    symbols::Vector{ImportSymbol}
    alias::Union{Nothing,String}
    parent_module::Vector{String}
end

"An `export` or `public` statement and the names it lists."
@auto_hash_equals struct InventoryExport
    order::Int
    id::Int64
    kind::Symbol
    names::Vector{String}
    parent_module::Vector{String}
end

"An `include(...)` call with its resolved target (or `nothing` if unresolvable)."
@auto_hash_equals struct InventoryInclude
    order::Int
    id::Int64
    target::Union{Nothing,URI}
    parent_module::Vector{String}
end

"""
A top-level macrocall whose effects the analyzer does not model (not in
`StaticLint.EFFECT_FREE_MACROS`/`HANDLED_MACROS`): its expansion may define
arbitrary names in `parent_module`, so bare missing-reference reporting there
is unreliable (`derived_module_has_opaque_macrocall`). The macrocall's
arguments are still walked transparently — visible definitions inside it stay
in `items`.
"""
@auto_hash_equals struct InventoryOpaqueMacro
    order::Int
    id::Int64
    parent_module::Vector{String}
end

"A `module`/`baremodule` declared in this file."
@auto_hash_equals struct InventoryModule
    order::Int
    id::Int64
    name::String
    bare::Bool
    parent_module::Vector{String}
end

"""
A `@testitem`/`@testmodule`/`@testsnippet` declared in this file.

TestItemRunner evaluates each of these bodies in a fresh module, so an
`include(...)` inside one splices into THAT module rather than the enclosing
one. The record opens a node in the module tree (`ModuleNode.kind ===
:testitem`) at `vcat(parent_module, [segment])`, and the body's items/includes/
imports are recorded with that extended `parent_module` — which is what makes
the ordinary splice machinery place an included helper's declarations where the
test item can see them.

A test item is NOT a module in any user-facing sense: it declares nothing in
its parent node, binds no name of its own, and is filtered out of workspace
symbols. `segment` is an opaque node key, not a name — see
`_mint_testitem_segment!` for why it is `#`-prefixed and how it stays
position-free.
"""
@auto_hash_equals struct InventoryTestItem
    order::Int
    id::Int64
    kind::Symbol                   # :testitem | :testmodule | :testsnippet
    label::String                  # the name as written; "" when malformed
    segment::String                # the module-tree node key for the body
    parent_module::Vector{String}  # file-relative path of the ENCLOSING module
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
    opaque_macros::Vector{InventoryOpaqueMacro}
    testitems::Vector{InventoryTestItem}
end

const EMPTY_FILE_INVENTORY = FileInventory(
    InventoryItem[], InventoryImport[], InventoryExport[], InventoryInclude[], InventoryModule[],
    InventoryOpaqueMacro[], InventoryTestItem[])

# Detect a doc-macro wrapper: a 4-arg :macrocall whose first arg is a doc-macro
# name (`StaticLint.is_doc_macro_name` — the implicit `globalrefdoc` or an
# explicit `@doc` / `Mod.@doc`). The wrapped item sits at args[4]. Mirrors
# layer_hover.jl's `_is_doc_expr` shape and layer_navigation.jl:105-109's offset
# handling.
function _doc_wrapped_item(x::CSTParser.EXPR)
    CSTParser.ismacrocall(x) || return nothing
    x.args !== nothing && length(x.args) == 4 || return nothing
    StaticLint.is_doc_macro_name(x.args[1]) || return nothing
    return x.args[4]
end

"""
    _foreach_toplevel_item(f, cst)

Call `f(x, order, id, parent_module, offset, testitem_segment)` for every
top-level item-like node of a `:file` CST in pre-order: the file's direct
children, plus — for `module`/`baremodule` declarations — the module node itself
and then the children of its body block (never the bodies of functions, structs,
etc.).

`testitem_segment` is `nothing` for every node except a testitem-family
macrocall (`@testitem`/`@testmodule`/`@testsnippet`) with a body block, where it
is the module-tree node key minted for that body; the body's own statements are
then walked with `parent_module` extended by it. See `InventoryTestItem`.

`order` is sequential in visit order and is what the module tree sorts on to
recover textual-splice semantics. `id` is the statement's identity, which is
what `ItemRef` carries; both are minted once per statement, so every record a
statement produces shares them (deliberately — see `_classify_assignment!`'s
tuple-destructure arm).

Doc-macro wrappers are transparent (the wrapped item is visited, with `offset`
pointing at it, not the docstring).
`if`/`elseif`/`else` and bare `begin...end` blocks are ALSO transparent (they
introduce no scope — StaticLint's `introduces_scope`, scope.jl:78-107, has no
arm for `:if`/`:block`, so definitions inside them bind at the enclosing
level): their statement lists are walked as if they were direct siblings of
the container, at the same `parent_module` and continuing the same order
sequence; the container node itself gets no order/id and is never passed to `f`.
Testitem-family macrocalls are descended into, but their statements land in a
`:testitem` node of their own rather than at the enclosing level — see
`_testitem_family_kind`. `@testset`/`@safetestset` stay opaque.
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
    _walk_toplevel!(f, cst.args, String[], 0, _ItemIdAllocator())
    return nothing
end

# An identity key for one top-level statement: coarse kind, the name as written
# (qualifier included), and the in-file module path. Statements sharing a key are
# separated by a disambiguator, so this only has to be a good HINT — a coarse or
# even wrong key costs id stability, never uniqueness. If every statement keyed
# the same, ids would degrade to dense positional numbering.
const _IdKey = Tuple{Symbol,String,String}

# An id is a 62-bit quantity, so every step that builds one is explicitly
# `Int64`/`UInt64` rather than `Int`: on a 32-bit platform `Int === Int32`, where
# `1 << 46` is undefined and the packed value would not fit. `hash` also returns
# `UInt32` there, so it is widened before masking — that costs collision
# resistance on 32-bit, which the assigned-id probe below absorbs.
const _ID_HASH_BITS = 46
const _ID_DIS_BITS = 16
const _ID_HASH_MASK = (UInt64(1) << _ID_HASH_BITS) - UInt64(1)
const _ID_DIS_MAX = Int64(1 << _ID_DIS_BITS) - Int64(1)

# Per-file id allocation state. `order` is the dense visit counter (a genuine
# machine `Int`); `buckets` counts earlier statements per identity key;
# `assigned` keeps ids unique within the file when a hash collides or a bucket
# overflows its 16 bits.
mutable struct _ItemIdAllocator
    order::Int
    buckets::Dict{_IdKey,Int}
    assigned::Set{Int64}
    testitem_counts::Dict{Tuple{Symbol,String},Int}
end
_ItemIdAllocator() = _ItemIdAllocator(0, Dict{_IdKey,Int}(), Set{Int64}(),
                                     Dict{Tuple{Symbol,String},Int}())

# Mint the `(order, id)` pair for one statement. Called exactly once per visited
# statement, so every record the classifier derives from it shares both.
function _mint_ids!(alloc::_ItemIdAllocator, x::CSTParser.EXPR, parent_module::Vector{String})
    alloc.order += 1

    key = _statement_id_key(x, parent_module)
    n = get(alloc.buckets, key, 0)
    alloc.buckets[key] = n + 1

    h = (hash(key) % UInt64) & _ID_HASH_MASK
    id = (Int64(h) << _ID_DIS_BITS) | min(Int64(n), _ID_DIS_MAX)
    while id in alloc.assigned
        id += Int64(1)
    end
    push!(alloc.assigned, id)

    return alloc.order, id
end

# Never throws: a malformed statement degrades to a coarse key rather than
# breaking inventory extraction (unlike `func_nargs`, this runs for every
# statement, including ones no classifier arm claims).
function _statement_id_key(x::CSTParser.EXPR, parent_module::Vector{String})::_IdKey
    return try
        (_id_kind_class(x), _id_dotted_name(x), join(parent_module, '.'))
    catch err
        err isa InterruptException && rethrow()
        (:unknown, "", join(parent_module, '.'))
    end
end

function _id_kind_class(x::CSTParser.EXPR)
    h = CSTParser.headof(x)
    CSTParser.defines_module(x) && return :module
    h === :function && return :function
    h === :macro && return :macro
    CSTParser.defines_datatype(x) && return :datatype
    h in (:const, :global, :export, :public, :using, :import) && return h
    _is_include_call(x) && return :include
    CSTParser.isassignment(x) && return :assignment
    CSTParser.ismacrocall(x) && return :macrocall
    return :other
end

# The name as written, qualifier included, so `Base.foo` and `foo` key apart.
# `""` when the statement binds no single name.
function _id_dotted_name(x::CSTParser.EXPR)
    h = CSTParser.headof(x)
    if CSTParser.defines_module(x)
        return CSTParser.isidentifier(x.args[2]) ? something(_item_name(x.args[2]), "") : ""
    elseif h === :const || h === :global
        for inner in something(x.args, CSTParser.EXPR[])
            inner isa CSTParser.EXPR && return _id_dotted_name(inner)
        end
        return ""
    elseif h in (:export, :public, :using, :import)
        # No single bound name; the statement's own text distinguishes it from a
        # sibling of the same kind. These have no bodies, so this is stable
        # against every edit except an edit to the statement itself.
        return _id_statement_text(x)
    end

    name = CSTParser.get_name(x)
    name isa CSTParser.EXPR || return ""
    base = _symbol_name(name)
    base === nothing && return ""
    qualifier = _item_qualifier(name)
    return isempty(qualifier) ? base : join(vcat(qualifier, base), '.')
end

_id_statement_text(x) = try
    string(CSTParser.to_codeobject(x))
catch err
    err isa InterruptException && rethrow()
    ""
end

function _walk_toplevel!(f, args, parent_module::Vector{String}, offset::Int, alloc::_ItemIdAllocator)
    args === nothing && return offset
    for a in args
        _walk_one!(f, a, parent_module, offset, alloc)
        offset += a.fullspan
    end
    return offset
end

function _walk_one!(f, a, parent_module::Vector{String}, offset::Int, alloc::_ItemIdAllocator)
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
    ti_kind = _testitem_family_kind(item)
    ti_body = ti_kind === nothing ? nothing : _testitem_body(item, item_offset)

    if CSTParser.headof(item) === :if && CSTParser.headof(item.trivia[1]) === :IF
        _walk_if_chain!(f, item, parent_module, item_offset, alloc)
    elseif CSTParser.headof(item) === :block
        _walk_transparent_block!(f, item, parent_module, item_offset, alloc)
    elseif ti_body !== nothing
        # A testitem-family body is a fresh module at runtime, so it gets its
        # own node and its statements are recorded under it. The macrocall
        # itself still produces the `:opaque_macrocall` usage row in the
        # ENCLOSING module (via `f` below, unchanged) — consumers filter on
        # that kind and must keep seeing it.
        order, id = _mint_ids!(alloc, item, parent_module)
        segment = _mint_testitem_segment!(alloc, ti_kind, _testitem_label(ti_kind, item))
        f(item, order, id, parent_module, item_offset, segment)

        body, body_offset = ti_body
        _walk_transparent_block!(f, body, vcat(parent_module, [segment]), body_offset, alloc)
    elseif CSTParser.ismacrocall(item) && !_is_enum_macro(item) && !_is_isolated_scope_macrocall(item)
        _walk_macrocall!(f, item, parent_module, item_offset, alloc)
    else
        order, id = _mint_ids!(alloc, item, parent_module)
        f(item, order, id, parent_module, item_offset, nothing)

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
                _walk_toplevel!(f, item.args[3].args, inner_parent, block_offset, alloc)
            end
        end
    end
    return nothing
end

# Macros whose bodies are ISOLATED from the enclosing module scope in the
# analysis — StaticLint's `is_scope_introducing_macrocall` (`@testitem`,
# `@testset`, `@safetestset`; scope.jl:144-154) plus the prebuilt-scope
# testsetup macros (`@testmodule`/`@testsnippet`; macros.jl matchers). Nothing
# declared inside them binds at the enclosing level, so the walker keeps the
# macrocall opaque (one `:opaque_macrocall` item, no descent). Every OTHER
# macrocall is walked transparently — matching StaticLint's traversal, which
# processes macro arguments in the enclosing scope.
#
# Qualified forms match STATICLINT'S OWN matchers exactly: `_macro_name_string`
# unwraps the `Module.@macro` getfield form the same way
# `is_scope_introducing_macrocall` (scope.jl) and `_is_testmodule_macro`/
# `_is_testsnippet_macro` (macros.jl) do, so all five names isolate whether
# bare or qualified.
function _is_isolated_scope_macrocall(x::CSTParser.EXPR)
    mname = _macro_name_string(x.args[1])
    return mname == "@testitem" || mname == "@testset" || mname == "@safetestset" ||
        mname == "@testmodule" || mname == "@testsnippet"
end

# The testitem-family subset of `_is_isolated_scope_macrocall`: the three macros
# whose body really is a fresh MODULE at runtime, so an `include` inside splices
# into that module. `_walk_one!` descends into these (into a `:testitem` node),
# while `@testset`/`@safetestset` stay opaque — see `InventoryTestItem` and the
# module-tree `:testitem` event.
#
# Delegates to StaticLint's own matchers rather than restating the names, so the
# two cannot drift and the qualified `TestItems.@testitem` form is recognised
# identically on both sides.
function _testitem_family_kind(x::CSTParser.EXPR)
    CSTParser.ismacrocall(x) || return nothing
    (x.args === nothing || isempty(x.args)) && return nothing
    name = x.args[1]
    name isa CSTParser.EXPR || return nothing
    StaticLint._is_testitem_macro(name) && return :testitem
    StaticLint._is_testmodule_macro(name) && return :testmodule
    StaticLint._is_testsnippet_macro(name) && return :testsnippet
    return nothing
end

# The test item's name as written: the string literal for `@testitem`, the
# identifier for `@testmodule`/`@testsnippet` (both name a setup, and
# `derived_test_setups_in_file` reads them the same way). `""` when the
# macrocall is malformed — the segment stays unique via the occurrence counter
# regardless.
function _testitem_label(kind::Symbol, x::CSTParser.EXPR)
    args = x.args
    (args === nothing || length(args) < 3) && return ""
    name_expr = args[3]
    name_expr isa CSTParser.EXPR || return ""
    if kind === :testmodule || kind === :testsnippet
        nm = _item_name(name_expr)
        return nm === nothing ? "" : nm
    end
    CSTParser.isstringliteral(name_expr) || return ""
    v = CSTParser.str_value(name_expr)
    return v isa AbstractString ? String(v) : ""
end

# The body block of a testitem-family macrocall, with its 0-based byte offset:
# the first `:block` argument. Offsets come from CSTParser's source-order child
# iteration (`for c in x`, which interleaves args and trivia), the same
# technique `_walk_macrocall!` uses — summing arg fullspans alone would drift
# for the call form `@testitem("n", begin … end)`, where paren/comma trivia sit
# between the args.
function _testitem_body(x::CSTParser.EXPR, offset::Int)
    args = x.args
    args === nothing && return nothing
    child_offset = offset
    for c in x
        if CSTParser.headof(c) === :block && any(j -> args[j] === c, 3:length(args))
            return (c, child_offset)
        end
        child_offset += c.fullspan
    end
    return nothing
end

# The module-tree node key for one test-item body.
#
# `"#" * kind * "#" * label * "#" * n`, where `n` is the 1-based occurrence
# index of that `(kind, label)` pair WITHIN THE FILE — test-item names repeat,
# so a counter is required.
#
# Two properties this scheme exists for:
#
#   * Position-free. The header's rule (no offsets in inventory values) is what
#     makes a body edit produce an `isequal` inventory and stop Salsa's
#     invalidation here; an offset-derived key would re-invalidate the whole
#     root's module tree on every keystroke. This is exactly as stable as
#     `_mint_ids!`'s bucket disambiguator, and keeping the LABEL in the key
#     (rather than a bare running counter) means inserting a test item shifts
#     only its same-labelled siblings instead of everything after it.
#   * Unwritable. The leading `#` makes the segment impossible to name in Julia
#     source, so no `using` can reach the node and `_classify_import`'s anchor
#     walk can never land on it. That is a safety guarantee only — the semantic
#     test for "this is a test item, not a module" is always
#     `ModuleNode.kind === :testitem`.
function _mint_testitem_segment!(alloc::_ItemIdAllocator, kind::Symbol, label::String)
    key = (kind, label)
    n = get(alloc.testitem_counts, key, 0) + 1
    alloc.testitem_counts[key] = n
    return string('#', kind, '#', label, '#', n)
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
function _walk_macrocall!(f, mc::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, alloc::_ItemIdAllocator)
    margs = mc.args
    (margs === nothing || length(margs) < 3) && return nothing

    # A macrocall whose effects the analyzer does not model may define names
    # its arguments never spell — record it (the classifier files it under
    # `opaque_macros`) BEFORE walking the arguments transparently, so visible
    # definitions inside still become ordinary items.
    if !StaticLint._macro_name_effects_known(_macro_name_string(margs[1]))
        order, id = _mint_ids!(alloc, mc, parent_module)
        f(mc, order, id, parent_module, offset, nothing)
    end

    child_offset = offset
    for c in mc
        if any(j -> margs[j] === c, 3:length(margs))
            _walk_one!(f, c, parent_module, child_offset, alloc)
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
function _walk_transparent_block!(f, block::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, alloc::_ItemIdAllocator)
    if block.trivia !== nothing && !isempty(block.trivia) && CSTParser.headof(block.trivia[1]) === :BEGIN
        offset += block.trivia[1].fullspan
    end
    _walk_toplevel!(f, block.args, parent_module, offset, alloc)
    return nothing
end

# Walks an `:if`/`:elseif` chain transparently. Node shape (confirmed via CST
# exploration): `trivia[1]` is the node's own `IF`/`ELSEIF` keyword; `args` is
# `[cond, then-block]` or `[cond, then-block, tail]`, where `tail` is either
# another `:elseif` node (continuing the chain — its own `ELSEIF` keyword is
# in ITS `trivia[1]`, not this node's) or a plain `:block` (a trailing `else`,
# whose `ELSE` keyword sits at this node's `trivia[2]`, right after the own
# keyword).
function _walk_if_chain!(f, node::CSTParser.EXPR, parent_module::Vector{String}, offset::Int, alloc::_ItemIdAllocator)
    offset += node.trivia[1].fullspan  # IF or ELSEIF keyword
    offset += node.args[1].fullspan    # condition
    _walk_transparent_block!(f, node.args[2], parent_module, offset, alloc)
    offset += node.args[2].fullspan

    if length(node.args) >= 3
        tail = node.args[3]
        if CSTParser.headof(tail) === :elseif
            _walk_if_chain!(f, tail, parent_module, offset, alloc)
        else
            offset += node.trivia[2].fullspan  # ELSE keyword
            _walk_transparent_block!(f, tail, parent_module, offset, alloc)
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
        offset => target for (offset, _, target, _) in include_records)

    acc = (items=InventoryItem[], imports=InventoryImport[], exports=InventoryExport[],
           includes=InventoryInclude[], modules=InventoryModule[], opaque_macros=InventoryOpaqueMacro[],
           testitems=InventoryTestItem[])
    _foreach_toplevel_item(cst) do x, order, id, parent_module, offset, testitem_segment
        pm = copy(parent_module)
        if testitem_segment !== nothing
            kind = _testitem_family_kind(x)
            kind === nothing || push!(acc.testitems, InventoryTestItem(
                order, id, kind, _testitem_label(kind, x), testitem_segment, pm))
        end
        _classify_item!(acc, x, order, id, pm, offset, include_targets_by_offset, include_records)
    end
    return FileInventory(acc.items, acc.imports, acc.exports, acc.includes, acc.modules,
                         acc.opaque_macros, acc.testitems)
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

# --- Modelled macros that declare names their argument never spells ---------
#
# A macrocall is transparent to the walker, so a macro that mints extra names
# leaves no trace of them anywhere. Each rule maps a macro to the names its
# FIRST argument implies. `derive` returns an empty vector when the argument is
# not the shape the macro requires — the only error path at this layer.
#
# `owner` is where the macro must come from. Nothing here checks that; it is the
# input to the confirmation step in layer_visibility.jl. Keeping both halves in
# one table is deliberate: the walker needs the names, confirmation needs the
# paths, and two tables would drift.
struct MacroDeclarationRule
    owner::Vector{String}
    macro_name::String
    derive::Function
end

# `@declare_input foo(rt, x::Int)::V` declares `foo`, `set_foo!`, `delete_foo!`
# (Salsa's declare_input_macro.jl builds the latter two by string interpolation).
function _declare_input_names(arg1::CSTParser.EXPR)
    CSTParser.isdeclaration(arg1) || return String[]
    (arg1.args !== nothing && length(arg1.args) >= 1) || return String[]
    CSTParser.iscall(arg1.args[1]) || return String[]
    n = _symbol_name(CSTParser.get_name(arg1.args[1]))
    return n === nothing ? String[] : [n, "set_$(n)!", "delete_$(n)!"]
end

# `@deprecate f(x::Int) g(x)` and `@deprecate old new` both declare the first
# argument's name. `get_name` unwraps a `where` and a getfield; `_symbol_name`
# additionally covers operator names.
function _deprecate_names(arg1::CSTParser.EXPR)
    n = _symbol_name(CSTParser.get_name(arg1))
    return n === nothing ? String[] : [n]
end

const MACRO_DECLARATION_RULES = MacroDeclarationRule[
    MacroDeclarationRule(["Salsa"], "@declare_input", _declare_input_names),
    MacroDeclarationRule(["Base"], "@deprecate", _deprecate_names),
]

function _macro_declaration_rule(macro_name::AbstractString)
    for r in MACRO_DECLARATION_RULES
        r.macro_name == macro_name && return r
    end
    return nothing
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
# Mirrors the structure of `StaticLint.is_doc_macro_name`, returning the name
# string instead of a boolean match.
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
# note. That firewall defers identity, it does not drop it: `MacroDeclarationRule`
# records an owner and has it confirmed in layer_visibility.jl
# (`_macro_owner_confirmed`), which is what rules out a local macro shadowing
# the name. `@enum` rows carry no spelling, so nothing confirms them and a
# shadowing `@enum` misclassifies — a known hole, not a constraint of this layer.
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
function _classify_assignment!(acc, x, order, id, parent_module, kind_override, container_offset, container_fullspan, records)
    if CSTParser.is_func_call(x.args[1])
        # `_symbol_name`, not `_item_name`: a function-definition name may be
        # an operator (`+(a, b) = 1`, or the quoted-operator getfield form
        # `Base.:+(a, b) = 2` — `get_name` already resolves through the
        # getfield down to the bare OPERATOR node; confirmed via CST
        # exploration), which `_item_name` alone silently drops.
        name = _symbol_name(CSTParser.get_name(x))
        if name !== nothing
            qualifier = _item_qualifier(CSTParser.get_name(x))
            push!(acc.items, InventoryItem(order, id,name, qualifier, something(kind_override, :function), _render_sig(x), String[], parent_module, (StaticLint._is_real_method(x) ? MethodArity(StaticLint.func_nargs(x)...) : nothing)))
        end
    elseif CSTParser.iscurly(x.args[1])
        # Typealias: `Vector{T} = ...` — name comes from the curly's base
        # identifier, mirroring `mark_typealias_bindings!` (bindings.jl:288-301).
        name = _item_name(CSTParser.get_name(x.args[1]))
        if name !== nothing
            push!(acc.items, InventoryItem(order, id,name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
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
            push!(acc.items, InventoryItem(order, id,name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
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
            push!(acc.items, InventoryItem(order, id,name, String[], something(kind_override, :assignment), nothing, String[], parent_module))
        end
    end

    if _is_include_call(x.args[2])
        target = _wrapped_include_target(records, container_offset, container_offset + container_fullspan)
        push!(acc.includes, InventoryInclude(order, id,target, parent_module))
    end
    return
end

# Names a modelled macro declares that its argument never spells. The walker is
# transparent through a macrocall, but CSTParser keeps parent links, so a
# statement can still tell that it is the macrocall's FIRST argument — `args[3]`,
# since `args[1]` is the macro name and `args[2]` a zero-span placeholder. Rows
# carry that argument's own id, so every name from one macrocall shares it (the
# shape `@enum` members already use).
#
# Matching is by bare macro name only: nothing here judges which module the macro
# came from, and nothing here reads the environment.
function _emit_macro_declarations!(acc, x, order, id, parent_module)
    p = CSTParser.parentof(x)
    (p isa CSTParser.EXPR && CSTParser.ismacrocall(p)) || return
    (p.args !== nothing && length(p.args) >= 3 && p.args[3] === x) || return
    mname = _macro_name_string(p.args[1])
    mname === nothing && return
    rule = _macro_declaration_rule(mname)
    rule === nothing && return

    spelling = (qualifier=_getfield_qualifier(p.args[1]), name=mname)
    for n in rule.derive(x)
        push!(acc.items, InventoryItem(order, id, n, String[], :macro_declared,
            nothing, String[], parent_module, nothing, spelling))
    end
    return
end

function _classify_item!(acc, x, order, id, parent_module, offset, include_targets_by_offset, include_records)
    _emit_macro_declarations!(acc, x, order, id, parent_module)
    if CSTParser.defines_module(x)
        # name/bare per bindings.jl:90-92 and scope.jl:172-181
        name = CSTParser.isidentifier(x.args[2]) ? StaticLint.valofid(x.args[2]) : nothing
        name === nothing && return
        push!(acc.modules, InventoryModule(order, id, name, CSTParser.headof(x.args[1]) === :FALSE, parent_module))
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
        push!(acc.items, InventoryItem(order, id,name, qualifier, kind, _render_sig(x), String[], parent_module, (StaticLint._is_real_method(x) ? MethodArity(StaticLint.func_nargs(x)...) : nothing)))
    elseif CSTParser.defines_datatype(x)
        # bindings.jl:96-115
        name = _item_name(CSTParser.get_name(x))
        name === nothing && return
        if CSTParser.defines_struct(x)
            kind = CSTParser.defines_mutable(x) ? :mutable_struct : :struct
            field_names = String[]
            for arg in x.args[3].args
                CSTParser.defines_function(arg) && continue
                # A field modifier wraps the declaration in a macrocall whose LAST
                # argument is the field (`@atomic a::Int = 1`). Unwrapping is
                # name-free on purpose: any such macro leaves a field behind, and a
                # shape that isn't a field declaration yields no name anyway. Without
                # this the field is missing from `field_names` entirely, and so from
                # every consumer of it (completion, hover, field-access checking).
                if CSTParser.ismacrocall(arg) && arg.args !== nothing && length(arg.args) > 1
                    arg = last(arg.args)
                end
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
        arity = CSTParser.defines_struct(x) ? MethodArity(StaticLint.struct_nargs(x)...) : nothing
        push!(acc.items, InventoryItem(order, id,name, String[], kind, nothing, field_names, parent_module, arity))
    elseif CSTParser.isassignment(x)
        # bindings.jl:57-66: function-call form → :function with signature;
        # curly lhs → :assignment (typealias); plain identifier lhs → :assignment
        _classify_assignment!(acc, x, order, id, parent_module, nothing, offset, x.fullspan, include_records)
    elseif CSTParser.headof(x) === :const || CSTParser.headof(x) === :global
        # unwrap and recurse into the inner assignment with kind override
        kind_override = CSTParser.headof(x) === :const ? :const : :global
        for inner in something(x.args, CSTParser.EXPR[])
            if CSTParser.isassignment(inner)
                _classify_assignment!(acc, inner, order, id, parent_module, kind_override, offset, x.fullspan, include_records)
            elseif CSTParser.isidentifier(inner)
                name = _item_name(inner)
                name === nothing || push!(acc.items, InventoryItem(order, id,name, String[], kind_override, nothing, String[], parent_module))
            elseif CSTParser.isdeclaration(inner) && CSTParser.isidentifier(inner.args[1])
                # `global x::T` (typed declaration, no assignment): the inner is a
                # `::` declaration node, not an identifier or assignment. Unwrap to
                # the declared name so it still enters the module's declared names —
                # mirrors the `:global`/`:local` typed-declaration handling in
                # `mark_bindings!` (bindings.jl). Without this, e.g. Revise's
                # module-wide `global juliadir::String` is invisible cross-file.
                name = _item_name(inner.args[1])
                name === nothing || push!(acc.items, InventoryItem(order, id,name, String[], kind_override, nothing, String[], parent_module))
            end
        end
    elseif CSTParser.headof(x) === :export || CSTParser.headof(x) === :public
        names = String[]
        for a in x.args
            nm = _symbol_name(a)
            nm === nothing || push!(names, nm)
        end
        isempty(names) || push!(acc.exports, InventoryExport(order, id, CSTParser.headof(x) === :export ? :export : :public, names, parent_module))
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
                isempty(path) || push!(acc.imports, InventoryImport(order, id, kind, path,symbols, alias, parent_module))
            end
        else
            # Non-colon form: each top-level arg (`using A, B`) is its own target.
            for block in something(args, CSTParser.EXPR[])
                path, alias = _walk_import_block(block)
                isempty(path) || push!(acc.imports, InventoryImport(order, id, kind, path,ImportSymbol[], alias, parent_module))
            end
        end
    elseif _is_include_call(x)  # call named "include"/"includet" with one argument
        push!(acc.includes, InventoryInclude(order, id,get(include_targets_by_offset, offset, nothing), parent_module))
    elseif CSTParser.ismacrocall(x)
        if _is_enum_macro(x)   # per macros.jl:55-67: name via _points_to_Base_macro-style check on x.args[1]
            # x.args[3] is always the enum type name (args[1]=macro name,
            # args[2]=the macrocall's parameters placeholder, always `nothing`
            # for `@enum`'s bare/space-separated call syntax); args[4:end] (or
            # args[4].args when args[4] is a `begin...end` block) are members.
            margs = x.args
            if margs !== nothing && length(margs) >= 3
                tname = _enum_item_name(margs[3])
                tname === nothing || push!(acc.items, InventoryItem(order, id,tname, String[], :enum, nothing, String[], parent_module))
                members = if length(margs) == 4 && CSTParser.headof(margs[4]) === :block
                    margs[4].args
                else
                    margs[4:end]
                end
                for member in something(members, CSTParser.EXPR[])
                    mname = _enum_item_name(member)
                    mname === nothing || push!(acc.items, InventoryItem(order, id,mname, String[], :enum_member, nothing, String[], parent_module))
                end
            end
        elseif _is_isolated_scope_macrocall(x)
            mname = _macro_name_string(x.args[1])
            push!(acc.items, InventoryItem(order, id,something(mname, ""), String[], :opaque_macrocall, nothing, String[], parent_module))
        else
            # A transparently-walked macrocall reaches this arm only when
            # `_walk_macrocall!` recorded it as effect-unknown: its expansion
            # may define names its arguments never spell, so file it for
            # `derived_module_has_opaque_macrocall` (its argument contents
            # were classified as ordinary items separately).
            push!(acc.opaque_macros, InventoryOpaqueMacro(order, id, parent_module))
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
    result = Dict{Int64,@NamedTuple{expr::CSTParser.EXPR, offset::Int}}()

    derived_has_content(rt, uri) || return result
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return result

    _foreach_toplevel_item(cst) do x, _order, id, parent_module, offset, _segment
        result[id] = (expr=x, offset=offset)
    end
    return result
end

"""
    derived_testitem_segments(rt, uri) -> Dict{UInt64,String}

Map the `objectid` of each testitem-family macrocall EXPR to the module-tree
segment `derived_file_inventory` recorded for its body.

Volatile and objectid-keyed — the objectids are only valid for the CST instance
they were built from — so it is deliberately kept OUT of `FileInventory`, which
must stay position- and identity-free for the cutoff contract. Same shape and
same lifetime caveat as `derived_include_dict`/`derived_computed_include_ids`,
and consumed the same way: from inside the semantic pass, which is traversing
that exact CST. This is how `_handle_testitem` learns the segment the inventory
walker minted, instead of re-deriving it (and drifting: StaticLint traverses
everything, the inventory walker only top-level-ish statements).
"""
Salsa.@derived function derived_testitem_segments(rt, uri)
    @debug "derived_testitem_segments" uri=uri

    result = Dict{UInt64,String}()

    derived_has_content(rt, uri) || return result
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return result

    _foreach_toplevel_item(cst) do x, _order, _id, _parent_module, _offset, segment
        segment === nothing || (result[UInt64(objectid(x))] = segment)
    end
    return result
end
