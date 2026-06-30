module CloudIndexApp

import Pkg
using Base: UUID

include("CloudIndex/registry.jl")
include("CloudIndex/filters.jl")
include("CloudIndex/cache_state.jl")
include("CloudIndex/launcher.jl")
include("CloudIndex/driver.jl")
include("CloudIndex/cli.jl")
include("CloudIndex/index.jl")

function (@main)(ARGS)
    return cli_main(collect(String, ARGS))
end

end
