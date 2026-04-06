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
                if CSTParser.isidentifier(mod_name) && CSTParser.valof(mod_name) == name
                    return StaticLint.bindingof(arg, meta_dict)
                end
            end
        end
    end
    return nothing
end

Salsa.@derived function derived_deved_package_meta(rt, pkg_entry_uri, project_uri)
    env = derived_environment(rt, project_uri)
    include_dict = derived_include_dict(rt)

    # Build meta_dict scoped to all workspace files (needed for cross-file include resolution)
    meta_dict = Dict{UInt64,StaticLint.Meta}()
    julia_files = derived_all_julia_files(rt)
    for uri in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        StaticLint.ensuremeta(cst, meta_dict)
    end

    cst = derived_julia_legacy_syntax_tree(rt, pkg_entry_uri)

    # Trigger the dynamic process for this environment
    project = derived_project(rt, project_uri)
    input_project_environment(rt, project_uri, project === nothing ? UInt(0) : project.content_hash)

    StaticLint.semantic_pass(pkg_entry_uri, cst, env, meta_dict, include_dict, rt)

    # Extract the package name from the URI (src/PackageName.jl -> PackageName)
    pkg_filename = basename(uri2filepath(pkg_entry_uri))
    pkg_name = pkg_filename[1:end-3]  # strip ".jl"

    mod_binding = find_module_binding(cst, pkg_name, meta_dict)

    return (meta_dict=meta_dict, module_binding=mod_binding)
end

Salsa.@derived function derived_static_lint_meta_for_root(rt, uri)
    meta_dict = Dict{UInt64,StaticLint.Meta}()
    include_dict = derived_include_dict(rt)

    julia_files = derived_all_julia_files(rt)

    for uri in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        StaticLint.ensuremeta(cst, meta_dict)
    end

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    # TODO Replace this with proper logic, but for now this should be not too bad.
    project_uri = derived_project_uri_for_root(rt, uri)

    env = derived_environment(rt, project_uri)

    # This will trigger the launch of the dynamic process
    project_for_hash = derived_project(rt, project_uri)
    input_project_environment(rt, project_uri, project_for_hash === nothing ? UInt(0) : project_for_hash.content_hash)

    # Build workspace_packages dict from cached deved package semantic info
    workspace_packages = Dict{String,Any}()
    workspace_deved = derived_workspace_deved_packages(rt, project_uri)
    for (pkg_name, pkg_entry_uri) in workspace_deved
        result = derived_deved_package_meta(rt, pkg_entry_uri, project_uri)
        merge_meta_dict!(meta_dict, result.meta_dict)
        if result.module_binding !== nothing
            workspace_packages[pkg_name] = result.module_binding
        end
    end

    StaticLint.semantic_pass(uri, cst, env, meta_dict, include_dict, rt; workspace_packages)

    for file in julia_files
        cst2 = derived_julia_legacy_syntax_tree(rt, file)

        StaticLint.check_all(cst2, StaticLint.LintOptions(), env, meta_dict)
    end

    return (meta_dict=meta_dict, workspace_packages=workspace_packages)
end

Salsa.@derived function derived_static_lint_all_diagnostics(rt)
    # We use a Set to deduplicate diagnostics, as the same diagnostic
    # can be produced from multiple roots due to includes
    res = Dict{URI,Set{Diagnostic}}()

    for root in derived_roots(rt)
        lint_result = derived_static_lint_meta_for_root(rt, root)
        meta_dict = lint_result.meta_dict
        workspace_packages = lint_result.workspace_packages
        env = derived_environment(rt, derived_project_uri_for_root(rt, root))

        uris_to_check = Set{URI}([root])
        while !isempty(uris_to_check)
            uri = first(uris_to_check)
            delete!(uris_to_check, uri)

            included_uris = derived_includes(rt, uri)
            for included_uri in included_uris
                push!(uris_to_check, included_uri)
            end

            current_res = get!(res, uri, Set{Diagnostic}())

            cst = derived_julia_legacy_syntax_tree(rt, uri)
            # errs = StaticLint.collect_hints(cst, getenv(doc), doc.server.lint_missingrefs)
            errs = StaticLint.collect_hints(cst, env, workspace_packages, meta_dict, :id)

            for err in errs
                rng = err[1]+1:err[1]+err[2].fullspan+1
                if StaticLint.headof(err[2]) === :errortoken
                    # push!(out, Diagnostic(rng, DiagnosticSeverities.Error, missing, missing, "Julia", "Parsing error", missing, missing))
                elseif CSTParser.isidentifier(err[2]) && !StaticLint.haserror(err[2], meta_dict)
                    push!(current_res, Diagnostic(rng, :warning, "Missing reference: $(err[2].val)", nothing, Symbol[], "StaticLint.jl"))
                elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) isa StaticLint.LintCodes
                    code = StaticLint.errorof(err[2], meta_dict)
                    description = get(StaticLint.LintCodeDescriptions, code, "")
                    severity, tags = if code in (StaticLint.UnusedFunctionArgument, StaticLint.UnusedBinding, StaticLint.UnusedTypeParameter)
                        :hint, Symbol[:unnecessary]
                    else
                        :information, Symbol[]
                    end
                    code_details = code === StaticLint.IndexFromLength ? URI("https://docs.julialang.org/en/v1/base/arrays/#Base.eachindex") : nothing
                    push!(current_res, Diagnostic(rng, severity, description, code_details, tags, "StaticLint.jl"))
                end
            end
        end
    end

    return res
end

Salsa.@derived function derived_static_lint_diagnostics(rt, uri)
    all_diags = derived_static_lint_all_diagnostics(rt)

    return all_diags[uri]
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
