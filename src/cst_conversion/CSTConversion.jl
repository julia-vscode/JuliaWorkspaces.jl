module CSTConversion

using CSTParser
using CSTParser: EXPR
using JuliaSyntax
using JuliaSyntax: GreenNode, Kind, @K_str, kind, haschildren, children, span

include("compare.jl")

export first_tree_diff, trees_equal

end
