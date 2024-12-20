Salsa.@derived function derived_formatterconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_formatterconfig_file(uri2filepath(file))]
end

struct RunicStyle <: JuliaFormatter.AbstractStyle
end

Salsa.@derived function derived_formatter_configuration(rt, uri)
    config_files = derived_formatterconfig_files(rt)

    config_files = sort(config_files, by=i->length(string(i)), rev=true)

    config_data = nothing

    for config_file in config_files
        config_folder_path = dirname(uri2filepath(config_file))

        if startswith(uri2filepath(uri), config_folder_path)
            config_data = derived_toml_syntax_tree(rt, config_file)
            break
        end
    end

    if config_data === nothing
        config_data = Dict()
    end

    if !haskey(config_data, "style")
        config_data["style"] = "minimal"
    end

    for (field, type) in fieldnts(JuliaFormatter.Options)
        if type == Union{Bool,Nothing}
            field = string(field)
            if get(config_data, field, "") == "nothing"
                config_data[field] = nothing
            end
        end
    end

    valid_styles = ("minimal", "default", "yas", "blue", "sciml", "runic")

    if !(config_data["style"] in valid_styles)
        return nothing
    end

    config_data["style"] = if config_data["style"] == "minimal"
        JuliaFormatter.MinimalStyle()
    elseif config_data["style"] == "default"
        JuliaFormatter.DefaultStyle()
    elseif config_data["style"] == "yas"
        JuliaFormatter.YASStyle()
    elseif config_data["style"] == "blue"
        JuliaFormatter.BlueStyle()
    elseif config_data["style"] == "sciml"
        JuliaFormatter.SciMLStyle()
    elseif config_data["style"] == "runic"
        RunicStyle()
    else
        error("Invalid style")
    end

    return config_data
end
