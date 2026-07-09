function _issubtype(a, b, store, meta_dict)
    _isany(b) && return true
    _type_compare(a, b) && return true
    sup_a = _super(a, store, meta_dict)
    _type_compare(sup_a, b) && return true
    !_isany(sup_a) && return _issubtype(sup_a, b, store, meta_dict)
    return false
end

function _has_type_intersection(a, b, store, meta_dict)
    return _issubtype(a, b, store, meta_dict) || _issubtype(b, a, store, meta_dict)
end

_isany(x::SymbolServer.FakeTypeName) = x.name == VarRef(VarRef(nothing, :Core), :Any)
_isany(x::SymbolServer.DataTypeStore) = x.name.name == VarRef(VarRef(nothing, :Core), :Any)
_isany(x) = false

# Base name of a type, ignoring parameters. Nominal comparison relies on this
# because the store mostly carries free typevars in its parameters, but aliases
# can pin some of them, which would make the supertype walk fail to match.
_basename(x::SymbolServer.FakeTypeName) = x.name
_basename(x::SymbolServer.DataTypeStore) = x.name.name
_basename(_) = nothing

const _NominalType = Union{SymbolServer.DataTypeStore,SymbolServer.FakeTypeName}

_type_compare(a::_NominalType, b::_NominalType) = _basename(a) == _basename(b)
# Two `FakeTypeName`s come from the same reduction, so compare them in full.
_type_compare(a::SymbolServer.FakeTypeName, b::SymbolServer.FakeTypeName) = a == b
_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeUnion) = _type_compare(a, b.a) || _type_compare(a, b.b)
_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeTypeVar) = _type_compare(a, b.ub)

# A `FakeUnionAll`'s parameters are hoisted into UnionAll vars, leaving the
# unwrapped body with empty `.parameters` — compare base names only. `ua_first`
# keeps the fallback recursion in the original argument order, since some
# `_type_compare` methods are one-directional.
_unionall_basename(x::SymbolServer.FakeUnionAll) =
    x.body isa SymbolServer.FakeUnionAll ? _unionall_basename(x.body) : x.body
function _unionall_compare(other, ua::SymbolServer.FakeUnionAll, ua_first::Bool)
    inner = _unionall_basename(ua)
    bn = _basename(inner)
    bn === nothing && return ua_first ? _type_compare(inner, other) : _type_compare(other, inner)
    return _basename(other) == bn
end
_type_compare(a::_NominalType, b::SymbolServer.FakeUnionAll) = _unionall_compare(a, b, false)
_type_compare(a::SymbolServer.FakeUnionAll, b::_NominalType) = _unionall_compare(b, a, true)

_type_compare(a, b) = a == b

_super(a::SymbolServer.DataTypeStore, store, meta_dict) = SymbolServer._lookup(a.super.name, store)
_super(a::SymbolServer.FakeTypeVar, store, meta_dict) = a.ub
_super(a::SymbolServer.FakeUnionAll, store, meta_dict) = a.body
_super(a::SymbolServer.FakeTypeName, store, meta_dict) = _super(SymbolServer._lookup(a.name, store), store, meta_dict)
_super(::SymbolServer.FakeUnion, store, meta_dict) = CoreTypes.Any
_super(::SymbolServer.FakeTypeofBottom, store, meta_dict) = CoreTypes.Any
@static if !(Vararg isa Type)
    _super(a::SymbolServer.FakeTypeofVararg, store, meta_dict) = CoreTypes.Any
end
_super(_, _, _) = CoreTypes.Any

function _super(b::Binding, store, meta_dict)
    StaticLint.CoreTypes.isdatatype(b.type) || return store[:Core][:Any]
    b.val isa Binding && return _super(b.val, store, meta_dict)
    sup = _super(b.val, store, meta_dict)
    if sup isa EXPR && StaticLint.hasref(sup, meta_dict)
        StaticLint.refof(sup, meta_dict)
    else
        store[:Core][:Any]
    end
end

function _super(x::EXPR, store, meta_dict)::Union{EXPR,Nothing}
    if x.head === :struct
        _super(x.args[2], store, meta_dict)
    elseif x.head === :abstract || x.head === :primitive
        _super(x.args[1], store, meta_dict)
    elseif CSTParser.issubtypedecl(x)
        x.args[2]
    elseif CSTParser.isbracketed(x)
        _super(x.args[1], store, meta_dict)
    end
end

function subtypes(T::Binding)
    @assert CSTParser.defines_abstract(T.val)
    subTs = []
    for r in T.refs
        if r isa EXPR && r.parent isa EXPR && CSTParser.issubtypedecl(r.parent) && r.parent.parent isa EXPR && CSTParser.defines_datatype(r.parent.parent)
            push!(subTs, r.parent.parent)
        end
    end
    subTs
end
