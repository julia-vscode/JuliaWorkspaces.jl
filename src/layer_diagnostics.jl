Salsa.@derived function derived_lintconfig_files(rt)
    files = derived_text_files(rt)

    println(files)

    return [file for file in files if file.scheme=="file" && is_path_lintconfig_file(uri2filepath(file))]
end

Salsa.@derived function derived_lint_configuration(rt, uri)
    config_files = derived_lintconfig_files(rt)

    sort!(config_files, by=i->length(string(i)))

    configs = Dict{String,Any}()
    for config_file in config_files
        config_folder_path = dirname(uri2filepath(config_file))

        if startswith(uri2filepath(uri), config_folder_path)
            content_as_toml = derived_toml_syntax_tree(rt, config_file)

            for (k,v) in pairs(content_as_toml)
                configs[k] = v
            end
        end
    end

    return configs
end

Salsa.@derived function derived_diagnostics(rt, uri)
    lint_config = derived_lint_configuration(rt, uri)

    results = Diagnostic[]

    if get(lint_config, "syntax-errors", true) == true || get(lint_config, "syntax-errors", false) == true
        syntax_diagnostics = derived_julia_syntax_diagnostics(rt, uri)

        if get(lint_config, "syntax-errors", true) == true
            append!(results, i for i in syntax_diagnostics if i.severity==:error)
        end

        if get(lint_config, "syntax-errors", false) == true
            append!(results, i for i in syntax_diagnostics if i.severity==:warning)
        end
    end

    if get(lint_config, "testitem-errors", true) == true
        tis = derived_testitems(rt, uri)
        append!(results, Diagnostic(i.range, :error, i.message, "Testitem") for i in tis.testerrors)
    end


    return results
end

function get_diagnostic(jw::JuliaWorkspace, uri::URI)    
    return derived_diagnostics(jw.runtime, uri)
end
