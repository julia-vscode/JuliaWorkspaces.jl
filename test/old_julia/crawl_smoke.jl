# Smoke test for the shared symbol server code, and the dynamic analysis process's own
# sources, on old Julia versions.
#
# `shared/symbolserver/` is also loaded by the dynamic analysis process, which runs on
# every Julia back to 1.0, but the main test suite only runs on modern Julia. This script
# loads the shared files the way `JuliaDynamicAnalysisProcess/src/symbolserver.jl` does,
# runs the same getenvtree/symbols/cache_new_methods! pipeline over Core, Base and a
# stdlib, checks that name enumeration sees every name `names` reports (a wrong-arity
# `jl_module_names` ccall silently truncates that list), and round-trips the result
# through the cache file writer and reader. It also parses every source file of the
# process package and exercises its Base-only helpers.
#
# Run with `julia test/old_julia/crawl_smoke.jl`. Keep it runnable on Julia 1.0: no
# keyword shorthand, no `isnothing`, no `@something`, etc.

module SymbolServer

using Pkg, SHA
using Base: UUID
using REPL

const SHARED = joinpath(@__DIR__, "..", "..", "shared", "symbolserver")
include(joinpath(SHARED, "faketypes.jl"))
include(joinpath(SHARED, "symbols.jl"))
include(joinpath(SHARED, "utils.jl"))
include(joinpath(SHARED, "serialize.jl"))
using .CacheStore

end

# The process package's helpers that need only Base, loaded as the package does.
module ChildHelpers
const CHILD_SRC = joinpath(@__DIR__, "..", "..", "juliadynamicanalysisprocess", "JuliaDynamicAnalysisProcess", "src")
include(joinpath(CHILD_SRC, "workspace_members.jl"))
include(joinpath(CHILD_SRC, "expansion_text.jl"))
end

using .SymbolServer: unsorted_names, symbols, getenvtree, getallns, cache_new_methods!,
    write_cache_atomic, ModuleStore, Package, CacheStore
using LinearAlgebra
using Test

@testset "shared symbol server on Julia $VERSION" begin
    @testset "unsorted_names agrees with names" begin
        for m in (Core, Base, LinearAlgebra)
            @test sort(unsorted_names(m, all=true, imported=true)) == sort(names(m, all=true, imported=true))
            @test sort(unsorted_names(m, all=true)) == sort(names(m, all=true))
            @test sort(unsorted_names(m)) == sort(names(m))
        end
    end

    # The analysis process pipeline (`get_store`), minus package loading. It skips Core
    # and Base there because the language server ships those; crawl them here anyway,
    # since they exercise far more of the code.
    world_before = SymbolServer.get_world_counter()
    env = getenvtree()
    symbols(env, nothing, getallns(), Base.IdSet{Module}())
    cache_new_methods!(env, world_before; get_return_type=false)

    @testset "crawl" begin
        for m in (:Core, :Base, :LinearAlgebra)
            @test env[m] isa ModuleStore
        end
        @test env[:Base][:MainInclude] isa ModuleStore
        @test haskey(env[:Base], :sin)
        @test haskey(env[:Base], :Dict)
        @test haskey(env[:LinearAlgebra], :norm)
        @test env[:LinearAlgebra][:BLAS] isa ModuleStore
        @test Set(env[:LinearAlgebra].publicnames) == Set(names(LinearAlgebra))
        @test issubset(env[:LinearAlgebra].exportednames, env[:LinearAlgebra].publicnames)
    end

    @testset "cache file round-trip" begin
        dir = mktempdir()
        for m in (:Core, :Base, :LinearAlgebra)
            store = env[m]
            path = write_cache_atomic(Package(String(m), store, Base.UUID(UInt128(1)), nothing), joinpath(dir, "$m.jstore"))
            back = open(CacheStore.read, path)
            @test back isa Package
            @test back.name == String(m)
            @test Set(keys(back.val.vals)) == Set(keys(store.vals))
            @test Set(back.val.exportednames) == Set(store.exportednames)
        end
    end

    @testset "overloads added after a method lookup are found" begin
        # Warm `methodinfo`'s cache first, as the crawl does before packages load.
        SymbolServer.methodlist(Base.show)
        w = SymbolServer.get_world_counter()
        pkg = Core.eval(Main, :(module SmokePkg
            struct Widget end
            Base.show(io::IO, ::Widget) = print(io, "Widget")
        end))
        penv = Dict{Symbol,ModuleStore}(:SmokePkg => ModuleStore(pkg))
        Base.invokelatest(cache_new_methods!, penv, w)
        @test haskey(penv[:SmokePkg], :show)
    end

    println("Julia $VERSION: crawled ", length(env[:Core].vals), " Core, ",
            length(env[:Base].vals), " Base, ", length(env[:LinearAlgebra].vals),
            " LinearAlgebra entries; names(all=true): ", length(names(Core, all=true)), " Core, ",
            length(names(Base, all=true)), " Base, ", length(names(LinearAlgebra, all=true)), " LinearAlgebra")
end

# Every file of the process package is parsed on every Julia the process runs on, even
# the parts that only run on newer ones.
function parses_cleanly(path)
    src = read(path, String)
    pos = 1
    while pos <= ncodeunits(src)
        ex, pos = try
            Meta.parse(src, pos)
        catch
            return false
        end
        ex isa Expr && (ex.head === :error || ex.head === :incomplete) && return false
    end
    return true
end

@testset "dynamic analysis process sources on Julia $VERSION" begin
    child_files = [joinpath(ChildHelpers.CHILD_SRC, f) for f in readdir(ChildHelpers.CHILD_SRC) if endswith(f, ".jl")]
    push!(child_files, joinpath(@__DIR__, "..", "..", "shared", "julia_dynamic_analysis_process_protocol.jl"))
    for path in child_files
        @test parses_cleanly(path)
    end

    @test ChildHelpers._bare_import_name("using Foo") == "Foo"
    @test ChildHelpers._bare_import_name("using Foo: bar") === nothing

    expanded = ChildHelpers._expand_fully(Main, :(@assert x > 0))
    @test expanded isa Expr
    @test !occursin("\$(Expr", string(expanded))
    @test ChildHelpers._surface_form(Expr(:isdefined, :x)) == Expr(:macrocall, Symbol("@isdefined"), nothing, :x)

    scratch = Module(:SmokeScratch)
    ChildHelpers._bind_real_macros!(scratch, Base)
    @test isdefined(scratch, Symbol("@assert"))
end
