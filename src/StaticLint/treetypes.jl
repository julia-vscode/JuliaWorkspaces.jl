"""
    TreeDataType

A workspace-declared datatype as a comparison operand: its index key, its
declared supertype record, and the resolver that can continue the walk.
Nominal identity is the key; a tree type never equals a store type.
"""
struct TreeDataType
    key::Tuple{Vector{String},String}
    sup::Union{Nothing,TypeExpr}
    resolve::Function
end

_type_compare(a::TreeDataType, b::TreeDataType) = a.key == b.key
_type_compare(a::TreeDataType, b::_NominalType) = false
_type_compare(a::_NominalType, b::TreeDataType) = false

function _super(a::TreeDataType, store, meta_dict)
    a.sup === nothing && return nothing
    a.sup == TYPE_ANY && return CoreTypes.Any
    a.sup isa TypeRef || return nothing
    return a.resolve(a.sup, a.key[1])
end

# `TypeVarRef` hops through the signature's own typevar table; `fuel` bounds
# pathological self-referential bounds.
function resolve_record_type(t::TypeExpr, sig::MethodSignature, defined_in, resolver, fuel=4)
    fuel <= 0 && return CoreTypes.Any
    if t isa TypeVarRef
        ub = get(sig.typevars, t.name, UnknownType())
        return resolve_record_type(ub, sig, defined_in, resolver, fuel - 1)
    elseif t isa TypeUnionExpr
        isempty(t.members) && return CoreTypes.Any
        members = [resolve_record_type(m, sig, defined_in, resolver, fuel - 1) for m in t.members]
        # `FakeUnion` member comparison only understands store operands; a
        # tree member inside one would rule out falsely. Until unions get
        # their own parity row, a mixed union carries no opinion.
        all(m -> m isa SymbolServer.DataTypeStore || m isa SymbolServer.FakeTypeName, members) ||
            return CoreTypes.Any
        return _fake_union(members)
    elseif t isa TypeRef
        r = resolver(t, defined_in)
        return r === nothing ? CoreTypes.Any : r
    end
    return CoreTypes.Any   # UnknownType and anything future: no opinion
end

function lower_descriptor(ls::LocatedSignature, resolver)
    sig = ls.sig
    res(t) = resolve_record_type(t, sig, ls.defined_in, resolver)
    fixed = Any[res(sl.type) for sl in sig.slots if !sl.optional]
    opts = Any[res(sl.type) for sl in sig.slots if sl.optional]
    has_vararg = sig.vararg !== nothing
    pad = has_vararg ? res(sig.vararg.eltype) : CoreTypes.Any
    N = has_vararg ? sig.vararg.count : nothing
    if has_vararg
        push!(fixed, pad)   # engine convention: vararg slot rides last in `fixed`
    end
    return SigDescriptor(fixed, opts, has_vararg, pad, N, Vector{Any}(sig.kws))
end

match_method(args::Vector{Any}, kws::Vector{Any}, ls::LocatedSignature, resolver, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(ls, resolver), store, meta_dict)
