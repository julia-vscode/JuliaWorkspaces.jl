# BodyTree: the position-free, trivia-free value tree that every v2 analysis
# layer is written against.
#
# The firewall contract: a `BodyTree` contains only plain data — kinds, leaf
# values, children — never a byte offset, a SyntaxTree reference, an objectid,
# a file name, or a runtime handle. Two trees are `isequal` iff the item's
# parsed content is identical, regardless of where the item sits in the file,
# surrounding whitespace, or comments (inside or outside the body). That makes
# per-item queries backdate under Salsa's early-exit, so consumers that analyze
# item content never rerun on position-only edits.
#
# Positions are reattached exclusively through the volatile address→range maps
# built alongside the trees (`derived_v2_file_maps`). Depending on a map from an
# analysis-layer computation is a bug — only last-mile assembly (joining node
# addresses to ranges) may read one. Node address = preorder index into the
# tree, root = 1; a tree and its map are produced by the same walk, so addresses
# always align.
#
# This file defines the TYPE only. Construction lives with the walker that owns
# item identity (`layer_inventory_v2.jl`), so tree, map and id always come from
# one traversal.

"""
    BodyTree

Position-free, trivia-free structural value of one syntax node. Leaves carry
their parsed value in `val` (identifier names, literals); interior nodes carry
the EST node's own `value` (usually `nothing`) plus their children. `hash` is
the structural hash, computed once at construction, so `isequal`/`hash` are
cheap for Salsa's early-exit comparison.

Equality is structural and slightly stricter than leaf `isequal`: leaf values
must also agree in type, so numerically-equal literals of different types
(e.g. `1` vs `Int8(1)` under the same kind) compare unequal.

Note that the EST produced by the vendored parser encodes several syntactic
distinctions as *structure* rather than head flags — `mutable struct` is
`(struct (Value true) …)`, `baremodule` is `(module (Value false) …)`, and a
short-form `f(x) = 1` has kind `K"="` where the long form has `K"function"`.
So `kind` + `val` + `children` is a complete record of the parse; there are no
head flags to carry.
"""
struct BodyTree{K}
    kind::K
    val::Any
    children::Union{Nothing,Vector{BodyTree{K}}}
    hash::UInt64

    # `K` is a 16-bit primitive kind type: the vendored JuliaSyntax `Kind`.
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

"Number of nodes in `bt` — i.e. the number of valid preorder addresses."
bt_node_count(bt::BodyTree) =
    bt.children === nothing ? 1 : 1 + sum(bt_node_count, bt.children; init = 0)
