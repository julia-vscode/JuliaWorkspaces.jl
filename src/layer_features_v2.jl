# v2-backed interactive features (experiment, behind `input_v2_enabled`):
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
    derived_has_content(rt, ref.file) || return nothing
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
# to the first string-family node and join its literal chunks. Raw parsed
# trees carry their leaf payload as `.value` (`.val` is the lowered-tree
# attribute — reading it here threw, and the throw fell back to the raw slice
# with its quote delimiters, which is how the bug surfaced on CRLF corpora).
function _v2f_string_value(st)
    JS2.is_leaf(st) && return JS2.kind(st) == JS2.K"String" ? string(st.value) : nothing
    if JS2.kind(st) == JS2.K"string"
        parts = String[]
        for c in JS2.children(st)
            (JS2.is_leaf(c) && JS2.kind(c) == JS2.K"String") || return nothing
            push!(parts, string(c.value))
        end
        return join(parts)
    end
    for c in JS2.children(st)
        v = _v2f_string_value(c)
        v === nothing || return v
    end
    return nothing
end

# ── document symbols ────────────────────────────────────────────────────────

"All identifier-leaf addresses in `view` spelling `name`."
function _v2f_name_leaf_addrs(view::V2ItemView, name::String)
    return [a for a in eachindex(view.ranges)
            if _v2f_is_identifier(view, a) && string(view.vals[a]) == name]
end

# Kind refinement for value-family items: v1 reports String(15)/Number(16)
# for literal-typed values and Function(12) for function-valued assignments
# via its type inference; v2 approximates from the RHS shape (declared
# degradation: inferred cases fall to Variable).
function _v2f_value_kind(body::Union{Nothing,BodyTree{V2Kind}})
    body === nothing && return 13
    inner = body
    while (inner.kind == JS2.K"const" || inner.kind == JS2.K"global") &&
          inner.children !== nothing && !isempty(inner.children)
        inner = inner.children[1]
    end
    (inner.kind == JS2.K"=" && inner.children !== nothing && length(inner.children) >= 2) || return 13
    rhs = inner.children[2]
    # Identifier leaves carry their NAME as a String val — only literal kinds
    # count (`plain = nothing` is a Variable, not a String).
    if rhs.children === nothing
        rhs.kind == JS2.K"String" && return 15
        (rhs.kind != JS2.K"Identifier" && rhs.val isa Number) && return 16
    end
    rhs.kind == JS2.K"string" && return 15
    (rhs.kind == JS2.K"->" || rhs.kind == JS2.K"function") && return 12
    return 13
end

# The macro name and first literal-string argument of an opaque macrocall
# body — the `@testset` title recovery (accepts both the begin-block and the
# for-loop forms; an interpolated title yields its first literal chunk).
function _v2f_macrocall_title(body::BodyTree{V2Kind})
    body.children === nothing && return nothing, nothing
    cs = body.children
    isempty(cs) && return nothing, nothing
    nm = cs[1].children === nothing ? cs[1].val : nothing
    name = nm isa Union{Symbol,AbstractString} ? string(nm) : nothing
    for c in cs[2:end]
        if c.children === nothing && c.kind == JS2.K"String" && c.val isa AbstractString
            return name, string(c.val)
        elseif c.kind == JS2.K"string" && c.children !== nothing
            for cc in c.children
                (cc.children === nothing && cc.val isa AbstractString) &&
                    return name, string(cc.val)
            end
            return name, ""
        end
    end
    return name, nothing
end

