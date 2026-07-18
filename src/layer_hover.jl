# Hover text generation layer
#
# Produces markdown documentation strings for a given position (string index)
# in a Julia source file. All the logic that was in LanguageServer/hover.jl
# now lives here, operating purely on CSTParser EXPR trees, StaticLint
# bindings/scopes, and SymbolServer stores — no LSP types.

using .URIs2: filepath2uri
import REPL

# ============================================================================
# Helper utilities (moved from LanguageServer utilities.jl / staticlint.jl)
# ============================================================================

const MetaDict = Dict{UInt64, StaticLint.Meta}

const _empty_hover_meta_dict = MetaDict()
const _empty_hover_env = StaticLint.ExternalEnv(
    SymbolServer.EnvStore(),
    Dict{SymbolServer.VarRef,Vector{SymbolServer.VarRef}}(),
    Symbol[],
)

# --- CST expr lookup --------------------------------------------------------

"""
    get_expr1(x, offset, pos=0)

Walk a CSTParser EXPR tree and return the leaf EXPR whose `span` covers
`offset` (0-based byte offset). Returns `nothing` if no match is found.
"""
function get_expr1(x, offset, pos=0)
    if length(x) == 0 || CSTParser.headof(x) === :NONSTDIDENTIFIER
        if pos <= offset <= pos + x.span
            return x
        else
            return nothing
        end
    else
        for i = 1:length(x)
            arg = x[i]
            if pos < offset < (pos + arg.span) # def within span
                return get_expr1(arg, offset, pos)
            elseif offset == pos
                if i > 1 && CSTParser.headof(x[i - 1]) === :IDENTIFIER && x[i - 1].span == x[i - 1].fullspan
                    # Attribute the position to the preceding identifier only when
                    # the cursor is flush against its text. The `span == fullspan`
                    # check excludes an identifier that carries trailing trivia
                    # (e.g. the `x` in `g(x;y)`, whose fullspan swallows the `;`):
                    # there the cursor is past the text, so the following node owns
                    # the position.
                    return get_expr1(x[i - 1], offset, pos)
                elseif arg.span != 0 || i == 1
                    return get_expr1(arg, offset, pos)
                end
                # Zero-width node (empty block, mutable/bare-module flag, …) cannot
                # own the position; fall through to the sibling that begins at this
                # same offset.
            elseif arg.span == arg.fullspan
                if i == length(x) # offset == pos + arg.fullspan
                    return get_expr1(arg, offset, pos)
                end
            else
                if offset == pos + arg.span
                    return get_expr1(arg, offset, pos)
                elseif offset == pos + arg.fullspan
                elseif pos + arg.span < offset < pos + arg.fullspan
                    return nothing
                end
            end
            pos += arg.fullspan
        end
        return nothing
    end
end

# --- Scope retrieval --------------------------------------------------------

function _retrieve_scope(x, meta_dict::MetaDict)
    if StaticLint.scopeof(x, meta_dict) !== nothing
        return StaticLint.scopeof(x, meta_dict)
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _retrieve_scope(CSTParser.parentof(x), meta_dict)
    end
    return nothing
end

function _retrieve_toplevel_scope(x::CSTParser.EXPR, meta_dict::MetaDict)
    if StaticLint.scopeof(x, meta_dict) !== nothing && StaticLint.is_toplevel_scope(x)
        return StaticLint.scopeof(x, meta_dict)
    elseif CSTParser.parentof(x) isa CSTParser.EXPR
        return _retrieve_toplevel_scope(CSTParser.parentof(x), meta_dict)
    end
    return nothing
end
_retrieve_toplevel_scope(s::StaticLint.Scope, meta_dict::MetaDict) =
    (StaticLint.is_toplevel_scope(s) || !(StaticLint.parentof(s) isa StaticLint.Scope)) ?
        s : _retrieve_toplevel_scope(StaticLint.parentof(s), meta_dict)

# --- Operator reference resolution ------------------------------------------

function _has_parent_file(x::CSTParser.EXPR)
    while CSTParser.parentof(x) isa CSTParser.EXPR
        x = CSTParser.parentof(x)
    end
    return CSTParser.parentof(x) === nothing && CSTParser.headof(x) === :file
end

function _resolve_op_ref(x::CSTParser.EXPR, env, meta_dict::MetaDict, rt=nothing, root=nothing, path=nothing)
    StaticLint.hasref(x, meta_dict) && return true
    !CSTParser.isoperator(x) && return false
    _has_parent_file(x) || return false
    scope = _retrieve_scope(x, meta_dict)
    scope === nothing && return false
    mn = CSTParser.str_value(x)
    _op_resolve_up_scopes(x, mn, scope, env, meta_dict) && return true
    # Per-file mode: the scope's `.modules` (which the walk above consults) are
    # stripped, so neither a cross-file operator declaration nor a Base/Core
    # exported operator is visible there. Fall back to (1) the module's visible
    # names — a hit sets a plain-data `TreeRef` the hover TreeRef arm renders —
    # then (2) the Base/Core env stores, exactly as the old scope.modules walk
    # did for exported operators.
    _op_resolve_from_tree(x, mn, meta_dict, rt, root, path) && return true
    return _op_resolve_from_env(x, mn, env, meta_dict)
