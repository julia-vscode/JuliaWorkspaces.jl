@testitem "SymbolServer: Core-in-Base re-exports resolve (invokelatest; julia#60046)" begin
    using JuliaWorkspaces.SymbolServer: getenvtree, symbols, _lookup, VarRef,
        FunctionStore, DataTypeStore

    # Build the Base/Core stores with the *live* crawler. We call getenvtree/symbols
    # directly rather than reading the module-level `stdlibs` const, because that
    # const is baked at precompile time; exercising the crawler is what actually
    # verifies the current symbols.jl code path.
    env = getenvtree([:Base, :Core])
    symbols(env)
    base = env[:Base]

    # On 1.12 `names(Base)` spuriously lists Core-owned bindings (JuliaLang/julia#60046).
    # `invokelatest` is owned by Core and NOT exported by Core. With no Core-in-Base
    # filter, it falls through the re-export branches and is aliased into Base as a
    # cheap VarRef to Core; it must be present, stay exported from Base, and resolve
    # to Core's function. (Before removing the filter this name was dropped entirely
    # and never resolved — the bug this guards against.)
    @test haskey(base.vals, :invokelatest)
    @test :invokelatest in base.exportednames
    entry = base.vals[:invokelatest]
    if entry isa VarRef
        # On 1.12 it's a cheap VarRef alias into Core (not a duplicated store).
        @test _lookup(entry, env, true) isa FunctionStore
    else
        @test entry isa FunctionStore
    end

    # A representative Core-exported re-export must still resolve (no regression).
    @test haskey(base.vals, :Bool)

    # Note: with the Core-in-Base filter removed wholesale, Core type aliases
    # (`Memory`, `MemoryRef`, `Cvoid`, ...) are duplicated into Base as full
    # DataTypeStores via the shadow-rename branch. That redundant duplication is
    # an accepted tradeoff of the simpler filter-free crawler, so we deliberately
    # do NOT assert against it here.
end

@testitem "SymbolServer: Core-level intrinsics forward to Core.Intrinsics" begin
    using JuliaWorkspaces.SymbolServer: load_core, _lookup, VarRef, FunctionStore

    # Exercise the *live* crawler (via load_core), not the baked `stdlibs` const.
    # Intrinsics report `parentmodule(x) === Core` even though they live in
    # `Core.Intrinsics`. Pre-fix the own-function test misclassified a Core-level
    # intrinsic (e.g. `Core.add_int`) as Core-owned and emitted a duplicate,
    # 0-method `FunctionStore` in `cache[:Core]`. The fix classifies an intrinsic
    # as "own" only at `Core.Intrinsics`, so accessed off `Core` it forwards to
    # `VarRef(VarRef(Core.Intrinsics), name)` which resolves to the owned store
    # (holding the synthetic intrinsic method).
    env = load_core()
    core = env[:Core]
    intrinsics = env[:Core][:Intrinsics]

    # Every intrinsic reachable as `Core.<name>` (parentmodule === Core) must, in
    # `cache[:Core]`, be a VarRef forwarding to the Core.Intrinsics store that
    # carries the method — NOT a 0-method own FunctionStore.
    core_level = Symbol[]
    for n in names(Core.Intrinsics; all = true)
        isdefined(Core.Intrinsics, n) || continue
        getglobal(Core.Intrinsics, n) isa Core.IntrinsicFunction || continue
        (isdefined(Core, n) && getglobal(Core, n) isa Core.IntrinsicFunction) || continue
        push!(core_level, n)
    end
    @test !isempty(core_level)   # there are Core-level-accessible intrinsics
    for s in core_level
        entry = core.vals[s]
        @test entry isa VarRef                      # forwarded, not an own store
        resolved = _lookup(entry, env, true)
        @test resolved isa FunctionStore
        @test length(resolved.methods) >= 1         # resolves to the store WITH the method
        @test resolved === intrinsics.vals[s]       # specifically the Core.Intrinsics-owned store
    end

    # Spot-check the two previously hardcoded names still work purely from the crawl.
    for s in (:add_int, :sle_int)
        @test s in core_level
        @test core.vals[s] isa VarRef
    end

    # No regression: the Core.Intrinsics-owned store itself is a real FunctionStore
    # with its method (not turned into a VarRef).
    @test intrinsics.vals[:add_int] isa FunctionStore
    @test length(intrinsics.vals[:add_int].methods) >= 1
