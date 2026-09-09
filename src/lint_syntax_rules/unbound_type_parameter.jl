# unbound_type_parameter: a method `where` parameter that no argument type
# binds. Ported idea: Aqua.jl's `test_unbound_args`.
#
# Mirrors `Test.detect_unbound_args`, whose ground truth is
# `Core.Compiler.constrains_param(var, sig, covariant=true, type_constrains=true)`
# on the method signature: a parameter is bound by appearing in an argument
# type directly, through invariant type parameters at any depth, through
# `Type{T}`, through EVERY branch of a `Union`, covariantly through an upper
# bound (`A{<:T}` at the top level of an argument, an explicit inner `where`,
# or a later where-parameter's `<:` bound), or through the `N` of
# `Vararg{T,N}`. Return-type annotations, lower bounds, and a trailing
# vararg's element type never bind — `f(::T...)` leaves `T` undefined for the
# empty call. Keyword argument types DO bind: lowering passes them
# positionally to the keyword-body method, which is what Julia's own check
# reports on.
#
# Deliberate divergences from the runtime check, both toward silence:
# a parameter that is never mentioned again at all is `unused_type_parameter`'s
# finding and skipped here; a type expression the model cannot interpret (a
# macro call, a computed type) suppresses the check for that parameter.

const _UNBOUND_TYPE_PARAMETER_MESSAGE_SUFFIX =
    " is not bound by the argument types of this method and will be undefined when it runs."

_utp_identifier_name(node) =
    kind(node) === K"Identifier" && node.val isa Symbol ? node.val : nothing

# `<:X`/`>:X` written as a bare prefix type parameter (`A{<:T}`).
_utp_is_prefix_bound(node) =
    (kind(node) === K"<:" || kind(node) === K">:") &&
    !JuliaSyntax.is_leaf(node) && length(children(node)) == 1

# The rightmost name of a possibly qualified head (`Vector`, `Base.RefValue`).
function _utp_head_name(node)
    n = _utp_identifier_name(node)
    n === nothing || return n
    if kind(node) === K"." && !JuliaSyntax.is_leaf(node) && !isempty(children(node))
        return _utp_identifier_name(children(node)[end])
    end
    return nothing
end

# `Vararg{X}` / `Vararg{X,N}` -> (X, N or nothing); anything else -> nothing.
function _utp_vararg_parts(node)
    kind(node) === K"curly" && !JuliaSyntax.is_leaf(node) || return nothing
    cs = children(node)
    length(cs) >= 2 || return nothing
    _utp_head_name(cs[1]) === :Vararg || return nothing
    return (cs[2], length(cs) >= 3 ? cs[3] : nothing)
end

"""
    _utp_typevar_decls(nodes) -> Union{Nothing,Vector}

The `(name_node, name, ub)` triples a `where` clause tail declares, `braces`
lists unwrapped, in source order (outermost first). `ub` is the `<:` upper
bound expression or `nothing` (lower bounds never bind anything). `nothing`
when any declaration has a shape the model does not know, in which case the
whole method is skipped.
"""
function _utp_typevar_decls(nodes)
    out = Tuple{SyntaxNode,Symbol,Union{Nothing,SyntaxNode}}[]
    work = SyntaxNode[]
    for n in nodes
        if kind(n) === K"braces" && !JuliaSyntax.is_leaf(n)
            append!(work, children(n))
        else
            push!(work, n)
        end
    end
    for e in work
        name = _utp_identifier_name(e)
        if name !== nothing
            push!(out, (e, name, nothing))
            continue
        end
        k = kind(e)
        JuliaSyntax.is_leaf(e) && return nothing
        cs = children(e)
        if (k === K"<:" || k === K">:") && length(cs) == 2
            n1 = _utp_identifier_name(cs[1])
            n1 === nothing && return nothing
            push!(out, (cs[1], n1, k === K"<:" ? cs[2] : nothing))
        elseif k === K"comparison" && length(cs) == 5
            # `lb <: T <: ub` (or `ub >: T >: lb`); the middle is the variable.
            op1, op2 = _utp_identifier_name(cs[2]), _utp_identifier_name(cs[4])
            var = _utp_identifier_name(cs[3])
            var === nothing && return nothing
            if op1 === :<: && op2 === :<:
                push!(out, (cs[3], var, cs[5]))
            elseif op1 === :>: && op2 === :>:
                push!(out, (cs[3], var, cs[1]))
            else
                return nothing
            end
        else
            return nothing
        end
    end
    return out
