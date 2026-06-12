# ═══════════════════════════════════════════════════════════════════════════════
# Dynamic process keys
# ═══════════════════════════════════════════════════════════════════════════════

# DJPKey is a tagged sum type identifying a DynamicJuliaProcess.
#
# Each variant carries exactly the fields that are meaningful for that kind of
# process. Producers (`handle!` for the work messages), the required-set
# computation (`derived_required_dynamic_projects`), and the reconcile path
# (`handle!(::ReconcileMsg)`) all construct/dispatch on these variants
# directly, which makes mismatches between them a type error rather than a
# silent string-sentinel collision.
#
# `@auto_hash_equals` gives them value-based `==`/`hash` (the default for plain
# structs compares `String` fields by identity, which is unsafe for use as
# `Set`/`Dict` keys).
@auto_hash_equals struct WatchEnvironmentKey
    project_path::String
    content_hash::UInt64
end

@auto_hash_equals struct WatchTestEnvironmentKey
    project_path::String
    package_name::String
    content_hash::UInt64
end

@auto_hash_equals struct CreateStandaloneProjectKey
    package_path::String
    content_hash::UInt64
end

const DJPKey = Union{WatchEnvironmentKey, WatchTestEnvironmentKey, CreateStandaloneProjectKey}

# ═══════════════════════════════════════════════════════════════════════════════
# Reactor messages (in_channel)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    DynamicReactorMessage

Abstract supertype for every message processed by the dynamic-feature reactor
loop (`Base.run(::DynamicFeature)`). Each concrete subtype is handled by a
type-specialized `handle!` method.
"""
abstract type DynamicReactorMessage end

# --- Work messages: produced by the lazy Salsa inputs (inputs.jl) ---

"""Request to index/watch the environment of a project."""
struct WatchEnvironmentMsg <: DynamicReactorMessage
    project_path::String
    content_hash::UInt64
end

"""Request to index/watch the test environment of a project + package."""
struct WatchTestEnvironmentMsg <: DynamicReactorMessage
    project_path::String
    package::String
    content_hash::UInt64
end

"""Request to create a standalone project for a package folder."""
struct CreateStandaloneProjectMsg <: DynamicReactorMessage
    package_path::String
    content_hash::UInt64
end

"""Request an orderly shutdown of the reactor."""
struct ShutdownMsg <: DynamicReactorMessage end

"""
Reconcile the set of running/required dynamic processes.

Carries the full set of [`DJPKey`](@ref)s the workspace currently needs (as
computed by `derived_required_dynamic_projects`). The reactor diffs this against
the processes it is already running / has completed, spawning the missing ones
and cancelling the ones that are no longer required. This replaces the previous
design where launches were triggered as a side effect of lazy Salsa inputs.
"""
struct ReconcileMsg <: DynamicReactorMessage
    required::Set{DJPKey}
end

# --- Internal follow-up messages: produced by reactor-spawned async tasks ---

"""
Posted by the async environment-prep task spawned from `WatchEnvironmentMsg`
once the (potentially slow) missing-package check + cloud download finished.
`still_missing` indicates whether a DJP is still required afterwards.
"""
struct EnvironmentPrepDoneMsg <: DynamicReactorMessage
    project_path::String
    content_hash::UInt64
    still_missing::Bool
end

# --- Lifecycle messages: produced by `start(djp)` and the index tasks ---

"""Posted by `start(djp)` once the child process is connected and ready."""
struct ProcessLaunchedMsg <: DynamicReactorMessage
    key::DJPKey
    proc::Base.Process
    endpoint::JSONRPC.JSONRPCEndpoint
end

"""Posted by the index task once the child returned a result (project dir)."""
struct ProcessIndexedMsg <: DynamicReactorMessage
    key::DJPKey
    result_dir::String
end

"""Posted by the index task when the index/standalone request failed."""
struct ProcessIndexFailedMsg <: DynamicReactorMessage
    key::DJPKey
    err::Any
end

"""Posted by `start(djp)` when the child process connection terminated."""
struct ProcessTerminatedMsg <: DynamicReactorMessage
    key::DJPKey
end

# ═══════════════════════════════════════════════════════════════════════════════
# Result messages (out_channel)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    DynamicResultMessage

Abstract supertype for results emitted on `DynamicFeature.out_channel` and
consumed by `process_from_dynamic` (types.jl).
"""
abstract type DynamicResultMessage end

"""A unit of dynamic work failed for the given key."""
struct FailedResult <: DynamicResultMessage
    key::DJPKey
end

"""The environment for a project has been fully processed."""
struct EnvironmentReadyResult <: DynamicResultMessage
    project_path::String
    content_hash::UInt64
end

"""The test environment for a project + package is ready."""
struct TestEnvironmentReadyResult <: DynamicResultMessage
    project_uri::URI
    package::String
    test_project_uri::URI
    content_hash::UInt64
end

"""A standalone package project has been created."""
struct StandaloneProjectReadyResult <: DynamicResultMessage
    package_folder_uri::URI
    project_uri::URI
    content_hash::UInt64
end
