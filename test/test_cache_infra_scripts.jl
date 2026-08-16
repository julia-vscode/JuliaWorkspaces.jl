# Integration tests for scripts/regen_symbolcache.sh and scripts/reconcile_symbolcache.sh.
#
# Each @testitem gates on rclone and linux.  The scripts assume a GNU userland —
# `package_symbolcache.sh` calls `nproc`, for one — so they do not run on macOS,
# and they are bash so they do not run on Windows either.  All scratch dirs live
# under mktempdir() and are cleaned up automatically.  The local rclone backend
# (:local:<dir>) is used — no R2 credentials or Docker required.
#
# CI installs rclone on the linux workers (.github/ci_prep.jl), so these run for
# real there; elsewhere they skip.

@testsnippet CacheInfraScripts begin
    # `success` spawns with an empty stdio set, so a failing script's stderr is
    # discarded and the test reports only `false`. Capture it and report it on
    # failure — but only on failure, since these scripts are chatty when they work.
    function run_script(cmd)
        out, err = IOBuffer(), IOBuffer()
        p = run(pipeline(ignorestatus(cmd), stdout = out, stderr = err); wait = true)
        ok = success(p)
        ok || @error(
            "cache-infra script failed", cmd, exitcode = p.exitcode,
            stdout = String(take!(out)), stderr = String(take!(err))
        )
        return ok
    end
end

@testitem "cache-infra: the shell STORE_VERSION matches CACHE_STORE_VERSION" begin
    using JuliaWorkspaces
    # symbolcache_common.sh keeps a hand-maintained copy of the Julia constant;
    # a bump that misses it points every script at the previous store version.
    common = read(joinpath(@__DIR__, "..", "scripts", "symbolcache_common.sh"), String)
    # `\r?` before the anchor: nothing forces LF on `.sh` here, so a Windows
    # checkout has CRLF endings and an anchored `$` sits behind the `\r`.
    m = match(r"^STORE_VERSION=\"\$\{SYMBOLCACHE_STORE_VERSION:-(v\d+)\}\"\r?$"m, common)
    @test m !== nothing
    @test m !== nothing && m[1] == JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
end

# ===========================================================================
# regen_symbolcache.sh tests
# ===========================================================================

@testitem "cache-infra regen: full run against empty remote" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION

    # ---- helpers (inline so no @testmodule dependency) --------------------
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end
    # -----------------------------------------------------------------------

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        stub    = joinpath(tmp, "stub_sweep.sh")

        uuid_ok  = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        uuid_bad = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        make_stub_sweep(stub,
            ["E/Example/$uuid_ok/h1"],
            [(uuid=uuid_ok,  treehash="h1", status="ok"),
             (uuid=uuid_bad, treehash="h2", status="unsatisfiable")])

        script = joinpath(scripts, "regen_symbolcache.sh")
        remote = ":local:" * abspath(bucket)
        cmd = `bash $script --remote $remote --mode full --work $workdir --sweep-cmd $("bash " * stub)`
        @test run_script(cmd)

        # 1a. artifact present at expected path
        artifact = joinpath(bucket, "store", V, "packages",
                            "E", "Example", uuid_ok, "h1.tar.gz")
        @test isfile(artifact)

        # 1b. index.tar.gz contains the ok key
        index = read_index_tar(bucket)
        @test "$uuid_ok/h1" in index

        # 1c. tombstones.txt.gz contains the unsatisfiable key but NOT the ok key
        tombs = read_tombstones_gz(bucket)
        @test "$uuid_bad/h2" in tombs
        @test !("$uuid_ok/h1" in tombs)
    end
end