end

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

@testitem "SymbolServer: cache_methods follows VarRef-aliased module entries" begin
    using JuliaWorkspaces.SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef, FunctionStore

    # A method whose defining (sub)module is recorded in the env as a VarRef alias
    # (e.g. a re-exported/used submodule) used to crash cache_methods with
    # `MethodError: haskey(::VarRef, ::Symbol)`. It must now resolve through the
    # alias to the real ModuleStore (regression for the registry-sweep failures).
    root = Module(:_VRefAliasRoot)
    Core.eval(root, :(module Sub; struct T end; foo(::T) = 1; end))
    sub = root.Sub

    env = EnvStore()
    target = ModuleStore(VarRef(sub), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
    env[nameof(root)] = ModuleStore(VarRef(root),
        Dict{Symbol,Any}(:Sub => VarRef(nothing, :_VRefAliasDest)), "", true, Symbol[], Symbol[])
    env[:_VRefAliasDest] = target   # Sub's entry is a VarRef alias pointing here

    cache_methods(sub.foo, :foo, env, false)   # must not throw

    @test haskey(target, :foo)
    @test target[:foo] isa FunctionStore
    @test length(target[:foo].methods) == 1
end

@testitem "SymbolServer: _lookup breaks cyclic VarRef alias chains" begin
    using JuliaWorkspaces.SymbolServer: _lookup, EnvStore, ModuleStore, VarRef

    # `_lookup(..., true)` follows VarRef aliases. A malformed store with a cyclic
    # alias chain (Top.A -> Top.B -> Top.A) used to recurse to a StackOverflowError
    # (regression for KrylovPreconditioners@0.2.3/0.3.8 in the registry sweep). It
    # must now terminate with `nothing` while normal aliases still resolve.
    env = EnvStore()
    top = ModuleStore(VarRef(nothing, :Top), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
    top.vals[:A] = VarRef(VarRef(nothing, :Top), :B)
    top.vals[:B] = VarRef(VarRef(nothing, :Top), :A)   # cycle back to A
    m = ModuleStore(VarRef(nothing, :M), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
    top.vals[:M] = m
    top.vals[:C] = VarRef(VarRef(nothing, :Top), :M)   # plain alias to a ModuleStore
    env[:Top] = top

    @test _lookup(VarRef(VarRef(nothing, :Top), :A), env, true) === nothing   # no StackOverflow
    @test _lookup(VarRef(VarRef(nothing, :Top), :C), env, true) === m         # alias still resolves
    # cont=false never follows aliases: returns the VarRef as-is.
    @test _lookup(VarRef(VarRef(nothing, :Top), :C), env, false) isa VarRef
end

@testitem "SymbolServer: _try_getglobal skips bindings whose getglobal throws" begin
    using JuliaWorkspaces.SymbolServer: _try_getglobal

    # On Julia 1.12, a name brought in by `using` that is also a Base binding is
    # ambiguous: it shows up in `names(...; usings=true)` but `getglobal` throws
    # UndefVarError. That throw used to abort indexing the whole package (the
    # registry sweep's dominant `UndefVarError` failures: CSV.Lockable,
    # HTTP.WebSockets.readuntil, ...). `_try_getglobal` swallows it.
    m = Module(:SSTryGetglobalTest)
    Core.eval(m, :(module A; export stack; stack() = 1; end))
    Core.eval(m, :(module C; using ..A; end))   # C.stack ambiguous with Base.stack
    C = invokelatest(getglobal, m, :C)
    A = invokelatest(getglobal, m, :A)

    @test_throws UndefVarError invokelatest(getglobal, C, :stack)   # the underlying failure
    @test _try_getglobal(C, :stack) === (false, nothing)           # ...is swallowed
    @test _try_getglobal(A, :stack)[1] === true                    # normal binding resolves
    @test _try_getglobal(A, :nope) === (false, nothing)            # missing name too
end

@testitem "SymbolServer: _isdefinedglobal reports ambiguous using-bindings as undefined" begin
    using JuliaWorkspaces.SymbolServer: _isdefinedglobal

    m = Module(:SSIsDefGlobalTest)
    Core.eval(m, :(module A; export stack; stack() = 1; end))
    Core.eval(m, :(module C; using ..A; end))   # C.stack ambiguous with Base.stack
    C = invokelatest(getglobal, m, :C)
    A = invokelatest(getglobal, m, :A)

    @test _isdefinedglobal(A, :stack)            # real binding
    @test !_isdefinedglobal(A, :nope)            # missing name
    # On 1.12+ the guard skips the ambiguous binding before any access throws.
    @static if isdefined(Base, :isdefinedglobal)
        @test !_isdefinedglobal(C, :stack)
    end
end

@testitem "SymbolServer: #295 cache_methods handles Vararg{T,N} signatures" begin
    using JuliaWorkspaces.SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef,
                                        FunctionStore, FakeTypeName

    # Julia normalises bounded `Vararg{T,N}` out of the method's tuple sig:
    # N=0 drops the slot entirely (used to BoundsError), and N>1 expands into
    # N copies of T (used to be silently truncated to one slot).
    fakemod = Module(:_TestPkgVararg)
    Core.eval(fakemod, quote
        f0(x::Vararg{Int,0})         = x
        f1(x::Vararg{Int,1})         = x
        f3(x::Vararg{Int,3})         = x
        fu(x::Vararg{Int})           = x
        h(x::Int, y::Vararg{Int,2})  = (x, y)
    end)

    env = EnvStore()
    name = nameof(fakemod)
    env[name] = ModuleStore(VarRef(fakemod), Dict{Symbol,Any}(),
                            "", true, Symbol[], Symbol[])

    for sym in (:f0, :f1, :f3, :fu, :h)
        cache_methods(Core.eval(fakemod, sym), sym, env, false)
        @test haskey(env[name], sym)
        @test env[name][sym] isa FunctionStore
    end

    # Vararg{Int,0}: the slot has no positional type info — sig is empty.
    @test isempty(env[name][:f0].methods[1].sig)

    # Vararg{Int,1}: single slot reconstructed as Vararg{Int,1}.
    sig1 = env[name][:f1].methods[1].sig
    @test length(sig1) == 1
    @test first(sig1).first == :x
    @test first(sig1).second == FakeTypeName(Vararg{Int,1})

    # Vararg{Int,3}: reconstructed as Vararg{Int,3} (previously truncated to one slot).
    sig3 = env[name][:f3].methods[1].sig
    @test length(sig3) == 1
    @test first(sig3).second == FakeTypeName(Vararg{Int,3})

    # Unbounded `Vararg{Int}` survives in the tuple as-is and must round-trip.
    sigu = env[name][:fu].methods[1].sig
    @test length(sigu) == 1
    @test first(sigu).second == FakeTypeName(Vararg{Int})

    # Fixed prefix + Vararg{T,N}: prefix recorded normally, vararg reconstructed.
    sigh = env[name][:h].methods[1].sig
    @test length(sigh) == 2
    @test sigh[1] == (:x => FakeTypeName(Int))
    @test sigh[2].first == :y
    @test sigh[2].second == FakeTypeName(Vararg{Int,2})
end

@testitem "SymbolServer: #319 cache_methods handles non-Function callables" begin
    using JuliaWorkspaces.SymbolServer: cache_methods, EnvStore, ModuleStore, VarRef, FunctionStore

    # A callable struct instance (e.g. SymbolicUtils.BasicSymbolic reaching
    # cache_new_methods! while indexing AbstractAlgebra) has no
    # `parentmodule(::Callable)` method and used to crash cache_methods.
    fakemod = Module(:_TestPkgCallable)
    Core.eval(fakemod, quote
        struct Callable end
        (::Callable)(x::Number) = x + 1
    end)
    f = Core.eval(fakemod, :(Callable()))

    env = EnvStore()
    name = nameof(fakemod)
    env[name] = ModuleStore(VarRef(fakemod), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])

    ms = cache_methods(f, :callable, env, false)   # must not throw
    @test length(ms) == 1
    @test haskey(env[name], :callable)
    @test env[name][:callable] isa FunctionStore
    @test length(env[name][:callable].methods) == 1
    # extends resolves to the type's module
    @test env[name][:callable].extends.parent.name == name
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
        "Docstring for myfunc."
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

        cache_path = joinpath(store, "B", "B", b_uuid, "0.1.0.jstore")
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
        # Docstrings must be captured (requires `using REPL` for parsedoc on 1.11+).
        @test !isempty(myfunc_entry.doc)
    end
end

@testitem "SymbolServer: #1395 DataTypeStore field types are serializable and aligned" begin
    using JuliaWorkspaces.SymbolServer: DataTypeStore, FakeTypeName, MethodStore
    using JuliaWorkspaces.SymbolServer.CacheStore: write, read

    for T in (MethodStore, DataTypeStore, Pair{Int,String}, Dict{Symbol,Any})
        ur = Base.unwrap_unionall(T)
        d = DataTypeStore(T, nameof(ur), @__MODULE__, false)
        @test length(d.types) == length(d.fieldnames) == fieldcount(ur)
        @test !any(t -> t isa Type, d.types)        # no raw types leaked in
        io = IOBuffer(); write(io, d); seekstart(io); read(io)   # must round-trip
    end

    # fieldtypes shorter than fieldnames -> padded with FakeTypeName(Any), not raw `Any`.
    dts = DataTypeStore(
        FakeTypeName(Int), FakeTypeName(Integer),
        Any[],                  # parameters
        Any[],                  # fieldtypes
        Any[:a, :b],            # fieldnames
        MethodStore[], "", false,
    )
    @test length(dts.types) == 2
    @test all(t -> t isa FakeTypeName, dts.types)
    io = IOBuffer(); write(io, dts); seekstart(io)
    back = read(io)
    @test length(back.types) == 2
    @test back.fieldnames == [:a, :b]
end

@testitem "SymbolServer: CacheStore validates file header" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read, write
    using JuliaWorkspaces.SymbolServer: VarRef

    io = IOBuffer()
    write(io, VarRef(nothing, :foo))
    seekstart(io)
    @test MagicHeader == Base.read(io, length(MagicHeader))
    @test StoreVersion == Base.read(io, length(StoreVersion))

    @test_throws CacheCorruptedError read(IOBuffer(vcat(UInt8[0x00], StoreVersion)))   # bad magic
    @test_throws CacheCorruptedError read(IOBuffer(vcat(MagicHeader, UInt8[0xff])))    # wrong version
    @test_throws CacheCorruptedError read(IOBuffer(MagicHeader))                       # truncated header
end

@testitem "SymbolServer: CacheStore rejects unknown header" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read

    @test_throws CacheCorruptedError read(IOBuffer(UInt8[0x00]))                              # bad magic
    @test_throws CacheCorruptedError read(IOBuffer(vcat(MagicHeader, StoreVersion, UInt8[0xff])))  # unknown tag
end

@testitem "SymbolServer: CacheStore rejects truncated stream" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read

    prefix = vcat(MagicHeader, StoreVersion)

    # SymbolHeader + length=100, but only 5 payload bytes
    io = IOBuffer(vcat(prefix, UInt8[0x02], reinterpret(UInt8, [Int(100)]), UInt8[0x41, 0x41, 0x41, 0x41, 0x41]))
    @test_throws CacheCorruptedError read(io)

    @test_throws CacheCorruptedError read(IOBuffer(UInt8[]))

    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, UInt8[0x02, 0x00, 0x00])))
