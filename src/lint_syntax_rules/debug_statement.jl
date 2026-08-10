# debug_statement: a leftover `@show`.
#
# Ported idea: ReLint's `show` rule. `@show` is an interactive debugging aid
# that prints straight to stdout; committed code usually wants a logging macro
# or nothing at all.

const _DEBUG_STATEMENT_MESSAGE = "`@show` looks like a leftover debug statement. Remove it or use a logging macro (`@info`, `@debug`)."

function _check_debug_statement(emit!, node, _ctx)
    _macro_name(node) === Symbol("@show") && emit!(_node_range(node), _DEBUG_STATEMENT_MESSAGE)
    return nothing
end

const DEBUG_STATEMENT_CHECK = SyntaxCheck(:debug_statement, (K"macrocall",), _check_debug_statement)
