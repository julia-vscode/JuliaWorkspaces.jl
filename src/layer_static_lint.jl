function StaticLint.hasfile(rt, path)
    return derived_has_file(rt, filepath2uri(path))
end

"""
    merge_meta_dict!(target, source)

Merge `source` meta_dict entries into `target`, shallow-copying `Binding.refs`
to prevent cross-root mutation when multiple roots share the same cached
deved package meta.
"""
function merge_meta_dict!(target::Dict{UInt64,StaticLint.Meta}, source::Dict{UInt64,StaticLint.Meta})
    for (k, meta) in source
        if meta.binding !== nothing
            # Shallow-copy refs to isolate per-root mutations from _mark_import_arg's push!(par.refs, arg)
            copied_binding = StaticLint.Binding(meta.binding.name, meta.binding.val, meta.binding.type, copy(meta.binding.refs), meta.binding.is_public)
            target[k] = StaticLint.Meta(copied_binding, meta.scope, meta.ref, meta.error)
        else
            target[k] = meta
        end
    end
end

"""
    find_module_binding(cst, name, meta_dict)

Find the `Binding` for a top-level `module` definition named `name` in the given CST.
"""
function find_module_binding(cst, name::String, meta_dict::Dict{UInt64,StaticLint.Meta})
    if cst.args !== nothing
        for arg in cst.args
            if CSTParser.defines_module(arg) && StaticLint.hasbinding(arg, meta_dict)
                mod_name = CSTParser.get_name(arg)
                # str_value also covers var"..." module names, where valof is nothing
                if CSTParser.isidentifier(mod_name) && CSTParser.str_value(mod_name) == name
                    return StaticLint.bindingof(arg, meta_dict)
                end
            end
        end
    end
    return nothing
end

Salsa.@derived function derived_deved_package_meta(rt, pkg_entry_uri, project_uri)
    @debug "derived_deved_package_meta" pkg_entry_uri=pkg_entry_uri project_uri=project_uri

    env = derived_environment(rt, project_uri)

    # Build meta_dict scoped to the entry file's include closure — the files the
    # semantic pass can actually traverse.
    meta_dict = Dict{UInt64,StaticLint.Meta}()
    for uri in derived_include_closure(rt, pkg_entry_uri)
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        StaticLint.ensuremeta(cst, meta_dict)
    end

    cst = derived_julia_legacy_syntax_tree(rt, pkg_entry_uri)

    StaticLint.semantic_pass(pkg_entry_uri, cst, env, meta_dict, rt)

    # Extract the package name from the URI (src/PackageName.jl -> PackageName)
    pkg_filename = basename(uri2filepath(pkg_entry_uri))
    pkg_name = pkg_filename[1:end-3]  # strip ".jl"

    mod_binding = find_module_binding(cst, pkg_name, meta_dict)

    return (meta_dict=meta_dict, module_binding=mod_binding)
end

Salsa.@derived function derived_static_lint_meta_for_root(rt, uri)
    @debug "derived_static_lint_meta_for_root" uri=uri

    meta_dict = Dict{UInt64,StaticLint.Meta}()

    # Scope all per-file work to the root's include closure: those are the files
    # the semantic pass can traverse and the only ones whose meta is ever read
    # for this root (the diagnostics pass walks the same closure). This keeps
    # edits outside the closure from invalidating this root's lint state.
    closure = derived_include_closure(rt, uri)

    for closure_uri in closure
        cst = derived_julia_legacy_syntax_tree(rt, closure_uri)
        StaticLint.ensuremeta(cst, meta_dict)
    end

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    # TODO Replace this with proper logic, but for now this should be not too bad.
    project_uri = derived_project_uri_for_root(rt, uri)

    # When no project URI is available yet (e.g. while a standalone package's
    # DJP is still computing its project), fall back to a stdlib-only env so
    # that hover, completions, and env-independent `check_all` passes still
    # work for locally-defined symbols and stdlib names. Workspace-package
    # discovery is skipped (it requires a real project), but the `check_all` loop still runs.
    if project_uri === nothing
        # Use the Salsa-memoized stdlib-only env so that every consumer observes
        # the *same* env object. This matters because `SymbolServer` stores
        # (FunctionStore/DataTypeStore) compare by identity, so refs resolved
        # during the pass must point at the same env instance that later
        # read-only queries retrieve.
        env = derived_stdlib_only_env(rt)
    else
        env = derived_environment(rt, project_uri)
    end

    # Build workspace_packages dict from cached deved package semantic info
    workspace_packages = Dict{String,Any}()
    if project_uri !== nothing
        workspace_deved = derived_workspace_deved_packages(rt, project_uri)
        for (pkg_name, pkg_entry_uri) in workspace_deved
            # Skip when the root IS the deved package — semantic_pass will process
            # these CST nodes directly, and merging stale meta would cause
            # resolve_ref to short-circuit (hasref→true) before new bindings are
            # added, resulting in false "unused binding" warnings.
            pkg_entry_uri == uri && continue

            result = derived_deved_package_meta(rt, pkg_entry_uri, project_uri)
            merge_meta_dict!(meta_dict, result.meta_dict)
            if result.module_binding !== nothing
                workspace_packages[pkg_name] = result.module_binding
            end
        end
    end

    StaticLint.semantic_pass(uri, cst, env, meta_dict, rt; workspace_packages)

    for file in closure
        cst2 = derived_julia_legacy_syntax_tree(rt, file)

        lint_config = derived_effective_lint_config(rt, file)
        opts = lint_options_from_config(lint_config)
        StaticLint.check_all(cst2, opts, env, meta_dict)

        # Late getfield reference resolution. This mutates meta_dict, so it must
        # run here (while we still own meta_dict) rather than from the read-only
        # diagnostics pass in `collect_hints`.
        StaticLint.resolve_remaining_getfields!(cst2, env, workspace_packages, meta_dict)

        # Late import-failure marking. Runs here (not in-pass) because
        # resolve_import failures may be retried via state.resolveonly.
        StaticLint.mark_unresolved_imports!(cst2, env, meta_dict)
    end

    return (meta_dict=meta_dict, workspace_packages=workspace_packages)
