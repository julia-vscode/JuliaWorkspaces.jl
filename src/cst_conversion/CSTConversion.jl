module CSTConversion

using CSTParser
using CSTParser: EXPR
using JuliaSyntax
using JuliaSyntax: GreenNode, Kind, @K_str, kind, haschildren, children, span

include("compare.jl")
include("tokens.jl")
include("terminals.jl")

export first_tree_diff, trees_equal, Leaf, flatten_leaves, is_ws_trivia, build_cst, oracle_diff

function build_cst(source::AbstractString)
    stream = JuliaSyntax.ParseStream(source; version=VERSION)
    JuliaSyntax.parse!(stream; rule=:all)
    build_cst(JuliaSyntax.build_tree(GreenNode, stream), source)
end

function build_cst(green::GreenNode, source::AbstractString)
    src = String(source)
    isempty(src) && return EXPR(:file, EXPR[], EXPR[], 0, 0)
    leaves, leading = flatten_leaves(green, src)
    file = EXPR(:file, EXPR[], nothing, 0, 0)
    attach_leading!(file, leading)
    for expr in terminal_exprs(leaves, src)
        push!(file, expr)  # CSTParser extends Base.push! with span updates
    end
    return file
end

# Oracle-pinned: leading file trivia (whitespace/comments before the first
# token, or the whole file when there is no token at all) becomes its own
# :NOTHING leaf at the front of file.args — it does not widen the first
# token's fullspan.
function attach_leading!(file::EXPR, leading::Int)
    leading == 0 && return file
    push!(file, EXPR(:NOTHING, leading, leading, ""))
    return file
end

end
