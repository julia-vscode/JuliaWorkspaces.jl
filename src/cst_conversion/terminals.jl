# Mirrors CSTParser's literalmap/tokenkindtoheadmap, keyed by JuliaSyntax kind.
# K"String"/K"Char" are here for documentation only: the quote-content-quote
# triple JuliaSyntax emits for these is merged before terminal_expr ever sees
# the content leaf in isolation (see merge_quoted below).
const TERMINAL_HEADS = Dict{Kind,Symbol}(
    K"Identifier" => :IDENTIFIER,
    K"Integer"    => :INTEGER,
    K"Float"      => :FLOAT,
    K"HexInt"     => :HEXINT,
    K"BinInt"     => :BININT,
    K"OctInt"     => :OCTINT,
    K"Char"       => :CHAR,
    K"String"     => :STRING,
    K"true"       => :TRUE,
    K"false"      => :FALSE,
)

token_text(leaf::Leaf, source::String) = source[leaf.pos:prevind(source, leaf.pos + leaf.span)]

# Oracle-pinned: keyword- and punctuation-headed EXPRs carry the raw token
# text as val (CSTParser's tokenkindtoheadmap path always calls val(ps.t,ps)),
# not nothing.
function terminal_expr(leaf::Leaf, source::String)
    k = leaf.kind
    if JuliaSyntax.is_operator(k)
        return EXPR(:OPERATOR, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif JuliaSyntax.is_keyword(k)
        return EXPR(Symbol(uppercase(string(k))), leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif haskey(TERMINAL_HEADS, k)
        return EXPR(TERMINAL_HEADS[k], leaf.fullspan, leaf.span, token_text(leaf, source))
    else
        return EXPR(punctuation_head(k), leaf.fullspan, leaf.span, token_text(leaf, source))
    end
end

# Mirrors tokenkindtoheadmap's punctuation entries; extend as kinds show up
# in oracle diffs (unmapped kinds fail loudly with a KeyError, which is wanted
# during burn-down — the corpus runner catches and reports it).
const PUNCTUATION_HEADS = Dict{Kind,Symbol}(
    K"(" => :LPAREN,   K")" => :RPAREN,
    K"[" => :LSQUARE,  K"]" => :RSQUARE,
    K"{" => :LBRACE,   K"}" => :RBRACE,
    K"," => :COMMA,
    K"@" => :ATSIGN,   K"." => :DOT,
)
punctuation_head(k::Kind) = PUNCTUATION_HEADS[k]

# JuliaSyntax splits quoted literals into open-quote/content/close-quote
# leaves; CSTParser sees them as one STRING or CHAR token. Merges a run of
# leaves starting at a quote leaf into a single EXPR, returning the next
# unconsumed index. Interpolation and triple-quoted/cmd literals are out of
# scope here (Task 4 territory).
function merge_quoted(leaves::Vector{Leaf}, i::Int, source::String)
    open = leaves[i]
    j = i + 1
    content = nothing
    while leaves[j].kind != open.kind
        content = leaves[j]
        j += 1
    end
    close = leaves[j]
    fullspan = close.pos - open.pos + close.fullspan
    span = close.pos - open.pos + close.span
    if open.kind == K"\""
        val = content === nothing ? "" : token_text(content, source)
        return EXPR(:STRING, fullspan, span, val), j + 1
    else # K"'"
        val = source[open.pos:prevind(source, close.pos + close.span)]
        return EXPR(:CHAR, fullspan, span, val), j + 1
    end
end

# Converts a flat leaf run into EXPRs, merging quote-delimited literals.
function terminal_exprs(leaves::Vector{Leaf}, source::String)
    exprs = EXPR[]
    i = 1
    n = length(leaves)
    while i <= n
        leaf = leaves[i]
        if leaf.kind == K"\"" || leaf.kind == K"'"
            expr, i = merge_quoted(leaves, i, source)
            push!(exprs, expr)
        else
            push!(exprs, terminal_expr(leaf, source))
            i += 1
        end
    end
    return exprs
end
