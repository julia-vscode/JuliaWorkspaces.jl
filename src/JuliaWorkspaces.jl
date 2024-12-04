module JuliaWorkspaces

import UUIDs, JuliaSyntax, TestItemDetection
using UUIDs: UUID, uuid4
using JuliaSyntax: SyntaxNode
using Salsa
using Documenter, DocStringExtensions

using AutoHashEquals

include("compat.jl")

import Pkg

include("URIs2/URIs2.jl")
import .URIs2
using .URIs2: filepath2uri, uri2filepath

using .URIs2: URI, @uri_str

include("exception_types.jl")
include("types.jl")
include("sourcetext.jl")
include("inputs.jl")
include("layer_files.jl")
include("layer_syntax_trees.jl")
include("layer_projects.jl")
include("layer_testitems.jl")
include("layer_diagnostics.jl")
include("fileio.jl")
include("public.jl")

end
