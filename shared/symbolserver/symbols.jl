using LibGit2, InteractiveUtils

mutable struct Server
    storedir::String
    context::Pkg.Types.Context
    depot::Dict
end

abstract type SymStore end
struct ModuleStore <: SymStore
    name::VarRef
    vals::Dict{Symbol,Any}
    doc::String
    # A binding's export/public status is a (module, name) property recorded here
    # for every name — including re-exports whose value is a bare `VarRef` and so
    # can't carry its own flag. exported ⊆ public.
    exportednames::Vector{Symbol}
    publicnames::Vector{Symbol}
    used_modules::Vector{Symbol}
end

# Back-compat positional form: the old `exported::Bool` (slot 4) is dropped, and
# the old single `exportednames` list seeds both name lists. `copy` keeps the
# two lists from aliasing the same array — a later `push!` to one (e.g. the
# `:include`/`:ccall` fixups in `load_core`) must not silently mutate the other.
ModuleStore(name::VarRef, vals, doc, ::Bool, exportednames, used_modules) =
    ModuleStore(name, vals, doc, exportednames, copy(exportednames), used_modules)

function ModuleStore(m)
    # `names(m)` (all=false) is exactly the public set (exported ∪ public) on
    # 1.11+, and the exported set pre-1.11 — so it already IS `publicnames`;
    # exported is the strict subset.
    ns = unsorted_names(m)
    ModuleStore(VarRef(m), Dict{Symbol,Any}(), _doc(m, nameof(m)),
        filter(s -> _isexported(m, s), ns), ns, Symbol[])
end
Base.getindex(m::ModuleStore, k) = m.vals[k]
Base.setindex!(m::ModuleStore, v, k) = (m.vals[k] = v)
Base.haskey(m::ModuleStore, k) = haskey(m.vals, k)

Base.show(io::IO, ms::ModuleStore) = print(io, "ModuleStore($(ms.name)) with $(length(ms.vals)) entries")

const EnvStore = Dict{Symbol,ModuleStore}

struct Package
    name::String
    val::ModuleStore
    uuid::Base.UUID
    sha::Union{Vector{UInt8},Nothing}
end
Package(name::String, val::ModuleStore, uuid::String, sha) = Package(name, val, Base.UUID(uuid), sha)

struct MethodStore
    name::Symbol
    mod::Symbol
    file::String
    line::Int32
    sig::Vector{Pair{Any,Any}}
    kws::Vector{Symbol}
    rt::Any
end

function Base.show(io::IO, ms::MethodStore)
    print(io, ms.mod, ".", ms.name, "(")
    for (a,b) in ms.sig
        print(io, a, "::", b)
    end
    print(io, ") at ", ms.file, ":", ms.line, )
end

_samestore(a::MethodStore, b::MethodStore) =
    a.file == b.file && a.line == b.line && a.sig == b.sig

struct DataTypeStore <: SymStore
    name::FakeTypeName
    super::FakeTypeName
    parameters::Vector{Any}
    types::Vector{Any}
    fieldnames::Vector{Any}
    methods::Vector{MethodStore}
    doc::String
    function DataTypeStore(names, super, parameters, fieldtypes, fieldnames, methods, doc)
        if length(fieldtypes) < length(fieldnames)
            append!(fieldtypes, [FakeTypeName(Any) for _ in 1:(length(fieldnames)-length(fieldtypes))])
        end
        new(names, super, parameters, fieldtypes, fieldnames, methods, doc)
    end
end

function DataTypeStore(@nospecialize(t), symbol, parent_mod)
    ur_t = Base.unwrap_unionall(t)
    parameters = if isdefined(ur_t, :parameters)
        map(ur_t.parameters) do p
            _parameter(p)
        end
    else
        []
    end
    has_fields = isconcretetype(ur_t) && fieldcount(ur_t) > 0
    types = if has_fields
        Any[FakeTypeName(p) for p in Base.fieldtypes(ur_t)]
    elseif isdefined(ur_t, :types)
        map(FakeTypeName, ur_t.types)
    else
        []
    end
    fieldnames = has_fields ? collect(Base.fieldnames(ur_t)) : Symbol[]
    DataTypeStore(FakeTypeName(ur_t), FakeTypeName(ur_t.super), parameters, types, fieldnames, MethodStore[], _doc(parent_mod, symbol))
end

function Base.show(io::IO, dts::DataTypeStore)
    print(io, dts.name, " <: ", dts.super, " with $(length(dts.methods)) methods")
end

struct FunctionStore <: SymStore
    name::VarRef
    methods::Vector{MethodStore}
    doc::String
    extends::VarRef
end

# Back-compat positional form: drop the trailing `exported::Bool`.
FunctionStore(name::VarRef, methods, doc, extends::VarRef, ::Bool) =
    FunctionStore(name, methods, doc, extends)

function FunctionStore(@nospecialize(f), symbol, parent_mod)
    if f isa Core.IntrinsicFunction
        FunctionStore(VarRef(VarRef(Core.Intrinsics), nameof(f)), MethodStore[], _doc(parent_mod, symbol), VarRef(VarRef(parentmodule(f)), nameof(f)))
    else
        FunctionStore(VarRef(VarRef(parent_mod), nameof(f)), MethodStore[], _doc(parent_mod, symbol), VarRef(VarRef(parentmodule(f)), nameof(f)))
    end
end

# Back-compat type-object form: drop the trailing `exported`.
FunctionStore(@nospecialize(f), symbol, parent_mod, ::Bool) = FunctionStore(f, symbol, parent_mod)

