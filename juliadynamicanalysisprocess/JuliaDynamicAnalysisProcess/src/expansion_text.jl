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
# The scratch fallback module sees only what the imports export; a package's
# own UNEXPORTED macros (IrrationalConstants' `@irrational`) are visible in
# the real module only — and an expansion that fails there (the macro
# refuses to redefine a type the loaded package already has) then fails in
# the fallback for want of the macro. Bind every macro of the real module
# into the scratch module, so the fallback expands with `__module__` = the
# scratch module, where nothing is defined yet.
function _bind_real_macros!(scratch::Module, real::Module)
    for n in names(real; all = true, imported = false)
        s = String(n)
        (startswith(s, "@") && isdefined(real, n)) || continue
        isdefined(scratch, n) && continue
        try
            Core.eval(scratch, Expr(:const, Expr(:(=), n, GlobalRef(real, n))))
        catch err
            err isa InterruptException && rethrow()
        end
    end
    return scratch
end

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
    # `QuoteNode(x)` prints as a `$(QuoteNode(…))` splice — Test's `@test`
    # carries the original expression that way — but means the quoted
    # value, which `:(x)` spells parseably (interpolation inside is not a
    # concern for a linter).
    ex isa QuoteNode && return Expr(:quote, _surface_form(ex.value))
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
