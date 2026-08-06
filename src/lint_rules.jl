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
    struct LintRule

A user-facing lint rule.

- `id::Symbol`: The rule id, as written in `JuliaLint.toml` and reported on
  [`Diagnostic`](@ref)`.code`.
- `codes::Vector{StaticLint.LintCodes}`: The StaticLint codes this rule covers;
  empty for rules backed by another analysis.
- `category::Union{Nothing,Symbol}`: The `StaticLint.LintOptions` field that
  gates the check emitting these codes, or `nothing` when the check always runs
  (those rules are filtered when diagnostics are emitted instead).
- `option_keys::Vector{Symbol}`: Extra keys accepted alongside `severity` when
  the rule is configured as a table.
"""
struct LintRule
    id::Symbol
    codes::Vector{StaticLint.LintCodes}
    category::Union{Nothing,Symbol}
    option_keys::Vector{Symbol}
end

const LINT_RULES = LintRule[
    # ── StaticLint rules gated by a `LintOptions` field ──────────────────────
    LintRule(:incorrect_call_args, [StaticLint.IncorrectCallArgs, StaticLint.FunctionHasNoMethods], :call, Symbol[]),
    LintRule(:incorrect_iter_spec, [StaticLint.IncorrectIterSpec], :iter, Symbol[]),
    LintRule(:index_from_length, [StaticLint.IndexFromLength], :iter, Symbol[]),
    LintRule(:nothing_comparison, [StaticLint.NothingEquality, StaticLint.NothingNotEq], :nothingcomp, Symbol[]),
    LintRule(:const_if_condition, [StaticLint.ConstIfCondition, StaticLint.EqInIfConditional], :constif, Symbol[]),
    LintRule(:pointless_boolean, [StaticLint.PointlessOR, StaticLint.PointlessAND], :lazy, Symbol[]),
    LintRule(:invalid_type_declaration, [StaticLint.InvalidTypeDeclaration], :datadecl, Symbol[]),
    LintRule(:unused_type_parameter, [StaticLint.UnusedTypeParameter], :typeparam, Symbol[]),
    LintRule(:module_name, [StaticLint.InvalidModuleName], :modname, Symbol[]),
    LintRule(:type_piracy, [StaticLint.TypePiracy, StaticLint.NotEqDef], :pirates, Symbol[]),
    LintRule(:unused_function_argument, [StaticLint.UnusedFunctionArgument], :useoffuncargs, Symbol[]),
    LintRule(:duplicate_function_argument, [StaticLint.DuplicateFuncArgName], :useoffuncargs, Symbol[]),
    LintRule(:kw_default_mismatch, [StaticLint.KwDefaultMismatch, StaticLint.UnassignedKeywordArgument], :kwdefault, Symbol[]),
    LintRule(:literal_use, [StaticLint.InappropriateUseOfLiteral], :literal, Symbol[]),
    LintRule(:break_continue, [StaticLint.ShouldBeInALoop], :breakcontinue, Symbol[]),
    LintRule(:global_const_decl, [StaticLint.TypeDeclOnGlobalVariable, StaticLint.UnsupportedConstLocalVariable], :constdecl, Symbol[]),

    # ── StaticLint rules whose checks always run (filtered at emission) ──────
    LintRule(:unused_binding, [StaticLint.UnusedBinding], nothing, Symbol[]),
    LintRule(:const_decl, [
        StaticLint.CannotDeclareConst,
        StaticLint.InvalidRedefofConst,
        StaticLint.CannotDefineFuncAlreadyHasValue,
    ], nothing, Symbol[]),
    LintRule(:relative_import, [StaticLint.RelativeImportTooManyDots], nothing, Symbol[]),
    LintRule(:include_errors, [
        StaticLint.IncludeLoop,
        StaticLint.DuplicateInclude,
        StaticLint.MissingFile,
        StaticLint.IncludePathContainsNULL,
        StaticLint.FileTooBig,
        StaticLint.FileNotAvailable,
    ], nothing, Symbol[]),
    LintRule(:missing_reference, [StaticLint.MissingRef], nothing, [:scope]),
    LintRule(:unresolved_import, [StaticLint.UnresolvedImport], nothing, Symbol[]),

    # ── Rules backed by analyses other than StaticLint ───────────────────────
    LintRule(:syntax_errors, StaticLint.LintCodes[], nothing, Symbol[]),
    LintRule(:syntax_warnings, StaticLint.LintCodes[], nothing, Symbol[]),
    LintRule(:testitem_errors, StaticLint.LintCodes[], nothing, Symbol[]),
    LintRule(:toml_syntax_errors, StaticLint.LintCodes[], nothing, Symbol[]),
    LintRule(:config_errors, StaticLint.LintCodes[], nothing, Symbol[]),
    LintRule(:shadowed_config, StaticLint.LintCodes[], nothing, Symbol[]),
]

const LINT_RULES_BY_ID = Dict{Symbol,LintRule}(r.id => r for r in LINT_RULES)

const LINTCODE_TO_RULE = Dict{StaticLint.LintCodes,Symbol}(
    c => r.id for r in LINT_RULES for c in r.codes
)

# Rules whose findings depend on package symbols being indexed, and which are
# therefore suppressed until a file's environment is ready (see
# `_is_env_dependent_diagnostic`).
const ENV_DEPENDENT_LINT_RULES = Set{Symbol}([
    :incorrect_call_args,
    :incorrect_iter_spec,
    :nothing_comparison,
    :invalid_type_declaration,
    :type_piracy,
    :kw_default_mismatch,
    :missing_reference,
    :unresolved_import,
])

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

# `default` reproduces the severities that were hard-coded before rules became
# configurable, so an absent config file changes nothing.
const _PRESET_DEFAULT = Dict{Symbol,Symbol}(
    :incorrect_call_args => :information,
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
    :relative_import => :information,
    :include_errors => :warning,
    :missing_reference => :warning,
    :unresolved_import => :warning,
    :syntax_errors => :error,
    :syntax_warnings => :off,
    :testitem_errors => :error,
    :toml_syntax_errors => :error,
    :config_errors => :error,
    :shadowed_config => :information,
)

# Checked here, before the derived presets are built, so that a rule nobody
# classified fails with this message rather than with an opaque `KeyError` from
# the `_PRESET_STRICT` comprehension below.
for _rule in LINT_RULES
    haskey(_PRESET_DEFAULT, _rule.id) || error(
        "Lint rule `$(_rule.id)` has no severity in the `default` preset. Add one to " *
        "`_PRESET_DEFAULT`. Prefer `:off` for a rule that did not exist before: a rule " *
        "that switches itself on for every project on upgrade breaks their CI."
    )
end

# Only the checks that catch outright breakage; everything stylistic is off.
const _PRESET_MINIMAL = Dict{Symbol,Symbol}(
    r.id => get(
        Dict{Symbol,Symbol}(
            :syntax_errors => :error,
            :testitem_errors => :error,
            :toml_syntax_errors => :error,
            :config_errors => :error,
            :include_errors => :warning,
            :const_decl => :warning,
            # A structural problem with the project's own configuration, not a
            # style opinion — it stays on even in the quietest preset.
            :shadowed_config => :information,
        ),
        r.id,
        :off,
    )
    for r in LINT_RULES
)

# Everything on, and everything that is merely a hint promoted to a warning.
const _PRESET_STRICT = Dict{Symbol,Symbol}(
    r.id => begin
        d = _PRESET_DEFAULT[r.id]
        r.id === :syntax_warnings ? :warning :
        d === :off ? :warning :
        d === :hint ? :warning :
        d === :information ? :warning : d
    end
    for r in LINT_RULES
)

const LINT_PRESETS = Dict{String,Dict{Symbol,Symbol}}(
    "minimal" => _PRESET_MINIMAL,
    "default" => _PRESET_DEFAULT,
    "strict" => _PRESET_STRICT,
)

# The same invariant for the derived presets: both are comprehensions over
# `LINT_RULES` today, so this only fires if one is later rewritten in a way that
# stops covering every rule.
for (_preset_name, _preset) in LINT_PRESETS, _rule in LINT_RULES
    haskey(_preset, _rule.id) || error(
        "Lint rule `$(_rule.id)` is missing from the `$(_preset_name)` preset. " *
        "Every preset in `LINT_PRESETS` must classify every rule in `LINT_RULES`."
    )
end

const DEFAULT_LINT_PRESET = "default"

const VALID_LINT_PRESETS = ["minimal", "default", "strict"]

# Tags are a property of the rule, not of the configured severity: an unused
# binding stays "unnecessary" (greyed out by the editor) whether the user
# reports it as a hint or an error.
const _UNNECESSARY_RULES = Set{Symbol}([
    :unused_binding,
    :unused_function_argument,
    :unused_type_parameter,
])

rule_tags(rule_id::Symbol) = rule_id in _UNNECESSARY_RULES ? Symbol[:unnecessary] : Symbol[]

# Documentation links surfaced as the diagnostic's code description.
const _RULE_CODE_DESCRIPTIONS = Dict{Symbol,URI}(
    :index_from_length => URI("https://docs.julialang.org/en/v1/base/arrays/#Base.eachindex"),
)

rule_code_description(rule_id::Symbol) = get(_RULE_CODE_DESCRIPTIONS, rule_id, nothing)

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

EffectiveLintConfig() = EffectiveLintConfig(copy(_PRESET_DEFAULT), Dict{Symbol,Dict{Symbol,Any}}(), true)

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
# No severity fallback: every preset classifies every rule (enforced at load),
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
