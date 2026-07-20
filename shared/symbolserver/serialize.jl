module CacheStore
using ..SymbolServer: VarRef, FakeTypeName, FakeTypeofBottom, FakeTypeVar, FakeUnion, FakeUnionAll, Unserializable
using ..SymbolServer: ModuleStore, Package, FunctionStore, MethodStore, DataTypeStore, GenericStore
using ..SymbolServer: CACHE_FORMAT_VERSION
@static if !(Vararg isa Type)
    using ..SymbolServer: FakeTypeofVararg
end

const NothingHeader = 0x01
const SymbolHeader = 0x02
const CharHeader = 0x03
const IntegerHeader = 0x04
const StringHeader = 0x05
const VarRefHeader = 0x06
const FakeTypeNameHeader = 0x07
const FakeTypeofBottomHeader = 0x08
const FakeTypeVarHeader = 0x09
const FakeUnionHeader = 0x0a
const FakeUnionAllHeader = 0xb
const ModuleStoreHeader = 0x0c
const MethodStoreHeader = 0x0d
const FunctionStoreHeader = 0x0e
const DataTypeStoreHeader = 0x0f
const GenericStoreHeader = 0x10
const PackageHeader = 0x11
const TrueHeader = 0x12
const FalseHeader = 0x13
const TupleHeader = 0x14
const FakeTypeofVarargHeader = 0x15
const UndefHeader = 0x16
const UnserializableHeader = 0x17

# reserve 0x00-0xfe for type headers and indicate that this file is binary by not starting
# with ASCII
const MagicHeader = b"\xffjstore"
# Derived from CACHE_FORMAT_VERSION (utils.jl, included first) as a 2-byte tag.
const StoreVersion = UInt8[CACHE_FORMAT_VERSION >> 8, CACHE_FORMAT_VERSION & 0xff]

struct CacheCorruptedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CacheCorruptedError) = print(io, "CacheCorruptedError: ", e.msg)

# bytesavailable(::IOStream) is the buffered chunk size, not remaining file bytes.
_remaining(io::IOStream) = Int(filesize(io)) - Int(position(io))
_remaining(io::IO) = bytesavailable(io)

function _check_len(io, n)
    n < 0 && throw(CacheCorruptedError("negative length: $n"))
    rem = _remaining(io)
    n > rem && throw(CacheCorruptedError("length $n exceeds remaining $rem bytes"))
    return n
end

const MAX_DEPTH = 256
const MAX_TUPLE_LEN = 10_000
# cutoff for degrading over-deep subtrees in Any-typed slots; the margin leaves
# room for typed substructure below the last Any slot (VarRef chains etc.) so
# written files always stay within the reader's MAX_DEPTH
const MAX_ANY_DEPTH = MAX_DEPTH - 64

function write(io, x)
    _write_header(io)
    _write(io, x, 0)
end

function _write_header(io)
    Base.write(io, MagicHeader)
    Base.write(io, StoreVersion)
end

# for values in Any-typed slots, which can absorb the sentinel: cut cycles and
# over-deep nesting here instead of erroring out of the whole write
function _write_any(io, x, depth::Int)
    if depth > MAX_ANY_DEPTH
        Base.write(io, UnserializableHeader)
        return
    end
    _write(io, x, depth)
end

function _write(io, x::VarRef, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, VarRefHeader)
    _write(io, x.parent, depth)
    _write(io, x.name, depth)
end
function _write(io, x::Nothing, depth::Int)
    Base.write(io, NothingHeader)
end
function _write(io, x::Unserializable, depth::Int)
    Base.write(io, UnserializableHeader)
end
function _write(io, x::Char, depth::Int)
    Base.write(io, CharHeader)
    Base.write(io, UInt32(x))
end
function _write(io, x::Bool, depth::Int)
    x ? Base.write(io, TrueHeader) : Base.write(io, FalseHeader)
end
function _write(io, x::Int, depth::Int)
    Base.write(io, IntegerHeader)
    Base.write(io, x)