function Base.show(io::IO, fs::FunctionStore)
    print(io, fs.name, " with $(length(fs.methods)) methods")
end

struct GenericStore <: SymStore
    name::VarRef
    typ::Any
    doc::String
end

# Back-compat positional form: drop the trailing `exported::Bool`.
GenericStore(name::VarRef, typ, doc, ::Bool) =
    GenericStore(name, typ, doc)

# adapted from https://github.com/timholy/CodeTracking.jl/blob/afc73a957f5034cc7f02e084a91283c47882f92b/src/utils.jl#L87-L122

"""
    path = maybe_fix_path(path)

Return a normalized, absolute path for a source file `path`.
"""
function maybe_fix_path(file)
    if !isabspath(file)
        # This may be a Base or Core method
        newfile = Base.find_source_file(file)
        if isa(newfile, AbstractString)
            file = normpath(newfile)
        end
    end
    return maybe_fixup_stdlib_path(file)
end

safe_isfile(x) = try isfile(x); catch; false end
const BUILDBOT_STDLIB_PATH = dirname(abspath(joinpath(String((@which versioninfo()).file), "..", "..", "..")))
replace_buildbot_stdlibpath(str::String) = replace(str, BUILDBOT_STDLIB_PATH => Sys.STDLIB)
"""
    path = maybe_fixup_stdlib_path(path::String)

Return `path` corrected for julia issue [#26314](https://github.com/JuliaLang/julia/issues/26314) if applicable.
Otherwise, return the input `path` unchanged.

Due to the issue mentioned above, location info for methods defined one of Julia's standard libraries
are, for non source Julia builds, given as absolute paths on the worker that built the `julia` executable.
This function corrects such a path to instead refer to the local path on the users drive.
"""
function maybe_fixup_stdlib_path(path)
    if !safe_isfile(path)
        maybe_stdlib_path = replace_buildbot_stdlibpath(path)
        safe_isfile(maybe_stdlib_path) && return maybe_stdlib_path
    end
    return path
end

_default_world_age() =
    if isdefined(Base, :get_world_counter)
        Base.get_world_counter()
    else
        typemax(UInt)
    end

const _METHOD_WORLD_FIELD =
    :primary_world in fieldnames(Method) ? :primary_world : :min_world

method_world(m::Method) = getfield(m, _METHOD_WORLD_FIELD)

const _global_method_cache = IdDict{Any,Vector{Any}}()
function methodinfo(@nospecialize(f); types = Tuple, world = _default_world_age())
    key = (f, types, world)
    if haskey(_global_method_cache, key)
        return _global_method_cache[key]
    else
        ms = Base._methods(f, types, -1, world)
        ms isa Vector || (ms = [])
        _global_method_cache[key] = ms
        return ms
    end
end

function methodlist(@nospecialize(f))
    ms = methodinfo(f)
    Method[x[3]::Method for x in ms]
end

function sparam_syms(meth::Method)
    s = Symbol[]
    sig = meth.sig
    while sig isa UnionAll
        push!(s, Symbol(sig.var.name))
        sig = sig.body
    end
    return s
end

function cache_methods(@nospecialize(f), name, env, get_return_type; min_world::UInt = UInt(0))
    if isa(f, Core.Builtin)
        return MethodStore[]
    end
    types = Tuple
    world = _default_world_age()
    ms = Tuple{Module,MethodStore}[]
    methods0 = try
        methodinfo(f; types = types, world = world)
    catch err
        @debug "Error in method lookup for $f" ex=(err, catch_backtrace())
        return ms
    end
    ind_of_method_w_kws = Int[] # stores the index of methods with kws.
    i = 1
    for m in methods0
        if method_world(m[3]) <= min_world
            continue
        end
        # Get inferred method return type
        if get_return_type
            sparams = Core.svec(sparam_syms(m[3])...)
            rt = try
                @static if isdefined(Core.Compiler, :NativeInterpreter)
                    Core.Compiler.typeinf_type(Core.Compiler.NativeInterpreter(), m[3], m[3].sig, sparams)
                else
                    Core.Compiler.typeinf_type(m[3], m[3].sig, sparams, Core.Compiler.Params(world))
                end
            catch e
                Any
            end
        else
            rt = Any
        end
        file = maybe_fix_path(String(m[3].file))
        MS = MethodStore(m[3].name, nameof(m[3].module), file, m[3].line, [], Symbol[], FakeTypeName(rt))
        # Get signature
        sig = Base.unwrap_unionall(m[1])
        argnames = getargnames(m[3])

        is_vararg = m[3].isva
        nargs = m[3].nargs - (1 & is_vararg)
        nsigparams = length(sig.parameters)

        for i = 2:nargs
            push!(MS.sig, argnames[i] => FakeTypeName(sig.parameters[i]))
        end

        # Julia normalises bounded `Vararg{T,N}` away from the tuple type:
        # `f(x::Vararg{T,N})` becomes `Tuple{typeof(f), T, T, …, T}` (N
        # copies) while `m.nargs` keeps counting the slot. For N=0 the
        # trailing slot disappears entirely and a naive `2:nargs` loop
        # walks past `sig.parameters` (BoundsError). Reconstruct
        # `Vararg{T,N}` from the expansion so the cached sig matches the
        # method as written.
        if is_vararg && nargs < nsigparams
            last_param = sig.parameters[end]
            if last_param isa Core.TypeofVararg
                # Unbounded `Vararg{T}` or `Vararg{T,N} where N` survives in the tuple.
                push!(MS.sig, argnames[nargs + 1] => FakeTypeName(last_param))
            else
                T = sig.parameters[nargs + 1]
                N = nsigparams - nargs
                push!(MS.sig, argnames[nargs + 1] => FakeTypeName(Vararg{T, N}))
            end
        end
        kws = getkws(m[3])
        if !isempty(kws)
            push!(ind_of_method_w_kws, i)
        end
        for kw in kws
            push!(MS.kws, kw)
        end
        push!(ms, (m[3].module, MS))
        i += 1
    end

    # Go back and add kws to methods defined in the same place as others with kws.
    for i in ind_of_method_w_kws
        for mj in ms
            if mj[2].file == ms[i][2].file && mj[2].line == ms[i][2].line && isempty(mj[2].kws)
                for kw in ms[i][2].kws
                    push!(mj[2].kws, kw)
                end
            end
        end
    end

    # non-Function callables (e.g. SymbolicUtils.BasicSymbolic, #319) have no
    # `parentmodule` method; fall back to the type's module
    fmod = f isa Union{Module,Function,Type} ? parentmodule(f) : parentmodule(typeof(f))
    func_vr = VarRef(VarRef(fmod), name)
    for m in ms
        mvr = VarRef(m[1])
        # `cont=true` follows VarRef chains to the actual ModuleStore: a module's
        # env entry can be a VarRef alias (e.g. a re-exported/used module), and an
        # unresolved VarRef has no `haskey`/`setindex!` (would throw MethodError).
        modstore = _lookup(mvr, env, true)
        modstore isa ModuleStore || continue

        if !haskey(modstore, name)
            modstore[name] = FunctionStore(VarRef(mvr, name), MethodStore[m[2]], "", func_vr, false)
        elseif !(modstore[name] isa DataTypeStore || modstore[name] isa FunctionStore)
            modstore[name] = FunctionStore(VarRef(mvr, name), MethodStore[m[2]], "", func_vr, false)
        else
            if !any(existing -> _samestore(existing, m[2]), modstore[name].methods)
                push!(modstore[name].methods, m[2])
            end
        end
    end
    return ms
