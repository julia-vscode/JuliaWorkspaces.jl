# Shared machinery for the three tool config files (`JuliaLint.toml`,
# `JuliaFormat.toml`, `JuliaTestItems.toml`).
#
# All three share the same shape:
#
#   * the *nearest* config file, walking up from the target file, governs that
#     file wholesale — keys it does not set fall back to built-in defaults, never
#     to a value from a config file further up the tree;
#   * top-level `include`/`exclude` gitignore-style globs select which files the
#     tool applies to at all;
#   * repeated `[[override]]` blocks with `paths = [...]` re-scope a subset of
#     the file's keys, with later blocks winning;
#   * unknown keys and invalid values are reported as diagnostics on the config
#     file itself.

# ── Glob matching ───────────────────────────────────────────────────────────

"""
    struct GlobPattern

A compiled gitignore-style glob. `*` matches within a path segment, `**` spans
segments, `?` matches a single non-separator character, and `[...]` is a
character class. A leading `/` anchors the pattern to the config file's
directory; a pattern containing no `/` matches at any depth. A trailing `/`
makes the pattern match everything below that directory.

The source `pattern` is what participates in equality, so that configs compare
and hash by their written form (the compiled `regex` is derived from it).
"""
struct GlobPattern
    pattern::String
    regex::Regex
end

GlobPattern(pattern::AbstractString) = GlobPattern(String(pattern), _glob_to_regex(pattern))

Base.:(==)(a::GlobPattern, b::GlobPattern) = a.pattern == b.pattern
Base.isequal(a::GlobPattern, b::GlobPattern) = isequal(a.pattern, b.pattern)
Base.hash(g::GlobPattern, h::UInt) = hash(g.pattern, hash(GlobPattern, h))

function _glob_to_regex(pattern::AbstractString)
    pat = replace(String(pattern), '\\' => '/')

    dir_only = endswith(pat, '/')
    dir_only && (pat = chop(pat))

    anchored = startswith(pat, '/')
    anchored && (pat = pat[nextind(pat, 1):end])

    io = IOBuffer()
    print(io, "^")

    # gitignore: a pattern with no separator matches at any depth.
    if !anchored && !occursin('/', pat)
        print(io, "(?:.*/)?")
    end

    i = firstindex(pat)
    stop = lastindex(pat)
    while i <= stop
        c = pat[i]
        if c == '*'
            j = nextind(pat, i)
            if j <= stop && pat[j] == '*'
                # `**/` consumes whole segments; a trailing `**` matches the rest.
                k = nextind(pat, j)
                if k <= stop && pat[k] == '/'
                    print(io, "(?:[^/]*/)*")
                    i = nextind(pat, k)
                else
                    print(io, ".*")
                    i = k
                end
            else
                print(io, "[^/]*")
                i = j
            end
        elseif c == '?'
            print(io, "[^/]")
            i = nextind(pat, i)
        elseif c == '['
            # Copy the character class through, honouring `!`/`^` negation and
            # an escaped `]` as the first member.
            j = nextind(pat, i)
            j <= stop && pat[j] in ('!', '^') && (j = nextind(pat, j))
            j <= stop && pat[j] == ']' && (j = nextind(pat, j))
            while j <= stop && pat[j] != ']'
                j = nextind(pat, j)
            end
            if j > stop
                print(io, "\\[")           # unterminated: treat as a literal
                i = nextind(pat, i)
            else
                cls = pat[i:j]
                startswith(cls, "[!") && (cls = "[^" * cls[3:end])
                print(io, cls)
                i = nextind(pat, j)
            end
        else
            print(io, _regex_escape_char(c))
            i = nextind(pat, i)
        end
    end

    print(io, dir_only ? "/.*\$" : "\$")

    flags = Sys.iswindows() ? "i" : ""
    return Regex(String(take!(io)), flags)
end

const _REGEX_METACHARS = Set{Char}(raw".^$|()[]{}+*?\/")

_regex_escape_char(c::Char) = c in _REGEX_METACHARS ? string('\\', c) : string(c)

matches(g::GlobPattern, relpath::AbstractString) = occursin(g.regex, relpath)

"""
    struct PathFilter

The `include`/`exclude` glob pair of a config file. An empty `include` list
selects everything; `exclude` always wins over `include`.
"""
struct PathFilter
    include::Vector{GlobPattern}
    exclude::Vector{GlobPattern}
end

PathFilter() = PathFilter(GlobPattern[], GlobPattern[])