end

"""
    derived_static_lint_diagnostics_for_root(rt, root)

Static-lint diagnostics for every file in `root`'s include closure, keyed by
file URI. Keyed per root so an edit only recomputes diagnostics for the roots
whose closure contains the edited file. Iterating the closure (which carries a
visited set) also makes include cycles inside a project terminate.
"""
Salsa.@derived function derived_static_lint_diagnostics_for_root(rt, root)
    @debug "derived_static_lint_diagnostics_for_root" root=root

    # We use a Set to deduplicate diagnostics, as the same diagnostic
    # can be produced from multiple roots due to includes
    res = Dict{URI,Set{Diagnostic}}()

    project_uri = derived_project_uri_for_root(rt, root)
    project_uri === nothing && return res

    lint_result = derived_static_lint_meta_for_root(rt, root)
    meta_dict = lint_result.meta_dict
    workspace_packages = lint_result.workspace_packages
    env = derived_environment(rt, project_uri)

    # Names the project declares as dependencies. An unresolved import of one of
    # these is a dependency whose symbols could not be indexed/cached (it would
    # otherwise be in the env and resolve), as opposed to a name that simply
    # isn't in the environment (typo / missing dependency).
    project = derived_project(rt, project_uri)
    declared_deps = project === nothing ? Set{String}() :
        Set{String}(Iterators.flatten((
            keys(project.regular_packages),
            keys(project.stdlib_packages),
            keys(project.deved_packages),
        )))

    for uri in derived_include_closure(rt, root)
        current_res = get!(res, uri, Set{Diagnostic}())

        cst = derived_julia_legacy_syntax_tree(rt, uri)
        lint_config = derived_effective_lint_config(rt, uri)
        missingrefs = missingrefs_from_config(lint_config)
        errs = StaticLint.collect_hints(cst, env, workspace_packages, meta_dict, missingrefs)

        _emit_hint_diagnostics!(
            current_res, errs, meta_dict, lint_config, declared_deps;
            describe_call = x -> StaticLint.describe_call_mismatch(x, env, meta_dict),
        )
    end

    return res
end

Salsa.@derived function derived_static_lint_diagnostics(rt, uri)
    # The same diagnostic can be produced from multiple roots due to includes;
    # the Set deduplicates across roots.
    res = Set{Diagnostic}()

    for root in derived_roots_for_uri(rt, uri)
        root_diags = derived_static_lint_diagnostics_for_root(rt, root)
        uri_diags = get(root_diags, uri, nothing)
        uri_diags === nothing || union!(res, uri_diags)
    end

    return res
end

"""
    derived_expr_uri_map(rt)

Build a mapping from `objectid(root_cst)` → `URI` for every Julia file in the
workspace. This allows resolving which file owns a given EXPR by walking
`parent` pointers up to the file-root node and looking up its `objectid`.

Salsa-memoized: invalidated when any file's CST changes (which also changes
its `objectid`).
"""
Salsa.@derived function derived_expr_uri_map(rt)
    result = Dict{UInt64,URI}()
    for uri in derived_all_julia_files(rt)
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        result[objectid(cst)] = uri
    end
    return result
end
