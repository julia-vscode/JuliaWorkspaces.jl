#!/usr/bin/env julia
# Standalone worker: index ONE pinned package@version in the active project, then
# scrub every newly written cache so its own package's src dir becomes PLACEHOLDER
# (relocatable, matching what the symbolcache download path expects).
#
# argv: <jw_src_root> <store_path> <uuid> <name> <version> <tree_hash>
# Runs with --project=<pinned env>. Reuses SymbolServer.get_store.
#
# Flow: resolve/install FIRST, then load the extractor only if that succeeded —
# so an unresolvable version exits without paying to compile SymbolServer. The
# include stays top-level (and precedes the call that uses it) so no invokelatest
# is needed.

import Pkg

include(joinpath(@__DIR__, "depot_lock.jl"))

const EXIT_OK = 0
const EXIT_UNSAT = 10
const EXIT_INDEX = 20
const EXIT_INTERRUPTED = 130   # 128 + SIGINT; the driver maps this to :cancelled

# Terse single-line failure summary; the driver lifts this line into its
# progress output, so keep it greppable and bounded (the full error with
# backtrace still follows via @error).
function report_failure(stage, err)
    msg = replace(sprint(showerror, err), r"\s*\n\s*" => " | ")
    println(stderr, "jwcloudindex-worker: ", stage, " failed: ", first(msg, 1000))
end

# argv[1] = JuliaWorkspaces `src/` dir. symbolserver.jl is one level up from it.
const SYMBOLSERVER_JL = abspath(joinpath(ARGS[1], "..",
    "juliadynamicanalysisprocess", "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))

function list_jstores(store_path)
    out = Set{String}()
    isdir(store_path) || return out
    for (root, _, files) in walkdir(store_path)
        for f in files
            endswith(f, ".jstore") && push!(out, joinpath(root, f))
        end
    end
    return out
end

# Ensure the pinned version is present. If the active project already has it
# (e.g. a path-deved test fixture), skip the registry add.
function ensure_installed(uuid_s, name, version_s)
    try
        ctx = Pkg.Types.Context()
        # ctx.env.manifest.deps :: Dict{UUID,PackageEntry} (verified on 1.12.6)
        need_add = !haskey(ctx.env.manifest.deps, Base.UUID(uuid_s))
        # Installs into the shared depot are serialized across workers (see
        # depot_lock.jl). Precompilation is rename-atomic and parallel-safe, so
        # it stays outside the lock: disabled here, it runs at first import.
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            with_depot_install_lock(first(Base.DEPOT_PATH)) do
                need_add && Pkg.add(Pkg.PackageSpec(name = name, uuid = Base.UUID(uuid_s),
                                                    version = VersionNumber(version_s)))
                Pkg.instantiate()
            end
        end
    catch err
        err isa InterruptException && return EXIT_INTERRUPTED
        report_failure("resolve/instantiate", err)
        @error "resolve/instantiate failed" exception=(err, catch_backtrace())
        return EXIT_UNSAT
    end
    return EXIT_OK
end

_jwroot, store_path, uuid_s, name, version_s, _tree_hash = ARGS

# Step 1: resolve. Bail before loading the extractor if it's unsatisfiable.
let rc = ensure_installed(uuid_s, name, version_s)
    rc == EXIT_OK || exit(rc)
end

# Step 2: load the extractor (only reached once resolution succeeded).
include(SYMBOLSERVER_JL)                 # defines module `SymbolServer` in Main
using .SymbolServer: get_store, CacheStore, modify_dirs, modify_dir, write_cache

# Step 3: index via the extractor (which loads the pkg itself), then scrub every
# cache it wrote this run so each package's own src dir becomes PLACEHOLDER.
function index_and_scrub(store_path)
    try
        # get_store writes the target and overwrites every dependency cache it
        # loads with this machine's real paths, so scrub every file whose mtime
        # advanced this run (per-file mtime is robust to shared-store clock skew).
        before = Dict{String,Float64}(p => mtime(p) for p in list_jstores(store_path))
        get_store(String(store_path), nothing)
        for path in list_jstores(store_path)
            mtime(path) <= get(before, path, -Inf) && continue   # untouched this run
            # A just-touched file under --jobs>1 may still be mid-write by another
            # worker; a clean read means it's complete (writes rename atomically).
            pkg = try
                open(CacheStore.read, path)                  # Package: has .name, .uuid
            catch err
                err isa CacheStore.CacheCorruptedError && continue
                rethrow()
            end
            Pkg.Types.is_stdlib(pkg.uuid) && continue        # stdlibs: not relocated per-pkg
            loc = Base.locate_package(Base.PkgId(pkg.uuid, pkg.name))
            (loc === nothing || !isfile(loc)) && continue
            src = dirname(loc)
            modify_dirs(pkg.val, f -> modify_dir(f, src, "PLACEHOLDER"))
            write_cache(pkg.uuid, pkg, path)   # atomic; safe for concurrent scrubs
        end
    catch err
        err isa InterruptException && return EXIT_INTERRUPTED
        report_failure("index/scrub", err)
        @error "index/scrub failed" exception=(err, catch_backtrace())
        return EXIT_INDEX
    end
    return EXIT_OK
end

exit(index_and_scrub(store_path))
