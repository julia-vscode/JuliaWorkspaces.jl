function settype!(b::Binding, type::Binding)
    push!(type.refs, b)
    b.type = type
end

function settype!(b::Binding, type)
    b.type = type
end

# `(a, b, …)::Tuple{T1, T2, …}` (a typed positional destructure, e.g. a function
# arg `(file, line)::Tuple{AbstractString, Any}`): each element must take its
# POSITIONAL parameter type, not the whole tuple type. Without this, every
# element was assigned `Tuple{...}` itself. Returns true when it set a type;
# falls back (returns false) for anything not a plain positional `Tuple{...}`
# match — `Vararg`/`NTuple` params, an out-of-range index, or a non-identifier
# element (e.g. a nested tuple) — leaving the caller's normal path to run.
function _infer_tuple_decl_element!(binding, lhs, ann, state, scope)
    (iscurly(ann) && isidentifier(ann.args[1]) && valofid(ann.args[1]) == "Tuple") || return false
    name = binding.name
    isidentifier(name) || return false
    nm = valofid(name)
    idx = findfirst(a -> isidentifier(a) && valofid(a) == nm, lhs.args)
    idx === nothing && return false
    # curly args are [Tuple, T1, T2, …], so the i-th element's param is ann.args[i+1]
    pidx = idx + 1
    pidx <= length(ann.args) || return false
    t = ann.args[pidx]
    # a `Vararg{…}` param spans a variable number of elements — can't map by position
    (iscurly(t) && isidentifier(t.args[1]) && valofid(t.args[1]) == "Vararg") && return false
    infer_type_decl(binding, t, state, scope)
    return true
end

function infer_type(binding::Binding, scope, state)
    if binding isa Binding
        binding.type !== nothing && return
        if binding.val isa EXPR && CSTParser.defines_module(binding.val)
            settype!(binding, CoreTypes.Module)
        elseif binding.val isa EXPR && CSTParser.defines_function(binding.val)
            settype!(binding, CoreTypes.Function)
        elseif binding.val isa EXPR && CSTParser.defines_datatype(binding.val)
            settype!(binding, CoreTypes.DataType)
        elseif binding.val isa EXPR
            if isassignment(binding.val)
                if CSTParser.is_func_call(binding.val.args[1])
                    settype!(binding, CoreTypes.Function)
                else
                    lhs = binding.val.args[1]
                    if lhs.head isa EXPR && valof(lhs.head) == "::"
                        infer_type_decl(binding, lhs.args[2], state, scope)
                    else
                        infer_type_assignment_rhs(binding, state, scope)
                    end
                end
            elseif binding.val.head isa EXPR && valof(binding.val.head) == "::"
                lhs = binding.val.args[1]
                if CSTParser.istuple(lhs) && _infer_tuple_decl_element!(binding, lhs, binding.val.args[2], state, scope)
                    # `(a, b, …)::Tuple{T1, T2, …}` positional destructure handled below
                else
                    infer_type_decl(binding, state, scope)
                end
            elseif CSTParser.issplat(binding.val) && length(binding.val.args) >= 1 &&
                   binding.val.args[1].head isa EXPR && valof(binding.val.args[1].head) == "::"
                infer_type_decl(binding, binding.val.args[1].args[2], state, scope)
            elseif iswhere(parentof(binding.val))
                settype!(binding, CoreTypes.DataType)
            end
        end
    end
end

# Resolve a datatype-denoting external `TreeRef` to its `SymStore` via the env.
# In the per-file traversal mode a `using`'d name from a sibling file (e.g.
# `using Base: PkgId`) resolves through the module tree to a `TreeRef`, not to a
# local `Binding`/store. Walk `getsymbols(env)` by `origin_module` to the
# `ModuleStore`, then look up `name` (following a `VarRef`). Mirrors hover's
# external-symbol resolution (`_get_tree_ref_hover`) but stays inside StaticLint.
# Returns the store (ideally a `DataTypeStore`) or `nothing`.
function resolve_treeref_store(tr::TreeRef, state)
    tr.kind === :external_symbol || return nothing
    isempty(tr.origin_module) && return nothing
    store = get(getsymbols(state), Symbol(tr.origin_module[1]), nothing)
    store isa SymbolServer.ModuleStore || return nothing
    for i in 2:length(tr.origin_module)
        sub = maybe_lookup(get(store.vals, Symbol(tr.origin_module[i]), nothing), state)
        sub isa SymbolServer.ModuleStore || return nothing
        store = sub
    end
    val = get(store.vals, Symbol(tr.name), nothing)
    val === nothing && return nothing
    return maybe_lookup(val, state)