"""
    _get_document_symbols_v2(runtime, uri) -> Vector{DocumentSymbolResult}

The v2 arm of `_get_document_symbols` (layer_symbols.jl). Full lexical
fidelity: modules, items (shape-refined kinds), struct fields, type
parameters and locals (from the per-item lowering), and test-macro title
symbols — nested uniformly by RANGE CONTAINMENT (sort by start asc / width
desc, stack sweep), which reproduces v1's lexical nesting for modules,
`@testset` blocks, fields and locals alike. Declared deltas vs v1: locals
attach flat to their item (v1 nests arbitrarily deep); value-family ranges
cover the whole statement (v1 anchors the identifier); inference-based kinds
degrade to Variable. Test-macro BODIES contribute children through the
per-item lowering (test blocks materialize let-wrapped, so inner definitions
are the item's locals — kind 13 rather than v1's def kinds), and
`@testmodule`/`@testsnippet`/interpolated titles are covered BETTER than v1.
"""
function _get_document_symbols_v2(runtime, uri::URI)
    maps = derived_v2_file_maps(runtime, uri)
    isempty(maps) && return DocumentSymbolResult[]
    skel = derived_v2_file_skeleton(runtime, uri)
    inv = derived_v2_file_inventory(runtime, uri)
    bodies = derived_v2_file_bodies(runtime, uri)

    cands = @NamedTuple{start0::Int, stop0::Int, name::String, kind::Int}[]
    add!(r::UnitRange{Int}, name::String, kind::Int) =
        push!(cands, (start0=_v2f_start0(r), stop0=_v2f_stop0(r), name=name, kind=kind))
    whole(id) = (rs = get(maps, id, nothing); rs === nothing || isempty(rs) ? nothing : rs[1])

    for m in skel.modules
        r = whole(m.id)
        r === nothing || add!(r, m.name, 2)
    end

    for t in skel.testitems
        r = whole(t.id)
        r === nothing && continue
        mac = t.kind === :testitem ? "@testitem" :
              t.kind === :testsetup_module ? "@testmodule" : "@testsnippet"
        add!(r, "$mac \"$(t.label)\"", 3)
    end
    seen_member_addrs = Dict{Int64,Set{Int}}()   # per id: leaf addrs already used
    for it in inv.items
        if it.kind === :opaque_macrocall
            # `@testset` is an ISOLATED macro: one opaque item row (it is NOT
            # in `skeleton.opaque_macros`, and its body is never descended, so
            # it contributes no children). Its title symbol comes from the
            # stored body's first string argument.
            if it.name == "@testset"
                body = get(bodies, it.id, nothing)
                if body !== nothing
                    _, title = _v2f_macrocall_title(body)
                    r = whole(it.id)
                    (title !== nothing && r !== nothing) &&
                        add!(r, "@testset \"$title\"", 3)
                end
            end
            continue
        end
        isempty(it.name) && continue
        (!isempty(it.qualifier) && !Base.isidentifier(it.name)) && continue
        r = whole(it.id)
        r === nothing && continue
        view = nothing
        used = get!(() -> Set{Int}(), seen_member_addrs, it.id)

        if it.kind === :enum_member
            # Members anchor at their own identifier leaf inside the shared
            # `@enum` statement, so containment nests them under the enum.
            view = v2_item_view(runtime, uri, it.id)
            view === nothing && continue
            placed = false
            for a in _v2f_name_leaf_addrs(view, it.name)
                a in used && continue
                push!(used, a)
                add!(view.ranges[a], it.name, 22)
                placed = true
                break
            end
            placed || add!(r, it.name, 22)
            continue
        end

        kind = it.kind in (:const, :global, :assignment) ?
            _v2f_value_kind(get(bodies, it.id, nothing)) : _item_symbol_kind(it.kind)
        add!(r, it.name, kind)

        # Struct fields: kind 8 at each field's identifier leaf.
        if it.kind in (:struct, :mutable_struct) && !isempty(it.field_names)
            view = v2_item_view(runtime, uri, it.id)
            if view !== nothing
                # The struct's own name leaf must not be claimed as a field.
                nl = _v2f_name_leaf_addrs(view, it.name)
                isempty(nl) || push!(used, nl[1])
                for fname in it.field_names
                    for a in _v2f_name_leaf_addrs(view, fname)
                        a in used && continue
                        push!(used, a)
                        add!(view.ranges[a], fname, 8)
                        break
                    end
                end
            end
        end
    end

    # Type parameters and locals from the lowering, flat per item.
    for row in skel.items
        (row.kind === :opaque_macrocall || !row.interpretable || row.under_macrocall) && continue
        ref = V2ItemRef(uri, row.id)
        low = derived_item_lowering(runtime, ref)
        (low === nothing || low.status !== :ok) && continue
        view = v2_item_view(runtime, uri, row.id)
        view === nothing && continue
        emitted = Set{Tuple{String,Int32}}()
        for b in low.bindings
            (b.is_internal || b.is_ssa || b.addr == Int32(0)) && continue
            b.kind in (:local, :argument, :typevar, :static_parameter) || continue
            isempty(b.name) && continue
            (b.name, b.addr) in emitted && continue
            a = Int(b.addr)
            (1 <= a <= length(view.ranges) && _v2f_is_identifier(view, a) &&
             string(view.vals[a]) == b.name) || continue
            push!(emitted, (b.name, b.addr))
            add!(view.ranges[a], b.name,
                 b.kind in (:typevar, :static_parameter) ? 26 : 13)
        end
    end

    # Nest by range containment: start asc, width desc; stack sweep. EQUAL
    # ranges are SIBLINGS, never parent/child — shared-id statements (a tuple
    # destructure mints one candidate per name at the same range) must not
    # swallow each other.
    sort!(cands; by=c -> (c.start0, -(c.stop0 - c.start0)))
    results = DocumentSymbolResult[]
    stack = Tuple{Int,Int,DocumentSymbolResult}[]   # (start0, stop0, node)
    for c in cands
        while !isempty(stack) &&
              !(stack[end][1] <= c.start0 && c.stop0 <= stack[end][2] &&
                !(stack[end][1] == c.start0 && stack[end][2] == c.stop0))
            pop!(stack)
        end
        ds = DocumentSymbolResult(c.name, c.kind,
            _offset_to_position(runtime, uri, c.start0),
            _offset_to_position(runtime, uri, c.stop0),
            DocumentSymbolResult[])
        push!(isempty(stack) ? results : stack[end][3].children, ds)
        push!(stack, (c.start0, c.stop0, ds))
    end
    return results
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

# ── selection ranges + block range ──────────────────────────────────────────

"""
    v2_node_addr_at(view, offset0) -> Union{Nothing,Int}

The innermost node (any kind, not just identifiers) under the cursor:
smallest containing range; ties prefer a range ENDING exactly at the offset
(the `get_expr1` right-edge rule), then the later preorder address.
"""
function v2_node_addr_at(view::V2ItemView, offset0::Int)
    best = nothing
    bkey = (typemax(Int), true, 0)
    for a in eachindex(view.ranges)
        r = view.ranges[a]
        _v2f_contains(r, offset0) || continue
        key = (_v2f_stop0(r) - _v2f_start0(r), _v2f_stop0(r) != offset0, -a)
        if best === nothing || key < bkey
            best, bkey = a, key
        end
    end
    return best
end

