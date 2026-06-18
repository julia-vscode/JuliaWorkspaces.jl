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

"""
    derived_text_file_content(rt, uri)

Return the `TextFile` content for `uri`. Prefers the regular `input_text_file`
when the URI is a regular workspace file, otherwise falls back to the lazy
`input_indirect_text_file` (which reads the file from disc on first access).
Returns `nothing` if neither is available.
"""
Salsa.@derived function derived_text_file_content(rt, uri)
    if derived_has_file(rt, uri)
        return input_text_file(rt, uri)
    else
        return input_indirect_text_file(rt, uri)
    end
end
