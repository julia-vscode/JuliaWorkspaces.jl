# Layer 1 of the v2 stack: the item walker, the per-file skeleton, the body
# forest, and the volatile address→range maps — all produced by ONE traversal of
# ONE parse.
#
# This file is the v2 analogue of layer_inventory.jl, and the reason the v2 stack
# can be CSTParser-free: it is the single source of truth for v2 item identity.
#
# Three products, three different invalidation behaviours, which is why they are
# split into separate Salsa queries over one shared walk:
#
#   skeleton  the file's API shape — orders, ids, module paths, imports, exports,
#             includes. Contains NO item bodies, so an edit inside any function
#             leaves it `isequal` and Salsa's early-exit stops there.
#   bodies    per-item `BodyTree`s. Position-free, so each item backdates
#             individually through `derived_v2_item_body`.
#   maps      address→byte-range, per item. VOLATILE: recomputes on every
#             reparse. Depending on it from an analysis-layer computation is a
#             bug — only last-mile position reattachment may read it.
#
# Because the walker yields the syntax node itself, tree and map come from the
# same nodes as the id. There is no cross-parser byte matching anywhere in v2.

# ── identity ────────────────────────────────────────────────────────────────

"""
    V2ItemRef(file, id)

A handle on one top-level item of the v2 pipeline.

Structurally identical to [`ItemRef`](@ref) but a DISTINCT TYPE on purpose: v1
and v2 mint ids from different walkers over different parsers, so the two id
spaces do not agree and never will. A distinct type turns a mix-up into a method
error instead of a silent lookup miss, and gives Salsa distinct cache keys. It
collapses back into `ItemRef` when v1 is retired.
"""
@auto_hash_equals struct V2ItemRef
    file::URI
    id::Int64
end

# ── skeleton records (body-free) ────────────────────────────────────────────

"""
    V2ItemRow

One classifiable top-level statement. `kind` here is the COARSE head kind, and
is deliberately body-independent (`:struct` covers both mutabilities, `:function`
only the long form) so that the skeleton stays insensitive to body edits and the
id key stays stable. The refined kind lives in [`V2Decl`](@ref), one Salsa hop
away in `derived_v2_item_classification`.

`interpretable` is `false` when the statement sits under a macrocall whose
argument merely LOOKS like a definition (see `DEFINITION_SHAPED_DSL_MACROS`);
such items are still enumerated, but the lowering layer declines to analyse them.
"""
@auto_hash_equals struct V2ItemRow
    order::Int
    id::Int64
    kind::Symbol
    parent_module::Vector{String}
    interpretable::Bool
    # True when the item was enumerated from INSIDE a macrocall's arguments
    # (`@derived function f() … end`, `@kwdef struct …`): the macro may
    # transform it, so lowering the bare form can raise errors that are false
    # for the real program. Binding analysis stays best-effort for such items;
    # lowering-ERROR findings are suppressed.
    under_macrocall::Bool
    # True when the item sits inside an `if`/`elseif`/`else` branch (the walk
    # is transparent through them, `@static if` included): only ONE branch
    # runs, so declaration-conflict rules must not pair declarations across —
    # or with — branches (v1's `in_same_if_branch` exemption, conservatively
    # widened to "any conditional declaration").
    conditional::Bool
end

"A `module`/`baremodule` declared in this file."
@auto_hash_equals struct V2Module
    order::Int
    id::Int64
    name::String
    bare::Bool
    parent_module::Vector{String}
end

"""
    V2ImportSymbol

An explicit symbol in a `using`/`import` colon-form list (`using X: a as b`).
`name` is always the SOURCE name, never the bound one; `alias` is the bound name
when the symbol is `as`-renamed, `nothing` otherwise.

v2's own type rather than v1's identically-shaped `ImportSymbol`: that one lives
in `layer_inventory.jl`, which is precisely the file this layer replaces, so
borrowing it would make v2 stop compiling the day v1 is deleted.
"""
const V2ImportSymbol = @NamedTuple{name::String, alias::Union{Nothing,String}}

"""
    V2Import

A `using`/`import` statement. `path` is the module path with leading `"."`
entries encoding relative levels (`using ..Sibling` → `[".", ".", "Sibling"]`);
`symbols` is the explicit list of `using X: a, b` (empty for whole-module
imports); `alias` is the `as` name if present.
"""
@auto_hash_equals struct V2Import
    order::Int
    id::Int64
    kind::Symbol
    path::Vector{String}
    symbols::Vector{V2ImportSymbol}
    alias::Union{Nothing,String}
    parent_module::Vector{String}
end

"An `export` or `public` statement and the names it lists."
@auto_hash_equals struct V2Export
    order::Int
    id::Int64
    kind::Symbol
    names::Vector{String}
    parent_module::Vector{String}
end

"""
    V2Include

An `include(...)` call. `path` is the LITERAL string argument, or `nothing` when
the argument is computed — resolution to a `URI` is the module tree's job
(`derived_v2_include_target`), because it needs the including file's directory.
"""
@auto_hash_equals struct V2Include
    order::Int
    id::Int64
    path::Union{Nothing,String}
    parent_module::Vector{String}
end

"""
A top-level macrocall whose effects the analyzer does not model: its expansion
may define arbitrary names in `parent_module`, so bare missing-reference
reporting there is unreliable. The macrocall's arguments are still walked
transparently, so visible definitions inside it stay in `items`.
"""
@auto_hash_equals struct V2OpaqueMacro
    order::Int
    id::Int64
    parent_module::Vector{String}
end

"""
    V2TestItem

One `@testitem`/`@testmodule`/`@testsnippet`, as the walker sees it (design doc
§13.4). Position-free BY OMISSION: no ranges and no `code` string, so the record
backdates on any edit that does not change the label, an option, or the item
set. Ranges and the code slice are reattached from `derived_v2_file_maps` at the
emission join (`derived_v2_testitem_details`), the same last-mile split the lint
findings use.

`id` is the walker's item id — the one id authority — so "did this test's body
change?" is `derived_v2_item_body_hash` on the same ref.

`option_skip` deviates from a literal port of `TestItemDetection`: a non-literal
skip expression is `nothing` here rather than a source range, because its source
text can only come from file text + map, which is the join's job.
"""
@auto_hash_equals struct V2TestItem
    order::Int
    id::Int64
    kind::Symbol                 # :testitem | :testsetup_module | :testsetup_snippet
    label::String
    parent_module::Vector{String}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
    option_skip::Union{Bool,Nothing}   # nothing ⇒ non-literal skip expr; the JOIN slices its text
end

"""
    V2TestError

A malformed test macro. The message is a position-free fact about the
macrocall's shape (the exact strings `TestItemDetection` emits); the range it is
reported at is always the whole macrocall, reattached in the join.
"""
@auto_hash_equals struct V2TestError
    order::Int
    id::Int64
    name::String                 # the label when it parsed, else "Test definition error"
    message::String
