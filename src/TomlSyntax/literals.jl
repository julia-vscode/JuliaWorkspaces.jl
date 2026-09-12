# Leaf value conversion. Runs on tokens the validate pass has accepted, so it
# never reports errors itself.

"""
    OffsetDateTime(datetime::Dates.DateTime, offset_minutes::Int)

A TOML offset date-time: the wall-clock `datetime` as written plus the UTC
offset in minutes (`Z` is 0). `Dates.DateTime(x)` converts to UTC.
"""
struct OffsetDateTime
    datetime::Dates.DateTime
    offset_minutes::Int
end

Dates.DateTime(x::OffsetDateTime) = x.datetime - Dates.Minute(x.offset_minutes)

function Base.show(io::IO, x::OffsetDateTime)
    print(io, "OffsetDateTime(", x.datetime, ", ")
    o = x.offset_minutes
    if o == 0
        print(io, "Z")
    else
        print(io, o < 0 ? '-' : '+', lpad(abs(o) ÷ 60, 2, '0'), ':', lpad(abs(o) % 60, 2, '0'))
    end
    print(io, ")")
end

_substr(buf::Vector{UInt8}, a::Int, b::Int) = b < a ? "" : String(buf[a:b])

# The fields of a date/time token whose SHAPE the lexer accepted.
function _datetime_parts(buf::Vector{UInt8}, a::Int, b::Int, k::Kind)
    d(j) = Int(buf[j] - UInt8('0'))
    read2(j) = 10 * d(j) + d(j + 1)
    j = a
    has_date = k != K"TomlLocalTime"
    year = month = day = 0
    if has_date
        year = 1000 * d(a) + 100 * d(a + 1) + 10 * d(a + 2) + d(a + 3)
        month = read2(a + 5)
        day = read2(a + 8)
        j = a + 10
    end
    has_time = j <= b
    hour = minute = second = ms = 0
    has_offset = false
    offset_hours = offset_minutes = offset_sign = 0
    if has_time
        has_date && (j += 1)   # separator
        hour = read2(j)
        minute = read2(j + 3)
        second = read2(j + 6)
        j += 8
        if j <= b && buf[j] == UInt8('.')
            j += 1
            scale = 100
            while j <= b && _is_digit(buf[j])
                if scale > 0
                    ms += scale * d(j)
                    scale ÷= 10
                end
                j += 1
            end
        end
        if j <= b
            has_offset = true
            c = buf[j]
            if c == UInt8('+') || c == UInt8('-')
                offset_sign = c == UInt8('-') ? -1 : 1
                offset_hours = read2(j + 1)
                offset_minutes = read2(j + 4)
            end
        end
    end
    return (; has_date, year, month, day, has_time, hour, minute, second, ms,
            has_offset, offset_sign, offset_hours, offset_minutes)
end

function _datetime_value(buf::Vector{UInt8}, a::Int, b::Int, k::Kind)
    p = _datetime_parts(buf, a, b, k)
    sec = min(p.second, 59)   # a leap second cannot be represented
    if k == K"TomlLocalDate"
        return Dates.Date(p.year, p.month, p.day)
    elseif k == K"TomlLocalTime"
        return Dates.Time(p.hour, p.minute, sec, p.ms)
    end
    dt = Dates.DateTime(p.year, p.month, p.day, p.hour, p.minute, sec, p.ms)
    k == K"TomlLocalDateTime" && return dt
    return OffsetDateTime(dt, p.offset_sign * (60 * p.offset_hours + p.offset_minutes))
end

function _skip_first_newline(buf, a, b)
    a > b && return a
    buf[a] == UInt8('\n') && return a + 1
    (buf[a] == UInt8('\r') && a < b && buf[a+1] == UInt8('\n')) && return a + 2
    return a
end

function _hex_value(buf, j, n)
    v = 0
    for i in j:j+n-1
        c = buf[i]
        v = 16v + (_is_digit(c) ? Int(c - UInt8('0')) :
                   c >= UInt8('a') ? Int(c - UInt8('a')) + 10 : Int(c - UInt8('A')) + 10)
    end
    return v
end

@inline _is_toml_ws(c::UInt8) = c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n') || c == UInt8('\r')

