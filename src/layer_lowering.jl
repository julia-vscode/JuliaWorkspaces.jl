# Lowering layer: runs the vendored JuliaLowering analysis passes (macro
# expansion SKIPPED — macrocalls are opaque placeholders until DJP-side
# expansion exists) over per-item value trees built with the vendored
# JuliaSyntax v2 parser.
#
# Contracts (mirroring layer_body_tree.jl):
# - `ItemLowering` values are position-free plain data with structural
#   equality: whitespace/comment/move edits reproduce `isequal` values so
#   Salsa backdates. Findings/uses reference nodes by PREORDER ADDRESS into
#   the item's v2 body tree; ranges are reattached exclusively via
#   `derived_file_lowering_maps` (volatile; depending on it from an
#   analysis-layer computation is a bug).
# - `derived_item_lowering` depends ONLY on `derived_item_lowering_body` —
#   never on any position map and never on file content directly.
# - Everything degrades: per-item lowering errors become `status = :error`
#   findings, never crashes.

"""
    LoweringFinding(addr, msg)

A message anchored to a preorder address in the item's lowering body tree
(`addr == 0` when no node association is available).
"""
@auto_hash_equals struct LoweringFinding
    addr::Int32
    msg::String
end

"""
    LoweredBinding

Plain-data projection of one JuliaLowering `BindingInfo`. `mod` is a module
NAME (never a `Module`); globals resolved against the throwaway per-frame
anchor module show up as `"JWLoweringAnchor"`.
"""
@auto_hash_equals struct LoweredBinding
    id::Int32
    name::String
    kind::Symbol            # :local | :global | :argument | :static_parameter
    addr::Int32             # declaration site (preorder address; 0 if unknown)
    mod::Union{Nothing,String}
    is_internal::Bool
    is_const::Bool
    is_ssa::Bool
    is_captured::Bool
    is_read::Bool
    is_assigned::Bool
    is_used_undef::Bool
    is_ambiguous_local::Bool
end

"""
    BindingUse(addr, binding)

One resolved identifier: the node at preorder address `addr` refers to
binding id `binding`.
"""
@auto_hash_equals struct BindingUse
    addr::Int32
    binding::Int32
end

"""
    ItemLowering

Result of running the (macro-free) lowering analysis passes over one item.
`status` is `:ok` or `:error` (lowering threw; see `findings`).
"""
@auto_hash_equals struct ItemLowering
    status::Symbol
    findings::Vector{LoweringFinding}
    bindings::Vector{LoweredBinding}
    uses::Vector{BindingUse}
end

# `JS2`/`JL2`/`V2Kind` are defined in packagedef.jl, before this file is
# included/macro-expanded (the `JS2.K"..."` string macros below need `JS2`
# bound at expansion time).

# ── v2 body forest (twin of layer_body_tree.jl, against the v2 parser) ──────

_range_v2(st) = _to_exclusive_end(JS2.byte_range(st))

function _build_body_tree_v2!(ranges::Union{Nothing,Vector{UnitRange{Int}}}, st)
    ranges !== nothing && push!(ranges, _range_v2(st))
    k = JS2.kind(st)
    if JS2.is_leaf(st)
        return BodyTree(k, st.value, nothing)
    else
        cs = Vector{BodyTree{V2Kind}}()
        for c in JS2.children(st)
            push!(cs, _build_body_tree_v2!(ranges, c))
        end
        # Interior nodes keep their `value` too, so materialization is faithful.
        return BodyTree(k, st.value, cs)
    end
end

# Keep the WIDEST node for each starting byte, not merely the first one seen:
# several nodes share a first byte (`f(x, y) = x` starts `=` and `call` at `f`)
# and only the widest is the whole item. Relying on preorder order alone picked
# the inner `call` for `@inline f(x, y) = x`, which materialised the signature
# without its body and hid every binding in it.
function _index_outermost_by_first_byte_v2!(dict::Dict{Int,JS2.SyntaxTree}, st, content::AbstractString)
    fb = _content_start(content, Int(JS2.first_byte(st)))
    prev = get(dict, fb, nothing)
    if prev === nothing || JS2.last_byte(st) > JS2.last_byte(prev)
        dict[fb] = st
    end
    if !JS2.is_leaf(st)
        for c in JS2.children(st)
            _index_outermost_by_first_byte_v2!(dict, c, content)
        end
    end
    return dict
end

