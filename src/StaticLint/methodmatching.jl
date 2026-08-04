function arg_type(arg, ismethod, meta_dict, store=nothing)
    # Strip `@nospecialize` and `x...` wrappers — the binding/type info
    # lives on the inner expression in both cases. unwrap_nospecialize handles
    # a bare `@nospecialize` (no inner arg) safely.
    arg = unwrap_nospecialize(arg)
    if CSTParser.issplat(arg) && length(arg.args) >= 1
        arg = arg.args[1]
    end
    if ismethod
        # A `x::Union{…}` declaration types the binding as the bare `Union`
        # datatype, dropping the members. Resolve the members directly so
        # subtyping keeps working (needs `store` for member lookup).
        if store !== nothing && isdeclaration(arg) && length(arg.args) >= 2 && _is_union_curly(arg.args[2])
            return _resolve_type_expr(arg.args[2], store, meta_dict)
        end
        if hasbinding(arg, meta_dict)
            if bindingof(arg, meta_dict) isa Binding && bindingof(arg, meta_dict).type !== nothing
                type = bindingof(arg, meta_dict).type
                if type isa Binding && type.val isa SymbolServer.DataTypeStore
                    type = type.val
                elseif type isa Binding && CoreTypes.isdatatype(type.type)
                    # Bound through a typevar (the link's `.type` is the
                    # `DataType` meta-type). A `where` clause may still give an
                    # UPPER bound, and the method can only ever instantiate at a
                    # subtype of it, so the bound is sound for ruling a call out.
                    # `>:` gives a lower bound and licenses nothing.
                    ub = store === nothing ? nothing : where_upper_bound_expr(type)
                    ub === nothing && return CoreTypes.Any
                    return _resolve_type_expr(ub, store, meta_dict)
                end
                return type
            end
        end
    else
        if hasref(arg, meta_dict)
            if refof(arg, meta_dict) isa Binding && refof(arg, meta_dict).type !== nothing
                type = refof(arg, meta_dict).type
                if type isa Binding && type.val isa SymbolServer.DataTypeStore
                    type = type.val
                end
                return type
            end
        elseif (t = infer_literal_type(arg)) !== nothing
            return t
        elseif headof(arg) in (:vect, :vcat, :hcat, :ncat, :typed_vcat, :typed_hcat,
                :typed_ncat, :comprehension, :typed_comprehension)
            # Bare generators aren't arrays; they stay untyped.
            return CoreTypes.Array
        elseif headof(arg) === :ref && arg.args !== nothing && length(arg.args) >= 1 &&
                store !== nothing && _is_type_callee(arg.args[1], store, meta_dict)
            # `T[…]` parses like indexing, but with `T` a type it's a typed
            # array literal.
            return CoreTypes.Array
        elseif isquotedsymbol(arg)
            return SymbolServer.stdlibs[:Core][:Symbol]
        end
    end
    # VarRef(VarRef(nothing, :Core), :Any)
    CoreTypes.Any
end

isquotedsymbol(x) = x isa EXPR && x.head === :quotenode && length(x.args) == 1 && x.args[1].head === :IDENTIFIER && hastrivia(x)

"""
    where_upper_bound_expr(b::Binding)

The type expression of a `where`-bound type variable's UPPER bound, or `nothing`
when it has none: a bare `T`, a lower bound (`T>:B`), or a descending chain. A
typevar's binding keeps the `where` argument as its `.val`, so the bound is
readable from the binding alone.
"""
function where_upper_bound_expr(b::Binding)
    a = b.val
    a isa EXPR || return nothing
    CSTParser.iswhere(parentof(a)) || return nothing
    if a.head isa EXPR && isoperator(a.head) && valof(a.head) == "<:" &&
            a.args !== nothing && length(a.args) == 2 && isidentifier(a.args[1])
        return a.args[2]
    elseif headof(a) === :comparison && a.args !== nothing && length(a.args) == 5 &&
            headof(a.args[2]) === :OPERATOR && headof(a.args[4]) === :OPERATOR &&
            valof(a.args[2]) == "<:" && valof(a.args[4]) == "<:" && isidentifier(a.args[3])
        # `Lo<:T<:Hi`: only the ascending chain has a readable upper bound.
        return a.args[5]
    end
    return nothing
end

# Extract the name from a kwarg in a `:parameters` block. The entry may be a
# bare identifier (sig form `f(a; p)`), a kwarg with default (`p = v`), or a
# typed decl (`p::T`). Bare identifiers have no `.args`.
function _kw_name(x::EXPR)
    x.args !== nothing && !isempty(x.args) ? x.args[1] : x
end

