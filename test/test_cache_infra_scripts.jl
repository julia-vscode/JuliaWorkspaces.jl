# Integration tests for scripts/regen_symbolcache.sh and scripts/reconcile_symbolcache.sh.
#
# Each @testitem gates on rclone availability.  All scratch dirs live under
# mktempdir() and are cleaned up automatically.  The local rclone backend
# (:local:<dir>) is used — no R2 credentials or Docker required.
#
# Run selectively:
#   using TestItemRunner
#   @run_package_tests filter=ti->occursin("cache-infra", ti.name)

# ===========================================================================
# regen_symbolcache.sh tests
# ===========================================================================

@testitem "cache-infra regen: full run against empty remote" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
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
        cmd = Cmd(`bash $script`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote,
            "MODE"          => "full",
            "WORK"          => workdir,
            "SWEEP_CMD"     => "bash $stub",
        )))
        @test success(cmd)

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

@testitem "cache-infra regen: incremental run preserves index union" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
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
        @test success(Cmd(`bash $regen`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote, "MODE" => "full",
            "WORK" => workdir1, "SWEEP_CMD" => "bash $stub"))))

        @test "$uuid_ok/h1" in read_index_tar(bucket)

        # --- Run 2: incremental, stub produces EMPTY store + empty results ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub, String[], NamedTuple[])
        @test success(Cmd(`bash $regen`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote, "MODE" => "incremental",
            "WORK" => workdir2, "SWEEP_CMD" => "bash $stub"))))

        # KEY ASSERTION: original key must still be in the index (union never shrinks)
        @test "$uuid_ok/h1" in read_index_tar(bucket)
    end
end

@testitem "cache-infra regen: incremental tombstone merge" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
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
        @test success(Cmd(`bash $regen`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote, "MODE" => "full",
            "WORK" => workdir1, "SWEEP_CMD" => "bash $stub"))))

        @test "$uuid_bad1/h2" in read_tombstones_gz(bucket)

        # --- Run 2: incremental, new unsatisfiable ---
        workdir2 = joinpath(tmp, "work2"); mkpath(workdir2)
        make_stub_sweep(stub, String[],
            [(uuid=uuid_bad2, treehash="h3", status="unsatisfiable")])
        @test success(Cmd(`bash $regen`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote, "MODE" => "incremental",
            "WORK" => workdir2, "SWEEP_CMD" => "bash $stub"))))

        tombs2 = read_tombstones_gz(bucket)
        # Both old and new tombstone keys must be present
        @test "$uuid_bad1/h2" in tombs2
        @test "$uuid_bad2/h3" in tombs2
    end
end

@testitem "cache-infra regen: cancelled status excluded from tombstones" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        stub    = joinpath(tmp, "stub_sweep.sh")
        remote  = ":local:" * abspath(bucket)

        uuid_cancelled = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        uuid_failed    = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        make_stub_sweep(stub, String[],
            [(uuid=uuid_cancelled, treehash="hc", status="cancelled"),
             (uuid=uuid_failed,    treehash="hf", status="failed")])

        @test success(Cmd(`bash $(joinpath(scripts, "regen_symbolcache.sh"))`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote, "MODE" => "full",
            "WORK" => workdir, "SWEEP_CMD" => "bash $stub"))))

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

@testitem "cache-infra seed: publishes artifacts + index + tombstones from a store" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
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

        cmd = Cmd(`bash $(joinpath(scripts, "seed_symbolcache.sh")) $store`;
                  env=merge(ENV, Dict("RCLONE_REMOTE" => remote, "WORK" => workdir)))
        @test success(cmd)

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

@testitem "cache-infra reconcile: index recovery + stale tombstone drop" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
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

    mktempdir() do tmp
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

        cmd = Cmd(`bash $(joinpath(scripts, "reconcile_symbolcache.sh"))`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote,
            "WORK"          => workdir,
        )))
        @test success(cmd)

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
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    mktempdir() do tmp
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
        cmd = Cmd(`bash $(joinpath(scripts, "reconcile_symbolcache.sh"))`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => bad_remote,
            "WORK"          => workdir,
        )))

        # Script must exit non-zero
        @test !success(ignorestatus(cmd))

        # index.tar.gz must be UNCHANGED (bytes identical) — the abort happened
        # before any upload, so the existing index was never overwritten
        @test isfile(idx_path)
        @test read(idx_path) == original_bytes
    end
end

@testitem "cache-infra reconcile: layer-2 abort on empty list with existing index" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    mktempdir() do tmp
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

        cmd = Cmd(`bash $(joinpath(scripts, "reconcile_symbolcache.sh"))`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote,
            "WORK"          => workdir,
        )))

        # Must exit non-zero (layer-2 abort: empty list, non-empty existing index)
        @test !success(ignorestatus(cmd))

        # index.tar.gz unchanged
        @test read(idx_path) == original_bytes
    end
end

@testitem "cache-infra reconcile: genuine-empty first run produces 0-entry index" begin
    if Sys.which("rclone") === nothing
        @info "skipping cache-infra integration test: rclone not on PATH"
        return
    end

    using JuliaWorkspaces
    V = JuliaWorkspaces.SymbolServer.CACHE_STORE_VERSION
    pkg_root = abspath(joinpath(@__DIR__, ".."))
    scripts  = joinpath(pkg_root, "scripts")

    function read_index_tar(bucket)
        gz = joinpath(bucket, "store", V, "index.tar.gz")
        isfile(gz) || return String[]
        raw = read(`tar -xzO -f $gz index.txt`, String)
        filter(!isempty, strip.(split(raw, '\n')))
    end

    mktempdir() do tmp
        bucket  = joinpath(tmp, "bucket"); mkpath(bucket)
        workdir = joinpath(tmp, "work");   mkpath(workdir)
        remote  = ":local:" * abspath(bucket)

        # Empty packages/ dir + NO existing index
        mkpath(joinpath(bucket, "store", V, "packages"))

        cmd = Cmd(`bash $(joinpath(scripts, "reconcile_symbolcache.sh"))`; env=merge(ENV, Dict(
            "RCLONE_REMOTE" => remote,
            "WORK"          => workdir,
        )))

        # Must exit 0
        @test success(cmd)

        # Produced a 0-entry index
        index = read_index_tar(bucket)
        @test isempty(index)
    end
end
