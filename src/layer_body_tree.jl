# BodyTree: a per-item, position-free, trivia-free value tree over top-level
# item expressions, plus a volatile node-address→byte-range side map.
#
# The firewall contract, one level below the inventory (`layer_inventory.jl`):
# a `BodyTree` contains only plain data — kinds, leaf values, children — never
# a byte offset, an EXPR/SyntaxNode reference, an objectid, or a runtime
# handle. Two trees are `isequal` iff the item's parsed content is identical,
# regardless of where the item sits in the file, surrounding whitespace, or
# comments (inside or outside the body). That makes `derived_item_body`
# backdate under Salsa's early-exit, so consumers that analyze item content
# never rerun on position-only edits.
#
# Positions are reattached exclusively through `derived_file_body_maps`, which
# is volatile by design (recomputes on every reparse). Depending on it from an
# analysis-layer computation is a bug — only last-mile assembly (joining
# node addresses to ranges) may read it. Node address = preorder index into
# the tree, root = 1; the tree and its map are produced by the same walk, so
# addresses always align.

"""
    BodyTree

Position-free, trivia-free structural value of one syntax node. Leaves carry
their parsed value in `val` (identifier `Symbol`s, literals); interior nodes
carry `val === nothing` and their children. `hash` is the structural hash,
computed once at construction, so `isequal`/`hash` are cheap for Salsa's
early-exit comparison.

Equality is structural and slightly stricter than leaf `isequal`: leaf values
must also agree in type, so numerically-equal literals of different types
(e.g. `1` vs `Int8(1)` under the same kind) compare unequal.
"""
struct BodyTree{K}
    kind::K
    val::Any
    children::Union{Nothing,Vector{BodyTree{K}}}
    hash::UInt64

    # `K` is a 16-bit primitive kind type: the registered JuliaSyntax.Kind for the
    # parse-facing forest, the vendored v2 Kind for the lowering layer's forest.
    function BodyTree{K}(kind::K, @nospecialize(val), children::Union{Nothing,Vector{BodyTree{K}}}) where {K}
        h = hash(reinterpret(UInt16, kind), 0xb0d1743e5eed0000 % UInt64)
        h = hash(typeof(val), h)
        h = hash(val, h)
        if children === nothing
            h = hash(false, h)
        else
            h = hash(true, h)
            for c in children
                h = hash(c.hash, h)
            end
        end
        return new{K}(kind, val, children, h)
    end
end

BodyTree(kind::K, @nospecialize(val), children::Union{Nothing,AbstractVector}) where {K} =
    BodyTree{K}(kind, val, children === nothing ? nothing : convert(Vector{BodyTree{K}}, children))

Base.hash(t::BodyTree, h::UInt) = hash(t.hash, h)

function Base.:(==)(a::BodyTree, b::BodyTree)
    a === b && return true
    a.hash == b.hash || return false
    a.kind == b.kind || return false
    typeof(a.val) === typeof(b.val) && isequal(a.val, b.val) || return false
    (a.children === nothing) == (b.children === nothing) || return false
    a.children === nothing && return true
    length(a.children) == length(b.children) || return false
    return all(a.children[i] == b.children[i] for i in eachindex(a.children))
end

Base.isequal(a::BodyTree, b::BodyTree) = a == b

# Shared preorder walk producing the tree and (optionally) the address→range
# map. One implementation for both guarantees that preorder addresses in the
# map line up with the tree.
function _build_body_tree!(ranges::Union{Nothing,Vector{UnitRange{Int}}}, node::SyntaxNode)
    ranges !== nothing && push!(ranges, _range(node))
    k = kind(node)
    if JuliaSyntax.is_leaf(node)
        return BodyTree(k, node.val, nothing)
    else
        cs = Vector{BodyTree{typeof(k)}}()
        for c in children(node)
            push!(cs, _build_body_tree!(ranges, c))
        end
        return BodyTree(k, nothing, cs)
    end
end

"""
    body_tree(node::SyntaxNode) -> BodyTree

The position-free structural value of `node`.
"""
body_tree(node::SyntaxNode) = _build_body_tree!(nothing, node)

"""
    body_tree_with_map(node::SyntaxNode) -> (BodyTree, Vector{UnitRange{Int}})

The tree plus its address map: entry `i` is the 1-based, exclusive-end byte
range of the node at preorder address `i` (root = 1).
"""
function body_tree_with_map(node::SyntaxNode)
    ranges = UnitRange{Int}[]
    tree = _build_body_tree!(ranges, node)
    return tree, ranges
