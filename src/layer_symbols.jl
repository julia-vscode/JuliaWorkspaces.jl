# Document symbols and workspace symbols layer
#
# Provides document outline (document symbols) and workspace symbol search.
# Document symbols could potentially be @derived (cached) since they depend
# only on URI, CST, and meta_dict — not position.

# ============================================================================
# Result types
# ============================================================================

struct DocumentSymbolResult
    name::String
    kind::Int  # LSP SymbolKind integer
    start_offset::Int  # 0-based byte offset (converted to 1-based in public API)
    end_offset::Int    # 0-based byte offset
    children::Vector{DocumentSymbolResult}
end

struct WorkspaceSymbolResult
    name::String
    kind::Int
    uri::URI
    start_offset::Int  # 0-based byte offset
    end_offset::Int    # 0-based byte offset
end

# ============================================================================
# Binding name helpers
# ============================================================================

function _is_callable_object_binding(name::CSTParser.EXPR)
    CSTParser.isoperator(CSTParser.headof(name)) && CSTParser.valof(CSTParser.headof(name)) === "::" && length(name.args) >= 1
end

_is_valid_binding_name(name) = false
function _is_valid_binding_name(name::CSTParser.EXPR)
    (CSTParser.headof(name) === :IDENTIFIER && CSTParser.valof(name) isa String && !isempty(CSTParser.valof(name))) ||
    CSTParser.isoperator(name) ||
    (CSTParser.headof(name) === :NONSTDIDENTIFIER && length(name.args) == 2 && CSTParser.valof(name.args[2]) isa String && !isempty(CSTParser.valof(name.args[2]))) ||
    _is_callable_object_binding(name)
end

function _get_name_of_binding(name::CSTParser.EXPR)
    if CSTParser.headof(name) === :IDENTIFIER
        CSTParser.valof(name)
    elseif CSTParser.isoperator(name)
        string(CSTParser.to_codeobject(name))
    elseif CSTParser.headof(name) === :NONSTDIDENTIFIER
        CSTParser.valof(name.args[2])
    elseif _is_callable_object_binding(name)
        string(CSTParser.to_codeobject(name))
    else
        ""
    end
end

# ============================================================================
# Binding kind detection
# ============================================================================

struct _BindingContext
    is_function_def::Bool
    is_datatype_def::Bool
    is_datatype_def_body::Bool
end
_BindingContext() = _BindingContext(false, false, false)

function _binding_kind(b, ctx::_BindingContext)
    if b isa StaticLint.Binding
        if b.type === nothing
            if ctx.is_datatype_def_body && !ctx.is_function_def
                return 8   # Field
            elseif ctx.is_datatype_def
                return 26  # TypeParameter
            else
                return 13  # Variable
            end
        elseif b.type == StaticLint.CoreTypes.Module
            return 2   # Module
        elseif b.type == StaticLint.CoreTypes.Function
            return 12  # Function
        elseif b.type == StaticLint.CoreTypes.String
            return 15  # String
        elseif b.type == StaticLint.CoreTypes.Int || b.type == StaticLint.CoreTypes.Float64
            return 16  # Number
        elseif b.type == StaticLint.CoreTypes.DataType
            if ctx.is_datatype_def && !ctx.is_datatype_def_body
                return 23  # Struct
            else
                return 26  # TypeParameter
            end
        else
            return 13  # Variable
        end
    elseif b isa SymbolServer.ModuleStore
        return 2   # Module
    elseif b isa SymbolServer.MethodStore
        return 6   # Method
    elseif b isa SymbolServer.FunctionStore
        return 12  # Function
    elseif b isa SymbolServer.DataTypeStore
        return 23  # Struct
    else
        return 13  # Variable
    end
end

# ============================================================================
# Document symbols collection
# ============================================================================

