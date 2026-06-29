# Launcher seam: turn a worker invocation into the actual command to spawn.
# Default runs on the host; a template wraps it (container/sandbox).

struct LaunchSpec
    cmd::Cmd        # the inner `julia ... worker.jl ...` invocation
    depot::String
    store::String
    env::String
    jwroot::String
end

default_launcher(s::LaunchSpec) = s.cmd

# Split a command string on spaces into argv. Placeholders are substituted first;
# `{cmd}` expands to the inner argv (already split), so wrap the rest plainly.
function template_launcher(template::AbstractString)
    return function (s::LaunchSpec)
        inner = collect(s.cmd.exec)            # Vector{String} argv of the inner cmd
        argv = String[]
        for tok in split(template)
            if tok == "{cmd}"
                append!(argv, inner)
            else
                tok = replace(String(tok),
                    "{depot}" => s.depot,
                    "{store}" => s.store,
                    "{env}" => s.env,
                    "{jwroot}" => s.jwroot)
                push!(argv, tok)
            end
        end
        return Cmd(argv)
    end
end
