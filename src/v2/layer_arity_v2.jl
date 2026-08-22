# Layer 2¾ of the v2 stack: method arities — the argument-count shape of every
# workspace-declared callable, per item and funnelled per (module path, name).
#
# The v1 counterparts are `func_nargs(::EXPR)`/`struct_nargs` (StaticLint
# checks.jl) and the `derived_method_items`/`derived_method_arities_index`
# projections (layer_module_tree.jl). This file is their PORT into BodyTree
# vocabulary, not a call into them; the `MethodArity` struct itself is reused
# (it is engine-neutral plain data — four integers/symbol-vectors — and moves
# here when v1 is deleted).
#
# Everything here is position-free: arities are pure functions of an item's
# `BodyTree` (plus its macro-wrapper names), so every query backdates. Serves
# both the call-args lint takeover and the signature-help feature.

# ── the func_nargs(::EXPR) port ─────────────────────────────────────────────

"Permissive-anything: accepts every positional count and every keyword."
_v2_any_arity() = MethodArity(0, typemax(Int), Symbol[], true)

# Does this type expression name `Vararg`, bare or dotted (`Base.Vararg`)?
function _v2_names_vararg(bt::BodyTree)
    _, n = _v2_qualified_name(bt)
    return n == "Vararg"
end

# The type expression of an argument declaration: `x::T` is a binary `::`
# (type at child 2), the anonymous `::T` is UNARY (type at child 1) — reading
# only the binary form would silently treat `f(::Vararg{Int})` as one ordinary
# positional (v1's `arg_decl_type` comment).
function _v2_arg_decl_type(bt::BodyTree)
    bt.kind == JS2.K"::" || return nothing
    n = _v2_nchildren(bt)
    n == 2 && return _v2_children(bt)[2]
    n == 1 && return _v2_children(bt)[1]
    return nothing
end

"Is this argument an explicit `::Vararg{…}` declaration (bound or anonymous)?"
function _v2_is_explicit_vararg_decl(bt::BodyTree)
    t = _v2_arg_decl_type(bt)
    t === nothing && return false
    _v2_names_vararg(t) && return true
    t.kind == JS2.K"curly" && _v2_nchildren(t) >= 1 &&
        _v2_names_vararg(_v2_children(t)[1]) && return true
    return false
end

# `x::Vararg{T,N}` with a literal integer N consumes exactly N arguments;
# every other Vararg form allows any count. EST integer literals carry their
# parsed value (an `Integer`), unlike CSTParser's string.
function _v2_bounded_vararg_N(bt::BodyTree)
    t = _v2_arg_decl_type(bt)
    t === nothing && return nothing
    t.kind == JS2.K"curly" || return nothing
    cs = _v2_children(t)
    length(cs) == 3 || return nothing
    _v2_names_vararg(cs[1]) || return nothing
    v = cs[3].children === nothing ? cs[3].val : nothing
    v isa Integer || return nothing
    return Int(v)
end

# `@nospecialize(x)` wraps the argument in a macrocall; the real argument is
# macrocall child 3 (after the name and the LineNumberNode).
function _v2_unwrap_nospecialize(bt::BodyTree)
    bt.kind == JS2.K"macrocall" || return bt
    _v2_macrocall_name(bt) == "@nospecialize" || return bt
    _v2_nchildren(bt) >= 3 || return bt
    return _v2_children(bt)[3]
end

# The bound name of a signature/parameters entry, through `kw` defaults,
# binary `::` declarations and splats. `nothing` for anonymous arguments.
function _v2_arity_arg_name(bt::BodyTree)
    node = bt
    while true
        k = node.kind
        if k == JS2.K"kw" && _v2_nchildren(node) >= 1
            node = _v2_children(node)[1]
        elseif k == JS2.K"::" && _v2_nchildren(node) == 2
            node = _v2_children(node)[1]
        elseif k == JS2.K"..." && _v2_nchildren(node) >= 1
            node = _v2_children(node)[1]
        else
            return _v2_leaf_string(node)
        end
    end
end

