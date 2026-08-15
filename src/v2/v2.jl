# The v2 static analysis framework: a JuliaLowering-backed stack that runs
# alongside StaticLint. Everything under src/v2/ is v2; nothing outside it is.
#
# v2 is CSTParser-free and StaticLint-free by construction: it parses with the
# vendored JuliaSyntax v2, enumerates items with its own walker, and mints its
# own item ids (`V2ItemRef`). The guard testitem in test/v2/test_inventory_v2.jl
# enforces that — if you find yourself reaching for `derived_file_inventory` or
# `CSTParser` from this directory, the layer you need is missing, not optional.
#
# Inert unless `input_lowering_lint` is true. The complete set of touchpoints
# with the rest of the package:
#   src/inputs.jl            - the `input_lowering_lint` feature flag
#   src/layer_diagnostics.jl - pulls v2 findings in / suppresses StaticLint's
#   src/public.jl            - `set_lowering_lint!`
#   src/packagedef.jl        - the single include of this file

# Parser-agnostic foundations, so they come before the vendored parser loads.
# `item_ids.jl` and `macro_tables.jl` are v2's OWN copies of machinery v1 also
# has: the two pipelines share the design, never the code, so that neither
# constrains the other and v1 can eventually be deleted outright.
include("body_tree.jl")
include("item_ids.jl")
include("macro_tables.jl")

# Vendored JuliaSyntax v2 + JuliaLowering (packages/, see VENDOR_JuliaLowering.md).
include("vendor_lowering.jl")
# Defined here (not in the layer files) so they exist BEFORE those files are
# macro-expanded: their qualified string macros (`JS2.K"..."`) resolve `JS2` at
# expansion time.
const JS2 = VendoredLowering.JuliaSyntax
const JL2 = VendoredLowering.JuliaLowering
const V2Kind = JS2.Kind

# Layer 1: the item walker (the v2 id authority), the per-file skeleton, the
# body forest, and the volatile address→range maps — all from ONE parse.
include("layer_inventory_v2.jl")
# Layer 2: module structure spliced from skeletons and include edges.
include("layer_module_tree_v2.jl")
# Layer 3: JuliaLowering binding analysis over per-item body trees.
include("layer_lowering.jl")
# Layer 4: the lint rules that consume it.
include("lint_lowering_rules.jl")
