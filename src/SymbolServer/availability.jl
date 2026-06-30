# Client-side availability index: a published set of "<uuid>/<stem>" keys naming
# the caches that exist on the server, so we only fetch what's available.

cache_key(uuid, stem) = string(uuid, '/', stem)

# `paths` is a get_cache_path result: [Initial, Name, uuid, "<stem>.jstore"].
cache_key_from_path(paths::AbstractVector) = cache_key(paths[3], first(splitext(paths[4])))

function parse_availability_index(io::IO)
    keys = Set{String}()
    for line in eachline(io)
        line = strip(line)
        isempty(line) && continue
        push!(keys, String(line))
    end
    return keys
end
parse_availability_index(s::AbstractString) = parse_availability_index(IOBuffer(s))
