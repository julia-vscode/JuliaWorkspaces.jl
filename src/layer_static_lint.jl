function StaticLint.hasfile(rt, path)
    return derived_has_file(rt, filepath2uri(path))
end

Salsa.@derived function derived_static_lint_meta_for_root(rt, uri)
    meta_dict = Dict{UInt64,StaticLint.Meta}()
    include_dict = derived_include_dict(rt)

    julia_files = derived_all_julia_files(rt)

    for uri in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        StaticLint.ensuremeta(cst, meta_dict)

        StaticLint.getmeta(cst, meta_dict).error = :doc # TODO WHAT IS OUR DOC??
    end

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    # TODO Replace this with proper logic, but for now this should be not too bad.
    project_uri = derived_project_uri_for_root(rt, uri)

    env = derived_environment(rt, project_uri)

    # This will trigger the launch of the dynamic process
    input_project_environment(rt, project_uri)

    StaticLint.semantic_pass(uri, cst, env, meta_dict, include_dict, rt)

    for file in julia_files
        cst2 = derived_julia_legacy_syntax_tree(rt, file)

        StaticLint.check_all(cst2, StaticLint.LintOptions(), env, meta_dict)
    end

    return meta_dict
end

Salsa.@derived function derived_static_lint_all_diagnostics(rt)    
    # We use a Set to deduplicate diagnostics, as the same diagnostic
    # can be produced from multiple roots due to includes
    res = Dict{URI,Set{Diagnostic}}()

    for root in derived_roots(rt)
        meta_dict = derived_static_lint_meta_for_root(rt, root)
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
            errs = StaticLint.collect_hints(cst, env, meta_dict, :id)

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