end

"""
    _utp_constrains(name, node, cov, unknown) -> Bool

Does the type expression `node` bind the where-parameter `name`? `cov` is the
variance of the position (`constrains_param`'s `covariant`). A construct the
model cannot interpret sets `unknown[]`, which suppresses reporting.
"""
function _utp_constrains(name::Symbol, node::SyntaxNode, cov::Bool, unknown::Base.RefValue{Bool})
    n = _utp_identifier_name(node)
    n === nothing || return n === name

    if JuliaSyntax.is_leaf(node)
        # Number/char/… literal type parameters are known non-binders; a leaf
        # of any other flavor (`var"T"`, an operator) is beyond the model.
        node.val isa Union{Number,AbstractString,AbstractChar,Bool} && return false
        unknown[] = true
        return false
    end

    k = kind(node)
    cs = children(node)

    if k === K"."
        # A qualified name cannot be the type variable.
        return false
    elseif k === K"quote"
        # Symbols as type parameters (`Val{:x}`) never bind.
        return false
    elseif k === K"where"
        # An explicit inner unionall: its upper bounds bind covariantly; its
        # body is checked unless the inner clause shadows `name`.
        isempty(cs) && return false
        decls = _utp_typevar_decls(cs[2:end])
        decls === nothing && (unknown[] = true; return false)
        for (_, _, ub) in decls
            cov && ub !== nothing && _utp_constrains(name, ub, cov, unknown) && return true
        end
        any(d -> d[2] === name, decls) && return false
        return _utp_constrains(name, cs[1], cov, unknown)
    elseif _utp_is_prefix_bound(node)
        # A bare `(<:T)` annotation: an implicit unionall around the argument.
        return kind(node) === K"<:" && cov && _utp_constrains(name, cs[1], cov, unknown)
    elseif k === K"curly"
        isempty(cs) && return false
        head = _utp_head_name(cs[1])
        params = cs[2:end]

        # `A{<:X}` is `A{S} where S<:X`, the unionall wrapping `A` itself: in a
        # covariant position its upper bound binds (`f(x::Vector{<:T})`), in an
        # invariant one it does not (`f(x::Ref{Vector{<:T}})`).
        for p in params
            if _utp_is_prefix_bound(p) && kind(p) === K"<:"
                cov && _utp_constrains(name, children(p)[1], cov, unknown) && return true
            end
        end

        if head === :Union
            # Every branch must bind (`Union{Int,T}` leaves `T` free).
            plain = [p for p in params if !_utp_is_prefix_bound(p)]
            length(plain) == length(params) || return false
            return !isempty(plain) &&
                all(p -> _utp_constrains(name, p, cov, unknown), plain)
        elseif head === :Tuple
            # Tuples are covariant; a trailing `Vararg{X}` binds only via `N`.
            for (i, p) in enumerate(params)
                _utp_is_prefix_bound(p) && continue
                va = i == length(params) ? _utp_vararg_parts(p) : nothing
                if va !== nothing
                    va[2] !== nothing && _utp_constrains(name, va[2], cov, unknown) && return true
                else
                    _utp_constrains(name, p, cov, unknown) && return true
                end
            end
            return false
        elseif head === :Vararg
            return length(params) >= 2 && _utp_constrains(name, params[2], cov, unknown)
        elseif head === :Type
            return length(params) == 1 && !_utp_is_prefix_bound(params[1]) &&
                _utp_constrains(name, params[1], false, unknown)
        elseif head === nothing
            unknown[] = true
            return false
        else
            # Any other parameterized type: parameters are invariant.
            for p in params
                _utp_is_prefix_bound(p) && continue
                _utp_constrains(name, p, false, unknown) && return true
            end
            return false
        end
    end

    unknown[] = true
    return false
end

# Count occurrences of `name` anywhere in the definition besides the
# declaration itself; zero means `unused_type_parameter` owns the finding.
function _utp_occurs_besides(name::Symbol, node::SyntaxNode, decl_node::SyntaxNode)
    if node !== decl_node && _utp_identifier_name(node) === name
        return true
    end
    JuliaSyntax.is_leaf(node) && return false
    return any(c -> _utp_occurs_besides(name, c, decl_node), children(node))