end

# The datatype constructed by a constructor-style call's callee (`x = T(...)`),
# for type inference — a datatype `Binding`, a `DataTypeStore`, or `nothing`.
# Handles a bare identifier callee, a qualified getfield callee (`Base.PkgId`),
# and a cross-file `TreeRef` callee (resolved through the env).
function _resolve_constructor_datatype(callname, scope, state)
    meta_dict = state.meta_dict
    if isidentifier(callname)
        resolve_ref(callname, scope, state)
        hasref(callname, meta_dict) || return nothing
        ref = refof(callname, meta_dict)
    elseif is_getfield_w_quotenode(callname)
        resolve_getfield(callname, scope, state)
        ref = refof_maybe_getfield(callname, meta_dict)
    else
        return nothing
    end
    if ref isa TreeRef
        ref = resolve_treeref_store(ref, state)
    end
    rb = get_root_method(ref)
    if (rb isa Binding && (CoreTypes.isdatatype(rb.type) || rb.val isa SymbolServer.DataTypeStore)) || rb isa SymbolServer.DataTypeStore
        return rb
    end
    return nothing
end

function infer_type_assignment_rhs(binding, state, scope)
    meta_dict = state.meta_dict
    lhs = binding.val.args[1]
    rhs = binding.val.args[2]

    is_destructuring = CSTParser.istuple(lhs) && !isempty(lhs.args) && CSTParser.isparameters(lhs.args[1])
    if is_loop_iter_assignment(binding.val)
        settype!(binding, infer_eltype(rhs, state))
    elseif headof(rhs) === :ref && length(rhs.args) > 1 && all(a -> _is_scalar_index(a, state, scope), @view rhs.args[2:end])
        # Only infer the element type when every index is provably scalar
        # (integer literal / `begin`/`end` / `Number`-typed ref). A slice or
        # otherwise non-scalar index yields an array, not an element (#449).
        ref = refof_maybe_getfield(rhs.args[1], meta_dict)
        if ref isa Binding && ref.val isa EXPR
            settype!(binding, infer_eltype(ref.val, state))
        end
    elseif CSTParser.isdeclaration(rhs) && length(rhs.args) == 2 && !is_destructuring
        # RHS is a type assertion (`y = x::T`, `x = x::T`): the assigned binding
        # takes the asserted type, the same way a `::T` parameter declaration
        # does. This lets field completion narrow through a local assertion.
        infer_type_decl(binding, rhs.args[2], state, scope)
    else
        if CSTParser.is_func_call(rhs)
            if CSTParser.istuple(lhs) && !is_destructuring
                return
            end
            callname = CSTParser.get_name(rhs)
            rb = _resolve_constructor_datatype(callname, scope, state)
            if rb !== nothing
                if is_destructuring
                    infer_destructuring_type(binding, rb, meta_dict)
                else
                    settype!(binding, rb)
                end
            end
        elseif CSTParser.iscurly(rhs) || CSTParser.iswhere(rhs)
            # `const Alias = SomeType{...}` aliases a parameterized type, possibly
            # behind `where` clauses (e.g. `const Alias = SomeType{T} where T`).
            # The alias is itself a type, so adding methods to it is valid. Peel
            # any `where`/declaration wrappers to get at the underlying `curly`.
            unwrapped = CSTParser.rem_wheres_decls(rhs)
            if CSTParser.iscurly(unwrapped)
                callname = CSTParser.get_name(unwrapped)
                if isidentifier(callname)
                    resolve_ref(callname, scope, state)
                    if hasref(callname, meta_dict)
                        rb = get_root_method(refof(callname, meta_dict))
                        if (rb isa Binding && (CoreTypes.isdatatype(rb.type) || rb.val isa SymbolServer.DataTypeStore)) || rb isa SymbolServer.DataTypeStore
                            settype!(binding, CoreTypes.DataType)
                        end
                    end
                end
            end
        elseif (literal_type = infer_literal_type(rhs)) !== nothing
            settype!(binding, literal_type)
        elseif isidentifier(rhs) || is_getfield_w_quotenode(rhs)
            refof_rhs = isidentifier(rhs) ? refof(rhs, meta_dict) : refof_maybe_getfield(rhs, meta_dict)
            if is_destructuring
                # property destructuring `(; field) = obj`: infer the field's
                # declared type from `obj`'s type rather than `obj`'s type itself.
                if refof_rhs isa Binding
                    infer_destructuring_type(binding, refof_rhs.type, meta_dict)
                else
                    infer_destructuring_type(binding, refof_rhs, meta_dict)
                end
            elseif refof_rhs isa Binding
                if refof_rhs.val isa SymbolServer.GenericStore && refof_rhs.val.typ isa SymbolServer.FakeTypeName
                    settype!(binding, maybe_lookup(refof_rhs.val.typ.name, state))
                elseif refof_rhs.val isa SymbolServer.FunctionStore
                    settype!(binding, CoreTypes.Function)
                elseif refof_rhs.val isa SymbolServer.DataTypeStore
                    settype!(binding, CoreTypes.DataType)
                else
                    settype!(binding, refof_rhs.type)
                end
            elseif refof_rhs isa SymbolServer.GenericStore && refof_rhs.typ isa SymbolServer.FakeTypeName
                settype!(binding, maybe_lookup(refof_rhs.typ.name, state))
            elseif refof_rhs isa SymbolServer.FunctionStore
                settype!(binding, CoreTypes.Function)
            elseif refof_rhs isa SymbolServer.DataTypeStore
                settype!(binding, CoreTypes.DataType)
            end
        end
    end