end

function _op_resolve_from_env(x, mn, env, meta_dict::MetaDict)
    env === nothing && return false
    (mn isa AbstractString && !isempty(mn)) || return false
    sym = Symbol(mn)
    for modname in (:Base, :Core)
        m = get(env.symbols, modname, nothing)
        if m isa SymbolServer.ModuleStore && StaticLint.isexportedby(sym, m)
            StaticLint.setref!(x, StaticLint.maybe_lookup(m[sym], env), meta_dict)
            return true
        end
    end
    return false
end

function _op_resolve_from_tree(x, mn, meta_dict::MetaDict, rt, root, path)
    (rt === nothing || root === nothing || path === nothing) && return false
    (mn isa AbstractString && !isempty(mn)) || return false
    p = vcat(path, _in_file_module_names(x, meta_dict))
    vn = get(derived_module_visible_names(rt, root, p), mn, nothing)
    vn === nothing && return false
    StaticLint.setref!(x, StaticLint.TreeRef(mn, vn.kind, vn.item, vn.origin_module), meta_dict)
    return true
end

function _op_resolve_up_scopes(x, mn, scope, env, meta_dict::MetaDict)
    scope isa StaticLint.Scope || return false
    if StaticLint.scopehasbinding(scope, mn)
        StaticLint.setref!(x, scope.names[mn], meta_dict)
        return true
    elseif scope.modules isa Dict && length(scope.modules) > 0
        for (_, m) in scope.modules
            if m isa SymbolServer.ModuleStore && StaticLint.isexportedby(Symbol(mn), m)
                StaticLint.setref!(x, StaticLint.maybe_lookup(m[Symbol(mn)], env), meta_dict)
                return true
            elseif m isa StaticLint.Scope && StaticLint.scopehasbinding(m, mn)
                StaticLint.setref!(x, StaticLint.maybe_lookup(m.names[mn], env), meta_dict)
                return true
            end
        end
    end
    CSTParser.defines_module(scope.expr) || !(StaticLint.parentof(scope) isa StaticLint.Scope) && return false
    return _op_resolve_up_scopes(x, mn, StaticLint.parentof(scope), env, meta_dict)
end

# --- String helpers ---------------------------------------------------------

function _sanitize_docstring(doc::String)
    doc = replace(doc, "```jldoctest" => "```julia")
    doc = replace(doc, "\n#" => "\n###")
    return doc
end

_ensure_ends_with(s, c = "\n") = endswith(s, c) ? s : string(s, c)

# Compact `module <name>` hover rendering, shared by the cross-file (`TreeRef`)
# and same-file (local `Binding` whose `.val` is a module EXPR) paths so both
# agree byte-for-byte. Any `documentation` prefix (the module's own docstring)
# is rendered above the compact block; an undocumented module renders just the
# block. Only the old whole-module-body dump is gone (user-approved 2026-07-17).
_module_ref_hover(documentation::String, name) =
    string(_ensure_ends_with(documentation), "```julia\nmodule ", name, "\n```\n")

# ============================================================================
# Type annotation helpers (for variable hover + completions)
# ============================================================================

"""
    completion_type(b) -> Union{Symbol,Missing}

Infer the type of a binding `b` as a `Symbol` suitable for display in hover and
completion results, stripping a leading `Core.` qualifier. Returns `missing`
when the type cannot be determined or `b` is not a `StaticLint.Binding`.
"""
function completion_type(b::StaticLint.Binding)
    typ = _inner_completion_type(b.type)
    typ === missing && return missing
    if startswith(typ, "Core.")
        typ = typ[6:end]
    end
    return Symbol(typ)
end
completion_type(_) = missing

_inner_completion_type(b::SymbolServer.DataTypeStore) = sprint(print, b.name)
_inner_completion_type(b::StaticLint.Binding) = sprint(print, CSTParser.to_codeobject(b.name))
_inner_completion_type(_) = missing

function _maybe_insert_type_declaration(b::StaticLint.Binding)
    if b.val isa CSTParser.EXPR
        _maybe_insert_type_declaration(CSTParser.to_codeobject(b.val), completion_type(b))
    else
        completion_type(b)
    end
end

_maybe_insert_type_declaration(_, type) = coalesce(type, "")
_maybe_insert_type_declaration(s::Symbol, ::Missing) = s
_maybe_insert_type_declaration(s::Symbol, type) = Expr(:(::), s, Symbol(type))
_maybe_insert_type_declaration(ex::Expr, ::Missing) = ex
function _maybe_insert_type_declaration(ex::Expr, type)
    if ex.head === :(=) && length(ex.args) >= 2
        lhs = ex.args[1]
        if !(lhs isa Expr && lhs.head === :(::))
            ex.args[1] = Expr(:(::), lhs, Symbol(type))
        end
    end
    return ex
