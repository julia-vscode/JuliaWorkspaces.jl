# The comparison operand for a `::T` annotation `t` whose head names a
# workspace datatype resolved (cross-file) to a `TreeRef`, or `nothing` when it
# doesn't. Unwraps `where`/curly to the head first, as `_names_workspace_datatype`
# does — the same idiom used wherever an annotation's own ref stands in for a
# type `Binding.type` can't carry.
function _annotation_treeref_operand(t, meta_dict, resolver)
    while iswhere(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    if iscurly(t) && t.args !== nothing && !isempty(t.args)
        t = t.args[1]
    end
    r = is_getfield_w_quotenode(t) ? refof_maybe_getfield(t, meta_dict) :
        (isidentifier(t) ? refof(t, meta_dict) : nothing)
    r isa TreeRef ? _treeref_operand(r, resolver) : nothing
end

function arg_type(arg, ismethod, meta_dict, store=nothing, resolver=nothing)
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
            return _resolve_type_expr(arg.args[2], store, meta_dict, resolver)
        end
        if hasbinding(arg, meta_dict)
            if bindingof(arg, meta_dict) isa Binding && bindingof(arg, meta_dict).type !== nothing
                type = bindingof(arg, meta_dict).type
                if type isa Binding && type.val isa SymbolServer.DataTypeStore
                    type = type.val
                elseif type isa Binding && CoreTypes.isdatatype(type.type) &&
                       type.val isa EXPR && CSTParser.iswhere(parentof(type.val))
                    # A genuine typevar binding (its `.val` sits in a `where`
                    # clause) — NOT a real datatype's own binding, which also
                    # carries `.type == DataType` but whose `.val` is the
                    # struct/abstract/primitive declaration itself (handled by
                    # the `return type` below via `_super`). A `where` clause
                    # may still give an UPPER bound, and the method can only
                    # ever instantiate at a subtype of it, so the bound is
                    # sound for ruling a call out. `>:` gives a lower bound and
                    # licenses nothing.
                    ub = store === nothing ? nothing : where_upper_bound_expr(type)
                    ub === nothing && return CoreTypes.Any
                    return _resolve_type_expr(ub, store, meta_dict, resolver)
                end
                return type
            end
        elseif store !== nothing
            # A nameless `::T` slot binds no name, so no Binding ever carries
            # its type — the usual by-binding inference never runs for it.
            # Read the annotation directly.
            t = arg_decl_type(arg)
            t !== nothing && return _resolve_type_expr(t, store, meta_dict, resolver)
        end
        # A NAMED slot's annotation resolved (cross-file) to a `TreeRef`:
        # `Binding.type` can't carry one, so the by-binding path above fell
        # through with no type. Read the annotation's own ref directly.
        if resolver !== nothing && isdeclaration(arg) && length(arg.args) >= 2
            dt = _annotation_treeref_operand(arg.args[2], meta_dict, resolver)
            dt === nothing || return dt
        end
    else
        # A `where` typevar PASSED as an argument: its binding carries the
        # `DataType` meta-type, but the variable can bind a VALUE
        # (`NamedTuple{names}`, `Val{N}`), and which it is cannot be read here.
        # No opinion rather than a wrong one — and the same operand the message
        # printer reports, so a rule-out can never contradict its own reason.
        _is_where_typevar_ref(arg, meta_dict) && return CoreTypes.Any
        # A constructor-call argument (`f(Own())`) types as the constructed
        # datatype rather than falling through to `Any`.
        if iscall(arg) && arg.args !== nothing && !isempty(arg.args) && store !== nothing &&
                _is_type_callee(arg.args[1], store, meta_dict)
            return _resolve_type_expr(arg.args[1], store, meta_dict, resolver)
        end
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
        # `arg` refs a binding whose OWN declaration annotation resolved
        # (cross-file) to a `TreeRef` — the same gap as the method side, one
        # hop removed: the by-ref path above fell through with no type
        # because `Binding.type` can't carry the TreeRef its declaration read.
        if resolver !== nothing && hasref(arg, meta_dict)
            b = refof(arg, meta_dict)
            if b isa Binding
                t = decl_annotation(b)
                if t !== nothing
                    dt = _annotation_treeref_operand(t, meta_dict, resolver)
                    dt === nothing || return dt
                end
            end
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
# bare identifier (sig form `f(a; p)`), a kwarg with default (`p = v`), a typed
# decl (`p::T`), or both (`p::T = v`). Bare identifiers have no `.args`.
function _kw_name(x::EXPR)
    n = x.args !== nothing && !isempty(x.args) ? x.args[1] : x
    return isdeclaration(n) && n.args !== nothing && !isempty(n.args) ? n.args[1] : n
end

# A keyword name as a `String`, regardless of which descriptor path produced
# it: a `Symbol` (record and store descriptors) or an identifier `EXPR` (call
# sites, and the EXPR-method descriptor). `nothing` for anything unreadable —
# callers must treat that as no opinion, never as a name mismatch.
_kw_name_str(x::Symbol) = String(x)
_kw_name_str(x::EXPR) = isidentifier(x) ? valofid(x) : nothing
_kw_name_str(x) = nothing

# Index of a call's first argument: past the callee, and past a `:parameters`
# block when the call has one.
_first_arg_index(call::EXPR) =
    length(call.args) > 1 && headof(call.args[2]) === :parameters ? 3 : 2

# The call's POSITIONAL argument expressions, in the order `call_arg_types`
# types them — the two must stay index-aligned.
function positional_args(call::EXPR)
    out = EXPR[]
    call.args === nothing && return out
    for i = _first_arg_index(call):length(call.args)
        CSTParser.iskwarg(call.args[i]) || push!(out, call.args[i])
    end
    return out
end

function call_arg_types(call::EXPR, ismethod, meta_dict, store=nothing, resolver=nothing)
    types, kws = [], []
    call.args === nothing && return types, kws
    if length(call.args) > 1 && headof(call.args[2]) === :parameters
        for i = 1:length(call.args[2].args)
            p = call.args[2].args[i]
            # `f(x; kws...)` passes an unknown — possibly empty — keyword set,
            # which can rule nothing out. Recording the splat's own name would
            # read as passing a keyword called `kws`.
            !ismethod && CSTParser.issplat(p) && continue
            push!(kws, _kw_name(p))
        end
    end
    for i = _first_arg_index(call):length(call.args)
        if CSTParser.iskwarg(call.args[i])
            # `f(a, b, kw = v)` — kwarg without semicolon.
            push!(kws, call.args[i].args[1])
        else
            push!(types, arg_type(call.args[i], ismethod, meta_dict, store, resolver))
        end
    end
    types, kws
end

function method_arg_types(call::EXPR, meta_dict, store=nothing, resolver=nothing)
    types, opts, kws = [], [], []
    kwsplat = false
    call.args === nothing && return types, opts, kws, kwsplat
    if length(call.args) > 1 && headof(call.args[2]) === :parameters
        for i = 1:length(call.args[2].args)
            entry = call.args[2].args[i]
            if CSTParser.issplat(entry)
                kwsplat = true
            else
                push!(kws, _kw_name(entry))
            end
        end
        for i = 3:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                push!(opts, arg_type(call.args[i].args[1], true, meta_dict, store, resolver))
            else
                push!(types, arg_type(call.args[i], true, meta_dict, store, resolver))
            end
        end
    else
        for i = 2:length(call.args)
            if CSTParser.iskwarg(call.args[i])
                push!(opts, arg_type(call.args[i].args[1], true, meta_dict, store, resolver))
            else
                push!(types, arg_type(call.args[i], true, meta_dict, store, resolver))
            end
        end
    end
    types, opts, kws, kwsplat
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

"""
    SigDescriptor

A callable signature reduced to what alignment needs. `fixed` includes the
vararg slot's own type as its LAST element whenever `has_vararg` and
`vararg_N === nothing` (the unbounded/parametric forms) — this is what lets a
single formula reproduce both the store and EXPR bodies.
"""
struct SigDescriptor
    fixed::Vector{Any}
    opts::Vector{Any}
    has_vararg::Bool
    vararg_pad::Any
    vararg_N::Union{Nothing,Int}
    kws::Vector{Any}
    # `; kwargs...` — the method takes any keyword, so no keyword rules it out.
    kwsplat::Bool
end
SigDescriptor(fixed, opts, has_vararg, pad, N, kws) =
    SigDescriptor(fixed, opts, has_vararg, pad, N, kws, false)

"""
    MatchRecorder

Observation hook for the matching engine: `comparisons` counts the candidates
examined, `rule_outs` the definite mismatches among them. Set
`_match_recorder[]` to record, back to `nothing` to stop; unset costs one `Ref`
load per candidate.
"""
mutable struct MatchRecorder
    comparisons::Int
    rule_outs::Int
end
MatchRecorder() = MatchRecorder(0, 0)

const _match_recorder = Ref{Union{Nothing,MatchRecorder}}(nothing)

function match_descriptor(args::Vector{Any}, kws::Vector{Any}, d::SigDescriptor, store, meta_dict, resolver=nothing)
    res = _match_descriptor(args, kws, d, store, meta_dict, resolver)
    r = _match_recorder[]
    if r !== nothing
        r.comparisons += 1
        res || (r.rule_outs += 1)
    end
    return res
end

# The parameter type each of `n` positional arguments lands on, in order: the
# required slots, then as many optional slots as the call fills, then the vararg
# pad for whatever is left. `nothing` when `n` cannot fit the signature at all.
# The vararg pad is NOT one of `fixed` — a defaulted slot always precedes it, so
# a descriptor that carried the pad among the fixed slots would compare every
# optional argument against the vararg's element type.
function _align_args(d::SigDescriptor, n::Int)
    nfixed = length(d.fixed)
    if d.vararg_N !== nothing
        nopt = n - d.vararg_N - nfixed
        (nopt < 0 || nopt > length(d.opts)) && return nothing
        return Any[d.fixed; d.opts[1:nopt]; fill(d.vararg_pad, d.vararg_N)]
    end
    n < nfixed && return nothing
    nopt = min(length(d.opts), n - nfixed)
    nva = n - nfixed - nopt
    nva > 0 && !d.has_vararg && return nothing
    return Any[d.fixed; d.opts[1:nopt]; fill(d.vararg_pad, nva)]
end

function _match_descriptor(args::Vector{Any}, kws::Vector{Any}, d::SigDescriptor, store, meta_dict, resolver=nothing)
    if !isempty(kws) && !d.kwsplat
        ref = [_kw_name_str(k) for k in d.kws]
        if !any(isnothing, ref)
            # Every declared name is readable, so absence from `ref` is a
            # genuine mismatch rather than a blind spot. A call kw we can't
            # read gets no opinion — it neither confirms nor rules out.
            refset = Set(ref)
            for k in kws
                n = _kw_name_str(k)
                n === nothing && continue
                n in refset || return false
            end
        end
        # else: some declared kw is unreadable — the method may accept names
        # we can't see, so name-checking is skipped for this candidate.
    end

    margs = _align_args(d, length(args))
    margs === nothing && return false

    # Only a DEFINITE mismatch rules a method out. An unknown slot leaves the
    # method a candidate — flagging on ignorance is a false positive.
    for i in eachindex(args)
        _has_type_intersection(args[i], margs[i], store, meta_dict, resolver) === false && return false
    end
    return true
end

# `Base.kwarg_decl` encodes a `; kwargs...` catch-all as a literal Symbol
# ending in `"..."` mixed into a `MethodStore`'s `kws` list, not a separate
# flag. Splits it out so callers never name-check the splat itself.
function _split_kwsplat(kws::Vector{Symbol})
    out = Symbol[]
    kwsplat = false
    for kw in kws
        if endswith(String(kw), "...")
            kwsplat = true
        else
            push!(out, kw)
        end
    end
    return out, kwsplat
end

function lower_descriptor(method::SymbolServer.MethodStore)
    fixed = Any[last(p) for p in method.sig]
    has_vararg = false
    pad = CoreTypes.Any
    N = nothing
    if !isempty(fixed) && last(fixed) isa SymbolServer.FakeTypeofVararg
        va = last(fixed)
        has_vararg = true
        pad = va.T
        if isdefined(va, :N) && va.N isa Integer
            N = va.N
        end
        pop!(fixed)   # the vararg slot is the pad, not a fixed parameter
    end
    kws, kwsplat = _split_kwsplat(method.kws)
    return SigDescriptor(fixed, Any[], has_vararg, pad, N, Vector{Any}(kws), kwsplat)
end

match_method(args::Vector{Any}, kws::Vector{Any}, method::SymbolServer.MethodStore, store, meta_dict) =
    match_descriptor(args, kws, lower_descriptor(method), store, meta_dict)

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
function _resolve_type_expr(t, store, meta_dict, resolver=nothing)
    if _is_union_curly(t)
        # A call matches a `Union{…}` slot if it matches any member, so keep the
        # members rather than collapsing to the `Union` datatype (which drops them).
        members = [_resolve_type_expr(t.args[i], store, meta_dict, resolver) for i in 2:length(t.args)]
        all(m -> m isa SymbolServer.DataTypeStore || m isa SymbolServer.FakeTypeName, members) &&
            return _fake_union(members)      # store-only unions keep the store shape
        return ResolvedUnion(members)
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
    elseif r isa Binding && r.val isa SymbolServer.DataTypeStore
        # `using Base: UUID` binds the name locally, but the operand is the store
        # type the import stands for — the binding itself carries no supertype
        # chain, so returning it would rule out every call it types.
        return r.val
    elseif r isa Binding && CoreTypes.isdatatype(r.type)
        # A workspace datatype's own binding (`struct`/`abstract`/`primitive`):
        # its supertype chain is walkable directly through `_super(::Binding)`.
        return r
    elseif r isa TreeRef && resolver !== nothing
        dt = _treeref_operand(r, resolver)
        return dt === nothing ? CoreTypes.Any : dt
    end
    return CoreTypes.Any
end

function match_method(args::Vector{Any}, kws::Vector{Any}, method::EXPR, store, meta_dict, resolver=nothing)
    margs, mopts, mkws = [], [], []
    mkwsplat = false
    vararg = false
    vararg_N = nothing
    vararg_T = nothing
    if CSTParser.defines_struct(method)
        for i in 1:length(method.args[3].args)
            arg = method.args[3].args[i]
            if defines_function(arg)
                # Hit an inner constructor so forget about the default one. The
                # call matches the struct if it matches ANY of them — they are
                # alternative methods, not conjunctive requirements.
                for arg in method.args[3].args
                    if defines_function(arg)
                        match_method(args, kws, arg, store, meta_dict, resolver) && return true
                    end
                end
                return false
            end
            push!(margs, arg_type(arg, true, meta_dict, store, resolver))
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
                    vararg_T = _resolve_type_expr(ty.args[2], store, meta_dict, resolver)
                end
            end
            if CSTParser.issplat(last_arg)
                vararg = true
            end
        end

        margs, mopts, mkws, mkwsplat = method_arg_types(sig, meta_dict, store, resolver)
        # The trailing vararg slot is the pad, not a fixed parameter.
        vararg && !isempty(margs) && pop!(margs)
    end
    pad = vararg_T === nothing ? CoreTypes.Any : vararg_T
    d = SigDescriptor(margs, mopts, vararg, pad, vararg_N, mkws, mkwsplat)
    return match_descriptor(args, kws, d, store, meta_dict, resolver)
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