end

"""
    V2FileSkeleton

The body-free API shape of one file. Structural equality is the early-cutoff
contract: two skeletons are equal iff the file's top-level API is identical,
regardless of body edits, whitespace, comments, or docstrings.
"""
@auto_hash_equals struct V2FileSkeleton
    items::Vector{V2ItemRow}
    imports::Vector{V2Import}
    exports::Vector{V2Export}
    includes::Vector{V2Include}
    modules::Vector{V2Module}
    opaque_macros::Vector{V2OpaqueMacro}
    testitems::Vector{V2TestItem}
    testerrors::Vector{V2TestError}
end

const EMPTY_V2_SKELETON = V2FileSkeleton(
    V2ItemRow[], V2Import[], V2Export[], V2Include[], V2Module[], V2OpaqueMacro[],
    V2TestItem[], V2TestError[])

# ── classification records (derived from an item's BodyTree) ────────────────

"""
    V2Decl

One name declared by an item, with the REFINED kind. A single statement can
declare several (`a, b = 1, 2`; `@enum Color red green`), which is why
classification returns a vector.
"""
@auto_hash_equals struct V2Decl
    name::String
    qualifier::Vector{String}
    kind::Symbol
    field_names::Vector{String}
end

"The v1-shaped join of a skeleton row with one of its declarations."
@auto_hash_equals struct V2InventoryItem
    order::Int
    id::Int64
    name::String
    qualifier::Vector{String}
    kind::Symbol
    field_names::Vector{String}
    parent_module::Vector{String}
end

"The complete v2 inventory of one file: classified items plus the skeleton's other rows."
@auto_hash_equals struct V2FileInventory
    items::Vector{V2InventoryItem}
    imports::Vector{V2Import}
    exports::Vector{V2Export}
    includes::Vector{V2Include}
    modules::Vector{V2Module}
    opaque_macros::Vector{V2OpaqueMacro}
end

const EMPTY_V2_FILE_INVENTORY = V2FileInventory(
    V2InventoryItem[], V2Import[], V2Export[], V2Include[], V2Module[], V2OpaqueMacro[])

# ── body tree construction ──────────────────────────────────────────────────

_range_v2(st) = _to_exclusive_end(JS2.byte_range(st))

# `parseall(SyntaxTree, …)` builds an EST (Expr-shaped tree), and EST macrocalls
# carry an Expr-style `LineNumberNode` — file name AND line — as their second
# child's value:
#
#   @inline k(w) = 4  ->  (macrocall (Identifier "@inline")
#                                    (Value :(#= t.jl:1 =#))
#                                    (= …))
#
# Stored verbatim that is a POSITION inside a value whose whole contract is to be
# position-free: it lands in `BodyTree.hash`, so the item stops backdating on any
# line shift and its hash depends on the file's name. Measured over this package,
# 130 of 330 items (39%) contain one — every item with a macrocall anywhere in it,
# including `@assert` inside a function body and every `@testitem`/`@testset`.
#
# The type is preserved (not erased to `nothing`) so `_materialize` still rebuilds
# a `LineNumberNode`-shaped value and JuliaLowering sees the shape it expects.
const BODY_LINENUMBER = LineNumberNode(0, :body)

_normalize_v2_value(@nospecialize(v)) = v isa LineNumberNode ? BODY_LINENUMBER : v

"""
    _build_body_tree_v2!(ranges, st) -> BodyTree{V2Kind}

Preorder walk producing the tree and, when `ranges !== nothing`, its address map.
One implementation for both guarantees that preorder addresses line up with the
tree: entry `i` is the byte range of the node at address `i` (root = 1).
"""
function _build_body_tree_v2!(ranges::Union{Nothing,Vector{UnitRange{Int}}}, st)
    ranges !== nothing && push!(ranges, _range_v2(st))
    k = JS2.kind(st)
    if JS2.is_leaf(st)
        return BodyTree(k, _normalize_v2_value(st.value), nothing)
    else
        cs = Vector{BodyTree{V2Kind}}()
        for c in JS2.children(st)
            push!(cs, _build_body_tree_v2!(ranges, c))
        end
        # Interior nodes keep their `value` too, so materialization is faithful.
        return BodyTree(k, _normalize_v2_value(st.value), cs)
    end
end

# ── small tree accessors ────────────────────────────────────────────────────

_v2_children(bt::BodyTree) = bt.children === nothing ? BodyTree{V2Kind}[] : bt.children
_v2_nchildren(bt::BodyTree) = bt.children === nothing ? 0 : length(bt.children)

"The `String` value of a leaf SYNTAX node (not a `BodyTree`), else `nothing`."
function _v2_node_string(st)
    v = st.value
    v isa AbstractString && return String(v)
    v isa Symbol && return String(v)
    return nothing
end

"The `String` value of an identifier-ish leaf, else `nothing`. EST identifiers are `String`s."
function _v2_leaf_string(bt::BodyTree)
    bt.children === nothing || return nothing
    v = bt.val
    v isa AbstractString && return String(v)
    v isa Symbol && return String(v)
    return nothing
end

# `Base.foo` parses as `(. (Identifier Base) (inert (Identifier foo)))`, and
# `Base.Iterators.bar` nests that on the left. Returns `(qualifier, name)`, with
# an empty qualifier for a plain identifier.
function _v2_qualified_name(bt::BodyTree)
    if bt.kind == JS2.K"."
        cs = _v2_children(bt)
        length(cs) == 2 || return (String[], nothing)
        q, n = _v2_qualified_name(cs[1])
        n === nothing && return (String[], nothing)
        tail = cs[2]
        # The rhs of a getfield is quoted: `(inert (Identifier foo))`.
        if tail.kind == JS2.K"inert" && _v2_nchildren(tail) >= 1
            tail = _v2_children(tail)[1]
        end
        t = _v2_leaf_string(tail)
        t === nothing && return (String[], nothing)
        return (push!(copy(q), n), t)
    end
    return (String[], _v2_leaf_string(bt))
end

# Strip the wrappers that sit between a definition and the name it binds:
# `where`, return-type `::`, `<:`, `curly`, and the call signature itself.
function _v2_unwrap_to_name(bt::BodyTree)
    node = bt
    while true
        k = node.kind
        if (k == JS2.K"where" || k == JS2.K"::" || k == JS2.K"<:" ||
            k == JS2.K"curly" || k == JS2.K"call") && _v2_nchildren(node) >= 1
            node = _v2_children(node)[1]
        else
            return node
        end
    end
end

