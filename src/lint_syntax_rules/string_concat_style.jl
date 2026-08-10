# string_concat_style: a string literal concatenated with `*`.
#
# Ported idea: ReLint's `string concatenation`. Only fires when a literal is
# involved — `a * b` on string variables is not distinguishable from numeric
# multiplication syntactically and is never reported.

const _STRING_CONCAT_MESSAGE = "Prefer string interpolation (`\"\$(x)…\"`) or `string(x, …)` over concatenating string literals with `*`."

_is_string_literal(node) = kind(node) === K"string"

function _check_string_concat_style(emit!, node, _ctx)
    cs = children(node)
    length(cs) >= 3 || return nothing
    if JuliaSyntax.is_infix_op_call(node)
        # `a * "b" * c` parses as one flattened infix call: the operator sits at
        # index 2, operands everywhere else.
        _op_symbol(cs[2]) === :* || return nothing
        any(_is_string_literal(cs[i]) for i in eachindex(cs) if i != 2) &&
            emit!(_node_range(node), _STRING_CONCAT_MESSAGE)
    else
        # `*(a, "b")`
        _op_symbol(cs[1]) === :* || return nothing
        any(_is_string_literal, @view cs[2:end]) &&
            emit!(_node_range(node), _STRING_CONCAT_MESSAGE)
    end
    return nothing
end

const STRING_CONCAT_STYLE_CHECK = SyntaxCheck(:string_concat_style, (K"call",), _check_string_concat_style)