# Same association scheme as `_foreach_item_syntax_node`: inventory item ids
# from the CST walker, matched to v2 nodes by first byte, root excluded.
function _foreach_item_v2_node(f, rt, uri)
    derived_has_content(rt, uri) || return nothing
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    (cst isa CSTParser.EXPR && CSTParser.headof(cst) === :file) || return nothing

    st = try
        JS2.parseall(JS2.SyntaxTree, tf.content.content; filename=string(uri))
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end

    content = tf.content.content
    outermost = Dict{Int,JS2.SyntaxTree}()
    if !JS2.is_leaf(st) && JS2.kind(st) == JS2.K"toplevel"
        for c in JS2.children(st)
            _index_outermost_by_first_byte_v2!(outermost, c, content)
        end
    else
        _index_outermost_by_first_byte_v2!(outermost, st, content)
    end

    _foreach_toplevel_item(cst) do _x, _order, id, _parent_module, offset
        node = get(outermost, _content_start(content, offset + 1), nothing)
        node === nothing && return
        # Module items get no lowering body (mirrors layer_body_tree.jl): the
        # module-tree layer models module structure; lowering the whole module
        # would duplicate inner items and error in the per-statement passes.
        JS2.kind(node) == JS2.K"module" && return
        f(id, node)
    end
    return nothing
end

Salsa.@derived function derived_file_lowering_forest(rt, uri)
    @debug "derived_file_lowering_forest" uri=uri

    result = Dict{Int64,BodyTree{V2Kind}}()
    _foreach_item_v2_node(rt, uri) do id, node
        result[id] = _build_body_tree_v2!(nothing, node)
    end
    return result
end

Salsa.@derived function derived_item_lowering_body(rt, ref)
    forest = derived_file_lowering_forest(rt, ref.file)
    return get(forest, ref.id, nothing)
end

"""
    derived_file_lowering_maps(rt, uri) -> Dict{Int64,Vector{UnitRange{Int}}}

Address→byte-range maps for the v2 lowering forest. Volatile leaf, exactly
like `derived_file_body_maps`: only last-mile position reattachment may read
it; depending on it from an analysis-layer computation is a bug.
"""
Salsa.@derived function derived_file_lowering_maps(rt, uri)
    @debug "derived_file_lowering_maps" uri=uri

    result = Dict{Int64,Vector{UnitRange{Int}}}()
    _foreach_item_v2_node(rt, uri) do id, node
        ranges = UnitRange{Int}[]
        _build_body_tree_v2!(ranges, node)
        result[id] = ranges
    end
    return result
end

# ── materialization (research report section H) ─────────────────────────────

_is_opaque_macrocall(bt::BodyTree{V2Kind}) =
    bt.kind == JS2.K"macrocall" ||
    (bt.kind == JS2.K"do" && bt.children !== nothing && !isempty(bt.children) &&
     bt.children[1].kind == JS2.K"macrocall")

_bt_node_count(bt::BodyTree) =
    bt.children === nothing ? 1 : 1 + sum(_bt_node_count, bt.children; init = 0)

# Macros that wrap a definition or expression and hand it through structurally:
# expanding them would return the argument essentially unchanged, so they can be
# unwrapped without executing anything. Mirrors StaticLint's
# `SIGNATURE_PRESERVING_MACROS` (StaticLint/linting/checks.jl:234) plus the
# argument annotations. Without this, `@inline f(x, y) = x` hides the whole
# definition and `f(@nospecialize(x::Int), y) = 1` hides the whole signature —
# between them the largest single source of missed bindings in the 2026-08-11
# corpus sweep.
#
# Stored without the leading `@` and matched on the trailing name, so
# `Base.@propagate_inbounds` matches too.
const TRANSPARENT_MACRO_NAMES = Set([
    "inline", "noinline", "propagate_inbounds", "generated",
    "assume_effects", "constprop", "pure", "nospecializeinfer",
    "nospecialize", "specialize", "inbounds",
])

function _macro_name_string(bt::BodyTree{V2Kind})
    node = bt
    # `Base.@propagate_inbounds` nests the name inside a `.`; take the trailing leaf.
    while node.children !== nothing && !isempty(node.children)
        node = node.children[end]
    end
    v = node.val
    v isa Union{Symbol,AbstractString} || return nothing
    s = string(v)
    return startswith(s, "@") ? s[2:end] : s
end

"The wrapped argument of a structurally transparent macrocall, else `nothing`."
function _transparent_macro_target(bt::BodyTree{V2Kind})
    bt.kind == JS2.K"macrocall" || return nothing
    (bt.children === nothing || length(bt.children) < 2) && return nothing
    nm = _macro_name_string(bt.children[1])
    (nm === nothing || !(nm in TRANSPARENT_MACRO_NAMES)) && return nothing
    # The wrapped form is always last: `@assume_effects :total function f() end`.
    return bt.children[end]
