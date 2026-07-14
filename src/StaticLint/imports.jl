function resolve_import_block(x::EXPR, state::TraverseState, root, usinged, markfinal=true)
    meta_dict = state.meta_dict

    if x.head == :as
        resolve_import_block(x.args[1], state, root, usinged, markfinal)
        ensuremeta(x.args[2], meta_dict)
        if hasbinding(last(x.args[1].args), meta_dict) && CSTParser.isidentifier(x.args[2])
            lhsbinding = bindingof(last(x.args[1].args), meta_dict)
            # Known accepted limitation: for `import A as B` that resolves only
            # on a later retry (see ResolveOnly below), this copy is made
            # *before* the retry fills `lhsbinding` in place, so `B`'s val/type
            # stay at whatever they were when this `:as` branch first ran
            # (nothing, for a synthetic binding). No diagnostics are affected;
            # only hover/goto-def stay degraded for that rare form.
            getmeta(x.args[2], meta_dict).binding = Binding(x.args[2], lhsbinding.val, lhsbinding.type, lhsbinding.refs)
            setref!(x.args[2], bindingof(x.args[2], meta_dict), meta_dict)
            getmeta(last(x.args[1].args), meta_dict).binding = nothing
        end
        return
    end
    n = length(x.args)
    for i = 1:length(x.args)
        arg = x.args[i]
        if isoperator(arg) && valof(arg) == "."
            # Leading dots. Can only be leading elements.
            if root == getsymbols(state)
                root = state.scope
            elseif root isa Scope && parentof(root) !== nothing
                root = parentof(root)
            else
                # Too many dots
                seterror!(arg, RelativeImportTooManyDots, meta_dict)
                return
            end
        elseif isidentifier(arg) || (i == n && (CSTParser.ismacroname(arg) || isoperator(arg)))
            cand = hasref(arg, meta_dict) ? refof(arg, meta_dict) : _get_field(root, arg, state)
            if hasref(arg, meta_dict) && is_synthetic_import_binding(cand)
                # A previous pass bound this name synthetically; retry the real
                # lookup and, on success, fill the same Binding object in place
                # so existing references see the real target.
                # (The hasref guard ensures `cand` is this arg's own synthetic
                # binding, not one that `_get_field` fished out of scope.names.)
                newcand = _get_field(root, arg, state)
                if newcand !== nothing && newcand !== cand
                    fill_synthetic_import_binding!(cand, newcand, state)
                else
                    # Still unresolved: keep the synthetic binding in place and
                    # stop. Continuing would let `_mark_import_arg` (and the
                    # `:as` copy logic, which cleared this component's binding)
                    # wrap the synthetic binding in a new one whose val is
                    # non-nothing, laundering it past is_synthetic_import_binding
                    # so the import would never be flagged as unresolved.
                    return
                end
            end
            if cand === nothing
                # Cannot resolve now (e.g. sibling not yet defined). Schedule a retry.
                if state isa Toplevel
                    # the import/using expression
                    imp = StaticLint.get_parent_fexpr(arg, y -> headof(y) === :using || headof(y) === :import)
                    #imp !== nothing && push!(state.resolveonly, imp)
                    imp !== nothing && (imp ∈ state.resolveonly || push!(state.resolveonly, imp))
                    # the enclosing module (so we re-resolve refs within it)
                    mod = StaticLint.maybe_get_parent_fexpr(imp, CSTParser.defines_module)
                    #mod !== nothing && push!(state.resolveonly, mod)
                    mod !== nothing && (mod ∈ state.resolveonly || push!(state.resolveonly, mod))
                    # bind the name this path would have bound so downstream
                    # references to it resolve (the user asserted it exists)
                    markfinal && ensure_synthetic_import_binding!(x, state)
                end
                return
            end
            root = maybe_lookup(cand, state)
            setref!(arg, root, meta_dict)
            if i == n
                markfinal && _mark_import_arg(arg, root, state, usinged, meta_dict)
                return refof(arg, meta_dict)
            end
        else
            return
        end
    end
