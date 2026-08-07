function handle_macro(@nospecialize(x), state) end
function handle_macro(x::EXPR, state)
    meta_dict = state.meta_dict
    !CSTParser.ismacrocall(x) && return
    if headof(x.args[1]) === :globalrefdoc
        if length(x.args) == 4
            if isidentifier(x.args[4]) && !resolve_ref(x.args[4], state)
                if state isa Toplevel
                    push!(state.resolveonly, x)
                end
            elseif CSTParser.is_func_call(x.args[4])
                sig = (x.args[4])
                if sig isa EXPR 
                    hasscope(sig, meta_dict) && return # We've already done this, don't repeat
                    setscope!(sig, Scope(sig), meta_dict)
                    mark_sig_args!(sig, meta_dict)                    
                end
                if state isa Toplevel
                    push!(state.resolveonly, x)
                end
            end
        end
    elseif CSTParser.ismacroname(x.args[1])
        process_EXPR(x.args[1], state)
        if _points_to_Base_macro(x.args[1], Symbol("@deprecate"), state) && length(x.args) == 4
            if bindingof(x.args[3], meta_dict) !== nothing
                return
            elseif CSTParser.is_func_call(x.args[3])
                # add deprecated method
                # add deprecated function binding and args in new scope
                mark_binding!(x.args[3], meta_dict, x)
                mark_sig_args!(x.args[3], meta_dict)
                s0 = state.scope # store previous scope
                state.scope = Scope(s0, x, Dict(), nothing, nothing)
                setscope!(x, state.scope, meta_dict) # tag new scope to generating expression
                process_EXPR(x.args[3], state)
                process_EXPR(x.args[4], state)
                state.scope = s0
            elseif isidentifier(x.args[3])
                mark_binding!(x.args[3], meta_dict, x)
            end
        elseif _points_to_Base_macro(x.args[1], Symbol("@deprecate_binding"), state) && length(x.args) == 4 && isidentifier(x.args[3]) && isidentifier(x.args[4])
            setref!(x.args[3], refof(x.args[4], meta_dict), meta_dict)
        elseif _points_to_Base_macro(x.args[1], Symbol("@eval"), state) && length(x.args) == 3 && state isa Toplevel
            # Create scope around eval'ed expression. This ensures anybindings are
            # correctly hoisted to the top-level scope.
            setscope!(x, Scope(x), meta_dict)
            setparent!(scopeof(x, meta_dict), state.scope)
            s0 = state.scope
            state.scope = scopeof(x, meta_dict)
            interpret_eval(x.args[3], state)
            state.scope = s0
        elseif _points_to_Base_macro(x.args[1], Symbol("@irrational"), state) && length(x.args) == 5
            mark_binding!(x.args[3], meta_dict, x)
        elseif _points_to_Base_macro(x.args[1], Symbol("@enum"), state)
            for i = 3:length(x.args)
                if bindingof(x.args[i], meta_dict) !== nothing
                    break
                end
                if i == 4 && headof(x.args[4]) === :block
                    for j in 1:length(x.args[4].args)
                        mark_enum_member_binding!(x.args[4].args[j], meta_dict, x)
                    end
                    break
                end
                mark_enum_member_binding!(x.args[i], meta_dict, x)
            end
        elseif _points_to_Base_macro(x.args[1], Symbol("@goto"), state)
            if length(x.args) == 3 && isidentifier(x.args[3])
                setref!(x.args[3], Binding(noname, nothing, nothing, EXPR[]), meta_dict)
            end
        elseif _points_to_Base_macro(x.args[1], Symbol("@label"), state)
            if length(x.args) == 3 && isidentifier(x.args[3])
                mark_binding!(x.args[3], meta_dict)
            end
        elseif _points_to_Base_macro(x.args[1], Symbol("@NamedTuple"), state) && length(x.args) > 2 && headof(x.args[3]) == :braces
            for a in x.args[3].args
                if CSTParser.isdeclaration(a) && isidentifier(a.args[1]) && !hasref(a.args[1], meta_dict)
                    setref!(a.args[1], Binding(noname, nothing, nothing, EXPR[]), meta_dict)
                end
            end
        elseif _points_to_arbitrary_macro(x.args[1], :Reexport, Symbol("@reexport"), state)
            # Treat @reexport using/import as regular using/import
            for i = 3:length(x.args)
                arg = x.args[i]
                if arg isa EXPR && (headof(arg) === :using || headof(arg) === :import)
                    resolve_import(arg, state)
                end
            end
        elseif is_nospecialize(x.args[1])
            for i = 2:length(x.args)
                if bindingof(x.args[i], meta_dict) !== nothing
                    break
                end
                mark_binding!(x.args[i], meta_dict, x)
            end
        elseif _is_testitem_macro(x.args[1]) && state isa Toplevel
            _handle_testitem(x, state)
        elseif _is_testmodule_macro(x.args[1]) && state isa Toplevel
            _handle_testmodule(x, state)
        elseif _is_testsnippet_macro(x.args[1]) && state isa Toplevel
            # @testsnippet body will be inlined into each @testitem that references it.
            # Create an isolating scope so the declaration-site traversal doesn't leak
            # bindings into the parent scope. Its bound names are separately indexed
            # (test_setup_info) and injected as synthetic bindings into each
            # @testitem's scope.
            _handle_testsnippet(x, state)
        elseif _is_symbolics_vardef_macro(x.args[1])
            # Symbolics/ModelingToolkit @variables / @parameters / @constants
            # introduce their arguments as new variables. Mark them as bindings so
            # they resolve and aren't reported as missing references (#85).
            for i = 3:length(x.args)
                _mark_symbolics_binding(x.args[i], meta_dict)
            end
        # elseif _points_to_arbitrary_macro(x.args[1], :Turing, :model, state) && length(x) == 3 &&
        #     isassignment(x.args[3]) &&
        #     headof(x.args[3].args[2]) === CSTParser.Begin && length(x.args[3].args[2]) == 3 && headof(x.args[3].args[2].args[2]) === :block
        #     for i = 1:length(x.args[3].args[2].args[2])
        #         ex = x.args[3].args[2].args[2].args[i]
        #         if isbinarycall(ex, "~")
        #             mark_binding!(ex)
        #         end
        #     end
        # elseif _points_to_arbitrary_macro(x.args[1], :JuMP, :variable, state)
        #     if length(x.args) < 3
        #         return
        #     elseif length(x) >= 5 && ispunctuation(x[2])
        #         _mark_JuMP_binding(x[5])
        #     else
        #         _mark_JuMP_binding(x[3])
        #     end
        # elseif (_points_to_arbitrary_macro(x[1], :JuMP, :expression, state) ||
        #     _points_to_arbitrary_macro(x[1], :JuMP, :NLexpression, state) ||
        #     _points_to_arbitrary_macro(x[1], :JuMP, :constraint, state) || _points_to_arbitrary_macro(x[1], :JuMP, :NLconstraint, state)) && length(x) > 1
        #     if ispunctuation(x[2])
        #         if length(x) == 8
        #             _mark_JuMP_binding(x[5])
        #         end
        #     else
        #         if length(x) == 4
        #             _mark_JuMP_binding(x[3])
        #         end
        #     end
        end
    end
