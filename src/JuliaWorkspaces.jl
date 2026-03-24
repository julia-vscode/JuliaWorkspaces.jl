module JuliaWorkspaces

import UUIDs, JuliaSyntax, TestItemDetection
using UUIDs: UUID, uuid4
using JuliaSyntax: @K_str, kind, children, haschildren, first_byte, last_byte, SyntaxNode
using Salsa

using AutoHashEquals
using CancellationTokens

include("packagedef.jl")

end
