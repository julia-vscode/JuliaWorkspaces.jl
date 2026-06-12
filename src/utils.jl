@inline function safe_getproperty(x, s::Symbol)
    if isnothing(x)
        return nothing
    else
        return getproperty(x, s)
    end
end
