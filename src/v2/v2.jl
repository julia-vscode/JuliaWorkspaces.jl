# The v2 static analysis framework: a JuliaLowering-backed stack that runs
# alongside StaticLint. Everything under src/v2/ is v2; nothing outside it is.
#
# Inert unless `input_lowering_lint` is true. The complete set of touchpoints
# with the rest of the package:
#   src/inputs.jl            - the `input_lowering_lint` feature flag
#   src/layer_diagnostics.jl - pulls v2 findings in / suppresses StaticLint's
#   src/public.jl            - `set_lowering_lint!`
#   src/packagedef.jl        - the single include of this file

include("layer_body_tree.jl")

# Vendored JuliaSyntax v2 + JuliaLowering (packages/, see VENDOR_JuliaLowering.md).
include("vendor_lowering.jl")
# Defined here (not in layer_lowering.jl) so they exist BEFORE that file is
# macro-expanded: its qualified string macros (`JS2.K"..."`) resolve `JS2` at
# expansion time.
const JS2 = VendoredLowering.JuliaSyntax
const JL2 = VendoredLowering.JuliaLowering
const V2Kind = JS2.Kind
include("layer_lowering.jl")
include("lint_lowering_rules.jl")