end

# The `(type_node, cov)` argument slots of a method signature `call`, in
# `constrains_param` terms: the callable-object/constructor slot, positional
# arguments (defaults unwrapped, the trailing vararg's element type dropped),
# and keyword arguments.
function _utp_argument_types(call::SyntaxNode)
    slots = Tuple{SyntaxNode,Bool}[]
    cs = children(call)
    isempty(cs) && return slots

    f = cs[1]
    if kind(f) === K"::" && !JuliaSyntax.is_leaf(f)
        fcs = children(f)
        push!(slots, (fcs[length(fcs) == 2 ? 2 : 1], true))
    elseif kind(f) === K"curly"
        # A constructor `Foo{T}(x)`: the slot type is `Type{Foo{T}}`, whose
        # parameter is invariant.
        push!(slots, (f, false))
    end

    positional = SyntaxNode[]
    keyword = SyntaxNode[]
    for a in cs[2:end]
        if kind(a) === K"parameters" && !JuliaSyntax.is_leaf(a)
            append!(keyword, children(a))
        else
            push!(positional, a)
        end
    end

    function push_arg!(a, allow_vararg_n)
        kind(a) === K"=" && !JuliaSyntax.is_leaf(a) && (a = children(a)[1])
        isva = kind(a) === K"..." && !JuliaSyntax.is_leaf(a)
        isva && (a = children(a)[1])
        kind(a) === K"::" && !JuliaSyntax.is_leaf(a) || return
        acs = children(a)
        t = acs[length(acs) == 2 ? 2 : 1]
        if isva
            # `x::T...`: the element type never binds (the empty call).
            return
        end
        if allow_vararg_n
            va = _utp_vararg_parts(t)
            if va !== nothing
                # `x::Vararg{T,N}`: `N` binds, `T` does not.
                va[2] !== nothing && push!(slots, (va[2], true))
                return
            end
        end
        push!(slots, (t, true))
    end

    for (i, a) in enumerate(positional)
        push_arg!(a, i == length(positional))
    end
    for a in keyword
        push_arg!(a, false)
    end
    return slots
end

function _check_unbound_type_parameter(emit!, node, _ctx)
    cs = children(node)
    isempty(cs) && return nothing
    kind(cs[1]) === K"where" || return nothing

    # Collect the where layers, outermost first (`braces` lists are already
    # outer-to-inner left to right).
    decls = Tuple{SyntaxNode,Symbol,Union{Nothing,SyntaxNode}}[]
    sig = cs[1]
    while kind(sig) === K"where" && !JuliaSyntax.is_leaf(sig)
        wcs = children(sig)
        isempty(wcs) && return nothing
        layer = _utp_typevar_decls(wcs[2:end])
        layer === nothing && return nothing
        append!(decls, layer)
        sig = wcs[1]
    end

    # Strip a return-type annotation; what remains must be the signature call.
    while kind(sig) === K"::" && !JuliaSyntax.is_leaf(sig) && length(children(sig)) == 2
        sig = children(sig)[1]
    end
    kind(sig) === K"call" && !JuliaSyntax.is_leaf(sig) || return nothing

    slots = _utp_argument_types(sig)

    for (i, (decl_node, name, _)) in enumerate(decls)
        # Never mentioned again at all: `unused_type_parameter`'s finding.
        _utp_occurs_besides(name, node, decl_node) || continue

        unknown = Ref(false)
        bound = any(_utp_constrains(name, t, cov, unknown) for (t, cov) in slots)
        if !bound
            # A later (inner) parameter's upper bound binds this one
            # covariantly: `f(x::S) where {T, S<:AbstractVector{T}}`.
            bound = any(
                ub !== nothing && _utp_constrains(name, ub, true, unknown)
                for (_, _, ub) in decls[i+1:end]
            )
        end
        bound && continue
        unknown[] && continue
        emit!(_node_range(decl_node), "The type parameter `$name`" * _UNBOUND_TYPE_PARAMETER_MESSAGE_SUFFIX)
    end
    return nothing
end

const UNBOUND_TYPE_PARAMETER_CHECK =
    SyntaxCheck(:unbound_type_parameter, (K"function",), _check_unbound_type_parameter)
