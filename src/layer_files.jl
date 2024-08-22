Salsa.@derived function derived_text_files(rt)
    files = input_files(rt)

    # TODO Actually filter this properly
    return Set{URI}(file for file in files)
end

Salsa.@derived function derived_julia_files(rt)
    files = derived_text_files(rt)

    # TODO Actually filter this properly
    return Set{URI}(file for file in files if endswith(string(file), ".jl"))
end

Salsa.@derived function derived_has_file(rt, uri)
    files = input_files(rt)

    return uri in files
end
