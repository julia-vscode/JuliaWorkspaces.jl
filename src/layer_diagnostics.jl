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

    if uri.scheme == "file"
        if is_path_julia_file(uri2filepath(uri)) && get(lint_config, "syntax-errors", true) == true || get(lint_config, "syntax-warnings", false) == true
            syntax_diagnostics = derived_julia_syntax_diagnostics(rt, uri)

            if get(lint_config, "syntax-errors", true) == true
                append!(results, i for i in syntax_diagnostics if i.severity==:error)
            end

            if get(lint_config, "syntax-warnings", false) == true
                append!(results, i for i in syntax_diagnostics if i.severity==:warning)
            end
        end

        if is_path_julia_file(uri2filepath(uri)) && get(lint_config, "testitem-errors", true) == true
            tis = derived_testitems(rt, uri)
            append!(results, Diagnostic(i.range, :error, i.message, "Testitem") for i in tis.testerrors)
        end

        if (is_path_lintconfig_file(uri2filepath(uri)) || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri)) ) && get(lint_config, "toml-syntax-errors", true) == true
            toml_syntax_errors = derived_toml_syntax_diagnostics(rt, uri)
            append!(results, toml_syntax_errors)
        end

        if is_path_lintconfig_file(uri2filepath(uri)) && get(lint_config, "lint-config-errors", true) == true
            lint_config_errors = derived_lintconfig_diagnostics(rt, uri)
            append!(results, lint_config_errors)
        end
    end

    return results
end

Salsa.@derived function derived_diagnostics(rt)
    files = derived_text_files(rt)

    results = Diagnostic[]

    for f in files
        append!(results, derived_diagnostics(rt, f))
    end

    return results
end

Salsa.@derived function derived_diagnostic_updated_since_mark(rt)
    marked_versions = input_marked_diagnostics(rt)

    old_text_files = keys(marked_versions)
    current_text_files = derived_text_files(rt)

    deleted_files = setdiff(old_text_files, current_text_files)
    updated_files = Set{URI}()

    for uri in current_text_files
        if !(uri in old_text_files)
            push!(updated_files, uri)
        else
            new_diag = derived_diagnostics(rt, uri)

            if hash(marked_versions[uri]) != hash(new_diag)
                push!(updated_files, uri)
            end
        end
    end

    return updated_files, deleted_files
end

function get_diagnostic(jw::JuliaWorkspace, uri::URI)
    return derived_diagnostics(jw.runtime, uri)
end

function get_diagnostics(jw::JuliaWorkspace)
    return derived_diagnostics(jw.runtime)
end

function mark_current_diagnostics(jw::JuliaWorkspace)
    files = derived_text_files(jw.runtime)

    results = Dict{URI,Vector{Diagnostic}}()

    for f in files
        results[f] = derived_diagnostics(jw.runtime, f)
    end
    set_input_marked_diagnostics!(jw.runtime, results)
end

function get_files_with_updated_diagnostics(jw::JuliaWorkspace)
    return derived_diagnostic_updated_since_mark(jw.runtime)
end
