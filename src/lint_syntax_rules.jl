# Purely syntactic lint rules (tier `TierSyntax`).
#
# Rules in this tier need nothing but the JuliaSyntax tree of a single file: no
# semantic pass, no environment, no other files. They are implemented as plain
# functions collected in the `SYNTAX_CHECKS` tuple and run in a single pre-order
# walk per file.
#
# The tuple (rather than a `Vector`) is deliberate: it makes the element types
# part of the container's type, so every `check.fn` call below is statically
# dispatched — no `::Function` fields, no dynamic dispatch in the hot walk, and
# the whole engine stays precompile- and juliac-friendly. Whether a rule is
# enabled is a runtime `Set` membership test, so configuration never affects
# code specialization.

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

# ── nan_comparison ──────────────────────────────────────────────────────────

const _NAN_NAMES = (:NaN, :NaN16, :NaN32, :NaN64)
const _EQUALITY_OPS = (:(==), :(!=), :≠)

_is_nan_identifier(node) = kind(node) === K"Identifier" && node.val isa Symbol && node.val in _NAN_NAMES

const _NAN_COMPARISON_MESSAGE = "Comparing with `NaN` using `==` or `!=` always yields the same result. Use `isnan` instead."

function _check_nan_comparison(emit!, node, _ctx)
    cs = children(node)
    if kind(node) === K"comparison"
        # Chained comparison: operands at odd indices, operators at even ones.
        for i in 2:2:length(cs)-1
            if _op_symbol(cs[i]) in _EQUALITY_OPS && (_is_nan_identifier(cs[i-1]) || _is_nan_identifier(cs[i+1]))
                emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
                return nothing
            end
        end
    elseif JuliaSyntax.is_infix_op_call(node)
        # `a == NaN`, `a .== NaN`
        if length(cs) == 3 && _op_symbol(cs[2]) in _EQUALITY_OPS &&
           (_is_nan_identifier(cs[1]) || _is_nan_identifier(cs[3]))
            emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
        end
    else
        # `==(a, NaN)`
        if length(cs) == 3 && _op_symbol(cs[1]) in _EQUALITY_OPS &&
           (_is_nan_identifier(cs[2]) || _is_nan_identifier(cs[3]))
            emit!(_node_range(node), _NAN_COMPARISON_MESSAGE)
        end
    end
    return nothing
end

# ── duplicate_branch_condition ──────────────────────────────────────────────

# A repeated condition only makes the later branch dead when evaluating the
# earlier one cannot have changed anything, so the rule restricts itself to
# conditions built from identifiers, literals, field access, indexing and
# operator calls. A condition containing an arbitrary function or macro call
# (`rand() < 0.5`, `readline() == "y"`) can legitimately differ between
# evaluations and is never reported.
function _side_effect_free(node::SyntaxNode)
    JuliaSyntax.is_leaf(node) && return true   # identifiers and literals
    k = kind(node)
    cs = children(node)
    if k === K"call" || k === K"dotcall"
        isempty(cs) && return false
        if JuliaSyntax.is_infix_op_call(node)
            op = _op_symbol(cs[2])
            op !== nothing && Base.isoperator(op) || return false
            return all(_side_effect_free(cs[i]) for i in eachindex(cs) if i != 2)
        else
            op = _op_symbol(cs[1])
            op !== nothing && Base.isoperator(op) || return false
            return all(_side_effect_free, @view cs[2:end])
        end
    elseif k === K"parens" || k === K"&&" || k === K"||" || k === K"comparison" ||
           k === K"." || k === K"ref" || k === K"quote"
        return all(_side_effect_free, cs)
    else
        return false
    end
end

const _DUPLICATE_BRANCH_MESSAGE = "This condition is identical to an earlier condition in the same `if`/`elseif` chain, so this branch can never run."

function _check_duplicate_branch_condition(emit!, node, _ctx)
    # Registered on `K"if"` only; the `elseif` chain is walked from here so
    # each chain is examined exactly once.
    conditions = SyntaxNode[]
    current = node
    while true
        cs = children(current)
        isempty(cs) && return nothing
        condition = cs[1]
        for earlier in conditions
            if _syntax_equal(earlier, condition) && _side_effect_free(condition)
                emit!(_node_range(condition), _DUPLICATE_BRANCH_MESSAGE)
                break
            end
        end
        push!(conditions, condition)
        kind(cs[end]) === K"elseif" || return nothing
        current = cs[end]
    end
end

# ── Check registry ──────────────────────────────────────────────────────────

# A concrete tuple: `Tuple{SyntaxCheck{typeof(f1)}, SyntaxCheck{typeof(f2)}, …}`.
const SYNTAX_CHECKS = (
    SyntaxCheck(:nan_comparison, (K"call", K"dotcall", K"comparison"), _check_nan_comparison),
    SyntaxCheck(:duplicate_branch_condition, (K"if",), _check_duplicate_branch_condition),
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
