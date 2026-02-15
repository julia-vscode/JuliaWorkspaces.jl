Salsa.@derived function derived_environment(rt, uri)
    project = derived_project(rt, uri)
    
    metadata_packages = SymbolServer.Package[]
    for (k,v) in project.regular_packages
        x = input_package_metadata(rt, Symbol(v.name), v.uuid, parse(VersionNumber, v.version), v.git_tree_sha1)
        if x!==nothing
            push!(metadata_packages, x)
        end
    end

    new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)

    for i in metadata_packages
        new_store[Symbol(i.name)] = i.val
    end    

    return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), collect(keys(new_store)))
end

Salsa.@derived function derived_project_uri_for_root(rt, uri)
    # TODO This needs to handle multi env
    return input_active_project(rt)
end
