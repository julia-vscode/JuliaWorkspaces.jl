Salsa.@derived function derived_text_files(rt)
    files = input_files(rt)

    # TODO Actually filter this properly
    return Set{URI}(file for file in files)
end

Salsa.@derived function derived_file_language_id(rt, uri)
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    return tf.content.language_id
end

# A URI whose content should be treated as Julia: a file-scheme `.jl` path
# (case-insensitive), or a buffer with no usable path (an untitled or
# notebook-cell document, say) whose language id is "julia". The language query
# is value-stable, so a keystroke in an untitled buffer never invalidates the
# root set, and a well-formed path answers without querying it at all.
#
# Single source of truth for "is pure Julia": include-target admission,
# formatting, and (widened by `_is_julia_analysis_uri` to markdown documents,
# see layer_markdown.jl) root admission, the diagnostics gate and the contract
# `derived_julia_legacy_syntax_tree` enforces. Every entry point that can be
# handed an arbitrary URI goes through one of the two.
function _is_julia_uri(rt, uri)
    if uri.scheme == "file"
        path = uri2filepath(uri)
        # A degenerate `file:` URI carries no path to classify — `file://x.jl`
        # parses `x.jl` as the *authority*, leaving the path empty. Ask the
        # recorded language id rather than answering "not Julia", which would
        # silently switch off every feature for that document.
        (path === nothing || isempty(path)) && return derived_file_language_id(rt, uri) == "julia"
        return is_path_julia_file(path)
    else
        return derived_file_language_id(rt, uri) == "julia"
    end
end

# Julia documents AND markdown documents: a markdown file's Julia view (see
# layer_markdown.jl) is analyzed exactly like a Julia file, and admitting
# every markdown file unconditionally — not just those that currently contain
# a Julia fence — keeps the root set stable under edits (a chunk-less file's
# view is all whitespace, which parses to an empty file, cheaply).
Salsa.@derived function derived_julia_files(rt)
    files = derived_text_files(rt)

    return Set{URI}(file for file in files if _is_julia_analysis_uri(rt, file))
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
