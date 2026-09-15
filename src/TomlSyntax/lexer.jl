# Byte-level lexer. It DELIMITS tokens only; token content (escapes, control
# characters, UTF-8, date ranges) is checked by `validate_tokens` and converted
# by `parse_toml_literal`, the same split JuliaSyntax uses.
#
# TOML tokens are context dependent: `1979-05-27` is a bare key before `=` and
# a date after it, so the parser drives the lexer through two modes, `:key`
# (headers, keys) and `:value`. Number/date words are classified here because
# their fine-grained error codes depend on the word's shape, and the ported
# stdlib tests pin those codes.

mutable struct TomlLexer
    buf::Vector{UInt8}
    pos::Int    # index of the next unread byte
    last::Int   # last valid index of `buf`
    mode::Symbol
end
TomlLexer(buf::Vector{UInt8}, pos::Integer) = TomlLexer(buf, Int(pos), length(buf), :key)

"A lexed token: its kind, an error code when the kind is `K\"error\"`, and the index after it."
struct TomlRawToken
    kind::Kind
    err::Union{Nothing,TomlErrorKind}
    next_byte::Int
end

@inline _is_digit(c::UInt8) = UInt8('0') <= c <= UInt8('9')
@inline _is_bare_key_byte(c::UInt8) =
    (UInt8('a') <= c <= UInt8('z')) || (UInt8('A') <= c <= UInt8('Z')) || _is_digit(c) ||
    c == UInt8('_') || c == UInt8('-')
@inline _is_word_byte(c::UInt8) =
    _is_bare_key_byte(c) || c == UInt8('.') || c == UInt8('+') || c == UInt8(':')
@inline _is_hex(c::UInt8) = _is_digit(c) || (UInt8('a') <= c <= UInt8('f')) || (UInt8('A') <= c <= UInt8('F'))
@inline _is_oct(c::UInt8) = UInt8('0') <= c <= UInt8('7')
@inline _is_bin(c::UInt8) = c == UInt8('0') || c == UInt8('1')

@inline function _at_newline(buf, j, n)
    c = buf[j]
    return c == UInt8('\n') || (c == UInt8('\r') && j < n && buf[j+1] == UInt8('\n'))
end

# Index after the UTF-8 sequence starting at `i` (by lead byte, not validated).
function _utf8_next(buf, i, n)
    c = buf[i]
    len = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4
    return min(i + len, n + 1)
end

function _starts_with(buf, i, n, s::String)
    m = ncodeunits(s)
    i + m - 1 <= n || return false
    for k in 1:m
        buf[i+k-1] == codeunit(s, k) || return false
    end
    return true
end

@inline function _emit_raw(lx::TomlLexer, k::Kind, err, next::Int)
    lx.pos = next
    return TomlRawToken(k, err, next)
end

"Lex the next token from `lx` in its current mode."
function next_token(lx::TomlLexer)
    buf = lx.buf
    n = lx.last
    i = lx.pos
    i > n && return _emit_raw(lx, K"EndMarker", nothing, i)
    c = buf[i]
    if c == UInt8(' ') || c == UInt8('\t')
        j = i + 1
        while j <= n && (buf[j] == UInt8(' ') || buf[j] == UInt8('\t'))
            j += 1
        end
        return _emit_raw(lx, K"Whitespace", nothing, j)
    elseif c == UInt8('\n')
        return _emit_raw(lx, K"NewlineWs", nothing, i + 1)
    elseif c == UInt8('\r')
        if i < n && buf[i+1] == UInt8('\n')
            return _emit_raw(lx, K"NewlineWs", nothing, i + 2)
        end
        return _emit_raw(lx, K"error", ErrUnexpectedCharacter, i + 1)
    elseif c == UInt8('#')
        j = i + 1
        while j <= n && !_at_newline(buf, j, n)
            j += 1
        end
        return _emit_raw(lx, K"Comment", nothing, j)
    elseif c == UInt8('"')
        return _lex_string(lx, i, UInt8('"'), true)
    elseif c == UInt8('\'')
        return _lex_string(lx, i, UInt8('\''), false)
    elseif c == UInt8('=')
        return _emit_raw(lx, K"=", nothing, i + 1)
    elseif c == UInt8('[')
        return _emit_raw(lx, K"[", nothing, i + 1)
    elseif c == UInt8(']')
        return _emit_raw(lx, K"]", nothing, i + 1)
    elseif c == UInt8('{')
        return _emit_raw(lx, K"{", nothing, i + 1)
    elseif c == UInt8('}')
        return _emit_raw(lx, K"}", nothing, i + 1)
    elseif c == UInt8(',')
        return _emit_raw(lx, K",", nothing, i + 1)
    elseif lx.mode === :key
        c == UInt8('.') && return _emit_raw(lx, K".", nothing, i + 1)
        if _is_bare_key_byte(c)
            j = i + 1
            while j <= n && _is_bare_key_byte(buf[j])
                j += 1
            end
            return _emit_raw(lx, K"TomlBareKey", nothing, j)
        end
        return _emit_raw(lx, K"error", ErrInvalidBareKeyCharacter, _utf8_next(buf, i, n))
    else
        if c == UInt8('t') && _starts_with(buf, i, n, "true")
            return _emit_raw(lx, K"TomlBool", nothing, i + 4)
        elseif c == UInt8('f') && _starts_with(buf, i, n, "false")
            return _emit_raw(lx, K"TomlBool", nothing, i + 5)
        elseif _is_word_byte(c)
            return _lex_word(lx, i)
        end
        return _emit_raw(lx, K"error", ErrUnexpectedStartOfValue, _utf8_next(buf, i, n))
    end