end

function _prettify_expr(ex::Expr)
    if ex.head === :kw && length(ex.args) == 2
        string(ex.args[1], " = ", ex.args[2])
    else
        string(ex)
    end
end
_prettify_expr(ex) = string(ex)

"""
    get_typed_definition(b) -> Union{String,Symbol,Missing}

Return a human-readable definition string for the binding `b` with its inferred
type annotation inserted where possible (for example `x::Int`). Falls back to
[`completion_type`](@ref) when `b` is not a `StaticLint.Binding`.
"""
get_typed_definition(b) = completion_type(b)
get_typed_definition(b::StaticLint.Binding) =
    _prettify_expr(_maybe_insert_type_declaration(b))

# ============================================================================
# Doc extraction helpers
# ============================================================================

function _maybe_get_doc_expr(x)
    while CSTParser.hasparent(x) && CSTParser.ismacrocall(CSTParser.parentof(x))
        x = CSTParser.parentof(x)
        _is_doc_expr(x) && return x
    end
    return x
end

# Recognise the documentation macro in any of its spellings: the implicit
# `:globalrefdoc`, an explicit `@doc`, or a module-qualified `Foo.@doc`.
_is_doc_macro_name(x) = false
function _is_doc_macro_name(x::CSTParser.EXPR)
    if CSTParser.headof(x) === :globalrefdoc
        return true
    elseif CSTParser.isidentifier(x)
        return CSTParser.valof(x) == "@doc"
    elseif CSTParser.is_getfield_w_quotenode(x)
        return _is_doc_macro_name(CSTParser.unquotenode(CSTParser.rhs_getfield(x)))
    else
        return false
    end
end

# A string-macro name like `raw` / `html` (`@raw_str`-style).
_is_string_macro_name(x) = false
function _is_string_macro_name(x::CSTParser.EXPR)
    if CSTParser.isidentifier(x)
        name = CSTParser.valof(x)
        return name isa String && endswith(name, "_str")
    elseif CSTParser.is_getfield_w_quotenode(x)
        return _is_string_macro_name(CSTParser.unquotenode(CSTParser.rhs_getfield(x)))
    else
        return false
    end
end

# The doc payload may itself be a string macrocall (e.g. `raw"..."`); unwrap to
# the underlying string literal.
_normalize_doc_payload_expr(x) = x
function _normalize_doc_payload_expr(x::CSTParser.EXPR)
    if CSTParser.ismacrocall(x) &&
       length(x.args) >= 3 &&
       _is_string_macro_name(x.args[1]) &&
       CSTParser.isstring(x.args[3])
        return x.args[3]
    end
    return x
end

_get_doc_payload_expr(x::CSTParser.EXPR) = length(x.args) >= 3 ? _normalize_doc_payload_expr(x.args[3]) : nothing
_get_doc_target_expr(x::CSTParser.EXPR) = length(x.args) >= 4 ? x.args[4] : nothing

# `@doc "..." target` written explicitly produces a doc macrocall referencing
# the binding via its refs rather than as a preceding doc on `b.val`.
function _maybe_get_doc_expr_from_refs(b::StaticLint.Binding, meta_dict)
    for r in b.refs
        r isa CSTParser.EXPR || continue
        doc_expr = _maybe_get_doc_expr(r)
        _is_doc_expr(doc_expr) || continue
        doc_target = _get_doc_target_expr(doc_expr)
        doc_target isa CSTParser.EXPR || continue
        if doc_target === r || StaticLint.bindingof(doc_target, meta_dict) === b
            return doc_expr
        end
    end
    return nothing
end

_expr_has_preceding_docs(x) = false
_expr_has_preceding_docs(x::CSTParser.EXPR) = _is_doc_expr(_maybe_get_doc_expr(x))

_is_const_expr(x) = false
_is_const_expr(x::CSTParser.EXPR) = CSTParser.headof(x) === :const

_is_doc_expr(x) = false
function _is_doc_expr(x::CSTParser.EXPR)
    return CSTParser.ismacrocall(x) &&
           length(x.args) == 4 &&
           _is_doc_macro_name(x.args[1]) &&
           CSTParser.isstring(_get_doc_payload_expr(x))
end

_binding_has_preceding_docs(b::StaticLint.Binding) = _expr_has_preceding_docs(b.val)

function _const_binding_has_preceding_docs(b::StaticLint.Binding)
    p = CSTParser.parentof(b.val)
    _is_const_expr(p) && _expr_has_preceding_docs(p)
end

function _get_preceding_docs(expr::CSTParser.EXPR, documentation)
    if _expr_has_preceding_docs(expr)
        string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(_maybe_get_doc_expr(expr))))
    elseif _is_const_expr(CSTParser.parentof(expr)) && _expr_has_preceding_docs(CSTParser.parentof(expr))
        string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(_maybe_get_doc_expr(CSTParser.parentof(expr)))))
    else
        documentation
    end
end

# ============================================================================
# Core hover dispatch
# ============================================================================