end

const MAX_DESTRUCTURE_INFER_DEPTH = 20
function infer_destructuring_type(binding, rb::SymbolServer.DataTypeStore, meta_dict, depth=0)
    assigned_name = CSTParser.get_name(binding.val)
    for (fieldname, fieldtype) in zip(rb.fieldnames, rb.types)
        if fieldname == assigned_name
            settype!(binding, fieldtype)
            return
        end
    end
end
function infer_destructuring_type(binding::Binding, rb::EXPR, meta_dict, depth=0)
    scope = scopeof(rb, meta_dict)
    if scope === nothing
        # `const FOO = Foo` — follow the alias's RHS to the real constructor.
        if depth < MAX_DESTRUCTURE_INFER_DEPTH && isassignment(rb) && !CSTParser.defines_datatype(rb)
            infer_destructuring_type(binding, refof_maybe_getfield(rb.args[2], meta_dict), meta_dict, depth + 1)
        end
        return
    end
    assigned_name = string(to_codeobject(binding.name))
    names = scope.names
    if haskey(names, assigned_name)
        b = names[assigned_name]
        settype!(binding, b.type)
    end
end
function infer_destructuring_type(binding, rb::Binding, meta_dict, depth=0)
    depth >= MAX_DESTRUCTURE_INFER_DEPTH && return
    return infer_destructuring_type(binding, rb.val, meta_dict, depth + 1)
end
# An alias may resolve to something carrying no field information (or `nothing`).
infer_destructuring_type(binding, rb, meta_dict, depth=0) = nothing

# Shared tail of both `infer_type_decl` forms: `t` is the (unwrapped, resolved)
# type expression of a `::T` declaration. A cross-file `TreeRef` annotation
# (e.g. a sibling `using Base: PkgId`) is resolved through the env — since
# `Binding.type` can't carry a TreeRef, the resolved `DataTypeStore` is set (and
# if it doesn't resolve, the type is left unset for `declared_type_is_tree_backed`
# to protect from by-use guessing).
function _settype_from_decl!(binding, t, state)
    meta_dict = state.meta_dict
    r = refof(t, meta_dict)
    if r isa TreeRef
        store = resolve_treeref_store(r, state)
        store isa SymbolServer.DataTypeStore && settype!(binding, store)
    elseif r isa Binding
        rb = get_root_method(r)
        if rb isa Binding && CoreTypes.isdatatype(rb.type)
            settype!(binding, rb)
        else
            settype!(binding, r)
        end
    else
        edt = get_eventual_datatype(r, state.env)
        if edt !== nothing
            settype!(binding, edt)
        end
    end
end

function infer_type_decl(binding, state, scope)
    t = binding.val.args[2]
    if isidentifier(t)
        resolve_ref(t, scope, state)
    end
    if iscurly(t)
        t = t.args[1]
        resolve_ref(t, scope, state)
    end
    if CSTParser.is_getfield_w_quotenode(t)
        resolve_getfield(t, scope, state)
        t = t.args[2].args[1]
    end
    _settype_from_decl!(binding, t, state)
end