end

function resolve_import(x::EXPR, state::TraverseState, root=getsymbols(state))
    if (headof(x) === :using || headof(x) === :import)
        usinged = (headof(x) === :using)
        if length(x.args) > 0 && isoperator(headof(x.args[1])) && valof(headof(x.args[1])) == ":"
            root2 = resolve_import_block(x.args[1].args[1], state, root, false, false)
            if root2 === nothing
                # schedule a retry like above
                if state isa Toplevel
                    push!(state.resolveonly, x)
                    mod = StaticLint.maybe_get_parent_fexpr(x, CSTParser.defines_module)
                    mod !== nothing && push!(state.resolveonly, mod)
                    # bind the explicitly listed names (`using A: b, c as d`)
                    for i = 2:length(x.args[1].args)
                        ensure_synthetic_import_binding!(x.args[1].args[i], state)
                    end
                end
                return
            end
            for i = 2:length(x.args[1].args)
                resolve_import_block(x.args[1].args[i], state, root2, usinged)
            end
        else
            for i = 1:length(x.args)
                resolve_import_block(x.args[i], state, root, usinged)
            end
        end
    end
end

function _mark_import_arg(arg, par, state, usinged, meta_dict)
    if par !== nothing && CSTParser.is_id_or_macroname(arg)
        if par isa Binding # mark reference to binding
            push!(par.refs, arg)
        end
        if par isa SymbolServer.VarRef
            par = SymbolServer._lookup(par, getsymbols(state), true)
            !(par isa SymbolServer.SymStore) && return
        end
        if bindingof(arg, meta_dict) === nothing
            ensuremeta(arg, meta_dict)
            getmeta(arg, meta_dict).binding = Binding(arg, par, _typeof(par, state), [])
            setref!(arg, bindingof(arg, meta_dict), meta_dict)
        end

        if usinged
            if par isa SymbolServer.ModuleStore
                add_to_imported_modules(state.scope, Symbol(valofid(arg)), par)
            elseif par isa Binding && par.val isa SymbolServer.ModuleStore
                add_to_imported_modules(state.scope, Symbol(valofid(arg)), par.val)
            elseif par isa Binding && par.val isa EXPR && CSTParser.defines_module(par.val)
                add_to_imported_modules(state.scope, Symbol(valofid(arg)), scopeof(par.val, meta_dict))
            elseif par isa Binding && par.val isa Binding && par.val.val isa EXPR && CSTParser.defines_module(par.val.val)
                add_to_imported_modules(state.scope, Symbol(valofid(arg)), scopeof(par.val.val, meta_dict))
            end
        else
           # import binds the name in the current scope
           state.scope.names[valofid(arg)] = bindingof(arg, meta_dict)
        end
    end
end



function add_to_imported_modules(scope::Scope, name::Symbol, val)
    if scope.modules isa Dict
        scope.modules[name] = val
    else
        scope.modules = Dict{Symbol,Any}(name => val)
    end
end
no_modules_above(s::Scope) = !CSTParser.defines_module(s.expr) || s.parent === nothing || no_modules_above(s.parent)
function get_named_toplevel_module(s, name)
    return nothing
end
function get_named_toplevel_module(s::Scope, name::String)
    if CSTParser.defines_module(s.expr)
        m_name = CSTParser.get_name(s.expr)
        if ((headof(m_name) === :IDENTIFIER && valof(m_name) == name) || headof(m_name) === :NONSTDIDENTIFIER && length(m_name.args) == 2 && valof(m_name.args[2]) == name) && no_modules_above(s)
            return s.expr
        end
    end
    if s.parent isa Scope
        return get_named_toplevel_module(s.parent, name)
    end
    return nothing
