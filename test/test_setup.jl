@testmodule SpawnHelper begin
    # Prefer Threads.@spawn (Julia ≥ 1.3) over @async.
    # On older Julia versions, fall back to @async.
    @static if VERSION >= v"1.3"
        macro spawn(expr)
            :(Threads.@spawn $(esc(expr)))
        end
    else
        macro spawn(expr)
            :(@async $(esc(expr)))
        end
    end

    export @spawn
end