function infer_type_decl(binding, t, state, scope)
    if isidentifier(t)
        resolve_ref(t, scope, state)
    end
    if iscurly(t)
        t = t.args[1]
        resolve_ref(t, scope, state)
    end
    if CSTParser.is_getfield_w_quotenode(t)
        resolve_getfield(t, scope, state)
        t = t.args[2].args[1]
    end
    _settype_from_decl!(binding, t, state)
end

get_eventual_datatype(_, _::ExternalEnv) = nothing
get_eventual_datatype(b::SymbolServer.DataTypeStore, _::ExternalEnv) = b
function get_eventual_datatype(b::SymbolServer.FunctionStore, env::ExternalEnv)
    return SymbolServer._lookup(b.extends, getsymbols(env))
end

# Per-file traversal mode only: does `b`'s declaration carry an explicit `::`
# type annotation that resolved through the module tree (a `TreeRef`)? The
# legacy `Binding.type` slot can't carry a TreeRef, so `infer_type_decl`
# leaves the type as `nothing` — but the type IS declared and known, so
# by-use inference must not override it with a guess (it inferred e.g.
# `Core.DebugInfo` for a `framecode::FrameCode` argument and then flagged the
# struct's real fields as missing references). Mirrors the annotation
# unwrapping in `infer_type_decl` (curly / getfield forms).
function declared_type_is_tree_backed(b::Binding, meta_dict)
    v = b.val
    v isa EXPR || return false
    t = if v.head isa EXPR && valof(v.head) == "::" && v.args !== nothing && length(v.args) == 2
        v.args[2]
    elseif isassignment(v) && v.args[1].head isa EXPR && valof(v.args[1].head) == "::" &&
           v.args[1].args !== nothing && length(v.args[1].args) == 2
        v.args[1].args[2]
    elseif CSTParser.issplat(v) && v.args !== nothing && length(v.args) >= 1 &&
           v.args[1].head isa EXPR && valof(v.args[1].head) == "::" &&
           v.args[1].args !== nothing && length(v.args[1].args) == 2
        v.args[1].args[2]
    else
        return false
    end
    if iscurly(t) && t.args !== nothing && length(t.args) >= 1
        t = t.args[1]
    end
    if CSTParser.is_getfield_w_quotenode(t)
        t = t.args[2].args[1]
    end
    return refof(t, meta_dict) isa TreeRef
end

# Work out what type a bound variable has by functions that are called on it.
function infer_type_by_use(b::Binding, env::ExternalEnv, meta_dict)
    b.type !== nothing && return # b already has a type
    declared_type_is_tree_backed(b, meta_dict) && return # declared type is known, just not carriable — never guess over it
    possibletypes = []
    visitedmethods = []
    ifbranch = nothing
    for ref in b.refs
        new_possibles = []
        ref isa EXPR || continue # skip non-EXPR (i.e. used for handling of globals)
        # Some simple handling for :if blocks
        if ifbranch === nothing
            ifbranch = find_if_parents(ref)
        else
            newbranch = find_if_parents(ref)
            if !in_same_if_branch(ifbranch, newbranch)
                return
            end
            ifbranch = newbranch
        end
        check_ref_against_calls(ref, visitedmethods, new_possibles, env, meta_dict)
        if !isempty(new_possibles)
            if isempty(possibletypes)
                possibletypes = new_possibles
            else
                possibletypes = intersect(possibletypes, new_possibles)
            end
            if isempty(possibletypes)
                return
            end
        end
    end
    # Only do something if we're left with a singleton set at the end.
    if length(possibletypes) == 1
        type = first(possibletypes)
        if type isa Binding
            settype!(b, type)
        elseif type isa SymbolServer.DataTypeStore
            settype!(b, type)
        elseif type isa SymbolServer.VarRef
            settype!(b, SymbolServer._lookup(type, getsymbols(env))) # could be nothing
        elseif type isa SymbolServer.FakeTypeName && isempty(type.parameters)
            settype!(b, SymbolServer._lookup(type.name, getsymbols(env))) # could be nothing
        end
    end
end

