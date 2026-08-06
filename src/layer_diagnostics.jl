# StaticLint findings that depend on environment data (package symbols) being
# fully loaded. These are suppressed until the environment is ready to avoid
# false positives from unresolved imports. Matching is on the rule id, so
# rephrasing a message (e.g. the detailed `describe_call_mismatch` text that
# replaces the generic `IncorrectCallArgs` one) cannot silently opt a finding
# out of the suppression.
function _is_env_dependent_diagnostic(d::Diagnostic)
    d.source != "StaticLint.jl" && return false
    d.code === nothing && return false
    return d.code in ENV_DEPENDENT_LINT_RULES
end

Salsa.@derived function derived_lintconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_lintconfig_file(uri2filepath(file))]
end


# Keys of the previous, flat `JuliaLint.toml` schema, mapped to advice naming
# their replacement. Reported instead of a bare "invalid key" so an existing
# config file tells its owner what to write instead.
const _LINT_CONFIG_MIGRATIONS = Dict{String,String}(
    "static-lint" => "set `preset` or individual entries under `[rules]`.",
    "syntax-errors" => "use `[rules] syntax_errors = \"error\"`.",
    "syntax-warnings" => "use `[rules] syntax_warnings = \"warning\"`.",
    "testitem-errors" => "use `[rules] testitem_errors = \"error\"`.",
    "toml-syntax-errors" => "use `[rules] toml_syntax_errors = \"error\"`.",
    "lint-config-errors" => "use `[rules] config_errors = \"error\"`.",
    "format-config-errors" => "use `[rules] config_errors = \"error\"`.",
    "call" => "use `[rules] incorrect_call_args = \"off\"`.",
    "iter" => "use `[rules] incorrect_iter_spec = \"off\"`.",
    "nothingcomp" => "use `[rules] nothing_comparison = \"off\"`.",
    "constif" => "use `[rules] const_if_condition = \"off\"`.",
    "lazy" => "use `[rules] pointless_boolean = \"off\"`.",
    "datadecl" => "use `[rules] invalid_type_declaration = \"off\"`.",
    "typeparam" => "use `[rules] unused_type_parameter = \"off\"`.",
    "modname" => "use `[rules] module_name = \"off\"`.",
    "pirates" => "use `[rules] type_piracy = \"off\"`.",
    "useoffuncargs" => "use `[rules] unused_function_argument = \"off\"`.",
    "kwdefault" => "use `[rules] kw_default_mismatch = \"off\"`.",
    "literal" => "use `[rules] literal_use = \"off\"`.",
    "break-continue" => "use `[rules] break_continue = \"off\"`.",
    "constdecl" => "use `[rules] global_const_decl = \"off\"`.",
    "missing-refs" => "use `[rules] missing_reference = { severity = \"warning\", scope = \"symbols\" }`.",
    "unresolved-import" => "use `[rules] unresolved_import = \"off\"`.",
)

const _LINT_CONFIG_TOP_LEVEL_KEYS = ["config-version", "preset", "include", "exclude", "rules", "override"]

# Validate one `[rules]` table, collecting `id => (severity, options)`.
function _validate_lint_rules!(res::Vector{Diagnostic}, table, into::Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}})
    table isa Dict || (push!(res, config_diagnostic("Invalid `[rules]`, expected a table.")); return into)

    for (k, v) in pairs(table)
        rule = get(LINT_RULES_BY_ID, Symbol(k), nothing)
        if rule === nothing
            if haskey(_LINT_CONFIG_MIGRATIONS, k)
                push!(res, config_diagnostic("`$k` is no longer supported: $(_LINT_CONFIG_MIGRATIONS[k])"))
            else
                push!(res, config_diagnostic("Unknown lint rule `$k`."))
            end
            continue
        end

        severity = nothing
        options = Dict{Symbol,Any}()

        if v isa AbstractString
            severity = get(SEVERITY_FROM_STRING, v, nothing)
            severity === nothing && push!(res, config_diagnostic(
                "Invalid severity `$v` for rule `$k`, expected one of $(join(VALID_SEVERITY_STRINGS, ", "))."))
        elseif v isa Dict
            for (ok, ov) in pairs(v)
                if ok == "severity"
                    if ov isa AbstractString && haskey(SEVERITY_FROM_STRING, ov)
                        severity = SEVERITY_FROM_STRING[ov]
                    else
                        push!(res, config_diagnostic(
                            "Invalid severity for rule `$k`, expected one of $(join(VALID_SEVERITY_STRINGS, ", "))."))
                    end
                elseif Symbol(ok) in rule.option_keys
                    options[Symbol(ok)] = ov
                else
                    push!(res, config_diagnostic("Unknown option `$ok` for rule `$k`."))
                end
            end
        else
            push!(res, config_diagnostic(
                "Invalid value for rule `$k`, expected a severity string or a table."))
            continue
        end

        # Rule-specific option validation.
        if rule.id === :missing_reference && haskey(options, :scope)
            sc = options[:scope]
            if !(sc isa AbstractString) || !(sc in ("none", "symbols", "all"))
                push!(res, config_diagnostic(
                    "Invalid `scope` for rule `missing_reference`, expected one of none, symbols, all."))
                delete!(options, :scope)
            end
        end

        into[rule.id] = (severity, options)
    end

    return into
