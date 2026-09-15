# Markdown (.md) and Julia Markdown (.jmd) documents as Julia analysis
# sources.
#
# The design is the one the pre-JuliaWorkspaces language server used
# (`parse_jmd`), rebuilt on MarkdownSyntax instead of regexes: a markdown
# document's *Julia view* is the document with every byte outside a Julia
# code fence replaced by whitespace, byte-for-byte. Offsets in the view ARE
# offsets in the document, so every parser (CSTParser, the fused JuliaSyntax
# parse, the v2 walk) reads the view through `derived_julia_source_view` and
# no feature needs a position-mapping layer.
#
# Two Salsa wins fall out of the value-stable queries here:
#  - `derived_markdown_julia_chunks` backdates whenever an edit leaves the
#    chunk table identical, and
#  - `derived_julia_source_view` backdates whenever an edit only touches
#    prose — so a README keystroke never reaches any Julia analysis.

"""
    _is_markdown_uri(rt, uri)

Whether `uri` is a Markdown or Julia Markdown document: a file-scheme
`.md`/`.jmd` path (case-insensitive), or a buffer with no usable path whose
language id is "markdown"/"juliamarkdown". The exact mirror of
[`_is_julia_uri`](@ref), with the same degenerate-URI handling.
"""
function _is_markdown_uri(rt, uri)
    if uri.scheme == "file"
        path = uri2filepath(uri)
        (path === nothing || isempty(path)) &&
            return derived_file_language_id(rt, uri) in ("markdown", "juliamarkdown")
        return is_path_markdown_file(path) || is_path_juliamarkdown_file(path)
    else
        return derived_file_language_id(rt, uri) in ("markdown", "juliamarkdown")
    end
end

"""
    _is_julia_analysis_uri(rt, uri)

Whether `uri` carries Julia content for the analysis layers: a Julia document,
or a Markdown document (whose Julia view may well be all whitespace — a
markdown file with no Julia fences analyses as an empty file, cheaply).
This is the root-admission and diagnostics gate; entry points that take a
position additionally gate on [`_julia_position_admitted`](@ref).
"""
_is_julia_analysis_uri(rt, uri) = _is_julia_uri(rt, uri) || _is_markdown_uri(rt, uri)

"""
    derived_markdown_julia_chunks(rt, uri) -> Vector{MarkdownSyntax.JuliaChunk}

The Julia code chunks of a markdown document, in document order (empty for
anything that is not markdown). Small and structurally comparable, so it
backdates across every edit that leaves the chunk table unchanged.
"""
Salsa.@derived function derived_markdown_julia_chunks(rt, uri)
    @debug "derived_markdown_julia_chunks" uri=uri

    _is_markdown_uri(rt, uri) || return MarkdownSyntax.JuliaChunk[]
    tf = derived_text_file_content(rt, uri)
    tf === nothing && return MarkdownSyntax.JuliaChunk[]

    return try
        MarkdownSyntax.julia_chunks(tf.content.content)
    catch err
        err isa InterruptException && rethrow()
        MarkdownSyntax.JuliaChunk[]
    end
end

"""
    derived_julia_source_view(rt, uri) -> Union{Nothing,String}

The text of `uri` AS JULIA SOURCE: the raw content for a Julia document, the
byte-offset-preserving shadow (chunks verbatim, prose blanked, see
`MarkdownSyntax.julia_shadow_source`) for a markdown document, `nothing` when
there is no content.

THE choke point: everything that parses a workspace document as Julia, or
slices/scans text at ranges a Julia parse produced, must read this instead of
`derived_text_file_content(...).content.content`. Reading the raw content is
correct only for non-Julia payloads (TOML tables, config files, content
hashes) and for pure position arithmetic (the view has identical byte length
and line structure).
"""
Salsa.@derived function derived_julia_source_view(rt, uri)
    @debug "derived_julia_source_view" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return nothing
    _is_markdown_uri(rt, uri) || return tf.content.content

    return try
        MarkdownSyntax.julia_shadow_source(tf.content.content; chunks=derived_markdown_julia_chunks(rt, uri))
    catch err
        err isa InterruptException && rethrow()
        # Fail to all-whitespace, never to raw prose: the parsers downstream
        # must not see markdown as Julia.
        MarkdownSyntax.julia_shadow_source(tf.content.content; chunks=MarkdownSyntax.JuliaChunk[])
    end
end

"""
    _julia_position_admitted(rt, uri, index) -> Bool

Whether the position-taking editor features should answer at the 1-based
string index `index` of `uri`: everywhere in a Julia document, only inside a
Julia chunk (inclusive of the position just past its last byte, where the
cursor sits while typing at the chunk's end) in a markdown document. The
prose of a markdown document gets no completions, hovers or actions.
"""
function _julia_position_admitted(rt, uri, index)
    _is_julia_uri(rt, uri) && return true
    _is_markdown_uri(rt, uri) || return false
    for c in derived_markdown_julia_chunks(rt, uri)
        first(c.code_range) <= index <= last(c.code_range) + 1 && return true
    end
    return false
end
