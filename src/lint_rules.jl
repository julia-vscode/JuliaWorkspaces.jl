# Lint rule registry
#
# The single source of truth for the user-facing lint rule ids: the names that
# appear in `JuliaLint.toml`, on `Diagnostic.code`, and as the rule id in the
# CLI's JSON and SARIF output.
#
# A rule groups one or more `StaticLint.LintCodes` members that a user would
# want to configure together (`NothingEquality` and `NothingNotEq` are one rule,
# `nothing_comparison`). Rules whose findings do not come from StaticLint at all
# (syntax, test items, TOML, config validation) carry no codes.

"""
    @enum LintTier

The inputs a lint rule needs, from least to most:

- `TierSyntax`: the syntax tree of a single file, nothing else.
- `TierSemantic`: a single file plus semantic information (bindings, scopes,
  package symbols — today the StaticLint semantic pass).
- `TierProject`: project or environment information (Project.toml, Manifest,
  configuration files, environment resolution).
- `TierWorkspace`: cross-file workspace information (include graph, the full
  set of configuration files).

The tier determines which derived query produces a rule's findings and which
prerequisites gate it; it is not user-visible.
"""
@enum LintTier TierSyntax TierSemantic TierProject TierWorkspace

"""
    struct LintRule

A user-facing lint rule. Fully declarative: everything the pipeline needs to
know about a rule — where its findings come from, how each preset classifies
it, its tags and documentation link, whether it depends on the environment
being ready — is a field here rather than a side table.

- `id::Symbol`: The rule id, as written in `JuliaLint.toml` and reported on
  [`Diagnostic`](@ref)`.code`.
- `tier::LintTier`: The inputs the rule needs, see [`LintTier`](@ref).
- `severity_minimal`/`severity_default`/`severity_strict::Symbol`: The rule's
  severity in each preset (`:off`, `:hint`, `:information`, `:warning`,
  `:error`). Every rule classifies all three presets, so the "every preset
  classifies every rule" invariant holds by construction. Prefer `:off` in
  `minimal` and `default` for a new rule: a rule that switches itself on for
  every project on upgrade breaks their CI.
- `tags::Vector{Symbol}`: LSP diagnostic tags, e.g. `[:unnecessary]`. A
  property of the rule, not of the configured severity: an unused binding stays
  "unnecessary" (greyed out by the editor) whether the user reports it as a
  hint or an error.
- `doc_link::Union{Nothing,URI}`: Documentation link surfaced as the
  diagnostic's code description.
- `env_dependent::Bool`: Whether findings depend on package symbols being
  indexed; such rules are suppressed until a file's environment is ready (see
  `_is_env_dependent_finding`).
- `option_keys::Vector{Symbol}`: Extra keys accepted alongside `severity` when
  the rule is configured as a table.
- `codes::Vector{StaticLint.LintCodes}`: The StaticLint codes this rule covers;
  empty for rules backed by another analysis.
- `category::Union{Nothing,Symbol}`: The `StaticLint.LintOptions` field that
  gates the check emitting these codes, or `nothing` when the check always runs
  (those rules are filtered when diagnostics are emitted instead).
"""
Base.@kwdef struct LintRule
    id::Symbol
    tier::LintTier
    severity_minimal::Symbol = :off
    severity_default::Symbol
    severity_strict::Symbol
    tags::Vector{Symbol} = Symbol[]
    doc_link::Union{Nothing,URI} = nothing
    env_dependent::Bool = false
    option_keys::Vector{Symbol} = Symbol[]
    codes::Vector{StaticLint.LintCodes} = StaticLint.LintCodes[]
    category::Union{Nothing,Symbol} = nothing
end