end
function _get_field(par, arg, state, visited=Base.IdSet{Any}())
    par in visited && return nothing
    push!(visited, par)

    meta_dict = state.meta_dict
    arg_str_rep = CSTParser.str_value(arg)
    if par isa SymbolServer.EnvStore
        if (arg_scope = retrieve_scope(arg, meta_dict)) !== nothing && (tlm = get_named_toplevel_module(arg_scope, arg_str_rep)) !== nothing && hasbinding(tlm, meta_dict)
            return bindingof(tlm, meta_dict)
        elseif haskey(state.workspace_packages, arg_str_rep)
            return state.workspace_packages[arg_str_rep]
        elseif haskey(par, Symbol(arg_str_rep))
            if isempty(state.env.project_deps) || Symbol(arg_str_rep) in state.env.project_deps
                return par[Symbol(arg_str_rep)]
            end
        end
    elseif par isa SymbolServer.ModuleStore # imported module
        if Symbol(arg_str_rep) === par.name.name
            return par
        elseif haskey(par, Symbol(arg_str_rep))
            par = par[Symbol(arg_str_rep)]
            if par isa SymbolServer.VarRef # reference to dependency
                return SymbolServer._lookup(par, getsymbols(state), true)
            end
            return par
        end
        for used_module_name in par.used_modules
            used_module = maybe_lookup(par[used_module_name], state)
            if used_module isa SymbolServer.ModuleStore && isexportedby(Symbol(arg_str_rep), used_module)
                return used_module[Symbol(arg_str_rep)]
            end
        end
    elseif par isa Scope
        if scopehasbinding(par, arg_str_rep)
            return par.names[arg_str_rep]
        elseif par.modules !== nothing
            for used_module in values(par.modules)
                if used_module isa SymbolServer.ModuleStore && isexportedby(Symbol(arg_str_rep), used_module)
                    return maybe_lookup(used_module[Symbol(arg_str_rep)], state)
                elseif used_module isa Scope && scope_exports(used_module, arg_str_rep, state)
                    return used_module.names[arg_str_rep]
                end
            end
        end
    elseif par isa Binding
        if par.val isa Binding
            return _get_field(par.val, arg, state, visited)
        elseif par.val isa EXPR && CSTParser.defines_module(par.val) && scopeof(par.val, meta_dict) isa Scope
            return _get_field(scopeof(par.val, meta_dict), arg, state, visited)
        elseif par.val isa EXPR && isassignment(par.val)
            if hasref(par.val.args[2], meta_dict)
                return _get_field(refof(par.val.args[2], meta_dict), arg, state, visited)
            elseif is_getfield_w_quotenode(par.val.args[2])
                return _get_field(refof_maybe_getfield(par.val.args[2], meta_dict), arg, state, visited)
            end
        elseif par.val isa SymbolServer.ModuleStore
            return _get_field(par.val, arg, state, visited)
        end
    end
    return
end

"""
    is_synthetic_import_binding(b)

Is `b` a binding created by `ensure_synthetic_import_binding!` for a name an
unresolved import statement would bind? Real import bindings created by
`_mark_import_arg` always carry a non-nothing `val`, so `val === nothing &&
type === nothing` on a binding whose name sits inside a `using`/`import`
statement identifies the synthetic ones.
"""
is_synthetic_import_binding(b) = b isa Binding && b.val === nothing && b.type === nothing &&
    b.name isa EXPR && is_in_fexpr(b.name, y -> headof(y) === :using || headof(y) === :import)

# Attach a synthetic binding to the name `block` (an import path) would bind:
# the alias for `as` blocks, otherwise the last path component. The user has
# asserted this name exists, so downstream references resolve to the import
# site instead of being reported as missing.
function ensure_synthetic_import_binding!(block::EXPR, state)
    if headof(block) === :as
        length(block.args) == 2 && _ensure_synthetic_import_binding_on!(block.args[2], state)
        return
    end
    (block.args === nothing || isempty(block.args)) && return
    _ensure_synthetic_import_binding_on!(last(block.args), state)
    return
end

