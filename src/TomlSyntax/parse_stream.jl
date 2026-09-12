# The output stream: an adapted copy of JuliaSyntax's `ParseStream`
# (core/parse_stream.jl), whose lookahead is hard-wired to the Julia lexer.
# Everything the parser sees is the same mark/peek/bump/emit API; the output
# is JuliaSyntax's flat postorder `RawGreenNode` buffer, so its cursors and
# `GreenNode` work on it unchanged.

struct TomlToken
    head::SyntaxHead
    err::Union{Nothing,TomlErrorKind}
    next_byte::UInt32
end
JuliaSyntax.head(t::TomlToken) = t.head

const TOML_DEFAULT_VERSION = v"1.0.0"

"""
    TomlParseStream(text; version=v"1.0.0")

Parser input/output over `text` (a `String`, `SubString{String}`,
`Vector{UInt8}` or `IO`). `version` is the TOML spec version to parse for;
only 1.0 is implemented today.
"""
mutable struct TomlParseStream
    textbuf::Vector{UInt8}
    text_root::Any
    lexer::TomlLexer
    lookahead::Vector{TomlToken}
    lookahead_index::Int
    output::Vector{RawGreenNode}
    next_byte::Int
    diagnostics::Vector{TomlDiagnostic}
    peek_count::Int
    version::VersionNumber

    function TomlParseStream(text_buf::Vector{UInt8}, text_root, next_byte::Integer, version::VersionNumber)
        nb = Int(next_byte)
        # A leading byte order mark is ignored (it sits inside the sentinel).
        if nb + 2 <= length(text_buf) && text_buf[nb] == 0xef && text_buf[nb+1] == 0xbb && text_buf[nb+2] == 0xbf
            nb += 3
        end
        sentinel = RawGreenNode(SyntaxHead(K"TOMBSTONE", EMPTY_FLAGS), nb - 1, K"TOMBSTONE")
        return new(text_buf, text_root, TomlLexer(text_buf, nb), TomlToken[], 1,
                   RawGreenNode[sentinel], nb, TomlDiagnostic[], 0, version)
    end
end

TomlParseStream(text::Vector{UInt8}, index::Integer=1; version=TOML_DEFAULT_VERSION) =
    TomlParseStream(text, text, index, version)
TomlParseStream(text::String, index::Integer=1; version=TOML_DEFAULT_VERSION) =
    TomlParseStream(unsafe_wrap(Vector{UInt8}, text), text, index, version)
TomlParseStream(text::SubString{String}, index::Integer=1; version=TOML_DEFAULT_VERSION) =
    TomlParseStream(unsafe_wrap(Vector{UInt8}, pointer(text), sizeof(text)), text, index, version)
TomlParseStream(text::AbstractString, index::Integer=1; version=TOML_DEFAULT_VERSION) =
    TomlParseStream(String(text), index; version)
function TomlParseStream(io::IO; version=TOML_DEFAULT_VERSION)
    buf = read(io)
    return TomlParseStream(buf, buf, 1, version)
end

function Base.show(io::IO, ::MIME"text/plain", st::TomlParseStream)
    print(io, "TomlParseStream at position ", st.next_byte)
end

"Switch the lexer mode; unbumped lookahead is discarded and re-lexed."
function set_mode!(st::TomlParseStream, mode::Symbol)
    st.lexer.mode === mode && return
    empty!(st.lookahead)
    st.lookahead_index = 1
    st.lexer.pos = st.next_byte
    st.lexer.mode = mode
    return
end

#-------------------------------------------------------------------------------
# Input side

# Lex up to and including the next non-trivia token, so a mode switch never
# throws away more than one classified token.
function _fill_lookahead!(st::TomlParseStream)
    while true
        raw = next_token(st.lexer)
        push!(st.lookahead, TomlToken(SyntaxHead(raw.kind, EMPTY_FLAGS), raw.err, UInt32(raw.next_byte)))
        is_toml_trivia(raw.kind) || return
    end
