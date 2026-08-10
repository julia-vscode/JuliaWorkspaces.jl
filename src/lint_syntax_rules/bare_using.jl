# bare_using: `using Foo` without an explicit name list.
#
# Ported idea: ReLint's `bare using`. A bare `using` makes it impossible to
# tell at the use site where a name comes from; `using Foo: x, y` (or
# `import Foo`) keeps the provenance explicit. `using Foo: x` parses as a
# `K":"` child and is fine; each direct `K"importpath"` child is one bare
# module.

const _BARE_USING_MESSAGE = "Prefer an explicit name list (`using Foo: x, y`) or `import Foo` over bare `using Foo`."

function _check_bare_using(emit!, node, _ctx)
    for c in children(node)
        kind(c) === K"importpath" && emit!(_node_range(c), _BARE_USING_MESSAGE)
    end
    return nothing
end

const BARE_USING_CHECK = SyntaxCheck(:bare_using, (K"using",), _check_bare_using)