@testitem "cache-infra regen: incremental run preserves index union" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end

    has_rclone && mktempdir() do tmp
        bucket = joinpath(tmp, "bucket"); mkpath(bucket)
        stub   = joinpath(tmp, "stub_sweep.sh")
        remote = ":local:" * abspath(bucket)
        regen  = joinpath(scripts, "regen_symbolcache.sh")

        uuid_ok  = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        uuid_bad = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        # --- Run 1: full, one success ---
        workdir1 = joinpath(tmp, "work1"); mkpath(workdir1)
        make_stub_sweep(stub,
            ["E/Example/$uuid_ok/h1"],
            [(uuid=uuid_ok,  treehash="h1", status="ok"),
             (uuid=uuid_bad, treehash="h2", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir1 --sweep-cmd $("bash " * stub)`)

        @test "$uuid_ok/h1" in read_index_tar(bucket)

        # --- Run 2: incremental, stub produces EMPTY store + empty results ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub, String[], NamedTuple[])
        @test run_script(`bash $regen --remote $remote --mode incremental --work $workdir2 --sweep-cmd $("bash " * stub)`)

        # KEY ASSERTION: original key must still be in the index (union never shrinks)
        @test "$uuid_ok/h1" in read_index_tar(bucket)
    end
end

@testitem "cache-infra regen: incremental tombstone merge" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end

    has_rclone && mktempdir() do tmp
        bucket = joinpath(tmp, "bucket"); mkpath(bucket)
        stub   = joinpath(tmp, "stub_sweep.sh")
        remote = ":local:" * abspath(bucket)
        regen  = joinpath(scripts, "regen_symbolcache.sh")

        uuid_ok   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        uuid_bad1 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        uuid_bad2 = "cccccccc-cccc-cccc-cccc-cccccccccccc"

        # --- Run 1: full, one success + one failure ---
        workdir1 = joinpath(tmp, "work1"); mkpath(workdir1)
        make_stub_sweep(stub,
            ["E/Example/$uuid_ok/h1"],
            [(uuid=uuid_ok,   treehash="h1", status="ok"),
             (uuid=uuid_bad1, treehash="h2", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir1 --sweep-cmd $("bash " * stub)`)

        @test "$uuid_bad1/h2" in read_tombstones_gz(bucket)

        # --- Run 2: incremental, new unsatisfiable ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub, String[],
            [(uuid=uuid_bad2, treehash="h3", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode incremental --work $workdir2 --sweep-cmd $("bash " * stub)`)

        tombs2 = read_tombstones_gz(bucket)
        # Both old and new tombstone keys must be present
        @test "$uuid_bad1/h2" in tombs2
        @test "$uuid_bad2/h3" in tombs2
    end
end

@testitem "cache-infra regen: full-mode shard preserves other shards' tombstones" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end

    has_rclone && mktempdir() do tmp
        bucket = joinpath(tmp, "bucket"); mkpath(bucket)
        stub   = joinpath(tmp, "stub_sweep.sh")
        remote = ":local:" * abspath(bucket)
        regen  = joinpath(scripts, "regen_symbolcache.sh")

        uuid_bad1 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        uuid_bad2 = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        uuid_ok   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        # A full sweep runs as n sequential shard jobs, each invoking the regen
        # script over 1/n of the versions. Simulate two shards of one sweep.

        # --- Shard A: tombstones uuid_bad1/h2 ---
        workdir1 = joinpath(tmp, "work1"); mkpath(workdir1)
        make_stub_sweep(stub, String[],
            [(uuid=uuid_bad1, treehash="h2", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir1 --sweep-cmd $("bash " * stub)`)
        @test "$uuid_bad1/h2" in read_tombstones_gz(bucket)

        # --- Shard B: different partition; never attempts uuid_bad1/h2 ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub,
            ["E/Example/$uuid_ok/h1"],
            [(uuid=uuid_ok,   treehash="h1", status="ok"),
             (uuid=uuid_bad2, treehash="h3", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir2 --sweep-cmd $("bash " * stub)`)

        tombs = read_tombstones_gz(bucket)
        # KEY ASSERTION: shard A's tombstone survives shard B's upload
        @test "$uuid_bad1/h2" in tombs
        @test "$uuid_bad2/h3" in tombs
        @test !("$uuid_ok/h1" in tombs)
    end
end

@testitem "cache-infra regen: full-mode retry graduates a tombstone that now succeeds" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end

    has_rclone && mktempdir() do tmp
        bucket = joinpath(tmp, "bucket"); mkpath(bucket)
        stub   = joinpath(tmp, "stub_sweep.sh")
        remote = ":local:" * abspath(bucket)
        regen  = joinpath(scripts, "regen_symbolcache.sh")

        uuid_bad = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        # --- Run 1: full, the version fails and is tombstoned ---
        workdir1 = joinpath(tmp, "work1"); mkpath(workdir1)
        make_stub_sweep(stub, String[],
            [(uuid=uuid_bad, treehash="h2", status="unsatisfiable")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir1 --sweep-cmd $("bash " * stub)`)
        @test "$uuid_bad/h2" in read_tombstones_gz(bucket)

        # --- Run 2: full retries it and it now succeeds ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub,
            ["B/Bad/$uuid_bad/h2"],
            [(uuid=uuid_bad, treehash="h2", status="ok")])
        @test run_script(`bash $regen --remote $remote --mode full --work $workdir2 --sweep-cmd $("bash " * stub)`)

        # Graduated: the key moved from tombstones to the index
        @test !("$uuid_bad/h2" in read_tombstones_gz(bucket))
    end
end

@testitem "cache-infra regen: cancelled status excluded from tombstones" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function make_stub_sweep(path, artifacts, results)
        store_lines = join(["mkdir -p \"\$WORK/store/$a\"; echo x > \"\$WORK/store/$a.jstore\""
                            for a in artifacts], "\n")
        json_lines  = join(["echo '{\"uuid\":\"$(r.uuid)\",\"treehash\":\"$(r.treehash)\",\"status\":\"$(r.status)\"}' >> \"\$WORK/results.jsonl\""
                            for r in results], "\n")
        write(path, """#!/usr/bin/env bash
set -euo pipefail
WORK=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --work) WORK="\$2"; shift 2 ;;
        *)      shift ;;
    esac
done
[[ -n "\$WORK" ]] || { echo "stub: --work required" >&2; exit 1; }
mkdir -p "\$WORK/store"
touch "\$WORK/results.jsonl"
$store_lines
$json_lines
""")
        chmod(path, 0o755)
    end

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        stub    = joinpath(tmp, "stub_sweep.sh")
        remote  = ":local:" * abspath(bucket)

        uuid_cancelled = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        uuid_failed    = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        make_stub_sweep(stub, String[],
            [(uuid=uuid_cancelled, treehash="hc", status="cancelled"),
             (uuid=uuid_failed,    treehash="hf", status="failed")])

        @test run_script(`bash $(joinpath(scripts, "regen_symbolcache.sh")) --remote $remote --mode full --work $workdir --sweep-cmd $("bash " * stub)`)

        tombs = read_tombstones_gz(bucket)
        # cancelled must NOT appear in tombstones
        @test !("$uuid_cancelled/hc" in tombs)
        # failed MUST appear
        @test "$uuid_failed/hf" in tombs
    end
end

# ===========================================================================
# seed_symbolcache.sh tests
# ===========================================================================

@testitem "cache-infra seed: publishes artifacts + index + tombstones from a store" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    has_rclone && mktempdir() do tmp
        store   = joinpath(tmp, "store")
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        remote  = ":local:" * abspath(bucket)

        uuid_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        uuid_b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        uuid_c = "cccccccc-cccc-cccc-cccc-cccccccccccc"

        # Fake store with successes (.jstore) and failure markers (.unavailable).
        for (initial, name, uuid, stem) in [
                ("E", "Example", uuid_a, "h1"),
                ("C", "Crayons", uuid_b, "h2")]
            d = joinpath(store, initial, name, uuid); mkpath(d)
            write(joinpath(d, "$stem.jstore"), "x")
        end
        # uuid_c/h3: a genuine failure tombstone (no artifact).
        d_c = joinpath(store, "F", "Foo", uuid_c); mkpath(d_c)
        write(joinpath(d_c, "h3.unavailable"), "unsatisfiable\n")
        # uuid_a/h1: stale marker alongside its artifact — must be dropped (disjoint).
        write(joinpath(store, "E", "Example", uuid_a, "h1.unavailable"), "failed\n")

        cmd = `bash $(joinpath(scripts, "seed_symbolcache.sh")) --remote $remote --store $store --work $workdir`
        @test run_script(cmd)

        # Artifacts uploaded at the expected paths
        @test isfile(joinpath(bucket, "store", V, "packages", "E", "Example", uuid_a, "h1.tar.gz"))
        @test isfile(joinpath(bucket, "store", V, "packages", "C", "Crayons", uuid_b, "h2.tar.gz"))

        # Index lists both artifact keys
        index = read_index_tar(bucket)
        @test "$uuid_a/h1" in index
        @test "$uuid_b/h2" in index

        # Tombstones carry the genuine failure; the stale marker (has an artifact) is dropped
        tombs = read_tombstones_gz(bucket)
        @test "$uuid_c/h3" in tombs
        @test !("$uuid_a/h1" in tombs)
    end
end

# ===========================================================================
# reconcile_symbolcache.sh tests
# ===========================================================================

@testitem "cache-infra reconcile: index recovery + stale tombstone drop" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    function read_tombstones_gz(bucket)
        gz = joinpath(bucket, "store", V, "_state", "tombstones.txt.gz")
        isfile(gz) || return String[]
        raw = read(pipeline(`gzip -dc $gz`), String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        remote  = ":local:" * abspath(bucket)

        uuid_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        uuid_b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        uuid_z = "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"

        # Seed two artifact tar.gz files: each tar contains a placeholder file
        for (initial, name, uuid, stem) in [
                ("E", "Example", uuid_a, "h1"),
                ("C", "Crayons", uuid_b, "h2")]
            dir = joinpath(bucket, "store", V, "packages", initial, name, uuid)
            mkpath(dir)
            placeholder = joinpath(dir, "$stem.jstore")
            write(placeholder, "x")
            run(`tar -czf $(joinpath(dir, "$stem.tar.gz")) -C $dir $stem.jstore`)
            rm(placeholder)
        end

        # Stale index: lists only uuid_a/h1
        idxdir = joinpath(tmp, "idx_staging"); mkpath(idxdir)
        write(joinpath(idxdir, "index.txt"), "$uuid_a/h1\n")
        mkpath(joinpath(bucket, "store", V))
        run(`tar -czf $(joinpath(bucket, "store", V, "index.tar.gz")) -C $idxdir index.txt`)

        # Tombstones: uuid_a/h1 (stale — artifact exists) + uuid_z/h9 (no artifact)
        statedir = joinpath(bucket, "store", V, "_state"); mkpath(statedir)
        run(pipeline(IOBuffer("$uuid_a/h1\n$uuid_z/h9\n"),
                     `gzip -c`,
                     joinpath(statedir, "tombstones.txt.gz")))

        cmd = `bash $(joinpath(scripts, "reconcile_symbolcache.sh")) --remote $remote --work $workdir`
        @test run_script(cmd)

        # 5a. Rebuilt index lists BOTH artifact keys
        index = read_index_tar(bucket)
        @test "$uuid_a/h1" in index
        @test "$uuid_b/h2" in index

        # 5b. Tombstones retain only the no-artifact key; stale key dropped
        tombs = read_tombstones_gz(bucket)
        @test "$uuid_z/h9" in tombs
        @test !("$uuid_a/h1" in tombs)
    end
end

@testitem "cache-infra reconcile: layer-1 abort on rclone list failure" begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)

        uuid_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        # Seed a non-empty index (no packages/ dir at all — simulates lost packages)
        idxdir = joinpath(tmp, "idx_staging"); mkpath(idxdir)
        write(joinpath(idxdir, "index.txt"), "$uuid_a/h1\nuuid-b/h2\n")
        idx_path = joinpath(bucket, "store", V, "index.tar.gz")
        mkpath(dirname(idx_path))
        run(`tar -czf $idx_path -C $idxdir index.txt`)

        # Snapshot the original index bytes for comparison
        original_bytes = read(idx_path)

        # Use a deliberately bad remote (nonexistent rclone config name).
        # rclone exits non-zero with an error that does NOT match the
        # "directory not found" pattern, triggering layer-1 abort.
        bad_remote = "badremote_does_not_exist_xyz:bucket"
        cmd = `bash $(joinpath(scripts, "reconcile_symbolcache.sh")) --remote $bad_remote --work $workdir`

        # Script must exit non-zero
        @test !success(ignorestatus(cmd))

        # index.tar.gz must be UNCHANGED (bytes identical) — the abort happened
        # before any upload, so the existing index was never overwritten
        @test isfile(idx_path)
        @test read(idx_path) == original_bytes
    end
end

@testitem "cache-infra reconcile: layer-2 abort on empty list with existing index" begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        remote  = ":local:" * abspath(bucket)

        uuid_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        # Create an empty packages/ dir (rclone lsf succeeds but finds nothing)
        mkpath(joinpath(bucket, "store", V, "packages"))

        # Non-empty existing index
        idxdir = joinpath(tmp, "idx_staging"); mkpath(idxdir)
        write(joinpath(idxdir, "index.txt"), "$uuid_a/h1\n")
        idx_path = joinpath(bucket, "store", V, "index.tar.gz")
        run(`tar -czf $idx_path -C $idxdir index.txt`)

        original_bytes = read(idx_path)

        cmd = `bash $(joinpath(scripts, "reconcile_symbolcache.sh")) --remote $remote --work $workdir`

        # Must exit non-zero (layer-2 abort: empty list, non-empty existing index)
        @test !success(ignorestatus(cmd))

        # index.tar.gz unchanged
        @test read(idx_path) == original_bytes
    end
end

@testitem "cache-infra reconcile: genuine-empty first run produces 0-entry index" setup=[CacheInfraScripts] begin
    using JuliaWorkspaces
    has_rclone = Sys.islinux() && Sys.which("rclone") !== nothing
    has_rclone || @info "skipping cache-infra integration test: needs rclone on linux"
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    has_rclone && mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        remote  = ":local:" * abspath(bucket)

        # Empty packages/ dir + NO existing index
        mkpath(joinpath(bucket, "store", V, "packages"))

        cmd = `bash $(joinpath(scripts, "reconcile_symbolcache.sh")) --remote $remote --work $workdir`

        # Must exit 0
        @test run_script(cmd)

        # Produced a 0-entry index
        index = read_index_tar(bucket)
        @test isempty(index)
    end
end
