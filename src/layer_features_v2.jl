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

# ── docstrings (A2) ─────────────────────────────────────────────────────────

"The byte range of `id`'s docstring literal in `uri`, or `nothing`."
v2_item_doc_range(rt, uri::URI, id::Int64) =
    get(derived_v2_file_doc_ranges(rt, uri), id, nothing)

"""
    v2_item_docstring(rt, ref) -> Union{Nothing,String}

The docstring text of one v2 item, recovered at REQUEST time: the walker
stores only the literal's byte range (`derived_v2_file_doc_ranges`), and this
helper slices the file and parses the tiny slice for the literal's value —
the same last-mile contract as v1's `item_documentation` (docs never enter
derived values, so a docstring edit backdates everything but this). Plain
function, never derived.
"""
function v2_item_docstring(rt, ref::V2ItemRef)
    r = v2_item_doc_range(rt, ref.file, ref.id)
    r === nothing && return nothing
    tf = input_text_file(rt, ref.file)
    tf === nothing && return nothing
    text = tf.content.content
    (1 <= first(r) && last(r) - 1 <= ncodeunits(text)) || return nothing
    slice = text[first(r):(last(r) - 1)]
    return try
        st = JS2.parseall(JS2.SyntaxTree, slice)
        v = _v2f_string_value(st)
        v === nothing ? slice : v
    catch err
        err isa InterruptException && rethrow()
        slice
    end
end

# The literal string value of a parsed slice: descend through wrapper nodes
# to the first string-family node and join its literal chunks.
function _v2f_string_value(st)
    JS2.is_leaf(st) && return JS2.kind(st) == JS2.K"String" ? string(st.val) : nothing
    if JS2.kind(st) == JS2.K"string"
        parts = String[]
        for c in JS2.children(st)
            (JS2.is_leaf(c) && JS2.kind(c) == JS2.K"String") || return nothing
            push!(parts, string(c.val))
        end
        return join(parts)
    end
    for c in JS2.children(st)
        v = _v2f_string_value(c)
        v === nothing || return v
    end
    return nothing
end

# ── workspace symbols ───────────────────────────────────────────────────────

# The v2 arm of `_get_workspace_symbols` (layer_symbols.jl): same enumeration,
# same query/kind rules (`_symbol_matches_query` / `_item_symbol_kind`), off
# the v2 inventory with ranges from the volatile maps. The parity contract is
# (name, uri, range); kind is deliberately outside it.
function _get_workspace_symbols_v2(runtime, query::String)
    results = WorkspaceSymbolResult[]
    for uri in derived_text_files(runtime)
        derived_v2_best_root_for_uri(runtime, uri) === nothing && continue
        inv = derived_v2_file_inventory(runtime, uri)
        (isempty(inv.items) && isempty(inv.modules)) && continue
        maps = derived_v2_file_maps(runtime, uri)

        for it in inv.items
            it.kind === :opaque_macrocall && continue
            isempty(it.name) && continue
            # Qualified method extensions ARE listed under their bare name
            # (v1 parity: `Base.foo(…) = …` shows as `foo`) — except
            # operator-spelled ones (`Base.:(==)`), which v1's name extraction
            # drops; mirror that with an identifier check.
            (!isempty(it.qualifier) && !Base.isidentifier(it.name)) && continue
            _symbol_matches_query(it.name, query) || continue
            ranges = get(maps, it.id, nothing)
            (ranges === nothing || isempty(ranges)) && continue
            push!(results, WorkspaceSymbolResult(
                it.name, _item_symbol_kind(it.kind), uri,
                _offset_to_position(runtime, uri, _v2f_start0(ranges[1])),
                _offset_to_position(runtime, uri, _v2f_stop0(ranges[1]))))
        end
        for m in inv.modules
            _symbol_matches_query(m.name, query) || continue
            ranges = get(maps, m.id, nothing)
            (ranges === nothing || isempty(ranges)) && continue
            push!(results, WorkspaceSymbolResult(
                m.name, 2, uri,   # 2 = Module
                _offset_to_position(runtime, uri, _v2f_start0(ranges[1])),
                _offset_to_position(runtime, uri, _v2f_stop0(ranges[1]))))
        end
    end
    return results
