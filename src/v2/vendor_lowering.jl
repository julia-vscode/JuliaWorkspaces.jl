# Vendored JuliaSyntax v2 + JuliaLowering (see packages/VENDOR_JuliaLowering.md;
# requires Julia >= 1.12, which is JW's minimum).
#
# The vendored files under packages/ are never patched. This wrapper owns all
# deviations. The `JuliaLowering` block below MIRRORS
# packages/JuliaLowering/src/JuliaLowering.jl (SHA b657e6a0d95c) with exactly
# these deviations — keep this list in sync when refreshing the vendored copy:
#   1. `using ..JuliaSyntax` (the vendored sibling below) instead of the
#      upstream `parentmodule === Base ? Base.JuliaSyntax : JuliaSyntax` switch.
#   2. `isdefined` instead of `isdefinedglobal` (identical semantics here).
#   3. `syntax_macros.jl` NOT included: it defines new-style macro methods on
#      Base macro functions (`Base.var"@ccall"` etc.) — method-table additions
#      to Base inside the LS process, and unreachable with macro expansion off.
#   4. `precompile.jl` NOT included (JW's own precompile workload governs) and
#      no `__init__` (a nested module's `__init__` would not run; kind
#      registration at include time is baked into JW's pkgimage, which both
#      modules share).
#   5. `_include` paths point into packages/JuliaLowering/src/.
#   6. `DEBUG = false` (upstream: true): drops @jl_assert bodies, @mknode debug
#      checks and @fzone profiling zones — measurably cheaper precompile and
#      per-item lowering; JW's catch-per-item tolerance covers what asserts
#      would have caught.
module VendoredLowering

# The v2 parser+porcelain. Self-contained (stdlib imports only), so the
# upstream file is included verbatim; it declares `module JuliaSyntax`.
include("../../packages/JuliaSyntax/src/JuliaSyntax.jl")

baremodule JuliaLowering

using Base
# We define a separate _include() for use in this module to avoid mixing method
# tables with the public `JuliaLowering.include()` API
const _include = Base.IncludeInto(JuliaLowering)

using ..JuliaSyntax

using .JuliaSyntax: @KSet_str, @stm, Kind, SourceAttrType, SourceRef,
    SyntaxList, SyntaxTree, byte_range, children, filename, first_byte,
    flattened_provenance, head, highlight,
    is_leaf, is_literal, kind, last_byte, mapchildren, mapsyntax, newleaf,
    newnode, node_string, numchildren, provenance, setmeta, setmeta!, getmeta,
    CompileHints, source_location, sourcefile, sourceref, mapindex, mktree,
    ScopeLayer, SyntaxContext, is_base_layer, base_layer, escape_layer,
    syntax_module, is_flisp_compat, adopt_scope, remove_context, fill_context!,
    fill_context, JL_NEW_SYNTAX_VERSION, JL_OLD_SYNTAX_VERSION

const DEBUG = false

# Falls back to `Union{}` so that `loc isa MacroSource` is always false on Julia < 1.14
# where `Core.MacroSource` is not defined.
const MacroSource = isdefined(Core, :MacroSource) ? Core.MacroSource : Union{}

const TypeEqOf = isdefined(Core, :TypeEqOf) ? "TypeEqOf" : "Typeof"

_include("../../packages/JuliaLowering/src/kinds.jl")
_register_kinds()

_include("../../packages/JuliaLowering/src/ast.jl")
_include("../../packages/JuliaLowering/src/bindings.jl")
_include("../../packages/JuliaLowering/src/utils.jl")
_include("../../packages/JuliaLowering/src/validation.jl")

_include("../../packages/JuliaLowering/src/macro_expansion.jl")
_include("../../packages/JuliaLowering/src/desugaring.jl")
_include("../../packages/JuliaLowering/src/scope_analysis.jl")
_include("../../packages/JuliaLowering/src/binding_analysis.jl")
_include("../../packages/JuliaLowering/src/closure_conversion.jl")
_include("../../packages/JuliaLowering/src/linear_ir.jl")
_include("../../packages/JuliaLowering/src/runtime.jl")

_include("../../packages/JuliaLowering/src/eval.jl")
_include("../../packages/JuliaLowering/src/compat.jl")
_include("../../packages/JuliaLowering/src/hooks.jl")

end # baremodule JuliaLowering

end # module VendoredLowering
