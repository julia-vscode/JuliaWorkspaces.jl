# Formatting layer
#
# Native source-code formatting driven by a `juliaformat.toml` configuration
# file. The configuration model (discovery + hierarchical merge) mirrors the
# lint configuration in layer_diagnostics.jl.
#
# Supported styles are the JuliaFormatter.jl styles ("default", "yas", "blue",
# "sciml", "minimal") plus "runic", which routes formatting through Runic.jl.
#
# This layer deliberately never reads JuliaFormatter.jl's own `.JuliaFormatter.toml`
# configuration files: `JuliaFormatter.format_text` is always called with an
# explicit set of options derived solely from `juliaformat.toml`.

const _FORMAT_STYLES = ("default", "yas", "blue", "sciml", "minimal", "runic")

# Default style used when no `juliaformat.toml` provides a `style` field.
const _FORMAT_DEFAULT_STYLE = "minimal"

Salsa.@derived function derived_formatconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_formatconfig_file(uri2filepath(file))]
end

Salsa.@derived function derived_formatconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    valid_option_fields = string.(fieldnames(JuliaFormatter.Options))

    for (k, v) in pairs(toml_content)
        if k == "style"
            if !(v isa String) || !(v in _FORMAT_STYLES)
                valid_values = join(_FORMAT_STYLES, ", ")
                push!(res, Diagnostic(1:1, :error, "Invalid format configuration value for style, only $valid_values are valid.", nothing, Symbol[], "JuliaWorkspaces.jl"))
            end
        elseif !(k in valid_option_fields)
            push!(res, Diagnostic(1:1, :error, "Invalid format configuration $k.", nothing, Symbol[], "JuliaWorkspaces.jl"))
        end
    end

    return res
end

Salsa.@derived function derived_format_configuration(rt, uri)
    @debug "derived_format_configuration" uri=uri

    config_files = derived_formatconfig_files(rt)

    config_files = sort(config_files, by=i->length(string(i)))

    configs = Dict{String,Any}()
    for config_file in config_files
        config_folder_path = dirname(uri2filepath(config_file))

        if startswith(uri2filepath(uri), config_folder_path)
            content_as_toml = derived_toml_syntax_tree(rt, config_file)

            for (k, v) in pairs(content_as_toml)
                configs[k] = v
            end
        end
    end

    return configs
end

function _format_style_object(style::AbstractString)
    style == "yas" && return JuliaFormatter.YASStyle()
    style == "blue" && return JuliaFormatter.BlueStyle()
    style == "sciml" && return JuliaFormatter.SciMLStyle()
    style == "minimal" && return JuliaFormatter.MinimalStyle()
    return JuliaFormatter.DefaultStyle()
end

function _juliaformatter_kwargs(config::Dict)
    valid = fieldnames(JuliaFormatter.Options)
    kw = Dict{Symbol,Any}()
    for (k, v) in pairs(config)
        k == "style" && continue
        sym = Symbol(k)
        if sym in valid
            kw[sym] = v
        end
    end
    return kw
end

function _format_text(text::AbstractString, config::Dict)
    style = get(config, "style", _FORMAT_DEFAULT_STYLE)

    if style == "runic"
        return Runic.format_string(text)
    else
        style_obj = _format_style_object(style)
        kw = _juliaformatter_kwargs(config)
        return JuliaFormatter.format_text(text; style=style_obj, kw...)
    end
end

# Returns `(formatted_text::Union{String,Nothing}, error::Union{String,Nothing})`.
Salsa.@derived function derived_formatted_text(rt, uri)
    @debug "derived_formatted_text" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return (nothing, "File not found.")

    text = tf.content.content
    config = derived_format_configuration(rt, uri)

    try
        return (_format_text(text, config), nothing)
    catch err
        return (nothing, sprint(showerror, err))
    end
end

# Full-document formatting. Returns `(WorkspaceFileEdit, nothing)` on success or
# `(nothing, error_message)` on failure.
Salsa.@derived function derived_format_edits(rt, uri)
    @debug "derived_format_edits" uri=uri

    formatted, err = derived_formatted_text(rt, uri)
    err === nothing || return (nothing, err)

    tf = derived_text_file_content(rt, uri)
    st = tf.content

    if formatted == st.content
        return (WorkspaceFileEdit(uri, TextEditResult[]), nothing)
    end

    end_position = position_at(st, lastindex(st.content) + 1)
    edit = TextEditResult(Position(1, 1), end_position, formatted)

    return (WorkspaceFileEdit(uri, TextEditResult[edit]), nothing)
end

# Strings broken up and joined with * so this file itself remains formattable.
const _FORMAT_MARK_BEGIN = "---- BEGIN JULIAWORKSPACES" * " RANGE FORMATTING ----"
const _FORMAT_MARK_END = "---- END JULIAWORKSPACES" * " RANGE FORMATTING ----"

# Range formatting over whole lines [start_line, stop_line] (1-based line
# numbers). Returns `(WorkspaceFileEdit, nothing)` on success or
# `(nothing, error_message)` on failure.
Salsa.@derived function derived_format_range_edits(rt, uri, start_line, stop_line)
    @debug "derived_format_range_edits" uri=uri start_line=start_line stop_line=stop_line

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return (nothing, "File not found.")

    st = tf.content
    oldcontent = st.content
    config = derived_format_configuration(rt, uri)

    original_lines = collect(eachline(IOBuffer(oldcontent); keep=true))

    startline = max(start_line, 1)
    stopline = min(stop_line, length(original_lines))

    if stopline < startline || isempty(original_lines)
        return (WorkspaceFileEdit(uri, TextEditResult[]), nothing)
    end

    original_block = join(@view(original_lines[startline:stopline]))

    # If the stopline does not have a trailing newline we need to add one before
    # our stop comment marker. This is removed again after formatting.
    stopline_has_newline = original_lines[stopline] != chomp(original_lines[stopline])
    insert!(original_lines, stopline + 1, (stopline_has_newline ? "# " : "\n# ") * _FORMAT_MARK_END * "\n")
    insert!(original_lines, startline, "# " * _FORMAT_MARK_BEGIN * "\n")
    text_marked = join(original_lines)

    text_formatted = try
        _format_text(text_marked, config)
    catch err
        return (nothing, sprint(showerror, err))
    end

    formatted_lines = collect(eachline(IOBuffer(text_formatted); keep=true))
    start_idx = findfirst(x -> occursin(_FORMAT_MARK_BEGIN, x), formatted_lines)
    start_idx === nothing && return (WorkspaceFileEdit(uri, TextEditResult[]), nothing)
    stop_idx = findfirst(x -> occursin(_FORMAT_MARK_END, x), formatted_lines)
    stop_idx === nothing && return (WorkspaceFileEdit(uri, TextEditResult[]), nothing)
    formatted_block = join(@view(formatted_lines[(start_idx+1):(stop_idx-1)]))

    if !stopline_has_newline
        formatted_block = chomp(formatted_block)
    end

    if formatted_block == original_block
        return (WorkspaceFileEdit(uri, TextEditResult[]), nothing)
    end

    edit = TextEditResult(Position(startline, 1), Position(stopline + 1, 1), formatted_block)

    return (WorkspaceFileEdit(uri, TextEditResult[edit]), nothing)
end