end

getargnames(m::Method) = Base.method_argnames(m)
@static if length(first(methods(Base.kwarg_decl)).sig.parameters) == 2
    getkws = Base.kwarg_decl
else
    function getkws(m::Method)
        sig = Base.unwrap_unionall(m.sig)
        length(sig.parameters) == 0 && return []
        sig.parameters[1] isa Union && return []
        !isdefined(Base.unwrap_unionall(sig.parameters[1]), :name) && return []
        fname = Base.unwrap_unionall(sig.parameters[1]).name
        if isdefined(fname.mt, :kwsorter)
            Base.kwarg_decl(m, typeof(fname.mt.kwsorter))
        else
            []
        end
    end
end

# Whether `m.s` resolves to one concrete global. On 1.12+ `isdefinedglobal`
# returns false for a name ambiguously brought in by two `using`d modules
# (`isdefined` would say true, then `getglobal` throws), so it filters those out
# before we read them. Only on 1.12+; fall back to `isdefined` on 1.11.
@static if isdefined(Base, :isdefinedglobal)
    _isdefinedglobal(m::Module, s::Symbol) = invokelatest(Base.isdefinedglobal, m, s)
else
    _isdefinedglobal(m::Module, s::Symbol) = invokelatest(isdefined, m, s)
end

# Whether `s` is exported by `m`. invokelatest for the same world-age reason as
# name enumeration. Pre-1.11 has no `public` keyword, and `names(m)` there is the
# exported set. (The public set needs no predicate — `unsorted_names(m)` IS it.)
@static if isdefined(Base, :isexported)
    _isexported(m::Module, s::Symbol) = invokelatest(Base.isexported, m, s)
else
    _isexported(m::Module, s::Symbol) = s in unsorted_names(m)
end

# Read global `m.s`, returning `(false, nothing)` rather than throwing on an
# ambiguous `using` binding. Backstop for the 1.11 path (1.12+ skips these via
# `_isdefinedglobal`); without it one such name aborts the whole package.
function _try_getglobal(m::Module, s::Symbol)
    try
        return (true, invokelatest(getglobal, m, s))
    catch err
        err isa UndefVarError && return (false, nothing)
        rethrow()
    end
end

function apply_to_everything(f, m = nothing, visited = Base.IdSet{Module}())
    if m isa Module
        push!(visited, m)
        for s in unsorted_names(m, all = true, imported = true, usings = true)
            (!_isdefinedglobal(m, s) || s == nameof(m)) && continue
            ok, x = _try_getglobal(m, s)
            ok || continue
            f(x)
            if x isa Module && !in(x, visited)
                apply_to_everything(f, x, visited)
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || apply_to_everything(f, m, visited)
        end
    end
end



function oneverything(f, m = nothing, visited = Base.IdSet{Module}())
    if m isa Module
        push!(visited, m)
        state = nothing
        for s in unsorted_names(m, all = true, imported = true, usings = true)
            !_isdefinedglobal(m, s) && continue
            ok, x = _try_getglobal(m, s)
            ok || continue
            state = f(m, s, x, state)
            if x isa Module && !in(x, visited)
                oneverything(f, x, visited)
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || oneverything(f, m, visited)
        end
    end
end

const _global_symbol_cache_by_mod = IdDict{Module,Base.IdSet{Symbol}}()
function build_namecache(m, s, @nospecialize(x), state::Union{Base.IdSet{Symbol},Nothing} = nothing)
    if state === nothing
        state = get(_global_symbol_cache_by_mod, m, nothing)
        if state === nothing
            state = _global_symbol_cache_by_mod[m] = Base.IdSet{Symbol}()
        end
    end
    push!(state, s)
