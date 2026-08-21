# v2-backed interactive features (experiment, behind `input_v2_features`):
# the offset→item/address query family ("A1") and the resolvers built on it.
# Lives OUTSIDE src/v2/ because feature code joins v2 data with feature result
# structs and v1 fallback paths (same reasoning as layer_testitems.jl).
#
# Everything here is a PLAIN function, never `Salsa.@derived`: these are
# last-mile consumers of `derived_v2_file_maps`, the volatile per-request
# leaf, exactly like v1's `derived_item_positions` consumers.
#
# Offset conventions: feature entry points carry 0-BASED byte offsets
# (`public.jl` does `index - 1`); map ranges are 1-based with EXCLUSIVE ends.
# So for a range `r`: start0 = `first(r) - 1`, stop0 = `last(r) - 1`, and the
# cursor-containment test is inclusive at BOTH edges (`x|` and `|x` both hit
# `x`), mirroring v1's `get_expr1`.

_v2f_start0(r::UnitRange{Int}) = first(r) - 1
_v2f_stop0(r::UnitRange{Int}) = last(r) - 1
_v2f_contains(r::UnitRange{Int}, offset0::Int) = _v2f_start0(r) <= offset0 <= _v2f_stop0(r)

"""
    V2ItemView

A per-request, preorder-aligned view of one item: the map's byte ranges plus
the body's kinds, leaf values and parent addresses, all indexed by preorder
address. Built by one walk of the position-free body; valid only within the
request that built it (the ranges come from the volatile map).
"""
struct V2ItemView
    ref::V2ItemRef
    ranges::Vector{UnitRange{Int}}
    kinds::Vector{V2Kind}
    vals::Vector{Any}          # leaf `val` (String for identifiers); nothing for interior nodes
    parents::Vector{Int32}     # preorder parent address; 0 for the root
end

function _v2f_fill!(kinds, vals, parents, bt::BodyTree{V2Kind}, parent::Int32, counter::Base.RefValue{Int32})
    my = (counter[] += Int32(1))
    kinds[my] = bt.kind
    vals[my] = bt.children === nothing ? bt.val : nothing
    parents[my] = parent
    if bt.children !== nothing
        for c in bt.children
            _v2f_fill!(kinds, vals, parents, c, my, counter)
        end
    end
    return nothing
end

"""
    v2_item_view(rt, uri, id) -> Union{Nothing,V2ItemView}

The aligned view for the item/record with walker id `id`, or `nothing` when
the body or map is missing or their preorder lengths disagree (a defensive
impossibility check — callers fall back to the v1 path).
"""
function v2_item_view(rt, uri::URI, id::Int64)
    body = get(derived_v2_file_bodies(rt, uri), id, nothing)
    body === nothing && return nothing
    ranges = get(derived_v2_file_maps(rt, uri), id, nothing)
    ranges === nothing && return nothing
    n = bt_node_count(body)
    n == length(ranges) || return nothing
    kinds = Vector{V2Kind}(undef, n)
    vals = Vector{Any}(undef, n)
    parents = Vector{Int32}(undef, n)
    _v2f_fill!(kinds, vals, parents, body, Int32(0), Ref(Int32(0)))
    return V2ItemView(V2ItemRef(uri, id), ranges, kinds, vals, parents)
end

_v2f_is_identifier(view::V2ItemView, a::Int) =
    view.kinds[a] == JS2.K"Identifier" &&
    view.vals[a] isa Union{Symbol,AbstractString} &&
    !startswith(string(view.vals[a]), "@")

"""
    v2_item_row_at(rt, uri, offset0) -> Union{Nothing,V2ItemRow}

The skeleton item row whose whole-item range contains the (0-based) offset.
Both edges count as inside, so at the exact boundary between two abutting
items BOTH contain the offset; the tie goes to the EARLIER item iff one of
its identifiers ends exactly there (v1's preceding-identifier rule), else to
the later one.
"""
function v2_item_row_at(rt, uri::URI, offset0::Int)
    maps = derived_v2_file_maps(rt, uri)
    isempty(maps) && return nothing
    hits = V2ItemRow[]
    for row in derived_v2_file_skeleton(rt, uri).items
        ranges = get(maps, row.id, nothing)
        (ranges === nothing || isempty(ranges)) && continue
        _v2f_contains(ranges[1], offset0) && push!(hits, row)
    end
    isempty(hits) && return nothing
    length(hits) == 1 && return hits[1]
    sort!(hits; by=r -> r.order)
    earlier = hits[1]
    view = v2_item_view(rt, uri, earlier.id)
    if view !== nothing &&
       any(a -> _v2f_is_identifier(view, a) && _v2f_stop0(view.ranges[a]) == offset0,
           eachindex(view.ranges))
        return earlier
    end
    return hits[end]
end

"""
    v2_identifier_addr_at(view, offset0) -> Union{Nothing,Int}

The preorder address of the identifier leaf under the cursor, with v1's
`get_expr1` tie-breaks: both edges inclusive; when two identifiers touch at
the offset, the one ENDING there wins (cursor at an identifier's right edge
belongs to it); `@`-spelled macro-name leaves never match.
"""
function v2_identifier_addr_at(view::V2ItemView, offset0::Int)
    best = nothing
    best_ends_here = false
    for a in eachindex(view.ranges)
        _v2f_is_identifier(view, a) || continue
        r = view.ranges[a]
        _v2f_contains(r, offset0) || continue
        ends_here = _v2f_stop0(r) == offset0
        if best === nothing || (ends_here && !best_ends_here)
            best = a
            best_ends_here = ends_here
        end
    end
    return best
end
