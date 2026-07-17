function setref!(x::EXPR, binding::Binding, meta_dict)
    ensuremeta(x, meta_dict)
    getmeta(x, meta_dict).ref = binding
    push!(binding.refs, x)
end

function setref!(x::EXPR, binding::SymbolServer.SymStore, meta_dict)
    ensuremeta(x, meta_dict)
    getmeta(x, meta_dict).ref = binding
end

function setref!(x::EXPR, binding::Nothing, meta_dict)
    ensuremeta(x, meta_dict)
    getmeta(x, meta_dict).ref = nothing
end

# Per-file traversal mode: a name resolved through the module tree. Plain
# data — deliberately no `Binding.refs` push (the cross-file reference table
# is aggregated from these refs separately, not through shared mutation).
function setref!(x::EXPR, tr::TreeRef, meta_dict)
    ensuremeta(x, meta_dict)
    getmeta(x, meta_dict).ref = tr
end

# Main function to be called. Given the `state` tries to determine what `x`
# refers to. If it remains unresolved and is in a delayed evaluation scope
# (i.e. a function) it gets pushed to list (.urefs) to be resolved after we've
# run over the entire top-level scope.
function resolve_ref(x, state)
    if !(parentof(x) isa EXPR && headof(parentof(x)) === :quotenode)
        resolve_ref(x, state.scope, state)
    end
end

# In a delayed (function-body) pass a reference may legitimately point to a
# binding introduced textually *later* in an enclosing scope (a closure
# capturing an outer local defined below it). Collect any identifier that fails
# to resolve now so it can be retried against enclosing scopes once the whole
# scope has been traversed (see retry_urefs!).
function resolve_ref(x, state::Delayed)::Bool
    meta_dict = state.meta_dict
    if parentof(x) isa EXPR && headof(parentof(x)) === :quotenode
        return hasref(x, meta_dict)
    end
    resolved = resolve_ref(x, state.scope, state)
    if isidentifier(x) && !hasref(x, meta_dict) && !hasbinding(x, meta_dict)
        push!(state.urefs, x)
    end
    return resolved
end

# Retry references that failed to resolve during the initial Delayed traversal.
# Only consult STRICTLY enclosing scopes (parentof(sc) upward): bindings added
# later in the ref's own scope are use-before-assignment, not closure forward
# references, and we don't want to silently resolve those.
function retry_urefs!(state::Delayed)
    isempty(state.urefs) && return
    meta_dict = state.meta_dict
    s0 = state.scope
    remaining = EXPR[]
    try
        for x in state.urefs
            hasref(x, meta_dict) && continue
            sc = retrieve_scope(x, meta_dict)
            sc isa Scope || (push!(remaining, x); continue)
            psc = parentof(sc)
            if psc isa Scope
                state.scope = psc
                resolve_ref(x, psc, state)
            end
            hasref(x, meta_dict) || push!(remaining, x)
        end
    finally
        state.scope = s0
        state.urefs = remaining
    end
    return
end


# The first method that is tried. Searches the current scope for local bindings
# that match `x`. Steps:
# 1. Check whether we've already checked this scope (inifinite loops are
# possible when traversing nested modules.)
# 2. Check what sort of EXPR we're dealing with, separate name from EXPR that
# binds.
# 3. Look in the scope's variable list for a binding matching the name.
# 4. If 3. is unsuccessful, check whether the scope imports any modules then check them.
# 5. If no match is found within this scope check the parent scope.
# The return value is a boolean that is false if x should point to something but
# can't be resolved.

