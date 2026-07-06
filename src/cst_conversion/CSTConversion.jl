module CSTConversion

using CSTParser
using CSTParser: EXPR
using JuliaSyntax
using JuliaSyntax: GreenNode, Kind, @K_str, kind, haschildren, children, span

include("compare.jl")
include("tokens.jl")

export first_tree_diff, trees_equal, Leaf, flatten_leaves, is_ws_trivia

end
