abstract type TraverseState end

function process_EXPR end

"""
    traverse(x, state)

Iterates across the child nodes of an EXPR in execution order (rather than
storage order) calling `process_EXPR` on each node.
"""
function traverse(x::EXPR, state::TraverseState)
    if (isassignment(x) && !(CSTParser.is_func_call(x.args[1]) || CSTParser.iscurly(x.args[1]))) || CSTParser.isdeclaration(x)
        process_EXPR(x.args[2], state)
        process_EXPR(x.args[1], state)
    elseif CSTParser.iswhere(x)
        for i = 2:length(x.args)
            process_EXPR(x.args[i], state)
        end
        process_EXPR(x.args[1], state)
    elseif headof(x) === :generator || headof(x) === :filter
        @inbounds for i = 2:length(x.args)
            process_EXPR(x.args[i], state)
        end
        process_EXPR(x.args[1], state)
    elseif headof(x) === :call && length(x.args) > 1 && headof(x.args[2]) === :parameters
        process_EXPR(x.args[1], state)
        @inbounds for i = 3:length(x.args)
            process_EXPR(x.args[i], state)
        end
        process_EXPR(x.args[2], state)
    elseif x.args !== nothing && length(x.args) > 0
        @inbounds for i = 1:length(x.args)
            process_EXPR(x.args[i], state)
        end
    end
end