"""
    _get_selection_ranges_v2(runtime, uri, offsets) -> Vector{Union{Nothing,SelectionRangeResult}}

The v2 arm of `_get_selection_ranges`: per offset, the innermost node's
parent chain within its item (consecutive duplicate ranges collapsed), then
synthetic outer links — enclosing module bodies and whole modules
(innermost-first, only when strictly widening) and finally the whole file.
Offsets with no item row (export statements, module headers, trivia) fall
back to the v1 CST path PER OFFSET. The chain's intermediate levels follow
the EST shape, not v1's CST shape — a declared, test-unpinned delta.
"""
function _get_selection_ranges_v2(runtime, uri::URI, offsets::Vector{Int})
    results = Union{Nothing,SelectionRangeResult}[]
    maps = derived_v2_file_maps(runtime, uri)
    skel = derived_v2_file_skeleton(runtime, uri)
    tf = input_text_file(runtime, uri)
    eof0 = tf === nothing ? 0 : ncodeunits(tf.content.content)
    cst = nothing
    for offset0 in offsets
        row = v2_item_row_at(runtime, uri, offset0)
        view = row === nothing ? nothing : v2_item_view(runtime, uri, row.id)
        if view === nothing
            cst === nothing && (cst = derived_julia_legacy_syntax_tree(runtime, uri))
            x = get_expr1(cst, offset0)
            push!(results, _get_selection_range_of_expr(x, runtime))
            continue
        end
        pairs = Tuple{Int,Int}[]
        a = v2_node_addr_at(view, offset0)
        a === nothing && (a = 1)
        while a != 0
            r = view.ranges[a]
            p = (_v2f_start0(r), _v2f_stop0(r))
            (isempty(pairs) || pairs[end] != p) && push!(pairs, p)
            a = Int(view.parents[a])
        end
        widen!(p) = (isempty(pairs) ||
            (p[1] <= pairs[end][1] && pairs[end][2] <= p[2] && p != pairs[end])) && push!(pairs, p)
        mods = [m for m in skel.modules
                if (rs = get(maps, m.id, nothing);
                    rs !== nothing && !isempty(rs) && _v2f_contains(rs[1], offset0))]
        sort!(mods; by=m -> -length(m.parent_module))
        for m in mods
            rs = maps[m.id]
            length(rs) >= 4 && widen!((_v2f_start0(rs[4]), _v2f_stop0(rs[4])))
            widen!((_v2f_start0(rs[1]), _v2f_stop0(rs[1])))
        end
        widen!((0, eof0))
        node = nothing
        for p in Iterators.reverse(pairs)
            node = SelectionRangeResult(_offset_to_position(runtime, uri, p[1]),
                                        _offset_to_position(runtime, uri, p[2]), node)
        end
        push!(results, node)
    end
    return results
end

