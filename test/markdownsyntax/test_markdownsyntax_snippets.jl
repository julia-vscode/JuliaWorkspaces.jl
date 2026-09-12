# Shared helpers of the MarkdownSyntax suite. Snippets are package-global, so
# every test_markdownsyntax_*.jl file uses `setup=[MdTS]`.
@testsnippet MdTS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: MarkdownSyntax
    using JuliaWorkspaces.MarkdownSyntax: MarkdownNode, JuliaChunk
    const MD = MarkdownSyntax

    # Bytes fb..lb (inclusive) of `src`; "" for a zero-width range.
    slice(src, r) = String(codeunits(src)[r])

    # The chunk table as (fence_kind, name, covered text) triples.
    chunk_rows(src) = [(c.fence_kind, c.name, slice(src, c.code_range)) for c in MD.julia_chunks(src)]

    # The structural (trivia-free) children of the document as
    # (kind string, covered text) pairs.
    function blocks(src)
        tree = MD.parsemd(src)
        JS = MD.JuliaSyntax
        return [(string(JS.kind(n)), slice(src, Int(first(JS.byte_range(n))):Int(last(JS.byte_range(n)))))
                for n in JS.children(tree)]
    end
end
