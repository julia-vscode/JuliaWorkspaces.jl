module JuliaDynamicAnalysisProcess

import Sockets, Pkg

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")
include("symbolserver.jl")

struct JuliaDynamicAnalysisProcessState
end

function index_project_request(params::JuliaDynamicAnalysisProtocol.IndexProjectParams, state::JuliaDynamicAnalysisProcessState, token)
    Pkg.activate(params.projectPath)

    SymbolServer.get_store(params.storePath, nothing)

    return nothing
end

JSONRPC.@message_dispatcher dispatch_msg begin
    JuliaDynamicAnalysisProtocol.index_project_request_type => index_project_request
end

function serve(pipename, error_handler=nothing)
    conn = Sockets.connect(pipename)

    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)
    run(endpoint)

    state = JuliaDynamicAnalysisProcessState()

    while true
        msg = JSONRPC.get_next_message(endpoint)
        dispatch_msg(endpoint, msg, state)

        if msg.method == "shutdown"
            break
        end
    end
end

end
