# Default-value/kwarg `a=b` inside a call's arg list is `:kw`, not the
# operator-as-head binary form: repackage the already-assembled `=` EXPR
# (same leaf spans, just relabeled) into CSTParser's kw shape.
to_kw(ex::EXPR) = EXPR(:kw, ex.args, EXPR[ex.head], ex.fullspan, ex.span)

# Fold `width` onto the leaf at absolute leaf index `i` — often a trivia
# token like a closing paren/bracket, so args-walking can't find it — and
# onto every ancestor of that leaf via the parent chain, which ends exactly
# at the leaf's currently-unattached subtree root (enclosing nodes are not
# constructed yet). Only fullspans grow, never spans. Returns false when no
# EXPR exists for that leaf.
function widen_at_leaf!(cur::Cursor, i::Int, width::Int)
    node = i >= 1 ? cur.terminals[i] : nothing
    node === nothing && return false
    while node !== nothing
        # A node whose LAST arg is a zero-width marker (e.g. a bare `@m`
        # macrocall's NOTHING) AND which has no trailing trivia measures span
        # to fullspan; a `;` folded onto it extends span too. A node ending in
        # trailing trivia (e.g. a `try ... end`, span measured to END) keeps
        # the `;` as excluded trailing width even with an empty last arg.
        grow = node.args !== nothing && !isempty(node.args) &&
               node.args[end].fullspan == 0 && node.span == node.fullspan &&
               (node.trivia === nothing || isempty(node.trivia) ||
                !(node.trivia[end].head in (:END, :RPAREN, :RSQUARE, :RBRACE)))
        node.fullspan += width
        grow && (node.span += width)
        node = node.parent
    end
    return true
end

# Fold a dropped `;`'s width onto the last REAL leaf before it. Consecutive
# separators (`a;; b`) must skip already-dropped `;` leaves — their EXPRs
# live in neither args nor trivia, so widening one loses the width.
function fold_semi!(cur::Cursor, semi_i::Int, width::Int)
    i = semi_i - 1
    while i >= 1 && cur.leaves[i].kind == K";"
        i -= 1
    end
    return widen_at_leaf!(cur, i, width)
end

# Sibling `;` groups nest recursively: for `f(a; b; c)` the oracle stores
# the c-group inside the b-group at args[1]. Spans follow CSTParser's
# update_span convention — span measured to the last STORED arg, which
# after the relocation is not the source-last child. Zero-width empty
# groups (a bare extra `;`, e.g. `f(a;;b)`) collapse away entirely; only
# an all-empty run (`f(;;)`) keeps a single empty group.
function merge_params!(groups::Vector{EXPR})
    real = filter(g -> !isempty(g.args) || g.fullspan != 0, groups)
    isempty(real) && return groups[1]
    groups = real
    for i in length(groups)-1:-1:1
        outer, inner = groups[i], groups[i+1]
        insert!(outer.args, 1, inner)
        CSTParser.setparent!(inner, outer)
        outer.fullspan += inner.fullspan
        lastarg = outer.args[end]
        outer.span = outer.fullspan - (lastarg.fullspan - lastarg.span)
    end
    return groups[1]
end

# Zero-width absent-clause marker shared by try's catch/finally/else slots
# (val is the empty string, NOT nothing — differs from struct/module's
# TRUE/FALSE marker convention, oracle-pinned via dump).
false_arg() = EXPR(:FALSE, 0, 0, "")

# generator/filter compute span via `fullspan - (args[end].fullspan -
# args[end].span)` (CSTParser's own convention, same family as
# merge_params!'s), not the auto raw-leaf-bookend calc `assemble()` performs
# by default — the two coincide UNLESS args[end] itself already carries a
# trim_span-style correction (filter's own fix feeds into generator's).
# Corrects the auto calc via the existing trim_span field; needs no new
# span machinery since it's a pure arithmetic reconciliation of the two
# already-sanctioned formulas.
function trim_span_to_last_arg!(cur::Cursor, args::Vector{EXPR})
    isempty(args) && return
    last_leaf = cur.leaves[cur.i-1]
    a = args[end]
    cur.trim_span += (a.fullspan - a.span) - (last_leaf.fullspan - last_leaf.span)
end

# Symmetric counterpart of trim_span_to_last_arg! for the grow direction:
# CSTParser measures a keyword-trivia-less node's span to its last stored
# arg, so when that arg's trailing exclusion is SMALLER than the raw last
# leaf's (only known case: a bare `return`, whose span was grown to its
# fullspan), the node's span must grow by the difference. delta can never
# be negative here (an arg's trailing can only shrink relative to its own
# raw leaves, never grow).
function grow_span_to_last_arg!(cur::Cursor, args::Vector{EXPR})
    isempty(args) && return
    last_leaf = cur.leaves[cur.i-1]
    a = args[end]
    delta = (last_leaf.fullspan - last_leaf.span) - (a.fullspan - a.span)
    delta > 0 && (cur.grow_span += delta)
    return
end

# Sum of the OWN spans of a maximal trailing run of `;`-kind kids (e.g. the
# double `;;` promoting to the next ncat dimension) — every one of them
# folds away via fold_semi!, but assemble()'s automatic span calc still
# counts each dropped separator's own "meaningful" width since the raw
# leaf-range last leaf IS the final one of the run; trim_span excludes them.
function trailing_semi_span(kids::Vector{EXPR}, kkinds::Vector{Kind})
    total = 0
    for j in length(kkinds):-1:1
        kkinds[j] == K";" || break
        total += kids[j].span
    end
    return total
end

# Cell elements directly inside hcat/vcat/row/ncat/nrow get EMPTY args AND
# trivia vectors instead of `nothing` when they're bare terminals — an
# oracle-pinned CSTParser quirk exclusive to matrix-literal contexts
# (vect/ref/call arguments keep the normal `nothing`). Composite cells
# (already carrying real args/trivia) are untouched.
function matrix_cell!(ex::EXPR)
    # Bare terminals get empty args; every cell (bare or composite) whose
    # trivia is `nothing` gets an empty trivia vector — a cell that already
    # carries real trivia (e.g. `f(x)`'s parens) is left as-is.
    ex.args === nothing && (ex.args = EXPR[])
    ex.trivia === nothing && (ex.trivia = EXPR[])
    return ex
end

# 1.x wraps a getfield/qualified-macro field name in a K"quote" green child
# only when the source used an explicit `:` (`a.:b`); a bare atom (`a.b`,
# `a.begin`, `a."prop"`) or a bare `@`+MacroName pair (`a.@m`) arrives
# unwrapped. These two helpers synthesize the :quotenode/:quote shape
# CSTParser still expects, mirroring the K"quote" branch's own atom path.
function wrap_field_atom(inner::EXPR)::EXPR
    inner.head === :BEGIN && (inner.head = :IDENTIFIER)
    inner.head === :END && (inner.head = :IDENTIFIER)
    inner.head in (:STRING, :TRIPLESTRING) && return inner
    head = (inner.args === nothing || inner.head === :NONSTDIDENTIFIER) ? :quotenode : :quote
    # Transparent width: this wrapper adds no source characters of its own,
    # so it must inherit inner's span (assemble()'s automatic fullspan/span
    # fixup only applies to a form's own top-level return, not this kind of
    # freshly-synthesized nested wrapper).
    return EXPR(head, EXPR[inner], nothing, inner.fullspan, inner.span)
end

function fuse_field_macroname(atex::EXPR, nameex::EXPR, cur::Cursor, name_slot::Int)::EXPR
    if nameex.val isa String
        fused = EXPR(:IDENTIFIER, atex.fullspan + nameex.fullspan,
                    atex.span + nameex.span, "@" * nameex.val)
        # Register the fused name at its leaf slot so a later `;`-fold
        # (e.g. `(Base.@m; x)`) widens THIS EXPR, not the orphaned MacroName.
        cur.terminals[name_slot] = fused
        return EXPR(:quotenode, EXPR[fused], nothing, fused.fullspan, fused.span)
    end
    # Broken macro name (missing/errored) — can't fuse into one IDENTIFIER;
    # keep both pieces reachable instead.
    fused = EXPR(:errortoken, EXPR[atex, nameex], nothing,
                 atex.fullspan + nameex.fullspan, atex.span + nameex.span)
    return EXPR(:quotenode, EXPR[fused], nothing, fused.fullspan, fused.span)
end

# Shared by call/dotcall/curly/macrocall arg lists: split into positional
# args, bracket/comma trivia, and `;`-groups (still unmerged/unrelocated —
# each caller decides where the merged group lands); `a=b` becomes `:kw`.
function collect_arglist(kids::Vector{EXPR}, kkinds::Vector{Kind}, open::Kind, close::Kind; kw::Bool=true)
    args = EXPR[]
    trivia = EXPR[]
    groups = EXPR[]
    for (ex, ck) in zip(kids, kkinds)
        if ck == open || ck == close || ck == K","
            push!(trivia, ex)
        elseif ck == K"parameters"
            push!(groups, ex)
        elseif ck == K"=" && kw && ex.head isa EXPR && ex.head.val == "="
            # only a plain `=` kwarg converts to :kw; a dotted `.=` broadcast
            # assignment (same green kind K"=") stays operator-headed.
            push!(args, to_kw(ex))
        else
            push!(args, ex)
        end
    end
    return args, trivia, groups
end

