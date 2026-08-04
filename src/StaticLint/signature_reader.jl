"""
    where_var_and_bound(x::EXPR)

One `where`-clause entry → `(name, upper_bound_expr_or_nothing)`, or `nothing`
when the entry isn't a readable type-variable declaration. The only reader of
this grammar: a bare `T`, `T <: B`, the ascending chain `Lo <: T <: Hi`, and
the lower-bound forms (`T >: B`, descending chains), which yield no bound.
"""
function where_var_and_bound(x::EXPR)
    if isidentifier(x)
        n = valofid(x)
        return n === nothing ? nothing : (n, nothing)
    end
    if x.head isa EXPR && isoperator(x.head) && x.args !== nothing && length(x.args) == 2 &&
            isidentifier(x.args[1])
        n = valofid(x.args[1])
        n === nothing && return nothing
        valof(x.head) == "<:" && return (n, x.args[2])
        valof(x.head) == ">:" && return (n, nothing)
        return nothing
    end
    if headof(x) === :comparison && x.args !== nothing && length(x.args) == 5 &&
            headof(x.args[2]) === :OPERATOR && headof(x.args[4]) === :OPERATOR &&
            isidentifier(x.args[3])
        n = valofid(x.args[3])
        n === nothing && return nothing
        if valof(x.args[2]) == "<:" && valof(x.args[4]) == "<:"
            return (n, x.args[5])
        end
        return (n, nothing)
    end
    return nothing
end
