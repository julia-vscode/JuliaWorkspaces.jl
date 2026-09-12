struct JWUnknownFileType <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::JWUnknownFileType)
    print(io, ex.msg)
end

struct JWDuplicateFile <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::JWDuplicateFile)
    print(io, ex.msg)
end

struct JWUnknownFile <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::JWUnknownFile)
    print(io, ex.msg)
end

struct JWInvalidFileContent <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::JWInvalidFileContent)
    print(io, ex.msg)
end

"""
    JWNotAJuliaFile

Thrown when a query that can only be answered for Julia source is asked about a
document that is not Julia (Markdown, Julia-markdown, TOML, ...). See
`derived_julia_legacy_syntax_tree` for the contract this enforces.
"""
struct JWNotAJuliaFile <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::JWNotAJuliaFile)
    print(io, ex.msg)
end
