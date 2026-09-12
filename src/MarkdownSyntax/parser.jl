# The block scanner. Markdown block structure is line-oriented, so instead of
# a token lexer + lookahead machinery this parser classifies whole lines and
# emits directly into JuliaSyntax's flat postorder `RawGreenNode` buffer; the
# shared cursors and `GreenNode` work on the output unchanged.

"""
    MarkdownParseStream(text)

Parser input/output over `text` (a `String`, `SubString{String}`,
`Vector{UInt8}` or `IO`).
"""
mutable struct MarkdownParseStream
    textbuf::Vector{UInt8}
    text_root::Any
    output::Vector{RawGreenNode}
    next_byte::Int

    function MarkdownParseStream(text_buf::Vector{UInt8}, text_root, next_byte::Integer)
        nb = Int(next_byte)
        # A leading byte order mark is ignored (it sits inside the sentinel).
        if nb + 2 <= length(text_buf) && text_buf[nb] == 0xef && text_buf[nb+1] == 0xbb && text_buf[nb+2] == 0xbf
            nb += 3
        end
        sentinel = RawGreenNode(SyntaxHead(K"TOMBSTONE", EMPTY_FLAGS), nb - 1, K"TOMBSTONE")
        return new(text_buf, text_root, RawGreenNode[sentinel], nb)
    end
end

MarkdownParseStream(text::Vector{UInt8}, index::Integer=1) =
    MarkdownParseStream(text, text, index)
MarkdownParseStream(text::String, index::Integer=1) =
    MarkdownParseStream(unsafe_wrap(Vector{UInt8}, text), text, index)
MarkdownParseStream(text::SubString{String}, index::Integer=1) =
    MarkdownParseStream(unsafe_wrap(Vector{UInt8}, pointer(text), sizeof(text)), text, index)
MarkdownParseStream(text::AbstractString, index::Integer=1) =
    MarkdownParseStream(String(text), index)
function MarkdownParseStream(io::IO)
    buf = read(io)
    return MarkdownParseStream(buf, buf, 1)
end

function Base.show(io::IO, ::MIME"text/plain", st::MarkdownParseStream)
    print(io, "MarkdownParseStream at position ", st.next_byte)
end

JuliaSyntax.first_byte(st::MarkdownParseStream) = Int(first(st.output).byte_span) + 1
JuliaSyntax.last_byte(st::MarkdownParseStream) = st.next_byte - 1

function JuliaSyntax.SourceFile(st::MarkdownParseStream; kws...)
    fbyte = first_byte(st)
    lbyte = last_byte(st)
    root = st.text_root
    str = if root isa String || root isa SubString{String}
        fbyte <= lbyte ? SubString(root, fbyte, thisind(root, lbyte)) : SubString(root, fbyte, fbyte - 1)
    else
        SubString(String(st.textbuf[fbyte:lbyte]))
    end
    return SourceFile(str; first_index=fbyte, kws...)
end

#-------------------------------------------------------------------------------
# Line classification
#
# A "line" is the 1-based inclusive byte range up to and including its `\n`
# (the final line may lack one). Classifiers ignore a trailing `\r`.

function _split_lines(buf::Vector{UInt8}, fb::Int, lb::Int)
    lines = UnitRange{Int}[]
    i = fb
    while i <= lb
        j = i
        while j <= lb && @inbounds(buf[j]) != UInt8('\n')
            j += 1
        end
        push!(lines, i:min(j, lb))
        i = j + 1
    end
    return lines
end

# Last byte of the line's content: the EOL (`\n`, and a `\r` before it) is
# stripped. May be `first(r) - 1` for a line that is only an EOL.
function _content_last(buf::Vector{UInt8}, r::UnitRange{Int})
    j = last(r)
    j >= first(r) && @inbounds(buf[j]) == UInt8('\n') && (j -= 1)
    j >= first(r) && @inbounds(buf[j]) == UInt8('\r') && (j -= 1)
    return j
end

# Leading indentation in columns (a tab advances to the next multiple of 4,
# CommonMark's expansion) and the index of the first byte after it.
function _indentation(buf::Vector{UInt8}, r::UnitRange{Int})
    cl = _content_last(buf, r)
    width = 0
    i = first(r)
    while i <= cl
        b = @inbounds buf[i]
        if b == UInt8(' ')
            width += 1
        elseif b == UInt8('\t')
            width += 4 - width % 4
        else
            break
        end
        i += 1
    end
    return width, i
