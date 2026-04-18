@enum DynamicMode DynamicOff DynamicIndexingOnly DynamicPersistent

# DJPKey is a tagged sum type identifying a DynamicJuliaProcess.
#
# Each variant carries exactly the fields that are meaningful for that kind of
# process. Producers (`start(df::DynamicFeature)`), the required-set computation
# (`derived_required_dynamic_projects`), and the cleanup path
# (`cleanup_stale_processes!`) all construct/dispatch on these variants
# directly, which makes mismatches between them a type error rather than a
# silent string-sentinel collision.
struct WatchEnvironmentKey
    project_path::String
    content_hash::UInt
end

struct WatchTestEnvironmentKey
    project_path::String
    package_name::String
    content_hash::UInt
end

struct CreateStandaloneProjectKey
    package_path::String
    content_hash::UInt
end

const DJPKey = Union{WatchEnvironmentKey, WatchTestEnvironmentKey, CreateStandaloneProjectKey}

mutable struct DynamicJuliaProcess
    project_path::String
    package::Union{Nothing,String}
    kind::Symbol
    proc::Union{Nothing, Base.Process}
    endpoint::Union{Nothing, JSONRPC.JSONRPCEndpoint}

    function DynamicJuliaProcess(project_path::String, package::Union{Nothing,String}, kind::Symbol)
        return new(
            project_path,
            package,
            kind,
            nothing,
            nothing
        )
    end
end

function index_project(djp::DynamicJuliaProcess, store_path::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.index_project_request_type,
        JuliaDynamicAnalysisProtocol.IndexProjectParams(
            djp.project_path,
            djp.package,
            store_path
        )
    )
end

function create_standalone_project(djp::DynamicJuliaProcess, store_path::String)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.create_standalone_project_request_type,
        JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams(
            djp.project_path,
            store_path
        )
    )
end

function start(djp::DynamicJuliaProcess)
    @info "Starting DynamicJuliaProcess" kind=djp.kind project_path=djp.project_path package=djp.package

    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)

    julia_dynamic_analysis_process_script = joinpath(@__DIR__, "../juliadynamicanalysisprocess/app/julia_dynamic_analysis_process_main.jl")

    pipe_out = Pipe()

    # jlArgs = copy(env.juliaArgs)

    # if env.juliaNumThreads!==missing && env.juliaNumThreads == "auto"
    #     push!(jlArgs, "--threads=auto")
    # end

    # jlEnv = copy(ENV)

    # for (k,v) in pairs(env.env)
    #     if v!==nothing
    #         jlEnv[k] = v
    #     elseif haskey(jlEnv, k)
    #         delete!(jlEnv, k)
    #     end
    # end

    # if env.juliaNumThreads!==missing && env.juliaNumThreads!="auto" && env.juliaNumThreads!=""
    #     jlEnv["JULIA_NUM_THREADS"] = env.juliaNumThreads
    # end

    error_handler_file = nothing
    crash_reporting_pipename = nothing

    error_handler_file = error_handler_file === nothing ? [] : [error_handler_file]
    crash_reporting_pipename = crash_reporting_pipename === nothing ? [] : [crash_reporting_pipename]

    env_to_use = copy(ENV)

    if haskey(env_to_use, "JULIA_DEPOT_PATH")
        delete!(env_to_use, "JULIA_DEPOT_PATH")
    end

    djp.proc = open(
        pipeline(
            Cmd(`julia --startup-file=no --history-file=no --depwarn=no $julia_dynamic_analysis_process_script $pipe_name $(error_handler_file...) $(crash_reporting_pipename...)`, detach=false, env=env_to_use),
            stdout = pipe_out,
            stderr = pipe_out
        )
    )

    @async try
        buffer = ""
        while !eof(pipe_out)
            data = readavailable(pipe_out)
            data_as_string = String(data)

            buffer *= data_as_string

            output_for_test_proc = IOBuffer()

            i = 1
            current_line_start = 1
            while i<=length(buffer)
                if buffer[i] == '\n'
                    line = strip(buffer[current_line_start:prevind(buffer,i)])
                    if length(line) > 0
                        @debug "Output from DynamicJuliaProcess" project_path=djp.project_path package=djp.package line=line
                    end
                    current_line_start = nextind(buffer, i)
                end
                i = nextind(buffer, i)
            end

            buffer = buffer[current_line_start:end]
        end
    catch err
        bt = catch_backtrace()
        Base.display_error(err, bt)
    end

    @debug "Waiting for connection from test process"
    socket = Sockets.accept(server)
    @debug "Connection established"

    djp.endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)

    JSONRPC.start(djp.endpoint)

    # while true
    #     msg = try
    #         JSONRPC.get_next_message(endpoint)
    #     catch err
    #         if CancellationTokens.is_cancellation_requested(token)
    #             break
    #         else
    #             rethrow(err)
    #         end
    #     end
    #     # @info "Processing msg from test process" msg

    #     dispatch_testprocess_msg(endpoint, msg, testprocess_msg_channel)
    # end
