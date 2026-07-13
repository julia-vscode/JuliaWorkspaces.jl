module CSTConversion

using CSTParser
using CSTParser: EXPR
using JuliaSyntax
using JuliaSyntax: GreenNode, Kind, @K_str, kind, haschildren, children, span

include("compare.jl")
include("tokens.jl")
include("assembly.jl")    # defines Cursor (used in terminals.jl signatures)
include("terminals.jl")
include("forms.jl")

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
    cur = Cursor(leaves, 1, src, green)
    ex = assemble(green, cur)   # root green node is always kind K"toplevel"
    ex.head = :file
    ex.trivia = nothing
    attach_leading!(ex, leading)
    return ex
end

# Oracle-pinned: leading file trivia (whitespace/comments before the first
# token, or the whole file when there is no token at all) becomes its own
# :NOTHING leaf at the front of file.args — it does not widen the first
# token's fullspan. Prepended (not pushed) since assemble() already filled
# in the real args before this runs; span/fullspan grow by leading's width.
function attach_leading!(file::EXPR, leading::Int)
    leading == 0 && return file
    node = EXPR(:NOTHING, leading, leading, "")
    CSTParser.setparent!(node, file)
    pushfirst!(file.args, node)
    file.fullspan += leading
    file.span += leading
    return file
end

end
