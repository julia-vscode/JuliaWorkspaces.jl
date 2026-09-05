# Producing an expansion the host can parse back. Only `Base` is needed
# here, so the file can be loaded on its own in tests.

# `macroexpand(recursive=true)` does not descend into an `Expr(:toplevel)`
# result (BitFlags' `@bitflag`, `@enum`-style DSLs), leaving `hygienic-scope`
# nodes that `string` can only print as `$(Expr(...))` — unparseable on the
# host. Expand each top-level statement itself and hand the result back as a
# plain block, which prints as ordinary code.
#
# Line-number nodes go too: `string` prints them as `#= file:line =#`
# comments, which is fine inside a block but not where a macro left one in
# an expression slot — Base's logging macros put one first in the condition
# of an `if`, printing `if #= logging.jl:386 =#, try …` (PlotsBase's
# `@attributes function … @maxlog_warn … end`). The host reads positions
# from the user's source, never from the expansion text.
function _expand_fully(mod::Module, expr)
    expanded = macroexpand(mod, expr; recursive=true)
    if expanded isa Expr && expanded.head === :toplevel
        expanded = Expr(:block, (macroexpand(mod, a; recursive=true) for a in expanded.args)...)
    end
    expanded isa Expr && Base.remove_linenums!(expanded)
    return expanded
end
