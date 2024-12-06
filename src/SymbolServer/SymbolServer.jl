module SymbolServer

import Pkg, InteractiveUtils, UUIDs

using UUIDs: UUID

include("faketypes.jl")
include("symbols.jl")
include("utils.jl")
include("serialize.jl")

using .CacheStore

end
