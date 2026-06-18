# References layer
#
# Provides go-to-definition, find-references, rename, document highlight,
# and prepare-rename. All position parameters use 0-based byte offsets
# internally; result types expose Position values.

# ============================================================================
# Result types
# ============================================================================

struct DefinitionResult
    uri::URI
    start::Position
    stop::Position
end

struct ReferenceResult
    uri::URI
    start::Position
    stop::Position
end

struct RenameEdit
    uri::URI
    start::Position
    stop::Position
    new_text::String
end

struct HighlightResult
    start::Position
    stop::Position
    kind::Symbol      # :read or :write
end

# ============================================================================
# Shared helpers (used by multiple layers)
# ============================================================================

"""
    _get_identifier(x, offset, pos=0)

Walk a CSTParser EXPR tree and return the IDENTIFIER leaf whose span
covers `offset` (0-based byte offset). Returns `nothing` if no identifier
is found at that position.
"""
function _get_identifier(x, offset, pos=0)
    if pos > offset
        return nothing
    end
    if length(x) > 0
        for a in x
            if pos <= offset <= (pos + a.span)
                return _get_identifier(a, offset, pos)
            end
            pos += a.fullspan
        end
    elseif CSTParser.headof(x) === :IDENTIFIER && (pos <= offset <= (pos + x.span)) || pos == 0
        return x
    end
    return nothing
end

"""
    _get_expr_or_parent(x, offset, pos=0)

Like `_get_expr`, but only returns an expr if offset is strictly within its
span (not on the edge). If offset falls in trailing whitespace, returns the
parent instead.
"""
function _get_expr_or_parent(x, offset, pos=0)
    if pos > offset
        return nothing, pos
    end
    ppos = pos
    if length(x) > 0 && CSTParser.headof(x) !== :NONSTDIDENTIFIER
        for a in x
            if pos < offset <= (pos + a.fullspan)
                if pos < offset < (pos + a.span)
                    return _get_expr_or_parent(a, offset, pos)
                else
                    return x, ppos
                end
            end
            pos += a.fullspan
        end
    elseif pos == 0
        return x, pos
    elseif (pos < offset <= (pos + x.fullspan))
        if pos + x.span < offset
            return x.parent, ppos
        end
        return x, pos
    end
    return nothing, pos
end

"""
    _resolve_shadow_binding(b)

Follow shadow binding chains (where `b.val` is another `Binding`) with loop
detection.
"""
_resolve_shadow_binding(b) = b
function _resolve_shadow_binding(b::StaticLint.Binding, visited=StaticLint.Binding[])
    if b in visited
        return b  # break loop
    else
        push!(visited, b)
    end
    if b.val isa StaticLint.Binding
        return _resolve_shadow_binding(b.val, visited)
    else
        return b
    end
end

"""
    _get_file_loc(x::CSTParser.EXPR, runtime)

Return `(uri, offset)` for the given EXPR node by walking parents to the file
root and looking up the owning URI from the Salsa-memoized expr→URI mapping.
Returns `nothing` if the EXPR cannot be mapped to a file.
"""
function _get_file_loc(x::CSTParser.EXPR, runtime)
    root = x
    while CSTParser.parentof(root) !== nothing
        root = CSTParser.parentof(root)
    end
    CSTParser.headof(root) === :file || return nothing
    expr_uri_map = derived_expr_uri_map(runtime)
    uri = get(expr_uri_map, objectid(root), nothing)
    uri === nothing && return nothing
    _, offset = _descend(root, x)
    return (uri, offset)
end

"""
    _for_each_ref(f, identifier::CSTParser.EXPR, meta_dict, runtime)

For each loose reference of the binding that `identifier` refers to, call
`f(ref_expr, ref_uri, ref_offset)`. This is the core iteration backbone
shared by references, rename, and highlight.
"""
function _for_each_ref(f, identifier::CSTParser.EXPR, meta_dict::MetaDict, runtime)
    if StaticLint.hasref(identifier, meta_dict) && StaticLint.refof(identifier, meta_dict) isa StaticLint.Binding
        for r in StaticLint.loose_refs(StaticLint.refof(identifier, meta_dict), meta_dict)
            if r isa CSTParser.EXPR
                loc = _get_file_loc(r, runtime)
                if loc !== nothing
                    uri, o = loc
                    f(r, uri, o)
                end
            end
        end
    end
end

"""
    safe_isfile(s)

Safe version of `isfile` that handles invalid paths, null bytes, and IO errors.
"""
safe_isfile(s::Symbol) = safe_isfile(string(s))
safe_isfile(::Nothing) = false
function safe_isfile(s::AbstractString)
    try
        !occursin("\0", s) && isfile(s)
    catch err
        isa(err, Base.IOError) || isa(err, Base.SystemError) || rethrow()
        false
    end
end

# ============================================================================
# Go-to-definition
# ============================================================================

function _get_definitions_from_val(x, tls, env, results, runtime) end # fallback

