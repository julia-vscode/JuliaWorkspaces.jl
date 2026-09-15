# v2 twins of the lint-config machinery
#
# The v1 config queries in `layer_diagnostics.jl` and the finding materializer
# in `lint_syntax_rules/engine.jl` resolve rule ids against the v1 registry,
# which is frozen to what `main` ships. Under the v2 flag the same machinery
# must resolve against `LINT_RULES_V2` instead: v2-only rule ids would
# otherwise be rejected by config validation and KeyError at emission. So each
# registry-dependent function has a `_v2` twin here, and the v1 query
# dispatches on `input_v2_enabled` — the same seam `derived_diagnostics` uses
# for the pipeline itself. Everything registry-free (path filters, override
# parsing, the `EffectiveLintConfig` struct, `rule_option`) stays shared.

# Twin of `_is_env_dependent_finding` (`layer_diagnostics.jl`).
function _is_env_dependent_finding_v2(f::LintFinding)
    f.source != "StaticLint.jl" && return false
    return LINT_RULES_V2_BY_ID[f.rule_id].env_dependent
end

# Twin of `_validate_lint_rules!` (`layer_diagnostics.jl`) against the v2
# registry. Also owns the option validation for the v2-only rules
# (`missing_compat`, `unused_dependency`), so the v1 validator stays exactly
# what `main` ships.
function _validate_lint_rules_v2!(res::Vector{Diagnostic}, table, into::Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}})
    table isa Dict || (push!(res, config_diagnostic("Invalid `[rules]`, expected a table.")); return into)

    for (k, v) in pairs(table)
        rule = get(LINT_RULES_V2_BY_ID, Symbol(k), nothing)
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

        if rule.id === :missing_compat
            for bool_key in (:check_julia, :check_extras, :check_weakdeps)
                if haskey(options, bool_key) && !(options[bool_key] isa Bool)
                    push!(res, config_diagnostic(
                        "Invalid `$bool_key` for rule `$k`, expected a boolean."))
                    delete!(options, bool_key)
                end
            end
        end
        if rule.id in (:missing_compat, :unused_dependency) && haskey(options, :ignore)
            ig = options[:ignore]
            if !(ig isa Vector) || !all(x -> x isa AbstractString, ig)
                push!(res, config_diagnostic(
                    "Invalid `ignore` for rule `$k`, expected an array of dependency names."))
                delete!(options, :ignore)
            end
        end

        into[rule.id] = (severity, options)
    end

    return into
end

Salsa.@derived function derived_lintconfig_diagnostics_v2(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    validate_key_set!(res, toml_content, _LINT_CONFIG_TOP_LEVEL_KEYS, _LINT_CONFIG_MIGRATIONS, "lint configuration key")
    validate_config_version!(res, toml_content)
    shadowing_diagnostic!(res, derived_lintconfig_files(rt), uri, "JuliaLint.toml")

    if haskey(toml_content, "preset")
        p = toml_content["preset"]
        if !(p isa AbstractString) || !haskey(LINT_PRESETS_V2, p)
            push!(res, config_diagnostic(
                "Invalid `preset`, expected one of $(join(VALID_LINT_PRESETS, ", "))."))
        end
    end

    parse_glob_list!(res, toml_content, "include")
    parse_glob_list!(res, toml_content, "exclude")

    haskey(toml_content, "rules") &&
        _validate_lint_rules_v2!(res, toml_content["rules"], Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}())

    parse_overrides!(res, toml_content, (r, block) -> begin
        validate_key_set!(r, block, ["paths", "rules"], _LINT_CONFIG_MIGRATIONS, "`[[override]]` key")
        haskey(block, "rules") &&
            _validate_lint_rules_v2!(r, block["rules"], Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}())
    end)

    return res
end

Salsa.@derived function derived_parsed_lint_config_v2(rt, config_uri)
    @debug "derived_parsed_lint_config_v2" config_uri=config_uri

    toml_content = derived_toml_syntax_tree(rt, config_uri)
    discard = Diagnostic[]   # diagnostics are reported by derived_lintconfig_diagnostics

    preset = get(toml_content, "preset", DEFAULT_LINT_PRESET)
    (preset isa AbstractString && haskey(LINT_PRESETS_V2, preset)) || (preset = DEFAULT_LINT_PRESET)

    rules = Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}()
    haskey(toml_content, "rules") && _validate_lint_rules_v2!(discard, toml_content["rules"], rules)

    overrides = parse_overrides!(discard, toml_content, (_, _) -> nothing)

    return ParsedLintConfig(String(preset), rules, overrides)
end

# Like `EffectiveLintConfig(selected)`, but seeded from the v2 default preset
# so v2-only rules are classified.
_default_effective_lint_config_v2(selected::Bool) =
    EffectiveLintConfig(copy(_PRESET_DEFAULT_V2), Dict{Symbol,Dict{Symbol,Any}}(), selected)

Salsa.@derived function derived_effective_lint_config_v2(rt, uri)
    @debug "derived_effective_lint_config_v2" uri=uri

    # Scope composes over every enclosing `JuliaLint.toml`, so it is resolved
    # before the nearest-file lookup that decides the preset and rules.
    config_files = derived_lintconfig_files(rt)
    selected = uri.scheme == "file" ? scope_selected(
        ancestor_configs(config_files, uri), uri2filepath(uri),
        c -> derived_lint_path_filter(rt, c),
    ) : true

    config_uri = nearest_config(config_files, uri)
    config_uri === nothing && return _default_effective_lint_config_v2(selected)

    parsed = derived_parsed_lint_config_v2(rt, config_uri)
    relpath = config_relative_path(config_dir_of(config_uri), uri2filepath(uri))
    relpath === nothing && return _default_effective_lint_config_v2(selected)

    severities = copy(LINT_PRESETS_V2[parsed.preset])
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
        _validate_lint_rules_v2!(Diagnostic[], ov["rules"], ov_rules)
        apply_rules!(ov_rules)
    end

    return EffectiveLintConfig(severities, options, selected)
end

# Twin of `materialize` (`lint_syntax_rules/engine.jl`): severity fallback and
# tags/doc-link lookup against the v2 registry.
function materialize_v2(f::LintFinding, config::EffectiveLintConfig)
    severity = rule_severity_v2(config, f.rule_id)
    severity === :off && return nothing
    rule = LINT_RULES_V2_BY_ID[f.rule_id]
    uri = f.uri === nothing ? rule.doc_link : f.uri
    return Diagnostic(f.range, severity, f.message, uri, rule.tags, f.source, f.rule_id)
end