_get_hover(x, documentation::String, expr, env, meta_dict, rt=nothing, root=nothing) = documentation

function _get_hover(x::CSTParser.EXPR, documentation::String, expr, env, meta_dict, rt=nothing, root=nothing)
    if (CSTParser.isidentifier(x) || CSTParser.isoperator(x)) && StaticLint.hasref(x, meta_dict)
        r = StaticLint.refof(x, meta_dict)
        documentation = if r isa StaticLint.Binding && r.val isa StaticLint.TreeRef
            # A file-local import binding of a tree name (`using .Sib`,
            # `import X: f`): its `.val` carries the tree target — render it as
            # a tree ref, not as the (contentless) local binding.
            _get_tree_ref_hover(r.val, documentation, expr, env, meta_dict, rt, root)
        elseif r isa StaticLint.Binding
            _get_hover(r, documentation, expr, env, meta_dict)
        elseif r isa SymbolServer.SymStore
            _get_hover(r, documentation, expr, env, meta_dict, rt, root)
        elseif r isa StaticLint.TreeRef
            # A name resolved THROUGH the module tree in per-file mode: render
            # from the inventory item (+ defining-file docstring) rather than a
            # merged Binding — the per-file meta never saw the declaring file.
            _get_tree_ref_hover(r, documentation, expr, env, meta_dict, rt, root)
        else
            documentation
        end
    end
    return documentation
end

# Hover rendering for a `TreeRef` (module-tree/env resolution stand-in).
#
# - function/macro/datatype items: byte-parity with the old merged Binding
#   rendering, reproduced by materializing every method item's defining EXPR
#   (`derived_method_items` + `derived_item_positions`) and re-using the same
#   preceding-docs + signature-block loop the local path runs over `b.refs`.
#   The method set can span files/roots, so this is done over the tree, not a
#   single binding.
# - other tree items (const/global/assignment/enum): the typed-definition +
#   docstring rendering, recovered by materializing the defining EXPR and its
#   OWN file-analysis Binding (same memoized CST, so `bindingof` matches by
#   objectid) and delegating to `_get_tooltip` exactly as the local path would.
# - `:module`: a compact module reference (the old pass dumped the whole module
#   body — deliberately not preserved; see the task-5 change-list).
# - `:external_symbol`/`:external_module` (item === nothing): resolve the env
#   store and render the SymStore, matching the old store-backed rendering.
function _get_tree_ref_hover(tr::StaticLint.TreeRef, documentation::String, expr, env, meta_dict, rt, root)
    (rt === nothing || root === nothing) && return documentation

    if tr.item === nothing
        # Env-backed stand-ins carry no ItemRef; resolve the store leaf.
        if tr.kind === :external_symbol && !isempty(tr.origin_module)
            store = _resolve_external_module(rt, root, tr.origin_module)
            if store isa SymbolServer.ModuleStore
                val = get(store.vals, Symbol(tr.name), nothing)
                val isa SymbolServer.VarRef && (val = StaticLint.maybe_lookup(val, env))
                val isa SymbolServer.SymStore && return _get_hover(val, documentation, expr, env, meta_dict, rt, root)
            end
        elseif tr.kind === :external_module
            store = _resolve_external_module(rt, root, vcat(tr.origin_module, [tr.name]))
            store isa SymbolServer.SymStore && return _get_hover(store, documentation, expr, env, meta_dict, rt, root)
        end
        return documentation
    end

    if tr.kind === :module
        # Cross-file module name: the module's docstring is materialized
        # request-time from its defining file (same helper functions/structs
        # use), rendered above the compact block — byte-identical to the
        # same-file path.
        doc = item_documentation(rt, tr.item)
        doc !== nothing && (documentation = string(documentation, doc))
        return _module_ref_hover(documentation, tr.name)
    elseif tr.kind in (:function, :macro, :struct, :mutable_struct, :abstract, :primitive, :enum)
        return _tree_method_items_hover(tr, documentation, rt, root)
    else
        return _tree_binding_hover(tr, documentation, expr, env, rt, root)
    end
end

# Function/macro/datatype: reproduce `_get_tooltip`'s per-method loop over the
# inventory method items (which span files and, for deved packages, roots).
function _tree_method_items_hover(tr::StaticLint.TreeRef, documentation::String, rt, root)
    qroot = _method_items_root(rt, root, tr.origin_module)
    rendered = false
    for ref in derived_method_items(rt, qroot, tr.origin_module, tr.name)
        entry = get(derived_item_positions(rt, ref.file), ref.id, nothing)
        entry === nothing && continue
        method = entry.expr
        documentation = _get_preceding_docs(method, documentation)
        if CSTParser.defines_function(method)
            documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(CSTParser.get_sig(method)), "\n```\n")
            rendered = true
        elseif CSTParser.defines_datatype(method)
            documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(method), "\n```\n")
            rendered = true
        end
    end
    return rendered ? documentation : _tree_item_fallback_hover(tr.item, documentation, rt)
end