# Basic string content between a and b (inclusive), escapes resolved.
function _unescape(buf::Vector{UInt8}, a::Int, b::Int, multiline::Bool)
    any(j -> buf[j] == UInt8('\\'), a:b) || return _substr(buf, a, b)
    io = IOBuffer()
    j = a
    while j <= b
        c = buf[j]
        if c == UInt8('\\') && j < b
            e = buf[j+1]
            if e == UInt8('b')
                write(io, '\b'); j += 2
            elseif e == UInt8('t')
                write(io, '\t'); j += 2
            elseif e == UInt8('n')
                write(io, '\n'); j += 2
            elseif e == UInt8('f')
                write(io, '\f'); j += 2
            elseif e == UInt8('r')
                write(io, '\r'); j += 2
            elseif e == UInt8('"')
                write(io, '"'); j += 2
            elseif e == UInt8('\\')
                write(io, '\\'); j += 2
            elseif e == UInt8('u')
                write(io, Char(_hex_value(buf, j + 2, 4))); j += 6
            elseif e == UInt8('U')
                write(io, Char(_hex_value(buf, j + 2, 8))); j += 10
            elseif multiline && _is_toml_ws(e)
                # Line-ending backslash: trim through the next non-whitespace.
                j += 1
                while j <= b && _is_toml_ws(buf[j])
                    j += 1
                end
            else
                write(io, c); j += 1
            end
        else
            write(io, c)
            j += 1
        end
    end
    return String(take!(io))
end

function _digits_string(buf, a, b)
    io = IOBuffer()
    for j in a:b
        buf[j] == UInt8('_') || write(io, buf[j])
    end
    return String(take!(io))
end

# Smallest of Int64/Int128/BigInt (decimal) or UInt64/UInt128/BigInt (prefixed).
function _integer_value(buf::Vector{UInt8}, a::Int, b::Int)
    neg = buf[a] == UInt8('-')
    s = (neg || buf[a] == UInt8('+')) ? a + 1 : a
    if s + 1 <= b && buf[s] == UInt8('0') && (buf[s+1] == UInt8('x') || buf[s+1] == UInt8('o') || buf[s+1] == UInt8('b'))
        base = buf[s+1] == UInt8('x') ? 16 : buf[s+1] == UInt8('o') ? 8 : 2
        str = _digits_string(buf, s + 2, b)
        v = Base.tryparse(UInt64, str; base)
        v === nothing || return v
        big = Base.parse(BigInt, str; base)
        return big <= typemax(UInt128) ? UInt128(big) : big
    end
    str = _digits_string(buf, neg ? a : s, b)   # keep the sign: typemin fits
    v = Base.tryparse(Int64, str)
    v === nothing || return v
    big = Base.parse(BigInt, str)
    return typemin(Int128) <= big <= typemax(Int128) ? Int128(big) : big
end

function _float_value(buf::Vector{UInt8}, a::Int, b::Int)
    neg = buf[a] == UInt8('-')
    s = (neg || buf[a] == UInt8('+')) ? a + 1 : a
    if _starts_with(buf, s, b, "inf")
        return neg ? -Inf : Inf
    elseif _starts_with(buf, s, b, "nan")
        return NaN
    end
    return Base.parse(Float64, _digits_string(buf, a, b))
end

"""
    parse_toml_literal(buf, head, range) -> Any

The value of the token with `head` covering `range` (1-based, inclusive) in
`buf`: `String` for keys and strings, `Int64`/`Int128`/`BigInt` or
`UInt64`/`UInt128`/`BigInt` for integers, `Float64`, `Bool`, `Dates.Date`,
`Dates.Time`, `Dates.DateTime` or [`OffsetDateTime`](@ref). Error tokens give
`ErrorVal()`; punctuation gives `nothing`.
"""
function parse_toml_literal(buf::Vector{UInt8}, head::SyntaxHead, range::UnitRange{Int})
    k = kind(head)
    a = first(range)
    b = last(range)
    if k == K"TomlBareKey"
        return _substr(buf, a, b)
    elseif k == K"TomlBasicString"
        return _unescape(buf, a + 1, b - 1, false)
    elseif k == K"TomlMultilineBasicString"
        return _unescape(buf, _skip_first_newline(buf, a + 3, b - 3), b - 3, true)
    elseif k == K"TomlLiteralString"
        return _substr(buf, a + 1, b - 1)
    elseif k == K"TomlMultilineLiteralString"
        return _substr(buf, _skip_first_newline(buf, a + 3, b - 3), b - 3)
    elseif k == K"TomlInteger"
        return _integer_value(buf, a, b)
    elseif k == K"TomlFloat"
        return _float_value(buf, a, b)
    elseif k == K"TomlBool"
        return buf[a] == UInt8('t')
    elseif is_toml_datetime(k)
        return _datetime_value(buf, a, b, k)
    elseif k == K"error"
        return ErrorVal()
    end
    return nothing
end
