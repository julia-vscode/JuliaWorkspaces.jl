include("../../../packages/JSON/src/JSON.jl")
include("../../../packages/CancellationTokens/src/CancellationTokens.jl")
include("../../../packages/TestEnv/src/TestEnv.jl")

@static if VERSION >= v"1.10.0"
    include("../../../packages/CodeTracking/src/CodeTracking.jl")
elseif VERSION >= v"1.6.0"
    include("../../../packages-old/v1.9/CodeTracking/src/CodeTracking.jl")
else
    include("../../../packages-old/v1.5/CodeTracking/src/CodeTracking.jl")
end

module JuliaInterpreter
    using ..CodeTracking

    @static if VERSION >= v"1.10.0"
        include("../../../packages/JuliaInterpreter/src/packagedef.jl")
    elseif VERSION >= v"1.6.0"
        include("../../../packages-old/v1.9/JuliaInterpreter/src/packagedef.jl")
    else
        include("../../../packages-old/v1.5/JuliaInterpreter/src/packagedef.jl")
    end
end

@static if VERSION >= v"1.10.0"
    include("../../../packages/Compiler/src/Compiler.jl")
end

module LoweredCodeUtils
    @static if VERSION >= v"1.10.0"
        using ..CodeTracking: MethodInfoKey

        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame, Interpreter, RecursiveInterpreter
        using ..JuliaInterpreter: codelocation, is_global_ref, is_global_ref_egal, is_quotenode_egal, is_return,
                        lookup, lookup_return, linetable, moduleof, next_until!, nstatements, pc_expr,
                        step_expr!, whichtt, extract_method_table
        using ..Compiler: Compiler as CC

        include("../../../packages/LoweredCodeUtils/src/packagedef.jl")
    elseif VERSION >= v"1.6.0"
        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame
        using ..JuliaInterpreter: @lookup, moduleof, pc_expr, step_expr!, is_global_ref, is_quotenode_egal, whichtt,
            next_until!, finish_and_return!, get_return, nstatements, codelocation, linetable,
            is_return, lookup_return

        include("../../../packages-old/v1.9/LoweredCodeUtils/src/packagedef.jl")
    else
        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame
        using ..JuliaInterpreter: @lookup, moduleof, pc_expr, step_expr!, is_global_ref, is_quotenode, whichtt,
            next_until!, finish_and_return!, get_return, nstatements, codelocation, linetable,
            is_return, lookup_return, is_GotoIfNot, is_ReturnNode

        include("../../../packages-old/v1.5/LoweredCodeUtils/src/packagedef.jl")
    end
end

module Revise
    @static if VERSION >= v"1.10.0"
        using TOML
        using ..OrderedCollections, ..CodeTracking, ..JuliaInterpreter, ..LoweredCodeUtils, ..Preferences

        using ...CodeTracking: PkgFiles, basedir, srcfiles, basepath, MethodInfoKey
        using ...JuliaInterpreter: Compiled, Frame, Interpreter, LineTypes, RecursiveInterpreter
        using ...JuliaInterpreter: codelocs, finish_and_return!, get_return, is_doc_expr, isassign,
                        isidentical, is_quotenode_egal, linetable, lookup, moduleof,
                        pc_expr, scopeof, step_expr!
        using ...LoweredCodeUtils: next_or_nothing!, callee_matches

        include("../../../packages/Revise/src/packagedef.jl")
    elseif VERSION >= v"1.6.0"
        using ..OrderedCollections
        using ..LoweredCodeUtils
        using ..CodeTracking
        using ..JuliaInterpreter
        using ..CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
        using ..JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return,
            @lookup, moduleof, scopeof, pc_expr, is_quotenode_egal,
            linetable, codelocs, LineTypes, isassign, isidentical
        using ..LoweredCodeUtils: next_or_nothing!, trackedheads, callee_matches

        include("../../../packages-old/v1.9/Revise/src/packagedef.jl")
    else
        using ..OrderedCollections
        using ..LoweredCodeUtils
        using ..CodeTracking
        using ..JuliaInterpreter
        using ..CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
        using ..JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return,
            @lookup, moduleof, scopeof, pc_expr, is_quotenode_egal,
            linetable, codelocs, LineTypes, isassign, isidentical
        using ..LoweredCodeUtils: next_or_nothing!, trackedheads, callee_matches

        include("../../../packages-old/v1.5/Revise/src/packagedef.jl")
    end
end

module JSONRPC
import ..CancellationTokens
import ..JSON
import UUIDs
include("../../../packages/JSONRPC/src/packagedef.jl")
end