function check_ref_against_calls(x, visitedmethods, new_possibles, env::ExternalEnv, meta_dict)
    if is_arg_of_resolved_call(x, meta_dict) && !call_is_func_sig(x.parent)
        sig = parentof(x)
        # x is argument of function call (func) and we know what that function is
        if CSTParser.isidentifier(sig.args[1])
            func = refof(sig.args[1], meta_dict)
        else
            func = refof(sig.args[1].args[2].args[1], meta_dict)
        end
        argi = get_arg_position_in_call(sig, x) # what slot does ref sit in?
        tls = retrieve_toplevel_scope(x, meta_dict)
        if func isa Binding
            for method in func.refs
                method = get_method(method)
                method === nothing && continue
                if method isa EXPR
                    if defines_function(method)
                        get_arg_type_at_position(method, argi, new_possibles, meta_dict)
                    # elseif CSTParser.defines_struct(method)
                        # Can we ignore this? Default constructor gives us no type info?
                    end
                else # elseif what?
                    iterate_over_ss_methods(method, tls, env, m -> (get_arg_type_at_position(m, argi, new_possibles, meta_dict);false))
                end
            end
        else
            iterate_over_ss_methods(func, tls, env, m -> (get_arg_type_at_position(m, argi, new_possibles, meta_dict);false))
        end
    end
end

function call_is_func_sig(call::EXPR)
    # assume initially called on a :call
    if call.parent isa EXPR
        if call.parent.head === :function || CSTParser.is_eq(call.parent.head)
            true
        elseif isdeclaration(call.parent) || iswhere(call.parent)
            call_is_func_sig(call.parent)
        else
            false
        end
    else
        false
    end
end

function is_arg_of_resolved_call(x::EXPR, meta_dict)
    parentof(x) isa EXPR && headof(parentof(x)) === :call && # check we're in a call signature
    (caller = parentof(x).args[1]) !== x && # and that x is not the caller
    ((CSTParser.isidentifier(caller) && hasref(caller, meta_dict)) || (is_getfield(caller) && headof(caller.args[2]) === :quotenode && hasref(caller.args[2].args[1], meta_dict)))
end

function get_arg_position_in_call(sig::EXPR, arg)
    for i in 1:length(sig.args)
        sig.args[i] == arg && return i
    end
end

function get_arg_type_at_position(method, argi, types, meta_dict)
    if method isa EXPR
        sig = CSTParser.get_sig(method)
        if sig !== nothing &&
            sig.args !== nothing && argi <= length(sig.args) &&
            hasbinding(sig.args[argi], meta_dict) &&
            (argb = bindingof(sig.args[argi], meta_dict); argb isa Binding && argb.type !== nothing) &&
            !(argb.type in types)
            push!(types, argb.type)
            return
        end
    elseif method isa SymbolServer.DataTypeStore || method isa SymbolServer.FunctionStore
        for m in method.methods
            get_arg_type_at_position(m, argi, types, meta_dict)
        end
    end
    return
end

function get_arg_type_at_position(m::SymbolServer.MethodStore, argi, types, meta_dict)
    argi -= 1
    if !(0 < argi < length(m.sig))
        return
    end
    if m.sig[argi][2] != SymbolServer.VarRef(SymbolServer.VarRef(nothing, :Core), :Any) && !(m.sig[argi][2] in types)
        push!(types, m.sig[argi][2])
    end
end

# Assumes x.head.val == "="
# Is `x` (an assignment) a loop's *iteration spec* (e.g. the `i = 1:n` in
# `for i in 1:n`), as opposed to an ordinary assignment in the loop body?
# A single iterator is a direct child of the `:for`/`:generator`. Multiple
# iterators (`for i in a, j in b`) are grouped in a block, which for a `:for`
# is the FIRST arg (args[1]) — the second arg is the body block, whose
# assignments must NOT be treated as iteration specs. For a `:generator` the
# yielded expression is args[1] and iterators follow, so the spec block is any
# block that is not args[1].
function is_loop_iter_assignment(x::EXPR)
    p = parentof(x)
    p isa EXPR || return false
    (p.head === :for || p.head === :generator) && return true
    if p.head === :block && parentof(p) isa EXPR
        gp = parentof(p)
        gp.head === :for && return length(gp.args) >= 1 && gp.args[1] === p
        gp.head === :generator && return length(gp.args) >= 1 && gp.args[1] !== p
    end
    return false
end

