struct DynamicJuliaProcess
    project::String
    proc::Union{Nothing, Base.Process}

    function DynamicJuliaProcess(project::String)
        return new(
            project,
            nothing
        )
    end
end

function Base.start(djp::DynamicJuliaProcess)
end

function Base.kill(djp::DynamicJuliaProcess)
end

struct DynamicFeature
    in_channel::Channel{Any}
    out_channel::Channel{Any}
    procs::Dict{String,DynamicJuliaProcess}

    function DynamicFeature()
        return new(
            Channel{Any}(Inf),
            Channel{Any}(Inf),
            Dict{String,DynamicJuliaProcess}()
        )
    end
end

function Base.start(df::DynamicFeature)
    Threads.@async begin
        while true
            msg = take!(df.in_channel)

            if msg.command == :set_environments
                # Delete Julia procs we no longer need
                foreach(setdiff(keys(df.procs), msg.environments)) do i
                    kill(procs[i])
                    delete!(df.procs, i)
                end

                # Add new required procs
                foreach(msg.environments, setdiff(keys(df.procs), )) do i
                    djp = DynamicJuliaProcess(i)
                    df.procs[i] = djp
                    start(djp)
                end
            else
                error("Unknown message: $msg")
            end
        end
    end
end
