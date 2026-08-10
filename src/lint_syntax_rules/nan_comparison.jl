# nan_comparison: `x == NaN` / `x != NaN` always yield the same answer.
#
# Ported idea: JuliaCheck's `use-isnan-to-check-for-nan`. `===`/`!==` are
# deliberately not flagged (a legitimate bit-pattern test), nor are ordering
# comparisons (`<`, `<=`, …) — always false, but a different claim than this
# rule makes.

const _NAN_NAMES = (:NaN, :NaN16, :NaN32, :NaN64)
const _EQUALITY_OPS = (:(==), :(!=), :≠)

_is_nan_identifier(node) = kind(node) === K"Identifier" && node.val isa Symbol && node.val in _NAN_NAMES

const _NAN_COMPARISON_MESSAGE = "Comparing with `NaN` using `==` or `!=` always yields the same result. Use `isnan` instead."

function _check_nan_comparison(emit!, node, _ctx)
    cs = children(node)
    if kind(node) === K"comparison"
        # Chained comparison: operands at odd indices, operators at even ones.
        for i in 2:2:length(cs)-1
            if _op_symbol(cs[i]) in _EQUALITY_OPS && (_is_nan_identifier(cs[i-1]) || _is_nan_identifier(cs[i+1]))
                emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
                return nothing
            end
        end
    elseif JuliaSyntax.is_infix_op_call(node)
        # `a == NaN`, `a .== NaN`
        if length(cs) == 3 && _op_symbol(cs[2]) in _EQUALITY_OPS &&
           (_is_nan_identifier(cs[1]) || _is_nan_identifier(cs[3]))
            emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
        end
    else
        # `==(a, NaN)`
        if length(cs) == 3 && _op_symbol(cs[1]) in _EQUALITY_OPS &&
           (_is_nan_identifier(cs[2]) || _is_nan_identifier(cs[3]))
            emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
        end
    end
    return nothing
end

const NAN_COMPARISON_CHECK = SyntaxCheck(:nan_comparison, (K"call", K"dotcall", K"comparison"), _check_nan_comparison)
