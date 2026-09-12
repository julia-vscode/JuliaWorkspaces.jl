# The v2 diagnostics join, behind `input_v2_enabled`: the twins of
# `derived_diagnostics`, `derived_new_static_lint_diagnostics` and
# `derived_environment_error_messages` (layer_diagnostics.jl and
# layer_file_analysis.jl gate to the first two; the third is only read
# here). The v1 join is main's, verbatim; this one adds the v2 producers
# and the boundary/project-file/located-environment-error emission.

"""
    derived_new_static_lint_diagnostics_v2(rt, uri) -> Set{LintFinding}

The per-file consumer face of static-lint diagnostics: for every root `uri`
belongs to (`derived_roots_for_uri`), take that root's per-file analysis
diagnostics (`derived_file_analysis(rt, root, uri).diagnostics`) and union
them into a `Set`. The cross-root union/dedup reproduces the old
`derived_static_lint_diagnostics` behavior exactly — the same diagnostic can
be produced from multiple roots via includes, and a file in no root yields
an empty set. The per-file provenance is what makes a per-keystroke edit cost
one analysis (the edited file's own) instead of a whole-closure re-lint.

A root with no project (`derived_project_uri_for_root === nothing`) publishes
NOTHING — matching the old `derived_static_lint_diagnostics_for_root`, which
bails empty in that case. The per-file ANALYSIS still runs against the
stdlib-only env fallback (so other consumers keep working), but its
diagnostics are suppressed here: while a root has no project (e.g. a loose
file during the LS-startup no-active-project window), every real-package
import would otherwise flash a "Failed to resolve …" false positive. Once a
project is active, `new == old` again.
"""
Salsa.@derived function derived_new_static_lint_diagnostics_v2(rt, uri)
    @debug "derived_new_static_lint_diagnostics_v2" uri=uri

    res = Set{LintFinding}()
    for root in derived_roots_for_uri(rt, uri)
        # A project-less root contributes no diagnostics (parity with the old
        # per-root query, layer_static_lint.jl) — except a package's script
        # (`perf/`, `benchmark/`, `examples/`), which is checked against the
        # active project or, without one, the stdlib-only environment: before
        # scripts were routed to the active project they were linted in the
        # package's environment, and the routing did not mean losing their
        # findings (`index_from_length` in benchmark loops).
        if derived_project_uri_for_root(rt, root) === nothing
            pkg_uri = derived_package_for_file(rt, root)
            (pkg_uri !== nothing && _is_package_script_file(rt, pkg_uri, root)) || continue
        end
        union!(res, derived_file_analysis(rt, root, uri).diagnostics)
    end
    return res
end

# The user-facing messages of every failed dynamic work item whose project
# folder contains the project file at `uri`. A test-env failure and an env
# failure for the same folder both land on that folder's Project.toml. A
# synthesized workspace member additionally shows its ROOT's failures — the
# member's environment depends on the root's watch item, and the member file
# is often the one open in the editor. Sorted for a deterministic diagnostic
# order; identical messages from different keys (e.g. stale content hashes of
# the same folder) collapse to one.
Salsa.@derived function derived_environment_error_messages_v2(rt, uri)
    folder_uri = filepath2uri(dirname(uri2filepath(uri)))
    match_uris = Set{URI}([folder_uri])
    project = derived_project_v2(rt, folder_uri)
    if project !== nothing && _is_synthesized_member(project, folder_uri)
        push!(match_uris, filepath2uri(dirname(uri2filepath(project.manifest_file_uri))))
    end
    messages = String[]
    for (key, message) in input_dynamic_failure_messages(rt)
        if _failure_folder_uri(rt, key) in match_uris
            push!(messages, message)
        end
    end
    return unique!(sort!(messages))
end

