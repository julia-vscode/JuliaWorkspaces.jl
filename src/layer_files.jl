Salsa.@derived function derived_text_files(rt)
    files = input_files(rt)

    # TODO Actually filter this properly
    return Set{URI}(file for file in files)
end

Salsa.@derived function derived_julia_files(rt)
    files = derived_text_files(rt)

    # File-scheme URIs keep the cheap suffix check; non-file buffers (e.g.
    # untitled) are Julia when their language id says so. The language query is
    # value-stable, so a keystroke in an untitled buffer never invalidates the
    # root set.
    return Set{URI}(file for file in files if
        endswith(string(file), ".jl") ||
        (file.scheme != "file" && derived_file_language_id(rt, file) == "julia"))
end

Salsa.@derived function derived_file_language_id(rt, uri)
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    return tf.content.language_id
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
    # Lazy probes (e.g. `derived_project_toml_files`) can hand through
    # `nothing` for a missing candidate file; treat that as "no content"
    # rather than crashing further down (e.g. in `input_indirect_text_file`).
    uri === nothing && return nothing

    if derived_has_file(rt, uri)
        return input_text_file(rt, uri)
    else
        return input_indirect_text_file(rt, uri)
    end
end

"""
    derived_has_content(rt, uri)

Return whether `uri` has text content available (either a regular workspace file
or a lazily-loaded indirect include target). Unlike `derived_text_file_content`,
this returns a value-stable `Bool`: it re-executes when the file's content
changes but the result only flips when the file appears or disappears, so
Salsa's early-exit shields dependents (e.g. `derived_include_closure`) from
ordinary content edits. Prefer this over `derived_text_file_content(...) !==
nothing` wherever only *presence* matters.
"""
Salsa.@derived function derived_has_content(rt, uri)
    return derived_text_file_content(rt, uri) !== nothing
end