end

function Base.kill(djp::DynamicJuliaProcess)
    @info "Killing DynamicJuliaProcess" kind=djp.kind project_path=djp.project_path package=djp.package

    if djp.proc !== nothing
        kill(djp.proc)
        djp.proc = nothing
    end
    djp.endpoint = nothing
end

const DEFAULT_SYMBOLCACHE_UPSTREAM = "https://www.julia-vscode.org/symbolcache"

struct DynamicFeature
    djp_mode::DynamicMode
    store_path::String
    download_enabled::Bool
    upstream_url::String
    in_channel::Channel{Any}
    out_channel::Channel{Any}
    procs::Dict{DJPKey,DynamicJuliaProcess}
    failed_projects::Set{DJPKey}
    missing_pkg_metadata::Set{@NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}}
    pending_count::Threads.Atomic{Int}
    update_channel::Channel{Symbol}

    function DynamicFeature(djp_mode::DynamicMode, store_path::String; download_enabled::Bool=false, upstream_url::String=DEFAULT_SYMBOLCACHE_UPSTREAM)
        return new(
            djp_mode,
            store_path,
            download_enabled,
            upstream_url,
            Channel{Any}(Inf),
            Channel{Any}(Inf),
            Dict{DJPKey,DynamicJuliaProcess}(),
            Set{DJPKey}(),
            Set{@NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}}(),
            Threads.Atomic{Int}(0),
            Channel{Symbol}(100)
        )
    end
end

const MissingPackage = @NamedTuple{name::String, uuid::UUID, version::String, git_tree_sha1::Union{String,Nothing}}

