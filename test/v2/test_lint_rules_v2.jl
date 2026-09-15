# The v2 lint-rule registry (`src/v2/bridge/lint_rules_v2.jl`): fully independent of
# the v1 registry, which is frozen to what `main` ships. These testitems pin
# the v2 presets the way `test_config.jl` pins the v1 ones, and document the
# current relationship between the two registries.

@testitem "v2 lint rules: every preset classifies every rule" begin
    # A rule no preset mentions would be reported at whatever severity the
    # lookup fell back to, in every project naming a preset, from the moment the
    # tool is upgraded. `v2/bridge/lint_rules_v2.jl` enforces this at load; this test states
    # the invariant so a refactor there cannot quietly drop it.
    for (name, preset) in JuliaWorkspaces.LINT_PRESETS_V2
        for rule in JuliaWorkspaces.LINT_RULES_V2
            @test haskey(preset, rule.id)
        end
        # ...and no preset invents a rule that does not exist.
        for id in keys(preset)
            @test haskey(JuliaWorkspaces.LINT_RULES_V2_BY_ID, id)
        end
    end
end

@testitem "v2 lint rules: preset severities pinned" begin
    # The presets used to be three hand-written dicts; they are now derived from
    # per-rule severity fields. This pins every value, so any change to a preset
    # severity is a conscious test update rather than a side effect. Values are
    # the original hand-written ones except for the three rules deliberately
    # demoted to `:off` in `default` on measured false-positive rates — see the
    # comment above `LINT_RULES` in `lint_rules.jl`.
    expected_default = Dict{Symbol,Symbol}(
        :incorrect_call_args => :off,   # demoted: 93% sampled FP
        :incorrect_iter_spec => :information,
        :index_from_length => :information,
        :nothing_comparison => :information,
        :const_if_condition => :information,
        :pointless_boolean => :information,
        :invalid_type_declaration => :information,
        :unused_type_parameter => :hint,
        :module_name => :information,
        :type_piracy => :information,
        :unused_function_argument => :hint,
        :duplicate_function_argument => :information,
        :kw_default_mismatch => :information,
        :literal_use => :information,
        :break_continue => :information,
        :global_const_decl => :information,
        :unused_binding => :hint,
        :const_decl => :information,
        :relative_import => :off,   # runtime nesting of included helpers is unknowable; dots saturate at Main
        :include_errors => :warning,
        :missing_reference => :off,     # demoted: 78% sampled FP
        :unresolved_import => :off,     # demoted: 77% sampled FP
        :syntax_errors => :error,
        :syntax_warnings => :off,
        :testitem_errors => :error,
        :toml_syntax_errors => :error,
        :config_errors => :error,
        :shadowed_config => :information,
        :environment_errors => :information,
        # Project/manifest file validation (Pkg feature support): structure Pkg
        # rejects is an error; tolerated inconsistencies warn; manifest shapes
        # we cannot interpret stay informational (machine-written files).
        :project_file_errors => :error,
        :project_file_warnings => :warning,
        :manifest_errors => :information,
        # Syntactic rules added with the rule registry; off outside `strict`,
        # except `detached_docstring` (see its LintRule entry).
        :nan_comparison => :off,
        :duplicate_branch_condition => :off,
        :string_concat_style => :off,
        :bare_using => :off,
        :debug_statement => :off,
        :async_task => :off,
        :detached_docstring => :warning,
        # Lowering-backed rule (Harvest JuliaLowering): shapes Julia will not
        # load — same class and treatment as syntax_errors.
        :lowering_errors => :error,
        # Small rule batch: Julia's soft-scope ambiguity warning, statically.
        :soft_scope_ambiguity => :information,
        # The analysis-boundary notice is OPT-IN (maintainer direction): the
        # default preset never reports on code merely because it cannot be
        # analyzed; strict promotes it to warning.
        :analysis_boundary => :off,
        # Package-quality rules ported from Aqua.jl; off outside `strict`.
        :missing_compat => :off,
        :unused_dependency => :off,
        :unbound_type_parameter => :off,
        :undocumented_public_name => :off,
    )
    @test JuliaWorkspaces.LINT_PRESETS_V2["default"] == expected_default

    # minimal: everything off except the checks that catch outright breakage.
    expected_minimal = Dict{Symbol,Symbol}(
        r.id => get(
            Dict{Symbol,Symbol}(
                :syntax_errors => :error,
                :lowering_errors => :error,
                :testitem_errors => :error,
                :toml_syntax_errors => :error,
                :project_file_errors => :error,
                :config_errors => :error,
                :include_errors => :warning,
                :const_decl => :warning,
                :shadowed_config => :information,
            ),
            r.id,
            :off,
        )
        for r in JuliaWorkspaces.LINT_RULES_V2
    )
    @test JuliaWorkspaces.LINT_PRESETS_V2["minimal"] == expected_minimal

    # strict: everything on, hints/infos/offs promoted to warnings.
    expected_strict = Dict{Symbol,Symbol}(
        r.id => begin
            d = expected_default[r.id]
            r.id === :syntax_warnings ? :warning :
            d in (:off, :hint, :information) ? :warning : d
        end
        for r in JuliaWorkspaces.LINT_RULES_V2
    )
    @test JuliaWorkspaces.LINT_PRESETS_V2["strict"] == expected_strict

    # The env-dependent set, formerly a side table, now derived from rule fields.
    @test JuliaWorkspaces.ENV_DEPENDENT_LINT_RULES_V2 == Set([
        :incorrect_call_args, :incorrect_iter_spec, :nothing_comparison,
        :invalid_type_declaration, :type_piracy, :kw_default_mismatch,
        :missing_reference, :unresolved_import,
    ])

    # Tags and doc links, formerly side tables.
    @test JuliaWorkspaces.rule_tags_v2(:unused_binding) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags_v2(:unused_function_argument) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags_v2(:unused_type_parameter) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags_v2(:nothing_comparison) == Symbol[]
    @test JuliaWorkspaces.rule_code_description_v2(:index_from_length) !== nothing
    @test JuliaWorkspaces.rule_code_description_v2(:nothing_comparison) === nothing
end

@testitem "v2 lint rules: registry relationship with v1" begin
    # The registries are separate so v2 can diverge; TODAY they agree on every
    # shared rule, and v2 adds exactly the v2-only producers. The first
    # deliberate divergence is a conscious update of this test, not a bug.
    v1 = JuliaWorkspaces.LINT_RULES_BY_ID
    v2 = JuliaWorkspaces.LINT_RULES_V2_BY_ID
    for (id, rule) in v1
        @test haskey(v2, id)
        haskey(v2, id) || continue
        for f in fieldnames(JuliaWorkspaces.LintRule)
            @test getfield(v2[id], f) == getfield(rule, f)
        end
    end
    @test Set(setdiff(keys(v2), keys(v1))) == Set([
        :lowering_errors, :soft_scope_ambiguity, :project_file_errors,
        :project_file_warnings, :manifest_errors, :analysis_boundary,
        :missing_compat, :unused_dependency, :unbound_type_parameter,
        :undocumented_public_name,
    ])
end
