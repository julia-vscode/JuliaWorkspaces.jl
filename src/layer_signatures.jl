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
# from the defining EXPR, materialized request-time.
function _workspace_extension_signatures!(sigs::Vector{SignatureInfo}, f_ref, env, runtime, root::URI)
    for e in _matching_workspace_extensions(runtime, root, env, f_ref)
        entry = get(derived_item_positions(runtime, e.ref.file), e.ref.id, nothing)
        entry === nothing && continue
        _expr_signature!(sigs, entry.expr)
    end
    return
end

# Signatures for a tree-resolved callee: every inventory method item of `name`
# in the callee's origin module (`derived_method_items`), rendered from its
# defining EXPR. The EXPR is materialized request-time from the item's own file
# (`derived_item_positions`) — allowed in a request handler, never in a derived
# value — and rendered on its own, without analyzing the defining file.
function _collect_tree_signatures!(sigs::Vector{SignatureInfo}, tr::StaticLint.TreeRef, runtime, root::URI)
    qroot = _method_items_root(runtime, root, tr.origin_module)
    for ref in derived_method_items(runtime, qroot, tr.origin_module, tr.name)
        entry = get(derived_item_positions(runtime, ref.file), ref.id, nothing)
        entry === nothing && continue
        _expr_signature!(sigs, entry.expr)
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
                    CSTParser.defines_function(member) && _expr_signature!(sigs, member)
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

# Assemble a signature label from its rendered pieces, returning it together
# with the `[start, end)` UTF-16 offset range of each positional parameter.
#
# `ParameterInformation.label` may be a substring of the signature label or such
# an offset range (LSP spec); we always emit ranges, because a substring cannot
# tell apart two parameters that render identically (`::Any, ::Any`) and would
# match a name that also occurs in the callee (the `a` of `bar(a::Int)`). Since
# the label is built here from the very same parameter texts, the ranges are
# exact by construction — no searching, and nothing to keep in sync with a
# separate renderer.
#
# Every signature source funnels through this: symbol-store methods and
# workspace definitions alike, so both produce identical label and range shapes.
function _assemble_signature(callee::AbstractString, positional::Vector{String};
        kwargs::Vector{String}=String[], suffix::AbstractString="")
    buf = IOBuffer()
    print(buf, callee, "(")
    off = _utf16_length(callee) + 1  # past "callee("
    ranges = Tuple{Int,Int}[]
    for (i, text) in enumerate(positional)
        if i > 1
            print(buf, ", ")
            off += 2
        end
        w = _utf16_length(text)
        push!(ranges, (off, off + w))
        print(buf, text)
        off += w
    end
    isempty(kwargs) || print(buf, "; ", join(kwargs, ", "))
    print(buf, ")", suffix)
    return String(take!(buf)), ranges
end

# Text of a single SymbolServer method parameter: `name::type`, `::type` for an
# unnamed (`#unused#`) argument, or just `name` when the annotation is `::Any`
# (which reads as noise in a parameter hint).
function _ss_param_text(a, pred)
    buf = IOBuffer()
    io = IOContext(buf, :ss_shorten => pred)
    a[1] === Symbol("#unused#") || print(io, a[1])
    SymbolServer.isfakeany(a[2]) || print(io, "::", a[2])
    return String(take!(buf))
end

# Where a store method comes from, as `Base.print(io, ::MethodStore)` renders it.
_ss_method_suffix(m::SymbolServer.MethodStore) =
    string(" in ", m.mod, " at ", replace(m.file, SymbolServer.JULIA_DIR => ""), ':', m.line)

function _get_signatures(b::T, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) where T <: Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}
    pred = _sig_shorten_pred(env)
    StaticLint.iterate_over_ss_methods(b, tls, env, function (m)
        texts = String[_ss_param_text(a, pred) for a in m.sig]
        # The store records keyword names but no types or defaults, so they are
        # listed bare — same as a workspace definition, they belong in the label
        # but are not offered as parameters.
        label, ranges = _assemble_signature(string(m.name), texts;
            kwargs=String[string(k) for k in m.kws], suffix=_ss_method_suffix(m))
        params = [ParameterInfo(
            ranges[i],
            SymbolServer.isfakeany(m.sig[i][2]) ? "" : _sig_type_str(m.sig[i][2], pred)
        ) for i in eachindex(ranges)]
        push!(sigs, SignatureInfo(label, "", params))
        return false
    end; in_scope=in_scope)
end

_get_signatures(x::CSTParser.EXPR, tls::StaticLint.Scope, sigs::Vector{SignatureInfo}, env, meta_dict, in_scope=nothing) =
    _expr_signature!(sigs, x)