# One module level's block candidates: every mapped, NON-degraded row spliced
# at exactly `pm`, deduped by id (an assignment-wrapped include has two rows
# sharing an id), with the effective start pulled back over the docstring —
# including its opening quote delimiter — when one exists (v1's top-level
# statement IS the doc wrapper, starting at the opening quotes). Degraded rows
# (inside `if` branches / macrocall arguments) are EXCLUDED wholesale: they
# are sub-statements of a statement that has no row of its own, and letting
# them in corrupts the window partition for their neighbors.
function _v2f_block_candidates(skel, maps, docs, text::String, pm::Vector{String})
    cands = @NamedTuple{start0::Int, stop0::Int, id::Int64, is_module::Bool}[]
    seen = Set{Int64}()
    function add!(id, is_module)
        id in seen && return
        rs = get(maps, id, nothing)
        (rs === nothing || isempty(rs)) && return
        push!(seen, id)
        s0 = _v2f_start0(rs[1])
        dr = get(docs, id, nothing)
        if dr !== nothing
            ds0 = _v2f_start0(dr)
            # The stored doc range covers the CONTENT; the wrapper begins at
            # the opening delimiter — scan back over the whitespace a
            # triple-quote opener leaves (`\"\"\"\n`), then the quotes.
            # Codeunit-wise: byte indexing must not trip on multibyte chars.
            j = ds0   # 1-based index of the byte just before the content
            while j >= 1 && codeunit(text, j) in
                  (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
                j -= 1
            end
            if j >= 3 && codeunit(text, j) == UInt8('"') &&
               codeunit(text, j - 1) == UInt8('"') && codeunit(text, j - 2) == UInt8('"')
                ds0 = j - 3
            elseif j >= 1 && codeunit(text, j) == UInt8('"')
                ds0 = j - 1
            end
            s0 = min(s0, ds0)
        end
        push!(cands, (start0=s0, stop0=_v2f_stop0(rs[1]), id=id, is_module=is_module))
    end
    for r in skel.items
        (r.parent_module == pm && !r.conditional && !r.under_macrocall) && add!(r.id, false)
    end
    for m in skel.modules
        m.parent_module == pm && add!(m.id, true)
    end
    for imp in skel.imports
        imp.parent_module == pm && add!(imp.id, false)
    end
    for inc in skel.includes
        inc.parent_module == pm && add!(inc.id, false)
    end
    for e in skel.exports
        e.parent_module == pm && add!(e.id, false)
    end
    sort!(cands; by=c -> c.start0)
    return cands
end

# Window selection: candidate i owns [start_i, start_{i+1}-1] (the GAP
# PARTITION standing in for v1's fullspan windows — CSTParser attaches
# trailing trivia to the preceding statement up to the next one's start);
# a cursor past the winning row's own stop bumps to the NEXT statement
# (v1's trailing-trivia rule). Returns `(cand, block_stop0)` or `nothing`.
function _v2f_block_pick(cands, offset0::Int, hi0::Int)
    isempty(cands) && return nothing
    idx = length(cands)
    for i in 1:(length(cands) - 1)
        if offset0 < cands[i + 1].start0
            idx = i
            break
        end
    end
    prebump_start0 = cands[idx].start0
    # Trailing-trivia bump — but the LAST statement keeps owning its trailing
    # region (v1's bump is guarded on a next statement existing).
    (offset0 > cands[idx].stop0 && idx < length(cands)) && (idx += 1)
    block_stop0 = idx < length(cands) ? cands[idx + 1].start0 : hi0
    return (cands[idx], block_stop0, prebump_start0)
end

"""
    _get_current_block_range_v2(runtime, uri, offset0)

The v2 arm of `_get_current_block_range`. Returns `:v1` to run the untouched
v1 body (no v2 root, empty maps, or a winner inside an `if` branch /
macrocall arguments — those rows are finer-grained than v1's whole-statement
answer). One level of module structure, exactly like v1: cursor in a module's
header or `end` region → the whole module; strictly inside the body → the
inner statement (an inner module returned whole, no recursion).
"""
function _get_current_block_range_v2(runtime, uri::URI, offset0::Int)
    derived_v2_best_root_for_uri(runtime, uri) === nothing && return :v1
    maps = derived_v2_file_maps(runtime, uri)
    isempty(maps) && return :v1
    skel = derived_v2_file_skeleton(runtime, uri)
    docs = derived_v2_file_doc_ranges(runtime, uri)
    tf = input_text_file(runtime, uri)
    tf === nothing && return :v1
    text = tf.content.content
    eof0 = ncodeunits(text)
    _pos(o) = _offset_to_position(runtime, uri, o)
    result(s0, h1, bs) = BlockRangeResult(_pos(s0), _pos(s0), _pos(h1), _pos(bs))

    # Degraded rows (inside `if` branches or macrocall arguments — including
    # `@inline function …`, whose row is under_macrocall) are sub-statements
    # of statements that have NO row of their own. Whenever the answer's
    # window would touch such a region, only v1 can produce the
    # whole-statement block — decline.
    degraded = Tuple{Int,Int}[]
    for r in skel.items
        (r.conditional || r.under_macrocall) || continue
        rs = get(maps, r.id, nothing)
        (rs === nothing || isempty(rs)) && continue
        lo = _v2f_start0(rs[1])
        # A documented degraded row's statement begins at its docstring.
        dr = get(docs, r.id, nothing)
        dr !== nothing && (lo = min(lo, max(_v2f_start0(dr) - 3, 0)))
        push!(degraded, (lo, _v2f_stop0(rs[1])))
    end
    touches_degraded(lo, hi) = any(d -> !(d[2] < lo || d[1] > hi), degraded)
    # The cursor sitting inside a degraded statement itself (including one
    # BEFORE the first candidate, where no window covers it) → v1.
    any(d -> d[1] <= offset0 <= d[2], degraded) && return :v1

    cands = _v2f_block_candidates(skel, maps, docs, text, String[])
    isempty(cands) && return :v1
    picked = _v2f_block_pick(cands, offset0, eof0)
    picked === nothing && return nothing
    c, block_stop0, prebump0 = picked
    # The degraded check spans from the PRE-BUMP window start: a cursor in the
    # trailing trivia of an unrepresented/degraded statement must not be
    # silently assigned to a neighbor.
    touches_degraded(min(prebump0, c.start0), block_stop0) && return :v1
    c.is_module || return result(c.start0, c.stop0, block_stop0)

    # Module: body range is preorder address 4 of the module's map.
    rs = maps[c.id]
    length(rs) < 4 && return result(c.start0, c.stop0, block_stop0)
    body_s0, body_e0 = _v2f_start0(rs[4]), _v2f_stop0(rs[4])
    (body_s0 < offset0 < body_e0) || return result(c.start0, c.stop0, block_stop0)

    m = only(filter(x -> x.id == c.id, skel.modules))
    inner_pm = vcat(m.parent_module, [m.name])
    inner = _v2f_block_candidates(skel, maps, docs, text, inner_pm)
    isempty(inner) && return :v1
    ip = _v2f_block_pick(inner, offset0, body_e0)
    ip === nothing && return nothing
    ic, iblock_stop0, iprebump0 = ip
    touches_degraded(min(iprebump0, ic.start0), iblock_stop0) && return :v1
    return result(ic.start0, ic.stop0, iblock_stop0)
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
    v2_global_occurrences(rt, uri, offset0) -> Union{Nothing,V2LocalOccurrences}

The SAME-FILE occurrence set of a module-level (global) name under the
cursor — the piece `v2_local_occurrences` deliberately declines. Name-keyed
over every item's lowering in the file, restricted to items spliced into the
SAME module as the cursor's (name-keying across modules would conflate
same-named globals). Declines, beyond the local resolver's gates: a cursor on
the right side of a `K"."` access (qualified members need target matching),
and any file whose import rows alias the name (`using X: f as g` — v1's
item-keyed join counts alias uses as references of the source; a name-keyed
answer would silently miss them). Only DOCUMENT HIGHLIGHT consumes this —
its v1 answer is file-confined by contract; references/rename are cross-file
and stay v1 for globals.
"""
function v2_global_occurrences(rt, uri::URI, offset0::Int)
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

    # Qualified member (`M.|name`): decline.
    p = Int(view.parents[addr])
    (p != 0 && view.kinds[p] == JS2.K"." && addr != p + 1) && return nothing

    # The cursor must resolve GLOBAL in its own item.
    used_here = Set{Int32}(u.binding for u in low.uses if u.addr == addr32)
    cursor_is_global = any(b -> b.name == name && b.kind === :global &&
                                (b.addr == addr32 || b.id in used_here), low.bindings)
    cursor_is_global || return nothing

    # Alias decline: any import row binding `name` through an `as` alias (or
    # aliasing `name` away) breaks the name-keyed join.
    skel = derived_v2_file_skeleton(rt, uri)
    for imp in skel.imports
        imp.alias == name && return nothing
        for s in imp.symbols
            (s.alias == name || (s.alias !== nothing && s.name == name)) && return nothing
        end
    end
    # Qualified-extension decline: `Base.hash(x::T) = …` in this file means
    # occurrences of `hash` split between the extended function and anything
    # local — v1 resolves them by TARGET; a name-keyed join cannot.
    for it in derived_v2_file_inventory(rt, uri).items
        (it.name == name && !isempty(it.qualifier)) && return nothing
    end

    occ = @NamedTuple{addr::Int32, range::UnitRange{Int}, write::Bool}[]
    cursor_range = view.ranges[addr]
    for r in skel.items
        r.parent_module == row.parent_module || continue
        (r.kind === :opaque_macrocall || !r.interpretable || r.under_macrocall) && continue
        rref = V2ItemRef(uri, r.id)
        isempty(derived_v2_item_expansion_sites(rt, rref)) || continue
        rlow = derived_item_lowering(rt, rref)
        (rlow === nothing || rlow.status !== :ok) && continue
        rview = r.id == row.id ? view : v2_item_view(rt, uri, r.id)
        rview === nothing && continue
        # A per-item :global binding's `addr` is its FIRST occurrence in that
        # item, not a real declaration site — only ASSIGNED bindings' addrs
        # count as write sites (`const LIMIT = 10` yes; a read-only use no).
        gids = Set{Int32}()
        addrs = Set{Int32}()
        decl_addrs = Set{Int32}()
        for b in rlow.bindings
            (b.name == name && b.kind === :global && !b.is_internal) || continue
            push!(gids, b.id)
            if b.addr != Int32(0)
                push!(addrs, b.addr)
                b.is_assigned && push!(decl_addrs, b.addr)
            end
        end
        isempty(gids) && continue
        for u in rlow.uses
            (u.binding in gids && u.addr != Int32(0)) && push!(addrs, u.addr)
        end
        n = length(rview.ranges)
        for a in sort!(collect(addrs))
            (1 <= a <= n) || continue
            ai = Int(a)
            (_v2f_is_identifier(rview, ai) && string(rview.vals[ai]) == name) || continue
            pp = Int(rview.parents[ai])
            write = (a in decl_addrs) ||
                (pp != 0 && rview.kinds[pp] == JS2.K"=" && ai == pp + 1)
            push!(occ, (addr=a, range=rview.ranges[ai], write=write))
        end
    end
    isempty(occ) && return nothing
    sort!(occ; by=o -> first(o.range))
    unique!(o -> o.range, occ)
    return V2LocalOccurrences(name, cursor_range, Int32[], occ)
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

# ── signature slicing (M3) ──────────────────────────────────────────────────
#
# Signatures are rendered by SLICING THE SOURCE at map ranges — byte-faithful
# to what the user wrote, with no printer to keep in sync — then normalizing
# whitespace so multi-line signatures read as one line. Plain functions, like
# everything in this file: the map is the volatile last-mile leaf.

"Slice `uri`'s text at 1-based exclusive-end range `r`, or `nothing`."
function _v2f_slice(rt, uri::URI, r::UnitRange{Int})
    derived_has_content(rt, uri) || return nothing
    tf = input_text_file(rt, uri)
    tf === nothing && return nothing
    text = tf.content.content
    (1 <= first(r) && last(r) - 1 <= ncodeunits(text)) || return nothing
    return text[first(r):(last(r) - 1)]
end

_v2f_normalize_ws(s::AbstractString) = String(strip(replace(s, r"\s+" => " ")))

"""
    v2_item_signature_text(rt, ref) -> Union{Nothing,String}

