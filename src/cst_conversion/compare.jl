# Structural equality of EXPR trees ignoring parent/meta.
# Returns nothing when equal, else a human-readable path to the first divergence.
function first_tree_diff(a::EXPR, b::EXPR; path::String="□")
    if typeof(a.head) != typeof(b.head)
        return "$path: head type $(typeof(a.head)) vs $(typeof(b.head))"
    end
    if a.head isa Symbol
        a.head === b.head || return "$path: head $(a.head) vs $(b.head)"
    else
        d = first_tree_diff(a.head, b.head; path="$path.head")
        d === nothing || return d
    end
    a.val == b.val || return "$path: val $(repr(a.val)) vs $(repr(b.val))"
    a.fullspan == b.fullspan || return "$path: fullspan $(a.fullspan) vs $(b.fullspan)"
    a.span == b.span || return "$path: span $(a.span) vs $(b.span)"
    for (field, fa, fb) in ((:args, a.args, b.args), (:trivia, a.trivia, b.trivia))
        (fa === nothing) == (fb === nothing) || return "$path: $field nothing-ness differs"
        fa === nothing && continue
        length(fa) == length(fb) || return "$path: $field length $(length(fa)) vs $(length(fb))"
        for i in eachindex(fa)
            d = first_tree_diff(fa[i], fb[i]; path="$path.$field[$i]")
            d === nothing || return d
        end
    end
    return nothing
end

trees_equal(a::EXPR, b::EXPR) = first_tree_diff(a, b) === nothing