Base.:(==)(a::PathFilter, b::PathFilter) = a.include == b.include && a.exclude == b.exclude
Base.isequal(a::PathFilter, b::PathFilter) = isequal(a.include, b.include) && isequal(a.exclude, b.exclude)
Base.hash(f::PathFilter, h::UInt) = hash(f.include, hash(f.exclude, hash(PathFilter, h)))

"""
    path_selected(filter, relpath) -> Bool

Whether `relpath` (relative to the config file's directory, `/`-separated) is
selected by `filter`.
"""
function path_selected(filter::PathFilter, relpath::AbstractString)
    any(g -> matches(g, relpath), filter.exclude) && return false
    isempty(filter.include) && return true
    return any(g -> matches(g, relpath), filter.include)
end

"""
    config_relative_path(config_dir, path) -> Union{String,Nothing}

`path` expressed relative to `config_dir` with `/` separators, or `nothing` when
`path` is not below `config_dir`.
"""
function config_relative_path(config_dir::AbstractString, path::AbstractString)
    dir = _normalize_dir(config_dir)
    p = replace(String(path), '\\' => '/')
    _path_startswith(p, dir) || return nothing
    return p[nextind(p, lastindex(dir)):end]
end

function _normalize_dir(dir::AbstractString)
    d = replace(String(dir), '\\' => '/')
    endswith(d, '/') || (d = d * "/")
    return d
end

# ── Config file discovery ───────────────────────────────────────────────────

"""
    nearest_config(config_uris, uri) -> Union{URI,Nothing}

The config file governing `uri`: the one in the deepest directory that is a
prefix of `uri`'s directory. Unlike the merging scheme this replaces, only this
single file applies.
"""
function nearest_config(config_uris, uri::URI)
    uri.scheme == "file" || return nothing
    target = replace(uri2filepath(uri), '\\' => '/')

    best = nothing
    best_len = -1
    for config_uri in config_uris
        config_uri.scheme == "file" || continue
        dir = _normalize_dir(dirname(uri2filepath(config_uri)))
        _path_startswith(target, dir) || continue
        if length(dir) > best_len
            best = config_uri
            best_len = length(dir)
        end
    end

    return best
end

"""
    config_dir_of(config_uri) -> String

The directory containing `config_uri`, `/`-separated and trailing-slashed.
"""
config_dir_of(config_uri::URI) = _normalize_dir(dirname(uri2filepath(config_uri)))

"""
    shadowed_config(config_uris, config_uri) -> Union{URI,Nothing}

The config file of the same kind that `config_uri` takes over from: the one in
the nearest strictly-enclosing directory, or `nothing` when `config_uri` is the
outermost of its kind.

Because the nearest config governs its subtree wholesale, a nested config file
does not extend the one above it — it replaces it, and the outer file's
settings stop applying with no other trace. Reporting that is the price of
choosing this discovery rule over cascading: the alternative is that a config
dropped into a subdirectory (a vendored repo, a copied example, a half-finished
subpackage extraction) silently voids the project's own configuration.
"""
function shadowed_config(config_uris, config_uri::URI)
    config_uri.scheme == "file" || return nothing
    own_dir = config_dir_of(config_uri)

    best = nothing
    best_len = -1
    for other in config_uris
        other == config_uri && continue
        other.scheme == "file" || continue
        dir = config_dir_of(other)
        # Strictly enclosing: a prefix of our directory, but not our directory.
        length(dir) < length(own_dir) || continue
        _path_startswith(own_dir, dir) || continue
        if length(dir) > best_len
            best = other
            best_len = length(dir)
        end
    end

    return best
end

# ── Overrides ───────────────────────────────────────────────────────────────

"""
    applicable_overrides(overrides, relpath) -> Vector

The `[[override]]` blocks whose `paths` match `relpath`, in file order. Callers
apply them in that order so later blocks win.
"""
function applicable_overrides(overrides::Vector{Any}, relpath::AbstractString)
    res = Any[]
    for ov in overrides
        ov isa Dict || continue
        globs = get(ov, "__paths__", nothing)
        globs === nothing && continue
        any(g -> matches(g, relpath), globs::Vector{GlobPattern}) && push!(res, ov)
    end
    return res
end

# ── Validation helpers ──────────────────────────────────────────────────────

config_diagnostic(message::AbstractString) =
    Diagnostic(1:1, :error, String(message), nothing, Symbol[], "JuliaWorkspaces.jl", :config_errors)

