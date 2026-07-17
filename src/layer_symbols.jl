# Document symbols and workspace symbols layer
#
# Provides document outline (document symbols) and workspace symbol search.
# Document symbols could potentially be @derived (cached) since they depend
# only on URI, CST, and meta_dict — not position.

# ============================================================================
# Result types
# ============================================================================

"""
    struct DocumentSymbolResult

A node in the document-outline tree (document symbols).

- `name::String`: Display name of the symbol.
- `kind::Int`: LSP `SymbolKind` integer.
- `start::Position`: Start of the symbol's range.
- `stop::Position`: End of the symbol's range.
- `children::Vector{DocumentSymbolResult}`: Nested symbols.
"""
struct DocumentSymbolResult
    name::String
    kind::Int  # LSP SymbolKind integer
    start::Position
    stop::Position
    children::Vector{DocumentSymbolResult}
end

"""
    struct WorkspaceSymbolResult

A single match returned by a workspace-wide symbol search.

- `name::String`: Display name of the symbol.
- `kind::Int`: LSP `SymbolKind` integer.
- `uri::URI`: File containing the symbol.
- `start::Position`: Start of the symbol's range.
- `stop::Position`: End of the symbol's range.
"""
struct WorkspaceSymbolResult
    name::String
    kind::Int
    uri::URI
    start::Position
    stop::Position
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

function _collect_document_symbols(x::CSTParser.EXPR, meta_dict::MetaDict, st::SourceText, pos=0, ctx=_BindingContext(), symbols=DocumentSymbolResult[])
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
                position_at(st, pos + 1),
                position_at(st, pos + x.span + 1),
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
                        position_at(st, pos + 1),
                        position_at(st, pos + x.span + 1),
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
            _collect_document_symbols(a, meta_dict, st, pos, ctx, symbols)
            pos += a.fullspan
        end
    end
    return symbols
end

# ============================================================================
# Workspace symbols collection
# ============================================================================

# Inventory item `kind` → LSP `SymbolKind` integer. Mirrors the value scheme
# `_binding_kind` uses for DOCUMENT symbols (Function=12, Struct=23, Module=2,
# Variable=13, …). The OLD workspace-symbols path hard-coded 1 (File) for every
# result (the LS never distinguished them); serving a real kind from the
# inventory is the improvement noted in the Task-8 change-list. The
# (name, uri, range) parity contract does NOT include kind.
function _item_symbol_kind(kind::Symbol)
    if kind === :function || kind === :macro
        return 12  # Function (LSP has no Macro kind)
    elseif kind === :struct || kind === :mutable_struct || kind === :abstract || kind === :primitive
        return 23  # Struct (mirrors _binding_kind's DataType → Struct)
    elseif kind === :enum
        return 10  # Enum
    elseif kind === :enum_member
        return 22  # EnumMember
    else
        # :const / :global / :assignment / anything else: the inventory carries
        # no inferred value type, so fall to Variable, exactly as _binding_kind
        # does for a typeless binding.
        return 13  # Variable
    end
end

# Match semantics mirror the OLD `startswith(name, query)` filter: case-SENSITIVE
# PREFIX (verified against `_collect_toplevel_bindings_w_loc`; NOT the
# case-insensitive substring the plan text guessed). One addition for the M4
# `@`-macro convention: macro items are `@`-spelled in the inventory ("@mymac"),
# whereas the old pass returned the bare name ("mymac"), so a bare query must
# still match — we additionally test the `@`-stripped name. Net effect: a macro
# is findable by BOTH "mymac" and "@mymac" (old found it by "mymac" only).
function _symbol_matches_query(name::AbstractString, query::AbstractString)
    isempty(query) && return true
    startswith(name, query) && return true
    startswith(name, "@") && startswith(SubString(name, 2), query) && return true
    return false
end

# Retained until Milestone 5 alongside the rest of the old whole-closure pass:
# no longer used in production (`_get_workspace_symbols` now reads the inventory
# directly), but the Task-8 parity tests reproduce the old output through it.
function _collect_toplevel_bindings_w_loc(x::CSTParser.EXPR, meta_dict::MetaDict, pos=0, bindings=Tuple{UnitRange{Int},StaticLint.Binding}[]; query="")
    b = StaticLint.bindingof(x, meta_dict)
    if b isa StaticLint.Binding && b.name isa CSTParser.EXPR && _is_valid_binding_name(b.name) &&
        b.val isa CSTParser.EXPR && startswith(_get_name_of_binding(b.name), query)
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

    # Per-file analysis meta (the inventories refactor) — the collection walk
    # below already collects top-level bindings of THIS file only (it stops at
    # non-file/non-module scopes), so it is already per-file semantics; only the
    # meta SOURCE changes. The per-file analysis runs over the same memoized CST
    # as `derived_julia_legacy_syntax_tree`, so objectids line up.
    meta_dict = derived_file_analysis(runtime, root, uri).meta
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    st = input_text_file(runtime, uri).content

    return _collect_document_symbols(cst, meta_dict, st)
end

"""
    _get_workspace_symbols(runtime, query)

Search all files for top-level bindings matching `query`.
"""
function _get_workspace_symbols(runtime, query::String)
    results = WorkspaceSymbolResult[]
    files = derived_text_files(runtime)

    for uri in files
        # Keep the OLD file gate (no-root files contribute nothing) — but never
        # run the whole-root static-lint pass. Re-expressing this over the
        # per-file inventory + position map is the point of the migration: the
        # old path executed `derived_static_lint_meta_for_root` (the WHOLE root
        # closure) once PER FILE, a real many-envs sweep cost.
        root = derived_best_root_for_uri(runtime, uri)
        root === nothing && continue

        inv = derived_file_inventory(runtime, uri)
        (isempty(inv.items) && isempty(inv.modules)) && continue
        positions = derived_item_positions(runtime, uri)

        for it in inv.items
            # `:opaque_macrocall` rows stand in for isolated-scope macrocalls
            # (`@testitem`/`@testset`/…); the old bindingof walk collected no
            # binding for those, so they are not workspace symbols.
            it.kind === :opaque_macrocall && continue
            _symbol_matches_query(it.name, query) || continue
            entry = get(positions, it.id, nothing)
            entry === nothing && continue
            push!(results, WorkspaceSymbolResult(
                it.name,
                _item_symbol_kind(it.kind),
                uri,
                _offset_to_position(runtime, uri, entry.offset),
                _offset_to_position(runtime, uri, entry.offset + entry.expr.span),
            ))
        end
        # Modules live in `inv.modules`, not `inv.items`; the old bindingof walk
        # collected module names as symbols, so include them to preserve that.
        for m in inv.modules
            _symbol_matches_query(m.name, query) || continue
            entry = get(positions, m.id, nothing)
            entry === nothing && continue
            push!(results, WorkspaceSymbolResult(
                m.name,
                2, # Module
                uri,
                _offset_to_position(runtime, uri, entry.offset),
                _offset_to_position(runtime, uri, entry.offset + entry.expr.span),
            ))
        end
    end

    return results
end