end

function _is_blank(buf::Vector{UInt8}, r::UnitRange{Int})
    cl = _content_last(buf, r)
    for i in first(r):cl
        b = @inbounds buf[i]
        (b == UInt8(' ') || b == UInt8('\t')) || return false
    end
    return true
end

"""
An opening code fence per CommonMark: at most 3 columns of indentation, then a
run of 3+ backticks or tildes, then the info string (which, for a backtick
fence, must not contain a backtick). Returns
`(; char, len, info_first, info_last)` -- the info string byte range is
whitespace-trimmed and empty ranges are `i:i-1` -- or `nothing`.
"""
function _fence_open(buf::Vector{UInt8}, r::UnitRange{Int})
    width, i = _indentation(buf, r)
    width <= 3 || return nothing
    cl = _content_last(buf, r)
    i <= cl || return nothing
    c = @inbounds buf[i]
    (c == UInt8(0x60) || c == UInt8('~')) || return nothing
    j = i
    while j <= cl && @inbounds(buf[j]) == c
        j += 1
    end
    len = j - i
    len >= 3 || return nothing
    # Trim the info string.
    a, b = j, cl
    while a <= b && (@inbounds(buf[a]) == UInt8(' ') || @inbounds(buf[a]) == UInt8('\t'))
        a += 1
    end
    while b >= a && (@inbounds(buf[b]) == UInt8(' ') || @inbounds(buf[b]) == UInt8('\t'))
        b -= 1
    end
    if c == UInt8(0x60)
        for k in a:b
            @inbounds(buf[k]) == UInt8(0x60) && return nothing
        end
    end
    return (char=c, len=len, info_first=a, info_last=b)
end

"""
A closing fence for an open fence of `char`/`len`: at most 3 columns of
indentation, a run of at least `len` `char`s, and nothing but whitespace after.
"""
function _fence_close(buf::Vector{UInt8}, r::UnitRange{Int}, char::UInt8, len::Int)
    width, i = _indentation(buf, r)
    width <= 3 || return false
    cl = _content_last(buf, r)
    j = i
    while j <= cl && @inbounds(buf[j]) == char
        j += 1
    end
    j - i >= len || return false
    for k in j:cl
        b = @inbounds buf[k]
        (b == UInt8(' ') || b == UInt8('\t')) || return false
    end
    return true
end

"An ATX heading: at most 3 columns of indentation, 1-6 hashes, then space or EOL."
function _atx_heading(buf::Vector{UInt8}, r::UnitRange{Int})
    width, i = _indentation(buf, r)
    width <= 3 || return false
    cl = _content_last(buf, r)
    j = i
    while j <= cl && @inbounds(buf[j]) == UInt8('#')
        j += 1
    end
    n = j - i
    1 <= n <= 6 || return false
    return j > cl || @inbounds(buf[j]) == UInt8(' ') || @inbounds(buf[j]) == UInt8('\t')
end

# Front matter delimiters (a Jekyll/Weave convention, not CommonMark): the
# document's very first line is exactly three dashes, closed by three dashes
# or three dots.
function _front_matter_delim(buf::Vector{UInt8}, r::UnitRange{Int}, byte::UInt8)
    cl = _content_last(buf, r)
    cl - first(r) + 1 == 3 || return false
    for i in first(r):cl
        @inbounds(buf[i]) == byte || return false
    end
    return true
end
_front_matter_open(buf, r) = _front_matter_delim(buf, r, UInt8('-'))
_front_matter_close(buf, r) = _front_matter_delim(buf, r, UInt8('-')) ||
                              _front_matter_delim(buf, r, UInt8('.'))

#-------------------------------------------------------------------------------
# Output side

# Leaves must be emitted contiguously; `fb == lb + 1` is a zero-width leaf.
function _emit_leaf!(st::MarkdownParseStream, k::Kind, fb::Int, lb::Int; trivia::Bool=false)
    @assert fb == st.next_byte "non-contiguous leaf: at byte $(st.next_byte), leaf starts at $fb"
    f = trivia ? TRIVIA_FLAG : EMPTY_FLAGS
    push!(st.output, RawGreenNode(SyntaxHead(k, f), lb - fb + 1, k))
    st.next_byte = lb + 1
    return
