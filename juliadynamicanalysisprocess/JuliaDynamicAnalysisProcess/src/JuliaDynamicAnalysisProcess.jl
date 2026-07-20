module JuliaDynamicAnalysisProcess

import Sockets, Pkg

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")
include("symbolserver.jl")

struct JuliaDynamicAnalysisProcessState
    endpoint::JSONRPC.JSONRPCEndpoint
end

# Progress callback for SymbolServer.get_store that forwards each report to the
# parent process as an `indexProgress` notification.
function progress_reporter(state::JuliaDynamicAnalysisProcessState)
    return function (message, percentage)
        JSONRPC.send(
            state.endpoint,
            JuliaDynamicAnalysisProtocol.index_progress_notification_type,
            JuliaDynamicAnalysisProtocol.IndexProgressParams(message, percentage)
        )
    end
end

function index_project_request(params::JuliaDynamicAnalysisProtocol.IndexProjectParams, state::JuliaDynamicAnalysisProcessState, token)
    Pkg.activate(params.projectPath)

    if params.package!==nothing
        TestEnv.activate(params.package);
    end

    SymbolServer.get_store(params.storePath, progress_reporter(state))

    return dirname(Base.active_project())
end

function create_standalone_project_request(params::JuliaDynamicAnalysisProtocol.CreateStandaloneProjectParams, state::JuliaDynamicAnalysisProcessState, token)
    mkpath(params.projectDir)
    Pkg.activate(params.projectDir)

    try
        Pkg.develop(path=params.packagePath)
        Pkg.resolve()
    catch err
        @warn "Failed to resolve standalone package project" params.packagePath exception=(err, catch_backtrace())
    end

    SymbolServer.get_store(params.storePath, progress_reporter(state))

    return dirname(Base.active_project())
end

JSONRPC.@message_dispatcher dispatch_msg begin
    JuliaDynamicAnalysisProtocol.index_project_request_type => index_project_request
    JuliaDynamicAnalysisProtocol.create_standalone_project_request_type => create_standalone_project_request
end

function serve(pipename, error_handler=nothing)
    conn = Sockets.connect(pipename)

    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)
    JSONRPC.start(endpoint)

    state = JuliaDynamicAnalysisProcessState(endpoint)

    while true
        msg = JSONRPC.get_next_message(endpoint)
        dispatch_msg(endpoint, msg, state)

        if msg.method == "shutdown"
            break
        end
    end
end

end