end

function mark_enum_member_binding!(arg::EXPR, meta_dict, val)
    if CSTParser.isassignment(arg)
        mark_binding!(arg.args[1], meta_dict, val)
    else
        mark_binding!(arg, meta_dict, val)
    end
end

function _rem_ref(x::EXPR)
    if headof(x) === :ref && length(x.args) > 0
        return x.args[1]
    end
    return x
end

is_nospecialize(x) = isidentifier(x) && valofid(x) == "@nospecialize"

# NOTE: currently unused (only referenced from commented-out JuMP handling).
# Fixed defensively: `:comparision` was a typo for the real head `:comparison`
# (same class as the _super `:primtive` fix), so the `lb <= x <= ub` branch
# was dead; also threaded the missing meta_dict.
function _mark_JuMP_binding(arg, meta_dict)
    if isidentifier(arg) || headof(arg) === :ref
        mark_binding!(_rem_ref(arg), meta_dict)
    elseif isbinarycall(arg, "==") || isbinarycall(arg, "<=")  || isbinarycall(arg, ">=")
        if isidentifier(arg.args[1]) || headof(arg.args[1]) === :ref
            mark_binding!(_rem_ref(arg.args[1]), meta_dict)
        else
            mark_binding!(_rem_ref(arg.args[3]), meta_dict)
        end
    elseif headof(arg) === :comparison && length(arg.args) == 5
        mark_binding!(_rem_ref(arg.args[3]), meta_dict)
    end
