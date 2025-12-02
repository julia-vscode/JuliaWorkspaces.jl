module JuliaDynamicAnalysisProcess

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")
include("symbolserver.jl")

struct JuliaDynamicAnalysisProcessState
end

function get_store_request(params::JuliaDynamicAnalysisProtocol.GetStoreParams, state::JuliaDynamicAnalysisProcessState, token)
    Pkg.activate(uri2filepath(params.projectUri))

    SymbolServer.get_store(params.storePath, nothing)
end

JSONRPC.@message_dispatcher dispatch_msg begin
    JuliaDynamicAnalysisProtocol.get_store_request_type => get_store_request
end

function serve(pipename, error_handler=nothing)
    conn = Sockets.connect(pipename)

    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)
    run(endpoint)

    state = JuliaDynamicAnalysisProcessState()

    while true
        msg = JSONRPC.get_next_message(endpoint)
        dispatch_msg(endpoint, msg, state)

        if msg.method == "testserver/shutdown"
            break
        end
    end
end

end
