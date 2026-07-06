struct Leaf
    kind::Kind
    pos::Int       # absolute first byte, 1-based
    span::Int      # bytes of the token itself
    fullspan::Int  # span + trailing trivia bytes
end

is_ws_trivia(k::Kind) = k == K"Whitespace" || k == K"NewlineWs" || k == K"Comment"

# Flattens the green tree into non-trivia tokens, folding each trivia token's
# width into the preceding token's fullspan (CSTParser's trivia model).
function flatten_leaves(green::GreenNode, source::AbstractString)
    leaves = Leaf[]
    leading = _flatten!(leaves, 0, green, 1)[2]
    return leaves, leading
end

function _flatten!(leaves::Vector{Leaf}, leading::Int, node::GreenNode, pos::Int)
    if !haschildren(node)
        w = Int(span(node))
        if is_ws_trivia(kind(node))
            if isempty(leaves)
                leading += w
            else
                l = leaves[end]
                leaves[end] = Leaf(l.kind, l.pos, l.span, l.fullspan + w)
            end
        else
            push!(leaves, Leaf(kind(node), pos, w, w))
        end
        return pos + w, leading
    end
    for c in children(node)
        pos, leading = _flatten!(leaves, leading, c, pos)
    end
    return pos, leading
end
