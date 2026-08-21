include("utils.jl")

include("URIs2/URIs2.jl")

include("SymbolServer/SymbolServer.jl")

include("compat.jl")

import Pkg

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
include("layer_syntax_trees.jl")
include("layer_includes.jl")
include("layer_inventory.jl")
include("layer_module_tree.jl")
include("v2/v2.jl")
include("layer_visibility.jl")
include("layer_scope_modules.jl")

include("StaticLint/StaticLint.jl")

include("lint_rules.jl")
include("lint_syntax_rules/engine.jl")
include("layer_parse_products.jl")
include("config_common.jl")
include("lint_emission.jl")

include("layer_file_analysis.jl")
include("layer_static_lint.jl")
include("layer_test_setups.jl")
include("layer_projects.jl")
include("layer_environment.jl")
# The v2 stack's ONLY contact with the environment stores; outside src/v2/
# because the store walk needs StaticLint/SymbolServer names the v2 boundary
# guard forbids (see the file header).
include("layer_v2_env_seam.jl")
include("layer_testitems.jl")
include("layer_diagnostics.jl")
include("layer_hover.jl")
include("layer_completions.jl")
include("layer_references.jl")
include("layer_signatures.jl")
include("layer_symbols.jl")
include("layer_navigation.jl")
include("layer_misc.jl")
# v2-backed interactive features (behind `input_v2_features`); outside src/v2/
# because it joins v2 data with feature result structs and v1 fallback paths.
include("layer_features_v2.jl")
include("layer_actions.jl")
include("layer_formatting.jl")
include("fileio.jl")
include("public.jl")
