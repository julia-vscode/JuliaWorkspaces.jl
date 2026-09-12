# `TomlNode`: the trivia-free AST, a `TreeNode{TomlData}` so JuliaSyntax's
# accessors (`kind`, `children`, `byte_range`, `sourcefile`, printing) apply.

"""
    TomlData

Per-node data of a [`TomlNode`](@ref): the source, the node's green tree, its
last byte and, for leaves, the parsed value (see `parse_toml_literal`).
"""
struct TomlData <: AbstractSyntaxData
    source::SourceFile
    raw::GreenNode{SyntaxHead}
    byte_end::UInt32
    val::Any
end

function Base.hash(data::TomlData, h::UInt)
    return hash(data.source, hash(data.raw, hash(data.byte_end, Core.invoke(hash, Tuple{Any,UInt}, data.val, h))))
end
function Base.:(==)(a::TomlData, b::TomlData)
    return a.source == b.source && a.raw == b.raw && a.byte_end == b.byte_end && a.val === b.val
end
Base.copy(data::TomlData) = TomlData(data.source, data.raw, data.byte_end, data.val)

"""
    TomlNode

A node of the trivia-free TOML syntax tree. `kind(node)`, `children(node)`,
`node.val` (leaves), `byte_range(node)` and `sourcefile(node)` are the API.
"""
const TomlNode = TreeNode{TomlData}

_should_include(child) = !is_trivia(child) || is_error(child)

function _to_toml_node(source::SourceFile, txtbuf::Vector{UInt8}, cursor::RedTreeCursor, green::GreenNode{SyntaxHead})
    if is_leaf(cursor)
        r = byte_range(cursor)
        val = parse_toml_literal(txtbuf, head(cursor), Int(first(r)):Int(last(r)))
        return TomlNode(nothing, nothing, TomlData(source, green, cursor.byte_end, val))
    end
    cs = TomlNode[]
    for (i, child) in enumerate(reverse(cursor))
        _should_include(child) && pushfirst!(cs, _to_toml_node(source, txtbuf, child, green[end-i+1]))
    end
    node = TomlNode(nothing, cs, TomlData(source, green, cursor.byte_end, nothing))
    for c in cs
        c.parent = node
    end
    return node
end

"""
    build_tree(TomlNode, st::TomlParseStream; filename=nothing, first_line=1)
    build_tree(GreenNode, st::TomlParseStream)

The tree of a parsed stream: the trivia-free AST, or the lossless green tree.
"""
function build_tree(::Type{TomlNode}, st::TomlParseStream; filename=nothing, first_line=1)
    source = SourceFile(st; filename, first_line)
    green_cursor = GreenTreeCursor(st.output, UInt32(length(st.output)))
    cursor = RedTreeCursor(green_cursor, UInt32(st.next_byte - 1))
    green = GreenNode(green_cursor)
    GC.@preserve st begin
        return _to_toml_node(source, st.textbuf, cursor, green)
    end
end

# Accepts (and ignores) the `TomlNode` method's keywords so `parsetoml` can
# call either uniformly.
function build_tree(::Type{GreenNode}, st::TomlParseStream; kws...)
    return GreenNode(GreenTreeCursor(st.output, UInt32(length(st.output))))
end

function JuliaSyntax.leaf_string(node::TomlNode)
    k = kind(node)
    v = node.val
    k == K"TomlBareKey" && return string(v)
    v === nothing && return untokenize(k)
    v isa ErrorVal && return "(error)"
    return is_toml_datetime(k) ? string(v) : repr(v)
end