# An import path node: `(. A B)` for `A.B`, `(. "." "." Sib)` for `..Sib`.
# Relative levels arrive as literal "." identifiers, matching v1's encoding.
function _v2_import_path(bt::BodyTree)
    bt.kind == JS2.K"." || return String[]
    out = String[]
    for c in _v2_children(bt)
        s = _v2_leaf_string(c)
        s === nothing && return String[]
        push!(out, s)
    end
    return out
end

# ── macro helpers ───────────────────────────────────────────────────────────

# EST macrocall children: [1] the macro name, [2] a LineNumberNode `Value`,
# [3:] the arguments. The name may be qualified (`Base.@propagate_inbounds`), in
# which case the trailing leaf carries it.
function _v2_macro_name(bt::BodyTree)
    node = bt
    while node.children !== nothing && !isempty(node.children)
        node = node.children[end]
    end
    if node.kind == JS2.K"inert" && _v2_nchildren(node) >= 1
        node = _v2_children(node)[1]
    end
    return _v2_leaf_string(node)
end

_v2_macrocall_name(bt::BodyTree) =
    _v2_nchildren(bt) >= 1 ? _v2_macro_name(_v2_children(bt)[1]) : nothing

# The same descent over a raw syntax node, so the walker can read a macro's name
# without building a `BodyTree` for the name subtree first.
function _v2_node_macro_name(st)
    node = st
    while !JS2.is_leaf(node)
        cs = JS2.children(node)
        (cs === nothing || isempty(cs)) && return nothing
        node = cs[end]
    end
    return _v2_node_string(node)
end

"The macrocall's actual arguments (children 3 onwards)."
_v2_macro_args(bt::BodyTree) =
    _v2_nchildren(bt) >= 3 ? _v2_children(bt)[3:end] : BodyTree{V2Kind}[]

# Macros whose bodies are ISOLATED from the enclosing module scope: nothing
# declared inside them binds at the enclosing level, so the walker keeps the
# macrocall opaque (one item, no descent). Mirrors v1's
# `_is_isolated_scope_macrocall`. Every OTHER macrocall is walked transparently,
# matching the traversal that consumes the inventory.
const V2_ISOLATED_SCOPE_MACROS = Set([
    "@testitem", "@testset", "@safetestset", "@testmodule", "@testsnippet",
])

# Macros whose argument merely LOOKS like a definition. `@define_diffrule
# Base.:+(x) = :(1)` is a rule-table entry, not a method: `x` is pattern syntax
# and cannot be removed, so analysing it as a signature invents findings.
#
# Deliberately a blocklist, not "everything we cannot expand". The broad rule was
# measured on the corpus and cost far more than it saved: it also suppressed
# definitions under `@static if …` and — worst — under `Core.@doc`, i.e. every
# docstring'd definition, adding ~353 false negatives to remove ~13 false
# positives. Add names here only with sweep evidence.
const DEFINITION_SHAPED_DSL_MACROS = Set([
    "@define_diffrule", "@with_kw", "@with_kw_noshow", "@attributes",
])

_v2_is_doc_macro(name) = name == "@doc"

# ── test macro scanning ─────────────────────────────────────────────────────

# The label of `@testitem "…"`. A plain literal is a `String` LEAF in the EST
# (no wrapper node); an interpolated label is a lowercase `string` node whose
# first chunk carries the name — the same "first child's value" rule
# `TestItemDetection` applies (`node[2][1].val`), including its stringified
# `nothing` when the first chunk is not a literal.
_v2_is_string_label(bt::BodyTree) = bt.kind == JS2.K"String" || bt.kind == JS2.K"string"

function _v2_string_label(bt::BodyTree)
    bt.kind == JS2.K"String" && return something(_v2_leaf_string(bt), "nothing")
    cs = _v2_children(bt)
    isempty(cs) && return "nothing"
    return something(_v2_leaf_string(cs[1]), "nothing")
end

"""
    _v2_scan_test_macro!(skel, bt, name, order, id, pm)

`TestItemDetection.find_test_detail!`'s per-macrocall argument checks, ported
onto the position-free `BodyTree` (same shapes accepted, same error strings).
Pushes exactly one `V2TestItem` or one `V2TestError` for the macrocall.

Everything here is a fact about the macrocall's SHAPE: ranges and the `code`
slice are reattached from the address map at the emission join. This looks
inside an isolated-scope macrocall, but enumeration is untouched — nothing in
the body binds outward, exactly as before.
"""
function _v2_scan_test_macro!(skel::V2FileSkeleton, bt::BodyTree, name::String,
                              order::Int, id::Int64, pm::Vector{String})
    args = _v2_macro_args(bt)
    err(n, msg) = (push!(skel.testerrors, V2TestError(order, id, n, msg)); nothing)

    if name == "@testitem"
        if isempty(args)
            return err("Test definition error", "Your @testitem is missing a name and code block.")
        elseif !_v2_is_string_label(args[1])
            return err("Test definition error", "Your @testitem must have a first argument that is of type String for the name.")
        end
        label = _v2_string_label(args[1])
        if length(args) == 1
            return err(label, "Your @testitem is missing a code block argument.")
        elseif args[end].kind != JS2.K"block"
            return err(label, "The final argument of a @testitem must be a begin end block.")
        end

        option_tags = nothing
        option_default_imports = nothing
        option_setup = nothing
        # `nothing` is a VALUE for skip (the non-literal sentinel), so presence
        # gets its own flag rather than the `=== nothing` test the others use.
        option_skip = false
        skip_seen = false

        for kw in args[2:end-1]
            if kw.kind != JS2.K"=" || _v2_nchildren(kw) != 2
                return err(label, "The arguments to a @testitem must be in keyword format.")
            end
            kcs = _v2_children(kw)
            key = kcs[1].kind == JS2.K"Identifier" ? _v2_leaf_string(kcs[1]) : nothing
            value = kcs[2]

            if key == "tags"
                option_tags === nothing ||
                    return err(label, "The keyword argument tags cannot be specified more than once.")
                value.kind == JS2.K"vect" ||
                    return err(label, "The keyword argument tags only accepts a vector of symbols.")
                option_tags = Symbol[]
                for el in _v2_children(value)
                    # `:a` quotes as `(inert (Identifier "a"))` in the EST.
                    (el.kind == JS2.K"inert" && _v2_nchildren(el) == 1 &&
                     _v2_children(el)[1].kind == JS2.K"Identifier") ||
                        return err(label, "The keyword argument tags only accepts a vector of symbols.")
                    push!(option_tags, Symbol(_v2_leaf_string(_v2_children(el)[1])))
                end
            elseif key == "default_imports"
                option_default_imports === nothing ||
                    return err(label, "The keyword argument default_imports cannot be specified more than once.")
                value.val in (true, false) ||
                    return err(label, "The keyword argument default_imports only accepts bool values.")
                option_default_imports = value.val
            elseif key == "setup"
                option_setup === nothing ||
                    return err(label, "The keyword argument setup cannot be specified more than once.")
                value.kind == JS2.K"vect" ||
                    return err(label, "The keyword argument `setup` only accepts a vector of `@testsetup module` names.")
                option_setup = Symbol[]
                for el in _v2_children(value)
                    el.kind == JS2.K"Identifier" ||
                        return err(label, "The keyword argument `setup` only accepts a vector of `@testsetup module` names.")
                    push!(option_setup, Symbol(_v2_leaf_string(el)))
                end
            elseif key == "skip"
                skip_seen &&
                    return err(label, "The keyword argument skip cannot be specified more than once.")
                skip_seen = true
                # A literal Bool is resolved here; anything else is the `nothing`
                # sentinel — the join slices its source text by address.
                option_skip = value.val in (true, false) ? value.val : nothing
            else
                return err(label, "Unknown keyword argument.")
            end
        end

        push!(skel.testitems, V2TestItem(
            order, id, :testitem, label, copy(pm),
            something(option_default_imports, true),
            something(option_tags, Symbol[]),
            something(option_setup, Symbol[]),
            option_skip))
    else
        kind = name == "@testmodule" ? :testsetup_module : :testsetup_snippet
        if isempty(args)
            return err("Test definition error", "Your $name is missing a name and code block.")
        elseif args[1].kind != JS2.K"Identifier"
            return err("Test definition error", "Your $name must have a first argument that is an identifier for the name.")
        end
        label = something(_v2_leaf_string(args[1]), "")
        if length(args) == 1
            return err(label, "Your $name is missing a code block argument.")
        elseif args[end].kind != JS2.K"block"
            return err(label, "The final argument of a $name must be a begin end block.")
        end
        for kw in args[2:end-1]
            kw.kind == JS2.K"=" ||
                return err(label, "The arguments to a $name must be in keyword format.")
            return err(label, "Unknown keyword argument.")
        end
        push!(skel.testitems, V2TestItem(
            order, id, kind, label, copy(pm), true, Symbol[], Symbol[], false))
    end
    return nothing
