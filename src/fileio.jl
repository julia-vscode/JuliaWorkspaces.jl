function workspace_from_folders(workspace_folders::Vector{URI})
    new_text_documents = isempty(workspace_folders) ? Dict{URI,TextDocument}() : merge((read_path_into_textdocuments(path) for path in workspace_folders)...)

    new_julia_syntax_trees = Dict{URI,SyntaxNode}()
    new_toml_syntax_trees = Dict{URI,Dict}()
    new_diagnostics = Dict{URI,Vector{JuliaSyntax.Diagnostic}}()
    for (k,v) in pairs(new_text_documents)
        if endswith(lowercase(string(k)), ".jl")
            node, diag = parse_julia_file(get_text(v))
            new_julia_syntax_trees[k] = node
            new_diagnostics[k] = diag
        elseif endswith(lowercase(string(k)), ".toml")
            # try
                new_toml_syntax_trees[k] = parse_toml_file(get_text(v))
            # catch err
                # TODO Add some diagnostics
            # end
        end
    end

    new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

    new_jw = JuliaWorkspace(
        workspace_folders,
        new_text_documents,
        new_julia_syntax_trees,
        new_toml_syntax_trees,
        new_diagnostics,        
        new_packages,
        new_projects,
        SemanticPassTests.semantic_pass_tests(workspace_folders, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
    )

    return new_jw
end
