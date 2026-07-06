# Default-value/kwarg `a=b` inside a call's arg list is `:kw`, not the
# operator-as-head binary form: repackage the already-assembled `=` EXPR
# (same leaf spans, just relabeled) into CSTParser's kw shape.
to_kw(ex::EXPR) = EXPR(:kw, ex.args, EXPR[ex.head], ex.fullspan, ex.span)

# Widen the trailing edge of a subtree by `excess` fullspan, recursing down
# the rightmost arg each level (mirrors how trailing trivia normally only
# ever bumps fullspan, never span, all the way down to the actual last leaf).
function widen_trailing!(ex::EXPR, excess::Int)
    ex.fullspan += excess
    ex.args === nothing || isempty(ex.args) || widen_trailing!(ex.args[end], excess)
end

function assemble_form(k::Kind, node::GreenNode, kids::Vector{EXPR}, kkinds::Vector{Kind}, cur::Cursor)::EXPR
    if k == K"toplevel"
        # Both the file root and semicolon-joined statement sequences share
        # this kind (build_cst renames the root's head to :file afterward).
        # Bare `;` separators are dropped entirely; their width is folded
        # into the preceding statement's fullspan, oracle-style.
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K";"
                isempty(args) || (args[end].fullspan += ex.fullspan)
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
        params = nothing
        last_pushed = nothing
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"(" || ck == K")" || ck == K","
                push!(trivia, ex)
                last_pushed = ex
            elseif ck == K"parameters"
                # The leading `;` isn't its own trivia in the oracle shape
                # (K"parameters" branch drops it); fold its width into
                # whatever immediately precedes it here, oracle-style.
                excess = ex.fullspan - sum(c -> c.fullspan, ex.args; init=0) -
                         (ex.trivia === nothing ? 0 : sum(c -> c.fullspan, ex.trivia; init=0))
                if excess > 0 && last_pushed !== nothing
                    widen_trailing!(last_pushed, excess)
                    ex.fullspan -= excess
                    ex.span -= excess
                end
                params = ex
                last_pushed = ex
            elseif ck == K"="
                kw = to_kw(ex)
                push!(args, kw)
                last_pushed = kw
            else
                push!(args, ex)
                last_pushed = ex
            end
        end
        params === nothing || insert!(args, 2, params)
        return EXPR(:call, args, trivia, 0, 0)
    elseif k == K"parameters"
        # `; z, w=1` after a call's semicolon → (:parameters, [z, kw(w=1)], trivia=[,]).
        # The leading `;` is dropped entirely (not even trivia); its width
        # is folded into the preceding call-level sibling by the K"call"
        # branch, which is the only place that sibling is reachable.
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K";"
                continue
            elseif ck == K","
                push!(trivia, ex)
            elseif ck == K"="
                push!(args, to_kw(ex))
            else
                push!(args, ex)
            end
        end
        return EXPR(:parameters, args, trivia, 0, 0)
    elseif (k == K"=" || k == K"->") && length(kids) == 3
        # binary syntax: operator EXPR becomes the head. Short-form function
        # defs (`f(x) = ...`, `f(x::T) where T = ...`) and `->` bodies wrap
        # their RHS in an implicit block; plain assignment does not.
        lhs, op, rhs = kids
        needs_block = k == K"->" || kkinds[1] == K"call" || kkinds[1] == K"where"
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