"""
    _environment_error_range(rt, uri, pf, message) -> UnitRange{Int}

Best-effort location for an environment-resolution failure: when the failure
message names a package from the file's `[deps]`/`[sources]`, the diagnostic
points at that entry's key; otherwise the whole-file `1:1`. Word-boundary,
case-sensitive matching — Julia package names are identifiers, so this cannot
tear a name out of a longer one.
"""
function _environment_error_range(rt, uri, pf, message)
    pf === nothing && return 1:1
    for (section, names) in (("deps", keys(pf.deps)), ("sources", keys(pf.sources)))
        for name in sort!(collect(names))
            if occursin(Regex("\\b\\Q$name\\E\\b"), message)
                return _toml_range_for_key_path(rt, uri, String[section, name], :key)
            end
        end
    end
    return 1:1
end

"""
    _toml_range_for_key_path(rt, uri, key_path, at) -> UnitRange{Int}

The byte range a `ProjectTomlProblem` (or any key-path-addressed TOML finding)
should be reported at: the key node of the item whose dotted path matches
`key_path`, or its value node when `at === :value`; the enclosing section
header when the exact item does not exist in the text; `1:1` as the last
resort. A last-mile reader of the volatile TOML walk maps — call this only
from a diagnostics emission join.
"""
function _toml_range_for_key_path(rt, uri, key_path::Vector{String}, at::Symbol)
    isempty(key_path) && return 1:1

    skeleton = derived_toml_file_skeleton(rt, uri)

    best = nothing
    for row in skeleton.items
        full = isempty(row.table) ? row.key : vcat(row.table, row.key)
        if full == key_path
            best = row
            break
        end
    end
    if best === nothing
        # No such item (a "missing key" problem): the deepest existing section
        # header on the path.
        for n in length(key_path):-1:1
            prefix = key_path[1:n]
            for row in skeleton.items
                if (row.kind === :table || row.kind === :array_table) && row.key == prefix
                    best = row
                    break
                end
            end
            best === nothing || break
        end
    end
    best === nothing && return 1:1

    ranges = get(derived_toml_file_maps(rt, uri), best.id, nothing)
    (ranges === nothing || isempty(ranges)) && return 1:1

    if at === :value && best.kind === :keyval
        # Preorder addresses: 1 = the keyval, 2 = the key node, 3..2+n = the n
        # key parts, 3+n = the value node.
        value_address = 3 + length(best.key)
        value_address <= length(ranges) && return ranges[value_address]
    end
    return length(ranges) >= 2 ? ranges[2] : ranges[1]
end