# const/global/assignment/enum: materialize the defining EXPR + its own
# file-analysis Binding and render exactly like the local path.
function _tree_binding_hover(tr::StaticLint.TreeRef, documentation::String, expr, env, rt, root)
    item = tr.item
    qroot = _method_items_root(rt, root, tr.origin_module)
    entry = get(derived_item_positions(rt, item.file), item.id, nothing)
    entry === nothing && return _tree_item_fallback_hover(item, documentation, rt)
    defmeta = derived_file_analysis(rt, qroot, item.file).meta
    b = _item_binding(entry.expr, defmeta)
    b isa StaticLint.Binding || return _tree_item_fallback_hover(item, documentation, rt)
    return _get_tooltip(b, documentation, defmeta, expr, env; show_definition = true)
end

# The `Binding` an item's defining node introduces. Item nodes from
# `derived_item_positions` are the DECLARATION statement (a `const`/`global`
# wrapper, an assignment, or the name itself); the binding lives on the bound
# identifier, so unwrap one level for `const`/`global` and read the LHS of an
# assignment.
function _item_binding(x::CSTParser.EXPR, meta)
    b = StaticLint.bindingof(x, meta)
    b isa StaticLint.Binding && return b
    if (_is_const_expr(x) || CSTParser.headof(x) === :global) && x.args !== nothing && !isempty(x.args)
        return _item_binding(x.args[1], meta)
    elseif CSTParser.isassignment(x) && x.args !== nothing && !isempty(x.args)
        return StaticLint.bindingof(x.args[1], meta)
    end
    return nothing
end

# Last-resort rendering when the defining EXPR/Binding can't be materialized:
# the item's docstring alone (still request-time via `item_documentation`).
function _tree_item_fallback_hover(item::ItemRef, documentation::String, rt)
    doc = item_documentation(rt, item)
    doc === nothing && return documentation
    return string(documentation, doc)
end

_get_hover(b::StaticLint.Binding, documentation::String, expr, env, meta_dict) =
    _get_tooltip(b, documentation, meta_dict, expr, env; show_definition = true)

function _get_tooltip(b::StaticLint.Binding, documentation::String, meta_dict::MetaDict=_empty_hover_meta_dict, expr = nothing, env = nothing; show_definition = false)
    if b.val isa StaticLint.Binding
        documentation = _get_hover(b.val, documentation, expr, env, meta_dict)
    elseif b.val isa CSTParser.EXPR
        if CSTParser.defines_module(b.val)
            # Same-file module name: render the module's OWN docstring (if any)
            # above the SAME compact `module <name>` block the cross-file
            # `TreeRef` path produces. Only the whole-module-body dump is gone
            # (user-approved 2026-07-17; see `_module_ref_hover`). The docstring
            # is surfaced exactly as the old `else` branch did.
            if _binding_has_preceding_docs(b)
                documentation = string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(_maybe_get_doc_expr(b.val))))
            end
            documentation = _module_ref_hover(documentation, CSTParser.str_value(CSTParser.get_name(b.val)))
        elseif CSTParser.defines_function(b.val) || CSTParser.defines_datatype(b.val)
            documentation = _get_func_hover(b, documentation, expr, env, meta_dict)
            for r in b.refs
                method = StaticLint.get_method(r)
                if method isa CSTParser.EXPR
                    documentation = _get_preceding_docs(method, documentation)
                    if CSTParser.defines_function(method)
                        documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(CSTParser.get_sig(method)), "\n```\n")
                    elseif CSTParser.defines_datatype(method)
                        documentation = string(_ensure_ends_with(documentation), "```julia\n", CSTParser.to_codeobject(method), "\n```\n")
                    end
                elseif method isa SymbolServer.SymStore
                    documentation = _get_hover(method, documentation, expr, env, meta_dict)
                end
            end
        else
            documentation = try
                if show_definition
                    documentation = string(
                        _ensure_ends_with(documentation),
                        """```julia
                        $(get_typed_definition(b))
                        ```\n
                        """
                    )
                end
                documentation = if _binding_has_preceding_docs(b)
                    string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(_maybe_get_doc_expr(b.val))))
                elseif _const_binding_has_preceding_docs(b)
                    string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(_maybe_get_doc_expr(CSTParser.parentof(b.val)))))
                elseif (doc_expr = _maybe_get_doc_expr_from_refs(b, meta_dict)) !== nothing
                    string(documentation, CSTParser.to_codeobject(_get_doc_payload_expr(doc_expr)))
                else
                    documentation
                end
            catch err
                @error "get_hover failed to convert Expr" exception = (err, catch_backtrace())
                documentation
            end
        end
    elseif b.val isa SymbolServer.SymStore
        documentation = _get_hover(b.val, documentation, expr, env, meta_dict)
    end
    return documentation
end

# --- SymbolServer stores ----------------------------------------------------

function _store_doc_hover(b::SymbolServer.SymStore, documentation::String)
    if !isempty(b.doc)
        documentation = string(documentation, b.doc, "\n")
    end
    return string(documentation, "```julia\n", b, "\n```")
end

