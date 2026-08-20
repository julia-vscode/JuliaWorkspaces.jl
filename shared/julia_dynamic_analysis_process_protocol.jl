module JuliaDynamicAnalysisProtocol

import ..JSONRPC
import ..JSONRPC.JSON

using ..JSONRPC: @dict_readable, RequestType, NotificationType, Outbound

@dict_readable struct IndexProjectParams <: JSONRPC.Outbound
    projectPath::String
    package::Union{Nothing,String}
    storePath::String
    # Parent-owned dir to persist the materialized environment into. When set,
    # the child copies the activated Project/Manifest there and returns this
    # dir instead of the (possibly process-local, temporary) activated one.
    projectDir::Union{Nothing,String}
end

@dict_readable struct CreateStandaloneProjectParams <: JSONRPC.Outbound
    packagePath::String
    storePath::String
    projectDir::String
end

@dict_readable struct ResolveEnvironmentParams <: JSONRPC.Outbound
    envPath::String
    storePath::String
    projectDir::String
end

@dict_readable struct IndexProgressParams <: JSONRPC.Outbound
    message::String
    percentage::Union{Int,Missing}
end

# ── Macro expansion ─────────────────────────────────────────────────────────
#
# One batch expands many macrocalls that share an environment (the child's
# active project) and a module context (`ctxId` + the import statements that
# define it). Entries are keyed by an opaque string the parent mints
# (content-hash based); the child never interprets it.

@dict_readable struct ExpandMacroEntry <: JSONRPC.Outbound
    key::String
    text::String                 # the macrocall's source text
end

@dict_readable struct ExpandMacrosParams <: JSONRPC.Outbound
    ctxId::String                # identifies the module context for caching
    imports::Vector{String}      # canonical import/using statements defining it
    entries::Vector{ExpandMacroEntry}
end

@dict_readable struct ExpandMacroResultEntry <: JSONRPC.Outbound
    key::String
    status::String               # "ok" | "error"
    result::String               # expansion source text, or the error message
end

@dict_readable struct ExpandMacrosResult <: JSONRPC.Outbound
    entries::Vector{ExpandMacroResultEntry}
    world::UInt64                # child world counter after Revise, for ordering/debugging
end

# Messages to the dynamic analysis process
const index_project_request_type = JSONRPC.RequestType("juliadynamicanalysisprocess/indexProject", IndexProjectParams, String)
const create_standalone_project_request_type = JSONRPC.RequestType("juliadynamicanalysisprocess/createStandaloneProject", CreateStandaloneProjectParams, String)
const resolve_environment_request_type = JSONRPC.RequestType("juliadynamicanalysisprocess/resolveEnvironment", ResolveEnvironmentParams, String)
const expand_macros_request_type = JSONRPC.RequestType("juliadynamicanalysisprocess/expandMacros", ExpandMacrosParams, ExpandMacrosResult)
# const testserver_activate_env_request_type = JSONRPC.RequestType("activateEnv", ActivateEnvParams, Nothing)
# const configure_testrun_request_type = JSONRPC.RequestType("testserver/ConfigureTestRun", ConfigureTestRunRequestParams, Nothing)
# const testserver_run_testitems_batch_request_type = JSONRPC.RequestType("testserver/runTestItems", RunTestItemsRequestParams, Nothing)
# const testserver_steal_testitems_request_type = JSONRPC.RequestType("testserver/stealTestItems", StealTestItemsRequestParams, Nothing)
# const testserver_shutdown_request_type = JSONRPC.RequestType("testserver/shutdown", Nothing, Nothing)

# Messages from the dynamic analysis process
const index_progress_notification_type = JSONRPC.NotificationType("juliadynamicanalysisprocess/indexProgress", IndexProgressParams)
# const started_notification_type = JSONRPC.NotificationType("started", StartedParams)
# const passed_notification_type = JSONRPC.NotificationType("passed", PassedParams)
# const errored_notification_type = JSONRPC.NotificationType("errored", ErroredParams)
# const failed_notification_type = JSONRPC.NotificationType("failed", FailedParams)
# const skipped_stolen_notification_type = JSONRPC.NotificationType("skippedStolen", SkippedStolenParams)

end