end

function _points_to_Base_macro(x::EXPR, name, state)
    CSTParser.is_getfield_w_quotenode(x) && return _points_to_Base_macro(x.args[2].args[1], name, state)
    haskey(getsymbols(state)[:Base], name) || return false
    targetmacro =  maybe_lookup(getsymbols(state)[:Base][name], state)
    isidentifier(x) && Symbol(valofid(x)) == name && (ref = refof(x, state.meta_dict)) !== nothing &&
    (ref == targetmacro || (ref isa Binding && ref.val == targetmacro))
end

# Variant usable in the check phase, where only the ExternalEnv + meta_dict are
# available (no analysis `state`).
function _points_to_Base_macro(x::EXPR, name, env::ExternalEnv, meta_dict)
    CSTParser.is_getfield_w_quotenode(x) && return _points_to_Base_macro(x.args[2].args[1], name, env, meta_dict)
    syms = getsymbols(env)
    haskey(syms[:Base], name) || return false
    targetmacro = maybe_lookup(syms[:Base][name], env)
    isidentifier(x) && Symbol(valofid(x)) == name && (ref = refof(x, meta_dict)) !== nothing &&
    (ref == targetmacro || (ref isa Binding && ref.val == targetmacro))
end

# `state` carries both the env and meta_dict; delegate to the env + meta_dict
# variant, which is also usable in the check phase (where no `state` exists).
_points_to_arbitrary_macro(x::EXPR, module_name::Symbol, name::Symbol, state) =
    _points_to_arbitrary_macro(x, module_name, name, state.env, state.meta_dict)

function _points_to_arbitrary_macro(x::EXPR, module_name::Symbol, name::Symbol, env::ExternalEnv, meta_dict)
    CSTParser.is_getfield_w_quotenode(x) && return _points_to_arbitrary_macro(x.args[2].args[1], module_name, name, env, meta_dict)
    syms = getsymbols(env)
    haskey(syms, module_name) || return false
    haskey(syms[module_name], name) || return false
    targetmacro = maybe_lookup(syms[module_name][name], env)
    isidentifier(x) && Symbol(valofid(x)) == name && (ref = refof(x, meta_dict)) !== nothing &&
    (ref == targetmacro || (ref isa Binding && ref.val == targetmacro))
end

maybe_lookup(x, env::ExternalEnv) = x isa SymbolServer.VarRef ? SymbolServer._lookup(x, getsymbols(env), true) : x
maybe_lookup(x, state::TraverseState) = maybe_lookup(x, state.env)

function maybe_eventually_get_id(x::EXPR)
    if isidentifier(x)
        return x
    elseif isbracketed(x)
        return maybe_eventually_get_id(x.args[1])
    end
    return nothing
end

is_eventually_interpolated(x::EXPR) = isbracketed(x) ? is_eventually_interpolated(x.args[1]) : isunarysyntax(x) && valof(headof(x)) == "\$"
isquoted(x::EXPR) = headof(x) === :quotenode && hastrivia(x) && isoperator(x.trivia[1]) && valof(x.trivia[1]) == ":"
maybeget_quotedsymbol(x::EXPR) = isquoted(x) ? maybe_eventually_get_id(x.args[1]) : nothing

function is_loop_iterator(x::EXPR)
    CSTParser.is_range(x) &&
    ((parentof(x) isa EXPR && headof(parentof(x)) === :for) ||
    (parentof(x) isa EXPR && parentof(parentof(x)) isa EXPR && headof(parentof(parentof(x))) === :for))