_get_hover(b::SymbolServer.SymStore, documentation::String, expr, env, meta_dict, rt=nothing, root=nothing) =
    _store_doc_hover(b, documentation)

# One numbered method-list entry per workspace extension of a store-backed
# function/type, appended to `io`; returns the updated method count. Links to
# the defining item when its position materializes.
function _workspace_extension_lines!(io::IO, rt, exts, method_count::Int, fallback_sig::String)
    for e in exts
        method_count += 1
        sig = something(e.signature, fallback_sig)
        entry = get(derived_item_positions(rt, e.ref.file), e.ref.id, nothing)
        if entry === nothing
            println(io, "$(method_count). `$(sig)`\n")
        else
            line = _offset_to_position(rt, e.ref.file, entry.offset).line
            p = uri2filepath(e.ref.file)
            text = string(p === nothing ? string(e.ref.file) : basename(p), ':', line)
            println(io, "$(method_count). `$(sig)` at [$(text)]($(string(e.ref.file, '#', line)))\n")
        end
    end
    return method_count
end

# A store-backed TYPE'S constructors are not listed on hover, but a workspace
# extension of one (`Base.Dict(::P)` in a sibling) is otherwise invisible at
# the call site — surface those, mirroring the function-store rendering.
function _get_hover(d::SymbolServer.DataTypeStore, documentation::String, expr, env, meta_dict, rt=nothing, root=nothing)
    documentation = _store_doc_hover(d, documentation)
    (rt === nothing || root === nothing) && return documentation
    exts = _matching_workspace_extensions(rt, root, env, d)
    isempty(exts) && return documentation
    name = _store_name_symbol(d)
    io = IOBuffer()
    count = _workspace_extension_lines!(io, rt, exts, 0, string(name))
    return string(
        documentation,
        "\n\n`$(name)` is extended in the workspace with **$(count)** method$(count == 1 ? "" : "s")\n",
        String(take!(io))
    )
end

function _get_hover(f::SymbolServer.FunctionStore, documentation::String, expr, env, meta_dict, rt=nothing, root=nothing)
    if !isempty(f.doc)
        documentation = string(documentation, f.doc, "\n\n")
    end

    if !isnothing(env)
        edt = StaticLint.get_eventual_datatype(f, env)
        if edt isa SymbolServer.DataTypeStore
            documentation = string(_get_hover(edt, documentation, expr, env, meta_dict), "\n\n")
        end
    end

    if expr !== nothing && env !== nothing
        tls = _retrieve_toplevel_scope(expr, meta_dict)
        itr = func -> StaticLint.iterate_over_ss_methods(f, tls, env, func)
    else
        itr = func -> begin
            for m in f.methods
                func(m)
            end
        end
    end

    method_count = 0
    totalio = IOBuffer()
    itr() do m
        method_count += 1

        io = IOBuffer()
        print(io, m.name, "(")
        nsig = length(m.sig)
        for (i, sig) = enumerate(m.sig)
            if sig[1] ≠ Symbol("#unused#")
                print(io, sig[1])
            end
            print(io, "::", sig[2])
            i ≠ nsig && print(io, ", ")
        end
        print(io, ")")
        sig = String(take!(io))

        # Always produce URI-based links
        path = replace(m.file, "\\" => "\\\\")
        if isabspath(m.file)
            link = string(filepath2uri(m.file), "#", m.line)
            text = string(basename(path), ':', m.line)
        else
            text = string(path, ':', m.line)
            link = text
        end

        println(totalio, "$(method_count). `$(sig)` in `$(m.mod)` at [$(text)]($(link))\n")
        return false
    end

    # Workspace files can extend a store-backed function (`Base.relpath(::T)` in a
    # sibling). Those methods live in the per-file scope, not the env store, so
    # `iterate_over_ss_methods` misses them — add them from the module tree.
    if rt !== nothing && root !== nothing
        exts = _matching_workspace_extensions(rt, root, env, f)
        method_count = _workspace_extension_lines!(totalio, rt, exts, method_count, string(f.name))
    end

    documentation = string(
        documentation,
        "`$(f.name)` is a function with **$(method_count)** method$(method_count == 1 ? "" : "s")\n",
        String(take!(totalio))
    )

    return documentation
end

# --- Func/datatype hover for bindings referencing SymStore -------------------

_get_func_hover(x, documentation, expr, env, meta_dict) = documentation
_get_func_hover(x::SymbolServer.SymStore, documentation, expr, env, meta_dict) =
    _get_hover(x, documentation, expr, env, meta_dict)

# ============================================================================
# Closer hover (what does this `end`/`)`/`]` close?)
# ============================================================================

