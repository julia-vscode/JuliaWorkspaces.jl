function StaticLint.hasfile(rt, path)
    return derived_has_file(rt, filepath2uri(path))
end

Salsa.@derived function derived_external_env(rt, uri)
    return StaticLint.ExternalEnv(Dict{Symbol,SymbolServer.ModuleStore}(:Base => SymbolServer.stdlibs[:Base], :Core => SymbolServer.stdlibs[:Core]), SymbolServer.collect_extended_methods(SymbolServer.stdlibs), Symbol[])
end

Salsa.@derived function derived_static_lint_meta(rt)
    meta_dict = Dict{UInt64,StaticLint.Meta}()
    root_dict = Dict{URI,URI}()

    julia_files = derived_julia_files(rt)

    for uri in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        StaticLint.ensuremeta(cst, meta_dict)

        StaticLint.getmeta(cst, meta_dict).error = :doc # TODO WHAT IS OUR DOC??
    end

    for uri in julia_files
        root_dict[uri] = uri
    end

    for uri in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, uri)
        env = derived_external_env(rt, uri)

        StaticLint.semantic_pass(uri, cst, env, meta_dict, root_dict, rt)
    end

    for file in julia_files
        cst = derived_julia_legacy_syntax_tree(rt, file)
        env = derived_external_env(rt, file)

        StaticLint.check_all(cst, StaticLint.LintOptions(), env, meta_dict)
    end

    return meta_dict
end

Salsa.@derived function derived_static_lint_diagnostics(rt, uri)

    meta_dict = derived_static_lint_meta(rt)

    cst = derived_julia_legacy_syntax_tree(rt, uri)
    env = derived_external_env(rt, uri)

    # errs = StaticLint.collect_hints(cst, getenv(doc), doc.server.lint_missingrefs)
    errs = StaticLint.collect_hints(cst, env, meta_dict, false)

    res = Diagnostic[]

    for err in errs
        rng = err[1]+1:err[1]+err[2].fullspan+1
        if StaticLint.headof(err[2]) === :errortoken
            # push!(out, Diagnostic(rng, DiagnosticSeverities.Error, missing, missing, "Julia", "Parsing error", missing, missing))
        elseif CSTParser.isidentifier(err[2]) && !StaticLint.haserror(err[2], meta_dict)
            push!(res, Diagnostic(rng, :warning, "Missing reference: $(err[2].val)", nothing, Symbol[], "StaticLint.jl"))
        elseif StaticLint.haserror(err[2], meta_dict) && StaticLint.errorof(err[2], meta_dict) isa StaticLint.LintCodes
            code = StaticLint.errorof(err[2], meta_dict)
            description = get(StaticLint.LintCodeDescriptions, code, "")
            severity, tags = if code in (StaticLint.UnusedFunctionArgument, StaticLint.UnusedBinding, StaticLint.UnusedTypeParameter)
                :hint, Symbol[:Unnecessary]
            else
                :information, Symbol[]
            end
            code_details = code === StaticLint.IndexFromLength ? URI("https://docs.julialang.org/en/v1/base/arrays/#Base.eachindex") : nothing
            # push!(out, Diagnostic(rng, severity, string(code), code_details, "Julia", description, tags, missing))
            push!(res, Diagnostic(rng, severity, description, code_details, tags, "StaticLint.jl"))
        end
    end

    return res
end
