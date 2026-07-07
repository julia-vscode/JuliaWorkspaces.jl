mutable struct Cursor
    leaves::Vector{Leaf}
    i::Int
    src::String
    # EXPR built for each consumed leaf (last leaf only for merged quotes);
    # lets forms locate the rightmost leaf of an already-assembled sibling.
    terminals::Vector{Union{Nothing,EXPR}}
    # leaf range consumed by each kid of the node currently in assemble_form
    kid_ranges::Vector{UnitRange{Int}}
    # width the current form excluded from its own leading edge (folded onto
    # a preceding leaf instead); assemble subtracts it from fullspan AND span
    # (a leading exclusion shifts both boundaries by the same amount).
    trim::Int
    # extra width to exclude from span ONLY, beyond `trim` — needed when a
    # dropped separator is the LAST leaf this node consumed (its own
    # meaningful width, `leaf.span`, would otherwise still count toward the
    # node's span even though the separator was folded away entirely; its
    # fullspan is already correctly included via the raw leaf range).
    trim_span::Int
    # extra width to ADD to span ONLY (never past fullspan) — trim_span's
    # symmetric counterpart, for forms whose oracle span extends past the
    # last real leaf's own span. Only known case: bare `return`, whose
    # synthetic zero-width NOTHING arg makes CSTParser measure span all the
    # way to fullspan, covering the keyword's trailing trivia. Same
    # lifecycle as trim/trim_span: set by a form, applied+reset by assemble.
    grow_span::Int
end

Cursor(leaves::Vector{Leaf}, i::Int, src::String) =
    Cursor(leaves, i, src, Vector{Union{Nothing,EXPR}}(nothing, length(leaves)), UnitRange{Int}[], 0, 0, 0)

const UNHANDLED_KINDS = Set{Kind}()

# Error-recovery safety net: a per-form branch's kid-dispatch loop can, on
# broken input, route an unexpected extra kid (e.g. a trailing marker for a
# missing `end`) into overwriting a single-slot field instead of keeping it
# — silently dropping that kid's width from the node's own children instead
# of just losing the kid itself. Mirrors check_spans' own childsum rule; when
# it would report a shortfall, pad it with a zero-content filler so spans
# stay tiled instead of desyncing. Gated on the green subtree actually
# containing an error node, so a childsum bug on VALID code still surfaces
# via check_spans instead of being silently padded over; the subtree-walking
# gate only runs when a gap exists, which never happens on valid code, so
# the non-error path pays nothing. Skips genuinely childless nodes (matrix
# cells), same rule as check_spans itself.
function patch_dropped_width!(ex::EXPR, node::GreenNode)
    ex.args === nothing && return ex
    has_children = !isempty(ex.args) ||
                   (ex.trivia !== nothing && !isempty(ex.trivia)) ||
                   ex.head isa EXPR
    has_children || return ex
    childsum = sum(c -> c.fullspan, ex.args; init=0) +
               (ex.trivia === nothing ? 0 : sum(c -> c.fullspan, ex.trivia; init=0)) +
               (ex.head isa EXPR ? ex.head.fullspan : 0)
    gap = ex.fullspan - childsum
    if gap > 0 && has_error_descendant(node)
        filler = EXPR(:errortoken, gap, 0, nothing)
        push!(ex.args, filler)
        CSTParser.setparent!(filler, ex)
    end
    return ex
end

function has_error_descendant(node::GreenNode)
    JuliaSyntax.is_error(kind(node)) && return true
    haschildren(node) || return false
    return any(has_error_descendant, children(node))
end

