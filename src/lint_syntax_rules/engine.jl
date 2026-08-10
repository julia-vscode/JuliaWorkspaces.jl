# Purely syntactic lint rules (tier `TierSyntax`).
#
# Rules in this tier need nothing but the JuliaSyntax tree of a single file: no
# semantic pass, no environment, no other files. Each rule lives in its own file
# in this folder and defines a check function plus a `SyntaxCheck` const; this
# file holds everything shared — the finding type, the engine, common helpers,
# the `SYNTAX_CHECKS` tuple that collects the rules, and the Salsa queries.
#
# The tuple (rather than a `Vector`) is deliberate: it makes the element types
# part of the container's type, so every `check.fn` call below is statically
# dispatched — no `::Function` fields, no dynamic dispatch in the hot walk, and
# the whole engine stays precompile- and juliac-friendly. Whether a rule is
# enabled is a runtime `Set` membership test, so configuration never affects
# code specialization.
#
# Adding a rule: one new file here (check function + `SyntaxCheck` const), one
# entry in the include list and `SYNTAX_CHECKS` below, one `LintRule` entry in
# lint_rules.jl.

"""
    struct LintFinding

One finding of a lint rule, before severity is applied. Producers emit findings;
[`materialize`](@ref) turns them into [`Diagnostic`](@ref)s using the effective
configuration, so severity, tags and documentation links are applied in exactly
one place.

- `range::UnitRange{Int64}`: 1-based byte range, exclusive end (as on `Diagnostic`).
- `rule_id::Symbol`: the rule that produced the finding, see `LINT_RULES`.
- `message::String`
- `uri::Union{Nothing,URI}`: an explicit related location; when `nothing`, the
  rule's `doc_link` is used instead.
- `source::String`: the `Diagnostic.source` to report.
"""
struct LintFinding
    range::UnitRange{Int64}
    rule_id::Symbol
    message::String
    uri::Union{Nothing,URI}
    source::String
end

# Same endpoint-comparing equality treatment as `Diagnostic` (see types.jl):
# empty ranges at different positions must not compare equal, or Salsa would
# backdate a shifted zero-width finding and keep a stale range.
function _finding_fields_equal(a::LintFinding, b::LintFinding, eq)
    eq(first(a.range), first(b.range)) && eq(last(a.range), last(b.range)) &&
        eq(a.rule_id, b.rule_id) && eq(a.message, b.message) &&
        eq(a.uri, b.uri) && eq(a.source, b.source)
end
Base.:(==)(a::LintFinding, b::LintFinding) = _finding_fields_equal(a, b, ==)
Base.isequal(a::LintFinding, b::LintFinding) = _finding_fields_equal(a, b, isequal)
function Base.hash(f::LintFinding, h::UInt)
    h = hash(first(f.range), h)
    h = hash(last(f.range), h)
    h = hash(f.rule_id, h)
    h = hash(f.message, h)
    h = hash(f.uri, h)
    h = hash(f.source, h)
    return hash(LintFinding, h)
end

"""
    materialize(finding, config) -> Union{Nothing,Diagnostic}

Apply the configured severity and the rule's tags and documentation link to a
[`LintFinding`](@ref). Returns `nothing` when the rule is off.
"""
function materialize(f::LintFinding, config::EffectiveLintConfig)
    severity = rule_severity(config, f.rule_id)
    severity === :off && return nothing
    rule = LINT_RULES_BY_ID[f.rule_id]
    uri = f.uri === nothing ? rule.doc_link : f.uri
    return Diagnostic(f.range, severity, f.message, uri, rule.tags, f.source, f.rule_id)
end

# ── Engine ──────────────────────────────────────────────────────────────────

struct SyntaxRuleContext
    uri::URI
end

"""
    struct SyntaxCheck{F}

The implementation of one `TierSyntax` rule. `fn` is called as
`fn(emit!, node, ctx)` for every node whose kind is in `kinds` (every node when
`kinds` is empty); it reports findings via `emit!(range, message)`. The type
parameter keeps the concrete function type in the struct so calls through the
`SYNTAX_CHECKS` tuple dispatch statically.
"""
struct SyntaxCheck{F}
    rule_id::Symbol
    kinds::Tuple{Vararg{JuliaSyntax.Kind}}
    fn::F
end

@inline _apply_syntax_checks(::Tuple{}, findings, node, ctx, enabled) = nothing
@inline function _apply_syntax_checks(checks::Tuple, findings, node, ctx, enabled)
    c = first(checks)
    if (isempty(c.kinds) || kind(node) in c.kinds) && c.rule_id in enabled
        emit! = (range, message) -> begin
            push!(findings, LintFinding(range, c.rule_id, message, nothing, "JuliaWorkspaces.jl"))
            nothing
        end
        c.fn(emit!, node, ctx)
    end
    _apply_syntax_checks(Base.tail(checks), findings, node, ctx, enabled)
    return nothing