end

# ── preorder addresses for the test-item emission join ──────────────────────

_v2_subtree_size(bt::BodyTree) =
    1 + (bt.children === nothing ? 0 : sum(_v2_subtree_size(c) for c in bt.children; init=0))

"Preorder addresses of `bt`'s direct children, given `bt`'s own address."
function _v2_child_addresses(bt::BodyTree, addr::Int)
    out = Int[]
    a = addr + 1
    for c in _v2_children(bt)
        push!(out, a)
        a += _v2_subtree_size(c)
    end
    return out
end

"""
    _v2_test_macro_addresses(bt) -> NamedTuple | nothing

The preorder addresses the test-item emission join needs from a test macrocall's
`BodyTree`: the trailing block, its first and last children (`nothing` when the
block is empty), and the value of a non-literal `skip` kwarg (`nothing`
otherwise). Addresses index `derived_v2_file_maps(rt, uri)[id]`, whose entries
`_build_body_tree_v2!` numbers with this same preorder walk.
"""
function _v2_test_macro_addresses(bt::BodyTree)
    cs = _v2_children(bt)
    isempty(cs) && return nothing
    addrs = _v2_child_addresses(bt, 1)
    block = cs[end]
    block.kind == JS2.K"block" || return nothing
    block_addr = addrs[end]
    baddrs = _v2_child_addresses(block, block_addr)

    skip_addr = nothing
    for (i, c) in enumerate(cs)
        (c.kind == JS2.K"=" && _v2_nchildren(c) == 2) || continue
        kcs = _v2_children(c)
        _v2_leaf_string(kcs[1]) == "skip" || continue
        kcs[2].val in (true, false) && continue
        skip_addr = _v2_child_addresses(c, addrs[i])[2]
    end

    return (block = block_addr,
            block_first = isempty(baddrs) ? nothing : baddrs[1],
            block_last = isempty(baddrs) ? nothing : baddrs[end],
            skip_value = skip_addr)
end

# ── include detection ───────────────────────────────────────────────────────

# `include("f.jl")` → `(call (Identifier "include") (String "f.jl"))`.
function _v2_is_include_call(bt::BodyTree)
    bt.kind == JS2.K"call" || return false
    cs = _v2_children(bt)
    length(cs) >= 2 || return false
    return _v2_leaf_string(cs[1]) == "include"
end

# The literal path argument of an include call, or `nothing` when computed.
# One computed idiom IS statically resolvable and common enough to support:
# `include(joinpath(@__DIR__, "a", "b.jl"))` — `@__DIR__` is the including
# file's directory, which is exactly what `derived_v2_include_target` resolves
# relative paths against, so the joined literal tail is equivalent to a plain
# relative path. (v1's StaticLint collector understands the same shape.)
function _v2_include_path(bt::BodyTree)
    cs = _v2_children(bt)
    length(cs) >= 2 || return nothing
    arg = cs[end]
    arg.kind == JS2.K"String" && return _v2_leaf_string(arg)
    if arg.kind == JS2.K"call"
        acs = _v2_children(arg)
        length(acs) >= 3 || return nothing
        _v2_leaf_string(acs[1]) == "joinpath" || return nothing
        dir = acs[2]
        (dir.kind == JS2.K"macrocall" && _v2_macrocall_name(dir) == "@__DIR__") || return nothing
        parts = String[]
        for c in acs[3:end]
            c.kind == JS2.K"String" || return nothing
            s = _v2_leaf_string(c)
            s === nothing && return nothing
            push!(parts, s)
        end
        isempty(parts) && return nothing
        return join(parts, "/")
    end
    return nothing
end

# ── id keys ─────────────────────────────────────────────────────────────────

# The coarse kind class for the id key. Maps to THE SAME symbols v1's
# `_id_kind_class` emits, so the two walkers share one key alphabet.
function _v2_id_kind_class(bt::BodyTree)
    k = bt.kind
    k == JS2.K"module" && return :module
    k == JS2.K"function" && return :function
    k == JS2.K"macro" && return :macro
    (k == JS2.K"struct" || k == JS2.K"abstract" || k == JS2.K"primitive") && return :datatype
    k == JS2.K"const" && return :const
    k == JS2.K"global" && return :global
    k == JS2.K"export" && return :export
    k == JS2.K"public" && return :public
    k == JS2.K"using" && return :using
    k == JS2.K"import" && return :import
    _v2_is_include_call(bt) && return :include
    k == JS2.K"=" && return :assignment
    k == JS2.K"macrocall" && return :macrocall
    return :other
end

