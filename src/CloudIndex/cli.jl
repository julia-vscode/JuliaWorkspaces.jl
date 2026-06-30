# CLI parsing + mode dispatch for the jwcloudindex app.

struct CliConfig
    registry::Union{Nothing,String}
    store::String
    filter::FilterSpec
    jobs::Int
    timeout::Float64
    resume::Bool
    progress::Bool
    launcher_template::Union{Nothing,String}
    depot::Union{Nothing,String}
    workdir::Union{Nothing,String}
    shard::Union{Nothing,Tuple{Int,Int}}
    mode::Symbol                # :index :dry_run :report_missing
    out::Union{Nothing,String}
    emit_index::Union{Nothing,String}
end

function _usage()
    println("""
    jwcloudindex — generate symbol caches across a Julia registry

      --registry PATH        registry to index (default: installed General)
      --store DIR            .jstore output root (default: ./symbolstore)
      --newest N             keep the newest N versions (default N=1)
      --per-break            apply --newest within each breaking line (major for
                             >=1.0, minor for 0.x) instead of overall
      --all-versions         keep every version
      --include REGEX        repeatable; keep only matching names
      --exclude REGEX        repeatable; drop matching names
      --include-yanked       keep yanked versions (default: drop)
      --include-jll          index _jll packages (default: skip)
      --julia-version V      compat target (default: running version)
      --jobs K               concurrent workers (default: CPU/2)
      --timeout SECONDS      per-worker wall clock (default: 600)
      --shard k/n            process shard k of n (k is 0-based: 0..n-1)
      --launcher TEMPLATE    wrap each worker ({cmd}{depot}{store}{env}{jwroot})
      --depot DIR            shared depot (default: <workdir>/depot)
      --workdir DIR          temp envs + logs (default: mktempdir)
      --no-resume            reindex already-cached entries (default: skip cached)
      --no-progress          suppress the per-completion progress lines (stderr)
      --dry-run              print the filtered worklist; don't index
      --report-missing       print only not-yet-indexed entries; don't index
      --out FILE             with --dry-run/--report-missing, write JSONL
      --emit-index FILE      write the availability index for --store to FILE; don't index
      -h | --help            this message
    """)
end

# tiny argv reader
function parse_args(argv::Vector{String})
    registry = nothing; store = "symbolstore"
    inc = Regex[]; exc = Regex[]; skip_yanked = true; skip_jll = true
    julia_version = VERSION
    n = 1; per_break = false; all_versions = false
    jobs = max(1, Sys.CPU_THREADS ÷ 2); timeout = 600.0; resume = true; progress = true
    launcher_template = nothing; depot = nothing; workdir = nothing
    shard = nothing; mode = :index; out = nothing; emit_index = nothing

    i = 1
    next!() = (i += 1; i <= length(argv) ? argv[i] : error("missing value for $(argv[i-1])"))
    while i <= length(argv)
        a = argv[i]
        if a == "--registry"; registry = next!()
        elseif a == "--store"; store = next!()
        elseif a == "--newest"; n = parse(Int, next!())
        elseif a == "--per-break"; per_break = true
        elseif a == "--all-versions"; all_versions = true
        elseif a == "--include"; push!(inc, Regex(next!()))
        elseif a == "--exclude"; push!(exc, Regex(next!()))
        elseif a == "--include-yanked"; skip_yanked = false
        elseif a == "--include-jll"; skip_jll = false
        elseif a == "--julia-version"; julia_version = VersionNumber(next!())
        elseif a == "--jobs"; jobs = parse(Int, next!())
        elseif a == "--timeout"; timeout = parse(Float64, next!())
        elseif a == "--shard"
            parts = split(next!(), "/"); shard = (parse(Int, parts[1]), parse(Int, parts[2]))
            (shard[2] >= 1 && 0 <= shard[1] < shard[2]) || error("--shard k/n requires n >= 1 and 0 <= k < n, got $(shard[1])/$(shard[2])")
        elseif a == "--launcher"; launcher_template = next!()
        elseif a == "--depot"; depot = next!()
        elseif a == "--workdir"; workdir = next!()
        elseif a == "--no-resume"; resume = false
        elseif a == "--no-progress"; progress = false
        elseif a == "--dry-run"; mode = :dry_run
        elseif a == "--report-missing"; mode = :report_missing
        elseif a == "--out"; out = next!()
        elseif a == "--emit-index"; emit_index = next!()
        elseif a == "-h" || a == "--help"; mode = :help
        else; error("unknown argument: $a")
        end
        i += 1
    end

    spec = FilterSpec(; include=inc, exclude=exc, skip_yanked, skip_jll,
                      julia_version, n, per_break, all_versions)
    return CliConfig(registry, store, spec, jobs, timeout, resume, progress,
                     launcher_template, depot, workdir, shard, mode, out, emit_index)
end

function _print_worklist(rows::Vector{PkgVersion}, out::Union{Nothing,String})
    if out === nothing
        lines = [string(r.name, "\t", r.version, "\t", r.uuid, "\t", r.tree_hash) for r in rows]
        for l in lines; println(l); end
    else
        open(out, "w") do io
            for r in rows
                println(io, to_json_line(Result(r, :pending, 0.0, 0, "")))
            end
        end
    end
    println(stderr, "$(length(rows)) entries")
end

function cli_main(argv::Vector{String})
    cfg = parse_args(argv)
    cfg.mode === :help && (_usage(); return 0)

    if cfg.emit_index !== nothing
        open(cfg.emit_index, "w") do io
            write_index(abspath(cfg.store), io)
        end
        return 0
    end

    regpath = cfg.registry !== nothing ? cfg.registry : general_registry_path()
    regpath === nothing && (println(stderr, "No registry found; pass --registry"); return 2)

    rows = enumerate_registry(regpath)
    rows = apply_filters(rows, cfg.filter)
    if cfg.shard !== nothing
        rows = shard_select(rows, cfg.shard[1], cfg.shard[2])
    end

    if cfg.mode === :dry_run
        _print_worklist(rows, cfg.out); return 0
    elseif cfg.mode === :report_missing
        missing_rows = find_missing(rows, abspath(cfg.store))
        _print_worklist(missing_rows, cfg.out); return 0
    end

    workdir = cfg.workdir !== nothing ? cfg.workdir : mktempdir()
    depot = cfg.depot !== nothing ? cfg.depot : joinpath(workdir, "depot")
    jwroot = abspath(joinpath(@__DIR__, ".."))     # CloudIndex/.. == src/
    launcher = cfg.launcher_template === nothing ? default_launcher :
               template_launcher(cfg.launcher_template)
    opts = IndexOpts(store=abspath(cfg.store),
                     depot=abspath(depot), workdir=abspath(workdir), jwroot=jwroot,
                     jobs=cfg.jobs, timeout=cfg.timeout, resume=cfg.resume,
                     progress=cfg.progress,
                     launcher=launcher, logfile=joinpath(workdir, "results.jsonl"))
    results = try
        run_index(rows, opts)
    catch err
        err isa InterruptException || rethrow()
        println("Interrupted. Partial results in ", opts.logfile)
        return 130
    end

    counts = Dict{Symbol,Int}()
    for r in results; counts[r.status] = get(counts, r.status, 0) + 1; end
    println("Done. ", join(["$(v) $(k)" for (k, v) in counts], ", "))
    println("Log: ", opts.logfile)
    return any(r -> r.status in (:failed, :timeout), results) ? 1 : 0
end