function assemble_form(k::Kind, node::GreenNode, kids::Vector{EXPR}, kkinds::Vector{Kind}, cur::Cursor)::EXPR
    if k == K"toplevel"
        # Both the file root and semicolon-joined statement sequences share
        # this kind (build_cst renames the root's head to :file afterward).
        # Bare `;` separators are dropped entirely; their width folds onto
        # the rightmost leaf of the preceding statement (and that leaf's
        # ancestors), oracle-style.
        args = EXPR[]
        lead = 0
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K";"
                semi_i = first(cur.kid_ranges[j])
                if fold_semi!(cur, semi_i, ex.fullspan)
                    # Same span bookkeeping as a block: a leading `;` widens a
                    # leaf outside this node; a trailing `;` widens this node's
                    # own last leaf but was folded away, so drop it from span.
                    j == 1 && (cur.trim += ex.fullspan)
                    j == length(kids) && (cur.trim_span += ex.span)
                elseif isempty(args)
                    # A `;` at the very start of the file has no preceding
                    # statement: CSTParser materializes an empty NOTHING one.
                    lead += ex.fullspan
                else
                    args[end].fullspan += ex.fullspan
                end
            else
                push!(args, ex)
            end
        end
        lead > 0 && pushfirst!(args, EXPR(:NOTHING, lead, lead, ""))
        # File/toplevel span is measured to the last stored arg (the outer
        # file root wraps an inner toplevel, so a trailing `;` or bare
        # `return` shows up as a span mismatch here); reconcile both
        # directions. Skip when the last kid was a dropped `;` (its own
        # trim_span above already owns that case).
        !isempty(args) && kkinds[end] != K";" && trim_span_to_last_arg!(cur, args)
        return EXPR(:toplevel, args, EXPR[], 0, 0)
    elseif k == K"call" && JuliaSyntax.is_infix_op_call(JuliaSyntax.head(node))
        # a + b (+ c ...) → (:call, [op, a, b, c...]); extra op tokens → trivia
        op = kids[2]
        # Word operators (isa/in/where) used as the callee of a real infix
        # call reclassify to plain Identifier in 1.x (same normalization as
        # +/-/==/etc.); the INFIX_FLAG on this node is authoritative that
        # it's semantically an operator regardless of the leaf's own kind.
        op.head === :IDENTIFIER && (op.head = :OPERATOR)
        args = EXPR[op, kids[1]]
        trivia = EXPR[]
        for j in 3:length(kids)
            if isodd(j)
                push!(args, kids[j])
            else
                push!(trivia, kids[j])   # repeated ops in chained calls
            end
        end
        return EXPR(:call, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"call" && JuliaSyntax.is_postfix_op_call(JuliaSyntax.head(node)) && length(kids) == 2
        # x' (postfix adjoint) → operator-headed EXPR (kids=[operand, op]),
        # unlike prefix calls (-x/!x) which stay :call-symbol-headed with the
        # operator as a plain leading arg.
        return EXPR(kids[2], EXPR[kids[1]], nothing, 0, 0)
    elseif k == K"call" && JuliaSyntax.is_prefix_op_call(JuliaSyntax.head(node)) &&
           length(kids) == 2 && kkinds[2] == K"parens" &&
           !(kids[1].val in ("-", "!", "~"))
        # `+(x)` — a prefix operator applied to a parenthesized single argument
        # is a normal function call of the operator: unwrap the parens so `x`
        # is the arg and the parens become the call's trivia. CSTParser keeps
        # `-`/`!`/`~` as genuine unary applications of the bracketed operand.
        op, parens = kids[1], kids[2]
        args = EXPR[op]
        append!(args, parens.args)
        return EXPR(:call, args, parens.trivia, 0, 0)
    elseif k == K"call" && kids[1].head === :OPERATOR && kids[1].val in ("-", "!", "~") &&
           length(kids) == 4 && kkinds[2] == K"(" && kkinds[3] != K"," && kkinds[4] == K")"
        # `macro -(ex)` / `function -(x)` — `-`/`!`/`~` applied to a single
        # directly-parenthesized operand keeps it as a :brackets (unlike other
        # prefix operators, which unwrap). The green tree here has the parens
        # as direct children (no K"parens" wrapper), so synthesize the brackets.
        op, lp, inner, rp = kids
        fs = lp.fullspan + inner.fullspan + rp.fullspan
        brackets = EXPR(:brackets, EXPR[inner], EXPR[lp, rp], fs, fs - (rp.fullspan - rp.span))
        return EXPR(:call, EXPR[op, brackets], nothing, 0, 0)
    elseif k == K"juxtapose"
        # 2x / 2(x+1) → implicit multiplication; CSTParser synthesizes a
        # zero-width `*` operator since juxtaposition has no real op leaf.
        # 3+ factors (`4A'B'`) nest right: `4 * (A' * B')`.
        acc = kids[end]
        for i in length(kids)-1:-1:1
            fs = kids[i].fullspan + acc.fullspan
            acc = EXPR(:call, EXPR[EXPR(:OPERATOR, 0, 0, "*"), kids[i], acc],
                       nothing, fs, fs - (acc.fullspan - acc.span))
        end
        return acc
    elseif k == K"comparison"
        # a < b < c → flat (:comparison, [a, op, b, op, c, ...]) — kids are
        # already in this exact order/shape. Dotted comparison operators
        # (`a .== b`) arrive as a K"." composite (dot+op leaves); fuse each
        # into one OPERATOR leaf (val ".==") like CSTParser does.
        args = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"." && ex.head isa EXPR && ex.args !== nothing &&
               length(ex.args) == 1 && ex.args[1].head === :OPERATOR
                # dotted comparison operator (`.==`); NOT a getfield `.x`
                # (which has two args ending in a quotenode).
                push!(args, EXPR(:OPERATOR, ex.fullspan, ex.span,
                                 ex.head.val * ex.args[1].val))
            else
                # Word operators (`isa`/`in`/`where`) in an operator slot
                # (even position) tokenize as Identifier but label OPERATOR.
                iseven(j) && ex.head === :IDENTIFIER &&
                    ex.val in ("where", "in", "isa") && (ex.head = :OPERATOR)
                push!(args, ex)
            end
        end
        return EXPR(:comparison, args, nothing, 0, 0)
    elseif k == K"call" && !isempty(kkinds) && kkinds[end] == K"do"
        # `f(x) do y ... end`: 1.x nests the do-block as this call's own
        # last child (0.4 had it inverted, a K"do" node wrapping the call)
        # — reunite the call target (this node's own kids minus the
        # trailing do-node, built the same way the plain K"call" branch
        # below does) with the do-body carrier the K"do" branch packaged.
        do_partial = kids[end]
        call_kids, call_kkinds = kids[1:end-1], kkinds[1:end-1]
        args, trivia, groups = collect_arglist(call_kids, call_kkinds, K"(", K")")
        isempty(groups) || insert!(args, 2, merge_params!(groups))
        if kkinds[1] == K"." && args[1].head isa EXPR && args[1].head.val == "." &&
           args[1].args !== nothing && length(args[1].args) == 1 &&
           args[1].args[1].head === :OPERATOR
            di = args[1]
            args[1] = EXPR(:OPERATOR, di.fullspan, di.span, di.head.val * di.args[1].val)
        end
        call_fs = sum(x -> x.fullspan, call_kids; init=0)
        call_sp = call_fs - (call_kids[end].fullspan - call_kids[end].span)
        call_ex = EXPR(:call, args, isempty(trivia) ? nothing : trivia, call_fs, call_sp)
        return EXPR(:do, EXPR[call_ex, do_partial.args[1]], do_partial.trivia, 0, 0)
    elseif k == K"call"
        # f(x, y) → (:call, [f, x, y], trivia=[lparen, commas..., rparen]).
        # `;`-separated keyword args nest under a `parameters` child at their
        # source position but the oracle always relocates it to args[2],
        # right after the callee (kids[1], which lands in args[1] here since
        # it matches none of collect_arglist's special cases); `a=b`
        # positional args become `:kw`.
        # Pre-existing gap found via corpus probing: a parenless prefix-op
        # call (`!x`, no LPAREN/RPAREN at all) never populates trivia, so it
        # stayed the initial empty Vector{EXPR} instead of `nothing`.
        args, trivia, groups = collect_arglist(kids, kkinds, K"(", K")")
        isempty(groups) || insert!(args, 2, merge_params!(groups))
        # A dotted-operator callee (`.+(a, b)`) arrives as a K"." composite
        # (dot+op leaves); fuse it into one OPERATOR leaf.
        if kkinds[1] == K"." && args[1].head isa EXPR && args[1].head.val == "." &&
           args[1].args !== nothing && length(args[1].args) == 1 &&
           args[1].args[1].head === :OPERATOR
            di = args[1]
            args[1] = EXPR(:OPERATOR, di.fullspan, di.span, di.head.val * di.args[1].val)
        end
        return EXPR(:call, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"dotcall" && JuliaSyntax.is_infix_op_call(JuliaSyntax.head(node))
        # a .+ b (.+ c ...) → dotted infix broadcast; JuliaSyntax keeps `.`
        # and the operator as TWO separate leaves (unlike macrocall's `@name`
        # fusion precedent, but the same fold: sum fullspan/span, concat
        # val), then reuses the plain infix-call shape (:call, [op, a, b,...]).
        lhs = kids[1]
        args = EXPR[]
        trivia = EXPR[]
        j = 2
        first_op = true
        while j < length(kids)
            dotex, opex = kids[j], kids[j+1]
            fused = EXPR(:OPERATOR, dotex.fullspan + opex.fullspan,
                        dotex.span + opex.span, dotex.val * opex.val)
            if first_op
                args = EXPR[fused, lhs]
                first_op = false
            else
                push!(trivia, fused)
            end
            j += 2
            push!(args, kids[j])
            j += 1
        end
        return EXPR(:call, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"dotcall" && JuliaSyntax.is_prefix_op_call(JuliaSyntax.head(node))
        # .!x → dotted prefix broadcast; same `.`+op fusion, single operand.
        # `.+(x)` — a parenthesized operand unwraps to a call (parens →
        # trivia), like the non-dotted `+(x)` path; unlike `-`/`!`/`~`,
        # dotted operators have NO keep-brackets exception.
        dotex, opex, operand = kids[1], kids[2], kids[3]
        fused = EXPR(:OPERATOR, dotex.fullspan + opex.fullspan,
                    dotex.span + opex.span, dotex.val * opex.val)
        if kkinds[3] == K"parens"
            args = EXPR[fused]
            append!(args, operand.args)
            return EXPR(:call, args, operand.trivia, 0, 0)
        end
        return EXPR(:call, EXPR[fused, operand], nothing, 0, 0)
    elseif k == K"dotcall"
        # f.(x, y) → (:., [f, tuple(x, y)]); the parenthesized arg list packs
        # into a :tuple the same way a call's does (parameters relocate to
        # its front — there's no callee slot to land after).
        callee, dot = kids[1], kids[2]
        sub = kids[3:end]
        args, trivia, groups = collect_arglist(sub, kkinds[3:end], K"(", K")")
        isempty(groups) || insert!(args, 1, merge_params!(groups))
        # Synthetic :tuple node — not a return value of assemble_form, so its
        # span isn't computed automatically; sum the pre-partition kids
        # (widths only move between them via merge_params!/to_kw, never
        # change) and exclude the trailing edge (always the RPAREN).
        fullspan = sum(x -> x.fullspan, sub; init=0)
        span = fullspan - (sub[end].fullspan - sub[end].span)
        tup = EXPR(:tuple, args, trivia, fullspan, span)
        return EXPR(dot, EXPR[callee, tup], nothing, 0, 0)
    elseif k == K"." && length(kids) >= 3 && kkinds[2] == K"."
        # a.b / a.b.c / a.:b / a.begin / a."prop" / a.@m x → (:., [a, field]);
        # dot is operator-headed like ::/<:/->. 1.x wraps the field-name side
        # in a K"quote" child only when the source used an explicit `:`
        # (`a.:b`); a bare atom (or a bare `@`+MacroName pair for `a.@m`)
        # needs the :quotenode/:quote wrap synthesized here instead.
        field = if kkinds[3] == K"quote"
            kids[3]
        elseif length(kids) == 4 && kkinds[3] == K"@"
            fuse_field_macroname(kids[3], kids[4], cur, first(cur.kid_ranges[4]))
        elseif kkinds[3] == K"$"
            # `a.$f` — interpolated field name (0.4 wrapped this in K"inert",
            # 1.x drops that indirection); kids[3] is already the converted
            # `$`-operator-headed EXPR, just needs the :quotenode wrap.
            EXPR(:quotenode, EXPR[kids[3]], nothing, kids[3].fullspan, kids[3].span)
        else
            wrap_field_atom(kids[3])
        end
        return EXPR(kids[2], EXPR[kids[1], field], nothing, 0, 0)
    elseif k == K"." && length(kids) == 4 && kkinds[1] == K"@"
        # @m.n x: a dotted/qualified macro name — the LHS itself is an
        # unfused `@`+name pair (same fusion as macrocall's own @+name, and
        # as the branch above does for the A.@m x case where the `@` sits on
        # the RHS instead). The RHS MacroName arrives as a bare atom in 1.x
        # (no K"quote" wrapper unless colon-prefixed), same wrap as above.
        atex, nameex, dotex, rhsraw = kids
        lhs = if nameex.val isa String
            EXPR(:IDENTIFIER, atex.fullspan + nameex.fullspan,
                 atex.span + nameex.span, "@" * nameex.val)
        else
            # Broken macro name (missing/errored) — can't fuse into one
            # IDENTIFIER; keep both pieces reachable instead.
            EXPR(:errortoken, EXPR[atex, nameex], nothing,
                 atex.fullspan + nameex.fullspan, atex.span + nameex.span)
        end
        rhs = kkinds[4] == K"quote" ? rhsraw : wrap_field_atom(rhsraw)
        return EXPR(dotex, EXPR[lhs, rhs], nothing, 0, 0)
    elseif k == K"quote"
        # Three shapes share this kind:
        #  (a) block form `quote ... end` → :quote wrapping the body block;
        #      quote/end keywords are held in the block's trivia (block
        #      branch) and lift up to the :quote node, the inner block keeps
        #      only its statements.
        #  (b) getfield field-name (`.b`, `.:b`, `.@m`) → :quotenode.
        #  (c) `:x`/`:(expr)` → :quotenode for a quoted atom (incl. a
        #      single-atom `:(x)`), :quote for a quoted composite —
        #      CSTParser's parse_quote split.
        if length(kids) == 1 && kkinds[1] == K"block"
            blk = kids[1]
            qkw = ekw = nothing
            for t in (blk.trivia === nothing ? EXPR[] : blk.trivia)
                t.head === :QUOTE && (qkw = t)
                t.head === :END && (ekw = t)
            end
            fs = sum(a -> a.fullspan, blk.args; init=0)
            sp = isempty(blk.args) ? 0 : fs - (blk.args[end].fullspan - blk.args[end].span)
            inner = EXPR(:block, blk.args, nothing, fs, sp)
            # qkw/ekw can be absent for malformed input; filter out nothings.
            qtriv = EXPR[t for t in (qkw, ekw) if t !== nothing]
            return EXPR(:quote, EXPR[inner], qtriv, 0, 0)
        end
        if kkinds[1] == K"@"
            atex, nameex = kids
            if nameex.val isa String
                fused = EXPR(:IDENTIFIER, atex.fullspan + nameex.fullspan,
                            atex.span + nameex.span, "@" * nameex.val)
                # Register the fused name at its leaf slot so a `;`-fold onto
                # a qualified macrocall (`(Base.@m; x)`) widens THIS EXPR.
                cur.terminals[first(cur.kid_ranges[2])] = fused
                return EXPR(:quotenode, EXPR[fused], nothing, 0, 0)
            end
            # Broken macro name (missing/errored) — can't fuse into one
            # IDENTIFIER; keep both pieces reachable instead.
            fused = EXPR(:errortoken, EXPR[atex, nameex], nothing,
                         atex.fullspan + nameex.fullspan, atex.span + nameex.span)
            return EXPR(:quotenode, EXPR[fused], nothing, 0, 0)
        end
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K":" ? push!(trivia, ex) : push!(args, ex)
        end
        # A quoted dotted operator (`:.&`, `:(.=)`) arrives as a K"." composite
        # (dot+op leaves); fuse it into one OPERATOR leaf, either directly or
        # inside a single-item brackets.
        fuse_dotop(ex) = (ex.head isa EXPR && ex.head.val == "." && ex.args !== nothing &&
                          length(ex.args) == 1 && ex.args[1].head === :OPERATOR) ?
            EXPR(:OPERATOR, ex.fullspan, ex.span, ex.head.val * ex.args[1].val) : ex
        args[1] = fuse_dotop(args[1])
        # Inside parens, only a dotted assignment (`:(.=)`) fuses to an
        # OPERATOR atom; a dotted broadcast operator (`:(.+)`) stays a
        # composite (a broadcast call), so it remains a :quote.
        is_assign(v) = endswith(v, "=") &&
            (length(v) == 1 || !(v[prevind(v, lastindex(v))] in ('=', '!', '<', '>')))
        if args[1].head === :brackets && args[1].args !== nothing &&
           length(args[1].args) == 1 && args[1].args[1].head isa EXPR &&
           args[1].args[1].args !== nothing && !isempty(args[1].args[1].args) &&
           args[1].args[1].args[1].head === :OPERATOR && is_assign(args[1].args[1].args[1].val)
            args[1].args[1] = fuse_dotop(args[1].args[1])
        end
        inner = args[1]
        # A quoted string field name (`a."prop"`) is used directly as the
        # getfield RHS — no :quotenode wrapper.
        if isempty(trivia) && inner.head in (:STRING, :TRIPLESTRING)
            return inner
        end
        # Word operators (`:where`/`:in`/`:isa`) tokenize as Identifier after
        # a quote colon, but CSTParser labels them OPERATOR. Only when the
        # quote is colon-prefixed — a bare getfield field name (`p.in`) stays
        # an IDENTIFIER.
        if K":" in kkinds && inner.head === :IDENTIFIER &&
           inner.val in ("where", "in", "isa")
            inner.head = :OPERATOR
        end
        # `begin`/`end` map to BEGIN/END in index context (terminal_expr),
        # but as a quoted field/symbol (`a.begin`, `a.end`, `:begin`) they
        # are IDENTIFIER.
        inner.head === :BEGIN && (inner.head = :IDENTIFIER)
        inner.head === :END && (inner.head = :IDENTIFIER)
        target = (inner.head === :brackets && inner.args !== nothing &&
                  length(inner.args) == 1) ? inner.args[1] : inner
        # atoms → :quotenode, composites → :quote; a var"..." nonstandard
        # identifier counts as an atom.
        head = (target.args === nothing || target.head === :NONSTDIDENTIFIER) ?
               :quotenode : :quote
        return EXPR(head, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"curly"
        # A{T; S} → (:curly, [A, parameters, T]) — parameters relocates to
        # args[2] exactly like call's.
        args, trivia, groups = collect_arglist(kids, kkinds, K"{", K"}")
        isempty(groups) || insert!(args, 2, merge_params!(groups))
        return EXPR(:curly, args, trivia, 0, 0)
    elseif k == K"tuple"
        if length(kids) == 1 && kkinds[1] != K";"
            # Paren-less single-element tuple: 1.x's uniform node kind for a
            # `->` LHS param regardless of spelling (`x -> ...` vs
            # `(x) -> ...`), and for a `do y ... end` single-param list; the
            # bare form has no bracket/comma kids at all (a real 1-tuple
            # `(x,)` always keeps its parens+comma kids). The oracle keeps a
            # do-param list as a :tuple (empty trivia) but a bare `->` LHS
            # as the plain identifier — trivia === nothing marks the bare
            # form so each consumer can tell (a bracketed tuple always has
            # paren/comma trivia): `do` normalizes it to EXPR[], `->`
            # unwraps it. Excludes the bare `;` placeholder of a no-params
            # `do; ... end` (still needs the regular :tuple path below, so
            # the K"do" branch's SEMICOLON check keeps working).
            return EXPR(:tuple, kids, nothing, kids[1].fullspan, kids[1].span)
        end
        # `(a, :b)` → (:tuple, [args], trivia=[parens, commas]); a named-tuple
        # field (`(a=b,)`) keeps `=` as assignment (not `:kw`); `;`-parameters
        # (`(; a=1)`) relocate to the front and keep their own `:kw` shape.
        args, trivia, groups = collect_arglist(kids, kkinds, K"(", K")"; kw=false)
        isempty(groups) || insert!(args, 1, merge_params!(groups))
        return EXPR(:tuple, args, trivia, 0, 0)
    elseif k == K"vect"
        # A `[a=b]` element keeps `=` as assignment (not `:kw`), like a tuple.
        args, trivia, groups = collect_arglist(kids, kkinds, K"[", K"]"; kw=false)
        isempty(groups) || insert!(args, 1, merge_params!(groups))
        return EXPR(:vect, args, trivia, 0, 0)
    elseif k == K"braces"
        args, trivia, groups = collect_arglist(kids, kkinds, K"{", K"}")
        isempty(groups) || insert!(args, 1, merge_params!(groups))
        return EXPR(:braces, args, trivia, 0, 0)
    elseif k == K"ref"
        # `a[i, j]` → (:ref, [callee, indices...], trivia=[brackets, commas]).
        callee = kids[1]
        args, trivia, groups = collect_arglist(kids[2:end], kkinds[2:end], K"[", K"]")
        isempty(groups) || insert!(args, 1, merge_params!(groups))
        return EXPR(:ref, EXPR[callee, args...], trivia, 0, 0)
    elseif k == K"typed_comprehension"
        # `T[gen]` → (:typed_comprehension, [T, generator], trivia=[brackets]).
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"[" || ck == K"]") ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:typed_comprehension, args, trivia, 0, 0)
    elseif k == K"typed_hcat"
        # `T[a b]` → (:typed_hcat, [T, cells...], trivia=[brackets]).
        typ = kids[1]
        trivia = EXPR[kids[2], kids[end]]
        cells = kids[3:end-1]
        length(cells) >= 2 && foreach(matrix_cell!, cells)
        return EXPR(:typed_hcat, EXPR[typ, cells...], trivia, 0, 0)
    elseif k == K"typed_vcat"
        # `T[1; 2]` / `T[1 2; 3 4]` → (:typed_vcat, [T, rows-or-cells...]),
        # same `;`-fold + matrix-cell quirk as vcat, T prepended.
        typ = kids[1]
        trivia = EXPR[]
        args = EXPR[]
        cells = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if j == 1
                continue
            elseif ck == K"[" || ck == K"]"
                push!(trivia, ex)
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(args) || (args[end].fullspan += ex.fullspan))
            elseif ck == K"row"
                push!(args, ex)
            else
                push!(args, ex)
                push!(cells, ex)
            end
        end
        length(args) >= 2 && foreach(matrix_cell!, cells)
        return EXPR(:typed_vcat, EXPR[typ, args...], trivia, 0, 0)
    elseif k == K"typed_ncat"
        # `T[1;; 2]` → typed_vcat plus the ncat dim marker after the type.
        dim = JuliaSyntax.numeric_flags(JuliaSyntax.flags(node))
        typ = kids[1]
        trivia = EXPR[]
        rest = EXPR[]
        cells = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if j == 1
                continue
            elseif ck == K"[" || ck == K"]"
                push!(trivia, ex)
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(rest) || (rest[end].fullspan += ex.fullspan))
            elseif ck == K"nrow"
                push!(rest, ex)
            else
                push!(rest, ex)
                push!(cells, ex)
            end
        end
        length(rest) >= 2 && foreach(matrix_cell!, cells)
        args = EXPR[typ, EXPR(Symbol(string(dim)), 0, 0, ""), rest...]
        return EXPR(:typed_ncat, args, trivia, 0, 0)
    elseif k == K"macrocall"
        # `@m x` fuses the `@` leaf and macro name into ONE IDENTIFIER
        # ("@m") — CSTParser never sees them as separate tokens. String/cmd
        # macro names (`m"str"`) are already a single mangled leaf (handled
        # in terminal_expr), nothing to fuse. A synthetic zero-width NOTHING
        # marker always follows the name; `;`-parameters relocate to right
        # after it (args[3]).
        # `@recipe(A) do scene ... end`: 1.x nests the do-node as this
        # macrocall's own last child (same inversion as call+do); split it
        # off, build the macrocall from the rest, and wrap in :do at the end.
        do_partial = nothing
        if kkinds[end] == K"do"
            do_partial = kids[end]
            mac_fs = sum(x -> x.fullspan, kids[1:end-1]; init=0)
            mac_sp = mac_fs - (kids[end-1].fullspan - kids[end-1].span)
            kids, kkinds = kids[1:end-1], kkinds[1:end-1]
        end
        if kkinds[1] == K"@"
            atex, nameex = kids[1], kids[2]
            if nameex.val isa String
                name = EXPR(:IDENTIFIER, atex.fullspan + nameex.fullspan,
                            atex.span + nameex.span, "@" * nameex.val)
                # Register the fused name at its leaf slot so a later `;`-fold
                # (e.g. `:(@m; x)`) widens THIS EXPR, not the orphaned MacroName.
                cur.terminals[first(cur.kid_ranges[2])] = name
            else
                # Broken macro name (missing/errored, e.g. `x = @`): can't
                # fuse `@`+name into one IDENTIFIER — keep both pieces so
                # spans still tile and the error stays traversable.
                name = EXPR(:errortoken, EXPR[atex, nameex], nothing,
                             atex.fullspan + nameex.fullspan, atex.span + nameex.span)
            end
            rest, restk = kids[3:end], kkinds[3:end]
        else
            name = kids[1]
            rest, restk = kids[2:end], kkinds[2:end]
        end
        # Macro args keep `=` as assignment (never `:kw`), unlike call args.
        args, trivia, groups = collect_arglist(rest, restk, K"(", K")"; kw=false)
        args = EXPR[name, EXPR(:NOTHING, 0, 0, nothing), args...]
        isempty(groups) || insert!(args, 3, merge_params!(groups))
        # Unprefixed cmd literals (name.head == :globalrefcmd) always keep
        # trivia = EXPR[], oracle-pinned, unlike every other macrocall shape.
        macro_trivia = name.head === :globalrefcmd ? EXPR[] : (isempty(trivia) ? nothing : trivia)
        # Oracle quirk: a qualified (dotted-name) macrocall's span reaches its
        # fullspan (keeping trailing trivia) when it ends in a paren arg list
        # (`M.@m(a)`) or has no real args at all (`Base.@_inline_meta`, whose
        # last arg is the zero-width NOTHING). A qualified macrocall with a
        # trailing real arg (`M.@m a`) keeps a normal span.
        if do_partial !== nothing
            # The span quirks below don't apply: the macrocall is not the
            # returned node, and its right edge is the do-block's start.
            mac = EXPR(:macrocall, args, macro_trivia, mac_fs, mac_sp)
            return EXPR(:do, EXPR[mac, do_partial.args[1]], do_partial.trivia, 0, 0)
        end
        if name.head isa EXPR && (kkinds[end] == K")" || last(args).fullspan == 0)
            ll = cur.leaves[cur.i-1]
            cur.grow_span += ll.fullspan - ll.span
        elseif kkinds[end] != K")" && last(args).fullspan != 0
            # A parenless macrocall's span is measured to its last REAL arg —
            # grow when that arg's span already extends past its own raw
            # leaves (e.g. `@eval M.@m(a)`: the nested qualified macrocall has
            # span == fullspan), so the quirk propagates through nesting. A
            # zero-width last arg (bare unqualified `@m`'s NOTHING) keeps the
            # normal trailing exclusion.
            grow_span_to_last_arg!(cur, args)
        end
        return EXPR(:macrocall, args, macro_trivia, 0, 0)
    elseif k == K"inert"
        # `A.$f` getfield with an interpolated field name: the field is a
        # K"inert"-wrapped `$` interpolation → CSTParser's :quotenode.
        return EXPR(:quotenode, kids, nothing, 0, 0)
    elseif k == K"doc"
        # `"..." expr` docstring → CSTParser's synthetic @doc macrocall:
        # [globalrefdoc, NOTHING, docstring, documented_expr], no trivia.
        return EXPR(:macrocall,
                    EXPR[EXPR(:globalrefdoc, 0, 0, nothing),
                         EXPR(:NOTHING, 0, 0, nothing), kids[1], kids[2]],
                    nothing, 0, 0)
    elseif k == K"importpath"
        # `A`, `A.B.C`, `..A` → a synthetic zero-width `.`-operator-headed
        # node: path components (identifiers + leading relative-dot operators)
        # are args, separator dots between components are trivia.
        dot_head = EXPR(:OPERATOR, 0, 0, ".")
        args = EXPR[]
        trivia = EXPR[]
        seen = false
        i = 1
        while i <= length(kids)
            ex, ck = kids[i], kkinds[i]
            if ck == K"@" && i < length(kids)
                # `A.@m` path component: fuse `@`+MacroName into one IDENTIFIER.
                nm = kids[i+1]
                if nm.val isa String
                    push!(args, EXPR(:IDENTIFIER, ex.fullspan + nm.fullspan,
                                     ex.span + nm.span, "@" * nm.val))
                else
                    # Broken macro name (missing/errored, e.g. a bare `@` at
                    # EOF) — can't fuse into one IDENTIFIER; keep both pieces
                    # reachable instead.
                    push!(args, EXPR(:errortoken, EXPR[ex, nm], nothing,
                                      ex.fullspan + nm.fullspan, ex.span + nm.span))
                end
                seen = true
                i += 2
            elseif ck == K"."
                # Leading relative dots are OPERATOR args; separator dots
                # between components are DOT-headed trivia.
                seen ? push!(trivia, EXPR(:DOT, ex.fullspan, ex.span, ".")) :
                       push!(args, ex)
                i += 1
            else
                # `import Base: in` — a word-operator path component is
                # tokenized as Identifier but labelled OPERATOR by CSTParser.
                ex.head === :IDENTIFIER && ex.val in ("where", "in", "isa") &&
                    (ex.head = :OPERATOR)
                push!(args, ex)
                seen = true
                i += 1
            end
        end
        return EXPR(dot_head, args, trivia, 0, 0)
    elseif k == K"as"
        # `A as B` → (:as, [path, newname], trivia=[as]).
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K"as" ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:as, args, trivia, 0, 0)
    elseif k == K":" && (kkinds[1] == K"using" || kkinds[1] == K"import")
        # Selective import `using A: x, y` → colon-operator-headed node,
        # args=[module_path, imported paths...], trivia=[commas]. The
        # using/import keyword leaf lives here in the green tree but the
        # oracle relocates it to the enclosing using/import node's trivia;
        # trim its leading width off this node (the parent re-adds it).
        cur.trim += kids[1].fullspan
        head = nothing
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids[2:end], kkinds[2:end])
            if ck == K":"
                head = ex
            elseif ck == K","
                push!(trivia, ex)
            else
                push!(args, ex)
            end
        end
        return EXPR(head, args, trivia, 0, 0)
    elseif k == K"using" || k == K"import"
        sym = k == K"using" ? :using : :import
        if kkinds[1] == K":"
            # colon node already assembled; the keyword leaf it swallowed is
            # this node's first consumed leaf (see the K":" branch above).
            kw = cur.terminals[first(cur.kid_ranges[1])]
            return EXPR(sym, EXPR[kids[1]], EXPR[kw], 0, 0)
        end
        kw = kids[1]
        args = EXPR[]
        trivia = EXPR[kw]
        for (ex, ck) in zip(kids[2:end], kkinds[2:end])
            ck == K"," ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(sym, args, trivia, 0, 0)
    elseif k == K"export" || k == K"public"
        # `export a, @m` → names in args (fusing `@`+MacroName), keyword and
        # commas in trivia.
        args = EXPR[]
        trivia = EXPR[]
        i = 1
        while i <= length(kids)
            ex, ck = kids[i], kkinds[i]
            if ck == k || ck == K","
                push!(trivia, ex)
            elseif ck == K"@" && i < length(kids)
                nm = kids[i+1]
                if nm.val isa String
                    push!(args, EXPR(:IDENTIFIER, ex.fullspan + nm.fullspan,
                                     ex.span + nm.span, "@" * nm.val))
                else
                    # Broken macro name (missing/errored) — can't fuse into
                    # one IDENTIFIER; keep both pieces reachable instead.
                    push!(args, EXPR(:errortoken, EXPR[ex, nm], nothing,
                                      ex.fullspan + nm.fullspan, ex.span + nm.span))
                end
                i += 1
            else
                # A word-operator name (`export isa`) tokenizes as Identifier
                # but is labelled OPERATOR, same as importpath's own path.
                ex.head === :IDENTIFIER && ex.val in ("where", "in", "isa") &&
                    (ex.head = :OPERATOR)
                push!(args, ex)
            end
            i += 1
        end
        return EXPR(Symbol(lowercase(string(k))), args, trivia, 0, 0)
    elseif k == K"do"
        # `f(x) do y ... end`: 1.x nests this do-node as the LAST child of
        # the enclosing K"call" node (0.4 had it inverted — a K"do" node
        # wrapped the call). This node's own kids are just [do, params-
        # tuple, body-block, end], with no call target; package the params/
        # body pair (with a synthetic zero-width `->`, no literal token
        # exists) plus the do/end trivia into a private carrier EXPR that
        # the enclosing K"call" branch below reunites with the call target.
        tuple_ex = block_ex = nothing
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"do" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K"tuple"
                tuple_ex = ex
            else
                block_ex = ex
            end
        end
        # `f(x) do; body end` (no params): the empty-params tuple carries a
        # lone `;` — CSTParser folds that onto the DO keyword and leaves an
        # empty tuple.
        if tuple_ex.args !== nothing && length(tuple_ex.args) == 1 &&
           tuple_ex.args[1].head === :SEMICOLON
            semi = tuple_ex.args[1]
            trivia[1].fullspan += semi.fullspan   # DO keyword is trivia[1]
            tuple_ex = EXPR(:tuple, EXPR[], EXPR[], 0, 0)
        end
        # Bare single-param list (`do y`): the K"tuple" branch marks it with
        # nothing-trivia; the oracle's do-param tuple always has EXPR[].
        tuple_ex.head === :tuple && tuple_ex.trivia === nothing &&
            (tuple_ex.trivia = EXPR[])
        fullspan = tuple_ex.fullspan + block_ex.fullspan
        span = fullspan - (block_ex.fullspan - block_ex.span)
        op = EXPR(:OPERATOR, 0, 0, "->")
        body = EXPR(op, EXPR[tuple_ex, block_ex], EXPR[], fullspan, span)
        return EXPR(:__do_body__, EXPR[body], trivia, body.fullspan, body.span)
    elseif k == K"..." && length(kids) == 2
        # x... (splat) → (:..., [x]) — postfix unary, operator is the 2nd kid.
        return EXPR(kids[2], EXPR[kids[1]], nothing, 0, 0)
    elseif k == K"::" && length(kids) == 2
        # ::T (bare type assertion, e.g. an unnamed call parameter) →
        # (:::, [T]) — prefix unary, operator is the 1st kid.
        return EXPR(kids[1], EXPR[kids[2]], nothing, 0, 0)
    elseif k == K"parameters"
        # `; z, w=1` after a call's semicolon → (:parameters, [z, kw(w=1)], trivia=[,]).
        # The `;` is dropped entirely (not even trivia); its width folds
        # onto the leaf preceding it, whichever parent the group sits under,
        # and the leading `;`'s width is trimmed from this node's own spans.
        # An all-empty group (`f(;)`) has trivia === nothing, not EXPR[].
        args = EXPR[]
        trivia = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K";"
                semi_i = first(cur.kid_ranges[j])
                if fold_semi!(cur, semi_i, ex.fullspan)
                    j == 1 && (cur.trim += ex.fullspan)
                else
                    push!(trivia, ex)   # nothing precedes; keep sums balanced
                end
            elseif ck == K","
                push!(trivia, ex)
            elseif ck == K"="
                push!(args, to_kw(ex))
            else
                push!(args, ex)
            end
        end
        return EXPR(:parameters, args,
                    isempty(args) && isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"in" && length(kids) == 3
        # for-loop/comprehension iteration spec (`i = xs`/`i in xs`/`i ∈ xs`),
        # always wrapped in a K"iteration" node (see that branch below).
        # JuliaSyntax gives the spec node its own Kind regardless of the
        # actual keyword. When literally spelled `=`, the oracle just uses
        # that real operator leaf as head (indistinguishable from a plain
        # assignment); only `in`/`∈` get a synthetic zero-width "=" head
        # with the real operator relocated to trivia.
        lhs, op, rhs = kids
        if op.val == "="
            return EXPR(op, EXPR[lhs, rhs], nothing, 0, 0)
        end
        head = EXPR(:OPERATOR, 0, 0, "=")
        return EXPR(head, EXPR[lhs, rhs], EXPR[op], 0, 0)
    elseif k == K"iteration"
        # Wraps one (single-spec for/generator) or several comma-joined
        # (multi-spec) iteration bindings. Multi collapses to the same
        # :block shape the old cartesian_iterator node produced; single is
        # transparent (no wrapper existed pre-1.x for the single-spec case).
        if length(kids) == 1
            return kids[1]
        end
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K"," ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:block, args, trivia, 0, 0)
    elseif (k == K"=" || k == K"->" ||
            (k == K"function" &&
             !any(j -> kkinds[j] == K"function" && kids[j].args === nothing,
                  eachindex(kids)))) && length(kids) == 3
        # binary syntax: operator EXPR becomes the head. Short-form function
        # defs (`f(x) = ...`, `f(x::T) where T = ...`) and `->` bodies wrap
        # their RHS in an implicit block; plain assignment does not, and an
        # explicit `begin ... end` RHS is never wrapped a second time.
        # 1.x normalizes ALL short-form defs to the K"function" node kind
        # (shared with the long `function ... end` form, which always keeps
        # a literal K"function" keyword child — the discriminator here);
        # CSTParser still treats them as `=`-headed binary syntax.
        lhs, op, rhs = kids
        if k == K"=" && JuliaSyntax.is_dotted(JuliaSyntax.head(node))
            # a .= b: dotted assignment reuses base K"=" plus a DOTTED flag
            # instead of a distinct Kind (unlike +=/-=/etc, which get their
            # own Kind and are handled by the generic operator branch below)
            # — op.val is already the real ".=" text, no fusion needed.
            return EXPR(op, EXPR[lhs, rhs], nothing, 0, 0)
        end
        if k == K"->" && lhs.head === :tuple && lhs.args !== nothing &&
           length(lhs.args) == 1 && lhs.args[1].head !== :parameters
            if lhs.trivia === nothing
                # Bare single-param LHS (`x -> ...`): unwrap the K"tuple"
                # branch's marked wrapper — the oracle keeps the plain
                # identifier (only do-blocks keep the :tuple shape).
                lhs = lhs.args[1]
            elseif length(lhs.trivia) == 2
                # `(x) -> ...`: parens but no comma (a real 1-tuple `(x,)`
                # has 3 trivia) — the oracle keeps a plain :brackets
                # grouping here, unlike `function (x) ... end`, which keeps
                # the :tuple under the same green shape.
                lhs = EXPR(:brackets, lhs.args, lhs.trivia, lhs.fullspan, lhs.span)
            end
        elseif k == K"->" && lhs.head === :tuple && lhs.args !== nothing &&
               length(lhs.args) == 2 && lhs.args[1].head === :parameters &&
               lhs.trivia !== nothing && length(lhs.trivia) == 2 &&
               !(lhs.args[2].head isa EXPR && lhs.args[2].head.val == "...")
            # `(s; kws...) -> ...`: `;`-split LHS with exactly ONE element
            # on each side of every `;` and no commas — the oracle parses
            # the paren group as a plain paren-BLOCK (brackets[block[s,
            # kws...]]) instead of recognizing `;`-parameters; `=` elements
            # stay plain assignments, not :kw. Any comma (`(a, b; c)`,
            # `(x; a, b)`), a params-ONLY LHS (`(;x)`) or a SPLAT pre-`;`
            # element (`(args...; kwargs...)`) keeps the :tuple+parameters
            # shape — all oracle-pinned. Flatten the group chain (sibling
            # `;` groups nested by merge_params!) back into block elements.
            elems = EXPR[lhs.args[2]]
            group = lhs.args[1]
            ok = true
            while group !== nothing
                nested = nothing
                n_real = 0
                for (gi, ge) in enumerate(group.args)
                    if gi == 1 && ge.head === :parameters
                        nested = ge
                    elseif ge.head === :kw
                        n_real += 1
                        push!(elems, EXPR(ge.trivia[1], ge.args, nothing,
                                          ge.fullspan, ge.span))
                    else
                        n_real += 1
                        push!(elems, ge)
                    end
                end
                n_real == 1 || (ok = false; break)
                group = nested
            end
            if ok
                bfs = sum(x -> x.fullspan, elems; init=0)
                bsp = bfs - (elems[end].fullspan - elems[end].span)
                blk = EXPR(:block, elems, EXPR[], bfs, bsp)
                lhs = EXPR(:brackets, EXPR[blk], lhs.trivia, lhs.fullspan, lhs.span)
            end
        end
        # A short-form definition (block-wrapped body) is keyed by the LHS
        # being a call / where-clause / return-type-annotated call
        # (`f()::T = ...`) — but NOT a plain typed assignment (`x::T = 5`).
        typed_def = kkinds[1] == K"::" && lhs.args !== nothing &&
                    !isempty(lhs.args) && lhs.args[1].head === :call
        # `(f(x)) = body` / `(f(x) where T) = body` — a parenthesized signature
        # is still a function def (block-wrapped body); `(x) = y` is not.
        parens_def = kkinds[1] == K"parens" && lhs.args !== nothing &&
                     !isempty(lhs.args) && lhs.args[1].head in (:call, :where)
        needs_block = (k == K"->" || kkinds[1] == K"call" || kkinds[1] == K"where" ||
                       typed_def || parens_def) && kkinds[3] != K"block"
        # A bare unary `::T` signature (`::typeof(x) = x` kwarg default) keeps
        # the wrapped body's trivia as EXPR[]; a binary `::` return-type def
        # (`f()::T = x`) and every other wrapped body use `nothing`.
        body_trivia = (typed_def && length(lhs.args) == 1) ? EXPR[] : nothing
        body = needs_block ? EXPR(:block, EXPR[rhs], body_trivia, rhs.fullspan, rhs.span) : rhs
        # Span is measured to the last arg; grow when that arg's span already
        # reaches its fullspan (bare `return`, qualified-macrocall RHS).
        grow_span_to_last_arg!(cur, EXPR[lhs, body])
        return EXPR(op, EXPR[lhs, body], nothing, 0, 0)
    elseif (k == K"::" || k == K"<:" || k == K">:") && length(kids) >= 2 &&
           kkinds[1] == k && kkinds[2] == K"("
        # operator-as-function-call: `<:(a, b)` → operator-headed with the
        # parenthesized args, parens/commas as trivia.
        op = kids[1]
        args, trivia, groups = collect_arglist(kids[2:end], kkinds[2:end], K"(", K")")
        return EXPR(op, args, trivia, 0, 0)
    elseif (k == K"::" || k == K"<:") && length(kids) == 3
        # binary syntax: operator EXPR becomes the head (type declarations,
        # supertype clauses)
        return EXPR(kids[2], EXPR[kids[1], kids[3]], nothing, 0, 0)
    elseif k == K"where"
        # f(x) where T → (:where, [sig, T], trivia=[where]); braces-wrapped
        # typevar lists (`where {T <: S}`) are flattened into where's own
        # args/trivia rather than kept as a nested :braces node.
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"where" && ex.args === nothing
                # keyword leaf (nested `where` composite reuses the kind — the
                # same trap as if/elseif; only the leaf goes to trivia).
                push!(trivia, ex)
            elseif ck == K"braces"
                append!(args, ex.args)
                append!(trivia, ex.trivia)
            else
                push!(args, ex)
            end
        end
        return EXPR(:where, args, trivia, 0, 0)
    elseif k == K"if" || k == K"elseif"
        # JuliaSyntax reuses K"if"/K"elseif" for both the composite node AND
        # its own leading keyword leaf — a leaf keyword has `args === nothing`
        # (built by terminal_expr), a nested elseif clause doesn't, so that's
        # the only reliable way to tell "keyword to drop" from "child node".
        trivia = EXPR[]
        args = EXPR[]
        has_end = K"end" in kkinds
        for (ex, ck) in zip(kids, kkinds)
            if ex.args === nothing && JuliaSyntax.is_keyword(ck)
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck) && !has_end && !isempty(args)
                # Unterminated `if`: the missing-`end` marker becomes a trivia
                # END-placeholder (not a spurious extra arg) so iterate holds.
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                   nothing, ex.fullspan, ex.span))
            else
                push!(args, ex)
            end
        end
        # An `elseif` ends in its (possibly empty) body block, not an END
        # keyword, so its span is measured to that last arg — grow when the
        # block is empty (its trailing exclusion is 0 but the last real leaf's
        # is not). An `if` ends in END trivia and must NOT grow (its END owns
        # any trailing whitespace up to the next statement).
        k == K"elseif" && grow_span_to_last_arg!(cur, args)
        return EXPR(k == K"if" ? :if : :elseif, args, trivia, 0, 0)
    elseif k == K"?"
        # ternary a ? b : c → (:if, [a, b, c], trivia=[?, :]) — reuses if's
        # head. Same kind-reuse trap as if/elseif: a NESTED ternary is a
        # composite K"?" kid, so only genuine leaves (`args === nothing`)
        # may be filed into trivia.
        trivia = EXPR[]
        args = EXPR[]
        haserr = false
        orphan = 0
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ex.args === nothing && (ck == K"?" || ck == K":")
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck)
                # Broken ternary emits zero-width error markers; drop them and
                # rebuild the fixed cond?then:else arity below. A marker can
                # carry folded trailing trivia (`a ? b\n`): fold that width
                # onto the preceding real leaf (skipping earlier markers) so
                # patch_dropped_width! never materializes a filler arg that
                # breaks the arity.
                haserr = true
                if ex.fullspan > 0
                    i = first(cur.kid_ranges[j]) - 1
                    while i >= 1 && JuliaSyntax.is_error(cur.leaves[i].kind)
                        i -= 1
                    end
                    widen_at_leaf!(cur, i, ex.fullspan) || (orphan += ex.fullspan)
                end
            else
                push!(args, ex)
            end
        end
        if haserr
            # Pad to CSTParser's 3-arg/2-trivia ternary shape so its iterate
            # accessor stays in bounds (recovery differs from the oracle).
            # `orphan` (no real leaf preceded the marker) rides on the first
            # pad so childsums stay balanced.
            while length(args) < 3
                push!(args, EXPR(:errortoken, orphan, 0, nothing))
                orphan = 0
            end
            while length(trivia) < 2
                push!(trivia, EXPR(:errortoken, orphan, 0, nothing))
                orphan = 0
            end
        end
        return EXPR(:if, args, trivia, 0, 0)
    elseif (k == K"break" || k == K"continue") && length(kids) == 1
        # The composite node wraps a single leaf of the SAME kind; the oracle
        # collapses the statement to just that leaf, no wrapping at all.
        return kids[1]
    elseif k == K"return"
        # `return` (no value) gets a synthetic zero-width NOTHING arg; `return
        # x` already has a real value kid, no synthesis needed. With the
        # NOTHING arg stored last, CSTParser measures span = fullspan (zero
        # trailing exclusion), so the keyword's trailing trivia must be
        # grown back into the span (the auto leaf-range calc excludes it).
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K"return" ? push!(trivia, ex) : push!(args, ex)
        end
        if isempty(args)
            push!(args, EXPR(:NOTHING, 0, 0, ""))
            kw = trivia[1]
            cur.grow_span += kw.fullspan - kw.span
        end
        return EXPR(:return, args, trivia, 0, 0)
    elseif k == K"catch"
        # Flattened into try's own args/trivia by the K"try" branch below;
        # this intermediate shape is never part of the final tree.
        catch_kw = nothing
        rest = EXPR[]
        restk = Kind[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"catch"
                catch_kw = ex
            else
                push!(rest, ex)
                push!(restk, ck)
            end
        end
        var, block = rest[1], rest[2]
        if var.span == 0 && var.fullspan != 0
            # JuliaSyntax's absent-catch-var placeholder is a zero-content
            # leaf that still swallows trailing whitespace up to the next
            # token; CSTParser's own CATCH keyword owns that width instead.
            catch_kw.fullspan += var.fullspan
            var.fullspan = 0
        end
        if restk[1] == K"Placeholder" && isempty(block.args)
            # Oracle-pinned quirk: an empty catch body with NO named var
            # keeps `trivia = EXPR[]`, not `nothing` (every other empty
            # block, incl. this same one WITH a var, uses `nothing`).
            block.trivia = EXPR[]
        end
        return EXPR(:catch, EXPR[var, block], EXPR[catch_kw], 0, 0)
    elseif k == K"finally"
        # Oracle-pinned: the finally block always keeps `trivia = EXPR[]`,
        # never `nothing`, regardless of statement count.
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"finally"
                push!(trivia, ex)
            else
                ex.trivia === nothing && (ex.trivia = EXPR[])
                push!(args, ex)
            end
        end
        return EXPR(:finally, args, trivia, 0, 0)
    elseif k == K"else" && kkinds[1] == K"else"
        # try's else-clause is its own composite node (unlike if/elseif's
        # bare ELSE leaf, which never reaches assemble_form at all). Same
        # trivia-always-EXPR[] quirk as finally's block.
        block = kids[2]
        block.trivia === nothing && (block.trivia = EXPR[])
        return EXPR(:elseclause, EXPR[block], EXPR[kids[1]], 0, 0)
    elseif k == K"try"
        # CSTParser's :try has a fixed 5-slot layout beyond the try-block:
        # [catch_var, catch_block, finally_block, else_block]. Absent
        # trailing slots are dropped entirely; an absent slot that still has
        # a present slot AFTER it (in this order) keeps a zero-width FALSE
        # placeholder instead. Same trim-from-the-tail rule applies to the
        # keyword trivia (CATCH is unconditional — a try always has catch or
        # finally, so CATCH is never the trailing item).
        try_kw = end_kw = try_block = missing_end = nothing
        catch_kw = catch_var = catch_block = nothing
        finally_kw = finally_block = nothing
        else_kw = else_block = nothing
        has_catch = has_finally = has_else = false
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"try"
                try_kw = ex
            elseif ck == K"end"
                end_kw = ex
            elseif ck == K"catch"
                has_catch = true
                catch_kw, catch_var, catch_block = ex.trivia[1], ex.args[1], ex.args[2]
            elseif ck == K"finally"
                has_finally = true
                finally_kw, finally_block = ex.trivia[1], ex.args[1]
            elseif ck == K"else"
                has_else = true
                else_kw, else_block = ex.trivia[1], ex.args[1]
            elseif JuliaSyntax.is_error(ck) && try_block !== nothing
                # Unterminated try (missing `end`); keep as the trailing
                # END-placeholder instead of clobbering the try body.
                missing_end = ex
            else
                try_block = ex
            end
        end
        if !has_catch && !has_finally && !has_else
            # Broken input (no catch/finally/else at all): synthesize an empty
            # catch so the node matches CSTParser iterate's fixed try arity.
            has_catch = true
            catch_kw = EXPR(:CATCH, 0, 0, nothing)
            catch_var = false_arg()
            catch_block = EXPR(:block, EXPR[], nothing, 0, 0)
        end
        # An empty catch body followed by a finally/else clause is degenerate
        # in CSTParser: a FALSE marker before `finally`, an args=nothing
        # `:block` (val "") before `else`.
        if has_catch && catch_block !== nothing && catch_block.fullspan == 0 &&
           (catch_block.args === nothing || isempty(catch_block.args))
            if has_else
                catch_block.args = nothing
                catch_block.trivia = nothing
                catch_block.val = ""
            elseif has_finally && catch_var !== nothing && catch_var.head === :FALSE
                # only a var-less empty catch collapses to FALSE before finally
                catch_block = false_arg()
            end
        end
        raw = [(catch_var, has_catch), (catch_block, has_catch),
               (finally_block, has_finally), (else_block, has_else)]
        while !isempty(raw) && !raw[end][2]
            pop!(raw)
        end
        args = EXPR[try_block]
        for (v, present) in raw
            push!(args, present ? v : false_arg())
        end
        catch_trivia = has_catch ? catch_kw : EXPR(:CATCH, 0, 0, nothing)
        raw_t = [(finally_kw, has_finally), (else_kw, has_else)]
        while !isempty(raw_t) && !raw_t[end][2]
            pop!(raw_t)
        end
        trivia = EXPR[try_kw, catch_trivia]
        for (v, present) in raw_t
            push!(trivia, present ? v : false_arg())
        end
        # end_kw can be absent when malformed input (e.g. `try catch finally
        # else`) buries the `end` inside a JuliaSyntax error node. Keep the
        # missing-`end` marker as a trailing END-placeholder so iterate's
        # arity holds; otherwise drop the slot entirely.
        if end_kw !== nothing
            push!(trivia, end_kw)
        elseif missing_end !== nothing
            push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                               nothing, missing_end.fullspan, missing_end.span))
        end
        return EXPR(:try, filter(!isnothing, args), trivia, 0, 0)
    elseif k == K"let"
        # bindings block collapses to its single item when there's exactly
        # one binding (`let x = 1` / `let x`); stays a :block for 0 or 2+.
        trivia = EXPR[]
        bindings = body = nothing
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"let" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K";"
                # `let x=1; y end` — the `;` separating bindings from body is
                # dropped; its width folds onto the bindings' last leaf.
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan)
            elseif bindings === nothing
                bindings = ex
            else
                body = ex
            end
        end
        length(bindings.args) == 1 && (bindings = bindings.args[1])
        return EXPR(:let, EXPR[bindings, body], trivia, 0, 0)
    elseif k == K"while" || k == K"for"
        # `while cond body end` / `for spec body end` → args=[cond/spec, body],
        # trivia=[keyword, END]. A real branch (not generic_form) is needed
        # because the condition/spec can itself be keyword-kinded (e.g. a
        # `while let ... end`), which generic_form would misfile as trivia.
        sym = k == K"while" ? :while : :for
        trivia = EXPR[]
        args = EXPR[]
        has_end = K"end" in kkinds
        for (ex, ck) in zip(kids, kkinds)
            if ck == k || ck == K"end"
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck) && !has_end && !isempty(args)
                # Unterminated body: the missing-`end` marker becomes an
                # END-placeholder in trivia (not a spurious extra arg) so
                # CSTParser's iterate finds the expected arity.
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                   nothing, ex.fullspan, ex.span))
            else
                push!(args, ex)
            end
        end
        return EXPR(sym, args, trivia, 0, 0)
    elseif k == K"comprehension"
        trivia = EXPR[kids[1], kids[end]]
        return EXPR(:comprehension, EXPR[kids[2]], trivia, 0, 0)
    elseif k == K"generator"
        # [expr for spec] → (:generator, [expr, spec], trivia=[for]); a
        # multi-spec K"iteration" FLATTENS its args/trivia directly into
        # generator's own (unlike `for`, which keeps it as a nested :block)
        # — confirmed via dump: comma lands in generator's trivia. Multiple
        # `for` clauses (`[x for a in as for b in bs]`) are ONE flat green
        # node, but the oracle nests them INVERTED — innermost generator
        # holds the body + LAST clause, each enclosing level adds the
        # next-earlier clause, and every multi-clause generator gets a
        # :flatten wrapper (child levels included, the innermost single-
        # clause one excluded). Nested levels are discontiguous in source,
        # so their spans are hand-built from child fullspan sums.
        body = kids[1]
        groups = Tuple{EXPR,EXPR}[]   # (for_kw, spec)
        j = 2
        while j <= length(kids)
            push!(groups, (kids[j], kids[j+1]))
            j += 2
        end
        function gen_level(child::EXPR, kw::EXPR, spec::EXPR)
            args = EXPR[child]
            trivia = EXPR[kw]
            if spec.head === :block
                # multi-spec K"iteration" collapsed to :block; flatten it.
                append!(args, spec.args)
                append!(trivia, spec.trivia)
            else
                push!(args, spec)
            end
            fs = child.fullspan + kw.fullspan + spec.fullspan
            return EXPR(:generator, args, trivia, fs,
                        fs - (args[end].fullspan - args[end].span)), args
        end
        if length(groups) == 1
            gen, args = gen_level(body, groups[1]...)
            trim_span_to_last_arg!(cur, args)
            return EXPR(:generator, gen.args, gen.trivia, 0, 0)
        end
        gen, _ = gen_level(body, groups[end]...)
        for gi in length(groups)-1:-1:1
            child = gi == length(groups) - 1 ? gen :
                    EXPR(:flatten, EXPR[gen], nothing, gen.fullspan, gen.span)
            gen, _ = gen_level(child, groups[gi]...)
        end
        trim_span_to_last_arg!(cur, EXPR[gen])
        return EXPR(:flatten, EXPR[gen], nothing, 0, 0)
    elseif k == K"filter"
        # `... if cond` clause → (:filter, [cond, spec], trivia=[if]) — args
        # order is COND-then-SPEC, reversed from source order (spec if cond),
        # so span follows CSTParser's own args[end]-trailing-exclusion
        # convention rather than the raw leaf-bookend calc.
        trivia = EXPR[]
        spec = cond = nothing
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"if"
                push!(trivia, ex)
            elseif spec === nothing
                spec = ex
            else
                cond = ex
            end
        end
        args = EXPR[cond, spec]
        trim_span_to_last_arg!(cur, args)
        return EXPR(:filter, args, trivia, 0, 0)
    elseif k == K"hcat"
        # Bare cells get the matrix_cell! quirk (hcat always has >=2, since
        # a single bracketed item is a :vect instead).
        trivia = EXPR[kids[1], kids[end]]
        cells = kids[2:end-1]
        length(cells) >= 2 && foreach(matrix_cell!, cells)
        return EXPR(:hcat, cells, trivia, 0, 0)
    elseif k == K"row"
        # `1 2;` inside vcat — bare cells, trailing `;` dropped/folded like a
        # block's, oracle-pinned zero-width trivia (never `nothing`). The
        # matrix_cell! quirk only fires with >=2 real cells — oracle-pinned:
        # a lone cell (e.g. the degenerate `[a;]`, no row wrapping needed)
        # keeps the normal `nothing` args/trivia.
        cells = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(cells) || (cells[end].fullspan += ex.fullspan))
            else
                push!(cells, ex)
            end
        end
        length(cells) >= 2 && foreach(matrix_cell!, cells)
        # Span is measured to the last cell, not the trailing `;` run (which
        # folds into that cell's fullspan) — this also excludes whitespace
        # between the last cell and the `;`.
        trim_span_to_last_arg!(cur, cells)
        return EXPR(:row, cells, EXPR[], 0, 0)
    elseif k == K"vcat"
        # Either wraps nested :row children (2D matrices) or holds bare cells
        # directly with `;` fold (flat column vectors) — both shapes seen in
        # the wild; handle both in one pass. Unlike row/nrow, a trailing `;`
        # here is always followed by the closing `]`, so it's never this
        # node's own leaf-range-computed last leaf — no trim_span needed.
        trivia = EXPR[kids[1], kids[end]]
        args = EXPR[]
        cells = EXPR[]   # bare (non-row) cells only, to gate the quirk
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"[" || ck == K"]"
                continue
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(args) || (args[end].fullspan += ex.fullspan))
            elseif ck == K"row"
                push!(args, ex)
            else
                push!(args, ex)
                push!(cells, ex)
            end
        end
        # The bare-cell quirk fires when the matrix has 2+ elements total
        # (rows + bare cells) — a lone bare cell in a multi-row vcat
        # (`[1 2; 3]`) still gets it, unlike the degenerate `[a;]`.
        length(args) >= 2 && foreach(matrix_cell!, cells)
        return EXPR(:vcat, args, trivia, 0, 0)
    elseif k == K"nrow"
        # Like row, but prefixed with a synthetic dim-number marker (a bare
        # Symbol head named after the digit, e.g. Symbol("1")) read from the
        # green node's own flags — CSTParser's ncat/nrow dimension encoding.
        dim = JuliaSyntax.numeric_flags(JuliaSyntax.flags(node))
        cells = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(cells) || (cells[end].fullspan += ex.fullspan))
            else
                push!(cells, ex)
            end
        end
        length(cells) >= 2 && foreach(matrix_cell!, cells)
        # Span is measured to the last cell, not the trailing `;` run (which
        # folds into that cell's fullspan) — this also excludes whitespace
        # between the last cell and the `;`.
        trim_span_to_last_arg!(cur, cells)
        args = EXPR[EXPR(Symbol(string(dim)), 0, 0, "")]
        append!(args, cells)
        return EXPR(:nrow, args, EXPR[], 0, 0)
    elseif k == K"ncat"
        dim = JuliaSyntax.numeric_flags(JuliaSyntax.flags(node))
        trivia = EXPR[kids[1], kids[end]]
        rest = EXPR[]
        cells = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"[" || ck == K"]"
                continue
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(rest) || (rest[end].fullspan += ex.fullspan))
            elseif ck == K"nrow"
                push!(rest, ex)
            else
                push!(rest, ex)
                push!(cells, ex)
            end
        end
        length(rest) >= 2 && foreach(matrix_cell!, cells)
        args = EXPR[EXPR(Symbol(string(dim)), 0, 0, "")]
        append!(args, rest)
        return EXPR(:ncat, args, trivia, 0, 0)
    elseif k == K"block" && length(kids) >= 2 && kkinds[1] == K"(" && kkinds[end] == K")"
        # `(a; b)` — JuliaSyntax gives ONE green `block` node wrapping the
        # parens directly (no nested "parens" node); the oracle synthesizes
        # two EXPR levels instead: outer :brackets(paren trivia) wrapping an
        # inner :block built with the same `;`-fold rules as a real block.
        # The inner node is hand-built (not an assemble_form return value
        # for a real node), so its span is computed directly rather than via
        # Cursor.trim/trim_span.
        args = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if j == 1 || j == length(kids)
                continue
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                if fold_semi!(cur, semi_i, ex.fullspan)
                else
                    isempty(args) || (args[end].fullspan += ex.fullspan)
                end
            else
                push!(args, ex)
            end
        end
        fullspan = sum(x -> x.fullspan, args; init=0)
        span = isempty(args) ? 0 : fullspan - (args[end].fullspan - args[end].span)
        inner = EXPR(:block, args, EXPR[], fullspan, span)
        return EXPR(:brackets, EXPR[inner], EXPR[kids[1], kids[end]], 0, 0)
    elseif k == K"block"
        # `;`-separated statements drop the `;` entirely, same as toplevel's:
        # its width folds onto the rightmost leaf of the preceding statement.
        args = EXPR[]
        trivia = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"begin" || ck == K"end" || (ck == K"quote" && ex.args === nothing)
                # `quote ... end`'s keywords live inside its body block; the
                # K"quote" branch lifts them up to the :quote node. Guard on
                # the leaf test so a nested composite quote statement stays.
                push!(trivia, ex)
            elseif ck == K","
                # `let`'s bindings list reuses K"block" for its comma-joined
                # `=` items; a plain statement block never has raw commas.
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck) && ex.fullspan == 0
                # Unterminated block: JuliaSyntax emits a zero-width error
                # recovery marker for the missing terminator. A `begin`/`quote`
                # block carries END in its trivia, so keep an END-placeholder
                # there (iterate expects trivia[2]); a plain statement block's
                # oracle keeps an empty body, so drop it (no width to fold).
                if !isempty(trivia) && trivia[1].head in (:BEGIN, :QUOTE)
                    push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                       nothing, ex.fullspan, ex.span))
                end
            elseif ck == K";"
                semi_i = first(cur.kid_ranges[j])
                if fold_semi!(cur, semi_i, ex.fullspan)
                    # A leading `;` (e.g. a do-block's params/body separator)
                    # widens a leaf OUTSIDE this block; exclude that width
                    # from the block's own leaf-range-computed span too.
                    j == 1 && (cur.trim += ex.fullspan)
                    # A trailing `;` (e.g. `do y; y; end`'s body terminator)
                    # widens this block's OWN last leaf, so it's still the
                    # node's leaf-range-computed last leaf — its own (never
                    # folded-away) span still inflates the auto span calc;
                    # exclude just that span-only, fullspan stays correct.
                    # ...unless the preceding arg absorbed the `;` into its own
                    # SPAN (a bare `return`, span == fullspan): then the block
                    # measures to that full span (grow, don't trim).
                    if j == length(kids) && !isempty(args)
                        if args[end].span != args[end].fullspan
                            cur.trim_span += ex.span
                        else
                            grow_span_to_last_arg!(cur, args)
                        end
                    end
                else
                    isempty(args) || (args[end].fullspan += ex.fullspan)
                end
            else
                push!(args, ex)
            end
        end
        # A trivia-less block's span is measured to its last stored arg;
        # grow when that arg's trailing exclusion shrank (bare `return`).
        # Skip when the last kid was a dropped `;` (trim_span owns that).
        isempty(trivia) && !isempty(args) && kkinds[end] != K";" &&
            grow_span_to_last_arg!(cur, args)
        return EXPR(:block, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"parens"
        if length(kids) < 2
            # Broken input: missing open and/or close paren (e.g. an
            # unterminated `$(` at EOF) collapses to a single error kid —
            # no open/close pair to split off as trivia.
            return EXPR(:brackets, EXPR[], kids, 0, 0)
        end
        trivia = EXPR[kids[1], kids[end]]
        return EXPR(:brackets, kids[2:end-1], trivia, 0, 0)
    elseif k == K"function"
        trivia = EXPR[]
        args = EXPR[]
        has_end = K"end" in kkinds
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"function" || ck == K"end"
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck) && !has_end && !isempty(args)
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                   nothing, ex.fullspan, ex.span))
            else
                push!(args, ex)
            end
        end
        return EXPR(:function, args, trivia, 0, 0)
    elseif k == K"struct"
        # struct A ... end / mutable struct A ... end share this green kind;
        # CSTParser marks mutability with a synthetic zero-width TRUE/FALSE
        # leaf as args[1] (no corresponding source token).
        trivia = EXPR[]
        is_mutable = false
        sig = nothing
        body = nothing
        errs = EXPR[]
        has_end = K"end" in kkinds
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"mutable"
                is_mutable = true
                push!(trivia, ex)
            elseif ck == K"struct" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K"block"
                body = ex
            elseif JuliaSyntax.is_error(ck) && !has_end && body !== nothing
                # Unterminated struct: the missing-`end` marker (after the body)
                # becomes a trivia END-placeholder so iterate's arity holds.
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                   nothing, ex.fullspan, ex.span))
            elseif sig === nothing
                sig = ex
            else
                # A further unclassified kid — never overwrite the real
                # signature; keep it reachable instead of dropping it.
                push!(errs, ex)
            end
        end
        marker = EXPR(is_mutable ? :TRUE : :FALSE, 0, 0, nothing)
        # Field docstrings: 1.x emits K"doc" nodes inside a struct body too,
        # but the oracle only fuses docstrings at toplevel/module/begin
        # scope — a struct body keeps the string and the field as separate
        # block siblings. Unfuse the doc-macrocalls the K"doc" branch built.
        if body !== nothing && body.args !== nothing
            unfused = EXPR[]
            for a in body.args
                if a.head === :macrocall && a.args !== nothing &&
                   length(a.args) == 4 && a.args[1].head === :globalrefdoc
                    push!(unfused, a.args[3], a.args[4])
                    CSTParser.setparent!(a.args[3], body)
                    CSTParser.setparent!(a.args[4], body)
                else
                    push!(unfused, a)
                end
            end
            body.args = unfused
        end
        return EXPR(:struct, EXPR[marker, sig, body, errs...], trivia, 0, 0)
    elseif k == K"abstract"
        trivia = EXPR[]
        args = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"abstract" || ck == K"type" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K";"
                # `abstract type A; end` — the `;` before `end` drops, folding
                # onto the preceding leaf (no block body to hold it).
                fold_semi!(cur, first(cur.kid_ranges[j]), ex.fullspan)
            else
                push!(args, ex)
            end
        end
        return EXPR(:abstract, args, trivia, 0, 0)
    elseif k == K"primitive"
        trivia = EXPR[]
        args = EXPR[]
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K"primitive" || ck == K"type" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K";"
                fold_semi!(cur, first(cur.kid_ranges[j]), ex.fullspan)
            else
                push!(args, ex)
            end
        end
        return EXPR(:primitive, args, trivia, 0, 0)
    elseif k == K"macro"
        trivia = EXPR[]
        args = EXPR[]
        has_end = K"end" in kkinds
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"macro" || ck == K"end"
                push!(trivia, ex)
            elseif JuliaSyntax.is_error(ck) && !has_end && !isempty(args)
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)],
                                   nothing, ex.fullspan, ex.span))
            else
                push!(args, ex)
            end
        end
        return EXPR(:macro, args, trivia, 0, 0)
    elseif k == K"module"
        # module A ... end / baremodule A ... end share this green kind;
        # same synthetic-marker trick as struct's mutability flag, here
        # meaning "not bare" (baremodule → FALSE).
        trivia = EXPR[]
        is_bare = false
        name = nothing
        body = nothing
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"baremodule"
                is_bare = true
                push!(trivia, ex)
            elseif ck == K"module" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K"block"
                body = ex
            elseif name === nothing
                name = ex
            else
                # A further unclassified kid (broken input's trailing marker
                # for a missing `end`) — oracle-pinned: CSTParser represents
                # a missing expected token as errortoken wrapping a
                # zero-width, val-less placeholder of that token's kind, kept
                # in trivia[2], never a 4th arg; never overwrite the name.
                push!(trivia, EXPR(:errortoken, EXPR[EXPR(:END, 0, 0, nothing)], nothing, ex.fullspan, ex.span))
            end
        end
        # A var"..." module name keeps trivia = EXPR[] (oracle-pinned; a
        # standalone var"..." value keeps nothing).
        name.head === :NONSTDIDENTIFIER && (name.trivia = EXPR[])
        marker = EXPR(is_bare ? :FALSE : :TRUE, 0, 0, nothing)
        return EXPR(:module, EXPR[marker, name, body], trivia, 0, 0)
    elseif k == K"const" || k == K"global" || k == K"local"
        # `global a, b` / `local x, y` → names in args, keyword+commas trivia.
        sym = Symbol(lowercase(string(k)))
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == k || ck == K",") ? push!(trivia, ex) : push!(args, ex)
        end
        # `global const x = 1`: green nests const inside the modifier, but
        # CSTParser puts const outermost — swap (spans are logical, not
        # positional; childsums still balance).
        if sym != :const && length(args) == 1 && args[1].head === :const
            inner = args[1]
            gkw = trivia[1]
            mfs = gkw.fullspan + sum(a -> a.fullspan, inner.args; init=0)
            # span measured to the last inner arg (e.g. `= if … end` excludes
            # its own trailing).
            la = inner.args[end]
            modifier = EXPR(sym, inner.args, EXPR[gkw], mfs, mfs - (la.fullspan - la.span))
            return EXPR(:const, EXPR[modifier], inner.trivia, 0, 0)
        end
        return EXPR(sym, args, trivia, 0, 0)
    elseif k == K"op=" && length(kids) in (4, 5)
        # 1.x splits a compound-assignment operator into separate leaves:
        # the operator name (reclassified to plain Identifier — same "value
        # position" normalization as any other operator used as a callee),
        # the real `=`, and for the broadcast form (`.+=`, same kind plus
        # the DOTTED flag) a leading `.` too. Fuse them into one OPERATOR
        # EXPR matching the oracle's single-token expectation.
        lhs, rhs = kids[1], kids[end]
        mid = kids[2:end-1]
        fused = EXPR(:OPERATOR, sum(x -> x.fullspan, mid),
                     sum(x -> x.span, mid), join(x.val for x in mid))
        grow_span_to_last_arg!(cur, EXPR[lhs, rhs])
        return EXPR(fused, EXPR[lhs, rhs], nothing, 0, 0)
    elseif length(kids) == 3 && kids[2].head === :OPERATOR && JuliaSyntax.is_operator(k)
        # Remaining binary-syntax-head kinds that use the operator's own
        # Kind as the NODE's kind (not K"call"): short-circuit (&&/||), and
        # remaining comparison-as-syntax ops (>:) — same shape as
        # =/->/::/<:` above, just not special-cased per-operator since none
        # of them need block-wrapping. Checks the already-converted kid's
        # head rather than its raw green Kind: 1.x reclassifies some of
        # these operator leaves (e.g. `>:`/`<:` used infix) to plain
        # Identifier, already normalized to :OPERATOR by terminal_expr.
        # Placed last: `where`/`in`/`isa` are also JuliaSyntax "operators"
        # by precedence but have their own dedicated non-operator-headed
        # branches earlier, which must win first.
        # A bare `return` RHS (`c && return`) has span==fullspan, so grow this
        # node's span to its last arg (same as the trivia-less block case).
        grow_span_to_last_arg!(cur, EXPR[kids[1], kids[3]])
        return EXPR(kids[2], EXPR[kids[1], kids[3]], nothing, 0, 0)
    elseif length(kids) == 2 && kids[1].head === :OPERATOR && JuliaSyntax.is_operator(k)
        # Remaining prefix-unary-syntax-head kinds (e.g. `&x`), same shape
        # as bare `::T` above; same last-resort placement rationale.
        return EXPR(kids[1], EXPR[kids[2]], nothing, 0, 0)
    elseif k == K"error"
        # A non-leaf error node (e.g. wraps an unexpected token, or is
        # entirely childless — a missing-token marker). CSTParser has no
        # equivalent shape for this; mirror the leaf errortoken so the
        # subtree stays traversable and spans still tile.
        return EXPR(:errortoken, kids, nothing, 0, 0)
    end
    return generic_form(k, kids, kkinds)
end
