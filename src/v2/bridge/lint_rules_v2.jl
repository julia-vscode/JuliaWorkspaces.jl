# The v2 lint rule registry
#
# The v2 stack's own, fully independent list of user-facing lint rules. The v1
# registry (`LINT_RULES` in `lint_rules.jl`) is frozen to what `main` ships;
# this list carries every rule the v2 pipeline emits: the rules shared with v1
# (today: identical entries, see the guard test in `test/v2/test_lint_rules_v2.jl`) plus the
# v2-only producers. Which registry is in force is decided per runtime by
# `input_v2_enabled`: the config queries in `layer_diagnostics.jl` dispatch to
# the `_v2` twins in `bridge/lint_config_v2.jl`, which read the artifacts
# below.
#
# Rules are plain `LintRule` values for now; a dedicated registration API for
# new v2 rules is planned on top of this seam.
#
# Deliberately NOT twinned, although both stacks run them: `LINTCODE_TO_RULE`
# (`lint_emission.jl`), `lint_options_from_config` and
# `missingrefs_from_config` (`lint_rules.jl`) only ever touch StaticLint-coded
# rules, which are identical in both registries by construction. They become
# twin candidates the day v2 diverges on a coded rule.
#
# Severity provenance and preset conventions: see the comment above
# `LINT_RULES` in `lint_rules.jl`.
const LINT_RULES_V2 = LintRule[
    # ── StaticLint rules gated by a `LintOptions` field ──────────────────────
    # Off in `default`: 93% of sampled findings were false positives (2026-08-12
    # sweep), because the checker's method table is incomplete for most callees.
    LintRule(id = :incorrect_call_args, tier = TierSemantic,
        severity_default = :off, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.IncorrectCallArgs, StaticLint.FunctionHasNoMethods], category = :call),
    LintRule(id = :incorrect_iter_spec, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.IncorrectIterSpec], category = :iter),
    LintRule(id = :index_from_length, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        doc_link = URI("https://docs.julialang.org/en/v1/base/arrays/#Base.eachindex"),
        codes = [StaticLint.IndexFromLength], category = :iter),
    LintRule(id = :nothing_comparison, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.NothingEquality, StaticLint.NothingNotEq], category = :nothingcomp),
    LintRule(id = :const_if_condition, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.ConstIfCondition, StaticLint.EqInIfConditional], category = :constif),
    LintRule(id = :pointless_boolean, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.PointlessOR, StaticLint.PointlessAND], category = :lazy),
    LintRule(id = :invalid_type_declaration, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.InvalidTypeDeclaration], category = :datadecl),
    LintRule(id = :unused_type_parameter, tier = TierSemantic,
        severity_default = :hint, severity_strict = :warning,
        tags = [:unnecessary],
        codes = [StaticLint.UnusedTypeParameter], category = :typeparam),
    LintRule(id = :module_name, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.InvalidModuleName], category = :modname),
    LintRule(id = :type_piracy, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.TypePiracy, StaticLint.NotEqDef], category = :pirates),
    LintRule(id = :unused_function_argument, tier = TierSemantic,
        severity_default = :hint, severity_strict = :warning,
        tags = [:unnecessary],
        codes = [StaticLint.UnusedFunctionArgument], category = :useoffuncargs),
    LintRule(id = :duplicate_function_argument, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.DuplicateFuncArgName], category = :useoffuncargs),
    LintRule(id = :kw_default_mismatch, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.KwDefaultMismatch, StaticLint.UnassignedKeywordArgument], category = :kwdefault),
    LintRule(id = :literal_use, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.InappropriateUseOfLiteral], category = :literal),
    LintRule(id = :break_continue, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.ShouldBeInALoop], category = :breakcontinue),
    LintRule(id = :global_const_decl, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
        codes = [StaticLint.TypeDeclOnGlobalVariable, StaticLint.UnsupportedConstLocalVariable], category = :constdecl),

    # ── StaticLint rules whose checks always run (filtered at emission) ──────
    LintRule(id = :unused_binding, tier = TierSemantic,
        severity_default = :hint, severity_strict = :warning,
        tags = [:unnecessary],
        codes = [StaticLint.UnusedBinding]),
    LintRule(id = :const_decl, tier = TierSemantic,
        severity_minimal = :warning, severity_default = :information, severity_strict = :warning,
        codes = [
            StaticLint.CannotDeclareConst,
            StaticLint.InvalidRedefofConst,
            StaticLint.CannotDefineFuncAlreadyHasValue,
        ]),
    LintRule(id = :relative_import, tier = TierSemantic,
        severity_default = :off, severity_strict = :warning,
        codes = [StaticLint.RelativeImportTooManyDots]),
    LintRule(id = :include_errors, tier = TierWorkspace,
        severity_minimal = :warning, severity_default = :warning, severity_strict = :warning,
        codes = [
            StaticLint.IncludeLoop,
            StaticLint.DuplicateInclude,
            StaticLint.MissingFile,
            StaticLint.IncludePathContainsNULL,
            StaticLint.FileTooBig,
            StaticLint.FileNotAvailable,
            StaticLint.ComputedInclude,
        ]),
    # Off in `default`: 78% of sampled findings were false positives, chiefly
    # names minted by `@eval` loops that no static pass can see.
    LintRule(id = :missing_reference, tier = TierSemantic,
        severity_default = :off, severity_strict = :warning,
        env_dependent = true, option_keys = [:scope],
        codes = [StaticLint.MissingRef]),
    # Off in `default`: 77% of sampled findings were false positives, chiefly
    # `using X` in `ext/` where X is a `[weakdeps]` trigger.
    LintRule(id = :unresolved_import, tier = TierSemantic,
        severity_default = :off, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.UnresolvedImport]),

    # ── Purely syntactic rules (see lint_syntax_rules.jl) ────────────────────
    # New rules ship `:off` outside `strict` so an upgrade never switches them
    # on for existing projects; promotion to default-on is a deliberate,
    # sweep-validated release decision. The one exception is
    # `detached_docstring`, and even it caps at `:warning`: no new rule may
    # enter `default` at `:error`, so an upgrade never flips `julialint`'s
    # exit code.
    LintRule(id = :nan_comparison, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning,
        doc_link = URI("https://docs.julialang.org/en/v1/base/numbers/#Base.isnan")),
    LintRule(id = :duplicate_branch_condition, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :string_concat_style, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :bare_using, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :debug_statement, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :async_task, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    # The text is discarded outright rather than a style opinion, so it does not
    # follow the `:off`-by-default convention for a new rule. `:warning`, not
    # `:error`: the detector is a heuristic, and only the definitional
    # breakage rules below may fail CI out of the box.
    LintRule(id = :detached_docstring, tier = TierSyntax,
        severity_default = :warning, severity_strict = :warning),

    # ── Rules backed by analyses other than StaticLint ───────────────────────
    # Shapes JuliaLowering rejects (v2 lowering producer, behind the lowering
    # flag): invalid assignment targets, malformed signatures, duplicate struct
    # fields, … — code that will NOT load (verified equivalent on stable
    # Julia's flisp lowering, not just the vendored master copy). Same class of
    # breakage as `syntax_errors`, so the same treatment: `:error` in every
    # preset. Under the flag this rule supersedes StaticLint's syntactic
    # approximations `duplicate_function_argument`/`break_continue`/
    # `global_const_decl`, which are suppressed rather than re-emitted.
    LintRule(id = :lowering_errors, tier = TierSemantic,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    # Julia's soft-scope ambiguity warning, statically (v2 lowering producer,
    # behind the lowering flag — no StaticLint counterpart): an un-annotated
    # assignment in a top-level for/while/try to a name that is also a plain
    # module global. Julia itself warns at run time in files; this predicts it.
    LintRule(id = :soft_scope_ambiguity, tier = TierSemantic,
        severity_minimal = :off, severity_default = :information, severity_strict = :warning),
    LintRule(id = :syntax_errors, tier = TierSyntax,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    LintRule(id = :syntax_warnings, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :testitem_errors, tier = TierSyntax,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    LintRule(id = :toml_syntax_errors, tier = TierProject,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    # Structure in a Project.toml that Pkg itself rejects (a malformed uuid, an
    # extension trigger that is not a declared weakdep, a `[sources]` entry
    # with neither url nor path): same class of breakage as syntax errors.
    LintRule(id = :project_file_errors, tier = TierProject,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    # Inconsistencies Pkg tolerates until the section is actually used (a
    # target dep missing from `[extras]`, a stale manifest, a dangling
    # `[sources]`/`[workspace]` path).
    LintRule(id = :project_file_warnings, tier = TierProject,
        severity_default = :warning, severity_strict = :warning),
    # Manifests are machine-written, so a shape we cannot interpret is as
    # likely our blind spot as the project's fault — informational by default.
    LintRule(id = :manifest_errors, tier = TierProject,
        severity_default = :information, severity_strict = :warning),
    LintRule(id = :config_errors, tier = TierProject,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    # A structural problem with the project's own configuration, not a style
    # opinion — it stays on even in the quietest preset.
    LintRule(id = :shadowed_config, tier = TierWorkspace,
        severity_minimal = :information, severity_default = :information, severity_strict = :warning),
    # Not the project's fault necessarily (a CI box without registry access
    # fails every resolve), so informational rather than CI-breaking.
    LintRule(id = :environment_errors, tier = TierProject,
        severity_default = :information, severity_strict = :warning),
    # An analysis boundary: a construct the linter cannot see through (a
    # computed or function-body `include`, an interpolated `@eval`/`eval`, a
    # guarded import, a macro whose expansion failed) silences a set of
    # semantic rules in its module. The default preset is SILENT about it by
    # design (maintainer direction): the linter never reports on things it
    # merely cannot analyze — it just drops the affected rules in the
    # smallest scope. Users opt in (`analysis_boundary = "warning"`, or the
    # strict preset) to be told what blocks analysis, and get the full
    # diagnostic set back by avoiding those constructs.
    LintRule(id = :analysis_boundary, tier = TierWorkspace,
        severity_minimal = :off, severity_default = :off, severity_strict = :warning),

    # ── Package-quality rules (ported from Aqua.jl) ──────────────────────────
    # All four are v2-only producers (their queries are reached only through
    # `derived_diagnostics_v2`, like `project_file_errors`), and like the
    # syntactic rules they ship `:off` outside `strict` so an upgrade never
    # switches them on for existing projects.
    # Aqua's `test_deps_compat`: a package should have a `[compat]` entry for
    # `julia` and for every `[deps]`/`[extras]`/`[weakdeps]` entry, stdlibs
    # included. Options gate the julia/extras/weakdeps checks and exempt
    # named dependencies.
    LintRule(id = :missing_compat, tier = TierProject,
        severity_default = :off, severity_strict = :warning,
        option_keys = [:check_julia, :check_extras, :check_weakdeps, :ignore]),
    # The static face of Aqua's `test_stale_deps`: a `[deps]` entry no
    # `using`/`import` in the package's source (src/ or extensions) references.
    # Aqua accepts transitively-loaded deps at run time; a static check cannot,
    # so such deps go on the `ignore` option.
    LintRule(id = :unused_dependency, tier = TierWorkspace,
        severity_default = :off, severity_strict = :warning,
        option_keys = [:ignore]),
    # Aqua's `test_unbound_args`, statically: a method `where` parameter no
    # argument type binds, so it is undefined when the method runs (e.g.
    # `f(::T...) where T` called with zero arguments).
    LintRule(id = :unbound_type_parameter, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    # Aqua's `test_undocumented_names`, statically: an exported/`public` name a
    # workspace package declares without a docstring, or a submodule without a
    # module docstring (the root module falls back to the README). Re-exported
    # names are skipped — their docstrings live upstream.
    LintRule(id = :undocumented_public_name, tier = TierWorkspace,
        severity_default = :off, severity_strict = :warning),
]

const LINT_RULES_V2_BY_ID = Dict{Symbol,LintRule}(r.id => r for r in LINT_RULES_V2)

const LINTCODE_TO_RULE_V2 = Dict{StaticLint.LintCodes,Symbol}(
    c => r.id for r in LINT_RULES_V2 for c in r.codes
)

# Same load-time invariant as the v1 registry: every StaticLint code must
# belong to a rule, or emission would throw at lint time.
for _code in instances(StaticLint.LintCodes)
    haskey(LINTCODE_TO_RULE_V2, _code) || error(
        "StaticLint code `$(_code)` is not covered by any rule in `LINT_RULES_V2`. " *
        "Add it to an existing rule or introduce a new one."
    )
end

const ENV_DEPENDENT_LINT_RULES_V2 = Set{Symbol}(r.id for r in LINT_RULES_V2 if r.env_dependent)

const _PRESET_MINIMAL_V2 = Dict{Symbol,Symbol}(r.id => r.severity_minimal for r in LINT_RULES_V2)
const _PRESET_DEFAULT_V2 = Dict{Symbol,Symbol}(r.id => r.severity_default for r in LINT_RULES_V2)
const _PRESET_STRICT_V2 = Dict{Symbol,Symbol}(r.id => r.severity_strict for r in LINT_RULES_V2)

const LINT_PRESETS_V2 = Dict{String,Dict{Symbol,Symbol}}(
    "minimal" => _PRESET_MINIMAL_V2,
    "default" => _PRESET_DEFAULT_V2,
    "strict" => _PRESET_STRICT_V2,
)

rule_tags_v2(rule_id::Symbol) = LINT_RULES_V2_BY_ID[rule_id].tags

rule_code_description_v2(rule_id::Symbol) = LINT_RULES_V2_BY_ID[rule_id].doc_link

# Twins of `rule_severity`/`rule_enabled`: same `EffectiveLintConfig`, but the
# preset fallback resolves against the v2 registry, so a v2-only rule id is
# never a KeyError. (`rule_option` is registry-free and shared.)
rule_severity_v2(config::EffectiveLintConfig, rule_id::Symbol) =
    get(config.severities, rule_id, _PRESET_DEFAULT_V2[rule_id])

rule_enabled_v2(config::EffectiveLintConfig, rule_id::Symbol) = rule_severity_v2(config, rule_id) !== :off
