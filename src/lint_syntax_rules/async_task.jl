# async_task: `@async` where `Threads.@spawn` is usually meant.
#
# Ported idea: ReLint's `@async` rule. `@async` pins the task to the thread
# that spawned it, which blocks migration and can starve the scheduler;
# `Threads.@spawn` is almost always the better default.

const _ASYNC_TASK_MESSAGE = "`@async` pins the task to the current thread. Consider `Threads.@spawn` unless thread-stickiness is intended."

function _check_async_task(emit!, node, _ctx)
    _macro_name(node) === Symbol("@async") && emit!(_node_range(node), _ASYNC_TASK_MESSAGE)
    return nothing
end

const ASYNC_TASK_CHECK = SyntaxCheck(:async_task, (K"macrocall",), _check_async_task)
