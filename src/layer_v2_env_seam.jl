# The v2 environment seam: the ONLY place the v2 stack touches the
# SymbolServer-backed environment stores. It lives OUTSIDE src/v2/ on purpose —
# the store walk needs `StaticLint.ExternalEnv` / `SymbolServer.ModuleStore`,
# and the v2 boundary guard (test/v2/test_inventory_v2.jl) forbids those tokens
# in src/v2 code. src/v2 files call these queries by name (call-time
# resolution), exactly like the v2 testitem join in layer_testitems.jl.
#
# The contract every query here obeys: STORES NEVER ESCAPE INTO DERIVED
# VALUES. Each query walks the env store at query time and returns plain data
# (String vectors, Symbols) — Salsa backdates on those, and the store-identity
# `isequal` on `ExternalEnv` gives early cutoff when an env is rebuilt
# identical.
#
# The helpers are PORTS of v1's `_resolve_env` / `_resolve_external_module`
# (layer_visibility.jl), not calls into them: when v1 dies, layer_visibility.jl
# is deleted but this env edge survives.

function _v2_resolve_env(rt, root)
    project_uri = derived_project_uri_for_root(rt, root)
    return project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
end

# Walk `path` through the environment's `EnvStore` (top-level module, then
# nested `ModuleStore`s per segment). Returns the final `ModuleStore`, or
# `nothing` if any segment is missing or not itself a module — a missing
# external module "contributes nothing", never an error.
function _v2_resolve_external_store(rt, root, path::Vector{String})
    isempty(path) && return nothing
    env = _v2_resolve_env(rt, root)
    haskey(env.symbols, Symbol(path[1])) || return nothing
    store = env.symbols[Symbol(path[1])]
    for seg in path[2:end]
        haskey(store, Symbol(seg)) || return nothing
        nxt = store[Symbol(seg)]
        nxt isa SymbolServer.ModuleStore || return nothing
        store = nxt
    end
    return store
end

"""
    derived_v2_external_module_exports(rt, root, path) -> Union{Nothing,Vector{String}}

The export list of the external module at `path`, resolved against `root`'s
environment — or `nothing` when the store walk fails (unindexed dependency or
genuinely missing package). Non-`nothing` is therefore also the
"this external path resolves" predicate the visibility layer's extension
validation uses. Order is the store's own `exportednames` order (deterministic
per store), preserved so within-tier last-wins in the visibility fold matches
v1's iteration exactly.
"""
Salsa.@derived function derived_v2_external_module_exports(rt, root::URI, path::Vector{String})
    store = _v2_resolve_external_store(rt, root, path)
    store === nothing && return nothing
    return String[String(en) for en in store.exportednames]
end

"""
    derived_v2_external_exported_module_names(rt, root, path) -> Vector{String}

The subset of the module's exports that are themselves module-valued
(`store[en] isa ModuleStore`) — the names whose wildcard bring-in gets a
module-target ledger entry. Empty when the store is missing (the exports query
already distinguishes missing from empty).
"""
Salsa.@derived function derived_v2_external_exported_module_names(rt, root::URI, path::Vector{String})
    store = _v2_resolve_external_store(rt, root, path)
    store === nothing && return String[]
    return String[String(en) for en in store.exportednames
                  if haskey(store, en) && store[en] isa SymbolServer.ModuleStore]
end

"""
    derived_v2_external_module_member_kind(rt, root, path, name) -> Symbol

One member probe for the visibility layer's colon-list lookup:
`:missing_store` (the module itself didn't resolve), `:absent` (store present,
no such member — v1's member gate is `haskey`, NOT export-gated), `:module`
(member is itself a module), `:datatype` (a `DataTypeStore` — consumed by the
`invalid_type_declaration` takeover; visibility treats it like `:value`), or
`:value`.
"""
Salsa.@derived function derived_v2_external_module_member_kind(rt, root::URI, path::Vector{String}, name::String)
    store = _v2_resolve_external_store(rt, root, path)
    store === nothing && return :missing_store
    haskey(store, Symbol(name)) || return :absent
    v = store[Symbol(name)]
    v isa SymbolServer.ModuleStore && return :module
    # The datatype/value split resolves VarRef forwards and, for constructor
    # FunctionStores, follows `.extends` (`Base.Int` is the constructor whose
    # extends points at Core's DataTypeStore — the same rule v1's
    # `is_never_datatype` applies). The `:module` determination above
    # deliberately does NOT look up (visibility parity with v1's lookup-free
    # member gate).
    env = _v2_resolve_env(rt, root)
    resolved = StaticLint.maybe_lookup(v, env)
    resolved isa SymbolServer.DataTypeStore && return :datatype
    if resolved isa SymbolServer.FunctionStore
        ext = SymbolServer._lookup(resolved.extends, StaticLint.getsymbols(env))
        ext isa SymbolServer.DataTypeStore && return :datatype
    end
    return :value
end

# ── method arities ──────────────────────────────────────────────────────────

"One store method's arity, as plain data (the `func_nargs(::MethodStore)` port)."
const V2StoreArity = @NamedTuple{minargs::Int, maxargs::Int, kws::Vector{Symbol}, kwsplat::Bool}