end

@testitem "SymbolServer: CacheStore rejects oversized length fields" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read

    prefix = vcat(MagicHeader, StoreVersion)
    huge = Int(10)^15
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, UInt8[0x02], reinterpret(UInt8, [huge]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, UInt8[0x02], reinterpret(UInt8, [Int(-1)]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, UInt8[0x05], reinterpret(UInt8, [huge]))))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, UInt8[0x14], reinterpret(UInt8, [huge]))))
end

@testitem "SymbolServer: CacheStore truncates cyclic/deep data on write" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: storeunstore, MAX_DEPTH
    using JuliaWorkspaces.SymbolServer: VarRef, FakeTypeName, Unserializable

    name = VarRef(nothing, :A)
    ft = FakeTypeName(name, Any[])
    push!(ft.parameters, ft)        # cycle: ft.parameters[1] === ft

    # the cycle is unrolled up to the depth cutoff, then cut with the sentinel
    tail, n = let x = storeunstore(ft), k = 0
        while x isa FakeTypeName
            x = x.parameters[1]
            k += 1
        end
        x, k
    end
    @test tail === Unserializable()
    @test 0 < n <= MAX_DEPTH

    deep = let d = FakeTypeName(name, Any[])
        for _ in 1:300
            d = FakeTypeName(name, Any[d])
        end
        d
    end
    @test storeunstore(deep) isa FakeTypeName
