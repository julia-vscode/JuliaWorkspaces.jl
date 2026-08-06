# Precompile workload: build a small but representative workspace and run the
# public entry points that CLI tools (julialint/juliaformat) and the language
# server hit on startup, so that the bulk of the analysis pipeline (parsing,
# Salsa derived layers, StaticLint, formatting) is compiled into the pkgimage.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    project_dir = mktempdir()

    mkpath(joinpath(project_dir, "src"))
    mkpath(joinpath(project_dir, "test"))
    mkpath(joinpath(project_dir, "scripts"))
    mkpath(joinpath(project_dir, "runicsub"))

    write(joinpath(project_dir, "Project.toml"), """
    name = "PrecompileWorkload"
    uuid = "8f2b0cb1-56a1-4b0f-9a37-9c2f7b1d2c40"
    version = "0.1.0"

    [deps]
    Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
    Logging = "56ddb016-857b-54e1-b83d-db4d58db5568"
    Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"
    """)

    # A manifest routes environment resolution through the same (much larger)
    # code path that real-world projects hit.
    write(joinpath(project_dir, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"
    project_hash = "0000000000000000000000000000000000000000"

    [[deps.Dates]]
    deps = ["Printf"]
    uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
    version = "1.11.0"

    [[deps.Logging]]
    deps = ["StyledStrings"]
    uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"
    version = "1.11.0"

    [[deps.Printf]]
    deps = ["Unicode"]
    uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
    version = "1.11.0"

    [[deps.StyledStrings]]
    uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
    version = "1.11.0"

    [[deps.Unicode]]
    uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
    version = "1.11.0"
    """)

    write(joinpath(project_dir, "JuliaLint.toml"), """
    preset = "default"

    [rules]
    syntax_warnings = "warning"
    missing_reference = { severity = "warning", scope = "all" }
    """)

    write(joinpath(project_dir, "src", "PrecompileWorkload.jl"), """
    module PrecompileWorkload

    export greet, Point2

    using Printf, Dates
    import Logging
    using Logging: @info

    const GREETING = "hello"

    abstract type AbstractShape end

    struct Point2{T<:Real} <: AbstractShape
        x::T
        y::T
    end

    Base.:+(a::Point2, b::Point2) = Point2(a.x + b.x, a.y + b.y)

    @enum Color Red Green Blue

    mutable struct Counter
        n::Int
        Counter() = new(0)
    end

    \"\"\"
        greet(name)

    Return a greeting for `name`.
    \"\"\"
    function greet(name::AbstractString="world"; excited::Bool=false)
        msg = "\$(GREETING), \$name"
        return excited ? uppercase(msg) : msg
    end

    norm2(p::Point2) = sqrt(p.x^2 + p.y^2)

    function process(xs::Vector{T}) where {T<:Number}
        total = zero(T)
        for (i, x) in enumerate(xs)
            if isodd(i)
                total += x
            elseif x > zero(T)
                total -= x
            else
                continue
            end
        end
        ys = [x^2 for x in xs if x > 0]
        zs = map(x -> 2x, xs)
        return total + sum(ys; init=zero(T)) + sum(zs; init=zero(T))
    end

    function risky()
        try
            error("boom")
        catch err
            @warn "caught" err
        finally
            nothing
        end
    end

    macro twice(ex)
        quote
            \$(esc(ex))
            \$(esc(ex))
        end
    end

    function use_macro()
        c = Counter()
        @twice c.n += 1
        unused_variable = 42
        not_a_real_function_xyz(c)
        return c.n
    end

    apply_all(f, xs) = map(xs) do x
        f(x)
    end

    struct Stamp <: Dates.AbstractTime
        t::Dates.DateTime
    end

    function stdlib_usage()
        d = Dates.Date(2020, 1, 1)
        t = Dates.now()
        @printf("%d\n", Dates.year(d))
        Logging.@warn "workload" t
        s = Stamp(t)
        io = IOBuffer()
        print(io, s.t, ' ', Dates.month(d))
        sum([1, 2, 3]; init=0)
        parse(Int, "42")
        return String(take!(io))
    end

    include("other.jl")

    end # module
    """)

    write(joinpath(project_dir, "src", "other.jl"), """
    struct Config
        name::String
        values::Dict{Symbol,Any}
    end

    function Base.show(io::IO, c::Config)
        print(io, "Config(", c.name, ")")
    end

    function count_up(limit::Int)
        s = 0
        while s < limit
            s += 1
        end
        return s
    end
    """)

    write(joinpath(project_dir, "test", "runtests.jl"), """
    using Test
    using PrecompileWorkload

    @testset "greet" begin
        @test greet() == "hello, world"
    end

    @testitem "point addition" begin
        p = PrecompileWorkload.Point2(1.0, 2.0) + PrecompileWorkload.Point2(3.0, 4.0)
        @test p.x == 4.0
    end
    """)

    # Badly formatted code so the formatter actually produces edits.
    write(joinpath(project_dir, "scripts", "script.jl"), """
    x=1+2
    function  f( a,b )
      a+ b
    end
    y = [ 1,2 ,3 ]
    """)

    # A file with a syntax error exercises error recovery and diagnostics.
    write(joinpath(project_dir, "scripts", "broken.jl"), """
    function oops(a, b
        return a + b
    """)

    # Subfolder configured for Runic so both formatter backends get compiled.
    write(joinpath(project_dir, "runicsub", "JuliaFormat.toml"), """
    style = "runic"
    """)
    write(joinpath(project_dir, "runicsub", "runic_file.jl"), """
    g(x)=x^ 2
    z  = g( 3 )
    """)

    @compile_workload begin
        # Explicit store_path avoids touching scratch spaces during precompile.
        jw = JuliaWorkspace(store_path=mktempdir())
        add_folder_from_disc!(jw, project_dir)

        for uri in get_julia_files(jw)
            text_file = get_text_file(jw, uri)
            position_at(text_file.content, 1)
            try
                get_format_edits(jw, uri)
            catch
                # the syntax-error file cannot be formatted
            end
        end

        get_diagnostics_blocking(jw)
        get_test_items(jw)

        # Symbol-cache serialization round-trip: compiles the package-cache
        # write/read path used when loading .jstore files at runtime.
        let store_name = haskey(SymbolServer.stdlibs, :Logging) ? :Logging : first(keys(SymbolServer.stdlibs))
            store_file = joinpath(mktempdir(), "cache.jstore")
            pkg = SymbolServer.Package(string(store_name), SymbolServer.stdlibs[store_name],
                Base.UUID("56ddb016-857b-54e1-b83d-db4d58db5568"), nothing)
            open(io -> SymbolServer.CacheStore.write(io, pkg), store_file, "w")
            package_data = open(SymbolServer.CacheStore.read, store_file)
            SymbolServer.modify_dirs(package_data.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", "src"))
        end

        # Compile the dynamic-feature code paths (reactor, reconcile,
        # readiness waiting) that CLI tools hit. A plain scripts folder
        # requires no environment indexing, so no child Julia processes are
        # spawned during precompilation.
        Logging.with_logger(Logging.NullLogger()) do
            scripts_dir = mktempdir()
            write(joinpath(scripts_dir, "script.jl"), "f(x) = x + 1\n")
            jw2 = JuliaWorkspace(store_path=mktempdir(), dynamic=DynamicIndexingOnly)
            add_folder_from_disc!(jw2, scripts_dir)
            get_diagnostics_blocking(jw2)
            put!(jw2.dynamic_feature.in_channel, ShutdownMsg())
            while state(jw2.dynamic_feature.controller_fsm) != DynamicControllerStopped
                yield()
            end
        end
    end
end
