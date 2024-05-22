function with_changes(file::TextFile, changes::Vector{TextChange})
    # TODO Optimize for scenario with 0 changes

    new_content = file.content.content
    
    for change in changes
        # TODO Unclear whether it really helps that we use three SubString values here, but maybe it makes things more type stable somehow?
        a = SubString(new_content, 1, prevind(new_content, change.span.start))
        b = SubString(change.new_text, 1)
        c = SubString(new_content, nextind(new_content, change.span.stop), lastindex(new_content))
        new_content = string(a, b, c)
    end

    return TextFile(file.uri, SourceText(new_content, file.content.language_id))
end
