# The v2 include diagnostics, behind `input_v2_enabled`: the twin of
# `derived_include_diagnostics` (layer_includes.jl gates to it). The include
# walk itself is v1's (`derived_file_include_data`: runtime targets, quoted
# code skipped, `module` bodies scoping duplicates); what differs is the
# emission: a computed include, or a function-body include whose literal
# target exists, is an analysis-boundary NOTICE routed to the
# `analysis_boundary` rule through the diagnostic's `code`, while the
# include-graph errors stay `include_errors` with StaticLint's codes.
#
# `_collect_include_diagnostics_v2!` is `_collect_include_diagnostics!`
# verbatim except for that code selection.

# The analysis-boundary notices of the v2 include diagnostics. Not StaticLint
# codes: they are v2's own, routed to the `analysis_boundary` rule by the
# diagnostic's `code`, while the include-graph errors keep StaticLint's codes
# and descriptions under `include_errors`.
const _INCLUDE_BOUNDARY_NOTICES_V2 = Dict{Symbol,String}(
    :computed => "The include path could not be determined statically. The included file is analyzed without this module's context, and missing_reference, incorrect_call_args, type_piracy, invalid_type_declaration, kw_default_mismatch and incorrect_iter_spec are not applied in this module.",
    :runtime => "This `include` runs inside a function body, so its target is spliced at run time rather than analyzed in this module's context; missing_reference, incorrect_call_args, type_piracy, invalid_type_declaration, kw_default_mismatch and incorrect_iter_spec are not applied in this module.",
)

function _include_diagnostic_v2(offset, span, code)
    rng = (offset + 1):(offset + span + 1)
    if code isa Symbol
        return Diagnostic(rng, :warning, _INCLUDE_BOUNDARY_NOTICES_V2[code], nothing, Symbol[], "StaticLint.jl", :analysis_boundary)
    end
    description = StaticLint.LintCodeDescriptions[code]
    return Diagnostic(rng, :warning, description, nothing, Symbol[], "StaticLint.jl", :include_errors)
end

function _collect_include_diagnostics_v2!(rt, uri, stack, visited, guarded_visited, result)
    push!(stack, uri)

    # A `@testitem`/`@testmodule`/`@testsnippet` body or a `module` block runs
    # in a module of its own, so including a file there says nothing about
    # whether the same file was included elsewhere: each body gets its own
    # visited sets, keyed by the macrocall or `module` offset. Including the
    # same file twice *within* one body is
    # still a duplicate, and so is a repeat further down that body's include
    # subtree, which inherits these sets.
    testitem_visited = Dict{Int,Tuple{Set{URI},Set{URI}}}()
    runtime_targets = derived_file_include_data(rt, uri).runtime_targets

    for (offset, span, target, guarded, testitem_ctx) in derived_file_include_records(rt, uri)
        seen, guarded_seen = testitem_ctx === nothing ?
            (visited, guarded_visited) :
            get!(() -> (Set{URI}(), Set{URI}()), testitem_visited, testitem_ctx)

        if target === nothing
            # A computed include path: the target file cannot be attributed,
            # so it is analyzed without this module's context and bare
            # missing-reference checking is unreliable in this module (see
            # `derived_module_has_computed_include`). One honest diagnostic
            # here replaces the storm of false missing_reference positives
            # the unattributed file would otherwise produce. Guarded computed
            # includes (`const depsjl = joinpath(...); isfile(depsjl) &&
            # include(depsjl)`) abstain like the rest; the missing-reference
            # relaxation applies either way.
            #
            # A LITERAL path inside a function body is spliced at run time —
            # no static splice context, so still a computed include for
            # analysis purposes — but its target can be existence-checked:
            # a missing file is a MissingFile, not a "path could not be
            # determined" (a `load() = include("x.jl")` thunk).
            #
            # v2: a runtime include whose target exists and a computed include are
            # analysis-boundary NOTICES (`:runtime` / `:computed`, routed to the
            # `analysis_boundary` rule by `_include_diagnostic_v2`), not
            # include_errors warnings; a missing literal target stays a MissingFile.
            rtarget = get(runtime_targets, offset, nothing)
            if !guarded
                code = if rtarget !== nothing
                    derived_text_file_content(rt, rtarget) === nothing ? StaticLint.MissingFile : :runtime
                else
                    :computed
                end
                push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, code))
            end
            continue
        end

        if derived_text_file_content(rt, target) === nothing
            # A guarded include's condition makes file structure runtime-
            # dependent (`isfile(deps) && include(deps)`, the standard shape
            # for Pkg.build-generated deps.jl files): whether the target
            # should exist statically is unknowable, so abstain.
            guarded || push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.MissingFile))
            continue
        end

        if target in stack
            push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.IncludeLoop))
            continue
        end

        if target in seen
            if guarded || target in guarded_seen
                # Abstain when either side of the duplication is conditional:
                # this include is guarded (`@isdefined(X) || include("x.jl")`
                # is idiomatic double-inclusion protection), or every prior
                # include of the target was — then this is the canonical
                # include, not a duplicate. The latter pardon is spent here,
                # so a further unconditional include is a real duplicate.
                guarded || delete!(guarded_seen, target)
            else
                push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.DuplicateInclude))
            end
            continue
        end

        push!(seen, target)
        guarded && push!(guarded_seen, target)

        # This walk follows include *targets*, so unlike the other traversals it
        # is not fed by `derived_all_julia_files` and can reach a non-Julia
        # document (`include("README.md")`). Loop and duplicate detection above
        # still counts it; descending would ask the legacy parser to read its
        # prose as Julia.
        _is_julia_uri(rt, target) || continue

        _collect_include_diagnostics_v2!(rt, target, stack, seen, guarded_seen, result)
    end

    pop!(stack)

    return result
end

"""
    derived_all_include_diagnostics_v2(rt)

Compute include-graph diagnostics (`DuplicateInclude`, `IncludeLoop`,
`MissingFile`) for the whole workspace, keyed by the URI of the file that
contains the offending `include(...)` statement.

This is a purely structural analysis over the include graph and does not depend
on a project/environment, so it is reported even for files that are not part of
a package.
"""
Salsa.@derived function derived_all_include_diagnostics_v2(rt)
    @debug "derived_all_include_diagnostics_v2"

    result = Dict{URI,Vector{Diagnostic}}()

    for root in derived_roots(rt)
        stack = URI[]
        visited = Set{URI}([root])
        guarded_visited = Set{URI}()
        _collect_include_diagnostics_v2!(rt, root, stack, visited, guarded_visited, result)
    end

    # The same statement can be reached from multiple roots; deduplicate.
    for ds in values(result)
        unique!(ds)
    end

    return result
end

Salsa.@derived function derived_include_diagnostics_v2(rt, uri)
    all_diags = derived_all_include_diagnostics_v2(rt)

    return get(all_diags, uri, Diagnostic[])
end