end

"""
    maybe_quoted_list(x::EXPR)

Try and get a list of quoted symbols from x. Return nothing if not possible.
"""
function maybe_quoted_list(x::EXPR)
    names = EXPR[]
    if headof(x) === :vect || headof(x) === :tuple
        for i = 1:length(x.args)
            name = maybeget_quotedsymbol(x.args[i])
            if name !== nothing
                push!(names, name)
            else
                return nothing
            end
        end
        return names
    end
end

"""
interpret_eval(x::EXPR, state)

Naive attempt to interpret `x` as though it has been eval'ed. Lifts
any bindings made within the scope of `x` to the toplevel and replaces
(some) interpolated binding names with the value where possible.
"""
function interpret_eval(x::EXPR, state)
    meta_dict = state.meta_dict
    # make sure we have bindings etc
    process_EXPR(x, state)
    tls = retrieve_toplevel_scope(x, meta_dict)
    for ex in collect_expr_with_bindings(x, meta_dict)
        b = bindingof(ex, meta_dict)
        if isidentifier(b.name)
            # The name of the binding is fixed
            add_binding(ex, state, tls)
        elseif isunarysyntax(b.name) && valof(headof(b.name)) == "\$"
            # The name of the binding is variable, we need to work out what the
            # interpolated symbol points to.
            variable_name = b.name.args[1]
            resolve_ref(variable_name, state.scope, state)
            if (ref = refof(variable_name, meta_dict)) isa Binding
                if isassignment(ref.val) && (rhs = maybeget_quotedsymbol(ref.val.args[2])) !== nothing
                    # `name = :something`
                    toplevel_binding = Binding(rhs, b.val, nothing, [])
                    settype!(toplevel_binding, b.type)
                    infer_type(toplevel_binding, tls, state)
                    if scopehasbinding(tls, valofid(toplevel_binding.name))
                        tls.names[valofid(toplevel_binding.name)] = toplevel_binding # TODO: do we need to check whether this adds a method?
                    else
                        tls.names[valofid(toplevel_binding.name)] = toplevel_binding
                    end
                elseif is_loop_iterator(ref.val) && (names = maybe_quoted_list(rhs_of_iterator(ref.val))) !== nothing
                    # name is of a collection of quoted symbols
                    for name in names
                        toplevel_binding = Binding(name, b.val, nothing, [])
                        settype!(toplevel_binding, b.type)
                        infer_type(toplevel_binding, tls, state)
                        if scopehasbinding(tls, valofid(toplevel_binding.name))
                            tls.names[valofid(toplevel_binding.name)] = toplevel_binding # TODO: do we need to check whether this adds a method?
                        else
                            tls.names[valofid(toplevel_binding.name)] = toplevel_binding
                        end
                    end
                end
            end
        end
    end
end


function rhs_of_iterator(x::EXPR)
    if isassignment(x)
        x.args[2]
    else
        x.args[3]
    end
end

function collect_expr_with_bindings(x, meta_dict, bound_exprs=EXPR[])
    if hasbinding(x, meta_dict)
        push!(bound_exprs, x)
        # Assuming here that if an expression has a binding we don't want anything bound to chlid nodes.
    elseif x.args !== nothing && !((CSTParser.defines_function(x) && !is_eventually_interpolated(x.args[1])) || CSTParser.defines_macro(x) || headof(x) === :export)
        for a in x.args
            collect_expr_with_bindings(a, meta_dict, bound_exprs)
        end
    end
    return bound_exprs
end

# ───────────────────────────────────────────────────────────────────
# TestItems.jl macro handling (@testitem, @testmodule, @testsnippet)
# ───────────────────────────────────────────────────────────────────

