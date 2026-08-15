# Lowering-backed lint rules (experiment, behind `input_lowering_lint`).
#
# No new rule ids: when the flag is on, this producer TAKES OVER the rules in
# `LOWERING_TAKEOVER_RULES` from StaticLint — same ids, severities, presets and
# JuliaLint.toml surface, different engine (the vendored-JuliaLowering binding
# analysis in layer_lowering.jl). When the flag is off (the default), nothing
# below the gate is ever demanded and diagnostics behave exactly as before.
#
# Query shape mirrors the syntax-rule engine: a position-free per-item query
# that backdates (`derived_item_semantic_findings`), and a volatile per-file
# emission join (`derived_semantic_lint_findings`) that is the only reader of
# the address→range maps.

const LOWERING_TAKEOVER_RULES = Set([:unused_binding, :unused_function_argument])

# The gate both producers consult. Evaluation order matters: with the flag off
# the only Salsa dependency is the flag input itself, so config edits do not
# even re-verify this query.
Salsa.@derived function derived_lowering_lint_active(rt, uri)
    input_lowering_lint(rt) || return false
    config = derived_effective_lint_config(rt, uri)
    return any(rule_enabled(config, id) for id in LOWERING_TAKEOVER_RULES)
end

const SemanticFinding = @NamedTuple{addr::Int32, rule_id::Symbol, msg::String}

"""
    derived_item_semantic_findings(rt, ref) -> Vector{SemanticFinding}

Position-free unused-binding findings for one item, from the lowering
projection. Backdates across position-only edits (its only dependency is the
position-free `derived_item_lowering`). Empty when lowering is unavailable,
errored, or absent — degradation is silence, never noise.
"""
Salsa.@derived function derived_item_semantic_findings(rt, ref)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return result

    # One source declaration can produce SEVERAL lowered bindings, because
    # desugaring duplicates a pattern into each closure or method it generates.
    # Two cases pull in opposite directions:
    #
    #   [f(n) for (n, c) in d if g(c)]   -> filter closure + body closure, each
    #                                       binding both names and reading one;
    #                                       the variable IS used.
    #   f(a, b = default) = ...          -> a forwarding method `f(a) = f(a, d)`
    #                                       that reads `a` purely to pass it on;
    #                                       an unused `a` IS still unused.
    #
    # What separates them is WHERE the read happens: a genuine use sits at a
    # different node than the declaration, whereas a synthesized forwarding read
    # is derived from the signature and so carries the declaration's own address.
    # So a declaration counts as used only when one of its bindings is read at
    # some other address.
    decl_of = Dict{Int32,Int32}()
    for b in low.bindings
        b.is_read && (decl_of[b.id] = b.addr)
    end
    used_addrs = Set{Int32}()
    for u in low.uses
        d = get(decl_of, u.binding, Int32(0))
        (d != Int32(0) && u.addr != d) && push!(used_addrs, d)
    end

    emitted = Set{Int32}()
    for b in low.bindings
        b.is_internal && continue
        b.is_read && continue
        b.addr == Int32(0) && continue
        b.addr in used_addrs && continue
        b.addr in emitted && continue
        # `_`-prefixed names are the intentionally-unused convention.
        (isempty(b.name) || startswith(b.name, "_")) && continue
        if b.kind === :local
            push!(emitted, b.addr)
            push!(result, (addr=b.addr, rule_id=:unused_binding,
                msg="Variable `$(b.name)` has been assigned but not used."))
        elseif b.kind === :argument
            push!(emitted, b.addr)
            push!(result, (addr=b.addr, rule_id=:unused_function_argument,
                msg="Argument `$(b.name)` is never used within the function body."))
        end
    end
    return result
end

"""
    derived_semantic_lint_findings(rt, uri) -> Vector{LintFinding}

The volatile emission join: per-item findings reattached to byte ranges via
`derived_file_lowering_maps`. Volatile by design (recomputes on every reparse,
like `derived_item_positions`); only `derived_diagnostics` may depend on it.
Returns an empty vector without demanding ANY lowering machinery when the
feature flag is off or no takeover rule is enabled.
"""
Salsa.@derived function derived_semantic_lint_findings(rt, uri)
    result = LintFinding[]
    derived_lowering_lint_active(rt, uri) || return result

    maps = derived_file_lowering_maps(rt, uri)
    maps === nothing && return result

    for item in derived_file_inventory(rt, uri).items
        item_findings = derived_item_semantic_findings(rt, ItemRef(uri, item.id))
        isempty(item_findings) && continue
        ranges = get(maps, item.id, nothing)
        ranges === nothing && continue
        for f in item_findings
            1 <= f.addr <= length(ranges) || continue
            push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
        end
    end
    return result
end