"""
    _v2_func_sig(bt) -> Union{Nothing,BodyTree}

The `K"call"` signature node of a method-defining item: child 1 of a
`function`/`macro`/short-form `=`, unwrapped through `where` clauses and the
return-type `::` (binary, with a call/where first child — the shape that
distinguishes it from a typed assignment `x::Int = 1`). `nothing` when the item
defines no method with a signature — notably `function f end`, whose child is a
bare identifier (the zero-method declaration).
"""
function _v2_func_sig(bt::BodyTree)
    (bt.kind == JS2.K"function" || bt.kind == JS2.K"macro" || bt.kind == JS2.K"=") ||
        return nothing
    _v2_nchildren(bt) >= 1 || return nothing
    node = _v2_children(bt)[1]
    while true
        if node.kind == JS2.K"where" && _v2_nchildren(node) >= 1
            node = _v2_children(node)[1]
        elseif node.kind == JS2.K"::" && _v2_nchildren(node) == 2 &&
               (_v2_children(node)[1].kind == JS2.K"call" ||
                _v2_children(node)[1].kind == JS2.K"where")
            node = _v2_children(node)[1]
        else
            break
        end
    end
    return node.kind == JS2.K"call" ? node : nothing
end

# Wrapped by a macro that may rewrite the signature? The doc wrapper never
# reaches `wrappers` (the walker's doc branch is transparent), so this is
# exactly v1's rule: permissive unless every wrapper is signature-preserving.
_v2_wrappers_permissive(wrappers::Vector{String}) =
    !isempty(wrappers) && any(w -> !(w in V2_SIGNATURE_PRESERVING_MACROS), wrappers)

"""
    _v2_func_nargs(call, wrappers) -> MethodArity

The `func_nargs(::EXPR)` port: count `call`'s signature entries into
`(minargs, maxargs, kws, kwsplat)`. Child 1 is the callee (skipped — for a
callable-object signature `(io::IO)(x)` that skips the object, as v1 does);
a `parameters` child holds the keywords; a `kw` positional widens the max
only; splats and explicit `Vararg` declarations unbound the max unless the
Vararg carries a literal N.
"""
function _v2_func_nargs(call::BodyTree, wrappers::Vector{String})
    _v2_wrappers_permissive(wrappers) && return _v2_any_arity()

    minargs, maxargs, kws, kwsplat = 0, 0, Symbol[], false
    cs = _v2_children(call)
    for i in 2:length(cs)
        arg = _v2_unwrap_nospecialize(cs[i])
        if arg.kind == JS2.K"parameters"
            for p in _v2_children(arg)
                if p.kind == JS2.K"..."
                    kwsplat = true
                else
                    n = _v2_arity_arg_name(p)
                    n !== nothing && push!(kws, Symbol(n))
                end
            end
        elseif arg.kind == JS2.K"kw"
            inner = _v2_nchildren(arg) >= 1 ? _v2_children(arg)[1] : arg
            if inner.kind == JS2.K"..."
                maxargs = typemax(Int)
            else
                maxargs !== typemax(Int) && (maxargs += 1)
            end
        elseif arg.kind == JS2.K"..."
            maxargs = typemax(Int)
        elseif _v2_is_explicit_vararg_decl(arg)
            bn = _v2_bounded_vararg_N(arg)
            if bn !== nothing
                minargs += bn
                maxargs !== typemax(Int) && (maxargs += bn)
            else
                maxargs = typemax(Int)
            end
        else
            minargs += 1
            maxargs !== typemax(Int) && (maxargs += 1)
        end
    end
    return MethodArity(minargs, maxargs, kws, kwsplat)
end

