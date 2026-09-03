# Deliberately not a derived function: caching a tree per workspace file
# retains hundreds of MiB on large repos, and a fresh `SyntaxNode` never
# backdates (identity `isequal`) so the cache provides no early cutoff.
# Consumers parse on demand (~1 ms/file) and cache only their small,
# structurally-comparable outputs.
function parse_julia_syntax_tree(content::AbstractString)
    stream = JuliaSyntax.ParseStream(content; version=VERSION)
    JuliaSyntax.parse!(stream; rule=:all)
    tree = JuliaSyntax.build_tree(SyntaxNode, stream)

    return tree, stream.diagnostics
end

# JuliaSyntax byte ranges are 1-based with both endpoints inclusive,
# diagnostic ranges are 1-based with an exclusive end
_to_exclusive_end(r) = first(r):(last(r) + 1)

@static if isdefined(JuliaSyntax, :byte_range)
    _range(x) = _to_exclusive_end(JuliaSyntax.byte_range(x))
else
    _range(x) = _to_exclusive_end(range(x))
end

# A selector over the fused parse (layer_parse_products.jl): the parse is
# shared with test item detection and the syntax lint tier.
Salsa.@derived function derived_julia_syntax_diagnostics(rt, uri)
    return derived_julia_parse_products(rt, uri).syntax_diagnostics
end

Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    @debug "derived_julia_legacy_syntax_tree" uri=uri

    tf = derived_text_file_content(rt, uri)

    content = tf.content.content

    cst = CSTParser.parse(content, true)

    return cst
end

