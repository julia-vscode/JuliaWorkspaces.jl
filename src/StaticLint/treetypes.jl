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

# A `TreeDataType` reached mid-walk (via a resolved `TreeRef`) against a
# same-file datatype `Binding`: the two domains have no shared identity to
# compare, so without this the walk sails past a real match to `Any` and
# rules it out. Compare by NAME only — deliberately permissive, since a
# same-name type in an unrelated module would wrongly compare equal too. That
# false `true` only ever keeps a candidate alive (the safe direction); it can
# never manufacture a `false` this walk wouldn't otherwise reach honestly.
function _type_compare(a::TreeDataType, b::Binding)
    isidentifier(b.name) || return false
    n = valofid(b.name)
    n !== nothing && a.key[2] == n
end
_type_compare(a::Binding, b::TreeDataType) = _type_compare(b, a)

"""
    ResolvedUnion

A `Union{…}` annotation with every member already resolved to a comparison
operand (store value or `TreeDataType`). Member-wise tri-state: intersecting
any member is `true`; ruled out only when EVERY member is definitely ruled out.
"""
struct ResolvedUnion
    members::Vector{Any}
end

# Member-wise tri-state: an indeterminate member blocks a `false`, never a
# `true` from another member. `ResolvedUnion` needs no `_super`/`_type_compare`
# — these methods are more specific than the generic `_has_type_intersection`,
# so a union never reaches the nominal walk.
function _has_type_intersection(a, b::ResolvedUnion, store, meta_dict, resolver=nothing)
    saw_unknown = false
    for m in b.members
        r = _has_type_intersection(a, m, store, meta_dict, resolver)
        r === true && return true
        r === nothing && (saw_unknown = true)
    end
    return saw_unknown ? nothing : false
end
_has_type_intersection(a::ResolvedUnion, b, store, meta_dict, resolver=nothing) =
    _has_type_intersection(b, a, store, meta_dict, resolver)
# Both operands unions: explicit method avoids the dispatch ambiguity between
# the two legs above.
function _has_type_intersection(a::ResolvedUnion, b::ResolvedUnion, store, meta_dict, resolver=nothing)
    saw_unknown = false
    for m in a.members
        r = _has_type_intersection(m, b, store, meta_dict, resolver)
        r === true && return true
        r === nothing && (saw_unknown = true)
    end
    return saw_unknown ? nothing : false
end

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
        any(m -> m === CoreTypes.Any || m === nothing, members) && return CoreTypes.Any
        all(m -> m isa SymbolServer.DataTypeStore || m isa SymbolServer.FakeTypeName, members) &&
            return _fake_union(members)      # store-only unions keep the store shape
        return ResolvedUnion(members)
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
    return SigDescriptor(fixed, opts, has_vararg, pad, N, Vector{Any}(sig.kws), sig.kwsplat)
end

match_method(args::Vector{Any}, kws::Vector{Any}, ls::LocatedSignature, resolver, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(ls, resolver), store, meta_dict, resolver)