"""
    _v2_struct_nargs(bt, wrappers) -> MethodArity

The `struct_nargs` port. A macro-wrapped struct likely gains arbitrary
constructors — permissive. Inner constructors are alternative methods, so the
struct's arity is their union (a single range can't express a gap, which errs
towards accepting a call, never a false positive). Otherwise the default
constructor takes exactly the field count — a field docstring is a bare string
child and not a field. An empty body answers `(0, typemax)` like v1.
"""
function _v2_struct_nargs(bt::BodyTree, wrappers::Vector{String})
    !isempty(wrappers) && return _v2_any_arity()
    cs = _v2_children(bt)
    length(cs) >= 3 || return MethodArity(0, typemax(Int), Symbol[], false)
    fields = _v2_children(cs[3])
    isempty(fields) && return MethodArity(0, typemax(Int), Symbol[], false)

    ctor_sigs = BodyTree{V2Kind}[]
    any_ctor = false
    for f in fields
        sig = _v2_func_sig(f)
        if sig !== nothing
            any_ctor = true
            push!(ctor_sigs, sig)
        elseif f.kind == JS2.K"function" || f.kind == JS2.K"macro"
            any_ctor = true    # `function S end`-shaped: a ctor with no signature
        end
    end

    if any_ctor
        isempty(ctor_sigs) && return _v2_any_arity()
        minargs, maxargs, kws, kwsplat = typemax(Int), 0, Symbol[], false
        for sig in ctor_sigs
            a = _v2_func_nargs(sig, _V2_NO_WRAPPERS)
            minargs = min(minargs, a.minargs)
            maxargs = max(maxargs, a.maxargs)
            union!(kws, a.kws)
            kwsplat |= a.kwsplat
        end
        return MethodArity(minargs, maxargs, kws, kwsplat)
    end

    nfields = count(f -> !(f.kind == JS2.K"String" || f.kind == JS2.K"string"), fields)
    nfields == 0 && return MethodArity(0, typemax(Int), Symbol[], false)
    return MethodArity(nfields, nfields, Symbol[], false)
end

"""
    derived_v2_item_arity(rt, ref) -> Union{Nothing,MethodArity}

The argument-count shape of one item's method/constructor, or `nothing` when
the item carries none — non-callables, and `function f end` (a method ITEM with
no method, which is exactly how the arity index distinguishes "declared with
zero methods" from "not a callable"). A pure function of the item's `BodyTree`
plus its macro-wrapper names, so it backdates per item; NOT a `V2Decl` field on
purpose — classification hashes stay stable across signature-detail edits.
"""
Salsa.@derived function derived_v2_item_arity(rt, ref::V2ItemRef)
    body = derived_v2_item_body(rt, ref)
    body === nothing && return nothing
    wrappers = derived_v2_item_macro_wrappers(rt, ref)
    return try
        k = body.kind
        if k == JS2.K"struct"
            _v2_struct_nargs(body, wrappers)
        elseif k == JS2.K"function" || k == JS2.K"="
            sig = _v2_func_sig(body)
            sig === nothing ? nothing : _v2_func_nargs(sig, wrappers)
        else
            nothing
        end
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
end

# ── the spliced item walk ───────────────────────────────────────────────────

# Item kinds whose declarations carry a method set the call-args check can
# reason about. Abstract/primitive types are deliberately absent: v1 gives them
# no arity, so a call to such a constructor declines rather than reporting
# "no methods".
const _V2_METHOD_ITEM_KINDS = (:function, :struct, :mutable_struct)

# Resolve a method-extension qualifier written at absolute module location
# `loc` to the absolute tree path it denotes, or `nothing` when it names no
# module of this tree. The port of v1's `_resolve_extension_qualifier`
# (layer_module_tree.jl): step outward from `loc`, anchor at the first
# enclosing prefix `M` for which `vcat(M, [qual[1]])` is a tree module, then
# require every remaining segment to resolve. A `Base.foo` qualifier never
# anchors, so a `Base.foo` extension belongs to NO tree path — which keeps it
# out of every workspace module's method set.
function _v2_resolve_extension_qualifier(modpaths::Set{Vector{String}}, loc::Vector{String},
                                         qual::Vector{String})
    isempty(qual) && return nothing
    M = copy(loc)
    while true
        if vcat(M, [qual[1]]) in modpaths
            resolved = copy(M)
            for seg in qual
                push!(resolved, seg)
                resolved in modpaths || return nothing
            end
            return resolved
        end
        isempty(M) && break
        pop!(M)
    end
    return nothing
end