# Bare `@testitem`/`Module.@testitem` and friends — the qualified `X.@macro`
# getfield form is unwrapped the same way `is_scope_introducing_macrocall`
# (scope.jl) does, so a qualified testitem-family call gets the same handling
# (prebuilt scope, default-import/setup injection) as a bare one.
function _is_testitem_macro(x)
    CSTParser.is_getfield_w_quotenode(x) && return _is_testitem_macro(x.args[2].args[1])
    return isidentifier(x) && valofid(x) == "@testitem"
end
function _is_testmodule_macro(x)
    CSTParser.is_getfield_w_quotenode(x) && return _is_testmodule_macro(x.args[2].args[1])
    return isidentifier(x) && valofid(x) == "@testmodule"
end
function _is_testsnippet_macro(x)
    CSTParser.is_getfield_w_quotenode(x) && return _is_testsnippet_macro(x.args[2].args[1])
    return isidentifier(x) && valofid(x) == "@testsnippet"
end

# The testitem-family macros are recognized syntactically (the defining
# package is usually not in the analysis environment), so their macro-name
# identifiers can never resolve through the env. Give them a benign ref so
# they are not reported as missing references.
function _mark_test_macro_name!(x::EXPR, meta_dict)
    x.args === nothing && return
    length(x.args) >= 1 || return
    hasref(x.args[1], meta_dict) || setref!(x.args[1], Binding(noname, nothing, nothing, EXPR[]), meta_dict)
    return
end

# Symbolics/ModelingToolkit variable-defining macros. Matched by name (like the
# TestItems macros above) so they work even when the defining package isn't
# indexed; these names are distinctive enough that false matches are unlikely.
function _is_symbolics_vardef_macro(x::EXPR)
    if CSTParser.is_getfield_w_quotenode(x)
        return _is_symbolics_vardef_macro(x.args[2].args[1])
    end
    isidentifier(x) || return false
    n = valofid(x)
    return n == "@parameters" || n == "@variables" || n == "@constants"
end

# Mark the name(s) introduced by a single argument of a Symbolics variable
# macro. Handles bare identifiers, comma tuples, dependent-variable calls
# (`x(t)`), array/curly forms (`y[1:3]`), typed and defaulted forms
# (`a::Real`, `a=1`), recursing to the leading identifier.
function _mark_symbolics_binding(arg, meta_dict)
    arg isa EXPR || return
    hasbinding(arg, meta_dict) && return
    if isidentifier(arg)
        mark_binding!(arg, meta_dict)
    elseif CSTParser.istuple(arg) || CSTParser.isbracketed(arg)
        for a in arg.args
            _mark_symbolics_binding(a, meta_dict)
        end
    elseif (isassignment(arg) || CSTParser.isdeclaration(arg) || CSTParser.iscall(arg) ||
            headof(arg) === :ref || CSTParser.iscurly(arg)) && length(arg.args) > 0
        _mark_symbolics_binding(arg.args[1], meta_dict)
    end
end

"""
    _parse_testitem_kwargs(x::EXPR)

Parse keyword arguments from a `@testitem` macrocall. Returns:
- `default_imports::Bool` (default `true`)
- `setup_names::Vector{Symbol}` (default empty)
- `body::Union{Nothing,EXPR}` — the `begin...end` block, if found.

Note: Inside a macrocall, keyword arguments parse as ASSIGNMENT nodes (not :kw),
so detection checks both iskwarg and isassignment node kinds.
"""
function _parse_testitem_kwargs(x::EXPR)
    default_imports = true
    setup_names = Symbol[]
    body = nothing

    # args layout: args[1]=@testitem, args[2]=NOTHING line-info placeholder, args[3]=name_string, args[4..end]=kwargs and body
    x.args === nothing && return (default_imports, setup_names, body)
    for i in 3:length(x.args)
        arg = x.args[i]
        arg === nothing && continue
        if (iskwarg(arg) || isassignment(arg)) && arg.args !== nothing && length(arg.args) >= 2
            kwname = arg.args[1]
            kwval = arg.args[2]
            if isidentifier(kwname) && valof(kwname) == "default_imports"
                if kwval isa EXPR && (headof(kwval) === :FALSE || (isidentifier(kwval) && valof(kwval) == "false"))
                    default_imports = false
                end
            elseif isidentifier(kwname) && valof(kwname) == "setup"
                # setup=[Foo, Bar] — kwval is a :vect EXPR
                if kwval isa EXPR && headof(kwval) === :vect && kwval.args !== nothing
                    for s in kwval.args
                        if isidentifier(s)
                            push!(setup_names, Symbol(valofid(s)))
                        end
                    end
                end
            end
        elseif headof(arg) === :block
            body = arg
        end
    end
    return (default_imports, setup_names, body)