function _collect_document_symbols(x::CSTParser.EXPR, meta_dict::MetaDict, pos=0, ctx=_BindingContext(), symbols=DocumentSymbolResult[])
    is_datatype_def_body = ctx.is_datatype_def_body
    if ctx.is_datatype_def && !is_datatype_def_body
        is_datatype_def_body = x.head === :block && length(x.parent.args) >= 3 && x.parent.args[3] == x
    end
    ctx = _BindingContext(
        ctx.is_function_def || CSTParser.defines_function(x),
        ctx.is_datatype_def || CSTParser.defines_datatype(x),
        is_datatype_def_body,
    )

    if StaticLint.bindingof(x, meta_dict) !== nothing
        b = StaticLint.bindingof(x, meta_dict)
        if b.val isa CSTParser.EXPR && _is_valid_binding_name(b.name)
            ds = DocumentSymbolResult(
                _get_name_of_binding(b.name),
                _binding_kind(b, ctx),
                pos,
                pos + x.span,
                DocumentSymbolResult[],
            )
            push!(symbols, ds)
            symbols = ds.children
        end
    elseif x.head == :macrocall
        # detect @testitem/testset "testname" ...
        child_nodes = filter(i -> !(isa(i, CSTParser.EXPR) && i.head == :NOTHING && i.args === nothing), x.args)
        if length(child_nodes) > 1
            macroname = CSTParser.valof(child_nodes[1])
            if macroname == "@testitem" || macroname == "@testset"
                if (child_nodes[2] isa CSTParser.EXPR && child_nodes[2].head == :STRING)
                    testname = CSTParser.valof(child_nodes[2])
                    ds = DocumentSymbolResult(
                        "$(macroname) \"$(testname)\"",
                        3, # Namespace
                        pos,
                        pos + x.span,
                        DocumentSymbolResult[],
                    )
                    push!(symbols, ds)
                    symbols = ds.children
                end
            end
        end
    end
    if length(x) > 0
        for a in x
            _collect_document_symbols(a, meta_dict, pos, ctx, symbols)
            pos += a.fullspan
        end
    end
    return symbols
end

# ============================================================================
# Workspace symbols collection
# ============================================================================

function _collect_toplevel_bindings_w_loc(x::CSTParser.EXPR, meta_dict::MetaDict, pos=0, bindings=Tuple{UnitRange{Int},StaticLint.Binding}[]; query="")
    b = StaticLint.bindingof(x, meta_dict)
    if b isa StaticLint.Binding && CSTParser.valof(b.name) isa String && b.val isa CSTParser.EXPR && startswith(CSTParser.valof(b.name), query)
        push!(bindings, (pos .+ (0:x.span), b))
    end
    s = StaticLint.scopeof(x, meta_dict)
    if s !== nothing && !(CSTParser.headof(x) === :file || CSTParser.defines_module(x))
        return bindings
    end
    if length(x) > 0
        for a in x
            _collect_toplevel_bindings_w_loc(a, meta_dict, pos, bindings, query=query)
            pos += a.fullspan
        end
    end
    return bindings
end

# ============================================================================
# Top-level entry points
# ============================================================================

"""
    _get_document_symbols(runtime, uri)

Collect all document symbols for the file identified by `uri`.
"""
function _get_document_symbols(runtime, uri::URI)
    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return DocumentSymbolResult[]

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict
    cst = derived_julia_legacy_syntax_tree(runtime, uri)

    return _collect_document_symbols(cst, meta_dict)
end

"""
    _get_workspace_symbols(runtime, query)

Search all files for top-level bindings matching `query`.
"""
function _get_workspace_symbols(runtime, query::String)
    results = WorkspaceSymbolResult[]
    files = derived_text_files(runtime)

    for uri in files
        root = derived_best_root_for_uri(runtime, uri)
        root === nothing && continue

        lint_result = derived_static_lint_meta_for_root(runtime, root)
        meta_dict = lint_result.meta_dict
        cst = derived_julia_legacy_syntax_tree(runtime, uri)

        bs = _collect_toplevel_bindings_w_loc(cst, meta_dict, query=query)
        for (rng, b) in bs
            push!(results, WorkspaceSymbolResult(
                CSTParser.valof(b.name),
                1, # SymbolKind.File (LS uses 1 for all workspace symbols)
                uri,
                first(rng),
                last(rng),
            ))
        end
    end

    return results
end
