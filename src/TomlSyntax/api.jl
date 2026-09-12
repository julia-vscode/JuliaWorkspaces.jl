# Entry points. `parsetoml` mirrors JuliaSyntax's `parseall`; `parse`,
# `tryparse`, `parsefile` and `tryparsefile` mirror the TOML stdlib.

"""
    TomlParseError

Thrown (or returned by `tryparse`) when a document has errors: the source, all
diagnostics in byte order, and the table built from the intact items.
"""
struct TomlParseError <: Exception
    source::SourceFile
    diagnostics::Vector{TomlDiagnostic}
    table::Dict{String,Any}
end

function Base.showerror(io::IO, err::TomlParseError)
    println(io, "TomlParseError:")
    show_diagnostics(io, err.diagnostics, err.source)
end

"The code of the first error diagnostic of `err`."
function error_kind(err::TomlParseError)
    for d in err.diagnostics
        is_error(d) && return d.code
    end
    return error("TomlParseError without an error diagnostic")
end

JuliaSyntax.sourcefile(err::TomlParseError) = err.source

"""
    parsetoml(TomlNode, text; filename=nothing, first_line=1, ignore_errors=false, version=v"1.0.0")
    parsetoml(GreenNode, text; ...)

Parse `text` into a syntax tree. Throws [`TomlParseError`](@ref) on syntax
errors unless `ignore_errors` is set, in which case the recovered tree (with
`K"error"` nodes) is returned. Semantic table rules are not checked here; see
[`build_table`](@ref).
"""
function parsetoml(::Type{T}, text::Union{AbstractString,IO}; filename=nothing, first_line=1,
                   ignore_errors::Bool=false, version=TOML_DEFAULT_VERSION) where {T}
    st = TomlParseStream(text; version)
    parse_toml!(st)
    if !ignore_errors && any_error(st)
        throw(TomlParseError(SourceFile(st; filename, first_line), st.diagnostics, Dict{String,Any}()))
    end
    return build_tree(T, st; filename, first_line)
end

"""
    parsetoml_with_diagnostics(text; filename=nothing, first_line=1, version=v"1.0.0")

The recovered [`TomlNode`](@ref) tree of `text` together with its syntax
diagnostics. Never throws.
"""
function parsetoml_with_diagnostics(text::Union{AbstractString,IO}; filename=nothing, first_line=1,
                                    version=TOML_DEFAULT_VERSION)
    st = TomlParseStream(text; version)
    parse_toml!(st)
    return build_tree(TomlNode, st; filename, first_line), st.diagnostics
end

"""
    tryparse(text; filename=nothing, version=v"1.0.0") -> Dict{String,Any} or TomlParseError

Parse a TOML document (a string or `IO`) into a `Dict{String,Any}`, like the
TOML stdlib. Errors are returned, not thrown.
"""
function tryparse(text::Union{AbstractString,IO}; filename=nothing, version=TOML_DEFAULT_VERSION)
    tree, syntax = parsetoml_with_diagnostics(text; filename, version)
    table, semantic = build_table(tree)
    if isempty(semantic) && !any_error(syntax)
        return table
    end
    all = sort!(vcat(syntax, semantic); by=first_byte)
    return TomlParseError(sourcefile(tree), all, table)
end

"""
    parse(text; filename=nothing, version=v"1.0.0") -> Dict{String,Any}

Like [`tryparse`](@ref) but throws the [`TomlParseError`](@ref).
"""
function parse(text::Union{AbstractString,IO}; kws...)
    r = tryparse(text; kws...)
    r isa TomlParseError && throw(r)
    return r
end

function _read_toml_file(path::AbstractString)
    isfile(path) || error(repr(path), ": No such file")
    return read(path, String)
end

"Parse the TOML file at `path`; throws on errors."
parsefile(path::AbstractString; kws...) = parse(_read_toml_file(path); filename=String(path), kws...)
"Parse the TOML file at `path`; returns the `TomlParseError` on errors."
tryparsefile(path::AbstractString; kws...) = tryparse(_read_toml_file(path); filename=String(path), kws...)
