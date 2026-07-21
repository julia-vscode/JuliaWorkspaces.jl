# Signature help layer
#
# Provides signature help (parameter hints) for function calls.
# All position parameters use 0-based byte offsets internally;
# the public API in public.jl converts 1-based string indices.

# ============================================================================
# Result types
# ============================================================================

"""
    struct ParameterInfo

Describes a single parameter of a function signature in signature help.

- `label::Union{String,Tuple{Int,Int}}`: The parameter as it appears in the
  signature — either the exact substring, or a `[start, end)` UTF-16 offset range
  into the signature label (LSP `ParameterInformation.label`).
- `documentation::Union{String,Nothing}`: Optional documentation for the parameter.
"""
struct ParameterInfo
    label::Union{String,Tuple{Int,Int}}
    documentation::Union{String,Nothing}
end

"""
    struct SignatureInfo

Describes a single callable signature in a signature-help result.

- `label::String`: The full signature rendered as text.
- `documentation::String`: Documentation for the signature.
- `parameters::Vector{ParameterInfo}`: The signature's parameters in order.
"""
struct SignatureInfo
    label::String
    documentation::String
    parameters::Vector{ParameterInfo}
end

"""
    struct SignatureResult

The result of a signature-help request at a call site.

- `signatures::Vector{SignatureInfo}`: Candidate signatures for the call.
- `active_signature::Int`: Index of the signature to highlight.
- `active_parameter::Int`: Index of the parameter to highlight.
"""
struct SignatureResult
    signatures::Vector{SignatureInfo}
    active_signature::Int
    active_parameter::Int
end

# ============================================================================
# Internal helpers
# ============================================================================

"""
    _fcall_arg_number(x)

Count which argument position the cursor is at within a function call.
"""
function _fcall_arg_number(x)
    if CSTParser.headof(x) === :LPAREN
        0
    else
        sum(CSTParser.headof(a) === :COMMA for a in CSTParser.parentof(x).trivia)
    end
end

"""
    _collect_signatures(x, meta_dict, env, runtime, root)

Given an EXPR `x` inside a call, collect all signature information for the
called function.
"""
function _collect_signatures(x, meta_dict::MetaDict, env, runtime, root::URI)
    sigs = SignatureInfo[]

    (x isa CSTParser.EXPR && CSTParser.parentof(x) isa CSTParser.EXPR && CSTParser.iscall(CSTParser.parentof(x))) || return sigs
    parent_call = CSTParser.parentof(x)
    if CSTParser.isidentifier(parent_call.args[1])
        call_name = parent_call.args[1]
    elseif CSTParser.iscurly(parent_call.args[1]) && CSTParser.isidentifier(parent_call.args[1].args[1])
        call_name = parent_call.args[1].args[1]
    elseif CSTParser.is_getfield_w_quotenode(parent_call.args[1])
        call_name = parent_call.args[1].args[2].args[1]
    else
        call_name = nothing
    end
    call_name === nothing && return sigs

    f_ref = StaticLint.refof(call_name, meta_dict)
    f_ref === nothing && return sigs

    # A callee resolved THROUGH the module tree carries a `TreeRef` (directly,
    # or as a file-local import binding's `.val`): its method set spans files
    # this per-file meta never merged, so collect the signatures from the
    # inventory method items of its origin module (`derived_method_items`).
    # Everything else — a file-local `Binding` (definitions in this very file)
    # or an env `FunctionStore`/`DataTypeStore` (Base/stdlib callees) — keeps
    # the old per-file/env path unchanged.
    tr = f_ref isa StaticLint.TreeRef ? f_ref :
        (f_ref isa StaticLint.Binding && f_ref.val isa StaticLint.TreeRef) ? f_ref.val : nothing
    if tr !== nothing
        _collect_tree_signatures!(sigs, tr, runtime, root)
    else
        tls = _retrieve_toplevel_scope(call_name, meta_dict)
        tls === nothing && return sigs
        in_scope = _in_scope_syms_at(runtime, root, x, meta_dict)
        _get_signatures(f_ref, tls, sigs, env, meta_dict, in_scope)
        # A store-backed callee the workspace extends (`Base.relpath(::T)` in a
        # sibling): the env store's method set misses that overload, so offer it
        # from its defining EXPR, like a tree method item.
        if f_ref isa Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
            _workspace_extension_signatures!(sigs, f_ref, env, runtime, root)
        end
    end

    return sigs