end

# Semi-transparent handling of an opaque macrocall's subtree: keep every
# `K"Identifier"` leaf (at its ORIGINAL preorder address) as a plain read.
# This is StaticLint's transparent-traversal precedent — a macro is assumed
# to potentially read whatever identifiers appear in its arguments — and is
# conservative in the right direction for unused-binding analysis (can only
# cause false negatives, never false positives). NOTE: consequently
# use-before-definition analysis must not be shipped while macros are opaque
# (a synthesized read may precede the real assignment).
function _collect_macrocall_identifiers!(kids::Vector{JS2.SyntaxTree}, bt::BodyTree{V2Kind}, addr::Base.RefValue{Int})
    myaddr = (addr[] += 1)
    if bt.children === nothing
        # Macro names themselves parse as identifiers spelled `@name` (v2
        # stores identifier names as String); they are not variable reads.
        if bt.kind == JS2.K"Identifier" &&
           !(bt.val isa Union{Symbol,AbstractString} && startswith(string(bt.val), "@"))
            push!(kids, JS2.SyntaxTree(bt.kind, nothing, bt.val, LineNumberNode(myaddr, :body), nothing))
        end
        return nothing
    end
    for c in bt.children
        _collect_macrocall_identifiers!(kids, c, addr)
    end
    return nothing
end

# Quote nesting depth, tracked exactly as JuliaLowering's own
# `collect_unquoted!` does: `quote` deepens, `$` unwraps one level.
function _quote_depth(k, qdepth::Int)
    (k == JS2.K"quote" || k == JS2.K"syntaxquote") && return qdepth + 1
    (k == JS2.K"$" || k == JS2.K"syntaxunquote") && return max(qdepth - 1, 0)
    return qdepth
end

# BodyTree → ephemeral v2 SyntaxTree. Every node's `source` is
# `LineNumberNode(preorder address)`, so pass-output provenance chains
# terminate at address anchors. Macrocalls are NOT expanded (no macro
# expansion in-process): they become a block of identifier reads (see
# `_collect_macrocall_identifiers!`) ending in a `Value(nothing)` placeholder
# carrying the macrocall's address; the address counter advances across the
# whole subtree so numbering stays aligned with the volatile map. This block
# is also the future DJP splice point (M1+).
#
# That substitution only applies in EVALUATED positions (`qdepth == 0`). Inside
# a `quote` a macrocall is data — it is never expanded — and flattening it
# would destroy the `$` interpolation nodes that the quote's own expansion
# needs, making interpolated variables look unused (e.g. `T` in
# `macro m(T); quote; @generated f($(esc(T))) = 1; end; end`).
function _materialize(bt::BodyTree{V2Kind}, addr::Base.RefValue{Int}, qdepth::Int = 0)
    myaddr = (addr[] += 1)
    src = LineNumberNode(myaddr, :body)
    # Structurally transparent macros unwrap to the form they wrap. The skipped
    # children still consume their addresses so the preorder numbering stays
    # aligned with `derived_file_lowering_maps`.
    if qdepth == 0
        target = _transparent_macro_target(bt)
        if target !== nothing
            for c in bt.children[1:end-1]
                addr[] += _bt_node_count(c)
            end
            return _materialize(target, addr, qdepth)
        end
    end
    if qdepth == 0 && _is_opaque_macrocall(bt)
        kids = Vector{JS2.SyntaxTree}()
        if bt.children !== nothing
            for c in bt.children
                _collect_macrocall_identifiers!(kids, c, addr)
            end
        end
        push!(kids, JS2.SyntaxTree(JS2.K"Value", nothing, nothing, src, nothing))
        return JS2.SyntaxTree(JS2.K"block", kids, nothing, src, nothing)
    end
    if bt.children === nothing
        return JS2.SyntaxTree(bt.kind, nothing, bt.val, src, nothing)
    else
        child_depth = _quote_depth(bt.kind, qdepth)
        kids = Vector{JS2.SyntaxTree}()
        for c in bt.children
            push!(kids, _materialize(c, addr, child_depth))
        end
        node = JS2.SyntaxTree(bt.kind, kids, bt.val, src, nothing)

        # Entering a quote from evaluated code: the quote's contents lower to
        # inert data, so a variable mentioned only inside it would look unused.
        # Lexically that is true, but it is the wrong answer for a linter —
        # renaming the variable changes what the quoted code means, and for
        # `@generated` bodies it breaks the generated method outright. So pair
        # the quote with reads of the identifiers it mentions, the same
        # treatment opaque macrocalls get. The quote stays last so the block's
        # value is still the quote's.
        if qdepth == 0 && child_depth > qdepth
            reads = Vector{JS2.SyntaxTree}()
            _collect_quoted_identifiers!(reads, bt, Ref(myaddr))
            if !isempty(reads)
                push!(reads, node)
                return JS2.SyntaxTree(JS2.K"block", reads, nothing, src, nothing)
            end
        end
        return node
    end