end

# ── document links ──────────────────────────────────────────────────────────

function _v2f_walk_links!(links, bt::BodyTree{V2Kind}, addr::Base.RefValue{Int},
                          ranges::Vector{UnitRange{Int}}, fpath::String, st)
    my = (addr[] += 1)
    if bt.children === nothing
        if bt.kind == JS2.K"String" && bt.val isa String &&
           isvalid(bt.val) && sizeof(bt.val) < 256
            val = bt.val
            r = ranges[my]
            try
                if isabspath(val) && safe_isfile(val)
                    push!(links, DocumentLinkResult(position_at(st, first(r)),
                        position_at(st, last(r)), URIs2.filepath2uri(val)))
                elseif !isempty(fpath) && safe_isfile(joinpath(_dirname(fpath), val))
                    push!(links, DocumentLinkResult(position_at(st, first(r)),
                        position_at(st, last(r)),
                        URIs2.filepath2uri(joinpath(_dirname(fpath), val))))
                end
            catch err
                isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
            end
        end
        return nothing
    end
    for c in bt.children
        _v2f_walk_links!(links, c, addr, ranges, fpath, st)
    end
    return nothing
end

# The v2 arm of `_get_document_links` (layer_misc.jl): v1 parity — ANY string
# literal naming an existing file (absolute, or relative to the file's dir)
# becomes a link; not tightened to real includes. Walks every stored body
# (items AND include rows, the latter stored since this milestone). Known
# deviation: docstring contents produce no links — the walker's doc-wrapper
# transparency drops the string part from item bodies.
function _get_document_links_v2(runtime, uri::URI)
    links = DocumentLinkResult[]
    tf = input_text_file(runtime, uri)
    tf === nothing && return links
    st = tf.content
    fpath = something(URIs2.uri2filepath(uri), "")
    maps = derived_v2_file_maps(runtime, uri)
    bodies = derived_v2_file_bodies(runtime, uri)
    for id in sort!(collect(keys(bodies)))
        body = bodies[id]
        ranges = get(maps, id, nothing)
        ranges === nothing && continue
        bt_node_count(body) == length(ranges) || continue
        _v2f_walk_links!(links, body, Ref(0), ranges, fpath, st)
    end
    return links
end

# ── module-at-position ──────────────────────────────────────────────────────

# The v2 arm of `_get_module_at` (layer_navigation.jl). Module rows carry maps
# whose preorder prefix is fixed — `[module, bare-flag, name, block]` — so
# `ranges[4]` is the body block. A module contributes its own name only when
# the offset is STRICTLY inside that body (`start0 < o <= stop0`, mirroring
# `_get_expr_or_parent`'s convention): a cursor on the `module` keyword, the
# name, or `end` attributes to the ENCLOSING module, reproducing v1's header
# corrections in range terms. Innermost (longest-chain) qualifying row wins.
function _get_module_at_v2(runtime, uri::URI, offset0::Int)
    root = derived_v2_best_root_for_uri(runtime, uri)
    root === nothing && return "Main"
    prefix = derived_v2_file_module_path(runtime, root, uri)
    prefix === nothing && (prefix = String[])
    maps = derived_v2_file_maps(runtime, uri)
    best = String[]
    for m in derived_v2_file_skeleton(runtime, uri).modules
        ranges = get(maps, m.id, nothing)
        (ranges === nothing || length(ranges) < 4) && continue
        _v2f_contains(ranges[1], offset0) || continue
        body = ranges[4]
        # Strict at BOTH edges: the block's mapped range can reach into the
        # `end` keyword's region, and a cursor there belongs to the enclosing
        # module (v1's header/end correction).
        (_v2f_start0(body) < offset0 < _v2f_stop0(body)) || continue
        chain = vcat(m.parent_module, [m.name])
        length(chain) > length(best) && (best = chain)
    end
    names = vcat(prefix, best)
    return isempty(names) ? "Main" : join(names, ".")
end

const _V2_LOCAL_BINDING_KINDS = (:local, :argument, :static_parameter, :typevar)