function resolve_ref(x::EXPR, scope::Scope, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    # if the current scope is a soft scope we should check the parent scope first
    # before trying to resolve the ref locally
    # if is_soft_scope(scope) && parentof(scope) isa Scope
    #     resolve_ref(x, parentof(scope), state) && return true
    # end

    hasref(x, meta_dict) && return true
    resolved = false

    if is_getfield(x)
        return resolve_getfield(x, scope, state)
    elseif iskwarg(x)
        # Note to self: this seems wronge - Binding should be attached to entire Kw EXPR.
        if isidentifier(x.args[1]) && !hasbinding(x.args[1], meta_dict)
            setref!(x.args[1], Binding(x.args[1], nothing, nothing, []), meta_dict)
        elseif isdeclaration(x.args[1]) && isidentifier(x.args[1].args[1]) && !hasbinding(x.args[1].args[1], meta_dict)
            if hasbinding(x.args[1], meta_dict)
                setref!(x.args[1].args[1], bindingof(x.args[1], meta_dict), meta_dict)
            else
                setref!(x.args[1].args[1], Binding(x.args[1], nothing, nothing, []), meta_dict)
            end
        end
        return true
    elseif is_special_macro_term(x) || new_within_struct(x)
        setref!(x, Binding(noname, nothing, nothing, []), meta_dict)
        return true
    end
    mn = nameof_expr_to_resolve(x)
    mn === nothing && return true

    if scopehasbinding(scope, mn)
        if x.parent.head === :public
            scope.names[mn].is_public = true
        end
        setref!(x, scope.names[mn], meta_dict)
        resolved = true
    elseif scope.modules isa Dict && length(scope.modules) > 0
        # Explicit rule: the `:__tree__` context (per-file traversal mode)
        # resolves BEFORE the global stores. A module-level declared name
        # shadows a Base/Core export in Julia, and the old whole-closure pass
        # got the same precedence from its merged scope `names`; iterating
        # `values(scope.modules)` alone reached the tree handle before
        # `:Base` only by Symbol-hash iteration-order accident.
        tree_ctx = get(scope.modules, :__tree__, nothing)
        if tree_ctx !== nothing
            resolve_ref_from_module(x, tree_ctx, state) && return true
        end
        for (k, m) in scope.modules
            k === :__tree__ && continue
            resolved = resolve_ref_from_module(x, m, state)
            resolved && return true
        end
    end
    if !resolved && !CSTParser.defines_module(scope.expr) && parentof(scope) isa Scope
        return resolve_ref(x, parentof(scope), state)
    end
    return resolved
end

# Searches a module store for a binding/variable that matches the reference `x1`.
function resolve_ref_from_module(x1::EXPR, m::SymbolServer.ModuleStore, state::TraverseState)::Bool
    meta_dict = state.meta_dict

    hasref(x1, meta_dict) && return true

    if CSTParser.ismacroname(x1)
        x = x1
        if valof(x) == "@." && m.name == VarRef(nothing, :Base)
            # @. gets converted to @__dot__, probably during lowering.
            setref!(x, m[:Broadcast][Symbol("@__dot__")], meta_dict)
            return true
        end

        mn = Symbol(valofid(x))
        if isexportedby(mn, m)
            setref!(x, maybe_lookup(m[mn], state), meta_dict)
            return true
        end
    elseif isidentifier(x1)
        x = x1
        if Symbol(valofid(x)) == m.name.name
            setref!(x, m, meta_dict)
            return true
        elseif isexportedby(x, m)
            setref!(x, maybe_lookup(m[Symbol(valofid(x))], state), meta_dict)
            return true
        end
    end
    return false
end

function resolve_ref_from_module(x::EXPR, scope::Scope, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true

    mn = nameof_expr_to_resolve(x)
    mn === nothing && return true

    # 1) If the scope is a module, allow resolving the module name itself
    if CSTParser.defines_module(scope.expr)
        n = CSTParser.get_name(scope.expr)
        if CSTParser.isidentifier(n) && mn == valofid(n)
            b = bindingof(scope.expr, meta_dict)  # module’s binding
            if b isa Binding
                setref!(x, b, meta_dict)
                return true
            end
        end
    end

    # 2) Resolve exported names from this module scope
    b = exported_binding(scope, mn, state)
    if b !== nothing
        setref!(x, b, meta_dict)
        return true
    end

    return false
end

"""
    scope_exports(scope::Scope, name::String, state)

Does the scope export a variable called `name`?
"""
scope_exports(scope::Scope, name::String, state) = exported_binding(scope, name, state) !== nothing

"""
    exported_binding(scope::Scope, name::String, state)

The binding a module scope makes available under `name` via an `export`
statement, or `nothing` if `name` isn't exported. Handles both names bound
directly in the module and names brought in from a `using`'d module and then
re-exported (`using ..Bar; export bar`).
"""
function exported_binding(scope::Scope, name::String, state)
    if scopehasbinding(scope, name) && (b = scope.names[name]) isa Binding
        initial_pass_on_exports(scope.expr, name, state)
        for ref in b.refs
            if ref isa EXPR && parentof(ref) isa EXPR && headof(parentof(ref)) === :export
                return b
            end
        end
    end
    # Re-export: `name` isn't bound locally, but an `export name` statement
    # names it after a `using`'d module brought it into this scope. The
    # exported identifier resolves (through the module's used modules) to the
    # originating binding, which is what callers should point references at.
    return reexported_binding(scope, name, state)
end

function reexported_binding(scope::Scope, name::String, state)
    meta_dict = state.meta_dict
    CSTParser.defines_module(scope.expr) || return nothing
    block = scope.expr.args[3]
    block === nothing && return nothing
    initial_pass_on_exports(scope.expr, name, state)
    for a in block.args
        headof(a) === :export || continue
        for arg in a.args
            (isidentifier(arg) && valofid(arg) == name) || continue
            r = refof(arg, meta_dict)
            (r isa Binding || r isa SymbolServer.SymStore) && return r
        end
    end
    return nothing
end

"""
    initial_pass_on_exports(x::EXPR, server)

Export statements need to be (pseudo) evaluated each time we consider
whether a variable is made available by an import statement.
"""

function initial_pass_on_exports(x::EXPR, name, state)
    meta_dict = state.meta_dict
    for a in x.args[3] # module block expressions
        if headof(a) === :export
            for i = 1:length(a.args)
                if isidentifier(a.args[i]) && valofid(a.args[i]) == name && !hasref(a.args[i], meta_dict)
                    process_EXPR(a.args[i], Delayed(scopeof(x, meta_dict), state.env, state.workspace_packages, meta_dict))
                end
            end
        end
    end
end

# Fallback method
function resolve_ref(x::EXPR, m, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    return hasref(x, meta_dict)::Bool
end

rhs_of_getfield(x::EXPR) = CSTParser.is_getfield_w_quotenode(x) ? x.args[2].args[1] : x
lhs_of_getfield(x::EXPR) = rhs_of_getfield(x.args[1])

"""
    resolve_getfield(x::EXPR, parent::Union{EXPR,Scope,ModuleStore,Binding}, state::TraverseState)::Bool

Given an expression of the form `parent.x` try to resolve `x`. The method
called with `parent::EXPR` resolves the reference for `parent`, other methods
then check whether the Binding/Scope/ModuleStore to which `parent` points has
a field matching `x`.
"""
function resolve_getfield(x::EXPR, scope::Scope, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    resolved = resolve_ref(x.args[1], scope, state)
    if isidentifier(x.args[1])
        lhs = x.args[1]
    elseif CSTParser.is_getfield_w_quotenode(x.args[1])
        lhs = lhs_of_getfield(x)
    else
        return resolved
    end
    if resolved && (rhs = rhs_of_getfield(x)) !== nothing
        resolved = resolve_getfield(rhs, refof(lhs, meta_dict), state)
    end
    return resolved
end


function resolve_getfield(x::EXPR, parent_type::EXPR, state::TraverseState)::Bool
    meta_dict = state.meta_dict

    hasref(x, meta_dict) && return true
    resolved = false
    if isidentifier(x)
        if CSTParser.defines_module(parent_type) && scopeof(parent_type, meta_dict) isa Scope
            resolved = resolve_ref(x, scopeof(parent_type, meta_dict), state)
        elseif CSTParser.defines_struct(parent_type)
            if scopehasbinding(scopeof(parent_type, meta_dict), valofid(x))
                setref!(x, scopeof(parent_type, meta_dict).names[valofid(x)], meta_dict)
                resolved = true
            end
        end
    end
    return resolved
end


function resolve_getfield(x::EXPR, b::Binding, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    resolved = false
    if b.val isa Binding
        resolved = resolve_getfield(x, b.val, state)
    elseif b.val isa TreeRef
        # per-file traversal mode only (a Binding's val can only be a TreeRef
        # there): an import-bound module name (`import .Sib` + `Sib.f()`)
        # stores its tree target as plain data — continue through it.
        resolved = resolve_getfield(x, b.val, state)
    elseif b.val isa SymbolServer.ModuleStore || (b.val isa EXPR && CSTParser.defines_module(b.val))
        resolved = resolve_getfield(x, b.val, state)
    elseif b.type isa Binding
        resolved = resolve_getfield(x, b.type.val, state)
    elseif b.type isa SymbolServer.DataTypeStore
        resolved = resolve_getfield(x, b.type, state)
    end
    return resolved
end

function resolve_getfield(x::EXPR, parent_type, state::TraverseState)::Bool
    hasref(x, state.meta_dict)
end

"""
    resolve_getfield(x::EXPR, tr::TreeRef, state::TraverseState)::Bool

Per-file traversal mode only: the getfield LHS resolved through the module
tree to a plain-data `TreeRef` (`Sib` in `Sib.f()` — directly as its
`Meta.ref`, or through an import binding's `val`). The concrete lookup lives
outside StaticLint: `qualified_module_target` (layer_file_analysis.jl) turns
the LHS `TreeRef` back into something resolvable — a (possibly cross-root)
module context for tree/workspace-package modules, or the env `ModuleStore`
for external stand-ins — and the member then resolves through the same
machinery import paths use (`_get_field` for contexts; the existing
`ModuleStore` arm for stores, so env-backed members behave exactly as in the
whole-closure pass). A member miss, or a `tr` that doesn't denote a module,
leaves `x` ref-less — matching the old getfield arms' miss behavior.

Unreachable in the whole-closure pass: `TreeRef`s are only ever constructed
in per-file mode, and the lookup additionally requires a seeded `:__tree__`
scope context (gone even in per-file mode's post-pass steps, which strip the
handles — those steps then no-op here via the `nothing` context).
"""
function resolve_getfield(x::EXPR, tr::TreeRef, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    CSTParser.is_id_or_macroname(x) || return false
    ctx = enclosing_tree_context(state.scope)
    ctx === nothing && return false
    target = qualified_module_target(ctx, tr)
    target === nothing && return false
    if target isa SymbolServer.ModuleStore
        return resolve_getfield(x, target, state)
    end
    cand = _get_field(target, x, state)
    cand === nothing && return false
    # `cand` is a plain-data TreeRef, or a module context whose setref!
    # stores its plain-data stand-in — never a runtime handle in meta.
    setref!(x, cand, meta_dict)
    return true
end

function is_overloaded(val::SymbolServer.SymStore, scope::Scope)
    vr = val.name isa SymbolServer.FakeTypeName ? val.name.name : val.name
    haskey(scope.overloaded, vr)
end

function resolve_getfield(x::EXPR, m::SymbolServer.ModuleStore, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    resolved = false
    if CSTParser.ismacroname(x) && (val = maybe_lookup(SymbolServer.maybe_getfield(Symbol(valofid(x)), m, getsymbols(state)), state)) !== nothing
        setref!(x, val, meta_dict)
        resolved = true
    elseif isidentifier(x) && (val = maybe_lookup(SymbolServer.maybe_getfield(Symbol(valofid(x)), m, getsymbols(state)), state)) !== nothing
        # Check whether variable is overloaded in top-level scope
        tls = retrieve_toplevel_scope(state.scope, meta_dict)
        # if tls.overloaded !== nothing && (vr = val.name isa SymbolServer.FakeTypeName ? val.name.name : val.name; haskey(tls.overloaded, vr))
        #     @info 1
        #     setref!(x, tls.overloaded[vr])
        #     return true
        # end
        vr = val.name isa SymbolServer.FakeTypeName ? val.name.name : val.name
        if haskey(tls.names, valofid(x)) && tls.names[valofid(x)] isa Binding && tls.names[valofid(x)].val isa SymbolServer.FunctionStore
            setref!(x, tls.names[valofid(x)], meta_dict)
            return true
        elseif tls.overloaded !== nothing && haskey(tls.overloaded, vr)
            setref!(x, tls.overloaded[vr], meta_dict)
            return true
        end
        setref!(x, val, meta_dict)
        resolved = true
    end
    return resolved
end

function resolve_getfield(x::EXPR, parent::SymbolServer.DataTypeStore, state::TraverseState)::Bool
    meta_dict = state.meta_dict
    hasref(x, meta_dict) && return true
    resolved = false
    if isidentifier(x) && Symbol(valofid(x)) in parent.fieldnames
        fi = findfirst(f -> Symbol(valofid(x)) == f, parent.fieldnames)
        ft = parent.types[fi]
        val = SymbolServer._lookup(ft, getsymbols(state), true)
        # TODO: Need to handle the case where we get back a FakeUnion, etc.
        setref!(x, Binding(noname, nothing, val, []), meta_dict)
        resolved = true
    end
    return resolved
end

resolvable_macroname(x::EXPR) = isidentifier(x) && CSTParser.ismacroname(x) && refof(x, meta_dict) === nothing

nameof_expr_to_resolve(x) = isidentifier(x) ? valofid(x) : nothing

"""
    normalize_id(s)

Normalize an identifier's characters the way Julia's parser does: NFC
normalization plus the two folds Julia applies on top of it (`µ` U+00B5 →
`μ` U+03BC and `ɛ` U+025B → `ε` U+03B5). CSTParser preserves the raw source
text, so without this `ɛ` and `ε` — which Julia treats as the same variable —
would be seen as distinct names and produce spurious unused/undefined
diagnostics (#88). ASCII identifiers (the overwhelming majority) are returned
unchanged, so this is a no-op on the hot path.
"""
normalize_id(@nospecialize(s)) = s
normalize_id(s::String) = isascii(s) ? s : replace(Base.Unicode.normalize(s, :NFC), 'µ' => 'μ', 'ɛ' => 'ε')

"""
    valofid(x)

Returns the string value of an expression for which `isidentifier` is true,
i.e. handles NONSTDIDENTIFIERs. The name is normalized to match Julia's own
identifier normalization (see [`normalize_id`](@ref)) so that scope keys and
reference lookups line up regardless of the exact source code points.
"""
valofid(x::EXPR) = normalize_id(headof(x) === :IDENTIFIER ? valof(x) : valof(x.args[2]))

"""
new_within_struct(x::EXPR)

Checks whether x is a reference to `new` within a datatype constructor.
"""
new_within_struct(x::EXPR) = isidentifier(x) && valofid(x) == "new" && is_in_fexpr(x, CSTParser.defines_struct)
is_special_macro_term(x::EXPR) = isidentifier(x) && (valofid(x) == "__source__" || valofid(x) == "__module__") && is_in_fexpr(x, CSTParser.defines_macro)
