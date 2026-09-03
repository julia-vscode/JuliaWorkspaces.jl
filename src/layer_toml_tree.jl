# TOML files through TomlSyntax: the parse products every consumer of
# `derived_toml_syntax_tree` reads, and the TOML item walk (skeleton, bodies,
# maps) that mirrors src/v2/layer_inventory_v2.jl for Julia files. Lint rules
# and editor features for TOML files build on the walk; none exist yet.
#
# The walk follows the v2 contract: `BodyTree`s are position-free and
# backdate across position-only edits; positions are reattached only through
# the volatile `derived_toml_file_maps` (preorder address -> 1-based,
# exclusive-end byte range), and only at the last mile.

# Not derived: a tree per file never backdates (identity equality) and the
# parse is cheap. Consumers cache their small products.
parse_toml_tree(content::AbstractString) = TomlSyntax.parsetoml_with_diagnostics(content)

_toml_range(node) = _to_exclusive_end(JS2.byte_range(node))

_toml_diagnostic(d::TomlSyntax.TomlDiagnostic) =
    Diagnostic(_to_exclusive_end(d.first_byte:d.last_byte), d.level, d.message, nothing, Symbol[], "TomlSyntax.jl")

"""
    derived_toml_parse_result(rt, uri) -> (Dict{String,Any}, Vector{Diagnostic})

The table of a TOML file (every intact item, even when the file has errors)
and its syntax plus semantic diagnostics, at real ranges.
"""
Salsa.@derived function derived_toml_parse_result(rt, uri)
    @debug "derived_toml_parse_result" uri=uri

    tf = derived_text_file_content(rt, uri)

    tf === nothing && return Dict{String,Any}(), Diagnostic[Diagnostic(1:1, :error, "File not found", nothing, Symbol[], "JuliaWorkspaces")]

    tree, syntax = parse_toml_tree(tf.content.content)
    table, semantic = TomlSyntax.build_table(tree)
    diags = Diagnostic[_toml_diagnostic(d) for d in syntax]
    for d in semantic
        push!(diags, _toml_diagnostic(d))
    end
    sort!(diags; by=d -> first(d.range))
    return table, diags
end

Salsa.@derived derived_toml_syntax_tree(rt, uri) = derived_toml_parse_result(rt, uri)[1]

Salsa.@derived derived_toml_syntax_diagnostics(rt, uri) = derived_toml_parse_result(rt, uri)[2]

#-------------------------------------------------------------------------------
# The TOML item walk

"""
    TomlItemRef(file, id)

Identifies one TOML item (a key/value pair or a table header) in a file. A
distinct type from `V2ItemRef` on purpose: a different walker over a different
parser is a different id space.
"""
@auto_hash_equals struct TomlItemRef
    file::URI
    id::Int64
end

"""
    TomlItemRow

One item of a TOML file's skeleton: `kind` is `:keyval`, `:table` or
`:array_table`; `key` the dotted key parts as written (`""` for an unreadable
part); `table` the enclosing section's key parts (empty at top level). No
positions and no values, so the skeleton backdates across body edits.
"""
@auto_hash_equals struct TomlItemRow
    order::Int
    id::Int64
    kind::Symbol
    key::Vector{String}
    table::Vector{String}
end

@auto_hash_equals struct TomlFileSkeleton
    items::Vector{TomlItemRow}
end
const EMPTY_TOML_SKELETON = TomlFileSkeleton(TomlItemRow[])

# A PLAIN struct (`===` equality) for the same reason as `V2FileWalk`: the
# maps shift on every position edit, so the early exit lives in the
# projections below.
struct TomlFileWalk
    skeleton::TomlFileSkeleton
    bodies::Dict{Int64,BodyTree{V2Kind}}
    maps::Dict{Int64,Vector{UnitRange{Int}}}
end
const EMPTY_TOML_FILE_WALK = TomlFileWalk(EMPTY_TOML_SKELETON, Dict{Int64,BodyTree{V2Kind}}(),
                                          Dict{Int64,Vector{UnitRange{Int}}}())

# One traversal produces the tree and its address map, so addresses align.
function _toml_body_tree!(ranges::Union{Nothing,Vector{UnitRange{Int}}}, node)
    ranges !== nothing && push!(ranges, _toml_range(node))
    k = JS2.kind(node)
    JS2.is_leaf(node) && return BodyTree(k, node.val, nothing)
    cs = BodyTree{V2Kind}[]
    for c in JS2.children(node)
        push!(cs, _toml_body_tree!(ranges, c))
    end
    return BodyTree(k, nothing, cs)