# The config format's own version. A file that does not say is version 1.
const CONFIG_FORMAT_VERSION = 1

"""
    validate_config_version!(res, table)

Check the `config-version` key. Reserved from the first release: without it, a
released tool meeting a file written for a later format can only complain about
an unknown key, and that cannot be fixed retroactively in copies already
installed.
"""
function validate_config_version!(res::Vector{Diagnostic}, table)
    haskey(table, "config-version") || return res
    v = table["config-version"]
    if !(v isa Integer) || v < 1
        push!(res, config_diagnostic("Invalid `config-version`, expected a positive integer."))
    elseif v > CONFIG_FORMAT_VERSION
        push!(res, config_diagnostic(
            "This file declares `config-version = $v`, but this version of the Julia " *
            "tooling only understands version $CONFIG_FORMAT_VERSION. Update the tooling to use it."))
    end
    return res
end

"""
    shadowing_diagnostic!(res, config_uris, config_uri, filename)

Report that `config_uri` takes over from a config file of the same kind in an
enclosing directory. See [`shadowed_config`](@ref) for why this is worth saying
out loud.
"""
function shadowing_diagnostic!(res::Vector{Diagnostic}, config_uris, config_uri::URI, filename::AbstractString)
    outer = shadowed_config(config_uris, config_uri)
    outer === nothing && return res

    outer_path = uri2filepath(outer)
    push!(res, Diagnostic(
        1:1, :information,
        "This $filename replaces `$outer_path` for everything below this directory, " *
        "rather than adding to it — settings from that file do not apply here. " *
        "Copy anything you want to keep, or remove this file.",
        nothing, Symbol[], "JuliaWorkspaces.jl", :shadowed_config,
    ))
    return res
end

"""
    validate_key_set!(res, table, valid_keys, migrations, what)

Report unknown keys in `table`. Keys present in `migrations` get a message
naming their replacement instead of a bare "invalid key".
"""
function validate_key_set!(res::Vector{Diagnostic}, table, valid_keys, migrations::Dict{String,String}, what::AbstractString)
    for k in keys(table)
        k in valid_keys && continue
        if haskey(migrations, k)
            push!(res, config_diagnostic("`$k` is no longer supported: $(migrations[k])"))
        else
            push!(res, config_diagnostic("Invalid $what `$k`."))
        end
    end
    return res
end

"""
    parse_glob_list!(res, table, key) -> Vector{GlobPattern}

Read a list-of-strings glob key, reporting a diagnostic and returning an empty
list when it is malformed.
"""
function parse_glob_list!(res::Vector{Diagnostic}, table, key::AbstractString)
    haskey(table, key) || return GlobPattern[]
    v = table[key]
    if !(v isa AbstractVector) || !all(x -> x isa AbstractString, v)
        push!(res, config_diagnostic("Invalid value for `$key`, expected a list of glob strings."))
        return GlobPattern[]
    end
    return GlobPattern[GlobPattern(x) for x in v]
end

"""
    parse_path_filter!(res, table) -> PathFilter

Read the shared `include`/`exclude` keys.
"""
parse_path_filter!(res::Vector{Diagnostic}, table) =
    PathFilter(parse_glob_list!(res, table, "include"), parse_glob_list!(res, table, "exclude"))

"""
    parse_overrides!(res, table, validate_block!) -> Vector{Any}

Read the `[[override]]` array of tables. Each block must carry a `paths` glob
list; the compiled globs are stashed under the reserved `__paths__` key for
[`applicable_overrides`](@ref). `validate_block!(res, block)` validates the
tool-specific keys of each block.
"""
function parse_overrides!(res::Vector{Diagnostic}, table, validate_block!)
    haskey(table, "override") || return Any[]
    raw = table["override"]
    if !(raw isa AbstractVector)
        push!(res, config_diagnostic("Invalid `override`, expected `[[override]]` blocks."))
        return Any[]
    end

    out = Any[]
    for block in raw
        if !(block isa Dict)
            push!(res, config_diagnostic("Invalid `[[override]]` block, expected a table."))
            continue
        end
        if !haskey(block, "paths")
            push!(res, config_diagnostic("An `[[override]]` block is missing the required `paths` key."))
            continue
        end
        globs = parse_glob_list!(res, block, "paths")
        prepared = Dict{String,Any}(block)
        prepared["__paths__"] = globs
        validate_block!(res, block)
        push!(out, prepared)
    end

    return out
end