"""
    _get_missing_packages(project_path, store_path) -> Vector{MissingPackage}

Parse the Manifest.toml at `project_path` and return a list of regular and stdlib
packages whose .jstore cache files do not yet exist on disk. Deved packages are
skipped entirely (they have no git_tree_sha1 and are handled by StaticLint).
"""
function _get_missing_packages(project_path::String, store_path::String)
    manifest_path = joinpath(project_path, "Manifest.toml")
    isfile(manifest_path) || return MissingPackage[]

    manifest_content = try
        Pkg.TOML.parsefile(manifest_path)
    catch
        return MissingPackage[]
    end

    manifest_version_str = get(manifest_content, "manifest_format", "1.0")
    manifest_version = tryparse(VersionNumber, manifest_version_str)
    manifest_version === nothing && return MissingPackage[]

    manifest_deps = if manifest_version.major == 1
        manifest_content
    elseif manifest_version.major == 2 && haskey(manifest_content, "deps") && manifest_content["deps"] isa Dict
        manifest_content["deps"]
    else
        return MissingPackage[]
    end

    missing = MissingPackage[]

    for (k_entry, v_entry) in pairs(manifest_deps)
        v_entry isa Vector || continue
        length(v_entry) == 1 || continue
        v_entry[1] isa Dict || continue
        entry = v_entry[1]

        # Skip deved packages (have "path" key)
        haskey(entry, "path") && continue

        uuid_str = get(entry, "uuid", nothing)
        uuid_str === nothing && continue
        uuid = tryparse(UUID, uuid_str)
        uuid === nothing && continue

        if haskey(entry, "git-tree-sha1") && haskey(entry, "version")
            # Regular package
            ver = entry["version"]
            tree_sha = entry["git-tree-sha1"]
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), string(k_entry, "_", uuid), string("v", ver, "_", tree_sha, ".jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver, tree_sha)))
            end
        elseif !haskey(entry, "git-tree-sha1")
            # Stdlib package
            ver_str = get(entry, "version", nothing)
            ver_str === nothing && continue
            cache_path = joinpath(store_path, uppercase(k_entry[1:1]), string(k_entry, "_", uuid), string("v", ver_str, "_nothing.jstore"))
            if !isfile(cache_path)
                push!(missing, MissingPackage((k_entry, uuid, ver_str, nothing)))
            end
        end
    end

    return missing
end

const GENERAL_REGISTRY_UUID = UUID("23338594-aafe-5451-b93e-139f81909106")

"""
    _get_general_registry_packages() -> Dict{UUID, NamedTuple}

Return a dict mapping UUID => (;name) for all packages in the General registry.
Used to filter out private packages from cloud download requests.
"""
function _get_general_registry_packages()
    dp_before = copy(Base.DEPOT_PATH)
    try
        push!(empty!(Base.DEPOT_PATH), joinpath(homedir(), ".julia"))
        regs = Pkg.Types.Context().registries
        i = findfirst(r -> r.name == "General" && r.uuid == GENERAL_REGISTRY_UUID, regs)
        i === nothing && return Dict{UUID,@NamedTuple{name::String}}()
        return Dict{UUID,@NamedTuple{name::String}}(
            uuid => (;name=info.name) for (uuid, info) in regs[i].pkgs
        )
    catch err
        @warn "Failed to read General registry" exception=(err, catch_backtrace())
        return Dict{UUID,@NamedTuple{name::String}}()
    finally
        append!(empty!(Base.DEPOT_PATH), dp_before)
    end
end

"""
    _download_single_cache(pkg, store_path, upstream_url, download_dir) -> Bool

Download a single .jstore.tar.gz from the cloud, unpack it, and move it to the
store path. Returns true on success, false on failure.
"""
function _download_single_cache(pkg::MissingPackage, store_path::String, upstream_url::String, download_dir::String)
    name, uuid, version, git_tree_sha1 = pkg
    tree_hash_str = git_tree_sha1 === nothing ? "nothing" : git_tree_sha1

    letter = uppercase(name[1:1])
    name_uuid = string(name, "_", uuid)
    filename = string("v", version, "_", tree_hash_str, ".jstore")

    dest_dir = joinpath(store_path, letter, name_uuid)
    dest_filepath = joinpath(dest_dir, filename)
    dest_filepath_unavailable = string(first(splitext(dest_filepath)), ".unavailable")

    # Skip if we already know it's unavailable
    if isfile(dest_filepath_unavailable)
        @debug "Cloud cache unavailable marker exists, skipping" name=name
        return false
    end

    link = string(upstream_url, "/store/v1/packages/", letter, "/", name_uuid, "/", first(splitext(filename)), ".tar.gz")

    pkg_download_dir = joinpath(download_dir, string(name, "_", uuid, "_", version))

    try
        @info "Downloading package cache" name=name version=version
        Pkg.PlatformEngines.download_verify_unpack(link, nothing, pkg_download_dir)

        download_filepath = joinpath(pkg_download_dir, filename)
        download_filepath_unavailable = string(first(splitext(download_filepath)), ".unavailable")

        if !isfile(download_filepath) && isfile(download_filepath_unavailable)
            mkpath(dest_dir)
            mv(download_filepath_unavailable, dest_filepath_unavailable, force=true)
            @debug "Cloud cache unavailable for package" name=name
            return false
        end

        if !isfile(download_filepath)
            @debug "Expected file not found in tarball" name=name expected=download_filepath
            return false
        end

        # Patch PLACEHOLDER paths
        cache = try
            open(download_filepath, "r") do io
                SymbolServer.CacheStore.read(io)
            end
        catch
            @warn "Couldn't read downloaded cache file" name=name
            return false
        end

        pkg_entry = Base.locate_package(Base.PkgId(uuid, name))
        if pkg_entry !== nothing && isfile(pkg_entry)
            pkg_src = dirname(pkg_entry)
            SymbolServer.modify_dirs(cache.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", pkg_src))
        end

        mkpath(dest_dir)
        open(dest_filepath, "w") do io
            SymbolServer.CacheStore.write(io, cache)
        end

        @info "Successfully downloaded cache" name=name version=version
        return true
    catch err
        @warn "Failed to download cache" name=name version=version exception=(err, catch_backtrace())
        return false
    finally
        try rm(pkg_download_dir, recursive=true, force=true) catch; end
    end
end

"""
    _download_missing_caches(missing_pkgs, store_path, upstream_url) -> Vector{MissingPackage}

Download missing package caches from the cloud. Filters to General registry
packages only (to avoid leaking private package names via URL requests).
Returns the list of packages still missing after download.
"""
function _download_missing_caches(missing_pkgs::Vector{MissingPackage}, store_path::String, upstream_url::String)
    general_pkgs = _get_general_registry_packages()
    if isempty(general_pkgs)
        @warn "Could not read General registry, skipping cloud downloads"
        return missing_pkgs
    end

    # Filter to General registry packages with tree_hash (no stdlibs, no _jll)
    downloadable = filter(missing_pkgs) do pkg
        pkg.git_tree_sha1 === nothing && return false  # stdlibs
        endswith(pkg.name, "_jll") && return false     # JLL packages
        info = get(general_pkgs, pkg.uuid, nothing)
        info === nothing && return false                # not in General
        info.name != pkg.name && return false           # UUID/name mismatch
        return true
    end

    isempty(downloadable) && return missing_pkgs

    download_dir_parent = joinpath(store_path, "_downloads")
    mkpath(download_dir_parent)

    downloaded_set = Set{MissingPackage}()

    mktempdir(download_dir_parent) do download_dir
        for batch in Iterators.partition(downloadable, 100)
            @sync for pkg in batch
                @async begin
                    yield()
                    if _download_single_cache(pkg, store_path, upstream_url, download_dir)
                        push!(downloaded_set, pkg)
                    end
                    yield()
                end
            end
        end
    end

    # Return packages still missing
    return filter(pkg -> pkg ∉ downloaded_set, missing_pkgs)
end

function start(df::DynamicFeature)
    Threads.@async try
        while true
            msg = take!(df.in_channel)

            @debug "Processing dynamic feature message" command=msg.command

            djp = nothing
            try
                if msg.command == :watch_environment
                    key = WatchEnvironmentKey(msg.project_path, msg.content_hash)

                    if key in df.failed_projects
                        @warn "Skipping previously failed project" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        missing_pkgs = _get_missing_packages(msg.project_path, df.store_path)

                        if !isempty(missing_pkgs) && df.download_enabled
                            @info "Downloading missing package caches" count=length(missing_pkgs)
                            missing_pkgs = _download_missing_caches(missing_pkgs, df.store_path, df.upstream_url)
                        end

                        if isempty(missing_pkgs)
                            @info "All package caches available, skipping DJP" project_path=msg.project_path
                            put!(df.out_channel, (;command=:environment_ready, project_path=msg.project_path, content_hash=msg.content_hash))
                        elseif df.djp_mode != DynamicOff
                            @info "Launching DJP for remaining missing packages" count=length(missing_pkgs)
                            djp = DynamicJuliaProcess(msg.project_path, nothing, :watch_environment)
                            df.procs[key] = djp

                            start(djp)

                            index_project(djp, df.store_path)

                            put!(df.out_channel, (;command=:environment_ready, project_path=msg.project_path, content_hash=msg.content_hash))

                            if df.djp_mode == DynamicIndexingOnly
                                kill(djp)
                                delete!(df.procs, key)
                            end
                        else
                            @info "Some packages missing but DJP disabled, proceeding with best-effort" missing_count=length(missing_pkgs)
                            put!(df.out_channel, (;command=:environment_ready, project_path=msg.project_path, content_hash=msg.content_hash))
                        end
                    end
                elseif msg.command == :watch_test_environment
                    key = WatchTestEnvironmentKey(msg.project_path, msg.package, msg.content_hash)

                    if key in df.failed_projects
                        @warn "Skipping previously failed test environment" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        djp = DynamicJuliaProcess(msg.project_path, msg.package, :watch_test_environment)
                        df.procs[key] = djp

                        start(djp)

                        test_project = index_project(djp, df.store_path)

                        test_project_uri = filepath2uri(test_project)

                        put!(df.out_channel, (;command=:test_environment_ready, project_uri=filepath2uri(msg.project_path), package=msg.package, test_project_uri=test_project_uri, content_hash=msg.content_hash))

                        if df.djp_mode == DynamicIndexingOnly
                            kill(djp)
                            delete!(df.procs, key)
                        end
                    end
                elseif msg.command == :create_standalone_package_project
                    key = CreateStandaloneProjectKey(msg.package_path, msg.content_hash)

                    if key in df.failed_projects
                        @warn "Skipping previously failed standalone project" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        djp = DynamicJuliaProcess(msg.package_path, nothing, :create_standalone_project)
                        df.procs[key] = djp

                        start(djp)

                        standalone_project = create_standalone_project(djp, df.store_path)

                        standalone_project_uri = filepath2uri(standalone_project)

                        put!(df.out_channel, (;command=:standalone_package_project_ready, package_folder_uri=filepath2uri(msg.package_path), project_uri=standalone_project_uri, content_hash=msg.content_hash))

                        if df.djp_mode == DynamicIndexingOnly
                            kill(djp)
                            delete!(df.procs, key)
                        end
                    end
                else
                    error("Unknown message: $msg")
                end
            catch err
                bt = catch_backtrace()
                @error "DynamicJuliaProcess failed" exception=(err, bt)
                # Mark this project as failed so we don't retry with the same content hash
                if hasproperty(msg, :content_hash)
                    failed_key = if msg.command == :watch_environment
                        WatchEnvironmentKey(msg.project_path, msg.content_hash)
                    elseif msg.command == :watch_test_environment
                        WatchTestEnvironmentKey(msg.project_path, msg.package, msg.content_hash)
                    elseif msg.command == :create_standalone_package_project
                        CreateStandaloneProjectKey(msg.package_path, msg.content_hash)
                    else
                        nothing
                    end
                    if failed_key !== nothing
                        push!(df.failed_projects, failed_key)
                        put!(df.out_channel, (;command=:failed, key=failed_key))
                    end
                end
                # Kill the DJP if it was started
                if djp !== nothing
                    try kill(djp) catch; end
                end
            finally
                Threads.atomic_sub!(df.pending_count, 1)
                try put!(df.update_channel, :data_available) catch; end
            end
        end
    catch err
        flush(stderr)
        bt = catch_backtrace()
        Base.display_error(err, bt)
        flush(stderr)
    end
end

function cleanup_stale_processes!(df::DynamicFeature, rt, required::Set{DJPKey})
    for (key, djp) in collect(df.procs)
        if key ∉ required
            @info "Killing stale DynamicJuliaProcess" key=key
            kill(djp)
            delete!(df.procs, key)

            # Clean up the corresponding Salsa inputs
            if key isa WatchEnvironmentKey
                delete_input_project_environment!(rt, filepath2uri(key.project_path), key.content_hash)
            elseif key isa CreateStandaloneProjectKey
                delete_input_standalone_package_project!(rt, filepath2uri(key.package_path), key.content_hash)
            elseif key isa WatchTestEnvironmentKey
                delete_input_project_test_environment!(rt, filepath2uri(key.project_path), key.package_name, key.content_hash)
            end
        end
    end

    # Prune failed_projects for keys that are no longer required
    filter!(k -> k in required, df.failed_projects)
end
