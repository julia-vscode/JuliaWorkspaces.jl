# StaticLint findings that depend on environment data (package symbols) being
# fully loaded. These are suppressed until the environment is ready to avoid
# false positives from unresolved imports. Matching is on the rule id, so
# rephrasing a message (e.g. the detailed `describe_call_mismatch` text that
# replaces the generic `IncorrectCallArgs` one) cannot silently opt a finding
# out of the suppression.
function _is_env_dependent_finding(f::LintFinding)
    f.source != "StaticLint.jl" && return false
    return LINT_RULES_BY_ID[f.rule_id].env_dependent
end

# Sorted: this vector is now a dependency of every file's scope, and
# `derived_text_files` is a `Set`, so an unsorted result would change on
# unrelated file adds and defeat Salsa's backdating.
Salsa.@derived function derived_lintconfig_files(rt)
    files = derived_text_files(rt)

    return sort!([file for file in files if file.scheme=="file" && is_path_lintconfig_file(uri2filepath(file))], by=string)
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

Carries only the keys the *nearest* config decides. The `include`/`exclude`
globs are deliberately not here: they compose over the whole ancestor chain and
live in [`derived_lint_path_filter`](@ref), so that editing `[rules]` does not
invalidate every file's scope, nor an `exclude` edit every file's rules.
"""
struct ParsedLintConfig
    preset::String
    rules::Dict{Symbol,Tuple{Union{Nothing,Symbol},Dict{Symbol,Any}}}
    overrides::Vector{Any}
end

ParsedLintConfig() = ParsedLintConfig(
    DEFAULT_LINT_PRESET,
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

    return ParsedLintConfig(String(preset), rules, overrides)
end

"""
    derived_lint_path_filter(rt, config_uri) -> PathFilter

