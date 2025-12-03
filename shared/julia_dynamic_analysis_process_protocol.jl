module JuliaDynamicAnalysisProtocol

import ..JSONRPC
import ..JSONRPC.JSON

using ..JSONRPC: @dict_readable, RequestType, NotificationType, Outbound

@dict_readable struct GetStoreParams <: JSONRPC.Outbound
    projectPath::String
    storePath::String
end

# Messages to the dynamic analysis process
const get_store_request_type = JSONRPC.RequestType("juliadynamicanalysisprocess/getStore", GetStoreParams, Nothing)
# const testserver_activate_env_request_type = JSONRPC.RequestType("activateEnv", ActivateEnvParams, Nothing)
# const configure_testrun_request_type = JSONRPC.RequestType("testserver/ConfigureTestRun", ConfigureTestRunRequestParams, Nothing)
# const testserver_run_testitems_batch_request_type = JSONRPC.RequestType("testserver/runTestItems", RunTestItemsRequestParams, Nothing)
# const testserver_steal_testitems_request_type = JSONRPC.RequestType("testserver/stealTestItems", StealTestItemsRequestParams, Nothing)
# const testserver_shutdown_request_type = JSONRPC.RequestType("testserver/shutdown", Nothing, Nothing)

# Messages from the dynamic analysis process
# const started_notification_type = JSONRPC.NotificationType("started", StartedParams)
# const passed_notification_type = JSONRPC.NotificationType("passed", PassedParams)
# const errored_notification_type = JSONRPC.NotificationType("errored", ErroredParams)
# const failed_notification_type = JSONRPC.NotificationType("failed", FailedParams)
# const skipped_stolen_notification_type = JSONRPC.NotificationType("skippedStolen", SkippedStolenParams)

end
