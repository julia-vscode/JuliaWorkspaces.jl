#!/usr/bin/env julia
# Standalone worker: index ONE pinned package@version in the active project, then
# scrub every newly written cache so its own package's src dir becomes PLACEHOLDER
# (relocatable, matching what the symbolcache download path expects).
#
# argv: <jw_src_root> <store_path> <uuid> <name> <version> <tree_hash>
# Runs with --project=<pinned env>. Reuses SymbolServer.get_store.
#
# import + include are TOP-LEVEL (illegal inside a function). Loading the
# extractor at top level also puts its module in an earlier world age than
# main()'s call, so we can call its functions directly (no invokelatest).

import Pkg

const EXIT_OK = 0
const EXIT_UNSAT = 10
const EXIT_INDEX = 20
const EXIT_INTERRUPTED = 130   # 128 + SIGINT; the driver maps this to :cancelled

# argv[1] = JuliaWorkspaces `src/` dir. symbolserver.jl is one level up from it.
const SYMBOLSERVER_JL = abspath(joinpath(ARGS[1], "..",
    "juliadynamicanalysisprocess", "JuliaDynamicAnalysisProcess", "src", "symbolserver.jl"))
include(SYMBOLSERVER_JL)                 # defines module `SymbolServer` in Main
using .SymbolServer: get_store, CacheStore, modify_dirs, modify_dir, write_cache

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

function main(args)
    _jwroot, store_path, uuid_s, name, version_s, _tree_hash = args
    uuid = Base.UUID(uuid_s)
    version = VersionNumber(version_s)

    # 1. Ensure the pinned version is present. If the active project already has it
    #    (e.g. a path-deved test fixture), skip the registry add.
    try
        ctx = Pkg.Types.Context()
        # ctx.env.manifest.deps :: Dict{UUID,PackageEntry} (verified on 1.12.6)
        if !haskey(ctx.env.manifest.deps, uuid)
            Pkg.add(Pkg.PackageSpec(name = name, uuid = uuid, version = version))
        end
        Pkg.instantiate()
    catch err
        err isa InterruptException && return EXIT_INTERRUPTED
        @error "resolve/instantiate failed" exception=(err, catch_backtrace())
        return EXIT_UNSAT
    end

    # 2 & 3. Index via the existing extractor (which loads the pkg itself), then
    #        scrub every cache it wrote this run so each package's own src dir
    #        becomes PLACEHOLDER.
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
        @error "index/scrub failed" exception=(err, catch_backtrace())
        return EXIT_INDEX
    end
    return EXIT_OK
end

exit(main(ARGS))
