mutable struct DynamicJuliaProcess
    project_path::String
    proc::Union{Nothing, Base.Process}
    endpoint::Union{Nothing, JSONRPC.JSONRPCEndpoint}

    function DynamicJuliaProcess(project_path::String)
        return new(
            project_path,
            nothing,
            nothing
        )
    end
end

function get_store(djp::DynamicJuliaProcess, store_path::String, depot_path)
    JSONRPC.send(
        djp.endpoint,
        JuliaDynamicAnalysisProtocol.get_store_request_type,
        JuliaDynamicAnalysisProtocol.GetStoreParams(
            djp.project_path,
            store_path
        )
    )

    new_store = SymbolServer.recursive_copy(SymbolServer.stdlibs)
    SymbolServer.load_project_packages_into_store!(store_path, depot_path, djp.project_path, new_store, nothing)

    return new_store
end

function start(djp::DynamicJuliaProcess)
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)

    julia_dynamic_analysis_process_script = joinpath(@__DIR__, "../juliadynamicanalysisprocess/app/julia_dynamic_analysis_process_main.jl")

    # pipe_out = Pipe()

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

    djp.proc = open(
        pipeline(
            Cmd(`julia --startup-file=no --history-file=no --depwarn=no $julia_dynamic_analysis_process_script $pipe_name $(error_handler_file...) $(crash_reporting_pipename...)`, detach=false),
            # stdout = pipe_out,
            # stderr = pipe_out
        )
    )

    # @async try
    #     begin_marker = "\x1f3805a0ad41b54562a46add40be31ca27"
    #     end_marker = "\x1f4031af828c3d406ca42e25628bb0aa77"
    #     buffer = ""
    #     current_output_testitem_id = nothing
    #     while !eof(pipe_out)
    #         data = readavailable(pipe_out)
    #         data_as_string = String(data)

    #         buffer *= data_as_string

    #         output_for_test_proc = IOBuffer()
    #         output_for_test_items = Pair{Union{Nothing,String},IOBuffer}[]

    #         i = 1
    #         while i<=length(buffer)
    #             might_be_begin_marker = false
    #             might_be_end_marker = false

    #             if current_output_testitem_id === nothing
    #                 j = 1
    #                 might_be_begin_marker = true
    #                 while i + j - 1<=length(buffer) && j <= length(begin_marker)
    #                     if buffer[i + j - 1] != begin_marker[j] || nextind(buffer, i + j - 1) != i + j
    #                         might_be_begin_marker = false
    #                         break
    #                     end
    #                     j += 1
    #                 end
    #                 is_begin_marker = might_be_begin_marker && length(buffer) - i + 1 >= length(begin_marker)

    #                 if is_begin_marker
    #                     ti_id_end_index = findfirst("\"", SubString(buffer, i))
    #                     if ti_id_end_index === nothing
    #                         break
    #                     else
    #                         current_output_testitem_id = SubString(buffer, i + length(begin_marker), i + ti_id_end_index.start - 2)
    #                         i = nextind(buffer, i + ti_id_end_index.start - 1)
    #                     end
    #                 elseif might_be_begin_marker
    #                     break
    #                 end
    #             else
    #                 j = 1
    #                 might_be_end_marker = true
    #                 while i + j - 1<=length(buffer) && j <= length(end_marker)
    #                     if buffer[i + j - 1] != end_marker[j] || nextind(buffer, i + j - 1) != i + j
    #                         might_be_end_marker = false
    #                         break
    #                     end
    #                     j += 1
    #                 end
    #                 is_end_marker = might_be_end_marker && length(buffer) - i + 1 >= length(end_marker)

    #                 if is_end_marker
    #                     current_output_testitem_id = nothing
    #                     i = i + length(end_marker)
    #                 elseif might_be_end_marker
    #                     break
    #                 end
    #             end

    #             if !might_be_begin_marker && !might_be_end_marker
    #                 print(output_for_test_proc, buffer[i])

    #                 if length(output_for_test_items) == 0 || output_for_test_items[end].first != current_output_testitem_id
    #                     push!(output_for_test_items, current_output_testitem_id => IOBuffer())
    #                 end

    #                 output_for_ti = output_for_test_items[end].second
    #                 if !CancellationTokens.is_cancellation_requested(token)
    #                     print(output_for_ti, buffer[i])
    #                 end

    #                 i = nextind(buffer, i)
    #             end
    #         end

    #         buffer = buffer[i:end]

    #         output_for_test_proc_as_string = String(take!(output_for_test_proc))

    #         if length(output_for_test_proc_as_string) > 0
    #             put!(
    #                 controller_msg_channel,
    #                 (
    #                     event = :testprocess_output,
    #                     id = testprocess_id,
    #                     output = output_for_test_proc_as_string
    #                 )
    #             )
    #         end

    #         for (k,v) in output_for_test_items
    #             output_for_ti_as_string = String(take!(v))

    #             if length(output_for_ti_as_string) > 0
    #                 put!(
    #                     testprocess_msg_channel,
    #                     (
    #                         event = :append_output,
    #                         testitem_id = something(k, missing),
    #                         output = replace(output_for_ti_as_string, "\n"=>"\r\n")
    #                     )
    #                 )
    #             end
    #         end
    #     end
    # catch err
    #     bt = catch_backtrace()
    #     if controller.err_handler !== nothing
    #         controller.err_handler(err, bt)
    #     else
    #         Base.display_error(err, bt)
    #     end
    # end

    @debug "Waiting for connection from test process"
    socket = Sockets.accept(server)
    @debug "Connection established"

    djp.endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)

    run(djp.endpoint)

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
end

struct DynamicFeature
    in_channel::Channel{Any}
    out_channel::Channel{Any}
    procs::Dict{String,DynamicJuliaProcess}

    function DynamicFeature()
        return new(
            Channel{Any}(Inf),
            Channel{Any}(Inf),
            Dict{String,DynamicJuliaProcess}()
        )
    end
end

function start(df::DynamicFeature)
    Threads.@async try
        while true
            msg = take!(df.in_channel)

            @info "Processing message" msg

            if msg.command == :set_environments
                # Delete Julia procs we no longer need
                foreach(setdiff(keys(df.procs), msg.environments)) do i
                    kill(procs[i])
                    delete!(df.procs, i)
                end

                # Add new required procs
                foreach(setdiff(msg.environments, keys(df.procs))) do i
                    djp = DynamicJuliaProcess(i)
                    df.procs[i] = djp

                    start(djp)
                end

                for i in msg.environments
                    env = get_store(df.procs[i], joinpath(homedir(), "djpstore"), joinpath(homedir(), ".julia"))

                    put!(df.out_channel, (command=:environment_ready, path=i, environment=env))
                end
            else
                error("Unknown message: $msg")
            end
        end
    catch err
        flush(stderr)
        bt = catch_backtrace()
        Base.display_error(err, bt)
        flush(stderr)
    end
end