function _ensure_synthetic_import_binding_on!(arg::EXPR, state)
    meta_dict = state.meta_dict
    CSTParser.is_id_or_macroname(arg) || return
    (hasbinding(arg, meta_dict) || hasref(arg, meta_dict)) && return
    ensuremeta(arg, meta_dict)
    b = Binding(arg, nothing, nothing, [])
    getmeta(arg, meta_dict).binding = b
    setref!(arg, b, meta_dict)
    return
end

# Late (ResolveOnly-retry) resolution: fill a synthetic binding in place so
# every reference already pointing at this Binding object sees the real target.
function fill_synthetic_import_binding!(b::Binding, val, state)
    val = maybe_lookup(val, state)
    val === b && return b # never create a self-referential binding
    b.val = val
    b.type = _typeof(val, state)
    return b
end

"""
    mark_unresolved_imports!(x::EXPR, meta_dict, isquoted=false)

Post-`semantic_pass` marking of import statements that still failed to
resolve: the first unresolved component of each import path gets an
`UnresolvedImport` error. Must run after all resolution retries (i.e.
alongside `resolve_remaining_getfields!`), because in-pass failures may
still be retried via `state.resolveonly`.
"""
function mark_unresolved_imports!(x::EXPR, meta_dict, isquoted=false)
    if quoted(x)
        isquoted = true
    elseif isquoted && unquoted(x)
        isquoted = false
    end
    if !isquoted && (headof(x) === :using || headof(x) === :import)
        mark_unresolved_import_stmt!(x, meta_dict)
        return x
    end
    if x.args !== nothing
        for a in x.args
            mark_unresolved_imports!(a, meta_dict, isquoted)
        end
    end
    return x
end

function mark_unresolved_import_stmt!(x::EXPR, meta_dict)
    x.args === nothing && return
    if length(x.args) > 0 && isoperator(headof(x.args[1])) && valof(headof(x.args[1])) == ":"
        colon_expr = x.args[1]
        failed = first_unresolved_import_component(colon_expr.args[1], meta_dict)
        if failed !== nothing
            # the whole module path is unknown; one error there covers the
            # statement (the listed names carry synthetic bindings)
            seterror!(failed, UnresolvedImport, meta_dict)
        else
            for i = 2:length(colon_expr.args)
                nfailed = first_unresolved_import_component(colon_expr.args[i], meta_dict)
                nfailed === nothing && continue
                seterror!(nfailed, UnresolvedImport, meta_dict)
            end
        end
    else
        for path in x.args
            failed = first_unresolved_import_component(path, meta_dict)
            failed === nothing && continue
            seterror!(failed, UnresolvedImport, meta_dict)
            if headof(x) === :using
                # wildcard using of an unknown module: suppress bare
                # missing-ref reporting in this scope (see collect_hints)
                scope = retrieve_scope(x, meta_dict)
                scope isa Scope && (scope.unresolved_wildcard_import = true)
            end
        end
    end
    return
end

# First component of an import path that is still unresolved after all
# passes: module-path components show up as ref-less (they never get
# synthetic bindings), bound-name components as still-synthetic bindings.
function first_unresolved_import_component(path::EXPR, meta_dict)
    headof(path) === :as && return first_unresolved_import_component(path.args[1], meta_dict)
    path.args === nothing && return nothing
    for arg in path.args
        isoperator(arg) && valof(arg) == "." && continue
        # already diagnosed some other way (e.g. RelativeImportTooManyDots)
        haserror(arg, meta_dict) && return nothing
        hasref(arg, meta_dict) || return arg
        is_synthetic_import_binding(refof(arg, meta_dict)) && return arg
    end
    return nothing
end

# Is `x` a component of a wildcard `using` (no explicit-name colon form)?
# Decides which UnresolvedImport message the diagnostics layer shows.
function is_in_wildcard_import(x::EXPR)
    imp = maybe_get_parent_fexpr(x, y -> headof(y) === :using || headof(y) === :import)
    imp === nothing && return false
    headof(imp) === :using || return false
    return !(imp.args !== nothing && length(imp.args) > 0 &&
             isoperator(headof(imp.args[1])) && valof(headof(imp.args[1])) == ":")
end