end

# Signatures of the workspace method extensions of a store-backed callee,
# rendered exactly like `_collect_tree_signatures!` renders a tree method item:
# the defining EXPR is materialized request-time and paired with its own
# file-analysis meta so parameter names recover.
function _workspace_extension_signatures!(sigs::Vector{SignatureInfo}, f_ref, env, runtime, root::URI)
    for e in _matching_workspace_extensions(runtime, root, env, f_ref)
        entry = get(derived_item_positions(runtime, e.ref.file), e.ref.id, nothing)
        entry === nothing && continue
        item_meta = derived_file_analysis(runtime, root, e.ref.file).meta
        _expr_signature!(sigs, entry.expr, item_meta)
    end
    return
end

# Signatures for a tree-resolved callee: every inventory method item of `name`
# in the callee's origin module (`derived_method_items`), rendered from its
# defining EXPR. The EXPR is materialized request-time from the item's own file
# (`derived_item_positions`) — allowed in a request handler, never in a derived
# value — and paired with that file's per-file analysis meta (same memoized
# CST, so the arg bindings match by objectid), so `_expr_signature!` recovers
# parameter names (and var"..." quoting) exactly as for a local definition.
function _collect_tree_signatures!(sigs::Vector{SignatureInfo}, tr::StaticLint.TreeRef, runtime, root::URI)
    qroot = _method_items_root(runtime, root, tr.origin_module)
    for ref in derived_method_items(runtime, qroot, tr.origin_module, tr.name)
        entry = get(derived_item_positions(runtime, ref.file), ref.id, nothing)
        entry === nothing && continue
        item_meta = derived_file_analysis(runtime, qroot, ref.file).meta
        _expr_signature!(sigs, entry.expr, item_meta)
        # A struct's INNER constructors are not separate top-level items (they
        # live inside the struct body), and `_expr_signature!`'s struct branch
        # deliberately suppresses the implicit field constructor when they
        # exist — so render them here, from the materialized struct EXPR.
        # Here ONLY, not in `_expr_signature!`: the local Binding path already
        # reaches inner constructors through the binding's method refs
        # (`get_method`), so rendering them inside `_expr_signature!` would
        # double-render for same-file structs.
        if CSTParser.defines_struct(entry.expr)
            body = entry.expr.args[3]
            if body isa CSTParser.EXPR && body.args !== nothing
                for member in body.args
                    CSTParser.defines_function(member) && _expr_signature!(sigs, member, item_meta)
                end
            end
        end
    end
    return
end

# The root whose tree `derived_method_items` should be queried with for a
# tree-resolved callee: the current root when `origin_module` is one of its
# tree paths (including the synthetic root `String[]`); otherwise — mirroring
# the cross-root dispatch of `_workspace_package_context` /
# `_tree_module_target` — the entry root of the workspace package named by the
# path's first segment. A deved workspace package's method set lives in ITS
# OWN root's tree, never the current one (the old whole-closure pass indexed
# deved packages too, so returning empty here would be a regression). Falls
# back to the current root (where `derived_method_items` then returns empty)
# when neither resolves.
function _method_items_root(rt, root::URI, origin_module::Vector{String})
    isempty(origin_module) && return root
    derived_module_exists(rt, root, origin_module) && return root
    entry = get(derived_workspace_package_roots(rt), origin_module[1], nothing)
    if entry !== nothing && derived_module_exists(rt, entry, origin_module)
        return entry
    end
    return root
end

# Fallback
function _get_signatures(b, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) end

function _get_signatures(b::StaticLint.Binding, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing)
    if b.val isa StaticLint.Binding
        _get_signatures(b.val, tls, sigs, env, meta_dict, in_scope)
    end
    if b.type == StaticLint.CoreTypes.Function || b.type == StaticLint.CoreTypes.DataType
        b.val isa SymbolServer.SymStore && _get_signatures(b.val, tls, sigs, env, meta_dict, in_scope)
        for ref in b.refs
            method = StaticLint.get_method(ref)
            if method !== nothing
                _get_signatures(method, tls, sigs, env, meta_dict, in_scope)
            end
        end
    end
end

