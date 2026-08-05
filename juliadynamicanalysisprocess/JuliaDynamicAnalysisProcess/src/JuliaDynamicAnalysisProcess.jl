module JuliaDynamicAnalysisProcess

import Sockets, Pkg

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")
include("symbolserver.jl")
include("scratch_env.jl")

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

# Turn any indexing failure into an ErrorException whose message carries the
# context (what we were indexing) plus the child-side stacktrace. Only the
# message crosses the JSONRPC boundary, so embedding the backtrace here is what
# lets the orchestrator log a meaningful cause instead of a bare exception.
function _index_failure(err, bt, what)
    error("Failed to index $what: $(sprint(showerror, err, bt))")
end

function index_project_request(params::JuliaDynamicAnalysisProtocol.IndexProjectParams, state::JuliaDynamicAnalysisProcessState, token)
    try
        if params.package !== nothing && CAN_MIRROR_ENV
            # `TestEnv.activate` instantiates whatever environment is active, which
            # would create a `Manifest.toml` in the user's folder. Give it a scratch
            # mirror of the environment instead.
            Pkg.activate(materialize_scratch_env(params.projectPath, params.package))

            TestEnv.activate(params.package)
        else
            # Either there is no test environment to build, or this Julia is too
            # old to mirror one. Reading an environment never writes to it, so
            # indexing the project where it lies is safe; on the old-Julia path
            # test files lose their test-only dependencies, which is the lesser
            # harm compared to writing into the user's folder.
            Pkg.activate(params.projectPath)
        end

        SymbolServer.get_store(params.storePath, progress_reporter(state))

        return dirname(Base.active_project())
    catch err
        err isa InterruptException && rethrow()
        _index_failure(err, catch_backtrace(),
            "project at $(params.projectPath)" *
            (params.package === nothing ? "" : " (test env for package $(params.package))"))
    end
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

    try
        SymbolServer.get_store(params.storePath, progress_reporter(state))

        return dirname(Base.active_project())
    catch err
        err isa InterruptException && rethrow()
        _index_failure(err, catch_backtrace(), "standalone project for package at $(params.packagePath)")
    end
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
