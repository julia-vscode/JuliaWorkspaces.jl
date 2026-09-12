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

"""
    derived_julia_legacy_syntax_tree(rt, uri)

The CSTParser tree for the Julia document `uri`.

**Only ever call this for a Julia document.** The legacy parser reads a whole
file as Julia source, so handing it Markdown or TOML produces garbage at best —
and, as seen in the wild, can trip CSTParser's own infinite-loop guard. Callers
must gate on [`_is_julia_uri`](@ref) first; the public API does this at its
entry points in `public.jl`, and the internal walks only ever reach files
admitted by `derived_julia_files` / `derived_all_julia_files`.

Throws `JWUnknownFile` if `uri` has no content, and `JWNotAJuliaFile` if it is
not a Julia document. Both are contract violations: a missed gate should surface
as a crash report naming the caller, not as a silently empty tree that makes
every CST-derived feature disappear without explanation.
"""
Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    @debug "derived_julia_legacy_syntax_tree" uri=uri

    tf = derived_text_file_content(rt, uri)

    tf === nothing && throw(JWUnknownFile("Requested a legacy syntax tree for $uri, which has no content."))

    _is_julia_uri(rt, uri) || throw(JWNotAJuliaFile("Requested a legacy syntax tree for $uri, which is not a Julia document."))

    content = tf.content.content

    cst = CSTParser.parse(content, true)

    return cst
end

Salsa.@derived function derived_toml_parse_result(rt, uri)
    @debug "derived_toml_parse_result" uri=uri

    tf = derived_text_file_content(rt, uri)

    tf === nothing && return Dict{String,Any}(), Diagnostic[Diagnostic(1:1, :error, "File not found", nothing, Symbol[], "JuliaWorkspaces")]

    content = tf.content.content

    parse_result = Pkg.TOML.tryparse(content)

    if parse_result isa Pkg.TOML.ParserError
        return parse_result.table, Diagnostic[Diagnostic(parse_result.pos:parse_result.pos, :error, Base.TOML.format_error_message_for_err_type(parse_result), nothing, Symbol[], "TOML.jl")]
    else
        return parse_result, Diagnostic[]
    end
end

Salsa.@derived function derived_toml_syntax_tree(rt, uri)
    parse_result = derived_toml_parse_result(rt, uri)

    return parse_result[1]
end

Salsa.@derived function derived_toml_syntax_diagnostics(rt, uri)
    parse_result = derived_toml_parse_result(rt, uri)

    return parse_result[2]
end