_get_closer_hover(x, documentation) = documentation
function _get_closer_hover(x::CSTParser.EXPR, documentation)
    if CSTParser.parentof(x) isa CSTParser.EXPR
        if CSTParser.headof(x) === :END
            if CSTParser.headof(CSTParser.parentof(x)) === :function
                documentation = string(documentation, "Closes function definition for `", CSTParser.to_codeobject(CSTParser.get_sig(CSTParser.parentof(x))), "`\n")
            elseif CSTParser.defines_module(CSTParser.parentof(x)) && length(CSTParser.parentof(x).args) > 1
                documentation = string(documentation, "Closes module definition for `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            elseif CSTParser.defines_struct(CSTParser.parentof(x))
                documentation = string(documentation, "Closes struct definition for `", CSTParser.to_codeobject(CSTParser.get_sig(CSTParser.parentof(x))), "`\n")
            elseif CSTParser.headof(CSTParser.parentof(x)) === :for && length(CSTParser.parentof(x).args) > 2
                documentation = string(documentation, "Closes for-loop expression over `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            elseif CSTParser.headof(CSTParser.parentof(x)) === :while && length(CSTParser.parentof(x).args) > 2
                documentation = string(documentation, "Closes while-loop expression over `", CSTParser.to_codeobject(CSTParser.parentof(x).args[2]), "`\n")
            else
                documentation = "Closes `$(CSTParser.headof(CSTParser.parentof(x)))` expression."
            end
        end
    end
    return documentation
end

# ============================================================================
# Function call position hover (argument N of M / datatype field)
# ============================================================================

_get_fcall_position(x, documentation, env, meta_dict, rt=nothing, root=nothing) = documentation

function _get_fcall_position(x::CSTParser.EXPR, documentation, env, meta_dict, rt=nothing, root=nothing, depth=0)
    # Guard against infinite loops via depth limit instead of Set{EXPR}
    depth > 100 && return documentation

    if CSTParser.parentof(x) isa CSTParser.EXPR
        if CSTParser.iscall(CSTParser.parentof(x))
            minargs, _, _ = StaticLint.call_nargs(CSTParser.parentof(x))
            arg_i = 0
            for (i, arg) in enumerate(CSTParser.parentof(x))
                if arg == x
                    arg_i = div(i - 1, 2)
                    break
                end
            end

            # hovering over the function name, so we might as well check the parent
            if arg_i == 0
                return _get_fcall_position(CSTParser.parentof(x), documentation, env, meta_dict, rt, root, depth + 1)
            end

            minargs < 4 && return documentation

            fname = CSTParser.get_name(CSTParser.parentof(x))
            fref = StaticLint.hasref(fname, meta_dict) ? StaticLint.refof(fname, meta_dict) : nothing
            # A cross-file callee resolves to a `TreeRef` (directly, or as a
            # file-local import binding's `.val`); its defining EXPR/method set
            # is materialized request-time via the inventory.
            ftree = fref isa StaticLint.TreeRef ? fref :
                (fref isa StaticLint.Binding && fref.val isa StaticLint.TreeRef) ? fref.val : nothing
            if fref isa StaticLint.Binding && fref.val isa CSTParser.EXPR && CSTParser.defines_struct(fref.val) && StaticLint.struct_nargs(fref.val, env, meta_dict)[1] == minargs
                dt_ex = fref.val
                args = dt_ex.args[3]
                args.args === nothing || arg_i > length(args.args) && return documentation
                _fieldname = CSTParser.str_value(CSTParser.get_arg_name(args.args[arg_i]))
                documentation = string("Datatype field `$_fieldname` of $(CSTParser.str_value(CSTParser.get_name(dt_ex)))", "\n", documentation)
            elseif fref isa SymbolServer.DataTypeStore || (fref isa StaticLint.Binding && fref.val isa SymbolServer.DataTypeStore)
                dts = fref isa StaticLint.Binding ? fref.val : fref
                if length(dts.fieldnames) == minargs && arg_i <= length(dts.fieldnames)
                    documentation = string("Datatype field `$(dts.fieldnames[arg_i])`", "\n", documentation)
                end
            elseif (fields = _tree_struct_field_hover(ftree, minargs, arg_i, env, rt, root)) !== nothing
                documentation = string(fields, "\n", documentation)
            else
                callname = if CSTParser.is_getfield(fname)
                    CSTParser.str_value(fname.args[1]) * "." * CSTParser.str_value(CSTParser.get_rhs_of_getfield(fname))
                else
                    CSTParser.str_value(fname)
                end
                arginfo = ftree === nothing ?
                    _resolve_call_arg_name(CSTParser.parentof(x), x, meta_dict, env) :
                    _resolve_tree_call_arg_name(CSTParser.parentof(x), x, ftree, rt, root)
                if arginfo === nothing
                    documentation = string("Argument $arg_i of $(minargs) in call to `", callname, "`\n", documentation)
                else
                    argname = arginfo.vararg ? string(arginfo.name, "...") : arginfo.name
                    documentation = string("Argument `", argname, "` ($arg_i of $(minargs)) in call to `", callname, "`\n", documentation)
                end
            end
            return documentation
        else
            return _get_fcall_position(CSTParser.parentof(x), documentation, env, meta_dict, rt, root, depth + 1)
        end
    end
    return documentation
end

# The datatype-field text for a cross-file struct constructor: materialize the
# struct's defining EXPR + its own file-analysis meta (so `struct_nargs` reads
# the declaring file's field bindings) and reproduce the local struct branch.
# Returns `nothing` when `tr` is not a same-arity tree struct (the caller then
# falls through to the general arg-name path).
function _tree_struct_field_hover(tr, minargs, arg_i, env, rt, root)
    (tr isa StaticLint.TreeRef && tr.item !== nothing && rt !== nothing && root !== nothing) || return nothing
    tr.kind in (:struct, :mutable_struct) || return nothing
    qroot = _method_items_root(rt, root, tr.origin_module)
    entry = get(derived_item_positions(rt, tr.item.file), tr.item.id, nothing)
    entry === nothing && return nothing
    dt_ex = entry.expr
    CSTParser.defines_struct(dt_ex) || return nothing
    defmeta = derived_file_analysis(rt, qroot, tr.item.file).meta
    StaticLint.struct_nargs(dt_ex, env, defmeta)[1] == minargs || return nothing
    args = dt_ex.args[3]
    (args.args === nothing || arg_i > length(args.args)) && return nothing
    fieldname = CSTParser.str_value(CSTParser.get_arg_name(args.args[arg_i]))
    return "Datatype field `$fieldname` of $(CSTParser.str_value(CSTParser.get_name(dt_ex)))"
end

# ============================================================================
# Top-level hover entry point (internal)
# ============================================================================

function _get_hover_text(rt, uri, index)
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst === nothing && return nothing

    root = derived_best_root_for_uri(rt, uri)
    if root !== nothing
        # Per-file analysis meta (the inventory architecture's per-file pass),
        # not the whole-closure static-lint meta: a name declared in a SIBLING
        # file is resolved here as a plain-data `TreeRef`, which the hover
        # rendering re-attaches to its inventory item + defining-file docstring
        # at the last mile. Same env selection as `derived_file_analysis`.
        project_uri = derived_project_uri_for_root(rt, root)
        meta_dict = derived_file_analysis(rt, root, uri).meta
        env = project_uri !== nothing ? derived_environment(rt, project_uri) : derived_stdlib_only_env(rt)
        path = derived_file_module_path(rt, root, uri)
    else
        meta_dict = _empty_hover_meta_dict
        env = _empty_hover_env
        path = nothing
    end

    offset = index - 1  # Convert 1-based string index to 0-based CSTParser offset
    x = get_expr1(cst, offset)

    x isa CSTParser.EXPR && CSTParser.isoperator(x) && _resolve_op_ref(x, env, meta_dict, rt, root, path)
    documentation = _get_hover(x, "", x, env, meta_dict, rt, root)
    documentation = _get_closer_hover(x, documentation)
    documentation = _get_fcall_position(x, documentation, env, meta_dict, rt, root)
    documentation = _sanitize_docstring(documentation)

    return isempty(documentation) ? nothing : documentation
end

# ============================================================================
# Word-based documentation search
# ============================================================================

function _doc_search_score(needle::Symbol, haystack::Symbol)
    needle === haystack && return 0.0
    needle_s = lowercase(string(needle))
    haystack_s = lowercase(string(haystack))
    ldist = Float64(REPL.levenshtein(needle_s, haystack_s))
    if startswith(haystack_s, needle_s)
        ldist *= 0.5
    end
    return ldist
end

_traverse_store!(_, _) = return
_traverse_store!(f, store::SymbolServer.EnvStore) = _traverse_store!.(f, values(store))
function _traverse_store!(f, store::SymbolServer.ModuleStore)
    for (sym, val) in store.vals
        f(sym, val)
        _traverse_store!(f, val)
    end
end

function _get_doc_from_word(rt, word::AbstractString)
    matches = Pair{Float64, String}[]
    needle = Symbol(word)

    # Collect all unique environments from workspace roots
    seen_envs = Set{UInt64}()
    envs = StaticLint.ExternalEnv[]
    for root in derived_roots(rt)
        project_uri = derived_project_uri_for_root(rt, root)
        project_uri === nothing && continue
        env = derived_environment(rt, project_uri)
        env === nothing && continue
        eid = objectid(env.symbols)
        eid in seen_envs && continue
        push!(seen_envs, eid)
        push!(envs, env)
    end

    # Fallback to stdlibs if no environments available
    if isempty(envs)
        push!(envs, _empty_hover_env)
    end

    for env in envs
        symbols = env.symbols
        # Also include stdlibs if not already in the env
        stores = isempty(symbols) ? [SymbolServer.stdlibs] : [symbols]

        for store in stores
            _traverse_store!(store) do sym, val
                score = _doc_search_score(needle, sym)
                if score < 2
                    hover_text = _get_hover(val, "", nothing, env, _empty_hover_meta_dict)
                    if !isempty(hover_text)
                        push!(matches, score => hover_text)
                    end
                end
            end
        end
    end

    if isempty(matches)
        return "No results found."
    else
        return join(map(x -> x.second, sort!(unique!(matches), by = x -> x.first)[1:min(end, 25)]), "\n---\n")
    end
end