The item's signature AS WRITTEN, whitespace-normalized: for a method item the
whole left-hand side (wheres and return type kept), for a struct the whole
definition expression. `nothing` for items that carry neither.
"""
function v2_item_signature_text(rt, ref::V2ItemRef)
    body = derived_v2_item_body(rt, ref)
    body === nothing && return nothing
    ranges = get(derived_v2_file_maps(rt, ref.file), ref.id, nothing)
    (ranges === nothing || length(ranges) != bt_node_count(body)) && return nothing
    k = body.kind
    if k == JS2.K"struct" || k == JS2.K"abstract" || k == JS2.K"primitive"
        s = _v2f_slice(rt, ref.file, ranges[1])
        return s === nothing ? nothing : _v2f_normalize_ws(s)
    end
    (k == JS2.K"function" || k == JS2.K"macro" || k == JS2.K"=") || return nothing
    _v2_nchildren(body) >= 1 || return nothing
    # A short-form item must actually be a method definition — `x = 1` is an
    # assignment, not a signature. `function f end` (bare identifier child)
    # stays: its name IS its signature.
    if k == JS2.K"=" && _v2_func_sig(body) === nothing
        return nothing
    end
    length(ranges) >= 2 || return nothing
    s = _v2f_slice(rt, ref.file, ranges[2])   # child 1 = preorder address 2
    return s === nothing ? nothing : _v2f_normalize_ws(s)
end

# One rendered signature: the assembled label plus the UTF-16 `[start, end)`
# offset range of each positional parameter within it — `_assemble_signature`'s
# exact contract, so v2 labels and v1 labels share one shape.
const V2Signature = @NamedTuple{label::String, param_ranges::Vector{Tuple{Int,Int}}}

# The whitespace-normalized source slice of one signature entry, with the
# wrappers that say nothing about the call peeled: `@nospecialize(x)` yields
# `x`'s own slice, a `const` field marker its field's.
function _v2f_param_slice(rt, uri::URI, ranges, node::BodyTree{V2Kind}, addr::Int)
    if node.kind == JS2.K"macrocall" && _v2_macrocall_name(node) == "@nospecialize" &&
       _v2_nchildren(node) >= 3
        caddrs = _v2_child_addresses(node, addr)
        return _v2f_param_slice(rt, uri, ranges, _v2_children(node)[3], caddrs[3])
    end
    if node.kind == JS2.K"const" && _v2_nchildren(node) >= 1
        return _v2f_param_slice(rt, uri, ranges, _v2_children(node)[1], addr + 1)
    end
    1 <= addr <= length(ranges) || return nothing
    s = _v2f_slice(rt, uri, ranges[addr])
    return s === nothing ? nothing : _v2f_normalize_ws(s)
end

# Assemble one V2Signature from a sig call node at `call_addr`. Positional
# entries each get a label range; keywords appear after `;` in the label only
# (they are not selected by index) — both exactly as v1's
# `_expr_signature!`/`_assemble_signature` pair behaves.
function _v2f_signature_from_call(rt, uri::URI, ranges, call::BodyTree{V2Kind}, call_addr::Int)
    cs = _v2_children(call)
    isempty(cs) && return nothing
    caddrs = _v2_child_addresses(call, call_addr)
    callee = _v2f_param_slice(rt, uri, ranges, cs[1], caddrs[1])
    callee === nothing && return nothing
    # A functor signature `(io::IO)(x)` needs its parens back to read as a call.
    cs[1].kind == JS2.K"::" && (callee = string("(", callee, ")"))
    positional = String[]
    kwargs = String[]
    for i in 2:length(cs)
        if cs[i].kind == JS2.K"parameters"
            paddrs = _v2_child_addresses(cs[i], caddrs[i])
            for (j, p) in enumerate(_v2_children(cs[i]))
                s = _v2f_param_slice(rt, uri, ranges, p, paddrs[j])
                s === nothing && return nothing
                push!(kwargs, s)
            end
        else
            s = _v2f_param_slice(rt, uri, ranges, cs[i], caddrs[i])
            s === nothing && return nothing
            push!(positional, s)
        end
    end
    label, prange = _assemble_signature(callee, positional; kwargs=kwargs)
    return (label=label, param_ranges=prange)::V2Signature
end

"""
    v2_item_signature_params(rt, ref) -> Vector{V2Signature}

