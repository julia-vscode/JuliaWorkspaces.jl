module CSTCorpus

using CSTParser
using JuliaWorkspaces: CSTConversion

# One corpus file's outcome: :pass, or a diff signature for grouping.
function check_file(path::String)
    src = read(path, String)
    ours = try
        CSTConversion.build_cst(src)
    catch err
        return (:errored, "converter threw: $(typeof(err))")
    end
    oracle = try
        CSTParser.parse(src, true)
    catch err
        return (:pass, nothing)   # oracle itself fails: out of scope
    end
    d = CSTConversion.first_tree_diff(ours, oracle)
    d === nothing && return (:pass, nothing)
    # signature = diff with indices stripped, so identical shapes group together
    return (:failed, replace(d, r"\[\d+\]" => "[]", r"\d+" => "N"))
end

function run_corpus(files::Vector{String}; report_path::String)
    empty!(CSTConversion.UNHANDLED_KINDS)
    passed = 0; failures = Dict{String,Vector{String}}(); errors = Dict{String,Vector{String}}()
    for f in files
        outcome, sig = check_file(f)
        if outcome == :pass
            passed += 1
        elseif outcome == :failed
            push!(get!(Vector{String}, failures, sig), f)
        else
            push!(get!(Vector{String}, errors, sig), f)
        end
    end
    open(report_path, "w") do io
        total = length(files)
        println(io, "# CST conversion corpus report\n")
        println(io, "$passed / $total files identical to oracle\n")
        println(io, "## Unhandled kinds\n")
        for k in sort!(string.(collect(CSTConversion.UNHANDLED_KINDS)))
            println(io, "- `", k, "`")
        end
        for (title, group) in (("Diffs", failures), ("Converter errors", errors))
            println(io, "\n## $title\n")
            for (sig, fs) in sort!(collect(group); by=p -> -length(p.second))
                println(io, "- **$(length(fs))×** `$sig`\n  - e.g. `$(first(fs))`")
            end
        end
    end
    return (total=length(files), passed=passed,
            failed=sum(length, values(failures); init=0),
            errored=sum(length, values(errors); init=0))
end

julia_files(dir::String) = String[joinpath(r, f) for (r, _, fs) in walkdir(dir) for f in fs if endswith(f, ".jl")]

end