# Depth-first splice walk mirroring `_v2_build_tree_structure`'s file/include
# interleaving: `emit(F, item, loc)` for every classified item — qualified
# extensions INCLUDED, which is precisely what the tree's own event stream
# filters out — in true splice order, `loc` the item's absolute module path.
# Include admission matches the tree exactly (first include wins, cycles
# terminate, `visited` seeded with the root).
function _v2_walk_spliced_items!(emit, rt, F::URI, P::Vector{String}, visited::Set{URI})
    inv = derived_v2_file_inventory(rt, F)
    events = Tuple{Int,Symbol,Any}[]
    for item in inv.items
        push!(events, (item.order, :item, item))
    end
    for inc in inv.includes
        push!(events, (inc.order, :include, inc))
    end
    # Include-first on an order tie (`const DATA = include("data.jl")`), the
    # tree's rule.
    sort!(events; by=e -> (e[1], e[2] === :include ? 0 : 1), alg=Base.Sort.MergeSort)

    for (_, kind, payload) in events
        if kind === :item
            item = payload
            emit(F, item, vcat(P, item.parent_module))
        else
            inc = payload
            target = derived_v2_include_target(rt, F, inc.path)
            target === nothing && continue
            target in visited && continue
            derived_has_content(rt, target) || continue
            push!(visited, target)
            _v2_walk_spliced_items!(emit, rt, target, vcat(P, inc.parent_module), visited)
        end
    end
    return
end

# ── the per-root projections ────────────────────────────────────────────────

"""
    derived_v2_method_items(rt, root, path, name) -> Vector{V2ItemRef}

Every item that declares or extends the callable `name` in the module at `path`
of `root`'s tree, in splice order: the unqualified method-kind declarations
whose module is `path`, plus every qualified extension (`Mod.name(...)`) whose
qualifier resolves to `path`. The v2 mirror of v1's `derived_method_items`.
Empty when `path` names no module or `name` no callable — `function f end` IS
an item here (the zero-method signal), it just contributes no arity.
"""
Salsa.@derived function derived_v2_method_items(rt, root, path, name)
    tree = derived_v2_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    result = V2ItemRef[]
    path in modpaths || return result

    _v2_walk_spliced_items!(rt, root, String[], Set{URI}([root])) do F, item, loc
        item.name == name || return
        item.kind in _V2_METHOD_ITEM_KINDS || return
        resolved = isempty(item.qualifier) ? loc :
            _v2_resolve_extension_qualifier(modpaths, loc, item.qualifier)
        resolved == path && push!(result, V2ItemRef(F, item.id))
    end
    return result
end

"""
    derived_v2_method_arities_index(rt, root)
        -> Dict{Tuple{Vector{String},String},Vector{MethodArity}}

Every `(module path, name) => arities` entry of `root`'s tree, from ONE splice
walk — the same funnel design as v1's `derived_method_arities_index` (per-name
queries would each depend on every file; the funnel makes them a lookup and
keeps early cutoff).

An entry EXISTS for every method-kind declaration, even one with no arity: a
lone `function f end` yields `("…","f") => []`, which is what lets the
call-args rule distinguish "declared with zero methods" (an empty vector) from
"not declared as a callable here" (no key).
"""
Salsa.@derived function derived_v2_method_arities_index(rt, root)
    @debug "derived_v2_method_arities_index" root=root

    tree = derived_v2_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    result = Dict{Tuple{Vector{String},String},Vector{MethodArity}}()

    _v2_walk_spliced_items!(rt, root, String[], Set{URI}([root])) do F, item, loc
        item.kind in _V2_METHOD_ITEM_KINDS || return
        resolved = isempty(item.qualifier) ? loc :
            _v2_resolve_extension_qualifier(modpaths, loc, item.qualifier)
        (resolved === nothing || !(resolved in modpaths)) && return
        entry = get!(() -> MethodArity[], result, (resolved, item.name))
        a = derived_v2_item_arity(rt, V2ItemRef(F, item.id))
        a !== nothing && push!(entry, a)
    end
    return result
end

"""
    derived_v2_method_arities(rt, root, path, name) -> Union{Nothing,Vector{MethodArity}}

The method arities of `name` at module `path`: a lookup into the funnel.
`nothing` when the name is not declared as a callable there (callers decline);
an EMPTY vector when it is declared but has no methods (`function f end` — the
`function_has_no_methods` signal).
"""
Salsa.@derived function derived_v2_method_arities(rt, root, path, name)
    return get(derived_v2_method_arities_index(rt, root), (path, name), nothing)
end
