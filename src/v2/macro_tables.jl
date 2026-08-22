# Macro-effect tables for the v2 item walker.
#
# The walker cannot expand macros, so for every top-level macrocall it has to
# answer one question: might this expansion define names the walk would
# otherwise miss? "No" lets the walk stay sighted; "yes" records the macrocall
# in `opaque_macros`, which marks the enclosing module blind in the same way a
# wildcard `using` does.
#
# Curated because resolution can say where a macro comes from, never what it
# expands to. Membership is tested by NAME, which is the weaker but necessary
# choice: a user macro shadowing `@inline` or `@show` buys the same treatment.
# Identity could rule that out for a resolving caller but not for a syntax-only
# walk — and only ever as a disqualifier, since an unresolved name must keep its
# name verdict, or the verdict would flip as indexing completes.
#
# SEEDED FROM StaticLint's `EFFECT_FREE_MACROS`/`HANDLED_MACROS` as of the commit
# that introduced this file, and then owned outright by v2. Divergence is
# EXPECTED, not drift to be policed: once v2 expands macros for real through
# JuliaLowering, most of `V2_EFFECT_FREE_MACROS` stops being a special case at
# all. Do not add a test pinning these lists to StaticLint's — that would
# recreate the coupling this file exists to avoid.
#
# Names are stored WITH the leading `@`, matching what `_v2_macro_name` and
# `_v2_node_macro_name` read off the EST. (`TRANSPARENT_MACRO_NAMES` and
# `TEST_BLOCK_MACRO_NAMES` in layer_lowering.jl use the opposite convention —
# they strip it — because they match on the trailing name of a possibly-qualified
# call.)

"Macros that introduce no names: their expansion defines nothing the walk would miss."
const V2_EFFECT_FREE_MACROS = Set{String}([
    # Base/Core annotations & wrappers
    "@inline", "@noinline", "@propagate_inbounds", "@generated",
    "@assume_effects", "@constprop", "@pure", "@nospecializeinfer",
    "@specialize", "@polly", "@inbounds", "@boundscheck", "@fastmath",
    "@simd", "@views", "@view", "@static", "@compat", "@doc", "@main",
    "@kwdef", "@.", "@__dot__", "@ccall", "@cfunction", "@ccallable",
    # logging / diagnostics / timing
    "@assert", "@show", "@info", "@warn", "@error", "@debug", "@logmsg",
    "@time", "@timed", "@timev", "@elapsed", "@allocated", "@allocations",
    "@profile",
    # concurrency / atomics
    "@threads", "@spawn", "@async", "@sync", "@lock",
    "@atomic", "@atomicswap", "@atomicreplace", "@atomiconce",
    # value-producing
    "@isdefined", "@__MODULE__", "@__FILE__", "@__DIR__", "@__LINE__",
    "@__FUNCTION__", "@ntuple", "@something", "@coalesce", "@invoke",
    "@invokelatest", "@macroexpand", "@macroexpand1",
    # Printf
    "@printf", "@sprintf",
    # Test / SafeTestsets / JET
    "@test", "@testset", "@test_throws", "@test_broken", "@test_skip",
    "@test_logs", "@test_deprecated", "@test_warn", "@test_nowarn",
    "@inferred", "@safetestset", "@test_opt", "@test_call",
    # common effect-free ecosystem macros
    "@load_preference", "@has_preference", "@set_preferences!",
    "@delete_preferences!", "@get_scratch!",
    "@setup_workload", "@compile_workload",
    "@muladd", "@turbo", "@tturbo",
])

"""
Macros with name-introducing effects that the analyzer models. Kept separate
from [`V2_EFFECT_FREE_MACROS`](@ref) because the two answer different questions
— "defines nothing" versus "defines something we already handle" — and only
their union makes a macrocall safe to walk transparently.
"""
const V2_HANDLED_MACROS = Set{String}([
    "@deprecate", "@deprecate_binding", "@eval", "@irrational", "@enum",
    "@goto", "@label", "@NamedTuple", "@reexport", "@nospecialize",
    "@testitem", "@testmodule", "@testsnippet",
    "@variables", "@parameters", "@constants",
    "@declare_input",
])

"""
Macros that pass the signature of a wrapped method definition through unchanged,
so its written arity is the real arity. Any OTHER macro wrapper may rewrite the
signature (`@kwdef` adds a keyword constructor, DSL macros do anything), which
makes the wrapped definition's arity permissive-anything — v1's `func_nargs`
early return, keyed there by resolving the macro to Base and here by name (the
same weaker-but-necessary choice the tables above make). Seeded from
StaticLint's `SIGNATURE_PRESERVING_MACROS`, then owned by v2.
"""
const V2_SIGNATURE_PRESERVING_MACROS = Set{String}([
    "@inline", "@noinline", "@propagate_inbounds", "@generated",
    "@assume_effects", "@constprop", "@pure", "@nospecializeinfer",
])

"""
    _v2_macro_name_effects_known(name) -> Bool

Whether a macrocall spelled `name` (with its leading `@`) can be assumed not to
define names the walk would otherwise miss. `false` means "this macrocall may
define anything", which makes the enclosing module blind.
"""
function _v2_macro_name_effects_known(name)
    name isa AbstractString || return false
    name in V2_EFFECT_FREE_MACROS && return true
    name in V2_HANDLED_MACROS && return true
    # String/cmd macros produce values by strong convention.
    (endswith(name, "_str") || endswith(name, "_cmd")) && return true
    return false
end