function _v2_store_method_arity(m::SymbolServer.MethodStore)::V2StoreArity
    minargs, maxargs, kws, kwsplat = 0, 0, Symbol[], false
    for arg in m.sig
        t = last(arg)
        if StaticLint.CoreTypes.isva(t)
            va = StaticLint.unwrap_fakeunionall(t)
            # Bounded `Vararg{T,N}` contributes exactly N args; unbounded forms
            # allow any count.
            if va isa SymbolServer.FakeTypeofVararg && isdefined(va, :N) && va.N isa Integer
                minargs += va.N
                maxargs !== typemax(Int) && (maxargs += va.N)
            else
                maxargs = typemax(Int)
            end
        else
            minargs += 1
            maxargs !== typemax(Int) && (maxargs += 1)
        end
    end
    for kw in m.kws
        endswith(String(kw), "...") ? (kwsplat = true) : push!(kws, kw)
    end
    return (minargs=minargs, maxargs=maxargs, kws=kws, kwsplat=kwsplat)
end

"""
    derived_v2_external_method_arities(rt, root, path, name)
        -> Union{Nothing,Vector{V2StoreArity}}

Every store method's arity for the function/datatype `name` in the external
module at `path`, EXTENDED METHODS INCLUDED — the plain-data projection of
v1's `iterate_over_ss_methods` union. Module-scope gating is deliberately
PERMISSIVE (every extension package in the env counts, not just in-scope
ones): over-accepting arities only widens the accepted set, i.e. fewer
`incorrect_call_args` findings — the safe direction, and it keeps scope
plumbing out of the seam. `nothing` when the name doesn't resolve to a
function/datatype store (callers decline).
"""
Salsa.@derived function derived_v2_external_method_arities(rt, root::URI, path::Vector{String}, name::String)
    store = _v2_resolve_external_store(rt, root, path)
    store === nothing && return nothing
    haskey(store, Symbol(name)) || return nothing
    env = _v2_resolve_env(rt, root)
    b = StaticLint.maybe_lookup(store[Symbol(name)], env)
    (b isa SymbolServer.FunctionStore || b isa SymbolServer.DataTypeStore) || return nothing

    out = V2StoreArity[]
    seen = Set{Tuple{String,Int32,Vector{Pair{Any,Any}}}}()
    for m in b.methods
        push!(seen, StaticLint._ss_method_key(m))
        push!(out, _v2_store_method_arity(m))
    end
    ext_key = b isa SymbolServer.FunctionStore ? b.extends :
              b.name isa SymbolServer.VarRef ? b.name : b.name.name
    extmap = StaticLint.getsymbolextendeds(env)
    if haskey(extmap, ext_key)
        for vr in extmap[ext_key]
            rootmod = SymbolServer._lookup(vr, StaticLint.getsymbols(env))
            rootmod isa SymbolServer.ModuleStore || continue
            haskey(rootmod.vals, ext_key.name) || continue
            v = rootmod.vals[ext_key.name]
            (v isa SymbolServer.FunctionStore || v isa SymbolServer.DataTypeStore) || continue
            for m in v.methods
                k = StaticLint._ss_method_key(m)
                k in seen && continue
                push!(seen, k)
                push!(out, _v2_store_method_arity(m))
            end
        end
    end
    return out
end

"""
    derived_v2_external_first_missing_segment(rt, root, path) -> Union{Nothing,String}

The first segment of `path` at which the store walk fails, or `nothing` when
the whole path resolves — the name v1's `unresolved_import` anchors its
message on.
"""
Salsa.@derived function derived_v2_external_first_missing_segment(rt, root::URI, path::Vector{String})
    isempty(path) && return nothing
    env = _v2_resolve_env(rt, root)
    haskey(env.symbols, Symbol(path[1])) || return path[1]
    store = env.symbols[Symbol(path[1])]
    for seg in path[2:end]
        (haskey(store, Symbol(seg)) && store[Symbol(seg)] isa SymbolServer.ModuleStore) || return seg
        store = store[Symbol(seg)]
    end
    return nothing
end

"""
    derived_v2_implicit_scope_names(rt, root, bare::Bool) -> Vector{String}

Every name a module at `root` can reach without a written import: the exports
of `StaticLint.IMPLICIT_SCOPE_MODULES` (the implicit `using Base`/`using
Core`), plus the builtins Julia gives every module regardless — the implicit
module names themselves, the per-module `include`/`eval`, `Main`, `var`, and
the ccall calling-convention markers v1's checks exempt. A `baremodule` has no
implicit `using Base`, so `bare = true` keeps only the Core side (Julia lowers
`baremodule` with `using Core`) and the builtins Core still provides.

Only *exported* names count for the implicit modules (mirrors v1's
`_implicit_member` / `isexportedby`). Sorted, deduplicated; membership is what
consumers test, so order is unobservable here.
"""
Salsa.@derived function derived_v2_implicit_scope_names(rt, root::URI, bare::Bool)
    env = _v2_resolve_env(rt, root)
    names = Set{String}(["Core", "eval", "include"])
    if !bare
        push!(names, "Base", "Main", "var", "stdcall", "cdecl", "fastcall", "thiscall", "llvmcall")
    end
    mods = bare ? (:Core,) : StaticLint.IMPLICIT_SCOPE_MODULES
    for m in mods
        store = get(env.symbols, m, nothing)
        store isa SymbolServer.ModuleStore || continue
        for en in store.exportednames
            haskey(store, en) && push!(names, String(en))
        end
    end
    return sort!(collect(names))
end

"""
    derived_v2_env_project_deps(rt, root) -> Vector{String}

The declared project dependencies of `root`'s environment, for the
"declared dependency but its symbols could not be indexed" message branch of
`unresolved_import`.
"""
Salsa.@derived function derived_v2_env_project_deps(rt, root::URI)
    env = _v2_resolve_env(rt, root)
    return sort!(String[String(d) for d in env.project_deps])
end