function assemble(node::GreenNode, cur::Cursor, is_cmdmacro_body::Bool=false)::EXPR
    if !haschildren(node)
        leaf = cur.leaves[cur.i]
        ex = terminal_expr(leaf, cur.src)
        cur.terminals[cur.i] = ex
        cur.i += 1
        return ex
    end
    k0 = kind(node)
    if k0 == K"char"
        # Quoted literals are open-quote/content/close-quote leaf triples in
        # the green tree, but CSTParser sees one CHAR token; consume the
        # whole run via the cursor instead of descending into children.
        expr, next_i = merge_quoted(cur.leaves, cur.i, cur.src, cur.i + leaf_count(node) - 1)
        cur.terminals[next_i - 1] = expr
        cur.i = next_i
        return expr
    elseif k0 == K"var"
        expr, next_i = merge_var(cur.leaves, cur.i, cur.src, cur.i + leaf_count(node) - 1)
        cur.terminals[next_i - 1] = expr
        cur.i = next_i
        return expr
    elseif k0 == K"string" || k0 == K"cmdstring"
        # Interpolation/triple-quote dedent/cmd-literal reconstruction; see
        # assemble_quoted for why this can't be a simple leaf-run merge.
        # assemble_quoted registers the close leaf's terminal itself (the
        # trailing chunk for interpolated strings, the whole literal
        # otherwise) so a `;`-fold widens the right node.
        expr = assemble_quoted(node, cur, k0 == K"cmdstring")
        expr = patch_dropped_width!(expr, node)
        if k0 == K"cmdstring" && !is_cmdmacro_body
            # Unprefixed backtick literal: 1.x emits the bare cmdstring node
            # with no wrapping macrocall at all (0.4 wrapped it in
            # macrocall[core_@cmd, cmdstring]); synthesize CSTParser's
            # :globalrefcmd macrocall wrapper ourselves. A prefixed literal
            # (`m\`c\``) is the cmdstring DIRECTLY following its
            # CmdMacroName sibling — already inside its own macrocall, no
            # extra wrap; a bare cmd used as a macro ARG still wraps.
            name = EXPR(:globalrefcmd, 0, 0, nothing)
            return EXPR(:macrocall, EXPR[name, EXPR(:NOTHING, 0, 0, nothing), expr],
                        EXPR[], expr.fullspan, expr.span)
        end
        return expr
    end
    first_i = cur.i
    kids = EXPR[]
    kkinds = Kind[]
    ranges = UnitRange{Int}[]
    prev_kind = K"TOMBSTONE"
    for c in children(node)
        is_ws_trivia(kind(c)) && continue
        s = cur.i
        push!(kids, assemble(c, cur, k0 == K"macrocall" && prev_kind == K"CmdMacroName"))
        push!(kkinds, kind(c))
        push!(ranges, s:cur.i-1)
        prev_kind = kind(c)
    end
    cur.kid_ranges = ranges   # inner assemble calls are done; safe to publish
    ex = assemble_form(kind(node), node, kids, kkinds, cur)
    # Spans from absolute leaf positions: independent of per-form layout.
    if cur.i > first_i
        first_leaf = cur.leaves[first_i]
        last_leaf = cur.leaves[cur.i - 1]
        ex.fullspan = (last_leaf.pos + last_leaf.fullspan) - first_leaf.pos
        ex.span = (last_leaf.pos + last_leaf.span) - first_leaf.pos
    end
    if cur.trim != 0 || cur.trim_span != 0
        ex.fullspan -= cur.trim
        ex.span = max(ex.span - cur.trim - cur.trim_span, 0)
        cur.trim = 0
        cur.trim_span = 0
    end
    if cur.grow_span != 0
        ex.span = min(ex.span + cur.grow_span, ex.fullspan)
        cur.grow_span = 0
    end
    patch_dropped_width!(ex, node)
    return ex
end

# Fallback: args = non-token children in source order, tokens into trivia.
# Wrong layout for anything CSTParser consumers pattern-match, but keeps the
# corpus runner alive and counts what still needs a real rule.
function generic_form(k::Kind, kids::Vector{EXPR}, kkinds::Vector{Kind})
    push!(UNHANDLED_KINDS, k)
    args = EXPR[]
    trivia = EXPR[]
    for (ex, ck) in zip(kids, kkinds)
        if JuliaSyntax.is_keyword(ck) || ex.head in (:LPAREN, :RPAREN, :COMMA,
            :LBRACE, :RBRACE, :LSQUARE, :RSQUARE, :SEMICOLON, :ATSIGN, :DOT)
            push!(trivia, ex)
        else
            push!(args, ex)
        end
    end
    EXPR(Symbol(lowercase(string(k))), args, trivia, 0, 0)
end
