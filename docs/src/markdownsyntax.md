# MarkdownSyntax

```@meta
CurrentModule = JuliaWorkspaces.MarkdownSyntax
```

`JuliaWorkspaces.MarkdownSyntax` is a block-level Markdown parser built on the
language-agnostic core of the vendored JuliaSyntax 2.0 (kinds, green tree,
cursors, source files), the same foundation as [TomlSyntax](tomlsyntax.md). It
recognises exactly the block structure needed to find embedded Julia code —
fenced code blocks, indented code blocks (so fence markers inside them are not
fences), front matter and ATX headings — and treats everything else as opaque
prose trivia. Container blocks (lists, quotes) are not modelled.

The workspace uses it to give Markdown (`.md`) and Julia Markdown (`.jmd`)
documents a **Julia view** (`layer_markdown.jl`): [`julia_chunks`](@ref) lists
the fences whose info string marks them as Julia — plain ` ```julia ` fences,
jmd/Quarto/Weave ` ```{julia ...} ` chunk headers, and Documenter's
plain-Julia block types (`@example`, `@setup`, `@repl`, `@eval`; doctests are
REPL transcripts and excluded) — and [`julia_shadow_source`](@ref) renders the
document with chunk bytes verbatim and every other byte blanked to whitespace,
byte-for-byte. Offsets in a parse of the shadow are offsets in the document,
so diagnostics, navigation and test items inside code fences need no position
mapping anywhere downstream.

The module itself depends only on JuliaSyntax, so it can become a standalone
package once JuliaSyntax 2.0 is released.

```@docs
MarkdownSyntax
```

## Julia chunks and the shadow source

```@docs
julia_chunks
julia_shadow_source
JuliaChunk
```

## Syntax trees

```@docs
parsemd
MarkdownNode
MarkdownData
build_tree
MarkdownParseStream
parse_markdown!
```

## Kind predicates

```@docs
is_md_trivia
is_md_nonterminal
```
