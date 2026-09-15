# Token content validation, run once over the output after parsing (the
# pattern of JuliaSyntax's `validate_tokens`). Offending tokens get a
# diagnostic and their head rewritten to `K"error"`, so a later
# `parse_toml_literal` never sees invalid content.

# Length of the valid UTF-8 sequence at `j`, or 0 when invalid.
function _utf8_seq_len(buf, j, last)
    c = buf[j]
    c < 0x80 && return 1
    if 0xc2 <= c <= 0xdf
        len, lo, hi = 2, 0x80, 0xbf
    elseif 0xe0 <= c <= 0xef
        len = 3
        lo = c == 0xe0 ? 0xa0 : 0x80
        hi = c == 0xed ? 0x9f : 0xbf
    elseif 0xf0 <= c <= 0xf4
        len = 4
        lo = c == 0xf0 ? 0x90 : 0x80
        hi = c == 0xf4 ? 0x8f : 0xbf
    else
        return 0
    end
    j + len - 1 <= last || return 0
    (lo <= buf[j+1] <= hi) || return 0
    for i in j+2:j+len-1
        (0x80 <= buf[i] <= 0xbf) || return 0
    end
    return len
end

@inline _is_control(c::UInt8) = c < 0x20 || c == 0x7f

# Checks the bytes a..b of a string (basic strings also have escapes).
# Returns true when a diagnostic was emitted.
function _validate_text!(st::TomlParseStream, buf, a::Int, b::Int; basic::Bool, multiline::Bool,
                         control_code::TomlErrorKind)
    bad = false
    j = a
    while j <= b
        c = buf[j]
        if basic && c == UInt8('\\')
            if j == b
                emit_diagnostic(st, j:j, ErrInvalidEscapeCharacter)
                return true
            end
            e = buf[j+1]
            if e == UInt8('b') || e == UInt8('t') || e == UInt8('n') || e == UInt8('f') ||
                    e == UInt8('r') || e == UInt8('"') || e == UInt8('\\')
                j += 2
            elseif e == UInt8('u') || e == UInt8('U')
                n = e == UInt8('u') ? 4 : 8
                ok = j + 1 + n <= b && all(i -> _is_hex(buf[i]), j+2:j+1+n)
                if ok
                    cp = _hex_value(buf, j + 2, n)
                    ok = cp <= 0xD7FF || 0xE000 <= cp <= 0x10FFFF
                end
                if !ok
                    emit_diagnostic(st, j:min(j + 1 + n, b), ErrInvalidUnicodeScalar)
                    bad = true
                end
                j += 2 + n
            elseif multiline && _is_toml_ws(e)
                # Line-ending backslash: only whitespace may precede the newline.
                i = j + 1
                while i <= b && (buf[i] == UInt8(' ') || buf[i] == UInt8('\t'))
                    i += 1
                end
                if !(i <= b && (buf[i] == UInt8('\n') || (buf[i] == UInt8('\r') && i < b && buf[i+1] == UInt8('\n'))))
                    emit_diagnostic(st, j:j+1, ErrInvalidEscapeCharacter)
                    bad = true
                end
                j += 2
            else
                e_end = _utf8_next(buf, j + 1, b) - 1
                emit_diagnostic(st, j:e_end, ErrInvalidEscapeCharacter)
                bad = true
                j = e_end + 1
            end
        elseif _is_control(c)
            if c == UInt8('\t') || (multiline && (c == UInt8('\n') || (c == UInt8('\r') && j < b && buf[j+1] == UInt8('\n'))))
                j += c == UInt8('\r') ? 2 : 1
            else
                emit_diagnostic(st, j:j, control_code)
                bad = true
                j += 1
            end
        elseif c >= 0x80
            len = _utf8_seq_len(buf, j, b)
            if len == 0
                # One diagnostic per bad sequence: the lead byte and whatever
                # continuation bytes follow it.
                e = j + 1
                while e <= b && 0x80 <= buf[e] <= 0xbf
                    e += 1
                end
                emit_diagnostic(st, j:e-1, ErrInvalidUTF8)
                bad = true
                j = e
            else
                j += len
            end
        else
            j += 1
        end
    end
    return bad
end

function _validate_datetime!(st::TomlParseStream, buf, a::Int, b::Int, k::Kind)
    p = _datetime_parts(buf, a, b, k)
    ok = true
    if p.has_date
        ok &= Dates.validargs(Dates.Date, p.year, p.month, p.day) === nothing
    end
    if p.has_time
        ok &= p.hour <= 23 && p.minute <= 59 && p.second <= 60
    end
    if p.has_offset
        ok &= p.offset_hours <= 23 && p.offset_minutes <= 59
    end
    ok && return false
    emit_diagnostic(st, a:b, ErrParsingDateTime)
    return true
end

"Validate token content across the whole output; see the file header."
function validate_tokens(st::TomlParseStream)
    buf = st.textbuf
    fbyte = first_byte(st)
    for i in 2:length(st.output)
        node = st.output[i]
        is_terminal(node) || continue
        nbyte = fbyte + Int(node.byte_span)
        a = fbyte
        b = nbyte - 1
        fbyte = nbyte
        k = kind(node)
        bad = if k == K"TomlBasicString"
            _validate_text!(st, buf, a + 1, b - 1; basic=true, multiline=false, control_code=ErrControlCharacterInString)
        elseif k == K"TomlMultilineBasicString"
            _validate_text!(st, buf, a + 3, b - 3; basic=true, multiline=true, control_code=ErrControlCharacterInString)
        elseif k == K"TomlLiteralString"
            _validate_text!(st, buf, a + 1, b - 1; basic=false, multiline=false, control_code=ErrControlCharacterInString)
        elseif k == K"TomlMultilineLiteralString"
            _validate_text!(st, buf, a + 3, b - 3; basic=false, multiline=true, control_code=ErrControlCharacterInString)
        elseif k == K"Comment"
            _validate_text!(st, buf, a + 1, b; basic=false, multiline=false, control_code=ErrControlCharacterInComment)
        elseif is_toml_datetime(k)
            _validate_datetime!(st, buf, a, b, k)
        else
            false
        end
        if bad
            st.output[i] = RawGreenNode(SyntaxHead(K"error", flags(node)), node.byte_span, node.orig_kind)
        end
    end
    sort!(st.diagnostics; by=first_byte)
    return st
end
