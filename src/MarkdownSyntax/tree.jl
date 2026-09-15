# `MarkdownNode`: the trivia-free AST, a `TreeNode{MarkdownData}` so
# JuliaSyntax's accessors (`kind`, `children`, `byte_range`, `sourcefile`,
# printing) apply. Prose runs are trivia and dropped; what remains is the
# document's structure: front matter, code fences, headings, indented code.

"""
    MarkdownData

Per-node data of a [`MarkdownNode`](@ref): the source, the node's green tree,
its last byte and, for some leaves, a parsed value -- the info string of a
fence delimiter line (`""` for a closing delimiter), or
`(; level, title)` of a heading line.
"""
struct MarkdownData <: AbstractSyntaxData
    source::SourceFile
    raw::GreenNode{SyntaxHead}
    byte_end::UInt32
    val::Any
end

function Base.hash(data::MarkdownData, h::UInt)
    return hash(data.source, hash(data.raw, hash(data.byte_end, Core.invoke(hash, Tuple{Any,UInt}, data.val, h))))
end
function Base.:(==)(a::MarkdownData, b::MarkdownData)
    return a.source == b.source && a.raw == b.raw && a.byte_end == b.byte_end && isequal(a.val, b.val)
end
Base.copy(data::MarkdownData) = MarkdownData(data.source, data.raw, data.byte_end, data.val)

"""
    MarkdownNode

A node of the trivia-free Markdown block tree. `kind(node)`, `children(node)`,
`node.val` (leaves), `byte_range(node)` and `sourcefile(node)` are the API.
"""
const MarkdownNode = TreeNode{MarkdownData}

_md_should_include(child) = !is_trivia(child) || is_error(child)

function _markdown_leaf_value(txtbuf::Vector{UInt8}, k::Kind, r::UnitRange{Int})
    if k == K"MdFenceDelim"
        fo = _fence_open(txtbuf, r)
        # A closing delimiter line parses as an opening fence with an empty
        # info string, so both delimiters uniformly carry a `String`.
        fo === nothing && return ""
        return String(txtbuf[fo.info_first:fo.info_last])
    elseif k == K"MdHeading"
        _, i = _indentation(txtbuf, r)
        cl = _content_last(txtbuf, r)
        j = i
        while j <= cl && @inbounds(txtbuf[j]) == UInt8('#')
            j += 1
        end
        level = j - i
        title = strip(String(txtbuf[j:cl]))
        # CommonMark: an optional closing sequence of hashes is not the title.
        title = rstrip(rstrip(title, '#'))
        return (level=level, title=String(title))
    end
    return nothing
end

function _to_markdown_node(source::SourceFile, txtbuf::Vector{UInt8}, cursor::RedTreeCursor, green::GreenNode{SyntaxHead})
    if is_leaf(cursor)
        r = byte_range(cursor)
        val = _markdown_leaf_value(txtbuf, kind(cursor), Int(first(r)):Int(last(r)))
        return MarkdownNode(nothing, nothing, MarkdownData(source, green, cursor.byte_end, val))
    end
    cs = MarkdownNode[]
    for (i, child) in enumerate(reverse(cursor))
        _md_should_include(child) && pushfirst!(cs, _to_markdown_node(source, txtbuf, child, green[end-i+1]))
    end
    node = MarkdownNode(nothing, cs, MarkdownData(source, green, cursor.byte_end, nothing))
    for c in cs
        c.parent = node
    end
    return node
end

"""
    build_tree(MarkdownNode, st::MarkdownParseStream; filename=nothing, first_line=1)
    build_tree(GreenNode, st::MarkdownParseStream)

The tree of a parsed stream: the trivia-free AST, or the lossless green tree.
"""
function build_tree(::Type{MarkdownNode}, st::MarkdownParseStream; filename=nothing, first_line=1)
    source = SourceFile(st; filename, first_line)
    green_cursor = GreenTreeCursor(st.output, UInt32(length(st.output)))
    cursor = RedTreeCursor(green_cursor, UInt32(st.next_byte - 1))
    green = GreenNode(green_cursor)
    GC.@preserve st begin
        return _to_markdown_node(source, st.textbuf, cursor, green)
    end
end

# Accepts (and ignores) the `MarkdownNode` method's keywords so `parsemd` can
# call either uniformly.
function build_tree(::Type{GreenNode}, st::MarkdownParseStream; kws...)
    return GreenNode(GreenTreeCursor(st.output, UInt32(length(st.output))))
end

function JuliaSyntax.leaf_string(node::MarkdownNode)
    v = node.val
    v === nothing && return untokenize(kind(node))
    return repr(v)
end
