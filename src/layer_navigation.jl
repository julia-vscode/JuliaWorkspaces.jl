# Navigation layer
#
# Provides selection ranges, current block range, and module-at-position.
# All position parameters use 0-based byte offsets internally;
# result types expose Position values.

# ============================================================================
# Result types
# ============================================================================

struct SelectionRangeResult
    start::Position
    stop::Position
    parent::Union{Nothing,SelectionRangeResult}
end

struct BlockRangeResult
    block_start::Position
    highlight_start::Position
    highlight_stop::Position
    block_stop::Position
end

# ============================================================================
# Selection range
# ============================================================================

_get_selection_range_of_expr(x, runtime) = nothing
function _get_selection_range_of_expr(x::CSTParser.EXPR, runtime)
    loc = _get_file_loc(x, runtime)
    loc === nothing && return nothing
    uri, offset = loc
    parent_result = _get_selection_range_of_expr(x.parent, runtime)
    return SelectionRangeResult(_offset_to_position(runtime, uri, offset), _offset_to_position(runtime, uri, offset + x.span), parent_result)
end

"""
    _get_selection_ranges(runtime, uri, offsets)

For each offset (0-based) in `offsets`, compute a nested selection range.
"""
function _get_selection_ranges(runtime, uri::URI, offsets::Vector{Int})
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    results = Union{Nothing,SelectionRangeResult}[]
    for offset in offsets
        x = get_expr1(cst, offset)
        push!(results, _get_selection_range_of_expr(x, runtime))
    end
    return results
end

# ============================================================================
# Get current block range
# ============================================================================

"""
    _get_current_block_range(runtime, uri, offset)

Find the current top-level block at `offset` (0-based) in the file.
Returns a `BlockRangeResult` or `nothing`.
"""
function _get_current_block_range(runtime, uri::URI, offset::Int)
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    loc = 0

    CSTParser.headof(cst) === :file || return nothing

    _pos(o) = _offset_to_position(runtime, uri, o)

    for (i, a) in enumerate(cst)
        if loc <= offset <= loc + a.fullspan
            # Try next expression if current is NOTHING or we're in trailing whitespace
            # that wraps to a new line
            if !(loc <= offset <= loc + a.span) || CSTParser.headof(a) === :NOTHING
                if length(cst) > i
                    loc += a.fullspan
                    a = cst[i + 1]
                end
            end

            # Unwrap globalrefdoc macrocall wrapping a module
            if a.head === :macrocall && a.args[1].head === :globalrefdoc && length(a.args) == 4 && CSTParser.defines_module(a.args[4])
                for j in 1:3
                    loc += a.args[j].fullspan
                end
                a = a.args[4]
            end

            if CSTParser.defines_module(a)
                # Within module keyword — return entire expression
                if loc <= offset <= loc + a.trivia[1].span
                    return BlockRangeResult(_pos(loc), _pos(loc), _pos(loc + a.span), _pos(loc + a.fullspan))
                end
                # Within module name — return entire expression
                if loc + a.trivia[1].fullspan <= offset <= loc + a.trivia[1].fullspan + a.args[2].span
                    return BlockRangeResult(_pos(loc), _pos(loc), _pos(loc + a.span), _pos(loc + a.fullspan))
                end
                # Within module body
                if loc + a.trivia[1].fullspan + a.args[2].fullspan <= offset <= loc + a.trivia[1].fullspan + a.args[2].fullspan + a.args[3].span
                    body_offset = loc + a.trivia[1].fullspan + a.args[2].fullspan
                    for b in a.args[3].args
                        if body_offset <= offset <= body_offset + b.span
                            return BlockRangeResult(_pos(body_offset), _pos(body_offset), _pos(body_offset + b.span), _pos(body_offset + b.fullspan))
                        end
                        body_offset += b.fullspan
                    end
                end
                # Within `end` keyword — return entire expression
                if loc + a.trivia[1].fullspan + a.args[2].fullspan + a.args[3].fullspan < offset <= loc + a.trivia[1].fullspan + a.args[2].fullspan + a.args[3].fullspan + a.trivia[2].span
                    return BlockRangeResult(_pos(loc), _pos(loc), _pos(loc + a.span), _pos(loc + a.fullspan))
                end
            else
                return BlockRangeResult(_pos(loc), _pos(loc), _pos(loc + a.span), _pos(loc + a.fullspan))
            end
        end
        loc += a.fullspan
    end

    return nothing
end

# ============================================================================
# Get module at position
# ============================================================================

function _get_module_of(s::StaticLint.Scope, ms=String[])
    if CSTParser.defines_module(s.expr) && CSTParser.isidentifier(s.expr.args[2])
        pushfirst!(ms, StaticLint.valofid(s.expr.args[2]))
    end
    if CSTParser.parentof(s) isa StaticLint.Scope
        return _get_module_of(CSTParser.parentof(s), ms)
    else
        return isempty(ms) ? "Main" : join(ms, ".")
    end
end

"""
    _get_module_at(runtime, uri, offset)

Return the fully qualified module name at `offset` (0-based) in `uri`,
or "Main" if no module scope is found.
"""
function _get_module_at(runtime, uri::URI, offset::Int)
    cst = derived_julia_legacy_syntax_tree(runtime, uri)
    x, p = _get_expr_or_parent(cst, offset, 1)

    x isa CSTParser.EXPR || return "Main"

    # If we're on a module keyword/name/end, navigate to the parent module
    if x.head === :MODULE || x.head === :IDENTIFIER || x.head === :END
        if x.parent !== nothing && x.parent.head === :module
            x = x.parent
            if CSTParser.defines_module(x)
                x = x.parent
            end
        end
    end
    if CSTParser.defines_module(x) && p <= offset <= p + x[1].fullspan + x[2].fullspan
        x = x.parent
    end

    root = derived_best_root_for_uri(runtime, uri)
    root === nothing && return "Main"

    lint_result = derived_static_lint_meta_for_root(runtime, root)
    meta_dict = lint_result.meta_dict

    scope = _retrieve_scope(x, meta_dict)
    scope === nothing && return "Main"

    return _get_module_of(scope)
end
