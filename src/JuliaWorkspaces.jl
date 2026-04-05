module JuliaWorkspaces

import UUIDs, JuliaSyntax, TestItemDetection, CSTParser, JSONRPC, Sockets, CancellationTokens
using UUIDs: UUID, uuid4
using JuliaSyntax: SyntaxNode
using Salsa

using AutoHashEquals

include("URIs2/URIs2.jl")

include("SymbolServer/SymbolServer.jl")

include("StaticLint/StaticLint.jl")

include("compat.jl")

import Pkg


import .URIs2
using .URIs2: filepath2uri, uri2filepath

using .URIs2: URI, @uri_str

include("exception_types.jl")
include("../shared/julia_dynamic_analysis_process_protocol.jl")
include("dynamic_feature.jl")
include("types.jl")
include("sourcetext.jl")
include("inputs.jl")
include("layer_files.jl")
include("layer_syntax_trees.jl")
include("layer_includes.jl")
include("layer_static_lint.jl")
include("layer_projects.jl")
include("layer_environment.jl")
include("layer_testitems.jl")
include("layer_diagnostics.jl")
include("layer_hover.jl")
include("layer_completions.jl")
include("layer_references.jl")
include("layer_signatures.jl")
include("layer_symbols.jl")
include("layer_navigation.jl")
include("layer_misc.jl")
include("layer_actions.jl")
include("fileio.jl")
include("public.jl")

end
