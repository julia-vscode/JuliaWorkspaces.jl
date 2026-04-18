module NoManifestPackage

"""
    greet(name)

Say hello.
"""
function greet(name)
    println("Hello, $name!")
end

counter = 0

struct Config
    host::String
    port::Int
end

end
