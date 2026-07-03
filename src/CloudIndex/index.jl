# Build the availability index from a store: one "<uuid>/<stem>" key per .jstore,
# where the store layout is <store>/<Initial>/<Name>/<uuid>/<stem>.jstore.
function build_index(store_path::AbstractString)
    keys = String[]
    isdir(store_path) || return keys
    for (root, _, files) in walkdir(store_path)
        for f in files
            endswith(f, ".jstore") || continue
            push!(keys, string(basename(root), '/', first(splitext(f))))
        end
    end
    return sort!(unique!(keys))
end

function write_index(store_path::AbstractString, out::IO)
    for k in build_index(store_path)
        println(out, k)
    end
    return nothing
end