end

Salsa.@derived function derived_lintconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    validate_key_set!(res, toml_content, _LINT_CONFIG_TOP_LEVEL_KEYS, _LINT_CONFIG_MIGRATIONS, "lint configuration key")
    validate_config_version!(res, toml_content)
    shadowing_diagnostic!(res, derived_lintconfig_files(rt), uri, "JuliaLint.toml")

    if haskey(toml_content, "preset")
        p = toml_content["preset"]
        if !(p isa AbstractString) || !haskey(LINT_PRESETS, p)
            push!(res, config_diagnostic(
                "Invalid `preset`, expected one of $(join(VALID_LINT_PRESETS, ", "))."))
        end
    end

    parse_glob_list!(res, toml_content, "include")
    parse_glob_list!(res, toml_content, "exclude")

    haskey(toml_content, "rules") &&
        _validate_lint_rules!(res, toml_content["rules"], Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}())

    parse_overrides!(res, toml_content, (r, block) -> begin
        validate_key_set!(r, block, ["paths", "rules"], _LINT_CONFIG_MIGRATIONS, "`[[override]]` key")
        haskey(block, "rules") &&
            _validate_lint_rules!(r, block["rules"], Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}())
    end)

    return res
end

"""
    struct ParsedLintConfig

One `JuliaLint.toml` file, parsed. Kept separate from the per-file
[`EffectiveLintConfig`](@ref) so that parsing happens once per config file
rather than once per linted file.
"""
struct ParsedLintConfig
    preset::String
    filter::PathFilter
    rules::Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}
    overrides::Vector{Any}
end

ParsedLintConfig() = ParsedLintConfig(
    DEFAULT_LINT_PRESET, PathFilter(),
    Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}(), Any[],
)

Salsa.@derived function derived_parsed_lint_config(rt, config_uri)
    @debug "derived_parsed_lint_config" config_uri=config_uri

    toml_content = derived_toml_syntax_tree(rt, config_uri)
    discard = Diagnostic[]   # diagnostics are reported by derived_lintconfig_diagnostics

    preset = get(toml_content, "preset", DEFAULT_LINT_PRESET)
    (preset isa AbstractString && haskey(LINT_PRESETS, preset)) || (preset = DEFAULT_LINT_PRESET)

    rules = Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}()
    haskey(toml_content, "rules") && _validate_lint_rules!(discard, toml_content["rules"], rules)

    overrides = parse_overrides!(discard, toml_content, (_, _) -> nothing)

    return ParsedLintConfig(String(preset), parse_path_filter!(discard, toml_content), rules, overrides)
end