end

function getnames(m::Module)
    cache = get(_global_symbol_cache_by_mod, m, nothing)
    if cache === nothing
        oneverything(build_namecache, m)
        cache = _global_symbol_cache_by_mod[m]
    end
    return cache
end

function allmodulenames()
    symbols = Base.IdSet{Symbol}()
    oneverything((m, s, x, state) -> (x isa Module && push!(symbols, s); return state))
    return symbols
end

function allthingswithmethods()
    symbols = Base.IdSet{Any}()
    oneverything(function (m, s, x, state)
        if !Base.isvarargtype(x) && !isempty(methodlist(x))
            push!(symbols, x)
        end
        return state
    end)
    return symbols
end

function allmethods()
    ms = Method[]
    oneverything(function (m, s, x, state)
        if !Base.isvarargtype(x) && !isempty(methodlist(x))
            append!(ms, methodlist(x))
        end
        return state
    end)
    return ms
end

# Cache methods added after `world_before` for every function that gained one,
# so overloads of functions defined elsewhere get attributed to the modules in `env`.
function cache_new_methods!(env, world_before::UInt; get_return_type = false)
    for f in allthingswithmethods()
        any(m -> method_world(m) > world_before, methodlist(f)) || continue

        name = try
            nameof(f)
        catch
            continue
        end
        cache_methods(f, name, env, get_return_type; min_world = world_before)
    end
end

# Accesses go through invokelatest: getmoduletree's frame predates the LoadingBay
# package loads, so a bare access would trip Julia 1.12's world-age binding warning.
function usedby(outer, inner)
    outer !== inner || return false
    _isdefinedglobal(outer, nameof(inner)) || return false
    ok, val = _try_getglobal(outer, nameof(inner))
    (ok && val === inner) || return false
    return all(_isdefinedglobal(outer, name) || !_isdefinedglobal(inner, name) for name in unsorted_names(inner))
end
istoplevelmodule(m) = parentmodule(m) === m || parentmodule(m) === Main

function getmoduletree(m::Module, amn, visited = Base.IdSet{Module}())
    push!(visited, m)
    cache = ModuleStore(m)
    for s in unsorted_names(m, all = true, imported = true, usings = true)
        !_isdefinedglobal(m, s) && continue
        ok, x = _try_getglobal(m, s)
        ok || continue
        if x isa Module
            if istoplevelmodule(x)
                cache[s] = VarRef(x)
            elseif m === parentmodule(x)
                cache[s] = getmoduletree(x, amn, visited)
            else
                cache[s] = VarRef(x)
            end
        end
    end
    for n in amn
        if n !== nameof(m) && _isdefinedglobal(m, n)
            ok, x = _try_getglobal(m, n)
            ok || continue
            if x isa Module
                if !haskey(cache, n)
                    cache[n] = VarRef(x)
                end
                if x !== Main && usedby(m, x)
                    push!(cache.used_modules, n)
                end
            end
        end
    end
    cache
end

function getenvtree(names = nothing)
    amn = allmodulenames()
    EnvStore(nameof(m) => getmoduletree(m, amn) for m in Base.loaded_modules_array() if names === nothing || nameof(m) in names)
end

# faster and more correct split_module_names
all_names(m) = all_names(m, x -> _isdefinedglobal(m, x))
function all_names(m, pred, symbols = Set(Symbol[]), seen = Set(Module[]))
    push!(seen, m)
    ns = unsorted_names(m; all = true, imported = false, usings = false)
    for n in ns
        _isdefinedglobal(m, n) || continue
        # TODO: deprecated bindings are dropped from the cache entirely, so a
        # reference to one reads as "Failed to resolve" and can't be hovered or
        # struck through. Ideally we'd index them with a `deprecatednames` list
        # (mirroring exportednames/publicnames) and drive the LSP Deprecated tag.
        # Blocked on Julia: `Base.isdeprecated` only detects explicit
        # `Base.deprecate` calls, not the `@deprecate`/`@deprecated` macros, so
        # the signal is too partial to rely on. Revisit when it's reliable.
        Base.isdeprecated(m, n) && continue
        ok, val = _try_getglobal(m, n)
        ok || continue
        if val isa Module && !(val in seen)
            all_names(val, pred, symbols, seen)
        end
        if pred(n)
            push!(symbols, n)
        end
    end
    symbols
end

