include("../../../packages/JSON/src/JSON.jl")
include("../../../packages/CancellationTokens/src/CancellationTokens.jl")
include("../../../packages/TestEnv/src/TestEnv.jl")

include("../../../packages/Preferences/src/Preferences.jl")

include("../../../packages/OrderedCollections/src/OrderedCollections.jl")

include("../../../packages/CodeTracking/src/CodeTracking.jl")

module JuliaInterpreter
    using ..CodeTracking

    include("../../../packages/JuliaInterpreter/src/packagedef.jl")
end

include("../../../packages/Compiler/src/Compiler.jl")

module LoweredCodeUtils
    using ..CodeTracking: MethodInfoKey

    using ..JuliaInterpreter
    using ..JuliaInterpreter: SSAValue, SlotNumber, Frame, Interpreter, RecursiveInterpreter
    using ..JuliaInterpreter: codelocation, is_global_ref, is_global_ref_egal, is_quotenode_egal, is_return,
                    lookup, lookup_return, linetable, moduleof, next_until!, nstatements, pc_expr,
                    step_expr!, whichtt, extract_method_table
    using ..Compiler: Compiler as CC

    include("../../../packages/LoweredCodeUtils/src/packagedef.jl")
end

module Revise
    using TOML
    using ..OrderedCollections, ..CodeTracking, ..JuliaInterpreter, ..LoweredCodeUtils, ..Preferences

    using ...CodeTracking: PkgFiles, basedir, srcfiles, basepath, MethodInfoKey
    using ...JuliaInterpreter: Compiled, Frame, Interpreter, LineTypes, RecursiveInterpreter
    using ...JuliaInterpreter: codelocs, finish_and_return!, get_return, is_doc_expr, isassign,
                    isidentical, is_quotenode_egal, linetable, lookup, moduleof,
                    pc_expr, scopeof, step_expr!
    using ...LoweredCodeUtils: next_or_nothing!, callee_matches

    include("../../../packages/Revise/src/packagedef.jl")
end

module JSONRPC
    import ..CancellationTokens
    import ..JSON
    import UUIDs, Sockets
    include("../../../packages/JSONRPC/src/packagedef.jl")
end
