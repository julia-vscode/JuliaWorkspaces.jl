# Formatting layer
#
# Native source-code formatting driven by a `JuliaFormat.toml` configuration
# file. The configuration model (nearest file governs its subtree wholesale,
# shared `include`/`exclude` globs, `[[override]]` blocks) mirrors the lint
# configuration in layer_diagnostics.jl; the shared machinery lives in
# config_common.jl.
#
# Supported styles are the JuliaFormatter.jl styles ("default", "yas", "blue",
# "sciml", "minimal") plus "runic", which routes formatting through Runic.jl.
# `style` names a preset; the `[options]` table holds deltas on top of it.
#
# This layer deliberately never reads JuliaFormatter.jl's own `.JuliaFormatter.toml`
# configuration files: `JuliaFormatter.format_text` is always called with an
# explicit set of options derived solely from `JuliaFormat.toml`.

const _FORMAT_STYLES = ("default", "yas", "blue", "sciml", "minimal", "runic")

# Default style used when no `JuliaFormat.toml` provides a `style` field.
const _FORMAT_DEFAULT_STYLE = "minimal"

# Runic takes no options at all, so silently accepting an `[options]` table
# alongside it would misreport what the formatter is going to do.
const _FORMAT_STYLES_WITHOUT_OPTIONS = ("runic",)

const _FORMAT_CONFIG_TOP_LEVEL_KEYS = ["config-version", "style", "include", "exclude", "options", "override"]

Salsa.@derived function derived_formatconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_formatconfig_file(uri2filepath(file))]
end

# Formatter knobs used to sit at the top level; they now live under `[options]`.
function _format_config_migrations()
    migrations = Dict{String,String}()
    for f in fieldnames(JuliaFormatter.Options)
        migrations[string(f)] = "move it into the `[options]` table."
    end
    return migrations
end

const _FORMAT_CONFIG_MIGRATIONS = _format_config_migrations()

function _validate_format_options!(res::Vector{Diagnostic}, table, style)
    table isa Dict || (push!(res, config_diagnostic("Invalid `[options]`, expected a table.")); return)

    valid_option_fields = string.(fieldnames(JuliaFormatter.Options))

    if !isempty(table) && style isa AbstractString && style in _FORMAT_STYLES_WITHOUT_OPTIONS
        push!(res, config_diagnostic("The `$style` style does not support any `[options]`."))
    end

    for k in keys(table)
        k in valid_option_fields ||
            push!(res, config_diagnostic("Invalid format option `$k`."))
    end
end

Salsa.@derived function derived_formatconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    validate_key_set!(res, toml_content, _FORMAT_CONFIG_TOP_LEVEL_KEYS, _FORMAT_CONFIG_MIGRATIONS, "format configuration key")
    validate_config_version!(res, toml_content)
    shadowing_diagnostic!(res, derived_formatconfig_files(rt), uri, "JuliaFormat.toml")

    style = get(toml_content, "style", _FORMAT_DEFAULT_STYLE)
    if !(style isa AbstractString) || !(style in _FORMAT_STYLES)
        push!(res, config_diagnostic("Invalid value for `style`, only $(join(_FORMAT_STYLES, ", ")) are valid."))
    end

    parse_glob_list!(res, toml_content, "include")
    parse_glob_list!(res, toml_content, "exclude")

    haskey(toml_content, "options") && _validate_format_options!(res, toml_content["options"], style)

    parse_overrides!(res, toml_content, (r, block) -> begin
        validate_key_set!(r, block, ["paths", "style", "options"], _FORMAT_CONFIG_MIGRATIONS, "`[[override]]` key")
        block_style = get(block, "style", style)
        if haskey(block, "style") && (!(block_style isa AbstractString) || !(block_style in _FORMAT_STYLES))
            push!(r, config_diagnostic("Invalid value for `style`, only $(join(_FORMAT_STYLES, ", ")) are valid."))
        end
        haskey(block, "options") && _validate_format_options!(r, block["options"], block_style)
    end)

    return res
end

"""
    struct EffectiveFormatConfig

The formatting configuration in force for one file, after resolving the style
preset, the `[options]` deltas and any applicable `[[override]]` blocks.

- `style::String`: The style preset.
- `options::Dict{Symbol,Any}`: `JuliaFormatter.Options` overrides.
- `selected::Bool`: Whether the file is formatted at all (`include`/`exclude`).
"""
struct EffectiveFormatConfig
    style::String
    options::Dict{Symbol,Any}
    selected::Bool
