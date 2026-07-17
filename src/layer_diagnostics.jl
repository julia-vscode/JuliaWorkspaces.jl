# StaticLint diagnostics that depend on environment data (package symbols) being fully loaded.
# These are suppressed until the environment is ready to avoid false positives from unresolved imports.
const _ENV_DEPENDENT_LINT_MESSAGES = Set{String}([
    StaticLint.LintCodeDescriptions[StaticLint.IncorrectCallArgs],
    StaticLint.LintCodeDescriptions[StaticLint.IncorrectIterSpec],
    StaticLint.LintCodeDescriptions[StaticLint.NothingEquality],
    StaticLint.LintCodeDescriptions[StaticLint.InvalidTypeDeclaration],
    StaticLint.LintCodeDescriptions[StaticLint.TypePiracy],
    StaticLint.LintCodeDescriptions[StaticLint.KwDefaultMismatch],
])

function _is_env_dependent_diagnostic(d::Diagnostic)
    d.source != "StaticLint.jl" && return false
    startswith(d.message, "Missing reference:") && return true
    startswith(d.message, "Failed to resolve `") && return true
    return d.message in _ENV_DEPENDENT_LINT_MESSAGES
end

Salsa.@derived function derived_lintconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_lintconfig_file(uri2filepath(file))]
end


Salsa.@derived function derived_lintconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    valid_lint_configs = [
        "syntax-errors", "syntax-warnings", "testitem-errors", "toml-syntax-errors", "lint-config-errors",
        "static-lint",
        "call", "iter", "nothingcomp", "constif", "lazy", "datadecl", "typeparam", "modname", "pirates", "useoffuncargs",
        "kwdefault", "literal", "break-continue", "constdecl",
        "missing-refs",
        "format-config-errors",
    ]

    string_valued_configs = Dict{String,Vector{String}}(
        "missing-refs" => ["none", "symbols", "all"],
    )

    for (k,v) in pairs(toml_content)
        if !(k in valid_lint_configs)
            push!(res, Diagnostic(1:1, :error, "Invalid lint configuration $k.", nothing, Symbol[], "JuliaWorkspaces.jl"))
        end

        if haskey(string_valued_configs, k)
            if !(v isa String) || !(v in string_valued_configs[k])
                valid_values = join(string_valued_configs[k], ", ")
                push!(res, Diagnostic(1:1, :error, "Invalid lint configuration value for $k, only $valid_values are valid.", nothing, Symbol[], "JuliaWorkspaces.jl"))
            end
        elseif !(v isa Bool)
            push!(res, Diagnostic(1:1, :error, "Invalid lint configuration value for $k, only `true` or `false` are valid.", nothing, Symbol[], "JuliaWorkspaces.jl"))
        end
    end

    return res
end

Salsa.@derived function derived_lint_configuration(rt, uri)
    @debug "derived_lint_configuration" uri=uri

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

function _lint_options_from_config(lint_config::Dict)
    StaticLint.LintOptions(
        get(lint_config, "call", true)::Bool,
        get(lint_config, "iter", true)::Bool,
        get(lint_config, "nothingcomp", true)::Bool,
        get(lint_config, "constif", true)::Bool,
        get(lint_config, "lazy", true)::Bool,
        get(lint_config, "datadecl", true)::Bool,
        get(lint_config, "typeparam", true)::Bool,
        get(lint_config, "modname", true)::Bool,
        get(lint_config, "pirates", true)::Bool,
        get(lint_config, "useoffuncargs", true)::Bool,
        get(lint_config, "kwdefault", true)::Bool,
        get(lint_config, "literal", true)::Bool,
        get(lint_config, "break-continue", true)::Bool,
        get(lint_config, "constdecl", true)::Bool,
    )
end

function _missingrefs_from_config(lint_config::Dict)
    val = get(lint_config, "missing-refs", "all")
    val == "none" && return :none
    val == "symbols" && return :id
    val == "all" && return :all
    return :all  # fallback
end

Salsa.@derived function derived_diagnostics(rt, uri)
    @debug "derived_diagnostics" uri=uri

    # Indirect files participate in the include graph (so cross-file
    # resolution works) but never report diagnostics — they are not files
    # the user explicitly asked the LS to track.
    if derived_is_indirect_file(rt, uri)
        return Diagnostic[]
    end

    if !(uri in derived_text_files(rt))
        error("Invalid uri $uri")
    end

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
            append!(results, Diagnostic(i.range, :error, i.message, nothing, Symbol[], "Testitem") for i in tis.testerrors)
        end

        if is_path_julia_file(uri2filepath(uri)) && get(lint_config, "static-lint", true) == true
            sl = derived_new_static_lint_diagnostics(rt, uri)
            env_ready = derived_file_env_ready(rt, uri)
            if env_ready
                append!(results, sl)
            else
                append!(results, d for d in sl if !_is_env_dependent_diagnostic(d))
            end

            # Include-graph diagnostics (DuplicateInclude / IncludeLoop /
            # MissingFile) are a purely structural analysis that does not depend
            # on a project/environment, so they are reported independently of the
            # semantic static-lint pass above.
            append!(results, derived_include_diagnostics(rt, uri))
        end

        if (is_path_lintconfig_file(uri2filepath(uri)) || is_path_formatconfig_file(uri2filepath(uri)) || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri)) ) && get(lint_config, "toml-syntax-errors", true) == true
            toml_syntax_errors = derived_toml_syntax_diagnostics(rt, uri)
            append!(results, toml_syntax_errors)
        end

        if is_path_lintconfig_file(uri2filepath(uri)) && get(lint_config, "lint-config-errors", true) == true
            lint_config_errors = derived_lintconfig_diagnostics(rt, uri)
            append!(results, lint_config_errors)
        end

        if is_path_formatconfig_file(uri2filepath(uri)) && get(lint_config, "format-config-errors", true) == true
            format_config_errors = derived_formatconfig_diagnostics(rt, uri)
            append!(results, format_config_errors)
        end
    end

    return results
end

Salsa.@derived function derived_all_diagnostics(rt)
    files = derived_text_files(rt)

    results = Dict{URI,Vector{Diagnostic}}()
    for uri in files
        results[uri] = derived_diagnostics(rt, uri)
        # Computing diagnostics for a whole workspace is one of the longest
        # uninterrupted computations on the calling task; yield between files
        # so cooperatively scheduled tasks (the dynamic-feature reactor,
        # connection handling in a host) aren't starved for its duration.
        yield()
    end

    return results
end