end

@testitem "SymbolServer: CacheStore rejects deeply nested input on read" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read

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

    prefix = vcat(MagicHeader, StoreVersion)
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, nested_bytes(300))))
    read(IOBuffer(vcat(prefix, nested_bytes(100))))   # under MAX_DEPTH, no throw
end

@testitem "SymbolServer: CacheStore wraps type-confused data in CacheCorruptedError" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read

    prefix = vcat(MagicHeader, StoreVersion)

    # VarRef whose name slot holds a String instead of a Symbol; the strictly
    # typed constructor throws MethodError, which must surface as corruption
    io = IOBuffer()
    Base.write(io, 0x06)                                               # VarRefHeader
    Base.write(io, 0x01)                                               # parent: nothing
    Base.write(io, 0x05); Base.write(io, Int(1)); Base.write(io, 0x61) # name: String "a"
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, take!(io))))

    # Char with an out-of-range code point (CodePointError)
    io = IOBuffer()
    Base.write(io, 0x03)                                               # CharHeader
    Base.write(io, typemax(UInt32))
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, take!(io))))
end

@testitem "SymbolServer: CacheStore caps tuple length" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, MagicHeader, StoreVersion, read, storeunstore
    using JuliaWorkspaces.SymbolServer: VarRef, FakeTypeName, Unserializable

    prefix = vcat(MagicHeader, StoreVersion)
    # a tuple of n `nothing`s: TupleHeader, length, then n NothingHeader bytes
    tuple_bytes(n) = vcat(UInt8[0x14], reinterpret(UInt8, [Int(n)]), fill(0x01, n))

    @test read(IOBuffer(vcat(prefix, tuple_bytes(100)))) === ntuple(_ -> nothing, 100)
    @test_throws CacheCorruptedError read(IOBuffer(vcat(prefix, tuple_bytes(10_001))))

    # the writer degrades oversized tuples to the sentinel instead of failing the file
    @test storeunstore(ntuple(_ -> nothing, 10_001)) === Unserializable()
    ft = FakeTypeName(VarRef(nothing, :T), Any[ntuple(_ -> nothing, 10_001), 1])
    back = storeunstore(ft)
    @test back.parameters[1] === Unserializable()
    @test back.parameters[2] == 1
    @test sprint(show, back) == "T{…,1}"
