# duplicate_branch_condition: an `elseif` condition identical to an earlier
# condition in the same chain makes the branch unreachable.
#
# Ported idea: ReLint's `unreachable branch`.

# A repeated condition only makes the later branch dead when evaluating the
# earlier one cannot have changed anything, so the rule restricts itself to
# conditions built from identifiers, literals, field access, indexing and
# operator calls. A condition containing an arbitrary function or macro call
# (`rand() < 0.5`, `readline() == "y"`) can legitimately differ between
# evaluations and is never reported.
function _side_effect_free(node::SyntaxNode)
    JuliaSyntax.is_leaf(node) && return true   # identifiers and literals
    k = kind(node)
    cs = children(node)
    if k === K"call" || k === K"dotcall"
        isempty(cs) && return false
        if JuliaSyntax.is_infix_op_call(node)
            op = _op_symbol(cs[2])
            op !== nothing && Base.isoperator(op) || return false
            return all(_side_effect_free(cs[i]) for i in eachindex(cs) if i != 2)
        else
            op = _op_symbol(cs[1])
            op !== nothing && Base.isoperator(op) || return false
            return all(_side_effect_free, @view cs[2:end])
        end
    elseif k === K"parens" || k === K"&&" || k === K"||" || k === K"comparison" ||
           k === K"." || k === K"ref" || k === K"quote"
        return all(_side_effect_free, cs)
    else
        return false
    end
end

const _DUPLICATE_BRANCH_MESSAGE = "This condition is identical to an earlier condition in the same `if`/`elseif` chain, so this branch can never run."

function _check_duplicate_branch_condition(emit!, node, _ctx)
    # Registered on `K"if"` only; the `elseif` chain is walked from here so
    # each chain is examined exactly once.
    conditions = SyntaxNode[]
    current = node
    while true
        cs = children(current)
        isempty(cs) && return nothing
        condition = cs[1]
        for earlier in conditions
            if _syntax_equal(earlier, condition) && _side_effect_free(condition)
                emit!(_node_range(condition), _DUPLICATE_BRANCH_MESSAGE)
                break
            end
        end
        push!(conditions, condition)
        kind(cs[end]) === K"elseif" || return nothing
        current = cs[end]
    end
end

const DUPLICATE_BRANCH_CONDITION_CHECK = SyntaxCheck(:duplicate_branch_condition, (K"if",), _check_duplicate_branch_condition)
