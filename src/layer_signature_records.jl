# Plain-data method-signature records, per-file firewall rules of
# layer_inventory.jl: no EXPR, no positions, no store values. A record's
# type names are UNRESOLVED, relative to the module that wrote them;
# resolution happens at check time, at the leaf.

"A type annotation as written. Closed vocabulary; anything unclassifiable is
`UnknownType`, which never rules anything out."
abstract type TypeExpr end

"A (possibly qualified) type name, one segment per qualifier:
`Base.AbstractString` → `[\"Base\", \"AbstractString\"]`. A parametric
annotation lowers to its head."
@auto_hash_equals struct TypeRef <: TypeExpr
    path::Vector{String}
end

"`Union{…}`, member-wise."
@auto_hash_equals struct TypeUnionExpr <: TypeExpr
    members::Vector{TypeExpr}
end

"A reference to a `where`-bound variable of the same signature. Resolves only
through the signature's own `typevars`, never through module scope."
@auto_hash_equals struct TypeVarRef <: TypeExpr
    name::String
end

@auto_hash_equals struct UnknownType <: TypeExpr end

"`Any` is recorded explicitly where its meaning is syntactically certain
(no annotation; a datatype with no `<:` clause) — unlike `UnknownType`,
it is definite and can end a supertype walk with a verdict."
const TYPE_ANY = TypeRef(["Core", "Any"])

"One positional parameter: its annotation and whether it is defaulted.
Optionality is alignment information only."
@auto_hash_equals struct SigSlot
    type::TypeExpr
    optional::Bool
end

"The trailing vararg slot, all spellings (`x...`, `::Vararg`, `::Vararg{T}`,
`::Vararg{T,N}`, `::Base.Vararg`). `count` is `N` for the bounded form."
@auto_hash_equals struct VarargSpec
    eltype::TypeExpr
    count::Union{Nothing,Int}
end

"""
    MethodSignature

One method's signature as written: positional `slots` in order (excluding the
vararg slot), the `vararg` if any, `where`-clause upper bounds in `typevars`
(a variable with no readable upper bound maps to `UnknownType`), and keyword
presence. Arity is derivable but the count verdict stays on `MethodArity`.
"""
@auto_hash_equals struct MethodSignature
    slots::Vector{SigSlot}
    vararg::Union{Nothing,VarargSpec}
    typevars::Dict{String,TypeExpr}
    kws::Vector{Symbol}
    kwsplat::Bool
end

"A signature plus the module path that wrote it — attached at index time
(inventories only know file-relative paths). `defined_in` is where the
signature's names resolve; for qualified extensions it differs from the
index key."
@auto_hash_equals struct LocatedSignature
    defined_in::Vector{String}
    sig::MethodSignature
end

"""
    NameMethods

Everything the signature index knows about one `(module path, name)`:
the signature `Set` (order-insensitive equality, so moving a method between
files backdates), plus two completeness markers. While `has_unknown_shapes`
is true the set is an under-approximation: its emptiness proves nothing and
exhausting it licenses nothing.
"""
@auto_hash_equals struct NameMethods
    signatures::Set{LocatedSignature}
    has_unknown_shapes::Bool
    has_forward_decl::Bool
end

const EMPTY_NAME_METHODS = NameMethods(Set{LocatedSignature}(), false, false)
