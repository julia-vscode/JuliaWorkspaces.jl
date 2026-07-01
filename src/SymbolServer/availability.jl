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

function keep_available!(to_download, manifest, index::Set{String})
    filter!(to_download) do pkg
        cache_key_from_path(get_cache_path(manifest, packageuuid(pkg))) in index
    end
    return to_download
end

# Network: fetch <upstream>/store/<version>/index.tar.gz (a tarball containing index.txt)
# and parse it. Returns `nothing` on any failure so callers can fall back to the
# legacy per-file attempt. Uses the same unpack path as the cache tarballs, so no
# new dependency is needed.
function fetch_availability_index(upstream::AbstractString)
    url = join([upstream, "store", CACHE_STORE_VERSION, "index.tar.gz"], '/')
    try
        return mktempdir() do dir
            dest = joinpath(dir, "idx")  # must NOT pre-exist: download_verify_unpack returns false if isdir(dest)
            Pkg.PlatformEngines.download_verify_unpack(url, nothing, dest) || return nothing
            idx = joinpath(dest, "index.txt")
            isfile(idx) ? open(parse_availability_index, idx) : nothing
        end
    catch err
        @debug "Could not fetch availability index" exception = (err, catch_backtrace())
        return nothing
    end
end
