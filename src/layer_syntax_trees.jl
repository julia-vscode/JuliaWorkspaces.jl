Salsa.@derived function derived_julia_syntax_tree(rt, uri)
    tf = input_text_file(rt, uri)
    
    content = tf.content.content

    return JuliaSyntax.parse!(SyntaxNode, IOBuffer(content))
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
