module Standalone

"""
    myfunc(x)

A test function.
"""
function myfunc(x)
    return x + 1
end

myvar = 42

struct MyStruct
    field1::Int
    field2::String
end

println("hello")
push!([1, 2], 3)

end