end

_toml_key_parts(keynode) = String[c.val isa String ? c.val : "" for c in JS2.children(keynode)]

mutable struct _TomlWalkState
    items::Vector{TomlItemRow}
    bodies::Dict{Int64,BodyTree{V2Kind}}
    maps::Dict{Int64,Vector{UnitRange{Int}}}
    alloc::_V2ItemIdAllocator
end
_TomlWalkState() = _TomlWalkState(TomlItemRow[], Dict{Int64,BodyTree{V2Kind}}(),
                                  Dict{Int64,Vector{UnitRange{Int}}}(), _V2ItemIdAllocator())

function _toml_emit_item!(state::_TomlWalkState, node, kindsym::Symbol, key::Vector{String}, table::Vector{String})
    ranges = UnitRange{Int}[]
    bt = if kindsym === :keyval
        _toml_body_tree!(ranges, node)
    else
        # A section item is its header only (address 1 = the section, 2 = the
        # key), so entry edits never touch it; entries are items of their own.
        push!(ranges, _toml_range(node))
        cs = JS2.children(node)
        keys = isempty(cs) ? BodyTree{V2Kind}[] : BodyTree{V2Kind}[_toml_body_tree!(ranges, cs[1])]
        BodyTree(JS2.kind(node), nothing, keys)
    end
    order, id = _v2_mint_ids!(state.alloc, (kindsym, join(key, '.'), join(table, '.')))
    push!(state.items, TomlItemRow(order, id, kindsym, key, table))
    state.bodies[id] = bt
    state.maps[id] = ranges
    return
end

function _toml_walk_file!(state::_TomlWalkState, root)
    for child in JS2.children(root)
        k = JS2.kind(child)
        if k == JS2.K"toml_keyval"
            _toml_emit_item!(state, child, :keyval, _toml_key_parts(child[1]), String[])
        elseif k == JS2.K"toml_table" || k == JS2.K"toml_array_table"
            cs = JS2.children(child)
            path = isempty(cs) ? String[] : _toml_key_parts(cs[1])
            _toml_emit_item!(state, child, k == JS2.K"toml_table" ? :table : :array_table, path, String[])
            for c in cs
                JS2.kind(c) == JS2.K"toml_keyval" || continue
                _toml_emit_item!(state, c, :keyval, _toml_key_parts(c[1]), path)
            end
        end
    end
    return state
end

"""
    derived_toml_file_walk(rt, uri) -> TomlFileWalk

The single TomlSyntax parse of `uri` walked into skeleton + bodies + maps.
Parses with recovery, so items after a syntax error survive. Consumers depend
on the projections below, never on this.
"""
Salsa.@derived function derived_toml_file_walk(rt, uri)
    @debug "derived_toml_file_walk" uri=uri

    derived_has_content(rt, uri) || return EMPTY_TOML_FILE_WALK
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return EMPTY_TOML_FILE_WALK

    state = try
        tree, _ = parse_toml_tree(tf.content.content)
        _toml_walk_file!(_TomlWalkState(), tree)
    catch err
        err isa InterruptException && rethrow()
        return EMPTY_TOML_FILE_WALK
    end
    return TomlFileWalk(TomlFileSkeleton(state.items), state.bodies, state.maps)
end

"The position-free item rows of a TOML file."
Salsa.@derived derived_toml_file_skeleton(rt, uri) = derived_toml_file_walk(rt, uri).skeleton

"Per-item `BodyTree`s of a TOML file, keyed by item id."
Salsa.@derived derived_toml_file_bodies(rt, uri) = derived_toml_file_walk(rt, uri).bodies

"""
    derived_toml_file_maps(rt, uri) -> Dict{Int64,Vector{UnitRange{Int}}}

Per item, the address map of its `BodyTree`: entry `i` is the 1-based,
exclusive-end byte range of the node at preorder address `i`. VOLATILE:
recomputes on every reparse. Last-mile position reattachment only; depending
on it from an analysis-layer computation is a bug.
"""
Salsa.@derived derived_toml_file_maps(rt, uri) = derived_toml_file_walk(rt, uri).maps

"The `BodyTree` of one TOML item, or `nothing`."
Salsa.@derived function derived_toml_item_body(rt, ref::TomlItemRef)
    return get(derived_toml_file_bodies(rt, ref.file), ref.id, nothing)
end