end

@testitem "SymbolServer: _lookup returns nothing for unresolvable type refs" begin
    using JuliaWorkspaces.SymbolServer: _lookup, ModuleStore, VarRef, FakeTypeName,
        FakeTypeVar, FakeTypeofBottom, Unserializable

    store = Dict{Symbol,ModuleStore}()
    core_any = FakeTypeName(VarRef(VarRef(nothing, :Core), :Any), Any[])
    # field types can be FakeTypeVar (`struct Foo{T}; x::T end`) or the
    # unserializable sentinel; resolve_getfield feeds them straight to _lookup
    @test _lookup(FakeTypeVar(:T, FakeTypeofBottom(), core_any), store, true) === nothing
    @test _lookup(FakeTypeofBottom(), store, true) === nothing
    @test _lookup(Unserializable(), store, true) === nothing
end

@testitem "SymbolServer: CacheStore drops module bindings it cannot serialize" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: storeunstore
    using JuliaWorkspaces.SymbolServer: ModuleStore, VarRef, GenericStore

    good = GenericStore(VarRef(nothing, :g), nothing, "doc", true)
    # unserializable value types degrade the binding, not the file
    mod = ModuleStore(VarRef(nothing, :M),
        Dict{Symbol,Any}(:weird => Ref(1), :good => good, :legit_nothing => nothing),
        "", true, Symbol[], Symbol[])

    back = storeunstore(mod)
    @test !haskey(back.vals, :weird)
    @test back.vals[:good].doc == "doc"
    # the sentinel is distinct from NothingHeader: real `nothing`s survive
    @test haskey(back.vals, :legit_nothing)
    @test back.vals[:legit_nothing] === nothing