_is_scalar_index(a, state, scope) = false
function _is_scalar_index(a::EXPR, state, scope)
    (headof(a) === :INTEGER || headof(a) === :END || headof(a) === :BEGIN) && return true
    meta_dict = state.meta_dict
    if isidentifier(a) || CSTParser.is_getfield_w_quotenode(a)
        # We may be inferring the assignment LHS before the index ref on the RHS
        # has been resolved / had its own type inferred (binding-pass ordering),
        # e.g. `for i in 1:n; x = v[i]`. Resolve + infer on demand (both are
        # idempotent) so a loop variable's scalar type is visible here.
        isidentifier(a) && !hasref(a, meta_dict) && resolve_ref(a, scope, state)
        r = isidentifier(a) ? refof(a, meta_dict) : refof_maybe_getfield(a, meta_dict)
        r isa Binding || return false
        r.type === nothing && infer_type(r, scope, state)
        r.type !== nothing || return false
        store = getsymbols(state.env)
        (haskey(store, :Core) && haskey(store[:Core], :Number)) || return false
        return _issubtype(r.type, store[:Core][:Number], store, meta_dict)
    end
    return false
end

# Type of a literal EXPR (as a CoreTypes store), or `nothing`.
function infer_literal_type(x::EXPR)
    h = headof(x)
    h === :INTEGER && return CoreTypes.Int
    if h === :HEXINT
        return if length(x.val) < 5
            CoreTypes.UInt8
        elseif length(x.val) < 7
            CoreTypes.UInt16
        elseif length(x.val) < 11
            CoreTypes.UInt32
        else
            CoreTypes.UInt64
        end
    end
    h === :FLOAT && return CoreTypes.Float64
    h === :CHAR && return CoreTypes.Char
    (h === :TRUE || h === :FALSE) && return CoreTypes.Bool
    CSTParser.isstringliteral(x) && return CoreTypes.String
    return nothing
end

# Best-effort scalar type of an expression used as a range bound: an
# Int/Float/Char literal, or a reference whose type is known. Bool/UInt/String
# literals are excluded — Julia promotes such range bounds, so the bound's own
# type is not the eltype. Returns `nothing` when unknown.
function _infer_scalar_type(x::EXPR, meta_dict)
    headof(x) === :INTEGER && return CoreTypes.Int
    headof(x) === :FLOAT && return CoreTypes.Float64
    headof(x) === :CHAR && return CoreTypes.Char
    if isidentifier(x) || CSTParser.is_getfield_w_quotenode(x)
        r = isidentifier(x) ? refof(x, meta_dict) : refof_maybe_getfield(x, meta_dict)
        r isa Binding && return r.type
    end
    return nothing
end
_infer_scalar_type(x, meta_dict) = nothing

# Is `t` (a type binding / DataTypeStore) a `Number`?
function _is_number(t, state)
    store = getsymbols(state.env)
    (haskey(store, :Core) && haskey(store[:Core], :Number)) || return false
    return _issubtype(t, store[:Core][:Number], store, state.meta_dict)
end

function infer_eltype(x::EXPR, state)
    meta_dict = state.meta_dict
    if isidentifier(x) && hasref(x, meta_dict) # assume is IDENT
        r = refof(x, meta_dict)
        if r isa Binding && r.val isa EXPR
            if isassignment(r.val) && r.val.args[2] != x
                return infer_eltype(r.val.args[2], state)
            end
        end
    elseif headof(x) === :ref && hasref(x.args[1], meta_dict)
        r = refof(x.args[1], meta_dict)
        if r isa Binding && CoreTypes.isdatatype(r.type)
            return r
        end
        edt = get_eventual_datatype(r, state.env)
        if edt isa SymbolServer.DataTypeStore
            return edt
        end
    elseif headof(x) === :STRING
        return CoreTypes.Char
    elseif headof(x) === :call && length(x.args) > 2 && CSTParser.is_colon(x.args[1])
        # number ranges are likely scalar
        t = _infer_scalar_type(x.args[2], state.meta_dict)
        if t !== nothing && all(3:length(x.args)) do i
                b = _infer_scalar_type(x.args[i], state.meta_dict)
                b !== nothing && (_type_compare(t, b) || (_is_number(t, state) && _is_number(b, state)))
            end
            return t
        end
    elseif hasbinding(x, meta_dict) && isdeclaration(x) && length(x.args) == 2
        return maybe_get_vec_eltype(x.args[2], state)
    end
end

function maybe_get_vec_eltype(t, state)
    meta_dict = state.meta_dict
    if iscurly(t)
        lhs_ref = refof_maybe_getfield(t.args[1], meta_dict)
        if lhs_ref isa SymbolServer.DataTypeStore && CoreTypes.isarray(lhs_ref) && length(t.args) > 1
            refof(t.args[2], meta_dict)
        end
    end
end
