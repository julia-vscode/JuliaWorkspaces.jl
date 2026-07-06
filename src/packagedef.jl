include("utils.jl")

include("URIs2/URIs2.jl")

include("SymbolServer/SymbolServer.jl")

include("compat.jl")

import Pkg
import Scratch

import .URIs2
using .URIs2: filepath2uri, uri2filepath

using .URIs2: URI, @uri_str

include("exception_types.jl")
include("../shared/julia_dynamic_analysis_process_protocol.jl")
include("dynamic_feature/dynamic_fsm.jl")
include("dynamic_feature/dynamic_messages.jl")
include("dynamic_feature/dynamic_feature.jl")
include("types.jl")
include("sourcetext.jl")
include("inputs.jl")
include("layer_files.jl")
include("cst_conversion/CSTConversion.jl")
include("layer_syntax_trees.jl")
include("layer_includes.jl")

include("StaticLint/StaticLint.jl")

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
include("layer_formatting.jl")
include("fileio.jl")
include("public.jl")