function call_arg_types(call::EXPR, ismethod, meta_dict, store=nothing)
    types, kws = [], []
    call.args === nothing && return types, kws
    if length(call.args) > 1 && headof(call.args[2]) === :parameters
        for i = 1:length(call.args[2].args)
            push!(kws, _kw_name(call.args[2].args[i]))
        end
        for i = 3:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                push!(kws, call.args[i].args[1])
            else
                push!(types, arg_type(call.args[i], ismethod, meta_dict, store))
            end
        end
    else
        for i = 2:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                # `f(a, b, kw = v)` — kwarg without semicolon.
                push!(kws, call.args[i].args[1])
            else
                push!(types, arg_type(call.args[i], ismethod, meta_dict, store))
            end
        end
    end
    types, kws
end

function method_arg_types(call::EXPR, meta_dict, store=nothing)
    types, opts, kws = [], [], []
    call.args === nothing && return types, opts, kws
    if length(call.args) > 1 && headof(call.args[2]) === :parameters
        for i = 1:length(call.args[2].args)
            push!(kws, _kw_name(call.args[2].args[i]))
        end
        for i = 3:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                push!(opts, arg_type(call.args[i].args[1], true, meta_dict, store))
            else
                push!(types, arg_type(call.args[i], true, meta_dict, store))
            end
        end
    else
        for i = 2:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                push!(opts, arg_type(call.args[i].args[1], true, meta_dict, store))
            else
                push!(types, arg_type(call.args[i], true, meta_dict, store))
            end
        end
    end
    types, opts, kws
end

function find_methods(x::EXPR, store, meta_dict)
    possibles = []
    if iscall(x)
        length(x.args) === 0 && return possibles
        func_ref = refof_call_func(x, meta_dict)
        if func_ref === nothing && iscurly(first(x.args)) && first(x.args).args !== nothing &&
                length(first(x.args).args) >= 1 && isidentifier(first(first(x.args).args)) &&
                hasref(first(first(x.args).args), meta_dict)
            # parametric constructor call `P{T}(...)`
            func_ref = refof(first(first(x.args).args), meta_dict)
        end
        func_ref === nothing && return possibles
        # follow shadow bindings (`const g = f`), with fuel against cycles
        fuel = 20
        while func_ref isa Binding && func_ref.val isa Binding && fuel > 0
            func_ref = func_ref.val
            fuel -= 1
        end
        args, kws = call_arg_types(x, false, meta_dict, store)
        if func_ref isa Binding && func_ref.val isa SymbolServer.FunctionStore ||
            func_ref isa Binding && func_ref.val isa SymbolServer.DataTypeStore
            func_ref = func_ref.val
        end
        if func_ref isa SymbolServer.FunctionStore || func_ref isa SymbolServer.DataTypeStore
            for method in func_ref.methods
                if match_method(args, kws, method, store, meta_dict)
                    push!(possibles, method)
                end
            end
        elseif func_ref isa Binding
            if (CoreTypes.isfunction(func_ref.type) || CoreTypes.isdatatype(func_ref.type)) && func_ref.val isa EXPR
                for method in func_ref.refs
                    method = get_method(method)
                    if method !== nothing
                        if method isa SymbolServer.FunctionStore
                            for method1 in method.methods
                                if match_method(args, kws, method1, store, meta_dict)
                                    push!(possibles, method1)
                                end
                            end
                        elseif match_method(args, kws, method, store, meta_dict)
                            push!(possibles, method)
                        end
                    end
                end
            elseif (method = method_of_callable_datatype(func_ref)) !== nothing
                if match_method(args, kws, method, store, meta_dict)
                    push!(possibles, method)
                end
            end
        end
    end
    possibles
end

"""
    is_explicit_vararg_decl(arg)

True if `arg` is a method-arg declaration of the form `x::Vararg` or
`x::Vararg{...}` (the explicit `::Vararg` spelling, not the `x...` splat).
"""
function is_explicit_vararg_decl(arg)
    t = arg_decl_type(arg)
    t === nothing && return false
    names_vararg(t) && return true
    iscurly(t) && length(t.args) >= 1 && names_vararg(t.args[1]) && return true
    return false
end

"Does this type expression name `Vararg`, bare or dotted (`Base.Vararg`)?"
function names_vararg(t)
    t isa EXPR || return false
    isidentifier(t) && return valofid(t) == "Vararg"
    if is_getfield_w_quotenode(t)
        q = t.args[2]
        return q isa EXPR && q.args !== nothing && !isempty(q.args) &&
            isidentifier(q.args[1]) && valofid(q.args[1]) == "Vararg"
    end
    return false
end