The `include`/`exclude` globs of one `JuliaLint.toml`. Separate from
[`derived_parsed_lint_config`](@ref) so scope and settings invalidate
independently.
"""
Salsa.@derived function derived_lint_path_filter(rt, config_uri)
    discard = Diagnostic[]   # diagnostics are reported by derived_lintconfig_diagnostics

    return parse_path_filter!(discard, derived_toml_syntax_tree(rt, config_uri))
end

Salsa.@derived function derived_effective_lint_config(rt, uri)
    @debug "derived_effective_lint_config" uri=uri

    # Scope composes over every enclosing `JuliaLint.toml`, so it is resolved
    # before the nearest-file lookup that decides the preset and rules.
    config_files = derived_lintconfig_files(rt)
    selected = uri.scheme == "file" ? scope_selected(
        ancestor_configs(config_files, uri), uri2filepath(uri),
        c -> derived_lint_path_filter(rt, c),
    ) : true

    config_uri = nearest_config(config_files, uri)
    config_uri === nothing && return EffectiveLintConfig(selected)

    parsed = derived_parsed_lint_config(rt, config_uri)
    relpath = config_relative_path(config_dir_of(config_uri), uri2filepath(uri))
    relpath === nothing && return EffectiveLintConfig(selected)

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

    return EffectiveLintConfig(severities, options, selected)
end

# The user-facing messages of every failed dynamic work item whose project
# folder contains the project file at `uri`. A test-env failure and an env
# failure for the same folder both land on that folder's Project.toml.
# Sorted for a deterministic diagnostic order; identical messages from
# different keys (e.g. stale content hashes of the same folder) collapse to one.
Salsa.@derived function derived_environment_error_messages(rt, uri)
    folder_uri = filepath2uri(dirname(uri2filepath(uri)))
    messages = String[]
    for (key, message) in input_dynamic_failure_messages(rt)
        key_path = _key_folder_path(key)
        if filepath2uri(key_path) == folder_uri
            push!(messages, message)
        end
    end
    return unique!(sort!(messages))
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

    # A config file validates itself even when its own globs exclude the
    # directory it lives in — otherwise a mistake in `exclude` could hide the
    # very diagnostic that explains it. The exemption covers *self*-exclusion
    # only: a config inside a subtree an enclosing `JuliaLint.toml` excluded is
    # part of code the project deliberately set aside (a vendored repository,
    # typically) and stays silent along with the rest of it.
    is_config_file = uri.scheme == "file" && (
        is_path_lintconfig_file(uri2filepath(uri)) ||
        is_path_formatconfig_file(uri2filepath(uri)) ||
        is_path_testitemsconfig_file(uri2filepath(uri))
    )

    is_self_validating_config = is_config_file &&
        scope_selected(
            strict_ancestor_configs(derived_lintconfig_files(rt), uri), uri2filepath(uri),
            c -> derived_lint_path_filter(rt, c),
        )

    if !lint_config.selected && !is_self_validating_config
        return results
    end

    enabled(rule) = rule_enabled(lint_config, rule)

    # The single point where severity, tags and doc links are applied — every
    # producer path below funnels its findings through `materialize`.
    emit_finding!(f::LintFinding) = begin
        d = materialize(f, lint_config)
        d === nothing || push!(results, d)
        nothing
    end
    emit!(range, rule_id, message, related_uri, source) =
        emit_finding!(LintFinding(range, rule_id, message, related_uri, source))

    # Julia-content diagnostics run for file-scheme .jl files AND non-file
    # (e.g. untitled) buffers whose language is julia.
    if _is_julia_uri(rt, uri)
        # The `enabled` guards below do not filter (materialize does); they skip
        # running a producer query at all when nothing it can emit is on.
        if enabled(:syntax_errors) || enabled(:syntax_warnings)
            for i in derived_julia_syntax_diagnostics(rt, uri)
                rule = i.severity == :error ? :syntax_errors : :syntax_warnings
                emit!(i.range, rule, i.message, i.uri, i.source)
            end
        end

        if enabled(:testitem_errors)
            for i in derived_testitems(rt, uri).testerrors
                emit!(i.range, :testitem_errors, i.message, nothing, "Testitem")
            end
        end

        # This only skips the semantic pass entirely when every rule it can
        # emit is off. `include_errors` is excluded from the test — its
        # findings come from the separate structural pass below, so leaving it
        # on is no reason to run the (much more expensive) semantic one.
        if any(enabled(r.id) for r in LINT_RULES if !isempty(r.codes) && r.id !== :include_errors)
            env_ready = derived_file_env_ready(rt, uri)
            for f in derived_new_static_lint_diagnostics(rt, uri)
                if !env_ready && _is_env_dependent_finding(f)
                    continue
                end
                emit_finding!(f)
            end
        end

        # Purely syntactic rules (tier `TierSyntax`, see lint_syntax_rules/)
        # run on the JuliaSyntax tree alone.
        foreach(emit_finding!, derived_syntax_lint_findings(rt, uri))

        # Include-graph diagnostics (DuplicateInclude / IncludeLoop /
        # MissingFile) are a purely structural analysis that does not depend on
        # a project/environment, so they are reported independently of the
        # semantic static-lint pass above.
        if enabled(:include_errors)
            for d in derived_include_diagnostics(rt, uri)
                emit!(d.range, :include_errors, d.message, d.uri, d.source)
            end
        end
    end

    # Config/TOML diagnostics are filesystem-file only.
    if uri.scheme == "file"
        if (is_config_file || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri))) && enabled(:toml_syntax_errors)
            for d in derived_toml_syntax_diagnostics(rt, uri)
                emit!(d.range, :toml_syntax_errors, d.message, d.uri, d.source)
            end
        end

        # Environment-resolution failures are reported on the project file of
        # the environment they were about — the closest file the user can act
        # on. Whole-file range, like `config_diagnostic`.
        if is_path_project_file(uri2filepath(uri)) && enabled(:environment_errors)
            for message in derived_environment_error_messages(rt, uri)
                emit!(1:1, :environment_errors, message, nothing, "JuliaWorkspaces.jl")
            end
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
                emit!(d.range, d.code === nothing ? :config_errors : d.code, d.message, d.uri, d.source)
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