# `x::Sub.Own` → ["Sub", "Own"], `x::Vector{T} where T` → ["Vector"]; `nothing`
# for anything that isn't a (possibly qualified) name.
function _type_name_segments(t)
    t isa EXPR || return nothing
    while iswhere(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    if iscurly(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    segs = String[]
    while is_getfield_w_quotenode(t)
        n = valofid(t.args[2].args[1])
        n === nothing && return nothing
        pushfirst!(segs, n)
        t = t.args[1]
    end
    isidentifier(t) || return nothing
    n = valofid(t)
    n === nothing && return nothing
    pushfirst!(segs, n)
    return segs
end

# Inventory item kinds that declare a datatype — the `TreeRef` kinds a type
# name, or a constructor callee, can carry. One list, so a callee and an
# annotation can never disagree about what a datatype is.
const _TREE_DATATYPE_KINDS = (:struct, :mutable_struct, :abstract, :primitive, :enum)

# A `TreeRef` as a comparison operand: its datatype, resolved in the module
# that binds it. `nothing` for non-datatype kinds and failed resolution. The
# one conversion helper, so a `TreeRef` can never be resolved two ways.
_treeref_operand(r::TreeRef, resolver) =
    r.kind in _TREE_DATATYPE_KINDS ? resolver(TypeRef([r.name]), r.origin_module) : nothing

# Does the annotation `t` name a datatype DECLARED IN THE WORKSPACE (this file
# or, through the tree, a sibling)? A `where` typevar, a type alias, a store
# type and an unresolved name all say no: for those the pass's own operand is
# at least as good, and re-resolving the name would answer for a different
# entity than the one the argument was declared with.
function _names_workspace_datatype(t, meta_dict)
    t isa EXPR || return false
    while iswhere(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    if iscurly(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    r = is_getfield_w_quotenode(t) ? refof_maybe_getfield(t, meta_dict) :
        (isidentifier(t) ? refof(t, meta_dict) : nothing)
    r isa TreeRef && return r.kind in _TREE_DATATYPE_KINDS
    r isa Binding || return false
    return r.val isa EXPR && CSTParser.defines_datatype(r.val)
end

"""
    tree_arg_operands(x, args, meta_dict, callsite_type) -> Vector{Any}

`args` (as typed by `call_arg_types`) with every argument that denotes a
WORKSPACE datatype replaced by that datatype as the record side sees it — the
`TreeDataType` `callsite_type` resolves its name to at the call site.

Both sides of a comparison must come from the same domain. The pass types such
an argument as the declared type's local `Binding` (same file, possibly through
an alias) or drops it to `Any` (sibling file, since `Binding.type` cannot carry
a `TreeRef`); against a `TreeDataType` parameter the first compares unequal and
then walks to `Any` — a definite `false` between a type and itself — and the
second carries no opinion at all. Anything that does not translate keeps the
operand it had.
"""
function tree_arg_operands(x::EXPR, args::Vector{Any}, meta_dict, callsite_type)
    exprs = positional_args(x)
    length(exprs) == length(args) || return args
    out = args
    for i in eachindex(args)
        segs = _workspace_datatype_segments(args[i], exprs[i], meta_dict)
        segs === nothing && continue
        dt = callsite_type(TypeRef(segs), x)
        dt isa TreeDataType || continue
        out === args && (out = copy(args))
        out[i] = dt
    end
    return out
end

# Is `arg` a reference to one of the enclosing signature's `where` variables? A
# type parameter can bind a VALUE (`GenericDomTree{IsPostDom}` with
# `IsPostDom::Bool`) as easily as a type, and which it is cannot be read here.
# `arg_type` answers `Any` for these, so every consumer — decision and message
# alike — sees the same unknown.
function _is_where_typevar_ref(arg, meta_dict)
    (arg isa EXPR && isidentifier(arg)) || return false
    b = refof(arg, meta_dict)
    b isa Binding || return false
    return b.val isa EXPR && iswhere(parentof(b.val))
end

# The name of the workspace datatype an argument denotes, as qualifier segments,
# or `nothing`. Two routes, in this order: the type the pass inferred, when that
# is a datatype `Binding` (a same-file declaration, reached directly or through
# an alias); and the declaration's own annotation, which covers the sibling-file
# case the pass drops to `Any`.
function _workspace_datatype_segments(val, arg, meta_dict)
    if val isa Binding && val.val isa EXPR && CSTParser.defines_datatype(val.val) &&
            !_is_function_local_binding(val, meta_dict)
        n = val.name isa EXPR ? valofid(val.name) : nothing
        n === nothing || return [n]
    end
    (arg isa EXPR && isidentifier(arg)) || return nothing
    b = refof(arg, meta_dict)
    b isa Binding || return nothing
    t = decl_annotation(b)
    (t !== nothing && _names_workspace_datatype(t, meta_dict)) || return nothing
    return _type_name_segments(t)
end
