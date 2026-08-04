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
    return SigDescriptor(fixed, opts, has_vararg, pad, N, Vector{Any}(sig.kws), sig.kwsplat)
end

match_method(args::Vector{Any}, kws::Vector{Any}, ls::LocatedSignature, resolver, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(ls, resolver), store, meta_dict)

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
operand it had — except a `where` typevar passed as an argument, which is
widened to `Any` (see `_is_where_typevar_ref`).
"""
function tree_arg_operands(x::EXPR, args::Vector{Any}, meta_dict, callsite_type)
    exprs = positional_args(x)
    length(exprs) == length(args) || return args
    out = args
    for i in eachindex(args)
        if _is_where_typevar_ref(exprs[i], meta_dict)
            out === args && (out = copy(args))
            out[i] = CoreTypes.Any
            continue
        end
        segs = _workspace_datatype_segments(args[i], exprs[i], meta_dict)
        segs === nothing && continue
        dt = callsite_type(TypeRef(segs), x)
        dt isa TreeDataType || continue
        out === args && (out = copy(args))
        out[i] = dt
    end
    return out
end

# Is `arg` a reference to one of the enclosing signature's `where` variables? The
# pass types every such reference `DataType`, but a type parameter can bind a
# VALUE (`GenericDomTree{IsPostDom}` with `IsPostDom::Bool`), and which it is
# cannot be read here — so it carries no opinion rather than a wrong one.
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