end

"""
    _handle_testitem(x::EXPR, state::Toplevel)

Handle a `@testitem "name" [kwargs...] begin ... end` macrocall.

Creates a module-like scope for the body block. If `default_imports=true`,
`Test` and the parent package module are injected into the scope. Setup modules
referenced via `setup=[...]` are also injected.
"""
function _handle_testitem(x::EXPR, state::Toplevel)
    meta_dict = state.meta_dict
    _mark_test_macro_name!(x, meta_dict)
    default_imports, setup_names, body = _parse_testitem_kwargs(x)

    body === nothing && return

    # Create a module-like scope for the @testitem body
    setscope!(x, Scope(x), meta_dict)
    setparent!(scopeof(x, meta_dict), state.scope)
    item_scope = scopeof(x, meta_dict)

    # Pre-populate with Base and Core (like a real module)
    item_scope.modules = Dict{Symbol,Any}()
    item_scope.modules[:Base] = getsymbols(state)[:Base]
    item_scope.modules[:Core] = getsymbols(state)[:Core]

    # Looked up once and shared by the default-imports injection below and
    # the setup-resolution loop (both need the per-file tree-resolution
    # handle; state.scope is still the ENCLOSING scope here, pre-dating the
    # item_scope we just created).
    tctx = enclosing_tree_context(state.scope)

    # If default_imports=true, add Test and the parent package module
    default_imports && state.simulate_testitem_runtime && _inject_testitem_default_imports!(item_scope, state, tctx)

    # Resolve setup=[...] references through the plain-data setup index
    # (test_setup_info interface). Testmodules bind their name — members
    # resolve via TestSetupModuleRef; snippet names are injected directly
    # (TestItemRunner splices snippet code into the testitem body).
    # Gated on simulate_testitem_runtime: a setup-body-only pass
    # (derived_test_setups_in_file) analyzing a @testitem nested in the
    # body would otherwise re-enter that same query via test_setup_info
    # and cycle.
    if tctx !== nothing && state.simulate_testitem_runtime
        for setup_name in setup_names
            info = test_setup_info(tctx, setup_name)
            info === nothing && continue
            if info.kind === :module
                item_scope.names[String(setup_name)] =
                    Binding(noname, TestSetupModuleRef(String(setup_name), info.names), CoreTypes.Module, EXPR[])
                # TestItemRunner injects a testmodule via `using ..Setups.TM`,
                # which brings TM's EXPORTED names — not its full member set
                # — into the testitem scope too.
                for n in info.exports
                    haskey(item_scope.names, n) ||
                        (item_scope.names[n] = Binding(noname, nothing, nothing, EXPR[]))
                end
            elseif info.kind === :snippet
                for n in info.names
                    haskey(item_scope.names, n) ||
                        (item_scope.names[n] = Binding(noname, nothing, nothing, EXPR[]))
                end
                # Re-attach the snippet's resolved wildcard `using`s: the env
                # store where available (full member info), the module tree
                # otherwise (export-filtered, like the default-imports path).
                # An attachment miss means the item can't enumerate what the
                # snippet sees — suppress bare missing-ref checks then.
                symbols = getsymbols(state)
                for pkgname in info.wildcard_packages
                    # `pkgname` is the bare leaf of a dotted `using X.Y` (i.e. `Y`),
                    # so on a name collision this can attach an unrelated top-level
                    # package sharing that name instead of failing safe.
                    pkg_sym = Symbol(pkgname)
                    attached = false
                    if haskey(symbols, pkg_sym)
                        item_scope.modules[pkg_sym] = symbols[pkg_sym]
                        _add_module_public_names!(item_scope, symbols[pkg_sym], state)
                        attached = true
                    else
                        wp = workspace_package_context(tctx, pkgname)
                        if wp !== nothing
                            haskey(item_scope.names, pkgname) ||
                                (item_scope.names[pkgname] = Binding(noname, context_tree_ref(wp), CoreTypes.Module, EXPR[]))
                            exps = context_exported_names(wp)
                            if exps !== nothing
                                item_scope.modules[pkg_sym] = ExportFilteredContext(wp, Set{String}(exps))
                                attached = true
                            end
                        end
                    end
                    attached || (item_scope.unresolved_wildcard_import = true)
                end
                info.has_unresolved_wildcard && (item_scope.unresolved_wildcard_import = true)
            end
        end
    end

    # NOTE: We intentionally do NOT call process_EXPR(body, state) here.
    # The body will be processed by the standard traverse() in process_EXPR,
    # which will use the scope we just created (pushed by scopes()).
    return
