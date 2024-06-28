Salsa.@derived function derived_julia_parse_result(rt, uri)
    tf = input_text_file(rt, uri)
    
    content = tf.content.content

    return JuliaSyntax.parse!(SyntaxNode, IOBuffer(content))
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

Salsa.@derived function derived_toml_syntax_tree(rt, uri)
    tf = input_text_file(rt, uri)
    
    content = tf.content.content

    return Pkg.TOML.parse(content)
end

function get_julia_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_julia_syntax_tree(jw.runtime, uri)
end

function get_toml_syntax_tree(jw::JuliaWorkspace, uri::URI)
    return derived_toml_syntax_tree(jw.runtime, uri)
end