function symbols(env::EnvStore, m::Union{Module,Nothing} = nothing, allnames::Base.IdSet{Symbol} = getallns(), visited = Base.IdSet{Module}();  get_return_type = false)
    if m isa Module
        cache = _lookup(VarRef(m), env, true)
        cache === nothing && return
        push!(visited, m)
        ns = all_names(m)
        for s in ns
            !_isdefinedglobal(m, s) && continue
            ok, x = _try_getglobal(m, s)
            ok || continue

            if Base.unwrap_unionall(x) isa DataType # Unions aren't handled here.
                if parentmodule(x) === m
                    cache[s] = DataTypeStore(x, s, m)
                    cache_methods(x, s, env, get_return_type)
                elseif !(x isa UnionAll) && haskey(cache, s) && (cache[s] isa FunctionStore || cache[s] isa DataTypeStore) && !isempty(cache[s].methods)
                    # `cache_methods` (run when the owning module was crawled — Core is
                    # crawled before Base) already seeded a method-carrying store for this
                    # name: a Core-owned *concrete* type re-exported or aliased by Base
                    # collects its Base-defined extension methods here — `String`
                    # (`String(::Vector{UInt8})` …), and concrete aliases like `Int`→`Int64`.
                    # Leave that store untouched. Overwriting it with a fresh shadow
                    # `DataTypeStore` (below) makes it a *different* instance from the
                    # canonical `Core.String`/`Core.Int` store, so the linter's identity-based
                    # type comparisons (`check_kw_default`, `check_call`, type inference) stop
                    # matching; overwriting with a `VarRef` (further below) drops the extension
                    # methods. Keeping the seeded `FunctionStore` lets `get_eventual_datatype`
                    # follow its `.extends` back to the canonical type.
                    #
                    # The `!(x isa UnionAll)` guard is essential: a *parametric* alias like
                    # `Vector` (= `Array{T,1} where T`, whose `nameof` is `:Array` ≠ `:Vector`,
                    # so it too is a shadow-rename case) must stay a `DataTypeStore` — arg-type
                    # inference needs its type structure to match e.g. `v::Vector{UInt8}`
                    # against `String(::Vector{UInt8})`. A `FunctionStore` has no such structure.
                    #
                    # A genuine renamed shadow (e.g. `DataFrames.Not → InvertedIndices.InvertedIndex`)
                    # is NOT seeded — `cache_methods` attributes those methods to the owning
                    # module, not the shadowing one — so it correctly falls through below.
                elseif nameof(x) !== s || x isa UnionAll
                    # This needs some finessing.
                    cache[s] = DataTypeStore(x, s, m)
                    ms = cache_methods(x, s, env, get_return_type)
                    # A slightly difficult case. `s` is probably a shadow binding of `x` but we should store the methods nonetheless.
                    # Example: DataFrames.Not points to InvertedIndices.InvertedIndex
                    #
                    # `x isa UnionAll` extends this to a *parametric* Core-owned type
                    # re-exported by Base under its own name (`Ref`, `nameof(Ref) === :Ref`,
                    # so the `nameof !== s` shadow test misses it). It needs a
                    # `DataTypeStore` — not the `VarRef` below — for two reasons: its
                    # constructor methods are attributed to Base (so a VarRef to the
                    # method-poor `Core.Ref` drops them, breaking call-checking of e.g.
                    # `Ref(5.0)`), and `T{...}` curly application needs the type structure.
                    for m in ms
                        push!(cache[s].methods, m[2])
                    end
                else
                    # These are imported variables that are reexported.
                    cache[s] = VarRef(VarRef(parentmodule(x)), nameof(x))
                end
            elseif x isa Function
                # Intrinsics report `parentmodule(x) === Core` even though they actually live in
                # `Core.Intrinsics`, so a plain `parentmodule(x) === m` test would misclassify them as
                # Core-owned and emit an empty (0-method) FunctionStore. Treat an intrinsic as "own" only
                # at `Core.Intrinsics`; accessed from anywhere else it falls through to the `elseif` branch
                # below which forwards to `VarRef(VarRef(Core.Intrinsics), nameof(x))`.
                if (x isa Core.IntrinsicFunction ? m === Core.Intrinsics : parentmodule(x) === m)
                    cache[s] = FunctionStore(x, s, m)
                    cache_methods(x, s, env, get_return_type)
                elseif !haskey(cache, s)
                    # This will be replaced at a later point by a FunctionStore if methods for `x` are defined within `m`.
                    if x isa Core.IntrinsicFunction
                        cache[s] = VarRef(VarRef(Core.Intrinsics), nameof(x))
                    else
                        cache[s] = VarRef(VarRef(parentmodule(x)), nameof(x))
                    end
                elseif !((cache[s] isa FunctionStore || cache[s] isa DataTypeStore) && !isempty(cache[s].methods))
                    # These are imported variables that are reexported.
                    # We don't want to remove Func/DT stores that have methods (these will be specific to the module)
                    if x isa Core.IntrinsicFunction
                        cache[s] = VarRef(VarRef(Core.Intrinsics), nameof(x))
                    else
                        cache[s] = VarRef(VarRef(parentmodule(x)), nameof(x))
                    end
                end
            elseif x isa Module
                if x === m
                    cache[s] = VarRef(x)
                elseif parentmodule(x) === m
                    symbols(env, x, allnames, visited, get_return_type = get_return_type)
                else
                    cache[s] = VarRef(x)
                end
            else
                cache[s] = GenericStore(VarRef(VarRef(m), s), FakeTypeName(typeof(x)), _doc(m, s))
            end
        end
    else
        for m in Base.loaded_modules_array()
            in(m, visited) || symbols(env, m, allnames, visited, get_return_type = get_return_type)
        end
    end
end


# stdlibs loaded in a bare Julia sysimage — their Base-function extensions are
# usable without an explicit `using`; determined empirically for Julia 1.12,
# review across Julia versions. (JLL build artifacts like OpenBLAS_jll /
# libblastrampoline_jll are loaded too but don't extend Base functions.)
const _ALWAYS_AVAILABLE_STDLIBS = Set{Symbol}([:LinearAlgebra, :Random, :SHA, :Sockets, :FileWatching, :Libdl, :Artifacts])

# A method defined in `mod` counts as always-available iff `mod` (or one of its
# ancestor modules, e.g. LinearAlgebra.BLAS → LinearAlgebra) is on the sysimage
# stdlib allow-list.
function _is_always_available(mod::Module)
    while true
        nameof(mod) in _ALWAYS_AVAILABLE_STDLIBS && return true
        p = parentmodule(mod)
        p === mod && return false
        mod = p
    end