# The name as written, qualifier included, so `Base.foo` and `foo` key apart.
# `""` when the statement binds no single name.
function _v2_id_dotted_name(bt::BodyTree)
    k = bt.kind
    if k == JS2.K"module"
        cs = _v2_children(bt)
        return length(cs) >= 2 ? something(_v2_leaf_string(cs[2]), "") : ""
    elseif k == JS2.K"const" || k == JS2.K"global"
        cs = _v2_children(bt)
        return isempty(cs) ? "" : _v2_id_dotted_name(cs[1])
    elseif k == JS2.K"export" || k == JS2.K"public" ||
           k == JS2.K"using" || k == JS2.K"import"
        # No single bound name. v1 keys these on the statement's printed text;
        # the structural hash is the same idea without a printer, and is stable
        # against every edit except an edit to the statement itself (these
        # statements have no body).
        return string(bt.hash, base=16)
    end

    target = k == JS2.K"=" || k == JS2.K"function" || k == JS2.K"macro" ?
        (_v2_nchildren(bt) >= 1 ? _v2_children(bt)[1] : bt) : bt
    if k == JS2.K"struct"
        cs = _v2_children(bt)
        target = length(cs) >= 2 ? cs[2] : bt
    elseif k == JS2.K"abstract" || k == JS2.K"primitive"
        cs = _v2_children(bt)
        target = isempty(cs) ? bt : cs[1]
    end

    q, n = _v2_qualified_name(_v2_unwrap_to_name(target))
    n === nothing && return ""
    return isempty(q) ? n : join(vcat(q, n), '.')
end

function _v2_statement_id_key(bt::BodyTree, parent_module::Vector{String})::_V2IdKey
    return try
        (_v2_id_kind_class(bt), _v2_id_dotted_name(bt), join(parent_module, '.'))
    catch err
        err isa InterruptException && rethrow()
        (:unknown, "", join(parent_module, '.'))
    end
end

# ── the walker ──────────────────────────────────────────────────────────────

# Mutable state threaded through the walk.
mutable struct _V2WalkState
    skeleton::V2FileSkeleton
    bodies::Dict{Int64,BodyTree{V2Kind}}
    maps::Dict{Int64,Vector{UnitRange{Int}}}
    alloc::_V2ItemIdAllocator
    # Macrocall-argument nesting depth of the walk position (see
    # `V2ItemRow.under_macrocall`).
    in_macro::Int
    # `if`-branch nesting depth of the walk position (see `V2ItemRow.conditional`).
    in_if::Int
end
_V2WalkState() = _V2WalkState(
    V2FileSkeleton(V2ItemRow[], V2Import[], V2Export[], V2Include[], V2Module[], V2OpaqueMacro[],
                   V2TestItem[], V2TestError[]),
    Dict{Int64,BodyTree{V2Kind}}(), Dict{Int64,Vector{UnitRange{Int}}}(), _V2ItemIdAllocator(), 0, 0)

"""
    _v2_walk_file!(state, root)

Walk a parsed file, filling `state` with the skeleton, the body forest and the
address maps.

Transparency rules mirror v1's exactly, because they encode real Julia scoping:
doc-macro wrappers, `if`/`elseif`/`else` chains, bare `begin…end` blocks, and
every macrocall except the isolating ones are transparent — their contents bind
at the enclosing level and must appear as ordinary items. `module` bodies are
descended into with an extended `parent_module`.
"""
function _v2_walk_file!(state::_V2WalkState, root)
    if !JS2.is_leaf(root) && JS2.kind(root) == JS2.K"toplevel"
        for c in JS2.children(root)
            _v2_walk_one!(state, c, String[], true)
        end
    else
        _v2_walk_one!(state, root, String[], true)
    end
    return state
end

# Emit one statement: mint its id, build its tree/map, and file it under the
# right skeleton bucket. Returns the minted id.
function _v2_emit!(state::_V2WalkState, node, parent_module::Vector{String}, interpretable::Bool)
    ranges = UnitRange{Int}[]
    bt = _build_body_tree_v2!(ranges, node)
    order, id = _v2_mint_ids!(state.alloc, _v2_statement_id_key(bt, parent_module))
    pm = copy(parent_module)
    k = bt.kind
    skel = state.skeleton

    if k == JS2.K"module"
        cs = _v2_children(bt)
        name = length(cs) >= 2 ? _v2_leaf_string(cs[2]) : nothing
        # EST encodes bare-ness as child 1: `module` → true, `baremodule` → false.
        not_bare = length(cs) >= 1 && cs[1].val === true
        name !== nothing && push!(skel.modules, V2Module(order, id, name, !not_bare, pm))
        # Module items get no BODY: it would duplicate every inner item's tree
        # and churn on any edit inside the module. Module structure is the
        # module-tree layer's job; the walker still yields the inner items.
        # The address MAP is stored though (volatile anyway), so module-level
        # findings — `module_name` — can be emitted at the name's range
        # (preorder address 3: children are [bare-flag, name, block]).
        state.maps[id] = ranges
        return order, id, bt
    elseif k == JS2.K"using" || k == JS2.K"import"
        _v2_emit_import!(skel, bt, order, id, pm)
        # Map (not body) stored, so import-level findings — `relative_import` —
        # can be emitted at the statement's range.
        state.maps[id] = ranges
        return order, id, bt
    elseif k == JS2.K"export" || k == JS2.K"public"
        names = String[]
        for c in _v2_children(bt)
            s = _v2_leaf_string(c)
            s !== nothing && push!(names, s)
        end
        push!(skel.exports, V2Export(order, id, k == JS2.K"export" ? :export : :public, names, pm))
        return order, id, bt
    elseif _v2_is_include_call(bt)
        push!(skel.includes, V2Include(order, id, _v2_include_path(bt), pm))
        return order, id, bt
    end

    push!(skel.items, V2ItemRow(order, id, _v2_id_kind_class(bt), pm, interpretable,
                                state.in_macro > 0, state.in_if > 0))
    state.bodies[id] = bt
    state.maps[id] = ranges

    # `const DATA = include("data.jl")` is both a binding and an include edge.
    inner = bt
    while (inner.kind == JS2.K"const" || inner.kind == JS2.K"global") && _v2_nchildren(inner) >= 1
        inner = _v2_children(inner)[1]
    end
    if inner.kind == JS2.K"=" && _v2_nchildren(inner) >= 2
        rhs = _v2_children(inner)[2]
        _v2_is_include_call(rhs) &&
            push!(skel.includes, V2Include(order, id, _v2_include_path(rhs), pm))
    end
    return order, id, bt
end

function _v2_emit_import!(skel::V2FileSkeleton, bt::BodyTree, order, id, pm)
    kind = bt.kind == JS2.K"using" ? :using : :import
    # One statement can name several modules — `import A, B, C` is three
    # imports sharing one id, exactly as v1 records them.
    for head in _v2_children(bt)
        _v2_emit_one_import!(skel, kind, head, order, id, pm)
    end
    return
end

