"""
    DynamicControllerPhase

States for the dynamic-feature controller-level FSM.
- `DynamicControllerRunning`: Normal operation, accepts new work.
- `DynamicControllerShuttingDown`: Rejects new work, cancels running processes.
- `DynamicControllerStopped`: Reactor loop breaks.
"""
@enum DynamicControllerPhase begin
    DynamicControllerRunning
    DynamicControllerShuttingDown
    DynamicControllerStopped
end

"""
    DynamicProcessPhase

States for the per-process FSM. `DynamicProcessDead` is reachable from any state.
- `DynamicProcessCreated`: Constructed, not yet launched.
- `DynamicProcessStarting`: Child process spawned, waiting for connection.
- `DynamicProcessConnected`: JSONRPC endpoint established.
- `DynamicProcessIndexing`: An index/standalone request is in flight.
- `DynamicProcessDone`: Request completed successfully.
- `DynamicProcessDead`: Killed or terminated.
"""
@enum DynamicProcessPhase begin
    DynamicProcessCreated
    DynamicProcessStarting
    DynamicProcessConnected
    DynamicProcessIndexing
    DynamicProcessDone
    DynamicProcessDead
end

"""
    FSM{S}

Simple finite state machine parameterized on state enum type `S`.
Validates transitions against an allowed-transition table and logs changes.
"""
mutable struct FSM{S}
    current::S
    transitions::Dict{S,Set{S}}
    id::String
end

"""Return the current state of the FSM."""
state(fsm::FSM) = fsm.current

"""
    transition!(fsm, new_state; reason=nothing)

Transition the FSM to `new_state`. Raises an error if the transition is not allowed.
"""
function transition!(fsm::FSM{S}, new_state::S; reason=nothing) where S
    allowed = get(fsm.transitions, fsm.current, Set{S}())
    if new_state ∉ allowed
        error("Invalid FSM transition for '$(fsm.id)': $(fsm.current) → $(new_state)" *
              (reason !== nothing ? " (reason: $reason)" : ""))
    end
    old_state = fsm.current
    fsm.current = new_state
    @debug "FSM transition" id=fsm.id from=old_state to=new_state reason
    return new_state
end

"""Create a controller-phase FSM starting in `DynamicControllerRunning`."""
function dynamic_controller_fsm(id::String)
    transitions = Dict{DynamicControllerPhase,Set{DynamicControllerPhase}}(
        DynamicControllerRunning      => Set([DynamicControllerShuttingDown]),
        DynamicControllerShuttingDown => Set([DynamicControllerStopped]),
    )
    return FSM(DynamicControllerRunning, transitions, id)
end

"""Create a dynamic-process-phase FSM starting in `DynamicProcessCreated`."""
function dynamic_process_fsm(id::String)
    dead_set = Set([DynamicProcessDead])

    transitions = Dict{DynamicProcessPhase,Set{DynamicProcessPhase}}()
    # ANY → Dead (except Dead itself)
    for phase in instances(DynamicProcessPhase)
        if phase != DynamicProcessDead
            transitions[phase] = copy(dead_set)
        end
    end
    # Specific transitions (merged with Dead)
    union!(transitions[DynamicProcessCreated],   Set([DynamicProcessStarting]))
    union!(transitions[DynamicProcessStarting],  Set([DynamicProcessConnected]))
    union!(transitions[DynamicProcessConnected], Set([DynamicProcessIndexing]))
    union!(transitions[DynamicProcessIndexing],  Set([DynamicProcessDone]))

    return FSM(DynamicProcessCreated, transitions, id)
end