# Predicate for `:ss_shorten`: a top-level `Core`/`Base` name that its module
# exports (e.g. `Core.Any`, `Base.Dict`) can be printed without its qualifier.
function _sig_shorten_pred(env)
    syms = StaticLint.getsymbols(env)
    return function (vr::SymbolServer.VarRef)
        SymbolServer.isfakeany(vr) && return true
        p = vr.parent
        (p isa SymbolServer.VarRef && p.parent === nothing) || return false
        mod = get(syms, p.name, nothing)
        mod isa SymbolServer.ModuleStore && vr.name in mod.exportednames
    end
end

_sig_type_str(@nospecialize(t), pred) =
    sprint((io, x) -> show(IOContext(io, :ss_shorten => pred), x), t)

# Number of UTF-16 code units in `s`. `ParameterInformation` label offsets are
# counted in UTF-16 code units (LSP spec), matching how the client indexes the
# signature label.
_utf16_length(s::AbstractString) = sum(c -> codepoint(c) >= 0x10000 ? 2 : 1, s; init=0)

# Text of a single SymbolServer method parameter exactly as it is rendered in
# the signature label by `Base.print(io, ::MethodStore)` under the same
# `:ss_shorten`/`:ss_omit_any` context: `name::type`, `::type` for an unnamed
# (`#unused#`) argument, or just `name` when the `::Any` annotation is omitted.
function _ss_param_text(a, pred)
    buf = IOBuffer()
    io = IOContext(buf, :ss_shorten => pred)
    a[1] === Symbol("#unused#") || print(io, a[1])
    SymbolServer.isfakeany(a[2]) || print(io, "::", a[2])
    return String(take!(buf))
end

function _get_signatures(b::T, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) where T <: Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
    pred = _sig_shorten_pred(env)
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        label = sprint((io, x) -> print(IOContext(io, :ss_shorten => pred, :ss_omit_any => true), x), m)
        # `ParameterInformation.label` is a `[start, end)` UTF-16 offset range
        # into the signature label (LSP spec). The label starts with `name(` and
        # joins parameters with `, `, so each parameter's span follows from the
        # accumulated rendered widths — a positional map, so it can never emit
        # the `#unused#` placeholder and stays unambiguous even when two
        # parameters render identically (e.g. `::Any, ::Any`).
        off = _utf16_length(string(m.name)) + 1  # advance past "name("
        n = length(m.sig)
        params = ParameterInfo[]
        for (i, a) in enumerate(m.sig)
            w = _utf16_length(_ss_param_text(a, pred))
            push!(params, ParameterInfo(
                (off, off + w),
                SymbolServer.isfakeany(a[2]) ? "" : _sig_type_str(a[2], pred)
            ))
            off += w
            i == n || (off += 2)  # ", " separator
        end
        push!(sigs, SignatureInfo(label, "", params))
        return false
    end; in_scope=in_scope)
end

_get_signatures(x::CSTParser.EXPR, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) =
    _expr_signature!(sigs, x, meta_dict)

# Build the `SignatureInfo` for a definition EXPR `x` (a function/macro
# definition or a struct) and push it onto `sigs`. Uses `meta_dict` only to
# recover argument bindings' names (var"..." quoting) — the struct branch needs
# no meta. Shared by the local-binding path (`_get_signatures`) and the
# tree-resolved path (`_collect_tree_signatures!`), which materializes the
# defining EXPR of a cross-file inventory item and passes that item's own
# file-analysis meta.
function _expr_signature!(sigs::Vector{SignatureInfo}, x::CSTParser.EXPR, meta_dict)
    if CSTParser.defines_function(x)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
        params = ParameterInfo[]
        if sig isa CSTParser.EXPR && sig.args !== nothing
            for i = 2:length(sig.args)
                argbinding = StaticLint.bindingof(sig.args[i], meta_dict)
                if argbinding !== nothing
                    # var"..." argument names keep their quoting
                    n = argbinding.name isa CSTParser.EXPR ? _name_expr_label(argbinding.name) : nothing
                    push!(params, ParameterInfo(something(n, ""), nothing))
                end
            end
            push!(sigs, SignatureInfo(string(CSTParser.to_codeobject(sig)), "", params))
        end
    elseif CSTParser.defines_struct(x)
        args = x.args[3]
        if length(args) > 0
            if !any(CSTParser.defines_function, args.args)
                params = ParameterInfo[]
                for field in args.args
                    field_name = CSTParser.rem_decl(field)
                    label = ""
                    if field_name isa CSTParser.EXPR && CSTParser.isidentifier(field_name)
                        # var"..." field names keep their quoting
                        label = something(_name_expr_label(field_name), "")
                    end
                    push!(params, ParameterInfo(label, nothing))
                end
                push!(sigs, SignatureInfo(string(CSTParser.to_codeobject(x)), "", params))
            end
        end
    end
