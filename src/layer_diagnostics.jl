Salsa.@derived function derived_lintconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_lintconfig_file(uri2filepath(file))]
end


Salsa.@derived function derived_lintconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    valid_lint_configs = ["syntax-errors", "syntax-warnings", "testitem-errors", "toml-syntax-errors", "lint-config-errors"]

    for (k,v) in pairs(toml_content)
        if !(k in valid_lint_configs)
            push!(res, Diagnostic(1:1, :error, "Invalid lint configuration $k.", "JuliaWorkspaces.jl"))
        end

        if !(v isa Bool)
            push!(res, Diagnostic(1:1, :error, "Invalid lint configuration value for $k, ony `true` or `false` are valid.", "JuliaWorkspaces.jl"))
        end
    end

    return res
end

Salsa.@derived function derived_lint_configuration(rt, uri)
    @assert uri.scheme === "file"

    config_files = derived_lintconfig_files(rt)

    config_files = sort(config_files, by=i->length(string(i)))

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
    results = Diagnostic[]

    uri.scheme != "file" && return results

    lint_config = derived_lint_configuration(rt, uri)
    path = uri2filepath(uri)

    if is_path_julia_file(path) && get(lint_config, "syntax-errors", true) == true || get(lint_config, "syntax-warnings", false) == true
        syntax_diagnostics = derived_julia_syntax_diagnostics(rt, uri)

        if get(lint_config, "syntax-errors", true) == true
            append!(results, i for i in syntax_diagnostics if i.severity==:error)
        end

        if get(lint_config, "syntax-warnings", false) == true
            append!(results, i for i in syntax_diagnostics if i.severity==:warning)
        end
    end

    if is_path_julia_file(path) && get(lint_config, "testitem-errors", true) == true
        tis = derived_testitems(rt, uri)
        append!(results, Diagnostic(i.range, :error, i.message, "Testitem") for i in tis.testerrors)
    end

    if (is_path_lintconfig_file(path) || is_path_project_file(path) || is_path_manifest_file(path) ) && get(lint_config, "toml-syntax-errors", true) == true
        toml_syntax_errors = derived_toml_syntax_diagnostics(rt, uri)
        append!(results, toml_syntax_errors)
    end

    if is_path_lintconfig_file(path) && get(lint_config, "lint-config-errors", true) == true
        lint_config_errors = derived_lintconfig_diagnostics(rt, uri)
        append!(results, lint_config_errors)
    end

    return results
end

Salsa.@derived function derived_all_diagnostics(rt)
    files = derived_text_files(rt)

    results = Dict{URI,Vector{Diagnostic}}(uri => derived_diagnostics(rt, uri) for uri in files)

    return results
end