"""
    arg_decl_type(arg)

The type expression of a method-arg declaration, for both the bound `x::T` form
and the anonymous `::T` form; `nothing` for anything else. The anonymous form is
UNARY `::`, so it has one argument rather than two and `isdeclaration` is false
for it — reading only the binary form silently treats `f(::Vararg{Int})` as one
ordinary positional.
"""
function arg_decl_type(arg)
    arg isa EXPR || return nothing
    if isdeclaration(arg)
        return length(arg.args) >= 2 ? arg.args[2] : nothing
    end
    h = headof(arg)
    if h isa EXPR && isoperator(h) && valof(h) == "::" && arg.args !== nothing && length(arg.args) == 1
        return arg.args[1]
    end
    return nothing
end

"""
    bounded_vararg_N(arg)

Return the literal `N` if `arg` is a method-arg declaration `x::Vararg{T,N}`
with an integer literal `N`; otherwise `nothing`. Distinguishes bounded
`Vararg{T,N}` (consumes exactly N args) from unbounded `Vararg{T}` and
parametric `Vararg{T,N} where N`.
"""
function bounded_vararg_N(arg)
    t = arg_decl_type(arg)
    t === nothing && return nothing
    iscurly(t) || return nothing
    length(t.args) == 3 || return nothing
    names_vararg(t.args[1]) || return nothing
    N_expr = t.args[3]
    CSTParser.headof(N_expr) === :INTEGER || return nothing
    N_expr.val isa AbstractString || return nothing
    return tryparse(Int, N_expr.val)
end

function match_method(args::Vector{Any}, kws::Vector{Any}, method::SymbolServer.MethodStore, store, meta_dict)
    !isempty(kws) && isempty(method.kws) && return false
    nsig = length(method.sig)
    if nsig > 0 && last(method.sig)[2] isa SymbolServer.FakeTypeofVararg
        va = last(method.sig)[2]
        n_no_vararg = nsig - 1
        # Bounded `Vararg{T,N}` consumes exactly N args; unbounded `Vararg{T}`
        # and `Vararg{T,N} where N` accept any count.
        if isdefined(va, :N) && va.N isa Integer
            length(args) == n_no_vararg + va.N || return false
        else
            length(args) >= n_no_vararg || return false
        end
        # Only a DEFINITE mismatch rules a method out. An unknown slot leaves the
        # method a candidate — flagging on ignorance is a false positive.
        for i in 1:n_no_vararg
            t = method.sig[i][2]
            _has_type_intersection(args[i], t, store, meta_dict) === false && return false
        end
        for i in (n_no_vararg + 1):length(args)
            _has_type_intersection(args[i], va.T, store, meta_dict) === false && return false
        end
        return true
    end
    length(args) == nsig || return false
    for i in 1:length(args)
        t = method.sig[i][2]
        _has_type_intersection(args[i], t, store, meta_dict) === false && return false
    end
    return true
end

# True for a `Union{A,B,…}` type-position EXPR (at least one member).
_is_union_curly(t) =
    iscurly(t) && length(t.args) >= 2 && isidentifier(t.args[1]) && valofid(t.args[1]) == "Union"

# Nest resolved members into a binary `FakeUnion` (mirrors how the store carries
# unions), so `_has_type_intersection` can test the branches individually.
_fake_union(members) = foldl(SymbolServer.FakeUnion, members)

# True when `t` provably refers to a type: a store `DataTypeStore` (possibly
# behind its constructor `FunctionStore`) or a locally defined datatype.
function _is_type_callee(t, store, meta_dict)
    if iscurly(t) && length(t.args) >= 1
        t = t.args[1]
    end
    hasref(t, meta_dict) || return false
    r = refof(t, meta_dict)
    r isa SymbolServer.DataTypeStore && return true
    if r isa SymbolServer.FunctionStore
        return SymbolServer._lookup(r.extends, store) isa SymbolServer.DataTypeStore
    end
    r isa Binding || return false
    return r.type == CoreTypes.DataType || (r.type isa Binding && r.type.val isa SymbolServer.DataTypeStore)
end

# Resolve a type-position EXPR (`String`, `Vector{Int}`, …) to the SymbolServer
# type used by `_has_type_intersection`. A type name often `refof`s to its
# constructor `FunctionStore`; we follow `extends` back to the `DataTypeStore`.
# Falls back to `CoreTypes.Any` if resolution fails.
function _resolve_type_expr(t, store, meta_dict)
    if _is_union_curly(t)
        # A call matches a `Union{…}` slot if it matches any member, so keep the
        # members rather than collapsing to the `Union` datatype (which drops them).
        return _fake_union([_resolve_type_expr(t.args[i], store, meta_dict) for i in 2:length(t.args)])
    end
    if iscurly(t) && length(t.args) >= 1
        t = t.args[1]
    end
    hasref(t, meta_dict) || return CoreTypes.Any
    r = refof(t, meta_dict)
    if r isa SymbolServer.DataTypeStore
        return r
    elseif r isa SymbolServer.FunctionStore
        dt = SymbolServer._lookup(r.extends, store)
        return dt === nothing ? CoreTypes.Any : dt
    elseif r isa Binding && r.type isa Binding && r.type.val isa SymbolServer.DataTypeStore
        return r.type.val
    end
    return CoreTypes.Any
