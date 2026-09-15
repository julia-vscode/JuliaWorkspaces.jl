# Recursive-descent productions over `TomlParseStream`. Tree shape (trivia
# dropped; punctuation is trivia):
#
#   (toml_document entry... (toml_table (toml_key part...) entry...) ...)
#   entry := (toml_keyval (toml_key part...) value)
#   value := TomlInteger | ... | (toml_array value...) | (toml_inline_table entry...)
#
# Sections nest their entries. Recovery is line based: every loop iteration
# consumes a token or breaks, and an error resynchronises at the next line
# terminator (`recover_line!`), so later items survive. Inside an inline
# table recovery also stops at `,` and `}`.

"""
    parse_toml!(st::TomlParseStream) -> st

Parse the whole input into `st.output`, then validate token content.
"""
function parse_toml!(st::TomlParseStream)
    parse_document(st)
    validate_tokens(st)
    return st
end

_toml11(st::TomlParseStream) = st.version >= v"1.1.0"

function parse_document(st::TomlParseStream)
    mark = position(st)
    set_mode!(st, :key)
    section = nothing   # (mark, kind) of the open table section
    while true
        k = peek(st; skip_newlines=true)
        if k == K"EndMarker" || k == K"["
            if section !== nothing
                emit(st, section[1], section[2])
                section = nothing
            end
            bump_trivia(st; skip_newlines=true)
            k == K"EndMarker" && break
            section = parse_header(st)
        else
            bump_trivia(st; skip_newlines=true)
            parse_keyval(st)
        end
        parse_line_end(st)
    end
    emit(st, mark, K"toml_document")
    return
end

# `[key]` or `[[key]]`. The section node is emitted by the caller once its
# entries have been parsed, so they nest under it.
function parse_header(st::TomlParseStream)
    mark = position(st)
    bump(st, TRIVIA_FLAG)   # [
    arr = kind(peek_token(st; skip_whitespace=false)) == K"["
    arr && bump(st, TRIVIA_FLAG)
    bump_trivia(st; skip_newlines=false)
    keymark = position(st)
    parse_key(st)
    ok = false
    if peek(st) == K"]"
        bump(st, TRIVIA_FLAG)
        if !arr
            ok = true
        elseif kind(peek_token(st; skip_whitespace=false)) == K"]"
            bump(st, TRIVIA_FLAG)
            ok = true
        else
            emit_diagnostic(st, ErrExpectedEndArrayOfTable)
        end
    else
        emit_diagnostic(st, arr ? ErrExpectedEndArrayOfTable : ErrExpectedEndOfTable)
    end
    if !ok
        # A malformed header: wrap its key in an error so the table pass
        # detaches the section's entries instead of misfiling them.
        emit(st, keymark, K"error")
        recover_line!(st)
    end
    return (mark, arr ? K"toml_array_table" : K"toml_table")
end

# Trivia before the key has been bumped by the caller.
function parse_keyval(st::TomlParseStream; inline::Bool=false)
    mark = position(st)
    nparts = parse_key(st)
    if peek(st) == K"="
        bump(st, TRIVIA_FLAG)
        set_mode!(st, :value)
        bump_trivia(st; skip_newlines=false)
        parse_value(st; in_collection=inline)
        set_mode!(st, :key)
    elseif nparts > 0
        emit_diagnostic(st, ErrExpectedEqualAfterKey)
        recover_line!(st; inline, always_mark=true)
    end
    # With no key at all, `ErrExpectedKey` has been reported and the
    # offending token is left to the caller.
    emit(st, mark, K"toml_keyval")
    return
end

# Dotted key: parts separated by `.`; whitespace around the dots is trivia.
# Returns the number of parts (an unreadable part counts).
function parse_key(st::TomlParseStream)
    mark = position(st)
    nparts = 0
    while true
        k = peek(st)
        if k == K"TomlBareKey" || k == K"TomlBasicString" || k == K"TomlLiteralString"
            bump(st)
        elseif k == K"TomlMultilineBasicString" || k == K"TomlMultilineLiteralString"
            bump(st; error=ErrMultilineStringAsKey)
        elseif k == K"error"
            bump(st)   # the lexer's diagnostic (invalid bare key character)
        elseif k == K"." && nparts == 0
            bump(st; error=ErrExpectedKey)   # `.a`: a missing first part
            continue
        elseif k == K"=" && nparts == 0
            bump_invisible(st, K"error"; error=ErrEmptyBareKey)
            break
        else
            bump_invisible(st, K"error"; error=ErrExpectedKey)
            break
        end
        nparts += 1
        # Junk glued to a part (`fooα`) belongs to the key.
        while kind(peek_token(st; skip_whitespace=false)) == K"error"
            bump(st)
        end
        peek(st) == K"." || break
        bump(st, TRIVIA_FLAG)
    end
    emit(st, mark, K"toml_key")
    return nparts
end

