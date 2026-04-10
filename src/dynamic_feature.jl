@enum DynamicMode DynamicOff DynamicIndexingOnly DynamicPersistent

const DJPKey = @NamedTuple{project_path::String, package::Union{Nothing,String}, content_hash::UInt}

mutable struct DynamicJuliaProcess
    project_path::String
    package::Union{Nothing,String}
    proc::Union{Nothing, Base.Process}
    endpoint::Union{Nothing, JSONRPC.JSONRPCEndpoint}

    function DynamicJuliaProcess(project_path::String, package::Union{Nothing,String})
        return new(
            project_path,
            package,
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
    @info "Starting DynamicJuliaProcess" project_path=djp.project_path package=djp.package

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
    @info "Killing DynamicJuliaProcess" project_path=djp.project_path package=djp.package

    if djp.proc !== nothing
        kill(djp.proc)
        djp.proc = nothing
    end
    djp.endpoint = nothing
end

struct DynamicFeature
    mode::DynamicMode
    store_path::String
    in_channel::Channel{Any}
    out_channel::Channel{Any}
    procs::Dict{DJPKey,DynamicJuliaProcess}
    failed_projects::Set{DJPKey}
    missing_pkg_metadata::Set{@NamedTuple{name::Symbol, uuid::UUID, version::VersionNumber, git_tree_sha1::Union{String,Nothing}}}
    pending_count::Threads.Atomic{Int}
    update_channel::Channel{Symbol}

    function DynamicFeature(mode::DynamicMode, store_path::String)
        return new(
            mode,
            store_path,
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

function start(df::DynamicFeature)
    Threads.@async try
        while true
            msg = take!(df.in_channel)

            @debug "Processing dynamic feature message" command=msg.command

            Threads.atomic_add!(df.pending_count, 1)

            djp = nothing
            try
                if msg.command == :watch_environment
                    key = DJPKey((msg.project_path, nothing, msg.content_hash))

                    if key in df.failed_projects
                        @warn "Skipping previously failed project" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        djp = DynamicJuliaProcess(msg.project_path, nothing)
                        df.procs[key] = djp

                        start(djp)

                        index_project(djp, df.store_path)

                        put!(df.out_channel, (;command=:environment_ready, project_path=msg.project_path, content_hash=msg.content_hash))

                        if df.mode == DynamicIndexingOnly
                            kill(djp)
                            delete!(df.procs, key)
                        end
                    end
                elseif msg.command == :watch_test_environment
                    key = DJPKey((msg.project_path, msg.package, msg.content_hash))

                    if key in df.failed_projects
                        @warn "Skipping previously failed test environment" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        djp = DynamicJuliaProcess(msg.project_path, msg.package)
                        df.procs[key] = djp

                        start(djp)

                        test_project = index_project(djp, df.store_path)

                        test_project_uri = filepath2uri(test_project)

                        put!(df.out_channel, (;command=:test_environment_ready, project_uri=filepath2uri(msg.project_path), package=msg.package, test_project_uri=test_project_uri, content_hash=msg.content_hash))

                        if df.mode == DynamicIndexingOnly
                            kill(djp)
                            delete!(df.procs, key)
                        end
                    end
                elseif msg.command == :create_standalone_package_project
                    key = DJPKey((msg.package_path, "__standalone__", msg.content_hash))

                    if key in df.failed_projects
                        @warn "Skipping previously failed standalone project" key
                        put!(df.out_channel, (;command=:failed, key=key))
                    else
                        djp = DynamicJuliaProcess(msg.package_path, nothing)
                        df.procs[key] = djp

                        start(djp)

                        standalone_project = create_standalone_project(djp, df.store_path)

                        standalone_project_uri = filepath2uri(standalone_project)

                        put!(df.out_channel, (;command=:standalone_package_project_ready, package_folder_uri=filepath2uri(msg.package_path), project_uri=standalone_project_uri, content_hash=msg.content_hash))

                        if df.mode == DynamicIndexingOnly
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
                        DJPKey((msg.project_path, nothing, msg.content_hash))
                    elseif msg.command == :watch_test_environment
                        DJPKey((msg.project_path, msg.package, msg.content_hash))
                    elseif msg.command == :create_standalone_package_project
                        DJPKey((msg.package_path, "__standalone__", msg.content_hash))
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
            if key.package === nothing
                delete_input_project_environment!(rt, filepath2uri(key.project_path), key.content_hash)
            elseif key.package == "__standalone__"
                delete_input_standalone_package_project!(rt, filepath2uri(key.project_path), key.content_hash)
            else
                delete_input_project_test_environment!(rt, filepath2uri(key.project_path), key.package, key.content_hash)
            end
        end
    end

    # Prune failed_projects for keys that are no longer required
    filter!(k -> k in required, df.failed_projects)
end
