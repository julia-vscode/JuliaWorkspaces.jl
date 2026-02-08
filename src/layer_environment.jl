Salsa.@derived function derived_environment(rt, uri)
    project = derived_project(rt, uri)
    
    metadata_packages = SymbolServer.ModuleStore[]
    for i in project.regular_packages
        x = input_package_metadata(rt, i.name, i.uuid, i.version, i.git_tree_sha1)
        push!(metadata_packages, x)
    end

    new_store = recursive_copy(stdlibs)

    for i in metadata_packages
        new_store[i.name.name] = i.val
    end    

    return StaticLint.ExternalEnv(new_store, SymbolServer.collect_extended_methods(new_store), collect(keys(new_store)))
end