function _v2_emit_one_import!(skel::V2FileSkeleton, kind::Symbol, head::BodyTree, order, id, pm)
    path = String[]
    symbols = V2ImportSymbol[]
    alias = nothing

    if head.kind == JS2.K":"
        # `using A.B: c, d as e`
        hcs = _v2_children(head)
        isempty(hcs) && return
        path = _v2_import_path(hcs[1])
        for s in hcs[2:end]
            if s.kind == JS2.K"as" && _v2_nchildren(s) >= 2
                scs = _v2_children(s)
                nm = _v2_import_path(scs[1])
                al = _v2_leaf_string(scs[2])
                isempty(nm) || push!(symbols, (name=last(nm), alias=al))
            else
                nm = _v2_import_path(s)
                isempty(nm) || push!(symbols, (name=last(nm), alias=nothing))
            end
        end
    elseif head.kind == JS2.K"as"
        # `import A as B`
        hcs = _v2_children(head)
        length(hcs) >= 2 || return
        path = _v2_import_path(hcs[1])
        alias = _v2_leaf_string(hcs[2])
    else
        path = _v2_import_path(head)
    end

    push!(skel.imports, V2Import(order, id, kind, path, symbols, alias, pm))
    return
end

function _v2_walk_one!(state::_V2WalkState, node, parent_module::Vector{String}, interpretable::Bool)
    JS2.is_leaf(node) && return _v2_emit_plain!(state, node, parent_module, interpretable)
    k = JS2.kind(node)
    cs = JS2.children(node)
    cs === nothing && return _v2_emit_plain!(state, node, parent_module, interpretable)

    if k == JS2.K"block"
        # Bare `begin…end` and `if`-branch bodies introduce no scope.
        for c in cs
            _v2_walk_one!(state, c, parent_module, interpretable)
        end
        return
    elseif k == JS2.K"if" || k == JS2.K"elseif"
        return _v2_walk_if_chain!(state, node, parent_module, interpretable)
    elseif k == JS2.K"macrocall"
        return _v2_walk_macrocall!(state, node, parent_module, interpretable)
    end

    _v2_emit!(state, node, parent_module, interpretable)
    if k == JS2.K"module" && length(cs) >= 3
        name = JS2.is_leaf(cs[2]) ? _v2_node_string(cs[2]) : nothing
        if name !== nothing
            inner = push!(copy(parent_module), name)
            body = cs[3]
            if !JS2.is_leaf(body) && JS2.children(body) !== nothing
                for c in JS2.children(body)
                    _v2_walk_one!(state, c, inner, interpretable)
                end
            end
        end
    end
    return
end

_v2_emit_plain!(state, node, parent_module, interpretable) =
    (_v2_emit!(state, node, parent_module, interpretable); nothing)

# A ternary `c ? a : b` also parses as `K"if"`, and checking whether the second
# child is a `K"block"` is NOT a reliable discriminator — `c ? begin … end : g()`
# gives a ternary a block child too. What IS reliable is byte position: a real
# `if`/`elseif` node starts at its keyword, BEFORE its condition, whereas a
# ternary starts exactly where its condition does. Verified on both shapes.
function _v2_walk_if_chain!(state::_V2WalkState, node, parent_module::Vector{String}, interpretable::Bool)
    cs = JS2.children(node)
    if isempty(cs) || JS2.first_byte(node) == JS2.first_byte(cs[1])
        return _v2_emit_plain!(state, node, parent_module, interpretable)  # ternary
    end
    # cs[1] is the condition; the rest are branch bodies / the elseif tail.
    state.in_if += 1
    for c in cs[2:end]
        ck = JS2.kind(c)
        if ck == JS2.K"elseif" || ck == JS2.K"if"
            _v2_walk_if_chain!(state, c, parent_module, interpretable)
        elseif ck == JS2.K"block"
            ccs = JS2.children(c)
            ccs === nothing && continue
            for cc in ccs
                _v2_walk_one!(state, cc, parent_module, interpretable)
            end
        else
            _v2_walk_one!(state, c, parent_module, interpretable)
        end
    end
    state.in_if -= 1
    return
end

function _v2_walk_macrocall!(state::_V2WalkState, node, parent_module::Vector{String}, interpretable::Bool)
    cs = JS2.children(node)
    name = length(cs) >= 1 ? _v2_node_macro_name(cs[1]) : nothing

    # A docstring wrapper is transparent: the wrapped item is what gets an id.
    if _v2_is_doc_macro(name) && length(cs) == 4
        return _v2_walk_one!(state, cs[4], parent_module, interpretable)
    end

    # `@enum` and the isolating test macros are single opaque items. The test
    # macros additionally get their argument shape SCANNED into native
    # `V2TestItem` records — the walker looks inside them, but still emits one
    # item and never descends, so the isolation rule is untouched.
    if name == "@enum" || (name !== nothing && name in V2_ISOLATED_SCOPE_MACROS)
        order, id, bt = _v2_emit!(state, node, parent_module, interpretable)
        name in ("@testitem", "@testmodule", "@testsnippet") &&
            _v2_scan_test_macro!(state.skeleton, bt, name, order, id, parent_module)
        return nothing
    end

    # Effects we do not model: record the macrocall itself, then still walk its
    # arguments so visible definitions inside remain ordinary items.
    if !_v2_macro_name_effects_known(name)
        ranges = UnitRange{Int}[]
        bt = _build_body_tree_v2!(ranges, node)
        order, id = _v2_mint_ids!(state.alloc, _v2_statement_id_key(bt, parent_module))
        push!(state.skeleton.opaque_macros, V2OpaqueMacro(order, id, copy(parent_module)))
        push!(state.skeleton.items, V2ItemRow(order, id, :opaque_macrocall, copy(parent_module),
                                              interpretable, state.in_macro > 0, state.in_if > 0))
        state.bodies[id] = bt
        state.maps[id] = ranges
    end

    child_interpretable = interpretable && !(name !== nothing && name in DEFINITION_SHAPED_DSL_MACROS)
    state.in_macro += 1
    for c in cs[min(3, length(cs) + 1):end]
        _v2_walk_one!(state, c, parent_module, child_interpretable)
    end
    state.in_macro -= 1
    return
end

# ── Salsa queries ───────────────────────────────────────────────────────────

"""
    V2FileWalk

The three products of one walk, bundled so they share a single parse.

Deliberately a PLAIN struct, not `@auto_hash_equals`: Salsa's early-exit
comparison on this bundle would be an O(file) walk that ALWAYS fails, since the
maps shift on any position edit. Default `==` is `===`, so the comparison is
O(1) and the real early-exit happens in the three projections below.
"""
struct V2FileWalk
    skeleton::V2FileSkeleton
    bodies::Dict{Int64,BodyTree{V2Kind}}
    maps::Dict{Int64,Vector{UnitRange{Int}}}
end

