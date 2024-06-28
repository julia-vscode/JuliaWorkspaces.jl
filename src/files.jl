function with_changes(file::TextFile, changes::Vector{TextChange}, language_id::String)
    new_source_text = with_changes(file.content, changes, language_id)

    return TextFile(file.uri, new_source_text)
end
