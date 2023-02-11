@static if VERSION < v"1.6"
    let
        @inline function __convert_digit(_c::UInt32, base)
            _0 = UInt32('0')
            _9 = UInt32('9')
            _A = UInt32('A')
            _a = UInt32('a')
            _Z = UInt32('Z')
            _z = UInt32('z')
            a::UInt32 = base <= 36 ? 10 : 36
            d = _0 <= _c <= _9 ? _c-_0             :
                _A <= _c <= _Z ? _c-_A+ UInt32(10) :
                _a <= _c <= _z ? _c-_a+a           : UInt32(base)
        end

        @inline function uuid_kernel(s, i, u)
            _c = UInt32(@inbounds codeunit(s, i))
            d = __convert_digit(_c, UInt32(16))
            d >= 16 && return nothing
            u <<= 4
            return u | d
        end

        function Base.tryparse(::Type{UUID}, s::AbstractString)
            u = UInt128(0)
            ncodeunits(s) != 36 && return nothing
            for i in 1:8
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 9) == UInt8('-') || return nothing
            for i in 10:13
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 14) == UInt8('-') || return nothing
            for i in 15:18
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 19) == UInt8('-') || return nothing
            for i in 20:23
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            @inbounds codeunit(s, 24) == UInt8('-') || return nothing
            for i in 25:36
                u = uuid_kernel(s, i, u)
                u === nothing && return nothing
            end
            return Base.UUID(u)
        end
    end
end

if VERSION < v"1.1" || Sys.iswindows() && VERSION < v"1.3"
    _splitdir_nodrive(path::String) = _splitdir_nodrive("", path)
    function _splitdir_nodrive(a::String, b::String)
        m = match(Base.Filesystem.path_dir_splitter, b)
        m === nothing && return (a, b)
        a = string(a, isempty(m.captures[1]) ? m.captures[2][1] : m.captures[1])
        a, String(m.captures[3])
    end
    splitpath(p::AbstractString) = splitpath(String(p))

    function splitpath(p::String)
        drive, p = _splitdrive(p)
        out = String[]
        isempty(p) && (pushfirst!(out, p))  # "" means the current directory.
        while !isempty(p)
            dir, base = _splitdir_nodrive(p)
            dir == p && (pushfirst!(out, dir); break)  # Reached root node.
            if !isempty(base)  # Skip trailing '/' in basename
                pushfirst!(out, base)
            end
            p = dir
        end
        if !isempty(drive)  # Tack the drive back on to the first element.
            out[1] = drive * out[1]  # Note that length(out) is always >= 1.
        end
        return out
    end
    _path_separator    = "\\"
    _path_separator_re = r"[/\\]+"
    function _pathsep(paths::AbstractString...)
        for path in paths
            m = match(_path_separator_re, String(path))
            m !== nothing && return m.match[1:1]
        end
        return _path_separator
    end
    function joinpath(a::String, b::String)
        isabspath(b) && return b
        A, a = _splitdrive(a)
        B, b = _splitdrive(b)
        !isempty(B) && A != B && return string(B,b)
        C = isempty(B) ? A : B
        isempty(a)                              ? string(C,b) :
        occursin(_path_separator_re, a[end:end]) ? string(C,a,b) :
                                                  string(C,a,_pathsep(a,b),b)
    end
    joinpath(a::AbstractString, b::AbstractString) = joinpath(String(a), String(b))
    joinpath(a, b, c, paths...) = joinpath(joinpath(a, b), c, paths...)
end

@static if Sys.iswindows() && VERSION < v"1.3"
    function _splitdir_nodrive(a::String, b::String)
        m = match(r"^(.*?)([/\\]+)([^/\\]*)$", b)
        m === nothing && return (a, b)
        a = string(a, isempty(m.captures[1]) ? m.captures[2][1] : m.captures[1])
        a, String(m.captures[3])
    end
    function _dirname(path::String)
        m = match(r"^([^\\]+:|\\\\[^\\]+\\[^\\]+|\\\\\?\\UNC\\[^\\]+\\[^\\]+|\\\\\?\\[^\\]+:|)(.*)$"s, path)
        m === nothing && return ""
        a, b = String(m.captures[1]), String(m.captures[2])
        _splitdir_nodrive(a, b)[1]
    end
    function _splitdrive(path::String)
        m = match(r"^([^\\]+:|\\\\[^\\]+\\[^\\]+|\\\\\?\\UNC\\[^\\]+\\[^\\]+|\\\\\?\\[^\\]+:|)(.*)$"s, path)
        m === nothing && return "", path
        String(m.captures[1]), String(m.captures[2])
    end
    function _splitdir(path::String)
        a, b = _splitdrive(path)
        _splitdir_nodrive(a, b)
    end
else
    _dirname = dirname
    _splitdir = splitdir
    _splitdrive = splitdrive
end