end

# Index every syntax node by its first byte, keeping the OUTERMOST node per
# byte (preorder visits parents before children, so `get!` keeps the parent —
# e.g. for `f(x) = 1` the whole definition, not the `f(x)` call or `f`).
function _index_outermost_by_first_byte!(dict::Dict{Int,SyntaxNode}, node::SyntaxNode)
    get!(dict, first_byte(node), node)
    if !JuliaSyntax.is_leaf(node)
        for c in children(node)
            _index_outermost_by_first_byte!(dict, c)
        end
    end
    return dict
end

# Shared skeleton for the forest and map queries: associate each inventory
# item with its JuliaSyntax node and call `f(id, node)`.
#
# Item ids are minted by the CSTParser-based `_foreach_toplevel_item` (the
# single source of truth for ids), while bodies are built from the JuliaSyntax
# parse of the same content, matched by the item's first byte (CST offsets are
# 0-based, JuliaSyntax bytes 1-based). An item whose start byte has no
# JuliaSyntax node (parser divergence) is skipped — absence, not an error.
function _foreach_item_syntax_node(f, rt, uri)
    derived_has_content(rt, uri) || return nothing
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return nothing

    syntax_tree, _ = parse_julia_syntax_tree(tf.content.content)
    outermost = Dict{Int,SyntaxNode}()
    # Skip the file's root `toplevel` node: it shares its first byte with the
    # first item, and the outermost-wins rule would otherwise map that item to
    # the whole file.
    if !JuliaSyntax.is_leaf(syntax_tree) && kind(syntax_tree) == K"toplevel"
        for c in children(syntax_tree)
            _index_outermost_by_first_byte!(outermost, c)
        end
    else
        _index_outermost_by_first_byte!(outermost, syntax_tree)
    end

    _foreach_toplevel_item(cst) do _x, _order, id, _parent_module, offset
        node = get(outermost, offset + 1, nothing)
        node === nothing && return
        f(id, node)
    end
    return nothing
end

"""
    derived_file_body_forest(rt, uri) -> Dict{Int64,BodyTree}

The `BodyTree` of every top-level item in `uri`, keyed by inventory item id.
One JuliaSyntax parse per recompute; values backdate individually through
`derived_item_body`.
"""
Salsa.@derived function derived_file_body_forest(rt, uri)
    @debug "derived_file_body_forest" uri=uri

    result = Dict{Int64,BodyTree{JuliaSyntax.Kind}}()
    _foreach_item_syntax_node(rt, uri) do id, node
        result[id] = body_tree(node)
    end
    return result
end

"""
    derived_item_body(rt, ref) -> Union{Nothing,BodyTree}

Per-item wrapper over `derived_file_body_forest` so Salsa's early-exit fires
per item: an edit that only changes OTHER items in the file leaves this value
`isequal` and stops invalidation here. `nothing` when the item does not exist
or has no matched syntax node.
"""
Salsa.@derived function derived_item_body(rt, ref)
    forest = derived_file_body_forest(rt, ref.file)
    return get(forest, ref.id, nothing)
end

"""
    derived_item_body_hash(rt, ref) -> UInt64

The structural hash of the item's `BodyTree`, `0` when absent. The cheap
"did this item's content change" gate for consumers that don't need the tree.
"""
Salsa.@derived function derived_item_body_hash(rt, ref)
    body = derived_item_body(rt, ref)
    return body === nothing ? UInt64(0) : body.hash
end

"""
    derived_file_body_maps(rt, uri) -> Dict{Int64,Vector{UnitRange{Int}}}

For each item id, the address map of its `BodyTree`: entry `i` is the
1-based, exclusive-end byte range (in `uri`'s current content) of the node at
preorder address `i`. Volatile: recomputes on every reparse, which is fine
because it is a leaf — analysis layers depend on `derived_item_body`
(position-free) only; this query exists solely to reattach locations at the
last mile. Depending on this query from an analysis-layer computation is a bug.
"""
Salsa.@derived function derived_file_body_maps(rt, uri)
    @debug "derived_file_body_maps" uri=uri

    result = Dict{Int64,Vector{UnitRange{Int}}}()
    _foreach_item_syntax_node(rt, uri) do id, node
        result[id] = body_tree_with_map(node)[2]
    end
    return result
end