end

# ============================================================================
# Call-site method matching (parameter names for hover and inlay hints)
# ============================================================================

# Positional index of `x` among the call's arguments, skipping the
# `;`-parameters block and inline kwargs. Returns `nothing` when `x` is not a
# positional argument, or when a splat at/before its position makes the
# mapping to declared parameters unknowable.
function _call_positional_arg_index(call::CSTParser.EXPR, x::CSTParser.EXPR)
    call.args === nothing && return nothing
    idx = 0
    for i in 2:length(call.args)
        a = call.args[i]
        (CSTParser.isparameters(a) || CSTParser.iskwarg(a)) && continue
        CSTParser.issplat(a) && return nothing
        idx += 1
        a == x && return idx
    end
    return nothing
end

function _sig_param_name(arg::CSTParser.EXPR, meta_dict::MetaDict)
    arg = StaticLint.unwrap_nospecialize(arg)
    inner = CSTParser.iskwarg(arg) ? arg.args[1] : arg
    b = StaticLint.bindingof(arg, meta_dict)
    b === nothing && (b = StaticLint.bindingof(inner, meta_dict))
    if b isa StaticLint.Binding && CSTParser.valof(b.name) isa String
        return CSTParser.valof(b.name)
    end
    nm = CSTParser.get_arg_name(inner)
    nmval = nm isa CSTParser.EXPR ? CSTParser.str_value(nm) : nothing
    return nmval isa String ? nmval : ""
end

# Positional parameter names of a matched method as `(names, vararg)`, where
# `vararg` says the last name is a trailing vararg; `nothing` when they can't
# be derived.
_method_param_names(m, meta_dict::MetaDict) = nothing

function _method_param_names(m::SymbolServer.MethodStore, meta_dict::MetaDict)
    names = String[string(first(p)) for p in m.sig]
    va = !isempty(m.sig) && StaticLint.CoreTypes.isva(last(m.sig)[2])
    return (names, va)
end

function _method_param_names(m::CSTParser.EXPR, meta_dict::MetaDict)
    if CSTParser.defines_function(m)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(m))
        (sig isa CSTParser.EXPR && sig.args !== nothing) || return nothing
        names = String[]
        va = false
        for i in 2:length(sig.args)
            arg = sig.args[i]
            CSTParser.isparameters(arg) && continue
            push!(names, _sig_param_name(arg, meta_dict))
            inner = StaticLint.unwrap_nospecialize(arg)
            va = CSTParser.issplat(inner) || StaticLint.is_explicit_vararg_decl(inner)
        end
        return (names, va)
    elseif CSTParser.defines_struct(m)
        args = m.args[3]
        args.args === nothing && return nothing
        inner = findfirst(CSTParser.defines_function, args.args)
        inner !== nothing && return _method_param_names(args.args[inner], meta_dict)
        return (String[_sig_param_name(field, meta_dict) for field in args.args], false)
    end
    return nothing
end

"""
    _resolve_call_param_names(call, meta_dict, env)

Positional parameter-name lists of the methods matching `call` (arity- and
type-checked by `StaticLint.find_methods`, the same matcher the
`IncorrectCallArgs` lint semantics build on). Returns `nothing` when the
callee or no matching method resolves. Never throws.
"""
function _resolve_call_param_names(call::CSTParser.EXPR, meta_dict::MetaDict, env)
    try
        methods = StaticLint.find_methods(call, StaticLint.getsymbols(env), meta_dict)
        names = Tuple{Vector{String},Bool}[]
        for m in methods
            ns = _method_param_names(m, meta_dict)
            ns === nothing || push!(names, ns)
        end
        return isempty(names) ? nothing : names
    catch
        return nothing
    end
end

_usable_param_name(name::String) = !(isempty(name) || startswith(name, "#") || name == "_")

# First usable name at position `arg_i` among the matched methods' parameter
# lists, as `(; name, vararg, slot)`: `vararg` says the position binds the
# trailing vararg whose declared position is `slot`.
function _pick_call_arg_name(names::Vector{Tuple{Vector{String},Bool}}, arg_i::Int)
    arg_i < 1 && return nothing
    for (ns, va) in names
        isempty(ns) && continue
        if arg_i <= length(ns)
            name = ns[arg_i]
            _usable_param_name(name) || continue
            return (name = name, vararg = va && arg_i == length(ns), slot = length(ns))
        elseif va
            name = last(ns)
            _usable_param_name(name) || continue
            return (name = name, vararg = true, slot = length(ns))
        end
    end
    return nothing