"""
    V2LocalOccurrences

The resolved occurrence set of one LOCAL binding group: every identifier
occurrence (declaration sites and uses) with its byte range and a
read/write classification, plus the cursor identifier's own range for
prepare-rename.
"""
struct V2LocalOccurrences
    name::String
    cursor_range::UnitRange{Int}
    decl_addrs::Vector{Int32}
    occ::Vector{@NamedTuple{addr::Int32, range::UnitRange{Int}, write::Bool}}
end

"""
    v2_local_occurrences(rt, uri, offset0) -> Union{Nothing,V2LocalOccurrences}

Resolve the identifier under the (0-based) cursor as a LOCAL binding of its
item via the v2 lowering, or return `nothing` — in which case the caller runs
the untouched v1 path. `nothing` covers, deliberately: no item / opaque or
degraded items (under-macrocall, expansion sites, failed lowering) / no
identifier at the cursor / the name resolving to a global (module-level names
keep the v1 `:tree` route) / quoted identifiers (their fabricated reads
anchor at the quote's address, so they never match) / groups with no
user-visible declaration site.

Lowering desugars one source declaration into several bindings sharing its
declaration address (kwarg forwarding methods, comprehension closures, the
`where`-param typevar/static_parameter pair) — the group is merged by
(name, declaration address), which is what unifies a `where` param's
signature and body occurrences. Occurrences are filtered to addresses that
ARE identifier leaves spelling the name, so a rename can never touch a
non-name token. `write` = a declaration site, or the first child of a `K"="`
assignment; compound assignment (`+=`) occurrences report `read` — a
documented approximation.
"""
function v2_local_occurrences(rt, uri::URI, offset0::Int)
    row = v2_item_row_at(rt, uri, offset0)
    row === nothing && return nothing
    (row.kind === :opaque_macrocall || !row.interpretable || row.under_macrocall) && return nothing
    ref = V2ItemRef(uri, row.id)
    isempty(derived_v2_item_expansion_sites(rt, ref)) || return nothing
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return nothing
    view = v2_item_view(rt, uri, row.id)
    view === nothing && return nothing
    addr = v2_identifier_addr_at(view, offset0)
    addr === nothing && return nothing
    name = string(view.vals[addr])
    addr32 = Int32(addr)

    used_here = Set{Int32}(u.binding for u in low.uses if u.addr == addr32)
    decl_set = Set{Int32}()
    for b in low.bindings
        b.name == name || continue
        b.kind in _V2_LOCAL_BINDING_KINDS || continue
        (b.is_internal || b.is_ssa) && continue
        (b.addr == addr32 || b.id in used_here) || continue
        push!(decl_set, b.addr)
    end
    isempty(decl_set) && return nothing

    group_ids = Set{Int32}()
    decl_addrs = Int32[]
    for b in low.bindings
        b.name == name || continue
        b.kind in _V2_LOCAL_BINDING_KINDS || continue
        b.is_internal && continue
        b.addr in decl_set || continue
        push!(group_ids, b.id)
        (b.addr != Int32(0) && !(b.addr in decl_addrs)) && push!(decl_addrs, b.addr)
    end
    isempty(decl_addrs) && return nothing   # no user-visible declaration site

    occ_addrs = Set{Int32}(decl_addrs)
    for u in low.uses
        (u.binding in group_ids && u.addr != Int32(0)) && push!(occ_addrs, u.addr)
    end
    n = length(view.ranges)
    occ = @NamedTuple{addr::Int32, range::UnitRange{Int}, write::Bool}[]
    for a in sort!(collect(occ_addrs))
        1 <= a <= n || continue
        ai = Int(a)
        _v2f_is_identifier(view, ai) || continue
        string(view.vals[ai]) == name || continue
        p = Int(view.parents[ai])
        write = (a in decl_addrs) ||
            (p != 0 && view.kinds[p] == JS2.K"=" && ai == p + 1)
        push!(occ, (addr=a, range=view.ranges[ai], write=write))
    end
    isempty(occ) && return nothing
    sort!(occ; by=o -> first(o.range))
    return V2LocalOccurrences(name, view.ranges[addr], decl_addrs, occ)
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
