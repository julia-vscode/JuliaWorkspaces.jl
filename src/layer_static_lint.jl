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
    @debug "derived_deved_package_meta" pkg_entry_uri=pkg_entry_uri project_uri=project_uri

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

    StaticLint.semantic_pass(pkg_entry_uri, cst, env, meta_dict, include_dict, rt)

    # Extract the package name from the URI (src/PackageName.jl -> PackageName)
    pkg_filename = basename(uri2filepath(pkg_entry_uri))
    pkg_name = pkg_filename[1:end-3]  # strip ".jl"

    mod_binding = find_module_binding(cst, pkg_name, meta_dict)

    return (meta_dict=meta_dict, module_binding=mod_binding)
end

Salsa.@derived function derived_static_lint_meta_for_root(rt, uri)
    @debug "derived_static_lint_meta_for_root" uri=uri

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

    # When no project URI is available yet (e.g. while a standalone package's
    # DJP is still computing its project), fall back to a stdlib-only env so
    # that hover, completions, and env-independent `check_all` passes still
    # work for locally-defined symbols and stdlib names. Workspace-package
    # discovery is skipped (it requires a real project), but test-setup
    # discovery and the `check_all` loop still run.
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

    # Pre-compute test setup bindings (@testmodule/@testsnippet) for the enclosing package
    test_setups = Dict{Symbol, StaticLint.TestSetupInfo}()
    self_package_name = nothing
    package_folder_uri = derived_package_for_file(rt, uri)
    if package_folder_uri !== nothing
        test_setups = derived_test_setup_bindings(rt, package_folder_uri)

        # Determine the self-package name and ensure it's in workspace_packages
        # so @testitem blocks can resolve `using PackageName` and bare references.
        pkg = derived_package(rt, package_folder_uri)
        if pkg !== nothing
            self_package_name = pkg.name
            if project_uri !== nothing && !haskey(workspace_packages, self_package_name)
                entry_uri = filepath2uri(joinpath(uri2filepath(package_folder_uri), "src", "$(self_package_name).jl"))
                if derived_has_file(rt, entry_uri) && entry_uri != uri
                    result = derived_deved_package_meta(rt, entry_uri, project_uri)
                    merge_meta_dict!(meta_dict, result.meta_dict)
                    if result.module_binding !== nothing
                        workspace_packages[self_package_name] = result.module_binding
                    end
                end
            end
        end
    end

    StaticLint.semantic_pass(uri, cst, env, meta_dict, include_dict, rt; workspace_packages, test_setups, self_package_name)

    for file in julia_files
        cst2 = derived_julia_legacy_syntax_tree(rt, file)

        lint_config = derived_lint_configuration(rt, file)
        opts = _lint_options_from_config(lint_config)
        StaticLint.check_all(cst2, opts, env, meta_dict)

        # Late getfield reference resolution. This mutates meta_dict, so it must
        # run here (while we still own meta_dict) rather than from the read-only
        # diagnostics pass in `collect_hints`.
        StaticLint.resolve_remaining_getfields!(cst2, env, workspace_packages, meta_dict)
    end

    return (meta_dict=meta_dict, workspace_packages=workspace_packages)
end

Salsa.@derived function derived_static_lint_all_diagnostics(rt)
    @debug "derived_static_lint_all_diagnostics"

    # We use a Set to deduplicate diagnostics, as the same diagnostic
    # can be produced from multiple roots due to includes
    res = Dict{URI,Set{Diagnostic}}()

    roots = derived_roots(rt)
    for root in roots
        project_uri = derived_project_uri_for_root(rt, root)
        @info "Workspace root" root=root project=project_uri
    end

    for root in roots
        project_uri = derived_project_uri_for_root(rt, root)
        project_uri === nothing && continue

        lint_result = derived_static_lint_meta_for_root(rt, root)
        meta_dict = lint_result.meta_dict
        workspace_packages = lint_result.workspace_packages
        env = derived_environment(rt, project_uri)

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
            lint_config = derived_lint_configuration(rt, uri)
            missingrefs = _missingrefs_from_config(lint_config)
            errs = StaticLint.collect_hints(cst, env, workspace_packages, meta_dict, missingrefs)

            for err in errs
                rng = err[1]+1:err[1]+err[2].span+1
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

    return get(all_diags, uri, Set{Diagnostic}())
end

# ───────────────────────────────────────────────────────────────────
# Test setup pre-computation (@testmodule / @testsnippet)
# ───────────────────────────────────────────────────────────────────