end

# Strings. `q` is the quote byte; `basic` strings have backslash escapes.
# A multi-line string closes on a run of >= 3 quotes, consuming at most 5 so
# that `""""str""""` and `""" """""` keep their extra quotes as content.
function _lex_string(lx::TomlLexer, i::Int, q::UInt8, basic::Bool)
    buf = lx.buf
    n = lx.last
    if i + 2 <= n && buf[i+1] == q && buf[i+2] == q
        k = basic ? K"TomlMultilineBasicString" : K"TomlMultilineLiteralString"
        j = i + 3
        while true
            j > n && return _emit_raw(lx, K"error", ErrUnexpectedEndString, n + 1)
            c = buf[j]
            if basic && c == UInt8('\\')
                j += 2
            elseif c == q
                e = j
                while e <= n && buf[e] == q
                    e += 1
                end
                run = e - j
                run >= 3 && return _emit_raw(lx, k, nothing, j + min(run, 5))
                j = e
            else
                j += 1
            end
        end
    else
        k = basic ? K"TomlBasicString" : K"TomlLiteralString"
        j = i + 1
        while true
            j > n && return _emit_raw(lx, K"error", ErrUnexpectedEndString, n + 1)
            c = buf[j]
            if basic && c == UInt8('\\')
                j += 2
            elseif c == q
                return _emit_raw(lx, k, nothing, j + 1)
            elseif _at_newline(buf, j, n)
                return _emit_raw(lx, K"error", ErrNewLineInString, j)
            else
                j += 1
            end
        end
    end
end

# Numbers, dates and times: take the maximal "word" and classify its shape.
function _lex_word(lx::TomlLexer, i::Int)
    buf = lx.buf
    n = lx.last
    j = i
    while j <= n && _is_word_byte(buf[j])
        j += 1
    end
    # `1979-05-27 07:32:00`: a space may separate date and time.
    if j - i == 10 && _looks_like_date(buf, i) && j < n && buf[j] == UInt8(' ') && _is_digit(buf[j+1])
        j += 1
        while j <= n && _is_word_byte(buf[j])
            j += 1
        end
    end
    k, err = _classify_word(buf, i, j - 1)
    return _emit_raw(lx, err === nothing ? k : K"error", err, j)
end

_looks_like_date(buf, s) =
    _is_digit(buf[s]) && _is_digit(buf[s+1]) && _is_digit(buf[s+2]) && _is_digit(buf[s+3]) &&
    buf[s+4] == UInt8('-') && _is_digit(buf[s+5]) && _is_digit(buf[s+6]) && buf[s+7] == UInt8('-') &&
    _is_digit(buf[s+8]) && _is_digit(buf[s+9])

# Digits (per `pred`) with underscores strictly between digits. Returns the
# index after the run and an error code or `nothing`.
function _scan_digits(buf, s, b, pred)
    j = s
    seen_digit = false
    after_underscore = false
    while j <= b
        c = buf[j]
        if c == UInt8('_')
            (after_underscore || !seen_digit) && return j, ErrUnderscoreNotSurroundedByDigits
            after_underscore = true
        elseif pred(c)
            seen_digit = true
            after_underscore = false
        else
            break
        end
        j += 1
    end
    after_underscore && return j, ErrTrailingUnderscoreNumber
    return j, nothing
end