end

function _walk_syntax_checks!(findings, node, ctx, enabled)
    _apply_syntax_checks(SYNTAX_CHECKS, findings, node, ctx, enabled)
    if !JuliaSyntax.is_leaf(node)
        for c in children(node)
            _walk_syntax_checks!(findings, c, ctx, enabled)
        end
    end
    return nothing
end

function run_syntax_rules(tree::SyntaxNode, enabled::Set{Symbol}, ctx::SyntaxRuleContext)
    findings = LintFinding[]
    _walk_syntax_checks!(findings, tree, ctx, enabled)
    return findings
end

# ── Shared helpers ──────────────────────────────────────────────────────────

_op_symbol(node) = kind(node) === K"Identifier" && node.val isa Symbol ? node.val : nothing

# `_range(node)`, minus leading whitespace. JuliaSyntax attributes the trivia
# between `elseif` and its condition to the condition node itself, so reporting
# the raw range there underlines " a > 1" instead of "a > 1".
function _node_range(node::SyntaxNode)
    rng = _range(node)
    txt = JuliaSyntax.sourcetext(node)
    start = first(rng)
    i = firstindex(txt)
    while i <= lastindex(txt) && isspace(txt[i])
        start += ncodeunits(txt[i])
        i = nextind(txt, i)
    end
    return min(start, last(rng)):last(rng)
end

# The `@name` symbol a macrocall invokes, or `nothing`: handles both the bare
# form (`@show x` — first child is the `MacroName`) and the qualified form
# (`Base.@show x` — first child is a `K"."` whose last child is the name).
function _macro_name(node::SyntaxNode)
    cs = children(node)
    isempty(cs) && return nothing
    c = cs[1]
    if kind(c) === K"." && !JuliaSyntax.is_leaf(c)
        inner = children(c)
        isempty(inner) && return nothing
        c = inner[end]
    end
    kind(c) === K"MacroName" && c.val isa Symbol || return nothing
    return c.val
end

# Structural equality of two syntax trees: same kinds, same leaf values,
# trivia (whitespace, comments) ignored because it never reaches the
# `SyntaxNode` tree.
function _syntax_equal(a::SyntaxNode, b::SyntaxNode)
    kind(a) === kind(b) || return false
    JuliaSyntax.is_leaf(a) != JuliaSyntax.is_leaf(b) && return false
    JuliaSyntax.is_leaf(a) && return isequal(a.val, b.val)
    ca, cb = children(a), children(b)
    length(ca) == length(cb) || return false
    return all(_syntax_equal(x, y) for (x, y) in zip(ca, cb))
end

# ── Rules ───────────────────────────────────────────────────────────────────

include("nan_comparison.jl")
include("duplicate_branch_condition.jl")
include("string_concat_style.jl")
include("bare_using.jl")
include("debug_statement.jl")
include("async_task.jl")

# A concrete tuple: `Tuple{SyntaxCheck{typeof(f1)}, SyntaxCheck{typeof(f2)}, …}`.
const SYNTAX_CHECKS = (
    NAN_COMPARISON_CHECK,
    DUPLICATE_BRANCH_CONDITION_CHECK,
    STRING_CONCAT_STYLE_CHECK,
    BARE_USING_CHECK,
    DEBUG_STATEMENT_CHECK,
    ASYNC_TASK_CHECK,
)

const SYNTAX_CHECK_RULE_IDS = Set{Symbol}(c.rule_id for c in SYNTAX_CHECKS)

# ── Salsa queries ───────────────────────────────────────────────────────────

# The enabled set is its own query so that a config edit that only changes
# severities (not which rules are on) backdates here and never re-runs the
# parse + walk in `derived_syntax_lint_findings`.
Salsa.@derived function derived_enabled_syntax_rules(rt, uri)
    config = derived_effective_lint_config(rt, uri)
    return Set{Symbol}(id for id in SYNTAX_CHECK_RULE_IDS if rule_enabled(config, id))
end

Salsa.@derived function derived_syntax_lint_findings(rt, uri)
    enabled = derived_enabled_syntax_rules(rt, uri)
    isempty(enabled) && return LintFinding[]

    tf = derived_text_file_content(rt, uri)
    tree, _ = parse_julia_syntax_tree(tf.content.content)

    return run_syntax_rules(tree, enabled, SyntaxRuleContext(uri))
end
