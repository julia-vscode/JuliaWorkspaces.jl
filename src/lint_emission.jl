# Conversion of `StaticLint.collect_hints` output into `LintFinding`s.
#
# Both static-lint pipelines funnel through here: the whole-closure pass in
# layer_static_lint.jl and the per-file pass in layer_file_analysis.jl. They
# differ only in how a call mismatch is described (the per-file pass has
# cross-file arity information available) and in the container they collect
# into, both of which are parameters.
#
# Findings carry no severity — that (plus tags and doc links) is applied in
# exactly one place, `materialize` in `derived_diagnostics`. This function only
# decides WHICH rule a hint belongs to and renders its message.

"""
    _emit_hint_findings!(sink, errs, meta_dict, declared_deps; describe_call)

Convert `errs` (as returned by `StaticLint.collect_hints`) into
[`LintFinding`](@ref)s and `push!` them onto `sink`.

Rule enablement and severity are applied later, at materialization — the
configuration deliberately does not reach this function. `describe_call` is
called for `IncorrectCallArgs` findings and returns a more specific message, or
`nothing` to keep the generic description.
"""
function _emit_hint_findings!(sink, errs, meta_dict, declared_deps; describe_call)
    for err in errs
        rng = err[1]+1:err[1]+err[2].span+1
        x = err[2]

        if StaticLint.headof(x) === :errortoken
            # Parse errors are the syntax layer's job.
            continue
        end

        if CSTParser.isidentifier(x) && !StaticLint.haserror(x, meta_dict)
            push!(sink, LintFinding(rng, :missing_reference, "Missing reference: $(x.val)", nothing, "StaticLint.jl"))
            continue
        end

        StaticLint.haserror(x, meta_dict) || continue
        code = StaticLint.errorof(x, meta_dict)

        if code === StaticLint.UnresolvedImport
            # This branch must stay separate from the generic `LintCodes` one
            # below, so an `unresolved_import` finding doesn't fall through and
            # re-emit the generic "Failed to resolve import." message.
            name = CSTParser.str_value(x)
            cause = name in declared_deps ?
                "`$name` is a declared dependency but its symbols could not be indexed." :
                "Failed to resolve `$name`."
            consequence = StaticLint.is_in_wildcard_import(x) ?
                "Missing-reference checks are disabled in this scope and all nested scopes." :
                "Anything imported through this statement is assumed to exist and will not be checked."
            push!(sink, LintFinding(rng, :unresolved_import, "$cause $consequence", nothing, "StaticLint.jl"))
            continue
        end

        code isa StaticLint.LintCodes || continue

        # Total by the load-time invariant in lint_rules.jl: every LintCodes
        # member belongs to exactly one rule.
        rule_id = LINTCODE_TO_RULE[code]

        description = get(StaticLint.LintCodeDescriptions, code, "")
        if code === StaticLint.IncorrectCallArgs
            detail = describe_call(x)
            detail !== nothing && (description = detail)
        end

        push!(sink, LintFinding(rng, rule_id, description, nothing, "StaticLint.jl"))
    end

    return sink
end