end

"""
    _inject_testitem_default_imports!(scope::Scope, state::Toplevel, tctx)

Simulate the default imports a `@testitem`/`@testsnippet` body runs with:
`using Test` and `using <the package under test>`. Shared by both handlers —
TestItemRunner `include_string`s a `@testsnippet`'s code INTO each
referencing testitem's module, so a snippet body sees the same defaults a
testitem body does (unlike `@testmodule`, which is a bare module at runtime
and gets neither).

`tctx` is the caller's `enclosing_tree_context(state.scope)` (passed in
rather than recomputed here so a caller resolving it for other purposes
too — `_handle_testitem`'s setup loop — only looks it up once).

If the package injection does not succeed (no `self_package_name`, or the
package resolves through neither the indexed env nor the workspace module
tree), the scope's wildcard-import is marked unresolved as a fallback: the
body behaves as though `using PackageName` ran, and if we cannot enumerate
that package's names we must suppress bare missing-ref reporting there
rather than flood it. This is keyed ONLY on the package outcome, deliberately
NOT on whether the `Test` injection above succeeded (`haskey(symbols,
:Test)` is false in headless environments where existing tests still expect
missing refs to fire).
"""
function _inject_testitem_default_imports!(scope::Scope, state::Toplevel, tctx)
    symbols = getsymbols(state)
    if haskey(symbols, :Test)
        scope.modules[:Test] = symbols[:Test]
        # Also add all Test exports into scope (simulating `using Test`)
        _add_module_public_names!(scope, symbols[:Test], state)
    end

    # Inject the parent package module (simulating `using PackageName`)
    package_injected = false
    if state.self_package_name !== nothing
        pkg_sym = Symbol(state.self_package_name)
        if haskey(symbols, pkg_sym)
            # Indexed (env-backed) package store
            scope.modules[pkg_sym] = symbols[pkg_sym]
            _add_module_public_names!(scope, symbols[pkg_sym], state)
            package_injected = true
        elseif tctx !== nothing
            # Workspace package: resolve through the module tree,
            # cross-root. The binding's val is the plain-data module
            # TreeRef (qualified `Pkg.x` goes through
            # `qualified_module_target`); bare exported names resolve via
            # an export-filtered context in scope.modules, which
            # `strip_module_contexts!` removes before meta is frozen.
            wp = workspace_package_context(tctx, state.self_package_name)
            if wp !== nothing
                scope.names[state.self_package_name] =
                    Binding(noname, context_tree_ref(wp), CoreTypes.Module, EXPR[])
                exps = context_exported_names(wp)
                if exps !== nothing
                    scope.modules[pkg_sym] = ExportFilteredContext(wp, Set{String}(exps))
                    package_injected = true
                end
            end
        end
    end

    package_injected || (scope.unresolved_wildcard_import = true)
    return
end

