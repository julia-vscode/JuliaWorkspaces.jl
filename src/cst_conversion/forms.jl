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

# Sibling `;` groups nest recursively: for `f(a; b; c)` the oracle stores
# the c-group inside the b-group at args[1]. Spans follow CSTParser's
# update_span convention — span measured to the last STORED arg, which
# after the relocation is not the source-last child.
function merge_params!(groups::Vector{EXPR})
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
                widen_at_leaf!(cur, semi_i - 1, ex.fullspan) ||
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
        # right after the callee; `a=b` positional args become `:kw`.
        args = EXPR[]
        trivia = EXPR[]
        groups = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"(" || ck == K")" || ck == K","
                push!(trivia, ex)
            elseif ck == K"parameters"
                push!(groups, ex)
            elseif ck == K"="
                push!(args, to_kw(ex))
            else
                push!(args, ex)
            end
        end
        isempty(groups) || insert!(args, 2, merge_params!(groups))
        return EXPR(:call, args, trivia, 0, 0)
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
                if widen_at_leaf!(cur, semi_i - 1, ex.fullspan)
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
    elseif k == K"block"
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"begin" || ck == K"end" || ck == K";") ? push!(trivia, ex) : push!(args, ex)
        end
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