end
function _write(io, x::Symbol, depth::Int)
    Base.write(io, SymbolHeader)
    Base.write(io, sizeof(x))
    Base.write(io, String(x))
end
function _write(io, x::NTuple{N,Any}, depth::Int) where N
    if N > MAX_TUPLE_LEN
        Base.write(io, UnserializableHeader)
        return
    end
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, TupleHeader)
    Base.write(io, N)
    for i = 1:N
        _write_any(io, x[i], depth)
    end
end
function _write(io, x::String, depth::Int)
    Base.write(io, StringHeader)
    Base.write(io, sizeof(x))
    Base.write(io, x)
end
function _write(io, x::FakeTypeName, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, FakeTypeNameHeader)
    _write(io, x.name, depth)
    _write_vector(io, x.parameters, depth)
end
_write(io, x::FakeTypeofBottom, depth::Int) = Base.write(io, FakeTypeofBottomHeader)
function _write(io, x::FakeTypeVar, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, FakeTypeVarHeader)
    _write(io, x.name, depth)
    _write_any(io, x.lb, depth)
    _write_any(io, x.ub, depth)
end
function _write(io, x::FakeUnion, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, FakeUnionHeader)
    _write_any(io, x.a, depth)
    _write_any(io, x.b, depth)
end
function _write(io, x::FakeUnionAll, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, FakeUnionAllHeader)
    _write(io, x.var, depth)
    _write_any(io, x.body, depth)
end

@static if !(Vararg isa Type)
    function _write(io, x::FakeTypeofVararg, depth::Int)
        depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
        depth += 1
        Base.write(io, FakeTypeofVarargHeader)
        isdefined(x, :T) ? _write_any(io, x.T, depth) : Base.write(io, UndefHeader)
        isdefined(x, :N) ? _write_any(io, x.N, depth) : Base.write(io, UndefHeader)
    end
end

function _write(io, x::MethodStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, MethodStoreHeader)
    _write(io, x.name, depth)
    _write(io, x.mod, depth)
    _write(io, x.file, depth)
    Base.write(io, x.line)
    Base.write(io, length(x.sig))
    for p in x.sig
        _write_any(io, p[1], depth)
        _write_any(io, p[2], depth)
    end
    _write_vector(io, x.kws, depth)
    _write_any(io, x.rt, depth)
end

function _write(io, x::FunctionStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, FunctionStoreHeader)
    _write(io, x.name, depth)
    _write_vector(io, x.methods, depth)
    _write(io, x.doc, depth)
    _write(io, x.extends, depth)
end

function _write(io, x::DataTypeStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, DataTypeStoreHeader)
    _write(io, x.name, depth)
    _write(io, x.super, depth)
    _write_vector(io, x.parameters, depth)
    _write_vector(io, x.types, depth)
    _write_vector(io, x.fieldnames, depth)
    _write_vector(io, x.methods, depth)
    _write(io, x.doc, depth)
end

function _write(io, x::GenericStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, GenericStoreHeader)
    _write(io, x.name, depth)
    _write_any(io, x.typ, depth)
    _write(io, x.doc, depth)
end

function _write(io, x::ModuleStore, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, ModuleStoreHeader)
    _write(io, x.name, depth)
    Base.write(io, length(x.vals))
    buf = IOBuffer()
    for p in x.vals
        _write(io, p[1], depth)
        # serialize the value out-of-band so one pathological binding (cycle,
        # unserializable type) degrades to a sentinel — which the reader drops —
        # instead of failing the whole cache file
        try
            _write_any(buf, p[2], depth)
            Base.write(io, take!(buf))
        catch err
            take!(buf)
            (err isa InterruptException || err isa OutOfMemoryError || err isa StackOverflowError) && rethrow()
            @debug "skipping unserializable module binding" key = p[1] exception = err
            Base.write(io, UnserializableHeader)
        end
    end
    _write(io, x.doc, depth)
    _write_vector(io, x.exportednames, depth)
    _write_vector(io, x.publicnames, depth)
    _write_vector(io, x.used_modules, depth)