end

function _lookahead_index(st::TomlParseStream, n::Integer, skip_newlines::Bool)
    i = st.lookahead_index
    while true
        if i > length(st.lookahead)
            if st.lookahead_index > 64
                ndel = st.lookahead_index - 1
                deleteat!(st.lookahead, 1:ndel)
                i -= ndel
                st.lookahead_index = 1
            end
            _fill_lookahead!(st)
            continue
        end
        k = kind(@inbounds st.lookahead[i])
        if !(k == K"Whitespace" || k == K"Comment" || (k == K"NewlineWs" && skip_newlines))
            n == 1 && return i
            n -= 1
        end
        i += 1
    end
end

@noinline _parser_stuck_error(st) = error("The parser seems stuck at byte $(st.next_byte)")

function _lookahead_token_first_byte(st, i)
    return i == 1 ? st.next_byte : Int(st.lookahead[i-1].next_byte)
end

"""
    peek_token(st, n=1; skip_newlines=false, skip_whitespace=true)

The `n`th upcoming non-trivia token (or the very next raw token when
`skip_whitespace` is false). Newlines are significant unless `skip_newlines`.
"""
function peek_token(st::TomlParseStream, n::Integer=1; skip_newlines::Bool=false, skip_whitespace::Bool=true)
    st.peek_count += 1
    st.peek_count > 100_000 && _parser_stuck_error(st)
    i = _lookahead_index(st, n, skip_newlines)
    skip_whitespace || (i = st.lookahead_index)
    return @inbounds st.lookahead[i]
end

"Like `peek_token`, returning only the kind."
Base.peek(st::TomlParseStream, n::Integer=1; skip_newlines::Bool=false, skip_whitespace::Bool=true) =
    kind(peek_token(st, n; skip_newlines, skip_whitespace))

#-------------------------------------------------------------------------------
# Output side

function _emit_token_diagnostic!(st::TomlParseStream, code::TomlErrorKind, fb::Int, lb::Int)
    detail = if code == ErrInvalidBareKeyCharacter
        ": '" * escape_string(String(st.textbuf[fb:lb])) * "'"
    else
        ""
    end
    push!(st.diagnostics, TomlDiagnostic(code, fb, lb; detail))
    return
end

# Copy lookahead tokens up to index `n` into the output.
function _bump_until_n(st::TomlParseStream, n::Integer, new_flags::RawFlags, remap_kind::Kind, report_errors::Bool)
    n < st.lookahead_index && return
    for i in st.lookahead_index:n
        tok = st.lookahead[i]
        k = kind(tok)
        k == K"EndMarker" && break
        f = new_flags | flags(tok)
        trivia = is_toml_trivia(k)
        trivia && (f |= TRIVIA_FLAG)
        outk = (trivia || remap_kind == K"None") ? k : remap_kind
        prev_byte = i == st.lookahead_index ? st.next_byte : Int(st.lookahead[i-1].next_byte)
        byte_span = Int(tok.next_byte) - prev_byte
        if report_errors && tok.err !== nothing
            _emit_token_diagnostic!(st, tok.err, prev_byte, prev_byte + byte_span - 1)
        end
        push!(st.output, RawGreenNode(SyntaxHead(outk, f), byte_span, k))
        st.next_byte += byte_span
    end
    st.lookahead_index = n + 1
    st.peek_count = 0
    return
end

"""
    bump(st, flags=EMPTY_FLAGS; skip_newlines=false, error=nothing, remap_kind=K"None", report_errors=true)

Move the next non-trivia token (and the trivia before it) to the output.
`error` wraps the token in a `K"error"` node with a diagnostic of that code.
"""
function bump(st::TomlParseStream, flags::RawFlags=EMPTY_FLAGS; skip_newlines::Bool=false,
              error::Union{Nothing,TomlErrorKind}=nothing, remap_kind::Kind=K"None",
              report_errors::Bool=true)
    mark = position(st)
    _bump_until_n(st, _lookahead_index(st, 1, skip_newlines), flags, remap_kind, report_errors)
    error === nothing || emit(st, mark, K"error"; error)
    return position(st)
