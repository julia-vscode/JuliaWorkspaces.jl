# Entry points: the tree, the Julia chunk table, and the shadow source.

"""
    parsemd(text; filename=nothing, first_line=1) -> MarkdownNode

Parse `text` into a [`MarkdownNode`](@ref) tree. Never throws on any input:
Markdown has no syntax errors at this level (an unclosed fence legally runs to
the end of the input).
"""
function parsemd(text::Union{AbstractString,IO}; filename=nothing, first_line=1)
    st = MarkdownParseStream(text)
    parse_markdown!(st)
    return build_tree(MarkdownNode, st; filename, first_line)
end

"""
    JuliaChunk

One fenced code block whose info string marks its content as Julia code.

- `fence_kind::Symbol`: `:julia` (a plain Julia fence), `:julia_attrs` (a
  brace-delimited jmd/Quarto/Weave chunk header), or the Documenter block
  types `:example`, `:setup`, `:repl`, `:eval`.
- `name::String`: the Documenter block name (`"name"` in an example block
  named `name`), or `""`.
- `info::String`: the whole info string as written.
- `code_range::UnitRange{Int}`: 1-based inclusive byte range of the fence
  content (the lines between the delimiters, EOLs included). Empty
  (`isempty`) for a fence with no content lines.
"""
struct JuliaChunk
    fence_kind::Symbol
    name::String
    info::String
    code_range::UnitRange{Int}
end

# The info strings that mark a fence as plain-Julia content. jldoctest is
# deliberately absent: doctests are REPL transcripts (prompts and expected
# output), not parseable Julia source.
function _classify_fence_info(info::AbstractString)
    isempty(info) && return nothing
    words = split(info)
    isempty(words) && return nothing
    w = words[1]
    if w == "julia"
        return (:julia, "")
    elseif startswith(w, "{")
        # `{julia}`, `{julia; opts...}`, `{julia, opts...}`, `{julia label}` --
        # but not `{juliette}` or `{r}`.
        occursin(r"^\{\s*julia([\s;,}]|$)", info) && return (:julia_attrs, "")
        return nothing
    elseif w == "@example" || w == "@setup" || w == "@repl" || w == "@eval"
        return (Symbol(w[2:end]), length(words) >= 2 ? String(words[2]) : "")
    end
    return nothing
end

"""
    julia_chunks(tree::MarkdownNode) -> Vector{JuliaChunk}
    julia_chunks(text::AbstractString) -> Vector{JuliaChunk}

The Julia code chunks of a document, in document order: every fenced code
block whose info string is a plain Julia fence, a brace-delimited chunk header
naming julia, or one of Documenter's plain-Julia block types (`@example`,
`@setup`, `@repl`, `@eval`). Doctest fences are not included.
"""
function julia_chunks(tree::MarkdownNode)
    chunks = JuliaChunk[]
    tree.children === nothing && return chunks
    for node in children(tree)
        kind(node) == K"md_code_fence" || continue
        cs = children(node)
        isempty(cs) && continue
        kind(cs[1]) == K"MdFenceDelim" || continue
        info = cs[1].val::String
        classified = _classify_fence_info(info)
        classified === nothing && continue
        fence_kind, name = classified
        code_idx = findfirst(c -> kind(c) == K"MdCode", cs)
        code_range = if code_idx === nothing
            b = Int(last(byte_range(cs[1])))
            (b + 1):b
        else
            r = byte_range(cs[code_idx])
            Int(first(r)):Int(last(r))
        end
        push!(chunks, JuliaChunk(fence_kind, name, info, code_range))
    end
    return chunks
end

julia_chunks(text::AbstractString) = julia_chunks(parsemd(text))

"""
    julia_shadow_source(text::AbstractString; chunks=julia_chunks(text)) -> String

The document as byte-offset-preserving Julia source: every byte inside a
Julia chunk's `code_range` is kept verbatim, every other non-EOL byte becomes
a space. The result has exactly the same byte length and line structure as
`text`, so positions in a parse of the shadow are positions in the document --
no mapping layer anywhere downstream.

The blanked bytes are all ASCII spaces, so the result is valid UTF-8 (and
valid Julia trivia) no matter what the prose contained.
"""
function julia_shadow_source(text::AbstractString; chunks::Vector{JuliaChunk}=julia_chunks(text))
    buf = Vector{UInt8}(codeunits(text))
    function blank!(from::Int, to::Int)
        for i in from:to
            b = @inbounds buf[i]
            if b != UInt8('\n') && b != UInt8('\r')
                @inbounds buf[i] = UInt8(' ')
            end
        end
    end
    pos = 1
    for c in chunks
        isempty(c.code_range) && continue
        blank!(pos, first(c.code_range) - 1)
        pos = last(c.code_range) + 1
    end
    blank!(pos, length(buf))
    return String(buf)
end
