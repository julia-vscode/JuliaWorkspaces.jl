# Conversion of `StaticLint.collect_hints` output into `Diagnostic`s.
#
# Both static-lint pipelines funnel through here: the whole-closure pass in
# layer_static_lint.jl and the per-file pass in layer_file_analysis.jl. They
# differ only in how a call mismatch is described (the per-file pass has
# cross-file arity information available) and in the container they collect
# into, both of which are parameters.

"""
    _emit_hint_diagnostics!(sink, errs, meta_dict, config, declared_deps; describe_call)

Convert `errs` (as returned by `StaticLint.collect_hints`) into
[`Diagnostic`](@ref)s and `push!` them onto `sink`.

`config` is an [`EffectiveLintConfig`](@ref); it supplies each rule's configured
severity and suppresses rules set to `"off"`. `describe_call` is called for
`IncorrectCallArgs` findings and returns a more specific message, or `nothing`
to keep the generic description.
"""
function _emit_hint_diagnostics!(sink, errs, meta_dict, config, declared_deps; describe_call)
    for err in errs
        rng = err[1]+1:err[1]+err[2].span+1
        x = err[2]

        if StaticLint.headof(x) === :errortoken
            # Parse errors are the syntax layer's job.
            continue
        end

        if CSTParser.isidentifier(x) && !StaticLint.haserror(x, meta_dict)
            severity = rule_severity(config, :missing_reference)
            severity === :off && continue
            push!(sink, Diagnostic(rng, severity, "Missing reference: $(x.val)", nothing, Symbol[], "StaticLint.jl", :missing_reference))
            continue
        end

        StaticLint.haserror(x, meta_dict) || continue
        code = StaticLint.errorof(x, meta_dict)

        if code === StaticLint.UnresolvedImport
            # This branch must stay separate from the generic `LintCodes` one
            # below even when the rule is off, so an off `unresolved_import`
            # doesn't fall through and re-emit the generic
            # "Failed to resolve import." message.
            severity = rule_severity(config, :unresolved_import)
            severity === :off && continue
            name = CSTParser.str_value(x)
            cause = name in declared_deps ?
                "`$name` is a declared dependency but its symbols could not be indexed." :
                "Failed to resolve `$name`."
            consequence = StaticLint.is_in_wildcard_import(x) ?
                "Missing-reference checks are disabled in this scope and all nested scopes." :
                "Anything imported through this statement is assumed to exist and will not be checked."
            push!(sink, Diagnostic(rng, severity, "$cause $consequence", nothing, Symbol[], "StaticLint.jl", :unresolved_import))
            continue
        end

        code isa StaticLint.LintCodes || continue

        rule_id = get(LINTCODE_TO_RULE, code, nothing)
        severity = rule_id === nothing ? :information : rule_severity(config, rule_id)
        severity === :off && continue

        description = get(StaticLint.LintCodeDescriptions, code, "")
        if code === StaticLint.IncorrectCallArgs
            detail = describe_call(x)
            detail !== nothing && (description = detail)
        end

        tags = rule_id === nothing ? Symbol[] : rule_tags(rule_id)
        code_details = rule_id === nothing ? nothing : rule_code_description(rule_id)

        push!(sink, Diagnostic(rng, severity, description, code_details, tags, "StaticLint.jl", rule_id))
    end

    return sink
end