end

EffectiveFormatConfig() = EffectiveFormatConfig(_FORMAT_DEFAULT_STYLE, Dict{Symbol,Any}(), true)

function _format_config_fields_equal(a::EffectiveFormatConfig, b::EffectiveFormatConfig, eq)
    eq(a.style, b.style) && eq(a.options, b.options) && eq(a.selected, b.selected)
end
Base.:(==)(a::EffectiveFormatConfig, b::EffectiveFormatConfig) = _format_config_fields_equal(a, b, ==)
Base.isequal(a::EffectiveFormatConfig, b::EffectiveFormatConfig) = _format_config_fields_equal(a, b, isequal)
Base.hash(c::EffectiveFormatConfig, h::UInt) =
    hash(c.style, hash(c.options, hash(c.selected, hash(EffectiveFormatConfig, h))))

function _read_format_options(table)
    out = Dict{Symbol,Any}()
    table isa Dict || return out
    valid = fieldnames(JuliaFormatter.Options)
    for (k, v) in pairs(table)
        sym = Symbol(k)
        sym in valid && (out[sym] = v)
    end
    return out
end

Salsa.@derived function derived_format_configuration(rt, uri)
    @debug "derived_format_configuration" uri=uri

    # Non-file buffers have no folder-based config; defaults apply.
    uri.scheme == "file" || return EffectiveFormatConfig()

    config_uri = nearest_config(derived_formatconfig_files(rt), uri)
    config_uri === nothing && return EffectiveFormatConfig()

    toml_content = derived_toml_syntax_tree(rt, config_uri)
    relpath = config_relative_path(config_dir_of(config_uri), uri2filepath(uri))
    relpath === nothing && return EffectiveFormatConfig()

    style = get(toml_content, "style", _FORMAT_DEFAULT_STYLE)
    (style isa AbstractString && style in _FORMAT_STYLES) || (style = _FORMAT_DEFAULT_STYLE)

    options = _read_format_options(get(toml_content, "options", nothing))

    discard = Diagnostic[]
    filter = parse_path_filter!(discard, toml_content)
    overrides = parse_overrides!(discard, toml_content, (_, _) -> nothing)

    for ov in applicable_overrides(overrides, relpath)
        ov_style = get(ov, "style", nothing)
        if ov_style isa AbstractString && ov_style in _FORMAT_STYLES
            style = ov_style
        end
        merge!(options, _read_format_options(get(ov, "options", nothing)))
    end

    return EffectiveFormatConfig(String(style), options, path_selected(filter, relpath))
end

function _format_style_object(style::AbstractString)
    style == "yas" && return JuliaFormatter.YASStyle()
    style == "blue" && return JuliaFormatter.BlueStyle()
    style == "sciml" && return JuliaFormatter.SciMLStyle()
    style == "minimal" && return JuliaFormatter.MinimalStyle()
    return JuliaFormatter.DefaultStyle()
end

function _format_text(text::AbstractString, config::EffectiveFormatConfig)
    if config.style in _FORMAT_STYLES_WITHOUT_OPTIONS
        # The config validator already flags this; erroring here keeps a
        # programmatically built config from silently dropping the options.
        isempty(config.options) ||
            error("The `$(config.style)` style does not support any `[options]`.")
        return Runic.format_string(text)
    else
        style_obj = _format_style_object(config.style)
        return JuliaFormatter.format_text(text; style=style_obj, config.options...)
    end
end

# Sentinel error value for files excluded through `include`/`exclude` globs.
# The public API compares against it by identity (`===`) to distinguish
# exclusion from real formatting failures, so this exact object must be
# returned wherever exclusion is reported.
const _FORMAT_EXCLUDED_MESSAGE = "File is excluded by JuliaFormat.toml."

# Returns `(formatted_text::Union{String,Nothing}, error::Union{String,Nothing})`.
Salsa.@derived function derived_formatted_text(rt, uri)
    @debug "derived_formatted_text" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return (nothing, "File not found.")

    text = tf.content.content
    config = derived_format_configuration(rt, uri)
    config.selected || return (nothing, _FORMAT_EXCLUDED_MESSAGE)

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
    config.selected || return (nothing, _FORMAT_EXCLUDED_MESSAGE)

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