# Trivia before the value has been bumped by the caller. Inside an array or
# inline table a stray separator or closer is reported but left for the
# enclosing loop to handle.
function parse_value(st::TomlParseStream; in_collection::Bool=false)
    k = peek(st)
    if k == K"["
        parse_array(st)
    elseif k == K"{"
        parse_inline_table(st)
    elseif is_toml_value_token(k) || k == K"error"
        bump(st)
    elseif k == K"EndMarker"
        bump_invisible(st, K"error"; error=ErrUnexpectedEofExpectedValue)
    elseif k == K"NewlineWs"
        bump_invisible(st, K"error"; error=ErrUnexpectedStartOfValue)
    elseif in_collection && (k == K"," || k == K"]" || k == K"}")
        emit_diagnostic(st, ErrUnexpectedStartOfValue)
        bump_invisible(st, K"error")
    else
        bump(st; error=ErrUnexpectedStartOfValue)
    end
    return
end

# A `key =` shape inside an array means its closing bracket is missing: the
# array stops there (before the line's newline, which the caller expects to
# find) instead of swallowing the rest of the file.
function _array_runaway(st::TomlParseStream, k::Kind)
    k == K"=" && return true
    (k == K"error" || is_toml_value_token(k)) || return false
    return peek(st, 2; skip_newlines=true) == K"="
end

# Newlines and comments may appear anywhere inside the brackets.
function parse_array(st::TomlParseStream)
    mark = position(st)
    bump(st, TRIVIA_FLAG)   # [
    while true
        k = peek(st; skip_newlines=true)
        if _array_runaway(st, k)
            bump_invisible(st, K"error"; error=ErrExpectedEndOfArray)
            break
        end
        bump_trivia(st; skip_newlines=true)
        if k == K"]"
            bump(st, TRIVIA_FLAG)
            break
        elseif k == K"EndMarker"
            bump_invisible(st, K"error"; error=ErrUnexpectedEofExpectedValue)
            break
        end
        parse_value(st; in_collection=true)
        k = peek(st; skip_newlines=true)
        if _array_runaway(st, k)
            bump_invisible(st, K"error"; error=ErrExpectedEndOfArray)
            break
        end
        bump_trivia(st; skip_newlines=true)
        if k == K","
            bump(st, TRIVIA_FLAG)
        elseif k == K"]"
            bump(st, TRIVIA_FLAG)
            break
        elseif k == K"EndMarker"
            bump_invisible(st, K"error"; error=ErrExpectedCommaBetweenItemsArray)
            break
        else
            bump_invisible(st, K"error"; error=ErrExpectedCommaBetweenItemsArray)
        end
    end
    emit(st, mark, K"toml_array")
    return
end

# TOML 1.0: single line, no trailing comma. (1.1 relaxes both; gated on the
# stream's version so the hooks exist, untested until 1.1 is implemented.)
function parse_inline_table(st::TomlParseStream)
    mark = position(st)
    multiline = _toml11(st)
    bump(st, TRIVIA_FLAG)   # {
    set_mode!(st, :key)
    bump_trivia(st; skip_newlines=multiline)
    if peek(st; skip_newlines=multiline) == K"}"
        bump(st, TRIVIA_FLAG)
    else
        while true
            parse_keyval(st; inline=true)
            bump_trivia(st; skip_newlines=multiline)
            k = peek(st; skip_newlines=multiline)
            if k == K"}"
                bump(st, TRIVIA_FLAG)
                break
            elseif k == K","
                bump(st, TRIVIA_FLAG)
                bump_trivia(st; skip_newlines=multiline)
                k = peek(st; skip_newlines=multiline)
                if k == K"}"
                    multiline || bump_invisible(st, K"error"; error=ErrTrailingCommaInlineTable)
                    bump(st, TRIVIA_FLAG)
                    break
                elseif k == K"NewlineWs" || k == K"EndMarker"
                    bump_invisible(st, K"error"; error=ErrExpectedKey)
                    break
                end
            else
                bump_invisible(st, K"error"; error=ErrExpectedCommaBetweenItemsInlineTable)
                break
            end
        end
    end
    set_mode!(st, :value)
    emit(st, mark, K"toml_inline_table")
    return
end

# After a statement only trailing whitespace, a comment, a newline or the end
# of input may follow.
function parse_line_end(st::TomlParseStream)
    k = peek(st)
    (k == K"NewlineWs" || k == K"EndMarker") && return
    emit_diagnostic(st, ErrExpectedNewLineKeyValue)
    recover_line!(st)
    return
end

# Skip to the end of the line (or, inside an inline table, to the next `,`
# or `}`), wrapping whatever was there in an error node (a zero-width one
# when `always_mark` is set and nothing was skipped, so the construct still
# carries its error). The skipped tokens' own lexer errors are not reported:
# one diagnostic per broken line is enough.
function recover_line!(st::TomlParseStream; inline::Bool=false, always_mark::Bool=false)
    mark = position(st)
    while true
        k = peek(st)
        (k == K"NewlineWs" || k == K"EndMarker") && break
        inline && (k == K"," || k == K"}") && break
        bump(st; report_errors=false)
    end
    if position(st) != mark
        emit(st, mark, K"error")
    elseif always_mark
        bump_invisible(st, K"error")
    end
    set_mode!(st, :key)
    return
end
