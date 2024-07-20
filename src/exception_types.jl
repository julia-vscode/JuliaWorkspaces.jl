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
