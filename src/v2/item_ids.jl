# Content-addressed item identity for the v2 walker.
#
# An item id identifies a top-level STATEMENT by what it declares, not by where
# it sits, so inserting a line above a definition does not renumber everything
# below it. The key is a HINT: statements sharing a key are separated by a
# disambiguator, so a coarse — or even wrong — key costs id stability, never
# uniqueness. If every statement keyed the same, ids would degrade to dense
# positional numbering.
#
# v1's `layer_inventory.jl` uses the same SCHEME, deliberately not the same code:
# v2 owns its identity machinery outright so that the two pipelines can evolve
# (and v1 can eventually be deleted) without either reaching into the other.
#
# The two ID SPACES are separate regardless — the walkers enumerate different
# statement sets over different parsers — which is why v2 carries its own
# `V2ItemRef` rather than reusing `ItemRef`. Never compare ids across pipelines.
#
# Names are `V2`/`_v2_`-prefixed because src/v2/*.jl is included into the same
# module as v1: `_IdKey`, `_ItemIdAllocator` and `_mint_ids!` are already taken.

"An identity key for one top-level statement: coarse kind, name as written (qualifier included), in-file module path."
const _V2IdKey = Tuple{Symbol,String,String}

# An id is a 62-bit quantity, so every step that builds one is explicitly
# `Int64`/`UInt64` rather than `Int`: on a 32-bit platform `Int === Int32`, where
# `1 << 46` is undefined and the packed value would not fit. `hash` also returns
# `UInt32` there, so it is widened before masking — that costs collision
# resistance on 32-bit, which the assigned-id probe below absorbs.
const _V2_ID_HASH_BITS = 46
const _V2_ID_DIS_BITS = 16
const _V2_ID_HASH_MASK = (UInt64(1) << _V2_ID_HASH_BITS) - UInt64(1)
const _V2_ID_DIS_MAX = Int64(1 << _V2_ID_DIS_BITS) - Int64(1)

# Per-file id allocation state. `order` is the dense visit counter (a genuine
# machine `Int`); `buckets` counts earlier statements per identity key;
# `assigned` keeps ids unique within the file when a hash collides or a bucket
# overflows its 16 bits.
mutable struct _V2ItemIdAllocator
    order::Int
    buckets::Dict{_V2IdKey,Int}
    assigned::Set{Int64}
end
_V2ItemIdAllocator() = _V2ItemIdAllocator(0, Dict{_V2IdKey,Int}(), Set{Int64}())

"""
    _v2_mint_ids!(alloc, key) -> (order, id)

Mint the `(order, id)` pair for one statement. Called exactly once per visited
statement, so every record the walker derives from it shares both.
"""
function _v2_mint_ids!(alloc::_V2ItemIdAllocator, key::_V2IdKey)
    alloc.order += 1

    n = get(alloc.buckets, key, 0)
    alloc.buckets[key] = n + 1

    h = (hash(key) % UInt64) & _V2_ID_HASH_MASK
    id = (Int64(h) << _V2_ID_DIS_BITS) | min(Int64(n), _V2_ID_DIS_MAX)
    while id in alloc.assigned
        id += Int64(1)
    end
    push!(alloc.assigned, id)

    return alloc.order, id
end