# Text of a name or type EXPR in a signature label: a `var"..."` name keeps its
# quoting (as a bare `Symbol` it would render unquoted), everything else is
# rendered by `to_codeobject`.
_sig_expr_text(x::CSTParser.EXPR) =
    CSTParser.isidentifier(x) ? something(_name_expr_label(x), "") : string(CSTParser.to_codeobject(x))

# Text of one parameter of a definition EXPR (or one field of a struct), spelled
# the way the call site reads it: `a`, `a::Int`, `::Int`, `a...`, `a = default`.
# A `@nospecialize` wrapper and a `const` field marker are dropped — neither says
# anything about the call. Rendering each parameter separately (rather than
# printing the whole signature) is what lets `_assemble_signature` know the
# parameters' offsets.
function _sig_param_text(arg::CSTParser.EXPR)
    inner = StaticLint.unwrap_nospecialize(arg)
    inner === arg || return _sig_param_text(inner)
    args = arg.args
    n = args === nothing ? 0 : length(args)
    if CSTParser.headof(arg) === :const && n == 1
        return _sig_param_text(args[1])
    elseif CSTParser.iskwarg(arg) && n == 2
        return string(_sig_param_text(args[1]), " = ", _sig_expr_text(args[2]))
    elseif CSTParser.issplat(arg) && n == 1
        return string(_sig_param_text(args[1]), "...")
    elseif CSTParser.isdeclaration(arg) && n == 2
        return string(_sig_param_text(args[1]), "::", _sig_expr_text(args[2]))
    end
    # an unnamed `::Int` (a declaration with no name) lands here
    return _sig_expr_text(arg)
end

# Text of what is being called: `foo`, `Base.getindex`, `Foo{T}`, or a functor's
# `(f::Foo)`, which needs its parens to read as a call.
_sig_callee_text(x::CSTParser.EXPR) =
    CSTParser.isdeclaration(x) ? string("(", _sig_param_text(x), ")") : _sig_expr_text(x)

# Build the `SignatureInfo` for a definition EXPR `x` (a function definition or a
# struct) and push it onto `sigs`. Shared by the local-binding path
# (`_get_signatures`) and the tree-resolved path (`_collect_tree_signatures!`),
# which materializes the defining EXPR of a cross-file inventory item. The EXPR
# alone is enough: parameters are rendered from the definition's own syntax, so
# no file analysis of the defining file is needed.
function _expr_signature!(sigs::Vector{SignatureInfo}, x::CSTParser.EXPR)
    if CSTParser.defines_function(x)
        sig = CSTParser.rem_wheres_decls(CSTParser.get_sig(x))
        (sig isa CSTParser.EXPR && sig.args !== nothing && !isempty(sig.args)) || return
        # An anonymous `function (x) ... end` has no callee to render — and no
        # name a call site could resolve, so it does not reach here either.
        CSTParser.iscall(sig) || return
        positional = String[]
        kwargs = String[]
        for i = 2:length(sig.args)
            arg = sig.args[i]
            if CSTParser.isparameters(arg)
                # kwargs appear in the label but are not offered as parameters
                arg.args === nothing || append!(kwargs, (_sig_param_text(a) for a in arg.args))
            else
                # EVERY positional parameter gets an entry, named or not: the
                # highlighted parameter is selected by index, so dropping an
                # unnamed `::Int` would shift every later parameter.
                push!(positional, _sig_param_text(arg))
            end
        end
        _push_expr_signature!(sigs, _sig_callee_text(sig.args[1]), positional, kwargs)
    elseif CSTParser.defines_struct(x)
        # a struct still being typed can be missing its name or body
        (x.args !== nothing && length(x.args) >= 3) || return
        body = x.args[3]
        (body isa CSTParser.EXPR && body.args !== nothing && !isempty(body.args)) || return
        # With an explicit inner constructor there is no implicit field
        # constructor to offer (`_collect_tree_signatures!` renders the inner
        # ones from the struct body instead).
        any(CSTParser.defines_function, body.args) && return
        fields = String[_sig_param_text(f) for f in body.args]
        _push_expr_signature!(sigs, _sig_callee_text(CSTParser.rem_subtype(x.args[2])), fields, String[])
    end
    return
end

function _push_expr_signature!(sigs::Vector{SignatureInfo}, callee::String, positional::Vector{String}, kwargs::Vector{String})
    label, ranges = _assemble_signature(callee, positional; kwargs=kwargs)
    push!(sigs, SignatureInfo(label, "", ParameterInfo[ParameterInfo(r, nothing) for r in ranges]))
    return
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