end

# Identifier leaves mentioned anywhere inside a quote, emitted as plain reads.
# Addresses are not meaningful here (the real nodes were already materialized
# with their own addresses), so everything anchors to the quote itself; these
# nodes exist only to mark the names as used.
function _collect_quoted_identifiers!(reads::Vector{JS2.SyntaxTree}, bt::BodyTree{V2Kind}, addr::Base.RefValue{Int})
    if bt.children === nothing
        if bt.kind == JS2.K"Identifier" &&
           !(bt.val isa Union{Symbol,AbstractString} && startswith(string(bt.val), "@"))
            push!(reads, JS2.SyntaxTree(bt.kind, nothing, bt.val,
                                        LineNumberNode(addr[], :body), nothing))
        end
        return nothing
    end
    for c in bt.children
        _collect_quoted_identifiers!(reads, c, addr)
    end
    return nothing
end

# ── the frame ───────────────────────────────────────────────────────────────

_node_addr(ex)::Int32 = try
    Int32(JS2.source_location(LineNumberNode, ex).line)
catch
    Int32(0)
end

function _error_finding(err)
    if err isa JL2.LoweringError
        # Fields: sts (trees the error refers to), msgs, internal.
        addr = isempty(err.sts) ? Int32(0) : _node_addr(err.sts[1])
        msg = isempty(err.msgs) ? "lowering error" : string(err.msgs[1])
        LoweringFinding(addr, msg)
    elseif err isa JL2.MacroExpansionError
        LoweringFinding(_node_addr(err.ex), err.msg)
    else
        LoweringFinding(Int32(0), first(sprint(showerror, err), 200))
    end
end

function _project!(bindings::Vector{LoweredBinding}, uses::Vector{BindingUse}, ctx3, ex3)
    for b in ctx3.bindings.info
        push!(bindings, LoweredBinding(
            Int32(b.id), b.name, b.kind, _node_addr(b.node_id),
            b.mod === nothing ? nothing : string(nameof(b.mod)),
            b.is_internal, b.is_const, b.is_ssa, b.is_captured,
            b.is_read, b.is_assigned, b.is_used_undef, b.is_ambiguous_local))
    end
    _collect_uses!(uses, ex3)
    return nothing
end

function _collect_uses!(uses::Vector{BindingUse}, ex)
    if JS2.kind(ex) == JS2.K"BindingId"
        push!(uses, BindingUse(_node_addr(ex), Int32(ex.value::Int)))
    end
    if !JS2.is_leaf(ex)
        for c in JS2.children(ex)
            _collect_uses!(uses, c)
        end
    end
    return nothing
end

# Pure function of the body value: the H invariant — no position map, no file
# content, no runtime state escapes into the result (module NAMES only).
function _lower_item(body::BodyTree{V2Kind})
    st = _materialize(body, Ref(0))
    findings = LoweringFinding[]
    bindings = LoweredBinding[]
    uses = BindingUse[]
    try
        world = Base.get_world_counter()
        anchor = Module(:JWLoweringAnchor)
        ex0 = JL2.rebase_layers(st, anchor, JL2.JL_NEW_SYNTAX_VERSION)
        ex1 = JL2.expand_forms_1(ex0, world, true)
        ctx2, ex2 = JL2.expand_forms_2(ex1, world)
        ctx3, ex3 = JL2.resolve_scopes(ctx2, ex2; soft_scope=false)
        try
            _project!(bindings, uses, ctx3, ex3)
        catch err
            err isa InterruptException && rethrow()
            empty!(bindings)
            empty!(uses)
            push!(findings, LoweringFinding(Int32(0),
                "binding projection failed: " * first(sprint(showerror, err), 200)))
        end
        return ItemLowering(:ok, findings, bindings, uses)
    catch err
        err isa InterruptException && rethrow()
        return ItemLowering(:error, [_error_finding(err)], LoweredBinding[], BindingUse[])
    end
end

"""
    derived_item_lowering(rt, ref) -> Union{Nothing,ItemLowering}

The (macro-free) lowering analysis of one item. `nothing` when the item has
no lowering body (missing file/item or parser divergence). Backdates across
position-only edits: its only dependency is the position-free body value.
"""
Salsa.@derived function derived_item_lowering(rt, ref)
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return nothing
    return _lower_item(body)
end
