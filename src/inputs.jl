Salsa.@declare_input input_files(rt)::Set{URI}

Salsa.@declare_input input_text_file(rt, uri)::Union{TextFile,Nothing}

Salsa.@declare_input input_active_project(rt)::Union{URI,Nothing}

Salsa.@declare_input input_notebook_file(rt, uri)::NotebookFile
Salsa.@declare_input input_fallback_test_project(rt)::Union{URI,Nothing}
Salsa.@declare_input input_project_environment(rt, uri)::StaticLint.ExternalEnv function(ctx, uri)

    @info "Lazy load for" uri
    new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)

    if ctx.dynamic_feature !== nothing
        SymbolServer.load_project_packages_into_store!(ctx.dynamic_feature.store_path, ctx.dynamic_feature.depot_path, uri2filepath(uri), new_store, nothing)

        put!(
            ctx.dynamic_feature.in_channel,
            (
                command = :watch_environment,
                project_path = uri2filepath(uri)
            )
        )
    end

    return StaticLint.ExternalEnv(
        new_store,
        SymbolServer.collect_extended_methods(new_store),
        collect(keys(new_store)))
end

Salsa.@declare_input input_package_metadata(rt, pe_name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::String)::SymbolServer.ModuleStore function(ctx, name, uuid, version, git_tree_sha1)
    @info "Lazy load package metadata for" name uuid version git_tree_sha1

    if ctx.dynamic_feature !== nothing
        cache_path = joinpath(ctx.dynamic_feature.store_path, uppercase(string(name)[1]), string(name, "_", uuid), string("v", ver, "_", git_tree_sha1, ".jstore"))

        if isfile(cache_path)
            package_data = open(cache_path) do io
                SymbolServer.CacheStore.read(io)
            end

            pkg_path = Base.locate_package(Base.PkgId(uuid, pe_name))

            # TODO Reenable this
            # if pkg_path === nothing || !isfile(pkg_path)
            #     pkg_path = SymbolServer.get_pkg_path(Base.PkgId(uuid, pe_name), environment_path, ctx.dynamic_feature.depot_path)
            # end

            if pkg_path !== nothing
                SymbolServer.modify_dirs(package_data.val, f -> modify_dir(f, r"^PLACEHOLDER", joinpath(pkg_path, "src")))
            end

            return package_data
        end
        # return ModuleStore(VarRef(nothing, Symbol(pe_name)), Dict{Symbol,Any}(), "$pe_name could not be indexed.", true, Symbol[], Symbol[])
    end

    return nothing
end

Salsa.@declare_input input_canonical_uri(rt, uri)::URI function(ctx, uri)
    # TODO We need to track this and then update as needed
    path = uri2filepath(uri)
    path2 = realpath(path)
    return filepath2uri(path2)
end
