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

@testitem "SymbolServer: CacheStore rejects unknown header" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, read

    io = IOBuffer(UInt8[0xff])
    @test_throws CacheCorruptedError read(io)
end

@testitem "SymbolServer: CacheStore rejects truncated stream" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, read

    # SymbolHeader + length=100, but only 5 payload bytes
    io = IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(100)]), UInt8[0x41, 0x41, 0x41, 0x41, 0x41]))
    @test_throws CacheCorruptedError read(io)

    @test_throws CacheCorruptedError read(IOBuffer(UInt8[]))

    @test_throws CacheCorruptedError read(IOBuffer(UInt8[0x02, 0x00, 0x00]))
end

@testitem "SymbolServer: CacheStore rejects oversized length fields" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, read

    huge = Int(10)^15
    @test_throws CacheCorruptedError read(IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [huge]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(UInt8[0x02], reinterpret(UInt8, [Int(-1)]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(UInt8[0x05], reinterpret(UInt8, [huge]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(UInt8[0x14], reinterpret(UInt8, [huge]))))
end

@testitem "SymbolServer: CacheStore rejects cyclic data on write" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: write
    using JuliaWorkspaces.SymbolServer: VarRef, FakeTypeName

    name = VarRef(nothing, :A)
    ft = FakeTypeName(name, Any[])
    push!(ft.parameters, ft)        # cycle: ft.parameters[1] === ft

    @test_throws ArgumentError write(IOBuffer(), ft)

    deep = let d = FakeTypeName(name, Any[])
        for _ in 1:300
            d = FakeTypeName(name, Any[d])
        end
        d
    end
    @test_throws ArgumentError write(IOBuffer(), deep)
end

@testitem "SymbolServer: CacheStore rejects deeply nested input on read" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, read

    # Hand-build `level` nested FakeTypeName encodings. Each level is:
    # FakeTypeNameHeader (0x07), name VarRef(nothing, :a), then a parameters
    # vector of length 1 (or 0 for the innermost).
    function nested_bytes(level::Int)
        io = IOBuffer()
        Base.write(io, 0x07)
        Base.write(io, 0x06); Base.write(io, 0x01)
        Base.write(io, 0x02); Base.write(io, Int(1)); Base.write(io, 0x61)
        Base.write(io, Int(0))
        bytes = take!(io)
        for _ in 1:level
            io = IOBuffer()
            Base.write(io, 0x07)
            Base.write(io, 0x06); Base.write(io, 0x01)
            Base.write(io, 0x02); Base.write(io, Int(1)); Base.write(io, 0x61)
            Base.write(io, Int(1))
            Base.write(io, bytes)
            bytes = take!(io)
        end
        return bytes
    end

    @test_throws CacheCorruptedError read(IOBuffer(nested_bytes(300)))
    read(IOBuffer(nested_bytes(100)))   # under MAX_DEPTH, no throw
end

@testitem "SymbolServer: corrupt cache file produces CacheCorruptedError" begin
    mktempdir() do store_path
        pkg_dir = joinpath(store_path, "Bogus", "Bogus_00000000-0000-0000-0000-000000000000")
        mkpath(pkg_dir)
        cache_path = joinpath(pkg_dir, "v0.1.0_nothing.jstore")
        open(cache_path, "w") do io
            Base.write(io, UInt8[0xff])
        end

        threw = false
        try
            open(JuliaWorkspaces.SymbolServer.CacheStore.read, cache_path)
        catch err
            threw = err isa JuliaWorkspaces.SymbolServer.CacheStore.CacheCorruptedError
        end
        @test threw
    end
end

@testitem "SymbolServer: length validation accepts valid lengths over IOStream buffer chunk" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: read

    mktemp() do path, io
        Base.write(io, 0x05)            # StringHeader
        Base.write(io, Int(30))
        Base.write(io, repeat("a", 30))
        close(io)

        @test open(read, path) == repeat("a", 30)
    end
end
