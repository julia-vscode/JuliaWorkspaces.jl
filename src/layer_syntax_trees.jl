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

Salsa.@derived function derived_julia_syntax_diagnostics(rt, uri)
    tf = derived_text_file_content(rt, uri)

    _, syntax_diagnostics = parse_julia_syntax_tree(tf.content.content)

    diag_results = map(syntax_diagnostics) do i
        Diagnostic(
            _range(i),
            i.level,
            i.message,
            nothing,
            Symbol[],
            "JuliaSyntax.jl"
        )
    end

    return diag_results
end

Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    @debug "derived_julia_legacy_syntax_tree" uri=uri

    tf = derived_text_file_content(rt, uri)

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
