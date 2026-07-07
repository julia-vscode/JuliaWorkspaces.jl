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
        node.fullspan += width
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
    if ex.args === nothing
        ex.args = EXPR[]
        ex.trivia = EXPR[]
    end
    return ex
end

# Shared by call/dotcall/curly/macrocall arg lists: split into positional
# args, bracket/comma trivia, and `;`-groups (still unmerged/unrelocated —
# each caller decides where the merged group lands); `a=b` becomes `:kw`.
function collect_arglist(kids::Vector{EXPR}, kkinds::Vector{Kind}, open::Kind, close::Kind)
    args = EXPR[]
    trivia = EXPR[]
    groups = EXPR[]
    for (ex, ck) in zip(kids, kkinds)
        if ck == open || ck == close || ck == K","
            push!(trivia, ex)
        elseif ck == K"parameters"
            push!(groups, ex)
        elseif ck == K"="
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
        for (j, (ex, ck)) in enumerate(zip(kids, kkinds))
            if ck == K";"
                semi_i = first(cur.kid_ranges[j])
                fold_semi!(cur, semi_i, ex.fullspan) ||
                    (isempty(args) || (args[end].fullspan += ex.fullspan))
            else
                push!(args, ex)
            end
        end
        return EXPR(:toplevel, args, EXPR[], 0, 0)
    elseif k == K"call" && JuliaSyntax.is_infix_op_call(JuliaSyntax.head(node))
        # a + b (+ c ...) → (:call, [op, a, b, c...]); extra op tokens → trivia
        op = kids[2]
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
        return EXPR(:call, args, isempty(trivia) ? nothing : trivia, 0, 0)
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
    elseif k == K"." && length(kids) == 3
        # a.b / a.b.c → (:., [a, quotenode(b)]); dot is operator-headed like
        # ::/<:/->. The field-name side is always a K"quote" child (see the
        # branch below), already packaged as :quotenode by the time we see it.
        return EXPR(kids[2], EXPR[kids[1], kids[3]], nothing, 0, 0)
    elseif k == K"quote" && length(kids) <= 2
        # Field-name wrapper under getfield's `.`: bare `b`, or `:b` with an
        # explicit-quote colon kept as trivia.
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K":" ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:quotenode, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"curly"
        # A{T; S} → (:curly, [A, parameters, T]) — parameters relocates to
        # args[2] exactly like call's.
        args, trivia, groups = collect_arglist(kids, kkinds, K"{", K"}")
        isempty(groups) || insert!(args, 2, merge_params!(groups))
        return EXPR(:curly, args, trivia, 0, 0)
    elseif k == K"macrocall"
        # `@m x` fuses the `@` leaf and macro name into ONE IDENTIFIER
        # ("@m") — CSTParser never sees them as separate tokens. String/cmd
        # macro names (`m"str"`) are already a single mangled leaf (handled
        # in terminal_expr), nothing to fuse. A synthetic zero-width NOTHING
        # marker always follows the name; `;`-parameters relocate to right
        # after it (args[3]).
        if kkinds[1] == K"@"
            atex, nameex = kids[1], kids[2]
            name = EXPR(:IDENTIFIER, atex.fullspan + nameex.fullspan,
                        atex.span + nameex.span, "@" * nameex.val)
            rest, restk = kids[3:end], kkinds[3:end]
        else
            name = kids[1]
            rest, restk = kids[2:end], kkinds[2:end]
        end
        args, trivia, groups = collect_arglist(rest, restk, K"(", K")")
        args = EXPR[name, EXPR(:NOTHING, 0, 0, nothing), args...]
        isempty(groups) || insert!(args, 3, merge_params!(groups))
        return EXPR(:macrocall, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"do"
        # `f(x) do y ... end` desugars to a call plus a synthetic zero-width
        # `->` operator wrapping the (params-tuple, body-block) pair — no
        # literal `->` token exists in the source.
        call_ex = tuple_ex = block_ex = nothing
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"do" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K"tuple"
                tuple_ex = ex
            elseif ck == K"block"
                block_ex = ex
            else
                call_ex = ex
            end
        end
        fullspan = tuple_ex.fullspan + block_ex.fullspan
        span = fullspan - (block_ex.fullspan - block_ex.span)
        op = EXPR(:OPERATOR, 0, 0, "->")
        body = EXPR(op, EXPR[tuple_ex, block_ex], EXPR[], fullspan, span)
        return EXPR(:do, EXPR[call_ex, body], trivia, 0, 0)
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
    elseif (k == K"=" || k == K"->") && length(kids) == 3
        # binary syntax: operator EXPR becomes the head. Short-form function
        # defs (`f(x) = ...`, `f(x::T) where T = ...`) and `->` bodies wrap
        # their RHS in an implicit block; plain assignment does not, and an
        # explicit `begin ... end` RHS is never wrapped a second time.
        lhs, op, rhs = kids
        if k == K"=" && op.val != "="
            # for-loop/comprehension iteration spec (`i in xs`/`i ∈ xs`):
            # JuliaSyntax reuses K"=" regardless of the actual keyword; the
            # oracle always synthesizes a zero-width "=" head and relocates
            # the real in/∈ operator to trivia.
            head = EXPR(:OPERATOR, 0, 0, "=")
            return EXPR(head, EXPR[lhs, rhs], EXPR[op], 0, 0)
        end
        needs_block = (k == K"->" || kkinds[1] == K"call" || kkinds[1] == K"where") &&
                      kkinds[3] != K"block"
        body = needs_block ? EXPR(:block, EXPR[rhs], nothing, rhs.fullspan, rhs.span) : rhs
        return EXPR(op, EXPR[lhs, body], nothing, 0, 0)
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
            if ck == K"where"
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
        for (ex, ck) in zip(kids, kkinds)
            if ex.args === nothing && JuliaSyntax.is_keyword(ck)
                push!(trivia, ex)
            else
                push!(args, ex)
            end
        end
        return EXPR(k == K"if" ? :if : :elseif, args, trivia, 0, 0)
    elseif k == K"?"
        # ternary a ? b : c → (:if, [a, b, c], trivia=[?, :]) — reuses if's
        # head. Same kind-reuse trap as if/elseif: a NESTED ternary is a
        # composite K"?" kid, so only genuine leaves (`args === nothing`)
        # may be filed into trivia.
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ex.args === nothing && (ck == K"?" || ck == K":")
                push!(trivia, ex)
            else
                push!(args, ex)
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
        if restk[1] == K"false" && isempty(block.args)
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
        try_kw = end_kw = try_block = nothing
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
            else
                try_block = ex
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
        push!(trivia, end_kw)
        return EXPR(:try, args, trivia, 0, 0)
    elseif k == K"let"
        # bindings block collapses to its single item when there's exactly
        # one binding (`let x = 1` / `let x`); stays a :block for 0 or 2+.
        trivia = EXPR[]
        bindings = body = nothing
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"let" || ck == K"end"
                push!(trivia, ex)
            elseif bindings === nothing
                bindings = ex
            else
                body = ex
            end
        end
        length(bindings.args) == 1 && (bindings = bindings.args[1])
        return EXPR(:let, EXPR[bindings, body], trivia, 0, 0)
    elseif k == K"cartesian_iterator"
        # Multi-spec `for`/generator iteration (`i = 1:10, j in ys`) → a
        # synthetic :block of iteration specs with comma trivia.
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == K"," ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:block, args, trivia, 0, 0)
    elseif k == K"comprehension"
        trivia = EXPR[kids[1], kids[end]]
        return EXPR(:comprehension, EXPR[kids[2]], trivia, 0, 0)
    elseif k == K"generator"
        # [expr for spec] → (:generator, [expr, spec], trivia=[for]); a
        # multi-spec cartesian_iterator FLATTENS its args/trivia directly
        # into generator's own (unlike `for`, which keeps it as a nested
        # :block) — confirmed via dump: comma lands in generator's trivia.
        # Multiple `for` clauses (`[x for a in as for b in bs]`) are ONE
        # flat green node, but the oracle nests them INVERTED — innermost
        # generator holds the body + LAST clause, each enclosing level adds
        # the next-earlier clause, and every multi-clause generator gets a
        # :flatten wrapper (child levels included, the innermost single-
        # clause one excluded). Nested levels are discontiguous in source,
        # so their spans are hand-built from child fullspan sums.
        body = kids[1]
        groups = Tuple{EXPR,EXPR,Kind}[]   # (for_kw, spec, spec_kind)
        j = 2
        while j <= length(kids)
            push!(groups, (kids[j], kids[j+1], kkinds[j+1]))
            j += 2
        end
        function gen_level(child::EXPR, kw::EXPR, spec::EXPR, sk::Kind)
            args = EXPR[child]
            trivia = EXPR[kw]
            if sk == K"cartesian_iterator"
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
        !isempty(kkinds) && kkinds[end] == K";" &&
            (cur.trim_span += trailing_semi_span(kids, kkinds))
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
        length(cells) >= 2 && foreach(matrix_cell!, cells)
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
        !isempty(kkinds) && kkinds[end] == K";" &&
            (cur.trim_span += trailing_semi_span(kids, kkinds))
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
        length(cells) >= 2 && foreach(matrix_cell!, cells)
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
            if ck == K"begin" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K","
                # `let`'s bindings list reuses K"block" for its comma-joined
                # `=` items; a plain statement block never has raw commas.
                push!(trivia, ex)
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
                    j == length(kids) && (cur.trim_span += ex.span)
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
        trivia = EXPR[kids[1], kids[end]]
        return EXPR(:brackets, kids[2:end-1], trivia, 0, 0)
    elseif k == K"function"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"function" || ck == K"end") ? push!(trivia, ex) : push!(args, ex)
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
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"mutable"
                is_mutable = true
                push!(trivia, ex)
            elseif ck == K"struct" || ck == K"end"
                push!(trivia, ex)
            elseif ck == K"block"
                body = ex
            else
                sig = ex
            end
        end
        marker = EXPR(is_mutable ? :TRUE : :FALSE, 0, 0, nothing)
        return EXPR(:struct, EXPR[marker, sig, body], trivia, 0, 0)
    elseif k == K"abstract"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"abstract" || ck == K"type" || ck == K"end") ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:abstract, args, trivia, 0, 0)
    elseif k == K"primitive"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"primitive" || ck == K"type" || ck == K"end") ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:primitive, args, trivia, 0, 0)
    elseif k == K"macro"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"macro" || ck == K"end") ? push!(trivia, ex) : push!(args, ex)
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
            else
                name = ex
            end
        end
        marker = EXPR(is_bare ? :FALSE : :TRUE, 0, 0, nothing)
        return EXPR(:module, EXPR[marker, name, body], trivia, 0, 0)
    elseif k == K"const" || k == K"global" || k == K"local"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            ck == k ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(Symbol(lowercase(string(k))), args, trivia, 0, 0)
    end
    return generic_form(k, kids, kkinds)
end