# `severity_default` reproduces the severities that were hard-coded before
# rules became configurable, so an absent config file changes nothing.
# `severity_strict` follows the convention "everything on, and everything that
# is merely a hint promoted to a warning"; `severity_minimal` keeps only the
# checks that catch outright breakage.
const LINT_RULES = LintRule[
    # ── StaticLint rules gated by a `LintOptions` field ──────────────────────
    LintRule(id = :incorrect_call_args, tier = TierSemantic,
        severity_default = :information, severity_strict = :warning,
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
        severity_default = :information, severity_strict = :warning,
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
    LintRule(id = :missing_reference, tier = TierSemantic,
        severity_default = :warning, severity_strict = :warning,
        env_dependent = true, option_keys = [:scope],
        codes = [StaticLint.MissingRef]),
    LintRule(id = :unresolved_import, tier = TierSemantic,
        severity_default = :warning, severity_strict = :warning,
        env_dependent = true,
        codes = [StaticLint.UnresolvedImport]),

    # ── Purely syntactic rules (see lint_syntax_rules.jl) ────────────────────
    # New rules ship `:off` outside `strict` so an upgrade never switches them
    # on for existing projects; promotion to default-on is a deliberate,
    # sweep-validated release decision.
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

    # ── Rules backed by analyses other than StaticLint ───────────────────────
    LintRule(id = :syntax_errors, tier = TierSyntax,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    LintRule(id = :syntax_warnings, tier = TierSyntax,
        severity_default = :off, severity_strict = :warning),
    LintRule(id = :testitem_errors, tier = TierSyntax,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
    LintRule(id = :toml_syntax_errors, tier = TierProject,
        severity_minimal = :error, severity_default = :error, severity_strict = :error),
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
]

const LINT_RULES_BY_ID = Dict{Symbol,LintRule}(r.id => r for r in LINT_RULES)

const LINTCODE_TO_RULE = Dict{StaticLint.LintCodes,Symbol}(
    c => r.id for r in LINT_RULES for c in r.codes
)

# Every StaticLint code must belong to a rule: `_emit_hint_findings!` indexes
# `LINTCODE_TO_RULE` unconditionally, so an unmapped code would throw at lint
# time. Enforced here so adding a code without classifying it fails the build.
for _code in instances(StaticLint.LintCodes)
    haskey(LINTCODE_TO_RULE, _code) || error(
        "StaticLint code `$(_code)` is not covered by any rule in `LINT_RULES`. " *
        "Add it to an existing rule or introduce a new one."
    )
end

# Derived view kept for introspection/tests; the emission-time check
# (`_is_env_dependent_finding`) reads the rule field directly.
const ENV_DEPENDENT_LINT_RULES = Set{Symbol}(r.id for r in LINT_RULES if r.env_dependent)

# ── Severities ──────────────────────────────────────────────────────────────

# The config file spells the LSP-ish names; internally severities are the
# symbols the `Diagnostic` struct already uses (`:information`, not `:info`).
const SEVERITY_FROM_STRING = Dict{String,Symbol}(
    "off" => :off,
    "hint" => :hint,
    "info" => :information,
    "warning" => :warning,
    "error" => :error,
)

const VALID_SEVERITY_STRINGS = ["off", "hint", "info", "warning", "error"]

# ── Presets ─────────────────────────────────────────────────────────────────

# Derived from the per-rule severity fields, so every preset classifies every
# rule by construction.
const _PRESET_MINIMAL = Dict{Symbol,Symbol}(r.id => r.severity_minimal for r in LINT_RULES)
const _PRESET_DEFAULT = Dict{Symbol,Symbol}(r.id => r.severity_default for r in LINT_RULES)
const _PRESET_STRICT = Dict{Symbol,Symbol}(r.id => r.severity_strict for r in LINT_RULES)

const LINT_PRESETS = Dict{String,Dict{Symbol,Symbol}}(
    "minimal" => _PRESET_MINIMAL,
    "default" => _PRESET_DEFAULT,
    "strict" => _PRESET_STRICT,
)

const DEFAULT_LINT_PRESET = "default"

const VALID_LINT_PRESETS = ["minimal", "default", "strict"]

rule_tags(rule_id::Symbol) = LINT_RULES_BY_ID[rule_id].tags

rule_code_description(rule_id::Symbol) = LINT_RULES_BY_ID[rule_id].doc_link

# ── Effective configuration ─────────────────────────────────────────────────

"""
    struct EffectiveLintConfig

The lint configuration in force for one file, after resolving the preset
baseline, the config file's `[rules]` deltas and any applicable `[[override]]`
blocks.

- `severities::Dict{Symbol,Symbol}`: rule id → severity, `:off` when disabled.
- `options::Dict{Symbol,Dict{Symbol,Any}}`: rule id → that rule's extra options.
- `selected::Bool`: whether the file is linted at all (`include`/`exclude`).
"""
struct EffectiveLintConfig
    severities::Dict{Symbol,Symbol}
    options::Dict{Symbol,Dict{Symbol,Any}}
    selected::Bool
end

# Defaults, with scope supplied by the caller: config resolution decides whether
# a file is in scope from the whole ancestor chain, so it knows `selected` even
# on the paths where it has no config file to read settings from.
EffectiveLintConfig(selected::Bool) = EffectiveLintConfig(copy(_PRESET_DEFAULT), Dict{Symbol,Dict{Symbol,Any}}(), selected)
EffectiveLintConfig() = EffectiveLintConfig(true)

function _lint_config_fields_equal(a::EffectiveLintConfig, b::EffectiveLintConfig, eq)
    eq(a.severities, b.severities) && eq(a.options, b.options) && eq(a.selected, b.selected)
end
Base.:(==)(a::EffectiveLintConfig, b::EffectiveLintConfig) = _lint_config_fields_equal(a, b, ==)
Base.isequal(a::EffectiveLintConfig, b::EffectiveLintConfig) = _lint_config_fields_equal(a, b, isequal)
Base.hash(c::EffectiveLintConfig, h::UInt) =
    hash(c.severities, hash(c.options, hash(c.selected, hash(EffectiveLintConfig, h))))

"""
    rule_severity(config, rule_id) -> Symbol

The configured severity of `rule_id`, or its `default` preset severity when the
config does not mention it.
"""
# No severity fallback: every preset classifies every rule (by construction),
# and an effective config always starts from a preset, so a miss here means the
# caller passed something that is not a rule id — which should be loud.
rule_severity(config::EffectiveLintConfig, rule_id::Symbol) =
    get(config.severities, rule_id, _PRESET_DEFAULT[rule_id])

rule_enabled(config::EffectiveLintConfig, rule_id::Symbol) = rule_severity(config, rule_id) !== :off

"""
    rule_option(config, rule_id, key, default)

A rule's configured option value, or `default`.
"""
function rule_option(config::EffectiveLintConfig, rule_id::Symbol, key::Symbol, default)
    opts = get(config.options, rule_id, nothing)
    opts === nothing && return default
    return get(opts, key, default)
end

"""
    lint_options_from_config(config) -> StaticLint.LintOptions

Build the `LintOptions` gate for `check_all`: a category runs when at least one
rule mapping into it is enabled. Rules with no category always run and are
filtered when their diagnostics are emitted instead.
"""
function lint_options_from_config(config::EffectiveLintConfig)
    category_on = Dict{Symbol,Bool}()
    for rule in LINT_RULES
        rule.category === nothing && continue
        on = get(category_on, rule.category, false)
        category_on[rule.category] = on || rule_enabled(config, rule.id)
    end
    on(cat) = get(category_on, cat, true)

    return StaticLint.LintOptions(
        on(:call),
        on(:iter),
        on(:nothingcomp),
        on(:constif),
        on(:lazy),
        on(:datadecl),
        on(:typeparam),
        on(:modname),
        on(:pirates),
        on(:useoffuncargs),
        on(:kwdefault),
        on(:literal),
        on(:breakcontinue),
        on(:constdecl),
    )
end

"""
    missingrefs_from_config(config) -> Symbol

The `missingrefs` mode `StaticLint.collect_hints` expects, derived from the
`missing_reference` rule's severity and `scope` option.
"""
function missingrefs_from_config(config::EffectiveLintConfig)
    rule_enabled(config, :missing_reference) || return :none
    scope = rule_option(config, :missing_reference, :scope, "all")
    scope == "none" && return :none
    scope == "symbols" && return :id
    return :all
end
