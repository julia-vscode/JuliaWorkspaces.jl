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

_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.DataTypeStore) = a.name == b.name
_type_compare(a::SymbolServer.FakeTypeName, b::SymbolServer.FakeTypeName) = a == b
_type_compare(a::SymbolServer.FakeTypeName, b::SymbolServer.DataTypeStore) = a == b.name
_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeTypeName) = a.name == b
_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeUnion) = _type_compare(a, b.a) || _type_compare(a, b.b)

_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeTypeVar) = _type_compare(a, b.ub)
_type_compare(a::SymbolServer.DataTypeStore, b::SymbolServer.FakeUnionAll) = _type_compare(a, b.body)
_type_compare(a::SymbolServer.FakeUnionAll, b::SymbolServer.DataTypeStore) = _type_compare(a.body, b)
_type_compare(a::SymbolServer.FakeTypeName, b::SymbolServer.FakeUnionAll) = _type_compare(a, b.body)
_type_compare(a::SymbolServer.FakeUnionAll, b::SymbolServer.FakeTypeName) = _type_compare(a.body, b)

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
    elseif x.head === :abstract || x.head === :primtive
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