end

"Move the trivia before the next token to the output (newlines too, by default)."
function bump_trivia(st::TomlParseStream; skip_newlines::Bool=true)
    _bump_until_n(st, _lookahead_index(st, 1, skip_newlines) - 1, EMPTY_FLAGS, K"None", true)
    return position(st)
end

"Push a zero-width token of `kind`; `error` attaches a zero-width diagnostic."
function bump_invisible(st::TomlParseStream, kind::Kind, flags::RawFlags=EMPTY_FLAGS;
                        error::Union{Nothing,TomlErrorKind}=nothing)
    b = st.next_byte
    push!(st.output, RawGreenNode(SyntaxHead(kind, flags), 0, kind))
    error === nothing || emit_diagnostic(st, b:b-1, error)
    st.peek_count = 0
    return position(st)
end

"The current output position, for a later `emit`."
Base.position(st::TomlParseStream) = ParseStreamPosition(st.next_byte, length(st.output))

"""
    emit(st, mark, kind, flags=EMPTY_FLAGS; error=nothing)

Emit a nonterminal of `kind` covering everything output since `mark`.
"""
function emit(st::TomlParseStream, mark::ParseStreamPosition, kind::Kind, flags::RawFlags=EMPTY_FLAGS;
              error::Union{Nothing,TomlErrorKind}=nothing)
    byte_span = st.next_byte - Int(mark.byte_index)
    node_span = length(st.output) - Int(mark.node_index)
    error === nothing || emit_diagnostic(st, Int(mark.byte_index):st.next_byte-1, error)
    push!(st.output, RawGreenNode(SyntaxHead(kind, flags), byte_span, node_span))
    return position(st)
end

"Record a diagnostic of `code` over a 1-based inclusive byte range."
function emit_diagnostic(st::TomlParseStream, byterange::AbstractUnitRange, code::TomlErrorKind;
                         detail::AbstractString="", level::Symbol=:error)
    push!(st.diagnostics, TomlDiagnostic(code, first(byterange), last(byterange); detail, level))
    return
end

# At the next token; zero-width in front of a newline or the end of input.
function emit_diagnostic(st::TomlParseStream, code::TomlErrorKind; detail::AbstractString="")
    i = _lookahead_index(st, 1, false)
    tok = st.lookahead[i]
    k = kind(tok)
    fb = _lookahead_token_first_byte(st, i)
    lb = (k == K"NewlineWs" || k == K"EndMarker") ? fb - 1 : Int(tok.next_byte) - 1
    emit_diagnostic(st, fb:lb, code; detail)
    return
end

#-------------------------------------------------------------------------------
# Results

JuliaSyntax.first_byte(st::TomlParseStream) = Int(first(st.output).byte_span) + 1
JuliaSyntax.last_byte(st::TomlParseStream) = st.next_byte - 1
JuliaSyntax.any_error(st::TomlParseStream) = any_error(st.diagnostics)

function JuliaSyntax.SourceFile(st::TomlParseStream; kws...)
    fbyte = first_byte(st)
    lbyte = last_byte(st)
    if !isempty(st.diagnostics)
        lbyte = max(lbyte, maximum(last_byte(d) for d in st.diagnostics))
    end
    root = st.text_root
    str = if root isa String || root isa SubString{String}
        SubString(root, fbyte, thisind(root, lbyte))
    else
        SubString(String(st.textbuf[fbyte:lbyte]))
    end
    return SourceFile(str; first_index=fbyte, kws...)
end

JuliaSyntax.show_diagnostics(io::IO, st::TomlParseStream) =
    show_diagnostics(io, st.diagnostics, SourceFile(st))