end

"""
    _resolve_call_arg_name(call, x, meta_dict, env)

Name of the positional parameter that call argument `x` supplies, from the
methods matching `call`, as `(; name, vararg, slot)` (see
`_pick_call_arg_name`). Returns `nothing` when no matching method provides a
usable name. Never throws.
"""
function _resolve_call_arg_name(call::CSTParser.EXPR, x::CSTParser.EXPR, meta_dict::MetaDict, env)
    arg_i = _call_positional_arg_index(call, x)
    arg_i === nothing && return nothing
    names = _resolve_call_param_names(call, meta_dict, env)
    names === nothing && return nothing
    return _pick_call_arg_name(names, arg_i)
end

"""
    _resolve_tree_call_arg_name(call, x, tr, rt, root)

Argument-name resolution for a cross-file callee resolved as a `TreeRef`. The
callee's methods span files (`derived_method_items`); each method's EXPR is
materialized request-time (`derived_item_positions`) and its parameter names
read against its OWN file-analysis meta (same memoized CST, so arg bindings
match by objectid), exactly as `_collect_tree_signatures!` does for signature
help. Candidates are arity-filtered by `_pick_call_arg_name` only — full
type-based overload discrimination (which the old merged pass did through
`find_methods`) is not reproduced across files, a sanctioned narrowing (the
first arity-compatible method's name wins). Never throws.
"""
function _resolve_tree_call_arg_name(call::CSTParser.EXPR, x::CSTParser.EXPR, tr::StaticLint.TreeRef, rt, root)
    (rt === nothing || root === nothing) && return nothing
    arg_i = _call_positional_arg_index(call, x)
    arg_i === nothing && return nothing
    qroot = _method_items_root(rt, root, tr.origin_module)
    names = Tuple{Vector{String},Bool}[]
    for ref in derived_method_items(rt, qroot, tr.origin_module, tr.name)
        entry = get(derived_item_positions(rt, ref.file), ref.id, nothing)
        entry === nothing && continue
        item_meta = derived_file_analysis(rt, qroot, ref.file).meta
        ns = _method_param_names(entry.expr, item_meta)
        ns === nothing || push!(names, ns)
    end
    isempty(names) && return nothing
    return _pick_call_arg_name(names, arg_i)
end

# ============================================================================
# Top-level entry point
# ============================================================================

"""
    _get_signature_help(runtime, uri, offset)

Core signature help logic: find all matching signatures for the function call
at `offset` (0-based) in the file identified by `uri`.
"""
function _get_signature_help(runtime, uri::URI, offset::Int)
    empty_result = SignatureResult(SignatureInfo[], 0, 0)

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return empty_result

    # Per-file analysis meta (the inventory architecture's per-file pass), not
    # the whole-closure static-lint meta: a callee defined in a SIBLING file is
    # resolved here as a `TreeRef` (through the module tree), and its method
    # signatures are collected from the inventory method items rather than from
    # a merged whole-closure binding. Same env selection as the per-file pass
    # (`derived_file_analysis`), so env-resolved `FunctionStore` callee refs
    # match the store the meta was built against.
    meta_dict = derived_file_analysis(runtime, root, uri).meta
    project_uri = derived_project_uri_for_root(runtime, root)
    env = project_uri === nothing ? derived_stdlib_only_env(runtime) : derived_environment(runtime, project_uri)

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = _get_expr(cst, offset)

    sigs = _collect_signatures(x, meta_dict, env, runtime, root)

    if isempty(sigs) || (x isa CSTParser.EXPR && CSTParser.headof(x) === :RPAREN)
        return empty_result
    end

    arg = _fcall_arg_number(x)

    # Once the cursor sits at a positional argument beyond the first (`arg > 0`),
    # narrow to signatures that actually have a parameter at that position. At the
    # first position (`arg == 0`) nothing has been committed yet, so every method
    # remains a candidate — including those with no positional parameters at all
    # (e.g. `f(; kw)` or `f()`), which must still be offered rather than skipped.
    filtered = arg == 0 ? sigs : filter(s -> length(s.parameters) > arg, sigs)
    return SignatureResult(filtered, 0, arg)
end