"""
    _handle_testmodule(x::EXPR, state::Toplevel)

Handle a `@testmodule Name begin ... end` macrocall.

Creates a module scope for the body block. The module binding is registered
in the parent scope so other code can reference it.
"""
function _handle_testmodule(x::EXPR, state::Toplevel)
    meta_dict = state.meta_dict
    _mark_test_macro_name!(x, meta_dict)

    # args layout: args[1]=@testmodule, args[2]=NOTHING line-info placeholder,
    # args[3]=Name, args[4:end] contain the begin...end block
    x.args === nothing && return
    length(x.args) < 4 && return
    name_expr = x.args[3]
    body = nothing
    for i in 4:length(x.args)
        if x.args[i] isa EXPR && headof(x.args[i]) === :block
            body = x.args[i]
            break
        end
    end
    body === nothing && return
    !isidentifier(name_expr) && return

    # valofid also covers var"..." names, where valof is nothing
    mod_name = valofid(name_expr)
    mod_name isa String || return

    # Create a module-like scope
    setscope!(x, Scope(x), meta_dict)
    setparent!(scopeof(x, meta_dict), state.scope)
    mod_scope = scopeof(x, meta_dict)

    mod_scope.modules = Dict{Symbol,Any}()
    mod_scope.modules[:Base] = getsymbols(state)[:Base]
    mod_scope.modules[:Core] = getsymbols(state)[:Core]

    # Create a binding for the module name
    binding = Binding(name_expr, x, nothing, EXPR[], true)
    mark_binding!(name_expr, meta_dict, x)
    state.scope.names[mod_name] = binding

    # NOTE: We intentionally do NOT call process_EXPR(body, state) here.
    # The body will be processed by the standard traverse() in process_EXPR,
    # which will use the scope we just created (pushed by scopes()).
    return
end

"""
    _handle_testsnippet(x::EXPR, state::Toplevel)

Handle a `@testsnippet Name begin ... end` macrocall.

Creates an isolating scope so the declaration-site traversal (by the standard
`traverse` in `process_EXPR`) doesn't leak bindings into the parent scope. The
snippet's bound names are separately indexed (`test_setup_info`) and injected
as synthetic bindings into each `@testitem`'s scope.

TestItemRunner `include_string`s the snippet's code INTO each referencing
`@testitem`'s module at runtime, so the snippet body itself sees the same
default imports (`Test`, the package under test) a testitem body does —
unlike `@testmodule`, whose declaration IS a real, bare module.
"""
function _handle_testsnippet(x::EXPR, state::Toplevel)
    meta_dict = state.meta_dict
    _mark_test_macro_name!(x, meta_dict)

    # Snippets take the same kwargs as @testitem; only default_imports
    # affects the declaration-site scope built here.
    default_imports, _, _ = _parse_testitem_kwargs(x)

    # Create an isolating scope — bindings created during traversal stay here
    setscope!(x, Scope(x), meta_dict)
    setparent!(scopeof(x, meta_dict), state.scope)
    snip_scope = scopeof(x, meta_dict)

    snip_scope.modules = Dict{Symbol,Any}()
    snip_scope.modules[:Base] = getsymbols(state)[:Base]
    snip_scope.modules[:Core] = getsymbols(state)[:Core]

    default_imports && state.simulate_testitem_runtime && _inject_testitem_default_imports!(snip_scope, state, enclosing_tree_context(state.scope))

    # Body will be traversed by the standard traverse() in process_EXPR,
    # using this isolating scope (pushed by scopes()).
    return
end

"""
    _add_module_public_names!(scope, mod_store, state)

Simulate `using ModuleName` by adding the module's exported names
into the given scope. Works with `SymbolServer.ModuleStore`.
"""
function _add_module_public_names!(scope::Scope, mod_store::SymbolServer.ModuleStore, state)
    for name_sym in mod_store.exportednames
        if haskey(mod_store, name_sym)
            val = maybe_lookup(mod_store[name_sym], state)
            if val !== nothing
                scope.names[string(name_sym)] = Binding(noname, val, nothing, EXPR[])
            end
        end
    end
end
function _add_module_public_names!(scope::Scope, mod_store, state)
    # Fallback for non-ModuleStore (e.g. Binding, Scope) — no-op
end