function _classify_word(buf, a, b)
    s = a
    signed = buf[a] == UInt8('+') || buf[a] == UInt8('-')
    signed && (s += 1)
    s > b && return K"error", ErrGenericValueError
    len = b - s + 1
    if len == 3 && (_starts_with(buf, s, b, "inf") || _starts_with(buf, s, b, "nan"))
        return K"TomlFloat", nothing
    end
    buf[s] == UInt8('.') && return K"error", ErrLeadingDot
    if len >= 2 && buf[s] == UInt8('0') &&
            (buf[s+1] == UInt8('x') || buf[s+1] == UInt8('o') || buf[s+1] == UInt8('b'))
        signed && return K"error", ErrSignInNonBase10Number
        pred = buf[s+1] == UInt8('x') ? _is_hex : buf[s+1] == UInt8('o') ? _is_oct : _is_bin
        j, err = _scan_digits(buf, s + 2, b, pred)
        err === nothing || return K"error", err
        (j == s + 2 || j <= b) && return K"error", ErrGenericValueError
        return K"TomlInteger", nothing
    end
    if len >= 5 && _is_digit(buf[s]) && _is_digit(buf[s+1]) && _is_digit(buf[s+2]) &&
            _is_digit(buf[s+3]) && buf[s+4] == UInt8('-')
        signed && return K"error", ErrParsingDateTime
        return _classify_datetime(buf, s, b)
    end
    if len >= 3 && _is_digit(buf[s]) && _is_digit(buf[s+1]) && buf[s+2] == UInt8(':')
        signed && return K"error", ErrParsingDateTime
        return _time_shape_ok(buf, s, b) ? (K"TomlLocalTime", nothing) : (K"error", ErrParsingDateTime)
    end
    # Decimal integer or float.
    buf[s] == UInt8('_') && return K"error", ErrUnexpectedStartOfValue
    _is_digit(buf[s]) || return K"error", ErrGenericValueError
    # Base's quirk, kept for parity: `0_` is "not surrounded", not "trailing".
    if buf[s] == UInt8('0') && s < b && buf[s+1] == UInt8('_')
        return K"error", ErrUnderscoreNotSurroundedByDigits
    end
    j, err = _scan_digits(buf, s, b, _is_digit)
    err === nothing || return K"error", err
    if buf[s] == UInt8('0') && j - s > 1
        return K"error", ErrLeadingZeroNotAllowedInteger
    end
    isfloat = false
    if j <= b && buf[j] == UInt8('.')
        isfloat = true
        j += 1
        (j > b || !_is_digit(buf[j])) && return K"error", ErrNoTrailingDigitAfterDot
        j, err = _scan_digits(buf, j, b, _is_digit)
        err === nothing || return K"error", err
    end
    if j <= b && (buf[j] == UInt8('e') || buf[j] == UInt8('E'))
        isfloat = true
        j += 1
        j <= b && (buf[j] == UInt8('+') || buf[j] == UInt8('-')) && (j += 1)
        (j > b || !_is_digit(buf[j])) && return K"error", ErrGenericValueError
        j, err = _scan_digits(buf, j, b, _is_digit)
        err === nothing || return K"error", err
    end
    j <= b && return K"error", ErrGenericValueError
    return isfloat ? K"TomlFloat" : K"TomlInteger", nothing
end

# `HH:MM:SS(.digits)?` occupying exactly s..b.
function _time_shape_ok(buf, s, b)
    b - s + 1 >= 8 || return false
    ok = _is_digit(buf[s]) && _is_digit(buf[s+1]) && buf[s+2] == UInt8(':') &&
         _is_digit(buf[s+3]) && _is_digit(buf[s+4]) && buf[s+5] == UInt8(':') &&
         _is_digit(buf[s+6]) && _is_digit(buf[s+7])
    ok || return false
    j = s + 8
    j > b && return true
    buf[j] == UInt8('.') || return false
    j += 1
    j > b && return false
    while j <= b
        _is_digit(buf[j]) || return false
        j += 1
    end
    return true
end

# Date family. Shape only; ranges are the validate pass's job.
function _classify_datetime(buf, s, b)
    (b - s + 1 >= 10 && _looks_like_date(buf, s)) || return K"error", ErrParsingDateTime
    j = s + 10
    j > b && return K"TomlLocalDate", nothing
    sep = buf[j]
    (sep == UInt8('T') || sep == UInt8('t') || sep == UInt8(' ')) || return K"error", ErrParsingDateTime
    j += 1
    # The time part runs to the offset marker, if any.
    e = j
    while e <= b && (_is_digit(buf[e]) || buf[e] == UInt8(':') || buf[e] == UInt8('.'))
        e += 1
    end
    _time_shape_ok(buf, j, e - 1) || return K"error", ErrParsingDateTime
    e > b && return K"TomlLocalDateTime", nothing
    c = buf[e]
    if c == UInt8('Z') || c == UInt8('z')
        return e == b ? (K"TomlOffsetDateTime", nothing) : (K"error", ErrParsingDateTime)
    elseif c == UInt8('+') || c == UInt8('-')
        ok = b - e == 5 && _is_digit(buf[e+1]) && _is_digit(buf[e+2]) && buf[e+3] == UInt8(':') &&
             _is_digit(buf[e+4]) && _is_digit(buf[e+5])
        return ok ? (K"TomlOffsetDateTime", nothing) : (K"error", ErrParsingDateTime)
    end
    return K"error", ErrParsingDateTime
end

"""
    tokenize(text; mode=:key) -> Vector{Tuple{Kind,Union{Nothing,TomlErrorKind},UnitRange{Int}}}

Lex `text` from start to end in one fixed mode. A debugging and testing aid;
the parser switches modes as it goes.
"""
function tokenize(text::AbstractString; mode::Symbol=:key)
    str = String(text)
    buf = unsafe_wrap(Vector{UInt8}, str)
    lx = TomlLexer(buf, 1)
    lx.mode = mode
    toks = Tuple{Kind,Union{Nothing,TomlErrorKind},UnitRange{Int}}[]
    start = 1
    GC.@preserve str while true
        t = next_token(lx)
        push!(toks, (t.kind, t.err, start:t.next_byte-1))
        t.kind == K"EndMarker" && break
        start = t.next_byte
    end
    return toks
end
