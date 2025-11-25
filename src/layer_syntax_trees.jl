Salsa.@derived function derived_julia_parse_result(rt, uri)
    tf = input_text_file(rt, uri)

    content = tf.content.content

    stream = JuliaSyntax.ParseStream(content; version=VERSION)
    JuliaSyntax.parse!(stream; rule=:all)
    tree = JuliaSyntax.build_tree(SyntaxNode, stream)

    return tree, stream.diagnostics
end

Salsa.@derived function derived_julia_syntax_tree(rt, uri)
    parse_result = derived_julia_parse_result(rt, uri)

    return parse_result[1]
end

@static if isdefined(JuliaSyntax, :byte_range)
    _range(x) = JuliaSyntax.byte_range(x)
else
    _range(x) = range(x)
end

Salsa.@derived function derived_julia_syntax_diagnostics(rt, uri)
    parse_result = derived_julia_parse_result(rt, uri)

    diag_results = map(parse_result[2]) do i
        Diagnostic(
            _range(i),
            i.level,
            i.message,
            "JuliaSyntax.jl"
        )
    end

    return diag_results
end

Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    tf = input_text_file(rt, uri)

    content = tf.content.content

    cst = CSTParser.parse(content, true)

    return cst
end

Salsa.@derived function derived_toml_parse_result(rt, uri)
    tf = input_text_file(rt, uri)

    content = tf.content.content

    parse_result = Pkg.TOML.tryparse(content)

    if parse_result isa Pkg.TOML.ParserError
        return parse_result.table, Diagnostic[Diagnostic(parse_result.pos:parse_result.pos, :error, Base.TOML.format_error_message_for_err_type(parse_result), "TOML.jl")]
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