end

# Wrap everything emitted since `mark` (an output index) into a nonterminal.
function _emit_nonterminal!(st::MarkdownParseStream, k::Kind, mark_node::Int, mark_byte::Int)
    push!(st.output, RawGreenNode(SyntaxHead(k, EMPTY_FLAGS), st.next_byte - mark_byte, length(st.output) - mark_node))
    return
end

#-------------------------------------------------------------------------------
# The scanner

"""
    parse_markdown!(st::MarkdownParseStream)

Scan the whole input into one `md_document`. Never fails: unrecognised input
is prose trivia, and an unclosed fence runs to the end of the input (which is
what CommonMark specifies, not an error).
"""
function parse_markdown!(st::MarkdownParseStream)
    buf = st.textbuf
    doc_mark_node = length(st.output)
    doc_mark_byte = st.next_byte
    lines = _split_lines(buf, st.next_byte, length(buf))
    n = length(lines)

    # Bytes of pending prose (paragraphs, blanks, anything unstructured) are
    # accumulated and emitted as one trivia leaf per maximal run.
    pending_fb = 0
    function flush_pending!(upto::Int)
        pending_fb == 0 && return
        _emit_leaf!(st, K"MdText", pending_fb, upto; trivia=true)
        pending_fb = 0
        return
    end

    i = 1

    # Front matter: only at the very start of the document, only when closed.
    if n >= 1 && _front_matter_open(buf, lines[1])
        j = 2
        while j <= n && !_front_matter_close(buf, lines[j])
            j += 1
        end
        if j <= n
            mark_node = length(st.output)
            mark_byte = st.next_byte
            _emit_leaf!(st, K"MdFrontMatterDelim", first(lines[1]), last(lines[1]))
            _emit_leaf!(st, K"MdFrontMatterContent", last(lines[1]) + 1, first(lines[j]) - 1)
            _emit_leaf!(st, K"MdFrontMatterDelim", first(lines[j]), last(lines[j]))
            _emit_nonterminal!(st, K"md_front_matter", mark_node, mark_byte)
            i = j + 1
        end
    end

    # A 4-column-indented line only opens an indented code block when it does
    # not continue a paragraph (CommonMark: indented code cannot interrupt a
    # paragraph).
    in_paragraph = false

    while i <= n
        r = lines[i]
        fo = _fence_open(buf, r)
        if fo !== nothing
            flush_pending!(first(r) - 1)
            j = i + 1
            while j <= n && !_fence_close(buf, lines[j], fo.char, fo.len)
                j += 1
            end
            mark_node = length(st.output)
            mark_byte = st.next_byte
            _emit_leaf!(st, K"MdFenceDelim", first(r), last(r))
            content_lb = j <= n ? first(lines[j]) - 1 : last(lines[n])
            _emit_leaf!(st, K"MdCode", last(r) + 1, content_lb)
            if j <= n
                _emit_leaf!(st, K"MdFenceDelim", first(lines[j]), last(lines[j]))
            end
            _emit_nonterminal!(st, K"md_code_fence", mark_node, mark_byte)
            i = j + 1
            in_paragraph = false
        elseif _is_blank(buf, r)
            pending_fb == 0 && (pending_fb = first(r))
            i += 1
            in_paragraph = false
        elseif !in_paragraph && _indentation(buf, r)[1] >= 4
            flush_pending!(first(r) - 1)
            # The run: indented and blank lines continue it, trailing blanks
            # are excluded (they go back to prose trivia).
            last_code = i
            j = i + 1
            while j <= n
                if _is_blank(buf, lines[j])
                    j += 1
                elseif _indentation(buf, lines[j])[1] >= 4
                    last_code = j
                    j += 1
                else
                    break
                end
            end
            _emit_leaf!(st, K"MdIndentedCode", first(r), last(lines[last_code]))
            i = last_code + 1
            in_paragraph = false
        elseif _atx_heading(buf, r)
            flush_pending!(first(r) - 1)
            _emit_leaf!(st, K"MdHeading", first(r), last(r))
            i += 1
            in_paragraph = false
        else
            pending_fb == 0 && (pending_fb = first(r))
            i += 1
            in_paragraph = true
        end
    end

    flush_pending!(length(buf))
    _emit_nonterminal!(st, K"md_document", doc_mark_node, doc_mark_byte)
    return st
end
