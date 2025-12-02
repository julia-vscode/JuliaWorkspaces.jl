module JuliaDynamicAnalysisProcess

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")

JSONRPC.@message_dispatcher dispatch_msg begin
    TestItemServerProtocol.testserver_revise_request_type => revise_request
    TestItemServerProtocol.testserver_activate_env_request_type => activate_env_request
    TestItemServerProtocol.configure_testrun_request_type => configure_test_run_request
    TestItemServerProtocol.testserver_run_testitems_batch_request_type => run_testitems_batch_request
    TestItemServerProtocol.testserver_steal_testitems_request_type => steal_testitems_request
    TestItemServerProtocol.testserver_shutdown_request_type => shutdown_request
end

function serve(pipename, error_handler=nothing)
    conn = Sockets.connect(pipename)

    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)

    run(endpoint)

    while true
        msg = JSONRPC.get_next_message(endpoint)

        if msg.method == "testserver/shutdown"
            dispatch_msg(endpoint, msg, state)
            break
        else
            @async try
                dispatch_msg(endpoint, msg, state)
            catch err
                Base.display_error(err, catch_backtrace())
            end
        end
    end
end

end