Every callable signature the item offers, from source slices: a method item's
own signature (wheres and return types dropped — the call site doesn't spell
them); a struct's inner constructors, or, absent any, its implicit field
constructor. Empty for non-callables and for `function f end`.
"""
function v2_item_signature_params(rt, ref::V2ItemRef)
    out = V2Signature[]
    body = derived_v2_item_body(rt, ref)
    body === nothing && return out
    ranges = get(derived_v2_file_maps(rt, ref.file), ref.id, nothing)
    (ranges === nothing || length(ranges) != bt_node_count(body)) && return out

    k = body.kind
    if k == JS2.K"function" || k == JS2.K"macro" || k == JS2.K"="
        siginfo = _v2_sig_with_addr(body, 1)
        siginfo === nothing && return out
        call, call_addr, _ = siginfo
        sig = _v2f_signature_from_call(rt, ref.file, ranges, call, call_addr)
        sig === nothing || push!(out, sig)
        return out
    end
    k == JS2.K"struct" || return out
    cs = _v2_children(body)
    length(cs) >= 3 || return out
    caddrs = _v2_child_addresses(body, 1)
    block = cs[3]
    baddrs = _v2_child_addresses(block, caddrs[3])

    # Inner constructors first: with any function definition present (even a
    # sig-less `function S end`) there is no implicit field constructor to
    # offer — v1's `any(defines_function, …)` gate.
    has_ctor = false
    for (j, f) in enumerate(_v2_children(block))
        si = _v2_sig_with_addr(f, baddrs[j])
        if si === nothing
            (f.kind == JS2.K"function" || f.kind == JS2.K"macro") && (has_ctor = true)
            continue
        end
        has_ctor = true
        sig = _v2f_signature_from_call(rt, ref.file, ranges, si[1], si[2])
        sig === nothing || push!(out, sig)
    end
    has_ctor && return out

    # The implicit constructor: the struct's name (subtype clause dropped,
    # curly parameters kept) applied to its fields; docstrings are not fields.
    namenode, nameaddr = cs[2], caddrs[2]
    while namenode.kind == JS2.K"<:" && _v2_nchildren(namenode) >= 1
        namenode, nameaddr = _v2_children(namenode)[1], nameaddr + 1
    end
    callee = _v2f_param_slice(rt, ref.file, ranges, namenode, nameaddr)
    callee === nothing && return out
    fields = String[]
    for (j, f) in enumerate(_v2_children(block))
        (f.kind == JS2.K"String" || f.kind == JS2.K"string") && continue
        s = _v2f_param_slice(rt, ref.file, ranges, f, baddrs[j])
        s === nothing && return out
        push!(fields, s)
    end
    label, prange = _assemble_signature(callee, fields)
    push!(out, (label=label, param_ranges=prange)::V2Signature)
    return out
end

# ── hover (M3) ──────────────────────────────────────────────────────────────
#
# The v2 hover arm owns exactly the cases whose v1 answer is type-free and
# reproducible from slices: a module-level FUNCTION name (docstring + one
# ```julia block per method, in splice order) and a MODULE name (docstring +
# the compact block). Everything else — locals (v1 renders inferred types),
# datatypes (v1 prints the canonical Expr; a comment-preserving slice can't
# match beyond whitespace), store names, argument positions (the "Argument i
# of n" prefix), macros, qualified members — DECLINES to the untouched v1
# path by returning `nothing`.

# Does the identifier at `addr` sit anywhere v1 would render extra context or
# v2 cannot resolve reliably: an argument slot of a call/do, a macrocall's
# arguments, or quoted code?
function _v2f_hover_position_declines(view::V2ItemView, addr::Int)
    child = addr
    p = Int(view.parents[addr])
    while p != 0
        k = view.kinds[p]
        if k == JS2.K"call"
            child == p + 1 || return true      # an argument, not the callee
        elseif k == JS2.K"do" || k == JS2.K"macrocall" ||
               k == JS2.K"quote" || k == JS2.K"syntaxquote" || k == JS2.K"inert"
            return true
        end
        child = p
        p = Int(view.parents[p])
    end
    return false
end

# The raw (as-written, whitespace-preserved) signature slice of a method item,
# or `nothing` when the item is not signature-shaped.
function _v2f_raw_sig_slice(rt, ref::V2ItemRef)
    body = derived_v2_item_body(rt, ref)
    body === nothing && return nothing
    k = body.kind
    (k == JS2.K"function" || k == JS2.K"=") || return nothing
    (k == JS2.K"=" && _v2_func_sig(body) === nothing) && return nothing
    _v2_nchildren(body) >= 1 || return nothing
    ranges = get(derived_v2_file_maps(rt, ref.file), ref.id, nothing)
    (ranges === nothing || length(ranges) < 2) && return nothing
    return _v2f_slice(rt, ref.file, ranges[2])
end

"""
    _get_hover_v2(rt, uri, offset0) -> Union{Nothing,String}

