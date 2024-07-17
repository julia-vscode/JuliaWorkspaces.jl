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

Salsa.@derived function derived_julia_syntax_diagnostics(rt, uri)
    parse_result = derived_julia_parse_result(rt, uri)

    diag_results = map(parse_result[2]) do i
        Diagnostic(
            range(i),
            i.level,
            i.message,
            "JuliaSyntax.jl"
        )
    end

    return diag_results
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

function get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_julia_syntax_tree(jw.runtime, uri)
end

function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_toml_syntax_tree(jw.runtime, uri)
end