# The v2 diagnostics join: the whole of `derived_diagnostics` again (the
# preamble is shared by construction), with the v2-only contributors —
# StaticLint findings pass through `emit_semantic_finding!` (unresolved
# imports at an analysis boundary become `analysis_boundary` notices), the
# lowering producer takes over `LOWERING_TAKEOVER_RULES`, v2 findings are
# joined, include notices route by their rule id, project/manifest problems
# and located environment errors are emitted.
Salsa.@derived function derived_diagnostics_v2(rt, uri)
    @debug "derived_diagnostics_v2" uri=uri

    # Indirect files participate in the include graph (so cross-file
    # resolution works) but never report diagnostics — they are not files
    # the user explicitly asked the LS to track.
    if derived_is_indirect_file(rt, uri)
        return Diagnostic[]
    end

    if !(uri in derived_text_files(rt))
        error("Invalid uri $uri")
    end

    lint_config = derived_effective_lint_config(rt, uri)

    results = Diagnostic[]

    # A config file validates itself even when its own globs exclude the
    # directory it lives in — otherwise a mistake in `exclude` could hide the
    # very diagnostic that explains it. The exemption covers *self*-exclusion
    # only: a config inside a subtree an enclosing `JuliaLint.toml` excluded is
    # part of code the project deliberately set aside (a vendored repository,
    # typically) and stays silent along with the rest of it.
    is_config_file = uri.scheme == "file" && (
        is_path_lintconfig_file(uri2filepath(uri)) ||
        is_path_formatconfig_file(uri2filepath(uri)) ||
        is_path_testitemsconfig_file(uri2filepath(uri))
    )

    is_self_validating_config = is_config_file &&
        scope_selected(
            strict_ancestor_configs(derived_lintconfig_files(rt), uri), uri2filepath(uri),
            c -> derived_lint_path_filter(rt, c),
        )

    if !lint_config.selected && !is_self_validating_config
        return results
    end

    enabled(rule) = rule_enabled_v2(lint_config, rule)

    # The single point where severity, tags and doc links are applied — every
    # producer path below funnels its findings through `materialize`.
    emit_finding!(f::LintFinding) = begin
        d = materialize_v2(f, lint_config)
        d === nothing || push!(results, d)
        nothing
    end
    emit!(range, rule_id, message, related_uri, source) =
        emit_finding!(LintFinding(range, rule_id, message, related_uri, source))

    # Extension blindness: for an `ext/` file whose extension has no covering
    # environment, an unresolved import OF A TRIGGER is an analysis boundary,
    # not a defect in the code — the linter simply cannot see the weakdep.
    # Silent by default; the opt-in `:analysis_boundary` rule reports it at
    # the import site (the boundaries convention). Computed lazily so files
    # without semantic findings never take these edges.
    # The same doctrine for a file whose owning environment work item failed
    # terminally (a test-environment child that crashed, an unresolvable
    # scratch env): the imports are then checked against a fallback
    # environment, which says nothing about the code. Every unresolved import
    # in such a file is a boundary notice, not a defect.
    ext_blind_triggers = nothing
    env_failed = nothing
    emit_semantic_finding!(f::LintFinding) = begin
        if f.rule_id === :unresolved_import
            if ext_blind_triggers === nothing
                ext_blind_triggers = derived_extension_blind_triggers(rt, uri)
            end
            trigger_idx = findfirst(t -> occursin("`$t`", f.message), ext_blind_triggers)
            if trigger_idx !== nothing
                emit!(f.range, :analysis_boundary,
                    "The extension trigger `$(ext_blind_triggers[trigger_idx])` is not resolved in any reachable environment; analysis of this extension is degraded.",
                    nothing, f.source)
                return nothing
            end
            env_failed === nothing && (env_failed = derived_file_env_failed(rt, uri))
            if env_failed
                emit!(f.range, :analysis_boundary,
                    "The environment of this file could not be resolved (see the environment_errors diagnostic on its project file), so this import is checked against a fallback environment and not reported.",
                    nothing, f.source)
                return nothing
            end
            # A dependency the project DECLARES whose symbols are not indexed
            # (a stale manifest — `project_file_warnings` reports that on the
            # project file — or a package the indexer could not load) is an
            # environment gap, not a code defect.
            if occursin("is a declared dependency but its symbols could not be indexed", f.message)
                emit!(f.range, :analysis_boundary,
                    replace(f.message, " Missing-reference checks are disabled in this scope and all nested scopes." => "",
                            " Anything imported through this statement is assumed to exist and will not be checked." => "") *
                    " Analysis of what it provides is degraded.",
                    nothing, f.source)
                return nothing
            end
        end
        emit_finding!(f)
    end

    # Julia-content diagnostics run for file-scheme .jl files AND non-file
    # (e.g. untitled) buffers whose language is julia.
    if _is_julia_uri(rt, uri)
        # The `enabled` guards below do not filter (materialize does); they skip
        # running a producer query at all when nothing it can emit is on.
        if enabled(:syntax_errors) || enabled(:syntax_warnings)
            for i in derived_julia_syntax_diagnostics(rt, uri)
                rule = i.severity == :error ? :syntax_errors : :syntax_warnings
                emit!(i.range, rule, i.message, i.uri, i.source)
            end
        end

        if enabled(:testitem_errors)
            for i in derived_testitems(rt, uri).testerrors
                emit!(i.range, :testitem_errors, i.message, nothing, "Testitem")
            end
        end

        # This only skips the semantic pass entirely when every rule it can
        # emit is off. `include_errors` is excluded from the test — its
        # findings come from the separate structural pass below, so leaving it
        # on is no reason to run the (much more expensive) semantic one.
        if any(enabled(r.id) for r in LINT_RULES_V2 if !isempty(r.codes) && r.id !== :include_errors)
            env_ready = derived_file_env_ready(rt, uri)
            # Experiment flag: when the lowering-backed producer is active it
            # takes over these rule ids, so StaticLint's findings for them are
            # suppressed here (no double-reporting; same ids, different engine).
            lowering_takeover = derived_lowering_lint_active(rt, uri)
            for f in derived_new_static_lint_diagnostics_v2(rt, uri)
                if !env_ready && _is_env_dependent_finding_v2(f)
                    continue
                end
                if lowering_takeover && f.rule_id in LOWERING_TAKEOVER_RULES
                    continue
                end
                emit_semantic_finding!(f)
            end
        end

        # Purely syntactic rules (tier `TierSyntax`, see lint_syntax_rules/)
        # run on the JuliaSyntax tree alone.
        foreach(emit_finding!, derived_syntax_lint_findings(rt, uri))

        # unbound_type_parameter (Aqua parity) is syntax-tier but v2-only, so
        # it is not in the shared `SYNTAX_CHECKS` tuple; its own producer runs
        # here (lint_unbound_type_parameter_v2.jl).
        if enabled(:unbound_type_parameter)
            foreach(emit_finding!, derived_unbound_type_parameter_findings(rt, uri))
        end

        # Lowering-backed rules from the v2 framework (experiment, behind
        # `input_v2_enabled`; see v2/lint_lowering_rules.jl). Empty unless
        # the flag is on and a takeover rule is enabled. Env-dependent rule ids
        # get the same not-ready suppression the StaticLint loop applies above
        # — checked lazily so a file with no env-dependent finding never takes
        # the `derived_file_env_ready` edge through this path.
        v2_findings = derived_semantic_lint_findings(rt, uri)
        if !isempty(v2_findings)
            v2_env_suppress = any(f -> f.rule_id in ENV_DEPENDENT_LINT_RULES_V2, v2_findings) &&
                !derived_file_env_ready(rt, uri)
            for f in v2_findings
                v2_env_suppress && f.rule_id in ENV_DEPENDENT_LINT_RULES_V2 && continue
                emit_semantic_finding!(f)
            end
        end

        # Include-graph diagnostics (DuplicateInclude / IncludeLoop /
        # MissingFile) are a purely structural analysis that does not depend on
        # a project/environment, so they are reported independently of the
        # semantic static-lint pass above.
        # ComputedInclude / RuntimeInclude are analysis-boundary notices and
        # carry that rule id on the diagnostic; the rest stay include_errors.
        if enabled(:include_errors) || enabled(:analysis_boundary)
            for d in derived_include_diagnostics_v2(rt, uri)
                rule = d.code === nothing ? :include_errors : d.code
                enabled(rule) && emit!(d.range, rule, d.message, d.uri, d.source)
            end
        end

        # Undocumented public names of the workspace packages this file's
        # statements belong to (Aqua parity; layer_undocumented_names_v2.jl).
        if enabled(:undocumented_public_name)
            for (range, message) in collect_undocumented_public_findings(rt, uri)
                emit!(range, :undocumented_public_name, message, nothing, "JuliaWorkspaces.jl")
            end
        end
    end

    # Config/TOML diagnostics are filesystem-file only.
    if uri.scheme == "file"
        if (is_config_file || is_path_project_file(uri2filepath(uri)) || is_path_manifest_file(uri2filepath(uri))) && enabled(:toml_syntax_errors)
            for d in derived_toml_syntax_diagnostics(rt, uri)
                emit!(d.range, :toml_syntax_errors, d.message, d.uri, d.source)
            end
        end

        # Semantic problems of the project/manifest file itself, located at the
        # offending key or value via the TOML item walk. Each problem carries
        # its rule id (`materialize` filters disabled ones; the `enabled` guard
        # only skips running the producers when all of them are off).
        if is_path_project_file(uri2filepath(uri)) &&
                (enabled(:project_file_errors) || enabled(:project_file_warnings))
            for p in Iterators.flatten((
                derived_project_file_problems(rt, uri),
                derived_project_semantic_problems(rt, uri),
            ))
                emit!(_toml_range_for_key_path(rt, uri, p.key_path, p.at), p.code, p.message, nothing, "JuliaWorkspaces.jl")
            end
        end

        # Package-quality findings on the project file (Aqua.jl parity). The
        # producers are config-independent; the rule options filter here. A
        # `missing_compat` finding's section is its key path's first segment.
        if is_path_project_file(uri2filepath(uri)) && enabled(:missing_compat)
            check_julia = rule_option(lint_config, :missing_compat, :check_julia, true)
            check_extras = rule_option(lint_config, :missing_compat, :check_extras, true)
            check_weakdeps = rule_option(lint_config, :missing_compat, :check_weakdeps, true)
            ignore = rule_option(lint_config, :missing_compat, :ignore, String[])
            for p in derived_missing_compat_problems(rt, uri)
                section = p.key_path[1]
                section == "compat" && !check_julia && continue
                section == "extras" && !check_extras && continue
                section == "weakdeps" && !check_weakdeps && continue
                length(p.key_path) >= 2 && p.key_path[2] in ignore && continue
                emit!(_toml_range_for_key_path(rt, uri, p.key_path, p.at), :missing_compat, p.message, nothing, "JuliaWorkspaces.jl")
            end
        end

        if is_path_project_file(uri2filepath(uri)) && enabled(:unused_dependency)
            ignore = rule_option(lint_config, :unused_dependency, :ignore, String[])
            for p in derived_unused_dependency_problems(rt, uri)
                length(p.key_path) >= 2 && p.key_path[2] in ignore && continue
                emit!(_toml_range_for_key_path(rt, uri, p.key_path, p.at), :unused_dependency, p.message, nothing, "JuliaWorkspaces.jl")
            end
        end

        if is_path_manifest_file(uri2filepath(uri)) && enabled(:manifest_errors)
            for p in derived_manifest_file_problems(rt, uri)
                emit!(_toml_range_for_key_path(rt, uri, p.key_path, p.at), p.code, p.message, nothing, "JuliaWorkspaces.jl")
            end
        end

        # Environment-resolution failures are reported on the project file of
        # the environment they were about — the closest file the user can act
        # on — pointing at the offending `[deps]`/`[sources]` entry when the
        # failure message names one.
        if is_path_project_file(uri2filepath(uri)) && enabled(:environment_errors)
            env_error_messages = derived_environment_error_messages_v2(rt, uri)
            env_error_pf = isempty(env_error_messages) ? nothing : derived_project_file(rt, uri)
            for message in env_error_messages
                emit!(_environment_error_range(rt, uri, env_error_pf, message),
                    :environment_errors, message, nothing, "JuliaWorkspaces.jl")
            end
        end

        if is_config_file
            config_diags = if is_path_lintconfig_file(uri2filepath(uri))
                derived_lintconfig_diagnostics(rt, uri)
            elseif is_path_formatconfig_file(uri2filepath(uri))
                derived_formatconfig_diagnostics(rt, uri)
            else
                derived_testitemsconfig_diagnostics(rt, uri)
            end

            # Validators emit more than one kind of finding (a schema mistake is
            # `config_errors`, a config that supersedes an outer one is
            # `shadowed_config`), so each keeps its own rule id and takes that
            # rule's configured severity rather than being flattened together.
            for d in config_diags
                emit!(d.range, d.code === nothing ? :config_errors : d.code, d.message, d.uri, d.source)
            end
        end
    end

    return results
end
