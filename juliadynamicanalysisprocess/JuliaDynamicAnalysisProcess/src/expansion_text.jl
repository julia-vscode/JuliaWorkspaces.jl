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
    expanded = _surface_form(expanded)
    expanded isa Expr && Base.remove_linenums!(expanded)
    return expanded
end

# Expression heads macros emit in LOWERED form, which `string` can only print
# as `$(Expr(…))` splices — unparseable, so the host treats the whole
# expansion as unmodelled. Rewritten to the surface form that means the same
# to a linter: `Expr(:isdefined, x)` (Base's logging macros) is `@isdefined x`;
# the inert markers `inbounds`/`boundscheck`/`meta`/`loopinfo`/GC-preserve and
# alias scopes declare nothing and vanish (`boundscheck` is `true`).
const _INERT_HEADS = (:inbounds, :meta, :loopinfo, :gc_preserve_begin, :gc_preserve_end,
                      :aliasscope, :popaliasscope)

function _surface_form(ex)
    ex isa Expr || return ex
    if ex.head === :isdefined && length(ex.args) == 1
        return Expr(:macrocall, Symbol("@isdefined"), nothing, _surface_form(ex.args[1]))
    elseif ex.head === :boundscheck
        return true
    elseif ex.head in _INERT_HEADS
        return nothing
    end
    return Expr(ex.head, (_surface_form(a) for a in ex.args)...)
end