The v2 hover answer for the identifier at the (0-based) cursor, or `nothing`
to decline to v1. Rendering matches v1's tree-ref path byte for byte on the
covered cases: the per-method docstring + ```julia signature blocks (via
`_ensure_ends_with`, so an undocumented first method opens with a newline
exactly as v1 does), the compact module block, the exported/public footer,
and the final `_sanitize_docstring` pass.
"""
function _get_hover_v2(rt, uri::URI, offset0::Int)
    root = derived_v2_best_root_for_uri(rt, uri)
    root === nothing && return nothing
    row = v2_item_row_at(rt, uri, offset0)
    row === nothing && return nothing
    (row.kind === :opaque_macrocall || row.kind === :macrocall) && return nothing
    (row.interpretable && !row.under_macrocall) || return nothing
    ref = V2ItemRef(uri, row.id)
    isempty(derived_v2_item_expansion_sites(rt, ref)) || return nothing
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return nothing
    view = v2_item_view(rt, uri, row.id)
    view === nothing && return nothing
    addr = v2_identifier_addr_at(view, offset0)
    addr === nothing && return nothing
    name = string(view.vals[addr])

    # Qualified member (`M.|name`): the member side needs target matching.
    p = Int(view.parents[addr])
    (p != 0 && view.kinds[p] == JS2.K"." && addr != p + 1) && return nothing
    _v2f_hover_position_declines(view, addr) && return nothing

    # The name at its own DEFINITION SITE declines: v1 deliberately renders
    # the same-file binding view there (same-file methods only, no export
    # footer) — a different answer than its own cross-file rendering, and one
    # v2 does not reproduce.
    body = derived_v2_item_body(rt, ref)
    if body !== nothing
        siginfo = _v2_sig_with_addr(body, 1)
        if siginfo !== nothing
            call, call_addr, _ = siginfo
            callee = _v2_children(call)[1]
            callee_addr = call_addr + 1
            (callee_addr <= addr < callee_addr + bt_node_count(callee)) && return nothing
        end
    end

    # A name that resolves to a local/argument/typevar in this item is v1's
    # (its hover renders inferred types v2 does not compute).
    addr32 = Int32(addr)
    used_here = Set{Int32}(u.binding for u in low.uses if u.addr == addr32)
    any(b -> b.name == name && b.kind !== :global && !b.is_internal &&
             (b.addr == addr32 || b.id in used_here), low.bindings) && return nothing

    path = vcat(_derived_v2_splice_prefix(rt, uri), row.parent_module)
    face = get(derived_v2_module_visible_names_idfree(rt, root, path), name, nothing)
    face === nothing && return nothing
    (face.origin === :declared || face.origin === :using_tree) || return nothing

    if face.kind === :module
        mref = derived_v2_visible_item(rt, root, path, name)
        # Declared in the CURSOR's file → v1 renders its same-file binding
        # view (no export footer), a different answer than its cross-file
        # rendering; only the cross-file case is reproduced.
        (mref !== nothing && mref.file == uri) && return nothing
        doc = mref === nothing ? nothing : v2_item_docstring(rt, mref)
        documentation = _module_ref_hover(doc === nothing ? "" : doc, name)
        documentation = string(documentation, _v2f_api_footer(rt, root, face.origin_module, name))
        return _sanitize_docstring(documentation)
    end

    face.kind === :function || return nothing
    # A workspace function that also extends an external store function
    # renders unified with the store in v1 — decline the partial view.
    name in derived_v2_partial_method_names(rt, root) && return nothing

    items = derived_v2_method_items(rt, root, face.origin_module, name)
    isempty(items) && return nothing
    # Any method declared in the CURSOR's file → v1 renders its same-file
    # binding view (same-file methods only, no export footer); only the
    # cross-file TreeRef rendering is reproduced.
    any(mref -> mref.file == uri, items) && return nothing
    documentation = ""
    for mref in items
        slice = _v2f_raw_sig_slice(rt, mref)
        slice === nothing && return nothing   # a non-function method item: decline whole
        d = v2_item_docstring(rt, mref)
        d === nothing || (documentation = string(documentation, d))
        documentation = string(_ensure_ends_with(documentation), "```julia\n", slice, "\n```\n")
    end
    documentation = string(documentation, _v2f_api_footer(rt, root, face.origin_module, name))
    return _sanitize_docstring(documentation)
end

# v1's workspace exported/public footer, from the v2 module node: exported →
# footer, public → footer, internal workspace name → none.
function _v2f_api_footer(rt, root, origin_module::Vector{String}, name::String)
    node = v2_module_node(derived_v2_module_tree(rt, root), origin_module)
    node === nothing && return ""
    status = name in node.exports ? :exported : name in node.publics ? :public : nothing
    status === nothing && return ""
    modname = isempty(origin_module) ? nothing : Symbol(last(origin_module))
    return _status_footer(status, modname)
end

# ── signature help (M3) ─────────────────────────────────────────────────────

"The BodyTree node at preorder address `addr` (root = 1), or `nothing`."
function _v2f_node_at(bt::BodyTree{V2Kind}, addr::Int)
    addr == 1 && return bt
    a = 1
    node = bt
    while node.children !== nothing
        found = false
        for c in node.children
            n = bt_node_count(c)
            if a + 1 <= addr <= a + n
                a += 1
                if a == addr
                    return c
                end
                node = c
                found = true
                break
            end
            a += n
        end
        found || return nothing
    end
    return nothing
end

"""
    _get_signature_help_v2(runtime, uri, offset0) -> Union{Nothing,SignatureResult}

The v2 signature-help answer for the innermost call containing the (0-based)
cursor, or `nothing` to decline to v1. Owns WORKSPACE callees only (declared
or tree-imported functions/structs, qualified through the module-target
ledger): labels and parameter ranges come from `v2_item_signature_params`
(source slices through `_assemble_signature`, the same label/offset contract
as v1). Store/external callees, locally-shadowed callees, store-extending
names, definition signatures, do-blocks and macro/quote contexts decline; a
cursor on the closing paren declines too (v1 answers empty there).

The active parameter mirrors v1's shipped rule exactly: 0 while the cursor
sits at/before the opening paren, else the call's total top-level comma count
(v1 counts the call node's COMMA trivia, cursor-independent).
"""
function _get_signature_help_v2(runtime, uri::URI, offset0::Int)
    root = derived_v2_best_root_for_uri(runtime, uri)
    root === nothing && return nothing
    row = v2_item_row_at(runtime, uri, offset0)
    row === nothing && return nothing
    (row.kind === :opaque_macrocall || row.kind === :macrocall) && return nothing
    (row.interpretable && !row.under_macrocall) || return nothing
    ref = V2ItemRef(uri, row.id)
    isempty(derived_v2_item_expansion_sites(runtime, ref)) || return nothing
    low = derived_item_lowering(runtime, ref)
    (low === nothing || low.status !== :ok) && return nothing
    view = v2_item_view(runtime, uri, row.id)
    view === nothing && return nothing

    # Innermost call containing the cursor. A call ENDING exactly at the
    # cursor is behind it, not around it — the cursor after `g(h(1),` sits in
    # the outer call, and after the only call's `)` there is no call at all
    # (v1 answers empty there; the decline reproduces that).
    call_addr = nothing
    best = typemax(Int)
    for a in eachindex(view.ranges)
        view.kinds[a] == JS2.K"call" || continue
        r = view.ranges[a]
        _v2f_contains(r, offset0) || continue
        _v2f_stop0(r) == offset0 && continue
        w = _v2f_stop0(r) - _v2f_start0(r)
        if w < best
            best = w
            call_addr = a
        end
    end
    call_addr === nothing && return nothing

    body = derived_v2_item_body(runtime, ref)
    body === nothing && return nothing
    siginfo = _v2_sig_with_addr(body, 1)
    (siginfo !== nothing && siginfo[2] == call_addr) && return nothing
    p = Int(view.parents[call_addr])
    (p != 0 && view.kinds[p] == JS2.K"do") && return nothing
    pp = p
    while pp != 0
        k = view.kinds[pp]
        (k == JS2.K"macrocall" || k == JS2.K"quote" ||
         k == JS2.K"syntaxquote" || k == JS2.K"inert") && return nothing
        pp = Int(view.parents[pp])
    end

    call = _v2f_node_at(body, call_addr)
    (call === nothing || call.children === nothing || isempty(call.children)) && return nothing
    callee = call.children[1]
    qual, name = _v2_qualified_name(callee)
    (name === nothing || isempty(name) || startswith(name, ".")) && return nothing

    # A callee lowering resolved to a local/argument shadows the global.
    callee_addr32 = Int32(call_addr + 1)
    binding_of = Dict{Int32,LoweredBinding}(b.id => b for b in low.bindings)
    for u in low.uses
        u.addr == callee_addr32 || continue
        b = get(binding_of, u.binding, nothing)
        (b !== nothing && !b.is_internal &&
         (b.kind === :local || b.kind === :argument)) && return nothing
    end

    path = vcat(_derived_v2_splice_prefix(runtime, uri), row.parent_module)
    origin = nothing
    if isempty(qual)
        face = get(derived_v2_module_visible_names_idfree(runtime, root, path), name, nothing)
        face === nothing && return nothing
        (face.origin === :declared || face.origin === :using_tree) || return nothing
        face.kind in (:function, :struct, :mutable_struct) || return nothing
        origin = face.origin_module
    else
        _, modtargets = _v2_visible_names_pass1(runtime, root, path, Set{URI}())
        mt = get(modtargets, qual[1], nothing)
        (mt === nothing || mt.sort !== :tree) && return nothing
        origin = copy(mt.path)
        tree = derived_v2_module_tree(runtime, root)
        modpaths = Set{Vector{String}}(n.path for n in tree.modules)
        for seg in qual[2:end]
            push!(origin, seg)
            origin in modpaths || return nothing
        end
    end
    name in derived_v2_partial_method_names(runtime, root) && return nothing

    items = derived_v2_method_items(runtime, root, origin, name)
    isempty(items) && return nothing
    sigs = SignatureInfo[]
    for mref in items
        for s in v2_item_signature_params(runtime, mref)
            push!(sigs, SignatureInfo(s.label, "",
                ParameterInfo[ParameterInfo(r, nothing) for r in s.param_ranges]))
        end
    end
    isempty(sigs) && return nothing

    # v1's active-parameter rule: LPAREN → 0, else the call's comma count.
    tf = input_text_file(runtime, uri)
    tf === nothing && return nothing
    text = tf.content.content
    call_range = view.ranges[call_addr]
    child_addrs = _v2_child_addresses(call, call_addr)
    child_ranges = [view.ranges[a] for a in child_addrs if 1 <= a <= length(view.ranges)]
    commas = 0
    for i in first(call_range):(last(call_range) - 1)
        i <= ncodeunits(text) || break
        codeunit(text, i) == UInt8(',') || continue
        any(r -> first(r) <= i <= last(r) - 1, child_ranges) && continue
        commas += 1
    end
    lparen_pos0 = _v2f_stop0(view.ranges[call_addr + 1]) + 1
    arg = offset0 <= lparen_pos0 ? 0 : commas

    filtered = arg == 0 ? sigs : filter(s -> length(s.parameters) > arg, sigs)
    return SignatureResult(filtered, 0, arg)
end