end

@testitem "SymbolServer: CacheStore rejects truncated sha" begin
    using JuliaWorkspaces.SymbolServer.CacheStore: CacheCorruptedError, read, write
    using JuliaWorkspaces.SymbolServer: Package, ModuleStore, VarRef

    mod = ModuleStore(VarRef(nothing, :Foo), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
    pkg = Package("Foo", mod, Base.UUID(UInt128(1)), collect(UInt8, 1:32))
    io = IOBuffer()
    write(io, pkg)
    bytes = take!(io)

    @test read(IOBuffer(bytes)).sha == collect(UInt8, 1:32)
    @test_throws CacheCorruptedError read(IOBuffer(bytes[1:end-10]))
end

@testitem "SymbolServer: write_cache uses unique temp names under concurrent same-path writes" begin
    using JuliaWorkspaces.SymbolServer: write_cache, Package, ModuleStore, VarRef
    using JuliaWorkspaces.SymbolServer.CacheStore: read as cache_read

    # Regression: the temp file used to be `<outpath>.tmp.<getpid()>`. Containerized
    # workers all run as PID 1 in their own PID namespace, so two workers scrubbing
    # the same shared dependency cache picked the identical temp name; one renamed it
    # into place and the other's rename failed with ENOENT. Concurrent tasks here
    # share one getpid(), reproducing the collision; mktemp makes each writer unique.
    mktempdir() do store_path
        pkg_dir = joinpath(store_path, "F", "Foo", "00000000-0000-0000-0000-000000000001")
        mkpath(pkg_dir)
        outpath = joinpath(pkg_dir, "deadbeef.jstore")
        mod = ModuleStore(VarRef(nothing, :Foo), Dict{Symbol,Any}(), "", true, Symbol[], Symbol[])
        pkg = Package("Foo", mod, Base.UUID("00000000-0000-0000-0000-000000000001"), nothing)

        errs = Channel{Any}(64)
        @sync for _ in 1:32
            @async try
                write_cache(pkg.uuid, pkg, outpath)
            catch err
                put!(errs, err)
            end
        end
        close(errs)
        collected = collect(errs)
        @test isempty(collected)                          # no rename ENOENT
        @test isfile(outpath)
        @test open(cache_read, outpath).name == "Foo"     # final file is intact
        # No predictable PID-named temp left behind.
        @test isempty(filter(f -> occursin(".tmp.", f), readdir(pkg_dir)))
    end
end

@testitem "SymbolServer: corrupt cache file produces CacheCorruptedError" begin
    using JuliaWorkspaces: JuliaWorkspaces

    mktempdir() do store_path
        pkg_dir = joinpath(store_path, "B", "Bogus", "00000000-0000-0000-0000-000000000000")
        mkpath(pkg_dir)
        cache_path = joinpath(pkg_dir, "0.1.0.jstore")
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
    using JuliaWorkspaces.SymbolServer.CacheStore: read, MagicHeader, StoreVersion

    mktemp() do path, io
        Base.write(io, MagicHeader)
        Base.write(io, StoreVersion)
        Base.write(io, 0x05)            # StringHeader
        Base.write(io, Int(30))
        Base.write(io, repeat("a", 30))
        close(io)

        @test open(read, path) == repeat("a", 30)
    end
end

@testitem "SymbolServer: dynamic-feature reader uses the cache layout get_store writes" begin
    using JuliaWorkspaces: JuliaWorkspaces

    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    th = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"

    mktempdir() do root
        proj = joinpath(root, "proj")
        store = joinpath(root, "store")
        mkpath(proj)
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "1.11.0"
        manifest_format = "2.0"

        [[deps.Example]]
        uuid = "$uuid"
        version = "0.5.3"
        git-tree-sha1 = "$th"
        """)

        @test any(m -> m.name == "Example", JuliaWorkspaces._get_missing_packages(proj, store))

        # A cache at the layout get_cache_path/get_store produce satisfies the reader.
        new_path = joinpath(store, "E", "Example", uuid, "$th.jstore")
        mkpath(dirname(new_path))
        write(new_path, "x")
        @test !any(m -> m.name == "Example", JuliaWorkspaces._get_missing_packages(proj, store))

        # The old layout must not.
        rm(new_path)
        old_path = joinpath(store, "E", "Example_$uuid", "v0.5.3_$th.jstore")
        mkpath(dirname(old_path))
        write(old_path, "x")
        @test any(m -> m.name == "Example", JuliaWorkspaces._get_missing_packages(proj, store))
    end
end

@testitem "SymbolServer: FakeTypeName caches nested type parameters" begin
    using JuliaWorkspaces.SymbolServer: FakeTypeName
    using JuliaWorkspaces.SymbolServer.CacheStore: storeunstore

    ft = FakeTypeName(Dict{String, Vector{Int}})
    @test !isempty(ft.parameters[2].parameters)   # nested Vector{Int} keeps its Int
    @test storeunstore(ft) == ft                   # survives a serialize round-trip
end

@testitem "SymbolServer: #161 cross-package overload is captured" begin
    using JuliaWorkspaces.SymbolServer: FunctionStore, EnvStore, VarRef, collect_extended_methods
    using JuliaWorkspaces.SymbolServer.CacheStore: read

    a_uuid = "5a61a11e-3d95-423b-8231-1a5bca90429f"
    b_uuid = "09fe8bcb-ac26-410c-9c93-4f8b45323ba9"
    symbolserver_jl = abspath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

    mktempdir() do root
        proj = joinpath(root, "proj")
        adir = joinpath(root, "A")
        bdir = joinpath(root, "B")
        store = joinpath(root, "store")
        mkpath(joinpath(adir, "src"))
        mkpath(joinpath(bdir, "src"))
        mkpath(proj)
        mkpath(store)

        write(joinpath(adir, "Project.toml"), """
        name = "A"
        uuid = "$a_uuid"
        version = "0.1.0"
        """)
        write(joinpath(adir, "src", "A.jl"), "module A\nfoo(x) = 1\nend # module A\n")

        write(joinpath(bdir, "Project.toml"), """
        name = "B"
        uuid = "$b_uuid"
        version = "0.1.0"

        [deps]
        A = "$a_uuid"
        """)
        # B extends A.foo for its own type without re-exporting the name.
        write(joinpath(bdir, "src", "B.jl"), """
        module B
        import A
        struct Foo end
        A.foo(::Foo) = 2
        end # module B
        """)

        write(joinpath(proj, "Project.toml"), """
        [deps]
        A = "$a_uuid"
        B = "$b_uuid"
        """)
        write(joinpath(proj, "Manifest.toml"), """
        julia_version = "1.11.0"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"

        [[deps.A]]
        path = "../A"
        uuid = "$a_uuid"
        version = "0.1.0"

        [[deps.B]]
        deps = ["A"]
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
        proc = withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            run(ignorestatus(`$jl --startup-file=no --project=$proj $runner`))
        end
        @test proc.exitcode == 0

        a_store = open(read, joinpath(store, "A", "A", a_uuid, "0.1.0.jstore")).val
        b_store = open(read, joinpath(store, "B", "B", b_uuid, "0.1.0.jstore")).val

        # A defines `foo(x) = 1` — captured as-is.
        @test haskey(a_store, :foo)
        a_foo = a_store[:foo]
        @test a_foo isa FunctionStore
        @test a_foo.name == a_foo.extends
        @test length(a_foo.methods) == 1

        # B's `A.foo(::Foo) = 2` must appear in B's store extending A.foo.
        @test haskey(b_store, :foo)
        b_foo = b_store[:foo]
        @test b_foo isa FunctionStore
        @test b_foo.name != b_foo.extends
        @test b_foo.name.parent !== nothing
        @test b_foo.name.parent.name == :B
        @test b_foo.extends.name == :foo
        @test b_foo.extends.parent !== nothing
        @test b_foo.extends.parent.name == :A
        @test length(b_foo.methods) == 1
        @test b_foo.methods[1].mod == :B

        # collect_extended_methods should surface B as an overloader of A.foo.
        exts = collect_extended_methods(EnvStore(:A => a_store, :B => b_store))
        @test haskey(exts, b_foo.extends)
        @test VarRef(nothing, :B) in exts[b_foo.extends]
    end
end

@testitem "SymbolServer: recursive type parameters are bounded" begin
    using JuliaWorkspaces.SymbolServer: FakeTypeName, ExpandBudget, Unserializable, CacheStore

    # Number of DataTypes that were expanded (i.e. kept their parameters).
    expanded(x) = x isa FakeTypeName && !isempty(x.parameters) && !(x.parameters[1] isa Unserializable) ? 1 + sum(expanded, x.parameters) : 0
    # Number of expansions aborted by the budget.
    truncated(x) = x isa FakeTypeName ? count(p -> p isa Unserializable, x.parameters) + sum(truncated, x.parameters; init = 0) : 0

    limit = 8
    deep = foldl((T, _) -> Tuple{T}, 1:100; init = Int)   # Tuple{Tuple{…{Int}}}
    wide = Tuple{ntuple(i -> Val{i}, 100)...}              # Tuple{Val{1},…,Val{100}}

    # However a type explodes — by depth or by width — expansion stops at the
    # budget, and each cut is marked rather than silently dropped.
    for T in (deep, wide)
        ft = FakeTypeName(T, ExpandBudget(limit))
        @test expanded(ft) <= limit
        @test truncated(ft) > 0
    end

    # An ordinary type has far fewer nodes than the budget, so nothing is dropped.
    ordinary = Dict{String,Vector{Tuple{Int,Float64}}}
    @test FakeTypeName(ordinary, ExpandBudget(limit)) == FakeTypeName(ordinary)
    @test truncated(FakeTypeName(ordinary, ExpandBudget(limit))) == 0

    # The marker renders as `…` and roundtrips through the cache format.
    ft = FakeTypeName(deep, ExpandBudget(limit))
    @test contains(string(ft), "…")
    io = IOBuffer()
    CacheStore.write(io, ft)
    @test CacheStore.read(IOBuffer(take!(io))) == ft
end