end

function load_core(; get_return_type = false)
    c = Pkg.Types.Context()
    cache = getenvtree([:Core,:Base])
    symbols(cache, get_return_type = get_return_type)
    cache[:Main] = ModuleStore(VarRef(nothing, :Main), Dict(), "", true, [], [])

    # This is wrong. Every module contains it's own include function.
    push!(cache[:Base].exportednames, :include)
    push!(cache[:Base].publicnames, :include)
    let f = cache[:Base][:include]
        if haskey(cache[:Base][:MainInclude], :include)
            cache[:Base][:include] = FunctionStore(f.name, cache[:Base][:MainInclude][:include].methods, f.doc, f.extends, true)
        else
            m1 = first(f.methods)
            push!(f.methods, MethodStore(
                m1.name,
                m1.mod,
                m1.file,
                m1.line,
                Pair{Any,Any}[
                    :x => SymbolServer.FakeTypeName(SymbolServer.VarRef(SymbolServer.VarRef(nothing, :Core), :AbstractString), Any[])
                ],
                [],
                m1.rt
            ))
        end
    end

    cache[:Base][Symbol("@.")] = cache[:Base][Symbol("@__dot__")]
    cache[:Core][:Main] = GenericStore(VarRef(nothing, :Main), FakeTypeName(Module), _doc(Main, :Main), true)
    # Add built-ins
    builtins = Symbol[nameof(getglobal(Core, n).instance) for n in unsorted_names(Core, all = true) if _isdefinedglobal(Core, n) && getglobal(Core, n) isa DataType && isdefined(getglobal(Core, n), :instance) && getglobal(Core, n).instance isa Core.Builtin]
    cnames = unsorted_names(Core)
    for f in builtins
        if !haskey(cache[:Core], f)
            cache[:Core][f] = FunctionStore(getglobal(Core, Symbol(f)), Symbol(f), Core, Symbol(f) in cnames)
        end
    end
    push!(cache[:Core][:_apply].methods, MethodStore(:_apply, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core].vals, :_apply_iterate) && push!(cache[:Core][:_apply_iterate].methods, MethodStore(:_apply_iterate, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    if isdefined(Core, :_call_latest)
        push!(cache[:Core][:_call_latest].methods, MethodStore(:_call_latest, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
        push!(cache[:Core][:_call_in_world].methods, MethodStore(:_call_in_world, :Core, "built-in", 0, [:world => FakeTypeName(UInt), :f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    else
        if isdefined(Core, :_apply_in_world)
            push!(cache[:Core][:_apply_in_world].methods, MethodStore(:_apply_in_world, :Core, "built-in", 0, [:world => FakeTypeName(UInt), :f => FakeTypeName(Function), :args => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
        end
        push!(cache[:Core][:_apply_latest].methods, MethodStore(:_apply_latest, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    end
    push!(cache[:Core][:_apply_pure].methods, MethodStore(:_apply_pure, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:_expr].methods, MethodStore(:_expr, :Core, "built-in", 0, [:head => FakeTypeName(Symbol), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Expr)))
    haskey(cache[:Core].vals, :_typevar) && push!(cache[:Core][:_typevar].methods, MethodStore(:_typevar, :Core, "built-in", 0, [:name => FakeTypeName(Symbol), :lb => FakeTypeName(Any), :ub => FakeTypeName(Any)], Symbol[], FakeTypeName(TypeVar)))
    push!(cache[:Core][:applicable].methods, MethodStore(:applicable, :Core, "built-in", 0, [:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Bool)))
    push!(cache[:Core][:apply_type].methods, MethodStore(:apply_type, :Core, "built-in", 0, [:T => FakeTypeName(UnionAll), :types => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(UnionAll)))
    push!(cache[:Core][:arrayref].methods, MethodStore(:arrayref, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any), :c => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:arrayset].methods, MethodStore(:arrayset, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any), :c => FakeTypeName(Any), :d => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:arraysize].methods, MethodStore(:arraysize, :Core, "built-in", 0, [:a => FakeTypeName(Array), :i => FakeTypeName(Int)], Symbol[], FakeTypeName(Int)))
    haskey(cache[:Core], :const_arrayref) && push!(cache[:Core][:const_arrayref].methods, MethodStore(:const_arrayref, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:fieldtype].methods, MethodStore(:fieldtype, :Core, "built-in", 0, [:t => FakeTypeName(DataType), :field => FakeTypeName(Symbol)], Symbol[], FakeTypeName(Type{T} where T)))
    push!(cache[:Core][:getfield].methods, MethodStore(:getfield, :Core, "built-in", 0, [:object => FakeTypeName(Any), :item => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:ifelse].methods, MethodStore(:ifelse, :Core, "built-in", 0, [:condition => FakeTypeName(Bool), :x => FakeTypeName(Any), :y => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    # `invoke` is handled below (its methods are replaced with the documented forms).
    push!(cache[:Core][:isa].methods, MethodStore(:isa, :Core, "built-in", 0, [:a => FakeTypeName(Any), :T => FakeTypeName(Type{T} where T)], Symbol[], FakeTypeName(Bool)))
    push!(cache[:Core][:isdefined].methods, MethodStore(:isdefined, :Core, "built-in", 0, [:value => FakeTypeName(Any), :field => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:nfields].methods, MethodStore(:nfields, :Core, "built-in", 0, [:x => FakeTypeName(Any)], Symbol[], FakeTypeName(Int)))
    push!(cache[:Core][:setfield!].methods, MethodStore(:setfield!, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol), :x => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:sizeof].methods, MethodStore(:sizeof, :Core, "built-in", 0, [:obj => FakeTypeName(Any)], Symbol[], FakeTypeName(Int)))
    push!(cache[:Core][:svec].methods, MethodStore(:svec, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:throw].methods, MethodStore(:throw, :Core, "built-in", 0, [:e => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:tuple].methods, MethodStore(:tuple, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:typeassert].methods, MethodStore(:typeassert, :Core, "built-in", 0, [:x => FakeTypeName(Any), :T => FakeTypeName(Type{T} where T)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:typeof].methods, MethodStore(:typeof, :Core, "built-in", 0, [:x => FakeTypeName(Any)], Symbol[], FakeTypeName(Type{T} where T)))

    push!(cache[:Core][:getproperty].methods, MethodStore(:getproperty, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:setproperty!].methods, MethodStore(:setproperty!, :Core, "built-in", 0, [:value => FakeTypeName(Any), :name => FakeTypeName(Symbol), :x => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_abstracttype) && push!(cache[:Core][:_abstracttype].methods, MethodStore(:_abstracttype, :Core, "built-in", 0, [:m => FakeTypeName(Module), :x => FakeTypeName(Symbol), :p => FakeTypeName(Core.SimpleVector)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_primitivetype) && push!(cache[:Core][:_primitivetype].methods, MethodStore(:_primitivetype, :Core, "built-in", 0, [:m => FakeTypeName(Module), :x => FakeTypeName(Symbol), :p => FakeTypeName(Core.SimpleVector), :n => FakeTypeName(Core.Int)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_equiv_typedef) && push!(cache[:Core][:_equiv_typedef].methods, MethodStore(:_equiv_typedef, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_setsuper!) && push!(cache[:Core][:_setsuper!].methods, MethodStore(:_setsuper!, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_structtype) && push!(cache[:Core][:_structtype].methods, MethodStore(:_structtype, :Core, "built-in", 0, [:m => FakeTypeName(Module), :x => FakeTypeName(Symbol), :p => FakeTypeName(Core.SimpleVector), :fields => FakeTypeName(Core.SimpleVector), :mut => FakeTypeName(Bool), :z => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    haskey(cache[:Core], :_typebody!) && push!(cache[:Core][:_typebody!].methods, MethodStore(:_typebody!, :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:(===)].methods, MethodStore(:(===), :Core, "built-in", 0, [:a => FakeTypeName(Any), :b => FakeTypeName(Any)], Symbol[], FakeTypeName(Any)))
    push!(cache[:Core][:(<:)].methods, MethodStore(:(<:), :Core, "built-in", 0, [:a => FakeTypeName(Type{T} where T), :b => FakeTypeName(Type{T} where T)], Symbol[], FakeTypeName(Any)))
    # Add unspecified methods for Intrinsics, working out the actual methods will need to be done by hand?
    for n in names(Core.Intrinsics)
        if getglobal(Core.Intrinsics, n) isa Core.IntrinsicFunction
            push!(cache[:Core][:Intrinsics][n].methods, MethodStore(n, :Intrinsics, "built-in", 0, [:args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
        end
    end

    for bi in builtins
        if haskey(cache[:Core], bi) && isempty(cache[:Core][bi].methods)
            # Add at least one arbitrary method for anything left over
            push!(cache[:Core][bi].methods, MethodStore(bi, :none, "built-in", 0, [:x => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)))
        end
    end

    cache[:Core][:ccall] = FunctionStore(VarRef(VarRef(Core), :ccall),
        MethodStore[
            MethodStore(:ccall, :Core, "built-in", 0, [:args => FakeTypeName(Vararg{Any})], Symbol[], FakeTypeName(Any)) # General method - should be fixed
        ],
        "`ccall((function_name, library), returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_name, returntype, (argtype1, ...), argvalue1, ...)`\n`ccall(function_pointer, returntype, (argtype1, ...), argvalue1, ...)`\n\nCall a function in a C-exported shared library, specified by the tuple (`function_name`, `library`), where each component is either a string or symbol. Instead of specifying a library, one\ncan also use a `function_name` symbol or string, which is resolved in the current process. Alternatively, `ccall` may also be used to call a function pointer `function_pointer`, such as one\nreturned by `dlsym`.\n\nNote that the argument type tuple must be a literal tuple, and not a tuple-valued variable or expression.\n\nEach `argvalue` to the `ccall` will be converted to the corresponding `argtype`, by automatic insertion of calls to `unsafe_convert(argtype, cconvert(argtype, argvalue))`. (See also the documentation for `unsafe_convert` and `cconvert` for further details.) In most cases, this simply results in a call to `convert(argtype, argvalue)`.",
        VarRef(VarRef(Core), :ccall),
        true)
    push!(cache[:Core].exportednames, :ccall)
    push!(cache[:Core].publicnames, :ccall)
    cache[:Core][Symbol("@__doc__")] = FunctionStore(VarRef(VarRef(Core), Symbol("@__doc__")), [], "", VarRef(VarRef(Core), Symbol("@__doc__")), true)
    cache_methods(getglobal(Core, Symbol("@__doc__")), Symbol("@__doc__"), cache, false)
    # `invokelatest` and `invoke_in_world` forward keyword arguments to their
    # target (`f(args...; kwargs...)`), but each is a single crawled method whose
    # `Base.kwarg_decl` reports no keywords and whose parameters are the generic
    # `(x...)` — so `check_call` would flag `invokelatest(f, args...; kw=v)` as an
    # unknown keyword, and hover/signature-help shows meaningless `x...`. Replace
    # the methods with their documented forms (mirroring the internal
    # `_call_latest`/`_call_in_world` signatures) plus a keyword splat so any
    # keyword is accepted. (They are Core-owned; Base re-exports them as VarRefs
    # to these stores.)
    for (n, sig) in (
        :invokelatest => Pair{Any,Any}[:f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})],
        :invoke_in_world => Pair{Any,Any}[:world => FakeTypeName(UInt), :f => FakeTypeName(Function), :args => FakeTypeName(Vararg{Any})],
    )
        haskey(cache[:Core], n) || continue
        fs = cache[:Core][n]
        fs isa FunctionStore || continue
        empty!(fs.methods)
        push!(fs.methods, MethodStore(n, :Core, "built-in", 0, sig, [Symbol("kwargs...")], FakeTypeName(Any)))
    end
    # `invoke`'s crawled signature is imprecise (it carries a spurious extra
    # positional, so the `argtypes::Type` constraint lands on the wrong argument
    # and valid calls are flagged). Replace it with the three documented forms,
    # each forwarding `; kwargs...`.
    if haskey(cache[:Core], :invoke) && cache[:Core][:invoke] isa FunctionStore
        invoke_methods = cache[:Core][:invoke].methods
        empty!(invoke_methods)
        for at in (FakeTypeName(Type{T} where T), FakeTypeName(Method), FakeTypeName(Core.CodeInstance))
            push!(invoke_methods, MethodStore(:invoke, :Core, "built-in", 0,
                [:f => FakeTypeName(Function), :argtypes => at, :args => FakeTypeName(Vararg{Any})],
                [Symbol("kwargs...")], FakeTypeName(Any)))
        end
    end
    # Accounts for Base functions that are always-available but which loaded stdlibs
    # (Random, LinearAlgebra, …) extend: the Core+Base crawl attributes each method to
    # its defining module, so methods defined outside Core/Base are dropped and those
    # Base functions end up method-incomplete (rand 0/76, randn 0/14, kron! 0/13 — fully
    # external; kron 1/17 — partial; plus operators `*`, `\`, `+`, … and others). Re-attach
    # the dropped methods generically rather than by hand, but ONLY those defined in an
    # always-available sysimage stdlib: load_core runs during JuliaWorkspaces' precompile
    # with its full dependency tree loaded, so an unscoped re-attach leaks methods from
    # Dates/LibGit2/CSTParser/… into the shipped Base store. Safe against double-counting at
    # request time via the `iterate_over_ss_methods` de-dup.
    for n in unsorted_names(Base; all = true, imported = true)
        _isdefinedglobal(Base, n) || continue
        ok, f = _try_getglobal(Base, n)
        ok || continue
        (f isa Function && !(f isa Core.Builtin)) || continue   # builtins/intrinsics handled separately
        haskey(cache[:Base], n) || continue
        st = cache[:Base][n]
        st isa FunctionStore || continue
        # Cheap gate: `methodlist` is exactly what `cache_methods` iterates, so a store
        # that already holds every method (crawl captured it fully) is skipped.
        length(st.methods) >= length(methodlist(f)) && continue
        for (mmod, mstore) in cache_methods(f, n, cache, get_return_type)
            _is_always_available(mmod) || continue                       # only re-attach sysimage-stdlib methods
            any(existing -> _samestore(existing, mstore), st.methods) && continue  # de-dup safety
            push!(st.methods, mstore)
        end
    end

    return cache
end


function collect_extended_methods(depot::EnvStore, extendeds = Dict{VarRef,Vector{VarRef}}())
    for m in depot
        collect_extended_methods(m[2], extendeds, m[2].name)
    end
    extendeds
end

function collect_extended_methods(mod::ModuleStore, extendeds, mname)
    for (n, v) in mod.vals
        if (v isa FunctionStore) && v.extends != v.name
            haskey(extendeds, v.extends) ? push!(extendeds[v.extends], mname) : (extendeds[v.extends] = VarRef[v.extends.parent, mname])
        elseif v isa ModuleStore
            collect_extended_methods(v, extendeds, v.name)
        end
    end
end

getallns() = let allns = Base.IdSet{Symbol}(); oneverything((m, s, x, state) -> push!(allns, s)); allns end

"""
    split_module_names(m::Module, allns)

Return two lists of names accessible from calling `getfield(m, somename)`. The first
contains those symbols returned by `Base.names(m, all = true)`. The second contains
all others, including imported symbols and those introduced by the `using` of modules.
"""
function split_module_names(m::Module, allns)
    internal_names = getnames(m)
    availablenames = Set{Symbol}([s for s in allns if _isdefinedglobal(m, s)])
    # usinged_names = Set{Symbol}()

    for n in availablenames
        if (n in internal_names)
            pop!(availablenames, n)
        end
    end
    allms = get_all_modules()
    for u in get_used_modules(m, allms)
        for n in unsorted_names(u)
            if n in availablenames
                pop!(availablenames, n)
                # push!(usinged_names, pop!(availablenames, n))
            end
        end
    end
    internal_names, availablenames
end

get_all_modules() = let allms = Base.IdSet{Module}(); apply_to_everything(x -> if x isa Module push!(allms, x) end); allms end
get_used_modules(M, allms = get_all_modules()) = [m for m in allms if usedby(M, m)]
