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
include("layer_body_tree.jl")

# Vendored JuliaSyntax v2 + JuliaLowering (packages/, see VENDOR_JuliaLowering.md).
# 1.11 cannot load them (`isdefinedglobal` etc.); the lowering layer's queries are
# defined unconditionally with gated bodies.
const LOWERING_AVAILABLE = VERSION >= v"1.12"
@static if VERSION >= v"1.12"
    include("vendor_lowering.jl")
    # Defined here (not in layer_lowering.jl) so they exist BEFORE that file is
    # macro-expanded: its qualified string macros (`JS2.K"..."`) resolve `JS2`
    # at expansion time, and an @static block expands as one unit.
    const JS2 = VendoredLowering.JuliaSyntax
    const JL2 = VendoredLowering.JuliaLowering
    const V2Kind = JS2.Kind
end
include("layer_lowering.jl")

include("layer_visibility.jl")
include("layer_scope_modules.jl")

include("StaticLint/StaticLint.jl")

include("lint_rules.jl")
include("lint_syntax_rules/engine.jl")
include("config_common.jl")
include("lint_emission.jl")

include("layer_file_analysis.jl")
include("layer_static_lint.jl")
include("layer_test_setups.jl")
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
