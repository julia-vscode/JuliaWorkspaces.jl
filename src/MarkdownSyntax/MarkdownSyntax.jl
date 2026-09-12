# MarkdownSyntax: a block-level Markdown parser built on the language-agnostic
# core of JuliaSyntax 2.0 (kinds, green tree, cursors, source files), the same
# foundation as TomlSyntax.
#
# Deliberately BLOCK-LEVEL ONLY, and only the blocks that matter for finding
# embedded Julia code and protecting against false fences:
#   - fenced code blocks (backtick and tilde, CommonMark rules)
#   - indented code blocks (so a fence marker inside one is not a fence)
#   - YAML/TOML front matter (so its `---` lines are not prose)
#   - ATX headings (structure for future document symbols / folding)
# Everything else -- paragraphs, lists, quotes, inline markup -- is opaque
# prose trivia. Container blocks are NOT modelled, so a fence nested inside a
# list item is not recognised; Julia documentation overwhelmingly keeps fences
# at the margin, and CommonMark's container/lazy-continuation rules are a
# swamp this parser does not need.
#
# Layering (mirrors TomlSyntax, minus the token lexer: Markdown block
# structure is line-oriented, so the "lexer" is a line classifier and the
# parser emits directly into JuliaSyntax's flat postorder green-node buffer):
#   kinds.jl   kind registration and predicates
#   parser.jl  line classification + the block scanner over a minimal stream
#   tree.jl    `MarkdownNode`, the trivia-free AST (a `TreeNode{MarkdownData}`)
#   api.jl     `parsemd`, `julia_chunks`, `julia_shadow_source`
#
# Self-contained by design: only JuliaSyntax. Nothing from JuliaWorkspaces
# (Salsa, URIs, Diagnostic) is referenced, so the module can be lifted into a
# standalone package once JuliaSyntax 2.0 is released; the one line to change
# is the `using` below.
"""
    MarkdownSyntax

A block-level Markdown parser on the JuliaSyntax 2.0 core: `parsemd` gives the
document as a syntax tree (`MarkdownNode`) with byte ranges, `julia_chunks`
lists the fenced code blocks whose info string marks them as Julia, and
`julia_shadow_source` renders the document as byte-offset-preserving Julia
source (chunk bytes verbatim, everything else whitespace).
"""
module MarkdownSyntax

using ..VendoredLowering: JuliaSyntax   # standalone package: `using JuliaSyntax`
using .JuliaSyntax: Kind, @K_str, SyntaxHead, RawFlags, EMPTY_FLAGS, TRIVIA_FLAG,
    NON_TERMINAL_FLAG, RawGreenNode, GreenTreeCursor, RedTreeCursor,
    GreenNode, TreeNode, AbstractSyntaxData, SourceFile,
    kind, flags, head, is_trivia, is_error, is_leaf, is_terminal, is_non_terminal,
    children, numchildren, byte_range, first_byte, last_byte, span, sourcefile,
    filename, untokenize

include("kinds.jl")
include("parser.jl")
include("tree.jl")
include("api.jl")

public parsemd, julia_chunks, julia_shadow_source, build_tree, parse_markdown!,
    MarkdownNode, MarkdownData, MarkdownParseStream, JuliaChunk,
    is_md_trivia, is_md_nonterminal

end # module MarkdownSyntax
