module SymbolServer

# !in("@stdlib", LOAD_PATH) && push!(LOAD_PATH, "@stdlib") # Make sure we can load stdlibs

start_time = time_ns()

using Pkg, SHA
using Base: UUID

# this is required to get parsedoc to work on Julia 1.11 and newer, since the implementation
# moved there
using REPL

include("../../../shared/symbolserver/faketypes.jl")
include("../../../shared/symbolserver/symbols.jl")
include("../../../shared/symbolserver/utils.jl")
include("../../../shared/symbolserver/serialize.jl")
using .CacheStore

# Add some methods to check whether a package is part of the standard library and so
# won't need recaching.
@static if isdefined(Pkg.Types, :is_stdlib)
    is_stdlib(uuid::UUID) = Pkg.Types.is_stdlib(uuid)
else
    is_stdlib(uuid::UUID) = uuid in keys(ctx.stdlibs)
end

# `progress_callback` is either `nothing` or a function taking
# `(message::String, percentage::Union{Int,Missing})`, where `missing` marks a
# report without a meaningful completion percentage.
function get_store(store_path::String, progress_callback)
    loading_bay = Module(:LoadingBay)

    ctx = try
        Pkg.Types.Context()
    catch err
        @info "Package environment can't be read."
        exit()
    end
    
    server = Server(store_path, ctx, Dict{UUID,Package}())

    written_caches = String[] # List of caches that have already been written
    toplevel_pkgs = deps(project(ctx)) # First get a list of all package UUIds that we want to cache
    packages_to_load = []

    # Obtain the directory containing the active Manifest.toml. Any 'develop'ed dependencies
    # will contain a path that is relative to this directory.
    manifest_dir = dirname(ctx.env.manifest_file)

    # Next make sure the cache is up-to-date for all of these.
    for (pk_name, uuid) in toplevel_pkgs
        uuid isa UUID || (uuid = UUID(uuid))
        if !isinmanifest(ctx, uuid)
            @info "$pk_name not in manifest, skipping."
            continue
        end
        pe = frommanifest(manifest(ctx), uuid)
        cache_path = joinpath(server.storedir, SymbolServer.get_cache_path(manifest(ctx), uuid)...)

        if isfile(cache_path)
            if is_package_deved(manifest(ctx), uuid)
                try
                    cached_version = open(cache_path) do io
                        CacheStore.read(io)
                    end
                    if sha_pkg(manifest_dir, frommanifest(manifest(ctx), uuid)) != cached_version.sha
                        @info "Outdated sha, will recache package $pk_name ($uuid)"
                        push!(packages_to_load, uuid)
                    else
                        @info "Package $pk_name ($uuid) is cached."
                    end
                catch err
                    if err isa CacheStore.CacheCorruptedError
                        @info "Couldn't load $pk_name ($uuid) from corrupt cache, will recache."
                        push!(packages_to_load, uuid)
                    else
                        rethrow()
                    end
                end
            else
                @info "Package $pk_name ($uuid) is cached."
            end
        else
            @info "Will cache package $pk_name ($uuid)"
            push!(packages_to_load, uuid)
        end
    end

    # Stamp the world before loading packages, so cache_new_methods! below can
    # find methods they add to functions defined elsewhere.
    world_before = Base.get_world_counter()

    # Load all packages together
    # This is important, or methods added to functions in other packages that are loaded earlier would not be in the cache
    n_to_load = length(packages_to_load)
    # Progress is reported on a step grid covering the whole pipeline: one step
    # per package to load, plus symbol extraction and cache writing. Each report
    # claims the middle of the step it is starting, so percentages rise strictly
    # from the first report on — LSP clients are allowed to ignore reports whose
    # percentage doesn't rise, so a 0% first report would never be displayed.
    n_steps = n_to_load + 2
    step_pct(step) = round(Int, 100 * (step - 0.5) / n_steps)
    n_to_load > 0 && @info "Indexing $n_to_load package(s)."
    for (i, uuid) in enumerate(packages_to_load)
        pe_name = packagename(ctx, uuid)
        @info "Loading package $pe_name ($i/$n_to_load)."
        progress_callback === nothing || progress_callback("Indexing $pe_name ($i/$n_to_load)...", step_pct(i))
        t_load = time()
        load_package(ctx, uuid, nothing, loading_bay)
        @info "Loaded package $pe_name in $(round(time() - t_load, digits=1)) seconds."
    end

    # Create image of whole package env. This creates the module structure only.
    @info "Extracting symbols from loaded packages."
    progress_callback === nothing || progress_callback("Extracting symbols from loaded packages...", step_pct(n_to_load + 1))
    env_symbols = getenvtree()

    # Populate the above with symbols, skipping modules that don't need caching.
    # symbols (env_symbols)
    visited = Base.IdSet{Module}([Base, Core])

    for (pid, m) in Base.loaded_modules
        if pid.uuid !== nothing && is_stdlib(pid.uuid) &&
            isinmanifest(ctx, pid.uuid) &&
            isfile(joinpath(server.storedir, SymbolServer.get_cache_path(manifest(ctx), pid.uuid)...))
            push!(visited, m)
            delete!(env_symbols, Symbol(pid.name))
        end
    end

    symbols(env_symbols, nothing, getallns(), visited)

    # Pick up overloads of foreign functions (e.g. Base.show) added without importing the name.
    cache_new_methods!(env_symbols, world_before; get_return_type=false)

    # Wrap the `ModuleStore`s as `Package`s.
    for (pkg_name, cache) in env_symbols
        !isinmanifest(ctx, String(pkg_name)) && continue
        uuid = packageuuid(ctx, String(pkg_name))
        pe = frommanifest(ctx, uuid)
        server.depot[uuid] = Package(String(pkg_name), cache, uuid, sha_pkg(manifest_dir, pe))
    end

    progress_callback === nothing || progress_callback("Writing symbol caches to disc...", step_pct(n_to_load + 2))
    write_depot(server, server.context, written_caches)

    @info "Symbol server indexing took $((time_ns() - start_time) / 1e9) seconds."
end

end