function _get_definitions_from_val(x::SymbolServer.ModuleStore, tls, env, results, runtime)
    if haskey(x.vals, :eval) && x[:eval] isa SymbolServer.FunctionStore
        _get_definitions_from_val(x[:eval], tls, env, results, runtime)
    end
end

function _get_definitions_from_val(x::Union{SymbolServer.FunctionStore,SymbolServer.DataTypeStore}, tls, env, results, runtime)
    StaticLint.iterate_over_ss_methods(x, tls, env, function (m)
        if safe_isfile(m.file)
            pos = Position(m.line, 1)
            push!(results, DefinitionResult(
                URIs2.filepath2uri(string(m.file)),
                pos,
                pos
            ))
        end
        return false
    end)
end

function _get_definitions_from_val(b::StaticLint.Binding, tls, env, results, runtime)
    if !(b.val isa CSTParser.EXPR)
        _get_definitions_from_val(b.val, tls, env, results, runtime)
    end
    if b.type === StaticLint.CoreTypes.Function || b.type === StaticLint.CoreTypes.DataType
        for ref in b.refs
            method = StaticLint.get_method(ref)
            if method !== nothing
                _get_definitions_from_val(method, tls, env, results, runtime)
            end
        end
    elseif b.val isa CSTParser.EXPR
        _get_definitions_from_val(b.val, tls, env, results, runtime)
    end
end

function _get_definitions_from_val(x::CSTParser.EXPR, tls::StaticLint.Scope, env, results, runtime)
    loc = _get_file_loc(x, runtime)
    if loc !== nothing
        uri, o = loc
        push!(results, DefinitionResult(uri, _offset_to_position(runtime, uri, o), _offset_to_position(runtime, uri, o + x.span)))
    end
end

"""
    _get_definitions(runtime, uri, offset)

Core definition logic: find all definition locations for the expression at
`offset` (0-based) in the file identified by `uri`.
"""
function _get_definitions(runtime, uri::URI, offset::Int)
    results = DefinitionResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    project_uri = derived_project_uri_for_root(runtime, root)
    env = derived_environment(runtime, project_uri)

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)

    if x isa CSTParser.EXPR && StaticLint.hasref(x, meta_dict)
        b = StaticLint.refof(x, meta_dict)
        b = _resolve_shadow_binding(b)
        tls = _retrieve_toplevel_scope(x, meta_dict)
        tls === nothing && return results
        _get_definitions_from_val(b, tls, env, results, runtime)
    end

    return unique!(results)
end

# ============================================================================
# Find references
# ============================================================================

"""
    _get_references(runtime, uri, offset)

Find all references to the symbol at `offset` (0-based) in the file `uri`.
"""
function _get_references(runtime, uri::URI, offset::Int)
    results = ReferenceResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x === nothing && return results

    _for_each_ref(x, meta_dict, runtime) do ref, ref_uri, o
        push!(results, ReferenceResult(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span)))
    end

    return results
end

# ============================================================================
# Rename
# ============================================================================

"""
    _get_rename_edits(runtime, uri, offset, new_name)

Compute rename edits for the symbol at `offset` (0-based) in `uri`.
"""
function _get_rename_edits(runtime, uri::URI, offset::Int, new_name::String)
    results = RenameEdit[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x === nothing && return results

    _for_each_ref(x, meta_dict, runtime) do ref, ref_uri, o
        push!(results, RenameEdit(ref_uri, _offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span), new_name))
    end

    return results
end

# ============================================================================
# Prepare rename
# ============================================================================

"""
    _can_rename(runtime, uri, offset)

Check if the symbol at `offset` (0-based) can be renamed. Returns a named
tuple with `start::Position` and `stop::Position`, or `nothing`.
"""
function _can_rename(runtime, uri::URI, offset::Int)
    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return nothing

    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x = get_expr1(cst, offset)
    x isa CSTParser.EXPR || return nothing

    loc = _get_file_loc(x, runtime)
    loc === nothing && return nothing
    _, x_start = loc

    return (start=_offset_to_position(runtime, uri, x_start), stop=_offset_to_position(runtime, uri, x_start + x.span))
end

# ============================================================================
# Document highlight
# ============================================================================

"""
    _get_highlights(runtime, uri, offset)

Get all highlights (read/write) for the symbol at `offset` (0-based) in `uri`.
Only returns highlights within the same file.
"""
function _get_highlights(runtime, uri::URI, offset::Int)
    results = HighlightResult[]

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return results

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    identifier = _get_identifier(cst, offset)
    identifier === nothing && return results

    _for_each_ref(identifier, meta_dict, runtime) do ref, ref_uri, o
        if ref_uri == uri
            kind = StaticLint.hasbinding(ref, meta_dict) ? :write : :read
            push!(results, HighlightResult(_offset_to_position(runtime, ref_uri, o), _offset_to_position(runtime, ref_uri, o + ref.span), kind))
        end
    end

    return results
end
