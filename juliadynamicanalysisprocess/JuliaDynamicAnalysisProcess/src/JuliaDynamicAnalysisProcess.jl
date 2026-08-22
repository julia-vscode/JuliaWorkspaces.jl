module JuliaDynamicAnalysisProcess

import Sockets, Pkg

include("pkg_imports.jl")
include("../../../shared/julia_dynamic_analysis_process_protocol.jl")
include("symbolserver.jl")
include("scratch_env.jl")

struct JuliaDynamicAnalysisProcessState
    endpoint::JSONRPC.JSONRPCEndpoint
    # Module-context cache for macro expansion, keyed by the parent's ctxId.
    # Each module holds the eval'd import statements of one file-module context;
    # the packages behind them are already loaded in this session (get_store
    # imported every manifest package), so building one is cheap.
    ctx_modules::Dict{String,Module}
end

JuliaDynamicAnalysisProcessState(endpoint::JSONRPC.JSONRPCEndpoint) =
    JuliaDynamicAnalysisProcessState(endpoint, Dict{String,Module}())

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
        if params.package !== nothing && needs_stdlib_test_env(params.projectPath, params.package)
            # TestEnv cannot build test environments for stdlib UUIDs, so dev
            # checkouts of stdlibs get a hand-built scratch test environment.
            Pkg.activate(materialize_stdlib_test_env(params.projectPath, params.package))
            Pkg.instantiate()
        elseif params.package !== nothing && CAN_MIRROR_ENV
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

        active_dir = dirname(Base.active_project())
        params.projectDir === nothing && return active_dir

        # Persist the materialized environment: the TestEnv path activates a
        # temp dir owned by this (short-lived) process, but the parent parses
        # the returned Manifest long after this process is gone. Copy the env
        # into the parent-owned dir and hand that back instead.
        mkpath(params.projectDir)
        cp(Base.active_project(), joinpath(params.projectDir, "Project.toml"); force=true)
        manifest = joinpath(active_dir, "Manifest.toml")
        if isfile(manifest)
            cp(manifest, joinpath(params.projectDir, "Manifest.toml"); force=true)
        end
        return params.projectDir
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

function resolve_environment_request(params::JuliaDynamicAnalysisProtocol.ResolveEnvironmentParams, state::JuliaDynamicAnalysisProcessState, token)
    write_resolved_env_project(params.envPath, params.projectDir)
    Pkg.activate(params.projectDir)

    try
        # `instantiate`, not `resolve`: SymbolServer loads the packages, so they
        # must be installed. A failed resolve degrades to whatever symbol caches
        # exist rather than blocking the environment forever.
        Pkg.instantiate()
    catch err
        @warn "Failed to resolve environment" params.envPath exception=(err, catch_backtrace())
    end

    try
        SymbolServer.get_store(params.storePath, progress_reporter(state))

        return dirname(Base.active_project())
    catch err
        err isa InterruptException && rethrow()
        _index_failure(err, catch_backtrace(), "environment (no manifest) at $(params.envPath)")
    end
end

# ── Macro expansion ─────────────────────────────────────────────────────────

# Bounds ctx-module memory. Dropping the whole cache on overflow is deliberate:
# rebuilding a context is cheap (packages stay loaded), and drop-all needs no
# bookkeeping.
const MAX_CTX_MODULES = 64

function _expansion_ctx_module!(state::JuliaDynamicAnalysisProcessState, ctx_id::AbstractString, imports::Vector{String})
    return get!(state.ctx_modules, ctx_id) do
        length(state.ctx_modules) >= MAX_CTX_MODULES && empty!(state.ctx_modules)
        # Default module: Base is in scope, as it is in any user file.
        m = Module(Symbol(:ExpansionCtx_, ctx_id))
        for stmt in imports
            try
                Core.eval(m, Meta.parse(stmt))
            catch err
                err isa InterruptException && rethrow()
                # A failing import degrades this context: macros from it error
                # per entry below instead of blocking the whole batch.
            end
        end
        m
    end
end

function expand_macros_request(params::JuliaDynamicAnalysisProtocol.ExpandMacrosParams, state::JuliaDynamicAnalysisProcessState, token)
    # Pick up on-disk edits to tracked (deved) packages, so re-expansions
    # requested after a macro-definition edit see the new definition.
    try
        Revise.revise()
    catch err
        err isa InterruptException && rethrow()
        @warn "Revise failed before macro expansion" exception=(err, catch_backtrace())
    end

    ctx = _expansion_ctx_module!(state, params.ctxId, params.imports)

    entries = map(params.entries) do e
        try
            expr = Meta.parse(e.text)
            if expr isa Expr && expr.head in (:incomplete, :error)
                error("macrocall text did not parse")
            end
            expanded = macroexpand(ctx, expr; recursive=true)
            JuliaDynamicAnalysisProtocol.ExpandMacroResultEntry(e.key, "ok", string(expanded))
        catch err
            err isa InterruptException && rethrow()
            JuliaDynamicAnalysisProtocol.ExpandMacroResultEntry(e.key, "error", sprint(showerror, err))
        end
    end

    return JuliaDynamicAnalysisProtocol.ExpandMacrosResult(entries, UInt64(Base.get_world_counter()))
end

JSONRPC.@message_dispatcher dispatch_msg begin
    JuliaDynamicAnalysisProtocol.index_project_request_type => index_project_request
    JuliaDynamicAnalysisProtocol.create_standalone_project_request_type => create_standalone_project_request
    JuliaDynamicAnalysisProtocol.resolve_environment_request_type => resolve_environment_request
    JuliaDynamicAnalysisProtocol.expand_macros_request_type => expand_macros_request
end

# Executed precompile workload: every dynamic-analysis child process pays at
# runtime for whatever of the symbol-extraction pipeline is not in this
# package's image. Reflecting over the modules loaded during precompilation
# (this package plus its stdlib deps) compiles the same getenvtree/symbols
# machinery that `get_store` runs on real environments.
function _precompile_workload_()
    try
        env_symbols = SymbolServer.getenvtree()
        visited = Base.IdSet{Module}([Base, Core])
        SymbolServer.symbols(env_symbols, nothing, SymbolServer.getallns(), visited)
    catch err
        # A failed workload must never break the analysis process itself.
        @warn "JuliaDynamicAnalysisProcess precompile workload failed" exception = (err, catch_backtrace())
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_workload_()
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