end

function _write(io, x::Package, depth::Int)
    depth > MAX_DEPTH && throw(ArgumentError("serialization depth limit exceeded — possible cycle in $(typeof(x))"))
    depth += 1
    Base.write(io, PackageHeader)
    _write(io, x.name, depth)
    _write(io, x.val, depth)
    Base.write(io, UInt128(x.uuid))
    Base.write(io, x.sha === nothing ? zeros(UInt8, 32) : x.sha)
end

function _write_vector(io, x, depth::Int)
    Base.write(io, length(x))
    depth += 1
    # only Any-typed elements may degrade to the sentinel; in typed vectors it
    # would come back as `nothing` and fail the read
    elwrite = eltype(x) === Any ? _write_any : _write
    for p in x
        elwrite(io, p, depth)
    end
end

# Reading into an IOBuffer increases performance by ~3x, because the
# many single-byte read calls don't require a ccall then
read(io::IOStream) = read(IOBuffer(Base.read(io)))

function read(io)
    try
        _read_header(io)
        return _read(io)
    catch err
        if err isa CacheCorruptedError || err isa InterruptException || err isa OutOfMemoryError || err isa StackOverflowError
            rethrow()
        elseif err isa EOFError
            throw(CacheCorruptedError("unexpected end of stream"))
        else
            # crafted tags can type-confuse strictly typed struct fields
            # (MethodError/TypeError), produce invalid code points, etc. —
            # all of it means the file is bad, not that the process is
            throw(CacheCorruptedError("malformed cache data: $(typeof(err))"))
        end
    end
end

function _read_header(io)
    header = Base.read(io, length(MagicHeader))
    if header != MagicHeader
        throw(CacheCorruptedError("invalid cache file (magic bytes mismatch)"))
    end
    version = Base.read(io, length(StoreVersion))
    if version != StoreVersion
        throw(CacheCorruptedError("invalid cache file version (read $(bytes2hex(version)), expected $(bytes2hex(StoreVersion)))"))
    end
end

