"""
    where_var_and_bound(x::EXPR)

One `where`-clause entry → `(name, upper_bound_expr_or_nothing)`, or `nothing`
when the entry isn't a readable type-variable declaration. The only reader of
this grammar: a bare `T`, `T <: B`, the ascending chain `Lo <: T <: Hi`, and
the lower-bound forms (`T >: B`, descending chains), which yield no bound.
"""
function where_var_and_bound(x::EXPR)
    if isidentifier(x)
        n = valofid(x)
        return n === nothing ? nothing : (n, nothing)
    end
    if x.head isa EXPR && isoperator(x.head) && x.args !== nothing && length(x.args) == 2 &&
            isidentifier(x.args[1])
        n = valofid(x.args[1])
        n === nothing && return nothing
        valof(x.head) == "<:" && return (n, x.args[2])
        valof(x.head) == ">:" && return (n, nothing)
        return nothing
    end
    if headof(x) === :comparison && x.args !== nothing && length(x.args) == 5 &&
            headof(x.args[2]) === :OPERATOR && headof(x.args[4]) === :OPERATOR &&
            isidentifier(x.args[3])
        n = valofid(x.args[3])
        n === nothing && return nothing
        if valof(x.args[2]) == "<:" && valof(x.args[4]) == "<:"
            return (n, x.args[5])
        end
        return (n, nothing)
    end
    return nothing
end

# Name path of a (possibly getfield-qualified) type name: `Base.Vararg` →
# ["Base", "Vararg"]. `nothing` when any segment isn't a plain identifier.
function _name_path(t::EXPR)
    if isidentifier(t)
        n = valofid(t)
        return n === nothing ? nothing : [n]
    end
    if is_getfield_w_quotenode(t)
        lhs = _name_path(t.args[1])
        lhs === nothing && return nothing
        q = t.args[2]
        (q isa EXPR && q.args !== nothing && !isempty(q.args) && isidentifier(q.args[1])) || return nothing
        n = valofid(q.args[1])
        n === nothing && return nothing
        return push!(lhs, n)
    end
    return nothing
end

"""
    lower_type_expr(t, typevars) -> TypeExpr

A type annotation as written → the record vocabulary. `typevars` holds the
names bound by the enclosing signature's `where` clause; those lower to
`TypeVarRef`, everything else by name path. Parametric annotations lower to
their head; an inner `where` is its head; unclassifiable shapes are
`UnknownType`.
"""
function lower_type_expr(t::EXPR, typevars::Set{String})
    if CSTParser.isbracketed(t)
        return lower_type_expr(CSTParser.rem_invis(t), typevars)
    end
    if iswhere(t) && t.args !== nothing && !isempty(t.args)
        return lower_type_expr(t.args[1], typevars)
    end
    if _is_union_curly(t)
        return TypeUnionExpr(TypeExpr[lower_type_expr(t.args[i], typevars) for i in 2:length(t.args)])
    end
    if iscurly(t) && t.args !== nothing && length(t.args) >= 1
        return lower_type_expr(t.args[1], typevars)
    end
    path = _name_path(t)
    path === nothing && return UnknownType()
    length(path) == 1 && path[1] in typevars && return TypeVarRef(path[1])
    return TypeRef(path)
end

"""
    method_signature(x::EXPR) -> Union{Nothing,MethodSignature}

The signature record of a function/macro definition or assignment-form method,
read syntactically. `nothing` when the definition has no readable signature
(`function f end`, unreadable shapes) — the caller records shape-unknown.
"""
function method_signature(x::EXPR)
    _is_real_method(x) || return nothing
    sig = CSTParser.get_sig(x)
    sig === nothing && return nothing

    typevar_list = Tuple{String,Union{Nothing,EXPR}}[]
    while sig isa EXPR && (iswhere(sig) || isdeclaration(sig))
        if iswhere(sig)
            for i in 2:length(sig.args)
                vb = where_var_and_bound(sig.args[i])
                vb === nothing || push!(typevar_list, vb)
            end
        end
        sig = sig.args[1]
    end
    (sig isa EXPR && iscall(sig) && sig.args !== nothing) || return nothing

    tvnames = Set{String}(first(vb) for vb in typevar_list)
    typevars = Dict{String,TypeExpr}(
        name => (ub === nothing ? UnknownType() : lower_type_expr(ub, tvnames))
        for (name, ub) in typevar_list)

    slots = SigSlot[]
    vararg = nothing
    kws = Symbol[]
    kwsplat = false

    record_kw!(entry) = begin
        if entry isa EXPR && CSTParser.issplat(entry)
            kwsplat = true
        else
            name_x = _kw_name(entry)
            n = name_x isa EXPR && isidentifier(name_x) ? valofid(name_x) : nothing
            n === nothing || push!(kws, Symbol(n))
        end
    end

    # One pass, in source order: `(expr, optional)` — a defaulted positional
    # parses kwarg-shaped OUTSIDE the `:parameters` block.
    positionals = Tuple{EXPR,Bool}[]
    for i in 2:length(sig.args)
        arg = sig.args[i]
        if isparameters(arg)
            for p in arg.args
                record_kw!(p)
            end
        elseif iskwarg(arg)
            push!(positionals, (arg.args[1], true))
        else
            push!(positionals, (arg, false))
        end
    end

    for (i, (arg, optional)) in enumerate(positionals)
        arg = unwrap_nospecialize(arg)
        if i == length(positionals) && !optional
            n = bounded_vararg_N(arg)
            if n !== nothing || is_explicit_vararg_decl(arg)
                t = arg_decl_type(arg)
                el = iscurly(t) && length(t.args) >= 2 ? lower_type_expr(t.args[2], tvnames) : TYPE_ANY
                vararg = VarargSpec(el, n)
                continue
            end
            if CSTParser.issplat(arg)
                inner = arg.args !== nothing && length(arg.args) >= 1 ? arg.args[1] : nothing
                vararg = VarargSpec(inner === nothing ? TYPE_ANY : _slot_type(inner, tvnames), nothing)
                continue
            end
        end
        push!(slots, SigSlot(_slot_type(arg, tvnames), optional))
    end

    return MethodSignature(slots, vararg, typevars, kws, kwsplat)
end

# The recorded type of one positional parameter: its `::T` annotation, else
# definite `Any` (an unannotated slot accepts anything — certain, not unknown).
function _slot_type(arg, tvnames::Set{String})
    t = arg_decl_type(arg)
    t === nothing && return TYPE_ANY
    return lower_type_expr(t, tvnames)
end

"""
    _erase_slot_types(sig::MethodSignature) -> MethodSignature

Constructor records carry alignment and keywords, never types: fields and
inner-constructor annotations are not a type opinion for dispatch on the type.
"""
_erase_slot_types(sig::MethodSignature) = MethodSignature(
    [SigSlot(UnknownType(), s.optional) for s in sig.slots],
    sig.vararg === nothing ? nothing : VarargSpec(UnknownType(), sig.vararg.count),
    Dict{String,TypeExpr}(), sig.kws, sig.kwsplat)

"""
    declared_supertype(x::EXPR) -> TypeExpr

The declared parent of a datatype definition. No `<:` clause means `Any` —
syntactically certain, so it can end a supertype walk with a verdict.
"""
function declared_supertype(x::EXPR)
    sup = _super(x, nothing, nothing)
    (sup === nothing || sup === CoreTypes.Any) && return TYPE_ANY
    sup isa EXPR || return UnknownType()
    return lower_type_expr(sup, Set{String}())
end