Salsa.@derived function derived_effective_lint_config(rt, uri)
    @debug "derived_effective_lint_config" uri=uri

    config_uri = nearest_config(derived_lintconfig_files(rt), uri)
    config_uri === nothing && return EffectiveLintConfig()

    parsed = derived_parsed_lint_config(rt, config_uri)
    relpath = config_relative_path(config_dir_of(config_uri), uri2filepath(uri))
    relpath === nothing && return EffectiveLintConfig()

    severities = copy(LINT_PRESETS[parsed.preset])
    options = Dict{Symbol,Dict{Symbol,Any}}()

    function apply_rules!(rules)
        for (id, (severity, opts)) in rules
            severity === nothing || (severities[id] = severity)
            isempty(opts) || (options[id] = merge(get(options, id, Dict{Symbol,Any}()), opts))
        end
    end

    apply_rules!(parsed.rules)

    for ov in applicable_overrides(parsed.overrides, relpath)
        haskey(ov, "rules") || continue
        ov_rules = Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}()
        _validate_lint_rules!(Diagnostic[], ov["rules"], ov_rules)
        apply_rules!(ov_rules)
    end

    return EffectiveLintConfig(severities, options, path_selected(parsed.filter, relpath))
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

    lint_config = derived_effective_lint_config(rt, uri)

    results = Diagnostic[]

    is_config_file = uri.scheme == "file" && (
        is_path_lintconfig_file(uri2filepath(uri)) ||
        is_path_formatconfig_file(uri2filepath(uri)) ||
        is_path_testitemsconfig_file(uri2filepath(uri))
    )

    # `include`/`exclude` suppress everything for a file — except a config
    # file's own validation, so that a config which happens to exclude its own
    # directory still reports its mistakes.
    if !lint_config.selected && !is_config_file
        return results
    end

    severity_of(rule) = rule_severity(lint_config, rule)
    enabled(rule) = severity_of(rule) !== :off

    # Julia-content diagnostics run for file-scheme .jl files AND non-file
    # (e.g. untitled) buffers whose language is julia.
    if _is_julia_uri(rt, uri)
        if enabled(:syntax_errors) || enabled(:syntax_warnings)
            syntax_diagnostics = derived_julia_syntax_diagnostics(rt, uri)

            if enabled(:syntax_errors)
                sev = severity_of(:syntax_errors)
                append!(results, Diagnostic(i.range, sev, i.message, i.uri, i.tags, i.source, :syntax_errors)
                        for i in syntax_diagnostics if i.severity == :error)
            end

            if enabled(:syntax_warnings)
                sev = severity_of(:syntax_warnings)
                append!(results, Diagnostic(i.range, sev, i.message, i.uri, i.tags, i.source, :syntax_warnings)
                        for i in syntax_diagnostics if i.severity == :warning)
            end
        end

        if enabled(:testitem_errors)
            sev = severity_of(:testitem_errors)
            tis = derived_testitems(rt, uri)
            append!(results, Diagnostic(i.range, sev, i.message, nothing, Symbol[], "Testitem", :testitem_errors) for i in tis.testerrors)
        end

        # Individual rule severities are applied where the diagnostics are
        # produced; this only skips the semantic pass entirely when every rule
        # it can emit is off. `include_errors` is excluded from the test — its
        # findings come from the separate structural pass below, so leaving it
        # on is no reason to run the (much more expensive) semantic one.
        if any(enabled(r.id) for r in LINT_RULES if !isempty(r.codes) && r.id !== :include_errors)
            sl = derived_new_static_lint_diagnostics(rt, uri)
            env_ready = derived_file_env_ready(rt, uri)
            if env_ready
                append!(results, sl)
            else
                append!(results, d for d in sl if !_is_env_dependent_diagnostic(d))
            end
        end

        # Include-graph diagnostics (DuplicateInclude / IncludeLoop /
        # MissingFile) are a purely structural analysis that does not depend on
        # a project/environment, so they are reported independently of the
        # semantic static-lint pass above.
        if enabled(:include_errors)
            sev = severity_of(:include_errors)
            append!(results, Diagnostic(d.range, sev, d.message, d.uri, d.tags, d.source, :include_errors)
                    for d in derived_include_diagnostics(rt, uri))
        end
    end

    # Config/TOML diagnostics are filesystem-file only.
    if uri.scheme == "file"
        if (is_config_file || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri))) && enabled(:toml_syntax_errors)
            sev = severity_of(:toml_syntax_errors)
            append!(results, Diagnostic(d.range, sev, d.message, d.uri, d.tags, d.source, :toml_syntax_errors)
                    for d in derived_toml_syntax_diagnostics(rt, uri))
        end

        if is_config_file
            config_diags = if is_path_lintconfig_file(uri2filepath(uri))
                derived_lintconfig_diagnostics(rt, uri)
            elseif is_path_formatconfig_file(uri2filepath(uri))
                derived_formatconfig_diagnostics(rt, uri)
            else
                derived_testitemsconfig_diagnostics(rt, uri)
            end

            # Validators emit more than one kind of finding (a schema mistake is
            # `config_errors`, a config that supersedes an outer one is
            # `shadowed_config`), so each keeps its own rule id and takes that
            # rule's configured severity rather than being flattened together.
            for d in config_diags
                rule = d.code === nothing ? :config_errors : d.code
                enabled(rule) || continue
                push!(results, Diagnostic(d.range, severity_of(rule), d.message, d.uri, d.tags, d.source, rule))
            end
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