const EMPTY_V2_FILE_WALK = V2FileWalk(
    EMPTY_V2_SKELETON, Dict{Int64,BodyTree{V2Kind}}(), Dict{Int64,Vector{UnitRange{Int}}}())

"""
    derived_v2_file_walk(rt, uri) -> V2FileWalk

The single v2 parse of `uri`, walked once into skeleton + bodies + maps.
Consumers depend on the projections below, never on this.

Parses with `ignore_errors=true`, so a syntax error yields JuliaSyntax's
RECOVERED tree rather than an empty walk — the same robustness CSTParser's
recovery gives v1. Intact items (test items included) survive an error
elsewhere in the file; `K"error"` nodes flow into `BodyTree`s like any other
kind, and the error itself is still reported by
`derived_julia_syntax_diagnostics`. For a clean file the flag changes nothing.
"""
Salsa.@derived function derived_v2_file_walk(rt, uri)
    @debug "derived_v2_file_walk" uri=uri

    derived_has_content(rt, uri) || return EMPTY_V2_FILE_WALK
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return EMPTY_V2_FILE_WALK

    root = try
        JS2.parseall(JS2.SyntaxTree, tf.content.content; filename=string(uri), ignore_errors=true)
    catch err
        err isa InterruptException && rethrow()
        return EMPTY_V2_FILE_WALK
    end

    state = try
        _v2_walk_file!(_V2WalkState(), root)
    catch err
        err isa InterruptException && rethrow()
        return EMPTY_V2_FILE_WALK
    end
    return V2FileWalk(state.skeleton, state.bodies, state.maps)
end

"""
    derived_v2_file_skeleton(rt, uri) -> V2FileSkeleton

The body-free API shape of `uri`. Backdates on every edit that does not change
the file's top-level API — which is what makes the module tree above it
insensitive to body edits.
"""
Salsa.@derived derived_v2_file_skeleton(rt, uri) = derived_v2_file_walk(rt, uri).skeleton

"Per-item `BodyTree`s, keyed by v2 item id."
Salsa.@derived derived_v2_file_bodies(rt, uri) = derived_v2_file_walk(rt, uri).bodies

"""
    derived_v2_file_maps(rt, uri) -> Dict{Int64,Vector{UnitRange{Int}}}

For each item id, the address map of its `BodyTree`: entry `i` is the 1-based,
exclusive-end byte range of the node at preorder address `i`. Module and
`using`/`import` rows have a map too (though no body), so module- and
import-level findings can be emitted at real ranges. VOLATILE by design
— it recomputes on every reparse. Analysis layers depend on `derived_v2_item_body`
(position-free) only; this exists solely to reattach locations at the last mile.
Depending on it from an analysis-layer computation is a bug.
"""
Salsa.@derived derived_v2_file_maps(rt, uri) = derived_v2_file_walk(rt, uri).maps

"""
    derived_v2_noninterpretable_ids(rt, uri) -> Set{Int64}

The items the walker marked non-interpretable — those sitting under a macrocall
whose argument merely LOOKS like a definition (`DEFINITION_SHAPED_DSL_MACROS`).
They are still enumerated and classified; only semantic analysis declines them.

A separate projection rather than a scan of `skeleton.items`, so the lowering
layer's per-item check is a hash lookup instead of a linear search — and so it
backdates on its own, independently of unrelated skeleton churn.
"""
Salsa.@derived function derived_v2_noninterpretable_ids(rt, uri)
    ids = Set{Int64}()
    for row in derived_v2_file_skeleton(rt, uri).items
        row.interpretable || push!(ids, row.id)
    end
    return ids
end

"""
    derived_v2_under_macrocall_ids(rt, uri) -> Set{Int64}

Items enumerated from inside a macrocall's arguments (see
`V2ItemRow.under_macrocall`). Same projection shape as
`derived_v2_noninterpretable_ids`, for the same reason: a hash lookup that
backdates on its own.
"""
Salsa.@derived function derived_v2_under_macrocall_ids(rt, uri)
    ids = Set{Int64}()
    for row in derived_v2_file_skeleton(rt, uri).items
        row.under_macrocall && push!(ids, row.id)
    end
    return ids
end

"The test items and test definition errors of one file, as a comparable value."
@auto_hash_equals struct V2FileTestItems
    testitems::Vector{V2TestItem}
    testerrors::Vector{V2TestError}
end

"""
    derived_v2_file_testitems(rt, uri) -> V2FileTestItems

Projection of the skeleton's test records, so consumers backdate on any edit
that does not change a label, an option, or the set of items — including every
position-only edit and every body edit. The volatile half (ranges, `code`) is
reattached in `derived_v2_testitem_details` (layer_testitems.jl).
"""
Salsa.@derived function derived_v2_file_testitems(rt, uri)
    skel = derived_v2_file_skeleton(rt, uri)
    return V2FileTestItems(skel.testitems, skel.testerrors)
end

"""
    derived_v2_item_body(rt, ref) -> Union{Nothing,BodyTree{V2Kind}}

Per-item wrapper so Salsa's early-exit fires per item: an edit that only changes
OTHER items in the file leaves this value `isequal` and stops invalidation here.
`nothing` when the item does not exist or carries no body (modules, imports,
exports, includes).
"""
Salsa.@derived function derived_v2_item_body(rt, ref::V2ItemRef)
    return get(derived_v2_file_bodies(rt, ref.file), ref.id, nothing)
end

"""
    derived_v2_item_body_hash(rt, ref) -> UInt64

The structural hash of the item's `BodyTree`, `0` when absent. The cheap
"did this item's content change" gate for consumers that don't need the tree.
"""
Salsa.@derived function derived_v2_item_body_hash(rt, ref::V2ItemRef)
    body = derived_v2_item_body(rt, ref)
    return body === nothing ? UInt64(0) : body.hash
end

# ── classification ──────────────────────────────────────────────────────────

# Struct field names: the body block's `(:: name Type)` and bare `name` entries,
# looking through `const`/`@atomic` wrappers.
function _v2_field_names(block::BodyTree)
    out = String[]
    block.kind == JS2.K"block" || return out
    for f in _v2_children(block)
        node = f
        while (node.kind == JS2.K"const" || node.kind == JS2.K"macrocall") && _v2_nchildren(node) >= 1
            node = _v2_children(node)[end]
        end
        if node.kind == JS2.K"::" && _v2_nchildren(node) >= 1
            node = _v2_children(node)[1]
        end
        s = _v2_leaf_string(node)
        s !== nothing && push!(out, s)
    end
    return out
end

