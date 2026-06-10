@testitem "SymbolServer: method_world reads the right field" begin
    using JuliaWorkspaces.SymbolServer: method_world

    m = first(methods(sin))
    w = method_world(m)
    @test w isa Unsigned
    @test w > 0
    @test w < typemax(typeof(w))
end

@testitem "SymbolServer: _samestore matches MethodStores by (file, line, sig)" begin
    using JuliaWorkspaces.SymbolServer: _samestore, MethodStore, FakeTypeName

    sig = Pair{Any,Any}[:x => FakeTypeName(Int)]
    a = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    b = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    c = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(11), sig, Symbol[], FakeTypeName(Any))
    d = MethodStore(:foo, :Mod, "/tmp/other.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    e = MethodStore(:foo, :Mod, "/tmp/foo.jl", Int32(10),
                    Pair{Any,Any}[:x => FakeTypeName(Float64)],
                    Symbol[], FakeTypeName(Any))

    @test _samestore(a, b)
    @test !_samestore(a, c)
    @test !_samestore(a, d)
    @test !_samestore(a, e)

    f = MethodStore(:bar, :Mod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    g = MethodStore(:foo, :OtherMod, "/tmp/foo.jl", Int32(10), sig, Symbol[], FakeTypeName(Any))
    @test _samestore(a, f)
    @test _samestore(a, g)
end

@testitem "SymbolServer: cache_new_methods! captures overloads via world age" begin
    using JuliaWorkspaces.SymbolServer: cache_new_methods!, EnvStore, ModuleStore, VarRef, FunctionStore

    fakemod = Module(:_TestPkgWorldDiff)
    Core.eval(fakemod, :(struct T end))

    w = Base.get_world_counter()
    Core.eval(fakemod, :(Base.length(::T) = 0))

    env = EnvStore()
    name = nameof(fakemod)
    env[name] = ModuleStore(VarRef(fakemod), Dict{Symbol,Any}(),
                            "", true, Symbol[], Symbol[])

    cache_new_methods!(env, w; get_return_type=false)

    @test haskey(env[name], :length)
    entry = env[name][:length]
    @test entry isa FunctionStore
    @test entry.name != entry.extends
    @test entry.extends.name == :length
    @test entry.extends.parent !== nothing
    @test entry.extends.parent.name == :Base
    @test length(entry.methods) == 1
end

@testitem "SymbolServer: cache_methods min_world filter skips pre-existing methods" begin
    using JuliaWorkspaces.SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef,
                                        FunctionStore, method_world

    env = EnvStore()
    env[:Base] = ModuleStore(VarRef(Base), Dict{Symbol,Any}(),
                             "", true, Symbol[], Symbol[])

    w_after_all = maximum(method_world(m) for m in methods(sin))

    cache_methods(sin, :sin, env, false; min_world = w_after_all)

    if haskey(env[:Base], :sin)
        @test isempty(env[:Base][:sin].methods)
    else
        @test !haskey(env[:Base], :sin)
    end
end

@testitem "SymbolServer: get_store captures overloads of foreign functions" begin
    using JuliaWorkspaces.SymbolServer: CacheStore, FunctionStore

    # Drive the indexer (SymbolServer.get_store) in a subprocess against a
    # fixture project with a package that overloads Base.show/Base.length
    # without importing them, plus an own function.
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))
    @test isfile(symbolserver_jl)

    b_uuid = "b8d7f5ca-4a81-4f4a-b8c7-1f4a0d2b3c4e"

    mktempdir() do root
        proj = joinpath(root, "proj")
        bdir = joinpath(root, "B")
        store = joinpath(root, "store")
        mkpath(joinpath(bdir, "src"))
        mkpath(proj)
        mkpath(store)

        write(joinpath(bdir, "Project.toml"), """
        name = "B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)
        write(joinpath(bdir, "src", "B.jl"), """
        module B
        struct BType end
        Base.show(io::IO, ::BType) = print(io, "B")
        Base.show(io::IO, ::MIME"text/plain", ::BType) = print(io, "B (verbose)")
        Base.length(::BType) = 0
        myfunc(x) = x
        end # module B
        """)
        write(joinpath(proj, "Project.toml"), """
        [deps]
        B = "$b_uuid"
        """)
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.B]]
        path = "../B"
        uuid = "$b_uuid"
        version = "0.1.0"
        """)

        runner = joinpath(root, "run_indexer.jl")
        write(runner, """
        include(raw"$symbolserver_jl")
        using Pkg
        Pkg.activate(raw"$proj")
        SymbolServer.get_store(raw"$store", nothing)
        """)

        jl = joinpath(Sys.BINDIR, Base.julia_exename())
        cmd = `$jl --startup-file=no --project=$proj $runner`
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(ignorestatus(cmd))
        end
        @test proc.exitcode == 0

        cache_path = joinpath(store, "B", "B_$b_uuid", "v0.1.0_nothing.jstore")
        @test isfile(cache_path)

        modstore = open(CacheStore.read, cache_path).val

        @test haskey(modstore, :show)
        show_entry = modstore[:show]
        @test show_entry isa FunctionStore
        @test show_entry.name != show_entry.extends
        @test show_entry.extends.name == :show
        @test show_entry.extends.parent !== nothing
        @test show_entry.extends.parent.name == :Base
        @test length(show_entry.methods) >= 2

        @test haskey(modstore, :length)
        length_entry = modstore[:length]
        @test length_entry isa FunctionStore
        @test length_entry.name != length_entry.extends
        @test length_entry.extends.name == :length
        @test length_entry.extends.parent !== nothing
        @test length_entry.extends.parent.name == :Base
        @test length(length_entry.methods) == 1

        @test haskey(modstore, :myfunc)
        myfunc_entry = modstore[:myfunc]
        @test myfunc_entry isa FunctionStore
        @test myfunc_entry.name == myfunc_entry.extends
        @test length(myfunc_entry.methods) == 1
    end
end