function _read(io, t = Base.read(io, UInt8), depth::Int = 0)
    # There are a bunch of `yield`s in potentially expensive code paths.
    # One top-level `yield` would probably increase responsiveness in the
    # LS, but increases runtime by 3x. This seems like a good compromise.
    depth > MAX_DEPTH && throw(CacheCorruptedError("depth limit exceeded ($MAX_DEPTH)"))
    depth += 1

    if t === VarRefHeader
        VarRef(_read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth))
    elseif t === NothingHeader
        nothing
    elseif t === SymbolHeader
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        Symbol(String(out))
    elseif t === StringHeader
        yield()
        n = Base.read(io, Int)
        _check_len(io, n)
        out = Vector{UInt8}(undef, n)
        read!(io, out)
        String(out)
    elseif t === CharHeader
        Char(Base.read(io, UInt32))
    elseif t === IntegerHeader
        Base.read(io, Int)
    elseif t === FakeTypeNameHeader
        FakeTypeName(_read(io, Base.read(io, UInt8), depth), _read_vector(io, Any, depth))
    elseif t === FakeTypeofBottomHeader
        FakeTypeofBottom()
    elseif t === FakeTypeVarHeader
        FakeTypeVar(_read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth))
    elseif t === FakeUnionHeader
        FakeUnion(_read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth))
    elseif t === FakeUnionAllHeader
        FakeUnionAll(_read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth))
    elseif t === FakeTypeofVarargHeader
        T, N = _read(io, Base.read(io, UInt8), depth), _read(io, Base.read(io, UInt8), depth)
        if T === nothing
            FakeTypeofVararg()
        elseif N === nothing
            FakeTypeofVararg(T)
        else
            FakeTypeofVararg(T, N)
        end
    elseif t === UndefHeader
        nothing
    elseif t === UnserializableHeader
        Unserializable()
    elseif t === MethodStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth)
        mod = _read(io, Base.read(io, UInt8), depth)
        file = _read(io, Base.read(io, UInt8), depth)
        line = Base.read(io, UInt32)
        nsig = Base.read(io, Int)
        _check_len(io, nsig)
        sig = Vector{Pair{Any, Any}}(undef, nsig)
        for i in 1:nsig
            sig[i] = _read(io, Base.read(io, UInt8), depth) => _read(io, Base.read(io, UInt8), depth)
        end
        kws = _read_vector(io, Symbol, depth)
        rt = _read(io, Base.read(io, UInt8), depth)
        MethodStore(name, mod, file, line, sig, kws, rt)
    elseif t === FunctionStoreHeader
        yield()
        FunctionStore(
            _read(io, Base.read(io, UInt8), depth),
            _read_vector(io, MethodStore, depth),
            _read(io, Base.read(io, UInt8), depth),
            _read(io, Base.read(io, UInt8), depth),
        )
    elseif t === DataTypeStoreHeader
        yield()
        DataTypeStore(
            _read(io, Base.read(io, UInt8), depth),
            _read(io, Base.read(io, UInt8), depth),
            _read_vector(io, Any, depth),
            _read_vector(io, Any, depth),
            _read_vector(io, Any, depth),
            _read_vector(io, MethodStore, depth),
            _read(io, Base.read(io, UInt8), depth),
        )
    elseif t === GenericStoreHeader
        yield()
        GenericStore(
            _read(io, Base.read(io, UInt8), depth),
            _read(io, Base.read(io, UInt8), depth),
            _read(io, Base.read(io, UInt8), depth),
        )
    elseif t === ModuleStoreHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth)
        n = Base.read(io, Int)
        _check_len(io, n)
        vals = Dict{Symbol,Any}()
        sizehint!(vals, n)
        for _ = 1:n
            k = _read(io, Base.read(io, UInt8), depth)
            vt = Base.read(io, UInt8)
            # drop bindings the writer couldn't serialize
            vt === UnserializableHeader && continue
            vals[k] = _read(io, vt, depth)
        end
        doc = _read(io, Base.read(io, UInt8), depth)
        exportednames = _read_vector(io, Symbol, depth)
        publicnames = _read_vector(io, Symbol, depth)
        used_modules = _read_vector(io, Symbol, depth)
        ModuleStore(name, vals, doc, exportednames, publicnames, used_modules)
    elseif t === TrueHeader
        true
    elseif t === FalseHeader
        false
    elseif t === TupleHeader
        N = Base.read(io, Int)
        _check_len(io, N)
        N > MAX_TUPLE_LEN && throw(CacheCorruptedError("tuple length $N exceeds limit $MAX_TUPLE_LEN"))
        ntuple(i->_read(io, Base.read(io, UInt8), depth), N)
    elseif t === PackageHeader
        yield()
        name = _read(io, Base.read(io, UInt8), depth)
        val = _read(io, Base.read(io, UInt8), depth)
        uuid = Base.UUID(Base.read(io, UInt128))
        # Base.read(io, n) returns short on EOF; read! errors instead
        sha = Vector{UInt8}(undef, 32)
        read!(io, sha)
        Package(name, val, uuid, all(x == 0x00 for x in sha) ? nothing : sha)
    else
        throw(CacheCorruptedError("unknown type tag: 0x$(string(t, base=16, pad=2))"))
    end
end

function _read_vector(io, T, depth::Int = 0)
    n = Base.read(io, Int)
    _check_len(io, n)
    v = Vector{T}(undef, n)
    depth += 1
    for i in 1:n
        v[i] = _read(io, Base.read(io, UInt8), depth)
    end
    v
end

function storeunstore(x)
    io = IOBuffer()
    write(io, x)
    bs = take!(io)
    read(IOBuffer(bs))
end
end