# `a, b = 1, 2`, `(; a, b) = cfg`, splats and nesting: one name per bound identifier.
function _v2_destructure_names!(out::Vector{String}, bt::BodyTree)
    k = bt.kind
    if k == JS2.K"tuple" || k == JS2.K"parameters"
        for c in _v2_children(bt)
            _v2_destructure_names!(out, c)
        end
    elseif k == JS2.K"..." || k == JS2.K"::"
        _v2_nchildren(bt) >= 1 && _v2_destructure_names!(out, _v2_children(bt)[1])
    elseif k == JS2.K"="
        # `(; a = x)` property destructuring with a default
        _v2_nchildren(bt) >= 1 && _v2_destructure_names!(out, _v2_children(bt)[1])
    else
        s = _v2_leaf_string(bt)
        s !== nothing && push!(out, s)
    end
    return out
end

_v2_is_tuple_lhs(bt::BodyTree) = bt.kind == JS2.K"tuple" || bt.kind == JS2.K"parameters"

"""
    _v2_classify(bt) -> Vector{V2Decl}

Every name one item declares, with its refined kind. A pure function of the
item's `BodyTree` — it cannot see a byte offset, because the type has none.
That is what makes the position-free firewall structural rather than a
convention.
"""
function _v2_classify(bt::BodyTree, kind_override::Union{Nothing,Symbol}=nothing)
    out = V2Decl[]
    k = bt.kind
    cs = _v2_children(bt)

    if k == JS2.K"function" || k == JS2.K"macro"
        isempty(cs) && return out
        q, n = _v2_qualified_name(_v2_unwrap_to_name(cs[1]))
        n === nothing && return out
        kind = k == JS2.K"function" ? :function : :macro
        # Macros are named WITH the `@` prefix throughout the inventory layers:
        # `@foo` and `foo` can legitimately coexist in one scope.
        kind === :macro && !startswith(n, "@") && (n = "@" * n)
        push!(out, V2Decl(n, q, something(kind_override, kind), String[]))

    elseif k == JS2.K"struct"
        length(cs) >= 2 || return out
        mutable = cs[1].val === true
        q, n = _v2_qualified_name(_v2_unwrap_to_name(cs[2]))
        n === nothing && return out
        fields = length(cs) >= 3 ? _v2_field_names(cs[3]) : String[]
        push!(out, V2Decl(n, q, something(kind_override, mutable ? :mutable_struct : :struct), fields))

    elseif k == JS2.K"abstract" || k == JS2.K"primitive"
        isempty(cs) && return out
        q, n = _v2_qualified_name(_v2_unwrap_to_name(cs[1]))
        n === nothing && return out
        push!(out, V2Decl(n, q, something(kind_override, k == JS2.K"abstract" ? :abstract : :primitive), String[]))

    elseif k == JS2.K"const" || k == JS2.K"global"
        isempty(cs) && return out
        return _v2_classify(cs[1], something(kind_override, k == JS2.K"const" ? :const : :global))

    elseif k == JS2.K"="
        length(cs) >= 1 || return out
        lhs = cs[1]
        # Look past a return-type declaration: `f(x)::Int = 1`.
        while lhs.kind == JS2.K"::" && _v2_nchildren(lhs) >= 1
            lhs = _v2_children(lhs)[1]
        end
        inner = lhs
        while inner.kind == JS2.K"where" && _v2_nchildren(inner) >= 1
            inner = _v2_children(inner)[1]
        end
        if inner.kind == JS2.K"call"
            # A method definition in short form.
            q, n = _v2_qualified_name(_v2_unwrap_to_name(inner))
            n !== nothing && push!(out, V2Decl(n, q, something(kind_override, :function), String[]))
        elseif inner.kind == JS2.K"curly"
            # Typealias: `Vector{T} = Array{T,1}`.
            q, n = _v2_qualified_name(_v2_unwrap_to_name(inner))
            n !== nothing && push!(out, V2Decl(n, q, something(kind_override, :assignment), String[]))
        elseif _v2_is_tuple_lhs(inner)
            for n in _v2_destructure_names!(String[], inner)
                push!(out, V2Decl(n, String[], something(kind_override, :assignment), String[]))
            end
        else
            n = _v2_leaf_string(inner)
            n !== nothing && push!(out, V2Decl(n, String[], something(kind_override, :assignment), String[]))
        end

    elseif k == JS2.K"macrocall"
        name = _v2_macrocall_name(bt)
        if name == "@enum"
            args = _v2_macro_args(bt)
            # Members may be listed inline (`@enum C red green`) or in a block
            # (`@enum C begin red; green end`); the type name is always first.
            if length(args) == 2 && args[2].kind == JS2.K"block"
                args = vcat(args[1], _v2_children(args[2]))
            end
            for (i, a) in enumerate(args)
                node = a
                # `@enum Color::UInt8 red=1 green`
                while (node.kind == JS2.K"::" || node.kind == JS2.K"=") && _v2_nchildren(node) >= 1
                    node = _v2_children(node)[1]
                end
                n = _v2_leaf_string(node)
                n === nothing && continue
                push!(out, V2Decl(n, String[], i == 1 ? :enum : :enum_member, String[]))
            end
        elseif name !== nothing && name in V2_ISOLATED_SCOPE_MACROS
            # An isolating macrocall declares nothing at this level, but it IS an
            # item, named after the macro so consumers can explain the opacity.
            push!(out, V2Decl(name, String[], :opaque_macrocall, String[]))
        end
        # Every other macrocall declares nothing nameable here: it is recorded in
        # `opaque_macros` (which is what marks the module blind), while whatever
        # its arguments spell was already walked into ordinary items.
    end
    return out
end

"""
    derived_v2_item_classification(rt, ref) -> Vector{V2Decl}

The names one item declares. Depends ONLY on `derived_v2_item_body`, so it
re-executes when that item's content changes and backdates otherwise.
"""
Salsa.@derived function derived_v2_item_classification(rt, ref::V2ItemRef)
    body = derived_v2_item_body(rt, ref)
    body === nothing && return V2Decl[]
    return try
        _v2_classify(body)
    catch err
        err isa InterruptException && rethrow()
        V2Decl[]
    end
end

"""
    derived_v2_file_inventory(rt, uri) -> V2FileInventory

The v1-shaped composite: every skeleton row joined with its classification.
Consumers that want one value per file use this; consumers that work item by
item should depend on `derived_v2_item_classification` directly, so they get
per-item early exit.
"""
Salsa.@derived function derived_v2_file_inventory(rt, uri)
    skel = derived_v2_file_skeleton(rt, uri)
    items = V2InventoryItem[]
    for row in skel.items
        for d in derived_v2_item_classification(rt, V2ItemRef(uri, row.id))
            # An opaque macrocall declares nothing nameable; it is still an item.
            push!(items, V2InventoryItem(row.order, row.id, d.name, d.qualifier,
                                         d.kind, d.field_names, row.parent_module))
        end
    end
    return V2FileInventory(items, skel.imports, skel.exports, skel.includes,
                           skel.modules, skel.opaque_macros)
end