"""
    _find_test_macros_in_cst(cst)

Walk a file-level CST and collect `@testmodule` and `@testsnippet` macrocall
EXPR nodes.  Returns `(modules, snippets)` where each is a vector of EXPR.
"""
function _find_test_macros_in_cst(cst)
    modules = CSTParser.EXPR[]
    snippets = CSTParser.EXPR[]
    cst.args === nothing && return (modules, snippets)
    for arg in cst.args
        if CSTParser.ismacrocall(arg) && arg.args !== nothing && length(arg.args) >= 1
            macro_name_expr = arg.args[1]
            if CSTParser.isidentifier(macro_name_expr)
                name = CSTParser.valof(macro_name_expr)
                if name == "@testmodule"
                    push!(modules, arg)
                elseif name == "@testsnippet"
                    push!(snippets, arg)
                end
            end
        end
    end
    return (modules, snippets)
end

"""
    _get_body_block(x::CSTParser.EXPR)

Find the `begin...end` block in a macrocall EXPR. Returns `nothing` if not found.
"""
function _get_body_block(x::CSTParser.EXPR)
    x.args === nothing && return nothing
    for i in 2:length(x.args)
        arg = x.args[i]
        if arg isa CSTParser.EXPR && CSTParser.headof(arg) === :block
            return arg
        end
    end
    return nothing
end

"""
    _collect_body_exprs(body::CSTParser.EXPR)

Collect the child EXPR nodes of a `:block` expression (the body of a macro).
Returns a `Vector{CSTParser.EXPR}` of the individual statements.
"""
function _collect_body_exprs(body::CSTParser.EXPR)
    exprs = CSTParser.EXPR[]
    body.args === nothing && return exprs
    for arg in body.args
        push!(exprs, arg)
    end
    return exprs
end

"""
    derived_test_setup_bindings(rt, package_folder_uri)

Pre-compute `TestSetupInfo` for all `@testmodule` and `@testsnippet`
declarations across all files in a package. Returns
`Dict{Symbol, StaticLint.TestSetupInfo}`.

For `@testmodule`: runs a lightweight semantic analysis on the module body
to produce a `Scope` and `Binding`.

For `@testsnippet`: stores the body EXPR nodes for later inline processing.
No semantic analysis is run — the snippet will be analyzed in-context when
inlined into each `@testitem`.
"""
Salsa.@derived function derived_test_setup_bindings(rt, package_folder_uri)
    @debug "derived_test_setup_bindings" package_folder_uri=package_folder_uri

    result = Dict{Symbol, StaticLint.TestSetupInfo}()

    # Collect all files in this package
    all_files = derived_all_julia_files(rt)

    package_folder_path = lowercase(uri2filepath(package_folder_uri))

    for uri in all_files
        file_path = lowercase(uri2filepath(uri))
        # Only scan files that belong to this package
        startswith(file_path, package_folder_path) || continue

        cst = derived_julia_legacy_syntax_tree(rt, uri)
        modules, snippets = _find_test_macros_in_cst(cst)

        # Process @testmodule declarations
        for mod_expr in modules
            mod_expr.args === nothing && continue
            length(mod_expr.args) < 3 && continue
            name_expr = mod_expr.args[2]
            CSTParser.isidentifier(name_expr) || continue
            mod_name = Symbol(CSTParser.valof(name_expr))

            body = _get_body_block(mod_expr)
            body === nothing && continue

            # Create a scope for the module and run a lightweight semantic pass
            meta_dict = Dict{UInt64, StaticLint.Meta}()
            StaticLint.ensuremeta(cst, meta_dict)
            StaticLint.ensuremeta(mod_expr, meta_dict)

            mod_scope = StaticLint.Scope(nothing, mod_expr, Dict{String,StaticLint.Binding}(), Dict{Symbol,Any}(), nothing)

            # Get the environment for this file to populate Base/Core in the module scope
            project_uri = derived_project_uri_for_root(rt, uri)
            if project_uri !== nothing
                env = derived_environment(rt, project_uri)
                mod_scope.modules = Dict{Symbol,Any}()
                mod_scope.modules[:Base] = env.symbols[:Base]
                mod_scope.modules[:Core] = env.symbols[:Core]
            end

            binding = StaticLint.Binding(name_expr, mod_expr, nothing, CSTParser.EXPR[], true)
            StaticLint.setscope!(mod_expr, mod_scope, meta_dict)

            result[mod_name] = StaticLint.TestSetupInfo(:module, binding, nothing, mod_scope)
        end

        # Process @testsnippet declarations
        for snip_expr in snippets
            snip_expr.args === nothing && continue
            length(snip_expr.args) < 3 && continue
            name_expr = snip_expr.args[2]
            CSTParser.isidentifier(name_expr) || continue
            snip_name = Symbol(CSTParser.valof(name_expr))

            body = _get_body_block(snip_expr)
            body === nothing && continue

            body_exprs = _collect_body_exprs(body)
            result[snip_name] = StaticLint.TestSetupInfo(:snippet, nothing, body_exprs, nothing)
        end
    end

    return result
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