end

function match_method(args::Vector{Any}, kws::Vector{Any}, method::EXPR, store, meta_dict)
    margs, mopts, mkws = [], [], []
    vararg = false
    vararg_N = nothing
    if CSTParser.defines_struct(method)
        for i in 1:length(method.args[3].args)
            arg = method.args[3].args[i]
            if defines_function(arg)
                # Hit an inner constructor so forget about the default one. The
                # call matches the struct if it matches ANY of them — they are
                # alternative methods, not conjunctive requirements.
                for arg in method.args[3].args
                    if defines_function(arg)
                        match_method(args, kws, arg, store, meta_dict) && return true
                    end
                end
                return false
            end
            push!(margs, arg_type(arg, true, meta_dict, store))
        end
    else
        # `rem_wheres_decls` strips outer `where` clauses (so parametric
        # `Vararg{T,N} where N` is reachable) and the outer return-type decl.
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(method))

        # Bare forward declaration `function f end`: `get_sig` returns the lone
        # name (an EXPR with `args === nothing`), no signature to match. It is
        # not a method, so it matches no call.
        sig.args === nothing && return false

        # Element type for an explicit `::Vararg{T,...}` slot.
        vararg_T = nothing
        if length(sig.args) > 0
            last_arg = unwrap_nospecialize(last(sig.args))
            vararg_N = bounded_vararg_N(last_arg)
            if vararg_N !== nothing || is_explicit_vararg_decl(last_arg)
                vararg = true
                ty = last_arg.args[2]
                if iscurly(ty) && length(ty.args) >= 2
                    vararg_T = _resolve_type_expr(ty.args[2], store, meta_dict)
                end
            end
            if CSTParser.issplat(last_arg)
                vararg = true
            end
        end

        margs, mopts, mkws = method_arg_types(sig, meta_dict, store)
    end
    !isempty(kws) && isempty(mkws) && return false

    # Bounded `Vararg{T,N}`: require exactly nfixed + N positional args and
    # match the trailing slots against `T`.
    if vararg_N !== nothing
        nfixed = length(margs) - 1
        length(args) == nfixed + vararg_N || return false
        tail = vararg_T === nothing ? CoreTypes.Any : vararg_T
        # Only a DEFINITE mismatch rules a method out. An unknown slot leaves the
        # method a candidate — flagging on ignorance is a false positive.
        for i in 1:nfixed
            _has_type_intersection(args[i], margs[i], store, meta_dict) === false && return false
        end
        for i in (nfixed + 1):length(args)
            _has_type_intersection(args[i], tail, store, meta_dict) === false && return false
        end
        return true
    end

    if length(margs) < length(args)
        for i in 1:min(length(mopts), length(args) - length(margs))
            push!(margs, mopts[i])
        end
        if vararg
            pad = vararg_T === nothing ? CoreTypes.Any : vararg_T
            for _ in 1:length(args) - length(margs)
                push!(margs, pad)
            end
        end
    end

    if length(args) == length(margs) || (vararg && length(args) == length(margs) - 1)
        for i in 1:length(args)
            _has_type_intersection(args[i], margs[i], store, meta_dict) === false && return false
        end
        return true
    end
    return false
end

function refof_call_func(x, meta_dict)
    if isidentifier(first(x.args)) && hasref(first(x.args), meta_dict)
        return refof(first(x.args), meta_dict)
    elseif is_getfield_w_quotenode(x.args[1]) && (rhs = rhs_of_getfield(x.args[1])) !== nothing && hasref(rhs, meta_dict)
        return refof(rhs, meta_dict)
    else
        return
    end
end

function is_sig_of_method(sig::EXPR, method = maybe_get_parent_fexpr(sig, defines_function))
    method !== nothing && sig == CSTParser.get_sig(method)
end

function method_of_callable_datatype(b::Binding)
    if b.type isa Binding && b.type.type === CoreTypes.DataType
        for ref in b.type.refs
            if ref isa EXPR && ref.parent isa EXPR && isdeclaration(ref.parent) && is_in_fexpr(ref.parent, x -> x.parent isa EXPR && x.parent.head === :call && x == x.parent.args[1] && is_in_funcdef(x.parent))
                return get_parent_fexpr(ref, defines_function)
            end
        end
    end
end
